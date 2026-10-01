-- Offline test of POI.lua (records, permissions, sync) and Positions packet format.
-- Run from the project root:   lua5.1 tests/test_poi.lua   (from the SawIt folder)
-- Two simulated clients exchange messages through a fake Comm; no WoW API is involved beyond small stubs.
local now = 1800000000
time = function() return now end
GetTime = function() return now end
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function runTimers() local t = timers; timers = {}; for _, f in ipairs(t) do f() end end
C_Map = { GetMapInfo = function(id) return { name = "Map" .. id } end }

local function deepcopy(v) if type(v) ~= "table" then return v end local t = {} for k, x in pairs(v) do t[k] = deepcopy(x) end return t end

local clients = {}
local function newClient(name, rank)
    local c = { name = name, store = { pois = {} }, handlers = {}, msgs = {} }
    local GA = { playerName = name, roster = {}, rosterReady = true, isSecret = function() return false end }
    GA.db = { profile = { poi = { officerRankIndex = 1 } } }
    function GA:Normalize(n) return n end
    function GA:IsOfficer(n) local r = self.roster[n]; return r ~= nil and r.rank <= 1 end
    function GA:GuildStore() return c.store end
    function GA:Debug() end
    function GA:Print(...) end
    function GA:GetGuildKey() return "G-R" end
    function GA:InGuild() return true end
    function GA:NewModule() local m = {}; m.SendMessage = function() end; m.RegisterMessage = function() end; m.Print = function() end; m.RegisterEvent = function() end; m.UnregisterEvent = function() end; return m end
    GA.Comm = {
        RegisterHandler = function(_, t, fn) c.handlers[t] = fn end,
        Send = function(_, t, payload, chan, target)
            for _, o in pairs(clients) do
                if o ~= c and (chan == "GUILD" or target == o.name) then
                    o.inbox[#o.inbox + 1] = { c.name, t, deepcopy(payload) }
                end
            end
        end,
        stats = {},
    }
    c.inbox, c.GA = {}, GA
    local ns = { addon = GA }
    local chunk = assert(loadfile("Modules/POI.lua"))
    chunk("GuildAtlas", ns)
    c.poi = GA.POI
    GA.POI.RegisterChatCommand = function() end
    GA.POI:OnEnable()
    clients[name] = c
    return c
end
local function pump()
    for _ = 1, 10 do
        runTimers()
        for _, c in pairs(clients) do
            local box = c.inbox; c.inbox = {}
            for _, m in ipairs(box) do c.handlers[m[2]](m[1], m[3], "x") end
        end
    end
end
local function roster(rs) for _, c in pairs(clients) do c.GA.roster = rs end end

local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1; print("FAIL " .. msg) end end

roster({})
local A, B, C, O = newClient("Alice"), newClient("Bob"), newClient("Cara"), newClient("Olga")
roster({ Alice = { rank = 5 }, Bob = { rank = 5 }, Cara = { rank = 5 }, Olga = { rank = 1 } })
for _, c in pairs(clients) do c.poi.syncUntil = nil end

-- live update
local id = A.poi:Create("Elite boar, spawns every 10 min", "rare", 1429, 0.4521, 0.6033)
check(id, "Alice creates a note")
pump()
check(B.poi:Get(id) and B.poi:Get(id).text:find("Elite"), "Bob receives live update")
check(B.poi:Get(id).x == 0.4521 and B.poi:Get(id).y == 0.6033, "coordinates survive quantisation")

-- permissions
local ok, why = B.poi:Edit(id, { text = "hijack" })
check(not ok and why == "not-allowed", "Bob (non-officer) cannot edit Alice's note: " .. tostring(why))
ok = O.poi:Edit(id, { text = "moderated text" })
pump()
check(ok and A.poi:Get(id).text == "moderated text", "officer Olga can edit, Alice sees it")
ok = A.poi:Edit(id, { cat = "grind" })
pump()
check(ok and O.poi:Get(id).cat == "grind", "author can edit own note afterwards (rev increments past officer's)")

-- forged live message: Mallory claims to be Alice
local forged = deepcopy(A.poi._pack(A.poi:Get(id)))
forged[2] = forged[2] + 100; forged[8] = "forged"
check(not B.poi:Apply(forged, "Bob", true), "live update whose updatedBy != sender is rejected")
forged[4] = "Bob"  -- Bob claims to be updatedBy, but author is Alice and Bob isn't an officer
check(not B.poi:Apply(forged, "Bob", true), "non-author non-officer rewrite rejected")

-- validation
local bad = deepcopy(A.poi._pack(A.poi:Get(id))); bad[2] = now + 10 * 86400
check(not B.poi:Apply(bad, "Alice", true), "rev far in the future rejected")
bad = deepcopy(A.poi._pack(A.poi:Get(id))); bad[6] = 99999; bad[2] = bad[2] + 1
check(not B.poi:Apply(bad, "Alice", true), "out-of-range x rejected")
bad = deepcopy(A.poi._pack(A.poi:Get(id))); bad[2] = bad[2] + 1; bad[8] = "|cffff0000red|r\nline" .. ("z"):rep(300)
check(B.poi:Apply(bad, "Alice", true) and #B.poi:Get(id).text <= 120 and not B.poi:Get(id).text:find("[|%c]"), "text sanitised and truncated")

-- titles
local P = A.poi
local tid = P:Create("near the cave", "rare", 1429, 0.3, 0.3, "Mother Fang")
pump()
check(B.poi:Get(tid) and B.poi:Get(tid).title == "Mother Fang" and B.poi:Get(tid).text == "near the cave", "title syncs to peers")
local legacy = deepcopy(P._pack(P:Get(tid))); legacy[11] = nil; legacy[2] = legacy[2] + 1
check(B.poi:Apply(legacy, "Alice", true) and B.poi:Get(tid).title == "", "10-field record from an old client accepted with empty title")
check(P.DisplayTitle({ title = "", text = "old note text" }) == "old note text", "untitled note displays its text as title")
check(#P.DisplayTitle({ title = "", text = ("x"):rep(100) }) == P.MAX_TITLE, "fallback title is capped")
local messy = deepcopy(P._pack(P:Get(tid))); messy[2] = messy[2] + 2; messy[11] = "[a|b]\n" .. ("t"):rep(100)
check(B.poi:Apply(messy, "Alice", true) and #B.poi:Get(tid).title <= P.MAX_TITLE and not B.poi:Get(tid).title:find("[|%[%]%c]"), "title sanitised and truncated")
local tonly = P:Create("", "other", 1429, 0.2, 0.2, "title only")
check(tonly ~= nil, "a note may have a title and no details")
check(P:Create("", "other", 1429, 0.2, 0.2, "  ") == nil, "a note needs a title or details")
local t1, d1 = P._splitTitle("Mother Fang; near the cave")
local t2, d2 = P._splitTitle("just a title")
check(t1 == "Mother Fang" and d1 == "near the cave" and t2 == "just a title" and d2 == nil, "'title; details' split for /sawit")
P.SlashCommand = P.SlashCommand or function() end
P:SlashCommand("edit " .. tid .. " Mother Fang the Elder")
check(P:Get(tid).title == "Mother Fang the Elder" and P:Get(tid).text == "near the cave", "/sawit edit <id> <title> keeps the details")
P:SlashCommand("edit " .. tid .. " rare Mother Fang; by the lake")
check(P:Get(tid).title == "Mother Fang" and P:Get(tid).text == "by the lake", "/sawit edit <id> [cat] <title>; <details> sets both")
check(pcall(P.SlashCommand, P, "edit") and pcall(P.SlashCommand, P, "edit   "), "/sawit edit without arguments doesn't error")
check(P.Details({ title = "T", text = "d" }) == "d" and P.Details({ title = "", text = "short" }) == ""
    and P.Details({ title = "", text = ("x"):rep(60) }) == ("x"):rep(60), "Details: text under a title; untitled only when cut")
check(not B.poi:Apply(42, "Alice", true) and not B.poi:Apply("junk", "Alice", false), "non-table payloads are rejected, not thrown")
local good = deepcopy(P._pack(P:Get(tid))); good[2] = good[2] + 10; good[11] = "after junk"
B.poi:OnRecords("Cara", { 7, "junk", good })
check(B.poi:Get(tid).title == "after junk", "a junk entry in a sync batch doesn't stop the valid ones")
P:OnRecords("Cara", { good })   -- Alice gets the same revision, so her delete below is newer everywhere
now = now + 5
P:Remove(tid); P:Remove(tonly)
pump()
check(B.poi:Get(tid).deleted and B.poi:Get(tid).title == "", "tombstone clears the title")

-- delete + tombstone
now = now + 5
ok = A.poi:Remove(id)
pump()
check(B.poi:Get(id) and B.poi:Get(id).deleted, "deletion arrives as tombstone on Bob")
local live = 0; for _ in B.poi:Iterate() do live = live + 1 end
check(live == 0, "tombstoned note not iterated")

-- offline sync: Cara was offline and has nothing; Bob has extra that Cara lacks and vice versa
local n1 = A.poi:Create("Hidden quest NPC", "quest", 1429, 0.1, 0.2)
-- Cara misses it: drop inbox
C.inbox = {}
now = now + 1
local n2 = C.poi:Create("Cara's grind spot", "grind", 1411, 0.5, 0.5)
B.inbox, A.inbox = {}, {}  -- Bob and Alice never saw Cara's note
local c1, s1 = A.poi:Checksum(); local c3, s3 = C.poi:Checksum()
check(s1 ~= s3, "checksums differ before sync")
for _, c in pairs(clients) do c.poi.syncUntil = nil end
C.poi:SendHello()
pump()
B.poi:SendHello()   -- Bob also missed Alice's note; he learns it at his own login hello
pump()
check(C.poi:Get(n1) ~= nil, "Cara pulled Alice's missed note via digest/request")
check(A.poi:Get(n2) ~= nil and B.poi:Get(n2) ~= nil, "Cara's note was pushed to peers via offer")
local _, sa = A.poi:Checksum(); local _, sb = B.poi:Checksum(); local _, sc = C.poi:Checksum(); local _, so = O.poi:Checksum()
check(sa == sb and sb == sc and sc == so, "all four clients converge to the same checksum")

-- Positions packet format
local pos = assert(loadfile("Modules/Positions.lua"))
local PGA = { NewModule = function() return {} end }
pos("GuildAtlas", { addon = PGA })
local Pos = PGA.Positions
local pkt = Pos.Encode(1429, 0.4521, 0.6033)
check(pkt == "10142945216033" and #pkt == 14, "position packet is 14 bytes: " .. pkt)
local m, x, y = Pos.Decode(pkt)
check(m == 1429 and x == 0.4521 and y == 0.6033, "position packet round-trips")
check(Pos.Decode("1garbage") == nil and Pos.Decode("0") == "leave" and Pos.Decode("2anything") == nil, "garbage/leave/reserved formats handled")

print(fails == 0 and "\nALL PASSED" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
