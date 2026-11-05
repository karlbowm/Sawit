--[[
SawIt - Comm: sends and receives all addon messages. Two prefixes on the GUILD channel (WHISPER for directed sync):

  GAtlasD  structured data. On the wire: "3" .. EncodeForPrint(Seal("D", inner))
             inner = "0" .. AceSerializer output, or "1" .. CompressDeflate(AceSerializer output)
           The serialized tuple is always (PROTO, msgType, payload). Another PROTO => dropped.
  GAtlasP  positions. On the wire: "F" .. EncodeForPrint(Seal("P", packet)); the packet is the plain
           fixed-width string from Positions.lua, no serializer.
EncodeForPrint (LibDeflate) only uses a-z A-Z 0-9 ( ), 4 characters per 3 bytes. Until 2026-11-05 the sealed blob went
out as raw bytes (EncodeForWoWAddonChannel, markers "2"/"E"); two clients with the same secret then reported each
other's messages as unreadable, most likely because the server changes some bytes. Old markers count as "oldFormat".

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
-- dropped counts every message ignored before crypto; notMember and rateLimited are the interesting parts of it.
-- sendFail counts addon message chunks the client refused.
local stats = { txData = 0, rxData = 0, txBytes = 0, rxBytes = 0, dropped = 0, badProto = 0, unreadable = 0,
                plaintext = 0, oldFormat = 0, noKey = 0, notMember = 0, rateLimited = 0, sendFail = 0,
                echoOK = 0, echoChanged = 0 }
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

-- First character of every message: "3" data, "F" positions. "2"/"E" were the raw-byte format before 2026-11-05.
local MARK_DATA, MARK_POS = "3", "F"
local OLD_MARKS = { ["2"] = true, ["E"] = true }

local function debugOn() return GA.db and GA.db.profile.comm.debug end

-- Debug only: length and a 32-bit hash of a wire string. The tx line on the sender and the drop line on the
-- receiver show the same value when the bytes arrived unchanged.
-- In: s  string.  Out: e.g. "212B #1a2b3c4d"
local function fingerprint(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return ("%dB #%08x"):format(#s, h)
end

---------------------------------------------------------------------------
-- transport checks
---------------------------------------------------------------------------
-- The server sends our own GUILD messages back to us. Comparing them with what we sent shows whether it changes
-- them on the way (stats.echoOK / echoChanged, in /sawit status).
local sentRecent, sentOrder = {}, {}   -- the last 30 texts we sent to GUILD: text -> true, and oldest first

-- In: text  a wire string we just sent to GUILD
local function rememberSent(text)
    sentRecent[text] = true
    sentOrder[#sentOrder + 1] = text
    if #sentOrder > 30 then sentRecent[table.remove(sentOrder, 1)] = nil end
end

-- Raw message log for offline analysis: SawItDB.global.debugLog, filled only while /sawit debug is on and written to
-- disk on /reload or logout. Wire strings are stored as hex, so every byte survives the SavedVariables file.
-- Keeps the last 200 data messages and the last 40 position packets (those come every few seconds per guildmate).
-- In:  dir  "tx" | "rx";  kind  "D" | "P";  text  wire string;  channel;  who  sender (rx) or whisper target (tx)
-- Out: the entry, for the caller to fill in .why (rx), or nil when not logging
local function logMessage(dir, kind, text, channel, who)
    if not debugOn() or type(text) ~= "string" or GA.isSecret(text) then return nil end
    local log = GA.db.global.debugLog
    if not log then log = { data = {}, pos = {} }; GA.db.global.debugLog = log end
    local list, cap = kind == "P" and log.pos or log.data, kind == "P" and 40 or 200
    local e = { t = time(), dir = dir, kind = kind, chan = channel, who = who and tostring(who), me = GA.playerName,
                hex = Crypto.hex(text) }
    list[#list + 1] = e
    while #list > cap do table.remove(list, 1) end
    return e
end

-- Encrypts and tags text as sent by us, encoded for the addon channel.
-- In:  ctx   crypto context (GA:NetContext())
--      kind  "D" (data) or "P" (positions); a message sealed for one kind won't open as the other
--      text  plaintext string
-- Out: printable string (a-z A-Z 0-9 ( )), without the leading marker character
local function seal(ctx, kind, text)
    local me = short(GA.playerName)
    return LibDeflate:EncodeForPrint(Crypto.Seal(ctx, kind, me, text, Crypto.Nonce(me)))
end

-- Reverses seal() for a received message.
-- In:  ctx, kind  as for seal()
--      marker     expected first character (MARK_DATA or MARK_POS)
--      text       the received string;  sender  the server's sender name
-- Out: plaintext, or nil, reason: "old-format" (a SawIt from before 2026-11-05), "plaintext" (no marker: not
--      encrypted) or "unreadable" (wrong key, changed in transit, or re-sent by someone else)
local function unseal(ctx, kind, marker, text, sender)
    local m = text:sub(1, 1)
    if m ~= marker then return nil, OLD_MARKS[m] and "old-format" or "plaintext" end
    local blob = LibDeflate:DecodeForPrint(text:sub(2))
    local plain = blob and Crypto.Open(ctx, kind, short(sender), blob)
    if not plain then return nil, "unreadable" end
    return plain
end

---------------------------------------------------------------------------
-- send
---------------------------------------------------------------------------
-- AceComm callback, once per chunk (<= 255 bytes) after ChatThrottleLib handed it to the client. Through AceComm only
-- CTL's didSend flag arrives (CTL calls AceComm's wrapper with (arg, didSend, result); the wrapper passes didSend on
-- as its 4th argument), not the client's SendAddonMessageResult code. CTL retries throttled chunks itself.
-- In: label  "D" .. msgType or "P";  didSend  false when the client refused the chunk (not in guild, lockdown, ...)
local function onSent(label, _, _, didSend)
    if didSend ~= false then return end
    stats.sendFail = stats.sendFail + 1
    GA:Debug("send refused", label)
end

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
    local text = MARK_DATA .. seal(ctx, "D", inner)
    stats.txData, stats.txBytes = stats.txData + 1, stats.txBytes + #text
    channel = channel or "GUILD"
    if channel == "GUILD" then rememberSent(text) end
    local e = logMessage("tx", "D", text, channel, target)
    if e then
        e.why = msgType
        GA:Debug("tx", msgType, fingerprint(text), "as", short(GA.playerName), channel, target or "")
    end
    self:SendCommMessage(self.PREFIX_DATA, text, channel, target, prio or "NORMAL", onSent, "D" .. msgType)
    return true
end

-- Sends one position packet to the guild.
-- In:  packet  plain string from Positions.lua (sealed it stays well under 255 bytes)
--      prio    default "BULK"
-- Out: true if queued for sending, false if nothing may be sent right now
function Comm:SendRaw(packet, prio)
    local ctx = sendContext()
    if not ctx then return false end
    local text = MARK_POS .. seal(ctx, "P", packet)
    rememberSent(text)
    logMessage("tx", "P", text, "GUILD")
    self:SendCommMessage(self.PREFIX_POS, text, "GUILD", nil, prio or "BULK", onSent, "P")
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
-- Out: the crypto context to open the message with, or nil, reason to ignore it (counted in stats)
local function receiveContext(text, sender, buckets)
    if GA:IsTestMode() or not GA:InRealGuild() then return nil, "test-mode-or-no-guild" end
    local why
    if type(text) ~= "string" or GA.isSecret(text) then
        why = "not-string"
    elseif GA:IsMe(sender) then   -- our own GUILD message coming back: never handled, only compared with what we sent
        if sentRecent[text] then
            stats.dropped, stats.echoOK = stats.dropped + 1, stats.echoOK + 1
            return nil, "echo-ok"
        end
        why, stats.echoChanged = "echo-changed", stats.echoChanged + 1
    elseif GA.rosterReady and not GA:IsGuildMember(sender) then   -- before the roster loads, only the seal vets senders
        why, stats.notMember = "not-in-roster", stats.notMember + 1
    elseif not allow(buckets, sender) then
        why, stats.rateLimited = "rate-limited", stats.rateLimited + 1
    end
    if why then
        stats.dropped = stats.dropped + 1
        if debugOn() then GA:Debug("drop", tostring(sender), why, why ~= "not-string" and fingerprint(text) or "") end
        return nil, why
    end
    local ctx = GA:NetContext()
    if not ctx then stats.noKey = stats.noKey + 1; GA:Debug("drop", sender, "no-secret"); return nil, "no-secret" end
    Crypto.AddEntropy(#text)   -- arrival timing feeds the nonce/secret entropy pool
    return ctx
end

-- Counts a message that failed to unseal or decode.
-- In:  why  reason from unseal() or OnData
local function countFailure(why)
    local key = (why == "plaintext" or why == "unreadable") and why or why == "old-format" and "oldFormat" or "dropped"
    stats[key] = stats[key] + 1
end

-- Unseals a data message and undoes the compression.
-- In:  ctx, text, sender  as for unseal()
-- Out: the AceSerializer string, or nil, reason ("plaintext" | "unreadable" | "bad-flag" | "inflate-failed")
local function readData(ctx, text, sender)
    local inner, why = unseal(ctx, "D", MARK_DATA, text, sender)
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
    local e = logMessage("rx", "D", text, channel, sender) or {}
    local ctx, why = receiveContext(text, sender, dataBuckets)
    if not ctx then e.why = why; return end
    stats.rxData, stats.rxBytes = stats.rxData + 1, stats.rxBytes + #text
    local body
    body, why = readData(ctx, text, sender)
    if not body then
        countFailure(why)
        e.why = why
        if debugOn() then GA:Debug("drop", sender, why, fingerprint(text), "from", short(sender)) end
        return
    end
    local ok, proto, msgType, payload = AceSerializer:Deserialize(body)
    if not ok then countFailure("deserialize-failed"); e.why = "deserialize-failed"; return end
    e.why = "ok " .. tostring(msgType)
    if proto ~= self.PROTO then
        stats.badProto, e.why = stats.badProto + 1, "bad-proto"
        if type(proto) == "number" and proto > self.PROTO and not warnedNewer[sender] then
            warnedNewer[sender] = true
            GA:Print(("%s runs a newer SawIt protocol (%d > %d). Please update SawIt."):format(sender, proto, self.PROTO))
        end
        return
    end
    GA:Debug("rx", tostring(msgType), #text .. "B", channel, sender)
    local fn = handlers[msgType]
    if fn then
        local okCall, err = pcall(fn, GA:Normalize(sender), payload, channel)
        if not okCall then GA:Debug("handler error", msgType, err) end
    end
end

-- AceComm callback for the position prefix: unseal, then pass the plain packet to the position handler.
-- In:  prefix, text, channel, sender  as delivered by AceComm
function Comm:OnRaw(prefix, text, channel, sender)
    if type(text) == "string" and #text > 255 then return end   -- a sealed position packet is ~50 bytes
    local e = logMessage("rx", "P", text, channel, sender) or {}
    local ctx, why = receiveContext(text, sender, posBuckets)
    if not ctx then e.why = why; return end
    local packet
    packet, why = unseal(ctx, "P", MARK_POS, text, sender)
    e.why = packet and "ok" or why
    if not packet then countFailure(why); return end
    if rawHandler then
        local ok, err = pcall(rawHandler, GA:Normalize(sender), packet, channel)
        if not ok then GA:Debug("raw handler error", err) end
    end
end
