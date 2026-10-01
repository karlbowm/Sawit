--[[
SawIt - Crypto: guild-secret encryption for addon messages. Pure Lua 5.1.

The primitives (SHA-256, HMAC-SHA256) come from LibHash-1.0 (Libs/LibHash-1.0, a WoW port of Egor Skriptunoff's
pure_lua_SHA, MIT). This file only combines them, using standard constructions:
  PBKDF2-HMAC-SHA256            RFC 8018; secret -> 32-byte master key, run once when the secret is entered, then cached
  keystream block i             HMAC(K_enc, nonce .. uint32(i)); ciphertext = plaintext XOR keystream (HMAC as PRF in
                                counter mode)
  tag                           first 10 bytes of HMAC(K_mac, kind .. len(name) .. name .. nonce .. ciphertext)
  K_enc, K_mac, check code      HMAC(master, "SawIt enc" / "SawIt mac" / "SawIt check")
tests/test_crypto.lua checks all of it against values computed with Python's hashlib/hmac.

Sealed blob = nonce(12) .. ciphertext .. tag(10). Open() checks the tag before anything else is done with the data.
kind is the channel ("D" data, "P" positions); name is the sender without realm, so a message can't be replayed as
another channel or re-sent by another player. Nonces must never repeat under one key, and every guildmate shares the
key, so the nonce is a hash of our own name, a per-session counter, the clock, a high-resolution timer and an entropy
pool (see Nonce).
]]
local _, ns = ...
local GA = ns.addon

local Crypto = {}
GA.Crypto = Crypto

local LH = LibStub("LibHash-1.0")

local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat
local NONCE, TAG = 12, 10
Crypto.NONCE, Crypto.TAG = NONCE, TAG
Crypto.KDF_ITER = 1000   -- once per secret entry; tests lower it

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
-- In:  s  binary string.  Out: lowercase hex string
local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(byte(c)) end)) end
-- In:  h  hex string.  Out: binary string
local unhex = LH.hex2bin
Crypto.hex, Crypto.unhex = hex, unhex

-- XOR of two bytes (0..255), bit by bit, so no bit library is needed.
local function xorByte(a, b)
    local r, p = 0, 1
    while a > 0 or b > 0 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + p end
        a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
end

-- In:  a, b  binary strings, #b >= #a.  Out: a XOR b, #a bytes long
local function xorStr(a, b)
    local out = {}
    for i = 1, #a do out[i] = char(xorByte(byte(a, i), byte(b, i))) end
    return concat(out)
end

-- In:  x  integer 0..2^32-1.  Out: 4 bytes, big-endian
local function be32(x) return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256) end

---------------------------------------------------------------------------
-- primitives (LibHash), returning binary strings
---------------------------------------------------------------------------
-- In:  msg  binary string.  Out: 32-byte SHA-256 digest
function Crypto.SHA256(msg) return unhex(LH.sha256(msg)) end

-- In:  key, msg  binary strings.  Out: 32-byte HMAC-SHA256
function Crypto.HMAC(key, msg) return unhex(LH.hmac(LH.sha256, key, msg)) end

-- PBKDF2-HMAC-SHA256 with one output block.
-- In:  password, salt  strings;  iterations  number >= 1.  Out: 32-byte key
function Crypto.PBKDF2(password, salt, iterations)
    local u = Crypto.HMAC(password, salt .. be32(1))
    local t = u
    for _ = 2, iterations do
        u = Crypto.HMAC(password, u)
        t = xorStr(t, u)
    end
    return t
end

