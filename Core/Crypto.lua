--[[
SawIt - Crypto: guild-secret encryption for addon messages. Pure Lua 5.1, no WoW API except bit/time helpers.

Only one primitive, SHA-256, verified against Python hashlib vectors in tests/test_crypto.lua. Everything else is built
from it:
  HMAC-SHA256                   RFC 2104
  PBKDF2-HMAC-SHA256            RFC 8018; secret -> 32-byte master key, run once when the secret is entered, then cached
  keystream block i             HMAC(K_enc, nonce .. uint32(i)); ciphertext = plaintext XOR keystream (HMAC as PRF in
                                counter mode)
  tag                           first 10 bytes of HMAC(K_mac, kind .. len(name) .. name .. nonce .. ciphertext)
  K_enc, K_mac, check code      HMAC(master, "SawIt enc" / "SawIt mac" / "SawIt check")

Sealed blob = nonce(12) .. ciphertext .. tag(10). Open() checks the tag before anything else is done with the data.
kind is the channel ("D" data, "P" positions); name is the sender without realm, so a message can't be replayed as
another channel or re-sent by another player. Nonces must never repeat under one key, and every guildmate shares the
key, so the nonce is a hash of our own name, a per-session counter, the clock, a high-resolution timer and an entropy
pool (see Nonce).

The `bit` library is used when it has band/bxor (WoW's does); results are taken mod 2^32 in case it returns signed
values. Without it (plain Lua in tests) a slower table-based fallback is used. Rotates and shifts are plain arithmetic.
]]
local _, ns = ...
local GA = ns.addon

local Crypto = {}
GA.Crypto = Crypto

local floor, char, byte, rep, concat = math.floor, string.char, string.byte, string.rep, table.concat
local M32 = 4294967296
local NONCE, TAG = 12, 10
Crypto.NONCE, Crypto.TAG = NONCE, TAG
Crypto.KDF_ITER = 1000   -- ~2000 SHA-256 blocks, once per secret entry; tests lower it

---------------------------------------------------------------------------
-- 32-bit and/xor
---------------------------------------------------------------------------
local band, bxor
local lib = _G.bit
if lib and lib.band and lib.bxor then
    local ba, bx = lib.band, lib.bxor
    band = function(x, y) return ba(x, y) % M32 end
    bxor = function(x, y) return bx(x, y) % M32 end
else
    local AND, XOR = {}, {}
    for a = 0, 255 do
        for b = 0, 255 do
            local r_and, r_xor, p, x, y = 0, 0, 1, a, b
            for _ = 1, 8 do
                local xa, yb = x % 2, y % 2
                if xa == 1 and yb == 1 then r_and = r_and + p end
                if xa ~= yb then r_xor = r_xor + p end
                x, y, p = (x - xa) / 2, (y - yb) / 2, p * 2
            end
            AND[a * 256 + b], XOR[a * 256 + b] = r_and, r_xor
        end
    end
    local function op(t, x, y)
        local r, p = 0, 1
        for _ = 1, 4 do
            local xa, yb = x % 256, y % 256
            r = r + t[xa * 256 + yb] * p
            x, y, p = (x - xa) / 256, (y - yb) / 256, p * 256
        end
        return r
    end
    band = function(x, y) return op(AND, x, y) end
    bxor = function(x, y) return op(XOR, x, y) end
end

local function rrot(x, n) local p = 2 ^ n; local lo = x % p; return (x - lo) / p + lo * 2 ^ (32 - n) end
local function rshift(x, n) return floor(x / 2 ^ n) end

---------------------------------------------------------------------------
-- SHA-256
---------------------------------------------------------------------------
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local IV = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

local W = {}
local function compress(H, s, i)
    for j = 0, 15 do
        local a, b, c, d = byte(s, i + j * 4, i + j * 4 + 3)
        W[j] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for j = 16, 63 do
        local w15, w2 = W[j - 15], W[j - 2]
        local s0 = bxor(bxor(rrot(w15, 7), rrot(w15, 18)), rshift(w15, 3))
        local s1 = bxor(bxor(rrot(w2, 17), rrot(w2, 19)), rshift(w2, 10))
        W[j] = (W[j - 16] + s0 + W[j - 7] + s1) % M32
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for j = 0, 63 do
        local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
        local ch = bxor(band(e, f), band(M32 - 1 - e, g))
        local t1 = (h + S1 + ch + K[j + 1] + W[j]) % M32
        local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
        local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
        h, g, f, e, d, c, b, a = g, f, e, (d + t1) % M32, c, b, a, (t1 + S0 + maj) % M32
    end
    H[1], H[2], H[3], H[4] = (H[1] + a) % M32, (H[2] + b) % M32, (H[3] + c) % M32, (H[4] + d) % M32
    H[5], H[6], H[7], H[8] = (H[5] + e) % M32, (H[6] + f) % M32, (H[7] + g) % M32, (H[8] + h) % M32
end

local function be32(x) return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256) end

