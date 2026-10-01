--[[
SawIt - Comm: sends and receives all addon messages. Two prefixes on the GUILD channel (WHISPER for directed sync):

  GAtlasD  structured data. On the wire: "2" .. EncodeForWoWAddonChannel(Seal("D", inner))
             inner = "0" .. AceSerializer output, or "1" .. CompressDeflate(AceSerializer output)
           The serialized tuple is always (PROTO, msgType, payload). Another PROTO => dropped.
  GAtlasP  positions. On the wire: "E" .. EncodeForWoWAddonChannel(Seal("P", packet)); the packet is the plain
           fixed-width string from Positions.lua, no serializer.

Everything is sealed with the guild secret (Core/Crypto.lua: encrypted, plus a tag bound to channel and sender).
Without a secret nothing is sent, and anything not sealed with our key is dropped unread: unencrypted messages (old
SawIt/GuildAtlas, or someone without the secret), a wrong secret, tampering, or a message re-sent by another player.
The counts are in Comm.stats for /sawit status.

Transport is AceComm-3.0 -> ChatThrottleLib. Priorities used by callers:
  ALERT  live note edits      NORMAL  note sync      BULK  positions
CTL keeps one queue per priority, so position traffic never sits in front of note data.

What a handler can rely on: the sender is a guild member (once the roster is known) and within its rate limit, the
seal is valid, PROTO matches, the payload deserialised. Content is still untrusted: the modules check it.
]]
local _, ns = ...
local GA = ns.addon

local Comm = GA:NewModule("Comm")
GA.Comm = Comm

Comm.PROTO = 1
Comm.PREFIX_DATA = "GAtlasD"
Comm.PREFIX_POS = "GAtlasP"

local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate")   -- embedded (embeds.xml); required for the wire encoding
local Crypto = GA.Crypto

LibStub("AceComm-3.0"):Embed(Comm)

local handlers = {}   -- msgType -> function(sender, payload, channel)
local rawHandler      -- function(sender, packet, channel), for positions
local stats = { txData = 0, rxData = 0, txBytes = 0, rxBytes = 0, dropped = 0, badProto = 0,
                unreadable = 0, plaintext = 0, noKey = 0 }
Comm.stats = stats

---------------------------------------------------------------------------
-- registration
---------------------------------------------------------------------------
-- Registers the function that handles one type of data message (one per type; a second call replaces it).
-- In:  msgType  string, e.g. "U"
--      fn       function(sender, payload, channel); sender is normalized (GA:Normalize)
function Comm:RegisterHandler(msgType, fn) handlers[msgType] = fn end

-- Registers the function that handles position packets (there is only one).
-- In:  fn  function(sender, packet, channel); packet is the decrypted plain string
function Comm:RegisterRawHandler(fn) rawHandler = fn end

-- AceAddon callback: start listening on both prefixes.
function Comm:OnEnable()
    self:RegisterComm(self.PREFIX_DATA, "OnData")
    self:RegisterComm(self.PREFIX_POS, "OnRaw")
end

-- Is addon messaging blocked right now (encounters / restricted content on Midnight-style clients)?
-- Out: true while locked; false otherwise, or when the client has no such API.
function Comm:IsLockedDown()
    local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    return f ~= nil and f() == true
end

---------------------------------------------------------------------------
-- sealing
---------------------------------------------------------------------------
-- Sender name without realm. The client formats cross-realm names differently on each end, so the seal uses this.
-- In:  name  "Name" or "Name-Realm"
-- Out: "Name"
local function short(name) return (tostring(name):match("^[^-]+")) end

-- Encrypts and tags text as sent by us, encoded for the addon channel.
-- In:  ctx   crypto context (GA:NetContext())
--      kind  "D" (data) or "P" (positions); a message sealed for one kind won't open as the other
--      text  plaintext string
-- Out: wire-safe string (no "\0"), without the leading marker character
local function seal(ctx, kind, text)
    local me = short(GA.playerName)
    return LibDeflate:EncodeForWoWAddonChannel(Crypto.Seal(ctx, kind, me, text, Crypto.Nonce(me)))
end

-- Reverses seal() for a received message.
-- In:  ctx, kind  as for seal()
--      marker     expected first character ("2" for data, "E" for positions)
--      text       the received string;  sender  the server's sender name
-- Out: plaintext, or nil, reason: "plaintext" (no marker: not encrypted) or "unreadable" (wrong key, tampered,
--      or re-sent by someone else)
local function unseal(ctx, kind, marker, text, sender)
    if text:sub(1, 1) ~= marker then return nil, "plaintext" end
    local blob = LibDeflate:DecodeForWoWAddonChannel(text:sub(2))
    local plain = blob and Crypto.Open(ctx, kind, short(sender), blob)
    if not plain then return nil, "unreadable" end
    return plain
end

---------------------------------------------------------------------------
-- send
---------------------------------------------------------------------------
-- The crypto context to send with, or nil when nothing may be sent (no guild, no secret, test mode, lockdown).
local function sendContext()
    if not GA:CanUseNetwork() or Comm:IsLockedDown() then return nil end
    return GA:NetContext()
end