---------------------------------------------------------------------------
-- keys
---------------------------------------------------------------------------
-- Turns the guild secret into the master key. Salted with the guild name only (not the realm: connected realms mean
-- guildmates can report different realm names). Surrounding spaces are ignored so a pasted secret still matches.
-- In:  secretText, guildName  strings.  Out: 32-byte master key
function Crypto.DeriveMaster(secretText, guildName)
    local s = tostring(secretText or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return Crypto.PBKDF2(s, "SawIt guild secret v1|" .. tostring(guildName), Crypto.KDF_ITER)
end

-- Short code guildmates compare to see they entered the same secret. From its own HMAC label, so it tells an
-- observer nothing about the keys.
-- In:  master  32-byte key.  Out: "ABC-DEF"
function Crypto.CheckCode(master)
    local h = hex(Crypto.HMAC(master, "SawIt check"):sub(1, 3)):upper()
    return h:sub(1, 3) .. "-" .. h:sub(4, 6)
end

-- In:  master  32-byte key.  Out: context for Seal/Open: { enc = encryption key, mac = tag key }
function Crypto.NewContext(master)
    return { enc = Crypto.HMAC(master, "SawIt enc"), mac = Crypto.HMAC(master, "SawIt mac") }
end

---------------------------------------------------------------------------
-- entropy, nonces, generated secrets
---------------------------------------------------------------------------
local pool = ""     -- 32-byte hash of everything mixed in so far (binary)
local counter = 0   -- nonces sent this session
local function clock() return (debugprofilestop and debugprofilestop() or 0) end

-- Mixes timing noise into the pool (called on incoming messages and key presses in the secret window).
-- In:  x  anything with a tostring
function Crypto.AddEntropy(x)
    pool = Crypto.SHA256(pool .. tostring(x) .. "|" .. clock() .. "|" .. math.random())
end

-- A fresh nonce for one message.
-- In:  selfName  our name without realm (makes nonces of different players differ).  Out: 12 bytes
function Crypto.Nonce(selfName)
    counter = counter + 1
    -- pool is binary: appended with .., since Lua 5.1's format("%s") stops at a zero byte
    return Crypto.SHA256(("%s|%d|%d|%.6f|%.17g|"):format(tostring(selfName), counter, time(), clock(), math.random())
        .. pool):sub(1, NONCE)
end

-- A random secret for an officer to hand out: 20 characters from a 32-letter alphabet (100 bits), grouped for
-- reading out.
-- In:  extra  optional string mixed in (e.g. the player name).  Out: "K7QWM-3PZXA-..."
local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
function Crypto.RandomSecret(extra)
    local cx, cy = 0, 0
    if GetCursorPosition then cx, cy = GetCursorPosition() end
    local seed = Crypto.SHA256(("%s|%d|%.6f|%.6f|%s|%s|%.17g|%.17g|%.17g|"):format(tostring(extra), time(), clock(),
        GetTime and GetTime() or 0, tostring(cx), tostring(cy), math.random(), math.random(), math.random()) .. pool)
    local out = {}
    for i = 1, 20 do
        local v = byte(seed, i) % 32
        out[#out + 1] = ALPHABET:sub(v + 1, v + 1)
        if i % 5 == 0 and i < 20 then out[#out + 1] = "-" end
    end
    Crypto.AddEntropy(seed)
    return concat(out)
end

---------------------------------------------------------------------------
-- seal / open
---------------------------------------------------------------------------
-- In:  ctx, nonce;  n  bytes needed.  Out: at least n keystream bytes
local function keystream(ctx, nonce, n)
    local blocks = {}
    for i = 0, floor((n - 1) / 32) do blocks[#blocks + 1] = Crypto.HMAC(ctx.enc, nonce .. be32(i)) end
    return concat(blocks)
end

-- In:  ctx, kind, name, nonce, ct.  Out: 10-byte tag over all of them
local function tagOf(ctx, kind, name, nonce, ct)
    return Crypto.HMAC(ctx.mac, kind .. char(#name % 256) .. name .. nonce .. ct):sub(1, TAG)
end

-- Encrypts and tags a message.
-- In:  ctx  from NewContext;  kind  "D" or "P";  name  sender without realm ("Marcus", not "Marcus-Realm");
--      plaintext  string;  nonce  12 bytes from Nonce()
-- Out: sealed blob (binary): nonce .. ciphertext .. tag
function Crypto.Seal(ctx, kind, name, plaintext, nonce)
    local ct = #plaintext > 0 and xorStr(plaintext, keystream(ctx, nonce, #plaintext)) or ""
    return nonce .. ct .. tagOf(ctx, kind, name, nonce, ct)
end

-- Checks the tag, then decrypts.
-- In:  ctx, kind, name  as for Seal;  blob  sealed blob
-- Out: the plaintext, or nil when the blob was not sealed with this key, kind and sender (or was changed)
function Crypto.Open(ctx, kind, name, blob)
    if type(blob) ~= "string" or #blob < NONCE + TAG then return nil end
    local nonce, ct, tag = blob:sub(1, NONCE), blob:sub(NONCE + 1, -TAG - 1), blob:sub(-TAG)
    if tagOf(ctx, kind, name, nonce, ct) ~= tag then return nil end
    if #ct == 0 then return "" end
    return xorStr(ct, keystream(ctx, nonce, #ct))
end