-- Hash msg continuing from state H0, which has already absorbed preLen bytes (a multiple of 64).
local function digest(H0, preLen, msg)
    local H = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local len = preLen + #msg
    local pad = (55 - len) % 64
    local bits = len * 8
    msg = msg .. "\128" .. rep("\0", pad) .. be32(floor(bits / M32)) .. be32(bits % M32)
    for i = 1, #msg, 64 do compress(H, msg, i) end
    local out = {}
    for j = 1, 8 do out[j] = be32(H[j]) end
    return concat(out)
end

function Crypto.SHA256(msg) return digest(IV, 0, msg) end

---------------------------------------------------------------------------
-- HMAC, PBKDF2
---------------------------------------------------------------------------
local function xorStr(a, b)   -- #b >= #a
    local out = {}
    for i = 1, #a do out[i] = char(bxor(byte(a, i), byte(b, i))) end
    return concat(out)
end

-- Precomputed HMAC key: the inner and outer hash states after the padded key block.
local function hmacKey(key)
    if #key > 64 then key = Crypto.SHA256(key) end
    key = key .. rep("\0", 64 - #key)
    local inner, outer = { unpack(IV) }, { unpack(IV) }
    compress(inner, xorStr(key, rep("\54", 64)), 1)
    compress(outer, xorStr(key, rep("\92", 64)), 1)
    return { inner = inner, outer = outer }
end

local function hmacWith(k, msg) return digest(k.outer, 64, digest(k.inner, 64, msg)) end

function Crypto.HMAC(key, msg) return hmacWith(hmacKey(key), msg) end

function Crypto.PBKDF2(password, salt, iterations)
    local k = hmacKey(password)
    local u = hmacWith(k, salt .. be32(1))
    local t = u
    for _ = 2, iterations do
        u = hmacWith(k, u)
        t = xorStr(t, u)
    end
    return t
end

---------------------------------------------------------------------------
-- keys
---------------------------------------------------------------------------
local function hex(s) return (s:gsub(".", function(c) return ("%02x"):format(byte(c)) end)) end
local function unhex(h) return (h:gsub("%x%x", function(x) return char(tonumber(x, 16)) end)) end
Crypto.hex, Crypto.unhex = hex, unhex

-- Secret text -> 32-byte master key. Salted with the guild name only (not the realm: connected realms mean
-- guildmates can report different realm names). Surrounding spaces are ignored so a pasted secret still matches.
function Crypto.DeriveMaster(secretText, guildName)
    local s = tostring(secretText or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return Crypto.PBKDF2(s, "SawIt guild secret v1|" .. tostring(guildName), Crypto.KDF_ITER)
end

-- Short code guildmates compare to see they entered the same secret. From its own HMAC label, so it tells an
-- observer nothing about the keys.
function Crypto.CheckCode(master)
    local h = hex(Crypto.HMAC(master, "SawIt check"):sub(1, 3)):upper()
    return h:sub(1, 3) .. "-" .. h:sub(4, 6)
end

function Crypto.NewContext(master)
    return { enc = hmacKey(Crypto.HMAC(master, "SawIt enc")), mac = hmacKey(Crypto.HMAC(master, "SawIt mac")) }
end

---------------------------------------------------------------------------
-- entropy, nonces, generated secrets
---------------------------------------------------------------------------
local pool = ""
local counter = 0
local function clock() return (debugprofilestop and debugprofilestop() or 0) end

-- Mix timing noise into the pool (called on incoming messages and on key presses in the secret window).
function Crypto.AddEntropy(x)
    pool = Crypto.SHA256(pool .. tostring(x) .. "|" .. clock() .. "|" .. math.random())
end

function Crypto.Nonce(selfName)
    counter = counter + 1
    -- pool is binary: appended with .., since Lua 5.1's format("%s") stops at a zero byte
    return Crypto.SHA256(("%s|%d|%d|%.6f|%.17g|"):format(tostring(selfName), counter, time(), clock(), math.random()) .. pool):sub(1, NONCE)
end

-- 20 characters from a 32-letter alphabet (100 bits), grouped for reading out: "K7QWM-3PZXA-...".
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
local function keystream(ctx, nonce, n)
    local blocks = {}
    for i = 0, floor((n - 1) / 32) do blocks[#blocks + 1] = hmacWith(ctx.enc, nonce .. be32(i)) end
    return concat(blocks)
end

local function tagOf(ctx, kind, name, nonce, ct)
    return hmacWith(ctx.mac, kind .. char(#name % 256) .. name .. nonce .. ct):sub(1, TAG)
end

-- name: sender without realm ("Marcus", not "Marcus-Realm").
function Crypto.Seal(ctx, kind, name, plaintext, nonce)
    local ct = #plaintext > 0 and xorStr(plaintext, keystream(ctx, nonce, #plaintext)) or ""
    return nonce .. ct .. tagOf(ctx, kind, name, nonce, ct)
end

-- Returns the plaintext, or nil when the blob was not sealed with this key, kind and sender.
function Crypto.Open(ctx, kind, name, blob)
    if type(blob) ~= "string" or #blob < NONCE + TAG then return nil end
    local nonce, ct, tag = blob:sub(1, NONCE), blob:sub(NONCE + 1, -TAG - 1), blob:sub(-TAG)
    if tagOf(ctx, kind, name, nonce, ct) ~= tag then return nil end
    if #ct == 0 then return "" end
    return xorStr(ct, keystream(ctx, nonce, #ct))
end
