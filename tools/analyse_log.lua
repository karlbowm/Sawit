--[[
SawIt - offline analysis of the raw addon message log (Comm.lua, logMessage). Not loaded by the game.

In game: /sawit debug (starts a fresh log), reproduce the problem, /reload (writes SawItDB to disk). Then, from the
SawIt folder:
    lua5.1 tools/analyse_log.lua ../../../WTF/Account/<ACCOUNT>/SavedVariables/SawIt.lua
It uses the guild key stored in that file and the real Crypto/LibDeflate/AceSerializer code, and prints per message:
  - whether the wire string decodes (printable format "3"/"F", or the raw-byte format "2"/"E" of older SawIt);
  - whether the seal opens with the sender's name, and if not, why: the key is right but the tag isn't (the bytes
    changed on the way, or the sender name differs), or the key itself is different (another secret);
  - for our own GUILD messages that came back from the server: whether they match what we sent, byte by byte.
Works on a guildmate's SawIt.lua as well (with their key).
]]
local path = arg[1]
if not path then
    io.stderr:write("usage: lua5.1 tools/analyse_log.lua <path to SavedVariables/SawIt.lua>\n")
    os.exit(1)
end

time = os.time
assert(loadfile("Libs/Ace3/LibStub/LibStub.lua"))()
assert(loadfile("Libs/LibHash-1.0/LibHash-1.0.lua"))()
assert(loadfile("Libs/LibDeflate/LibDeflate.lua"))()
assert(loadfile("Libs/Ace3/AceSerializer-3.0/AceSerializer-3.0.lua"))()
local ns = { addon = {} }
assert(loadfile("Core/Crypto.lua"))("SawIt", ns)
local Crypto = ns.addon.Crypto
local LibDeflate = LibStub("LibDeflate")
local AceSerializer = LibStub("AceSerializer-3.0")

