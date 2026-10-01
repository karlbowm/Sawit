-- Offline test of Core/Crypto.lua against reference values from Python's hashlib/hmac (generated, not typed in).
-- Run from the SawIt folder:   lua5.1 tests/test_crypto.lua
-- Loads LibStub and LibHash-1.0 as the game does (embeds.xml), then Crypto.lua.
time = os.time
assert(loadfile("Libs/Ace3/LibStub/LibStub.lua"))()
assert(loadfile("Libs/LibHash-1.0/LibHash-1.0.lua"))()
local ns = { addon = {} }
assert(loadfile("Core/Crypto.lua"))("SawIt", ns)
local C = ns.addon.Crypto

local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end end
local hex, unhex = C.hex, C.unhex

local V = {}   -- python3: hashlib.sha256 / hmac.new(..., hashlib.sha256) / hashlib.pbkdf2_hmac
V["e"] = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
V["abc"] = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
V["56"] = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
V["1000"] = "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
V["hmac_short"] = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
V["hmac_long"] = "bd56a1782c2830e8abc6ed866a57a1230661e650b84c62f7ee3accc5fa5af491"
V["pbkdf2"] = "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
V["master"] = "a57ff13ec56233ce85de0f2f3b44b5db64533a2a3c2dacbc76d0cc0420e0c691"
V["check"] = "B83-CC8"
V["blob"] = "0102030405060708090a0b0cf8f66831683dff6f703417517d4fa29e8d02c742f5ccfbdc485e9c22f0d38df45b4e6a7decc402ef2b8a6ebe609fce164f5e562f5bf35f2ff98bffcbf9287a91f8dbf1716bc1"

local function run()
    check(hex(C.SHA256("")) == V.e, "SHA-256 of empty string")
    check(hex(C.SHA256("abc")) == V.abc, "SHA-256 of 'abc'")
    check(hex(C.SHA256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) == V["56"], "SHA-256 of the 56-byte vector (two blocks)")
    check(hex(C.SHA256(("a"):rep(1000))) == V["1000"], "SHA-256 of 1000 bytes")
    check(hex(C.HMAC("key", "The quick brown fox jumps over the lazy dog")) == V.hmac_short, "HMAC-SHA256, short key")
    check(hex(C.HMAC(("k"):rep(100), "msg")) == V.hmac_long, "HMAC-SHA256, key longer than a block")
    check(hex(C.PBKDF2("password", "salt", 2)) == V.pbkdf2, "PBKDF2-HMAC-SHA256, 2 iterations")

    local iter = C.KDF_ITER
    C.KDF_ITER = 2
    local master = C.DeriveMaster("  My Secret \n", "AZB")
    C.KDF_ITER = iter
    check(hex(master) == V.master, "master key from secret + guild name (surrounding spaces ignored)")
    check(C.CheckCode(master) == V.check, "check code " .. C.CheckCode(master))

    local ctx = C.NewContext(master)
    local pt = "hello guild, this is a message longer than thirty-two bytes!"
    local nonce = ""
    for i = 1, 12 do nonce = nonce .. string.char(i) end
    local blob = C.Seal(ctx, "D", "Marcus", pt, nonce)
    check(hex(blob) == V.blob, "sealed blob matches the Python reference")
    check(C.Open(ctx, "D", "Marcus", blob) == pt, "opens with the same key, kind and sender")
    check(C.Open(ctx, "D", "Mallory", blob) == nil, "rejected when re-sent by another player")
    check(C.Open(ctx, "P", "Marcus", blob) == nil, "rejected on the other channel")
    for _, pos in ipairs({ 1, 13, 30, #blob }) do
        local b = blob:sub(1, pos - 1) .. string.char((blob:byte(pos) + 1) % 256) .. blob:sub(pos + 1)
        check(C.Open(ctx, "D", "Marcus", b) == nil, "one changed byte at " .. pos .. " is rejected")
    end
    check(C.Open(ctx, "D", "Marcus", blob:sub(1, -2)) == nil and C.Open(ctx, "D", "Marcus", "short") == nil, "truncated blobs rejected")
    C.KDF_ITER = 2
    local other = C.NewContext(C.DeriveMaster("Other secret", "AZB"))
    local sameSecretOtherGuild = C.NewContext(C.DeriveMaster("My Secret", "Other Guild"))
    C.KDF_ITER = iter
    check(C.Open(other, "D", "Marcus", blob) == nil, "wrong secret rejected")
    check(C.Open(sameSecretOtherGuild, "D", "Marcus", blob) == nil, "same secret in another guild gives another key")
    check(C.Open(ctx, "D", "Marcus", C.Seal(ctx, "D", "Marcus", "", nonce)) == "", "empty plaintext round-trips")

    local n1, n2 = C.Nonce("Marcus"), C.Nonce("Marcus")
    check(#n1 == 12 and n1 ~= n2 and C.Nonce("Bob") ~= n1, "nonces are 12 bytes and differ per call and per player")
    local s1, s2 = C.RandomSecret(), C.RandomSecret()
    check(s1:match("^[A-Z2-9]+%-[A-Z2-9]+%-[A-Z2-9]+%-[A-Z2-9]+$") and #s1 == 23 and s1 ~= s2, "generated secret looks like " .. s1)
end

run()

print(fails == 0 and "\nALL PASSED" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