-- Sends one data message. AceComm splits it into several addon messages if it is longer than 255 bytes.
-- In:  msgType  string;  payload  any AceSerializer-able value
--      channel  "GUILD" (default) or "WHISPER" (then target = player name)
--      prio     "ALERT" | "NORMAL" (default) | "BULK"
-- Out: true if queued for sending, false if nothing may be sent right now
function Comm:Send(msgType, payload, channel, target, prio)
    local ctx = sendContext()
    if not ctx then return false end
    local s = AceSerializer:Serialize(self.PROTO, msgType, payload)
    local inner = "0" .. s
    if #s > 80 then   -- small messages don't shrink
        local c = LibDeflate:CompressDeflate(s)
        if #c < #s then inner = "1" .. c end
    end
    local text = "2" .. seal(ctx, "D", inner)
    stats.txData, stats.txBytes = stats.txData + 1, stats.txBytes + #text
    GA:Debug("tx", msgType, #text .. "B", channel or "GUILD", target or "")
    self:SendCommMessage(self.PREFIX_DATA, text, channel or "GUILD", target, prio or "NORMAL")
    return true
end

-- Sends one position packet to the guild.
-- In:  packet  plain string from Positions.lua (sealed it stays well under 255 bytes)
--      prio    default "BULK"
-- Out: true if queued for sending, false if nothing may be sent right now
function Comm:SendRaw(packet, prio)
    local ctx = sendContext()
    if not ctx then return false end
    self:SendCommMessage(self.PREFIX_POS, "E" .. seal(ctx, "P", packet), "GUILD", nil, prio or "BULK")
    return true
end

---------------------------------------------------------------------------
-- receive
---------------------------------------------------------------------------
-- Rate limit: token bucket per sender and prefix, 40 messages burst, refilled at 4 per second. A full sync from
-- one peer is a handful of messages, so this only stops a flooding or broken client.
local dataBuckets, posBuckets = {}, {}

-- In:  buckets  dataBuckets or posBuckets;  sender  name
-- Out: true if the sender may send another message now (and uses up one token)
local function allow(buckets, sender)
    local now = GetTime()
    local b = buckets[sender]
    if not b then b = { tokens = 40, t = now }; buckets[sender] = b end
    b.tokens = math.min(40, b.tokens + (now - b.t) * 4)
    b.t = now
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

-- Checks that apply to every received message, cheapest first and before any crypto work.
-- In:  text  received string;  sender  name;  buckets  rate-limit table for this prefix
-- Out: the crypto context to open the message with, or nil to ignore it (counted in stats)
local function receiveContext(text, sender, buckets)
    if GA:IsTestMode() or not GA:InRealGuild() then return nil end   -- test mode ignores the real guild
    if type(text) ~= "string" or GA.isSecret(text) or GA:IsMe(sender)
        or (GA.rosterReady and not GA:IsGuildMember(sender))   -- before the roster loads, only the seal vets senders
        or not allow(buckets, sender) then
        stats.dropped = stats.dropped + 1
        return nil
    end
    local ctx = GA:NetContext()
    if not ctx then stats.noKey = stats.noKey + 1; return nil end
    Crypto.AddEntropy(#text)   -- arrival timing feeds the nonce/secret entropy pool
    return ctx
end

-- Counts a message that failed to unseal or decode.
-- In:  why  reason from unseal() or OnData
local function countFailure(why)
    local key = (why == "plaintext" or why == "unreadable") and why or "dropped"
    stats[key] = stats[key] + 1
end

-- Unseals a data message and undoes the compression.
-- In:  ctx, text, sender  as for unseal()
-- Out: the AceSerializer string, or nil, reason ("plaintext" | "unreadable" | "bad-flag" | "inflate-failed")
local function readData(ctx, text, sender)
    local inner, why = unseal(ctx, "D", "2", text, sender)
    if not inner then return nil, why end
    local flag, body = inner:sub(1, 1), inner:sub(2)
    if flag == "0" then return body end
    if flag ~= "1" then return nil, "bad-flag" end
    body = LibDeflate:DecompressDeflate(body)
    if not body then return nil, "inflate-failed" end
    return body
end

-- AceComm callback for the data prefix: unseal, decompress, deserialize, then call the handler for msgType.
-- In:  prefix, text, channel, sender  as delivered by AceComm (text already reassembled from its parts)
local warnedNewer = {}
function Comm:OnData(prefix, text, channel, sender)
    local ctx = receiveContext(text, sender, dataBuckets)
    if not ctx then return end
    stats.rxData, stats.rxBytes = stats.rxData + 1, stats.rxBytes + #text
    local body, why = readData(ctx, text, sender)
    if not body then countFailure(why); GA:Debug("drop", sender, why); return end
    local ok, proto, msgType, payload = AceSerializer:Deserialize(body)
    if not ok then countFailure("deserialize-failed"); return end
    if proto ~= self.PROTO then
        stats.badProto = stats.badProto + 1
        if type(proto) == "number" and proto > self.PROTO and not warnedNewer[sender] then
            warnedNewer[sender] = true
            GA:Print(("%s runs a newer SawIt protocol (%d > %d). Please update SawIt."):format(sender, proto, self.PROTO))
        end
        return
    end
    local fn = handlers[msgType]
    if fn then
        local okCall, err = pcall(fn, GA:Normalize(sender), payload, channel)
        if not okCall then GA:Debug("handler error", msgType, err) end
    end
end

-- AceComm callback for the position prefix: unseal, then pass the plain packet to the position handler.
-- In:  prefix, text, channel, sender  as delivered by AceComm
function Comm:OnRaw(prefix, text, channel, sender)
    if type(text) == "string" and #text > 255 then return end   -- a sealed position packet is ~40 bytes
    local ctx = receiveContext(text, sender, posBuckets)
    if not ctx then return end
    local packet, why = unseal(ctx, "P", "E", text, sender)
    if not packet then countFailure(why); return end
    if rawHandler then
        local ok, err = pcall(rawHandler, GA:Normalize(sender), packet, channel)
        if not ok then GA:Debug("raw handler error", err) end
    end
end