-- The SavedVariables file is plain Lua assigning SawItDB; run it in an empty environment.
local env = {}
local chunk = assert(loadfile(path))
setfenv(chunk, env)
chunk()
local db = env.SawItDB
assert(db and db.global, "no SawItDB in " .. path)
local log = db.global.debugLog
if not log or (#(log.data or {}) == 0 and #(log.pos or {}) == 0) then
    print("No messages logged. In game: /sawit debug, reproduce, then /reload before running this.")
    os.exit(0)
end

---------------------------------------------------------------------------
-- key
---------------------------------------------------------------------------
local guildKey, entry = next(db.global.netKeys or {})
if next(db.global.netKeys or {}, guildKey) then
    print("Several guild keys stored; using the one for " .. tostring(guildKey))
end
assert(entry and entry.key, "no guild key (netKeys) in this file: set the secret first")
local ctx = Crypto.NewContext(Crypto.unhex(entry.key))
print(("Guild %s, check code %s"):format(guildKey, tostring(entry.check)))

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function short(name) return (tostring(name):match("^[^-]+")) end

-- Every name seen in the log (senders and ourselves): candidates when a tag doesn't match the expected name.
local names = {}
for _, list in pairs({ log.data or {}, log.pos or {} }) do
    for _, e in ipairs(list) do
        if e.who then names[short(e.who)] = true end
        if e.me then names[short(e.me)] = true end
    end
end

-- In: wire string.  Out: sealed blob or nil, format name
local function decode(text)
    local m = text:sub(1, 1)
    if m == "3" or m == "F" then return LibDeflate:DecodeForPrint(text:sub(2)), "printable" end
    if m == "2" or m == "E" then return LibDeflate:DecodeForWoWAddonChannel(text:sub(2)), "raw-bytes" end
    return nil, "unknown marker " .. ("%q"):format(m)
end

-- Decrypts without checking the tag (Seal on the ciphertext with the same nonce gives back the plaintext).
-- Only for analysis: the addon never does this.
local function peek(kind, blob)
    local nonce, ct = blob:sub(1, Crypto.NONCE), blob:sub(Crypto.NONCE + 1, -Crypto.TAG - 1)
    return Crypto.Seal(ctx, kind, "", ct, nonce):sub(Crypto.NONCE + 1, -Crypto.TAG - 1)
end

-- Does a decrypted plaintext have the shape SawIt sends? Out: description, or nil
local function plausible(kind, plain)
    if kind == "P" then
        if plain == "0" then return "position: stopped sharing" end
        if plain:match("^1%d%d%d%d%d%d%d%d%d%d%d%d%d$") then return "position packet " .. plain end
        return nil
    end
    local flag, body = plain:sub(1, 1), plain:sub(2)
    if flag == "1" then body = LibDeflate:DecompressDeflate(body) end
    if (flag == "0" or flag == "1") and body then
        local ok, proto, msgType = AceSerializer:Deserialize(body)
        if ok then return ("data: PROTO %s, type %s"):format(tostring(proto), tostring(msgType)) end
    end
    return nil
end

-- Is the start of a tag-less decryption what SawIt sends? With a wrong key it is random bytes. A changed byte
-- later in the message only spoils the plaintext from there on (stream cipher), so the start still shows the key.
local function keyLooksRight(kind, plain)
    if kind == "P" then return plain == "0" or plain:match("^1%d%d%d%d%d") ~= nil end
    if plain:sub(1, 7) == "0^1^N1^" then return true end   -- uncompressed: flag "0", AceSerializer header, PROTO 1
    return plain:sub(1, 1) == "1" and LibDeflate:DecompressDeflate(plain:sub(2)) ~= nil
end

local function printable(s, n)
    return (s:sub(1, n or 40):gsub("[^%w%p ]", "."))
end

---------------------------------------------------------------------------
-- per message
---------------------------------------------------------------------------
local totals = {}
local function count(k) totals[k] = (totals[k] or 0) + 1 end

local function analyse(e)
    local text = Crypto.unhex(e.hex)
    local head = ("%s %s %-5s %-8s %-24s %4dB  logged: %-16s"):format(os.date("%H:%M:%S", e.t), e.dir, e.kind,
        tostring(e.chan), tostring(e.who or ""), #text, tostring(e.why))
    local blob, fmt = decode(text)
    if not blob then count("decode failed"); return print(head .. "  DECODE FAILED (" .. fmt .. ")") end
    if #blob < Crypto.NONCE + Crypto.TAG then count("too short"); return print(head .. "  too short to be sealed") end
    local sender = short(e.dir == "tx" and e.me or e.who)
    local plain = Crypto.Open(ctx, e.kind, sender, blob)
    if plain then
        count("opens")
        return print(head .. "  opens [" .. fmt .. "]: " .. (plausible(e.kind, plain) or ("? " .. printable(plain))))
    end
    for n in pairs(names) do   -- right key, other name?
        if n ~= sender and Crypto.Open(ctx, e.kind, n, blob) then
            count("opens with another name")
            return print(head .. ("  OPENS ONLY AS %q, not %q: sender name mismatch"):format(n, sender))
        end
    end
    local p = peek(e.kind, blob)
    if keyLooksRight(e.kind, p) then
        count("key right, tag wrong")
        return print(head .. "  KEY RIGHT, TAG WRONG [" .. fmt .. "]: bytes changed on the way? decrypts to "
            .. (plausible(e.kind, p) or printable(p, 24)))
    end
    count("wrong key or garbled")
    print(head .. "  WRONG KEY or garbled from the start [" .. fmt .. "]: decrypts to " .. printable(p, 16))
end

-- Our own GUILD messages come back from the server: compare each with the tx entry it should equal.
local function compareEchoes(list)
    local sent = {}
    for _, e in ipairs(list) do
        if e.dir == "tx" and e.chan == "GUILD" then sent[#sent + 1] = e end
    end
    for _, e in ipairs(list) do
        if e.dir == "rx" and e.who and e.me and short(e.who) == short(e.me) then
            local exact = false
            for _, s in ipairs(sent) do if s.hex == e.hex then exact = true end end
            if exact then
                count("echo unchanged")
            else
                count("echo changed")
                -- closest tx: same nonce (first 12 bytes after decoding) if it survived, else same length and time
                local rx = Crypto.unhex(e.hex)
                local best
                for _, s in ipairs(sent) do
                    if s.kind == e.kind and math.abs(s.t - e.t) < 10 and (not best or #s.hex == #e.hex) then best = s end
                end
                print(("echo at %s (%dB) differs from everything we sent"):format(os.date("%H:%M:%S", e.t), #rx))
                if best then
                    local tx = Crypto.unhex(best.hex)
                    print(("  closest tx %dB at %s; first differences:"):format(#tx, os.date("%H:%M:%S", best.t)))
                    local shown = 0
                    for i = 1, math.max(#tx, #rx) do
                        local a, b = tx:byte(i), rx:byte(i)
                        if a ~= b and shown < 12 then
                            shown = shown + 1
                            print(("    byte %4d: sent %s, got %s"):format(i, a and ("0x%02x"):format(a) or "-",
                                b and ("0x%02x"):format(b) or "-"))
                        end
                    end
                end
            end
        end
    end
end

for _, part in ipairs({ { "data messages", log.data or {} }, { "position packets", log.pos or {} } }) do
    print(("\n== %s (%d) =="):format(part[1], #part[2]))
    for _, e in ipairs(part[2]) do analyse(e) end
    compareEchoes(part[2])
end

print("\n== summary ==")
for k, v in pairs(totals) do print(("%-26s %d"):format(k, v)) end
