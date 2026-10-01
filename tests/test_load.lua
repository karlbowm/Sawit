-- Load smoke test: loads every file in SawIt.toc order (expanding embeds.xml and the Ace .xml includes)
-- against a stubbed WoW API, then fires ADDON_LOADED / PLAYER_LOGIN / PLAYER_ENTERING_WORLD.
-- Catches load-order and nil-index errors like "attempt to index local 'LDB' (a nil value)".
-- It does NOT prove anything renders or that the real client API matches the stubs.
-- Run from the SawIt folder:   lua5.1 tests/test_load.lua
local ADDON = "SawIt"

-- universal stub: any field is a callable that returns the stub; used for unknown APIs and frames
local stub
stub = setmetatable({}, { __index = function() return stub end, __call = function() return stub end })

-- frames that remember their scripts and events so we can fire events at them
local frames = {}
local Frame = {}
Frame.__index = function(t, k) return Frame[k] or function() return stub end end
function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:HookScript(name, fn) self.scripts[name] = fn end
function Frame:RegisterEvent(e) self.events[e] = true end
function Frame:UnregisterEvent(e) self.events[e] = nil end
function Frame:IsEventRegistered(e) return self.events[e] end
function Frame:UnregisterAllEvents() self.events = {} end
function Frame:GetName() return self.name end
function Frame:Show() self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end
function Frame:Hide() local was = self.shown; self.shown = false; if was and self.scripts.OnHide then self.scripts.OnHide(self) end end
function Frame:IsShown() return self.shown == true end
function Frame:IsVisible() return self.shown == true end
function Frame:SetText(t) self.text = t end
function Frame:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
function Frame:GetText() return self.text end
function Frame:Click(button) if self.scripts.OnClick then self.scripts.OnClick(self, button or "LeftButton") end end
function Frame:GetWidth() return 100 end
function Frame:GetHeight() return 100 end
function Frame:GetEffectiveScale() return 1 end
function Frame:GetFrameLevel() return 1 end
function Frame:GetNumPoints() return 0 end
function Frame:GetZoom() return 0 end
function Frame:GetScale() return 1 end
function Frame:GetParent() return self.parent end
function Frame:CreateTexture() return CreateFrame("Texture", nil, self) end
function Frame:CreateFontString() return CreateFrame("FontString", nil, self) end
function CreateFrame(_, name, parent)
    local f = setmetatable({ scripts = {}, events = {}, name = name, parent = parent }, Frame)
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
local shiftDown = false
IsShiftKeyDown = function() return shiftDown end
IsControlKeyDown = function() return false end
UISpecialFrames = {}
UIParent, Minimap, WorldMapFrame = CreateFrame("Frame"), CreateFrame("Frame"), CreateFrame("Frame")
GameTooltip = CreateFrame("GameTooltip")
WorldMapFrame.pinPools = {}
function WorldMapFrame:AddDataProvider(p) p.GetMap = function() return WorldMapFrame end end   -- as MapCanvasMixin does
WorldMapFrame.clickHandlers = {}
function WorldMapFrame:AddCanvasClickHandler(fn, priority) self.clickHandlers[#self.clickHandlers + 1] = { fn = fn, priority = priority } end
function WorldMapFrame:GetMapID() return self.mapID end

-- the WoW API the code actually needs real values from
local now = 1000
GetTime = function() return now end
time = os.time
date = os.date
debugprofilestop = function() return now * 1000 end
GetBuildInfo = function() return "1.16.0", "1", "Sep 1 2026", 16001 end
GetLocale = function() return "enUS" end
IsLoggedIn = function() return false end
InCombatLockdown = function() return false end
UnitName = function() return "Marcus" end
GetRealmName = function() return "Realm" end
UnitFactionGroup = function() return "Alliance" end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitRace = function() return "Human", "Human", 1 end
UnitLevel = function() return 60 end
UnitAffectingCombat = function() return false end
IsInGuild = function() return false end
IsInInstance = function() return false, "none" end
GetGuildInfo = function() return nil end
GetNumGuildMembers = function() return 0 end
GetCurrentRegion = function() return 3 end
GetFramerate = function() return 60 end
GetCVar = function() return "0" end
Ambiguate = function(n) return n end
-- WoW's xpcall forwards extra arguments to the function (Lua 5.2 style); plain Lua 5.1's does not
local xpcall51 = xpcall
xpcall = function(f, h, ...)
    local n, args = select("#", ...), { ... }
    return xpcall51(function() return f(unpack(args, 1, n)) end, h)
end
local caught = {}   -- errors the libraries pass to the error handler (AceAddon swallows them otherwise)
geterrorhandler = function() return function(e) caught[#caught + 1] = tostring(e); print("ERROR " .. tostring(e)) end end
securecallfunction = function(f, ...) return f(...) end
hooksecurefunc = function() end
issecurevariable = function() return true end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove, strsub, strlen, format, strmatch = table.insert, table.remove, string.sub, string.len, string.format, string.match
strsplit = function(sep, s) local r = {} for p in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do r[#r + 1] = p end return unpack(r) end
strjoin = function(sep, ...) return table.concat({ ... }, sep) end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
string.trim = strtrim
max, min, floor, ceil, abs, mod = math.max, math.min, math.floor, math.ceil, math.abs, math.fmod
bit = { band = function(a, b) local r, p = 0, 1 while a > 0 and b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + p end a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2 end return r end }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("[chat] " .. tostring(m)) end }
SlashCmdList, hash_SlashCmdList = {}, {}
RAID_CLASS_COLORS = { WARRIOR = { r = 1, g = 1, b = 1 } }
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE, WOW_PROJECT_CLASSIC = 2, 1, 2
C_Timer = { After = function() end, NewTicker = function() return stub end, NewTimer = function() return stub end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, IsAddonMessagePrefixRegistered = function() return true end,
    SendAddonMessage = function() return true end }
C_Map = { GetBestMapForUnit = function() return nil end, GetMapInfo = function() return nil end,
    GetMapChildrenInfo = function() return {} end, GetMapWorldSize = function() return 0, 0 end,
    GetWorldPosFromMapPos = function() return nil end, GetMapGroupID = function() return nil end,
    GetMapArtID = function() return 1 end, GetPlayerMapPosition = function() return nil end }
C_AddOns = { IsAddOnLoaded = function() return false end }
Enum = setmetatable({ UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 } },
    { __index = function() return stub end })
CreateVector2D = function(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
UiMapPoint = { CreateFromCoordinates = function() return stub end }
Mixin = function(o, ...) for _, m in ipairs({ ... }) do for k, v in pairs(m) do o[k] = v end end return o end
CreateFromMixins = function(...) return Mixin({}, ...) end
UnitPosition = function() return nil end
GetPlayerFacing = function() return 0 end
GetMinimapShape = function() return "ROUND" end
MapCanvasDataProviderMixin, MapCanvasPinMixin = {}, {}
CreateFramePool = function() return {} end
-- unknown globals stay nil, as in the real client when an API is missing

-- load list: toc -> embeds.xml -> Ace .xml includes
local function readLines(p) local t = {} for l in io.lines(p) do t[#t + 1] = l end return t end
local files = {}
local function addXml(path)
    local dir = path:match("^(.*)[\\/]") or "."
    for _, l in ipairs(readLines(path)) do
        local kind, f = l:match("<(%a+) file=\"([^\"]+)\"")
        if kind then
            local full = dir .. "/" .. f:gsub("\\", "/")
            if kind == "Include" then addXml(full) else files[#files + 1] = full end
        end
    end
end
for _, l in ipairs(readLines(ADDON .. ".toc")) do
    l = l:gsub("\r", "")
    if l ~= "" and not l:find("^#") then
        local f = l:gsub("\\", "/")
        if f:find("%.xml$") then addXml(f) else files[#files + 1] = f end
    end
end

local ns = {}
for _, f in ipairs(files) do
    f = f:gsub("^%./", "")
    local chunk = assert(loadfile(f))
    local ok, err = pcall(chunk, ADDON, ns)
    if not ok then print("FAIL loading " .. f .. ": " .. tostring(err)); os.exit(1) end
end
print(("ok   loaded %d files"):format(#files))

local function fire(event, ...)
    for _, f in ipairs(frames) do
        local h = f.scripts.OnEvent
        if h and (f.events[event] or f.events.ALL) then
            local ok, err = pcall(h, f, event, ...)
            if not ok then print("FAIL " .. event .. ": " .. tostring(err)); os.exit(1) end
        end
    end
end
fire("ADDON_LOADED", ADDON)
IsLoggedIn = function() return true end
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD", true, false)
print("ok   ADDON_LOADED, PLAYER_LOGIN, PLAYER_ENTERING_WORLD fired without errors")

local GA = LibStub("AceAddon-3.0"):GetAddon(ADDON)
-- The checks below expect normal (non-test) mode; the test-mode section turns the flag on itself.
if GA.TEST_MODE then print("note: GA.TEST_MODE is ON in Core/Core.lua (fine for testing in game; set false before release)") end
GA.TEST_MODE = false
local fails = 0
local function check(c, m) if c then print("ok   " .. m) else fails = fails + 1; print("FAIL " .. m) end end
check(#caught == 0, "no errors reported to the error handler during load and login")
check(GA == ns.addon and GA == SawIt, "one addon object, exposed as ns.addon and SawIt")
check(GA.db and GA.db.profile.minimap and GA.db.profile.positions.share == false, "one AceDB with merged defaults (sharing off)")
for _, m in ipairs({ "Comm", "POI", "POIMap", "Positions", "MinimapButton" }) do
    local mod = GA:GetModule(m, true)
    check(mod and mod:IsEnabled(), "module " .. m .. " enabled")
end
check(LibStub("LibDBIcon-1.0"):GetMinimapButton("SawIt") ~= nil, "minimap button registered")
local ldb = LibStub("LibDataBroker-1.1"):GetDataObjectByName("SawIt")
check(pcall(ldb.OnTooltipShow, GameTooltip), "tooltip builds")
shiftDown = true
check(pcall(ldb.OnClick, nil, "LeftButton"), "shift-left-click (status) runs")
shiftDown = false
check(pcall(ldb.OnClick, nil, "LeftButton") and not (GA.NoteDialog.GetFrame() and GA.NoteDialog.GetFrame():IsShown()),
    "left-click without a guild does not open the note window")
local ringOwner = GA:GetModule("MinimapButton")
local function ringColor()
    local r = ringOwner.ring
    if not r or not r:IsShown() then return "none" end
    local c = rawget(r, "color")
    if c[1] < 0.5 and c[2] > 0.9 then return "green" end
    if c[1] > 0.9 and c[2] > 0.5 and c[2] < 0.8 then return "orange" end
    return "other"
end
check(ringOwner.ring and ringColor() == "none", "sharing off: no ring on the minimap button")
check(pcall(ldb.OnClick, nil, "RightButton") and GA.db.profile.positions.share == true, "right-click turns sharing on")
check(ringColor() == "orange", "sharing on without a guild: orange ring (nothing sent)")
check(pcall(ldb.OnClick, nil, "RightButton") and GA.db.profile.positions.share == false, "right-click turns sharing off")
check(ringColor() == "none", "sharing off again: ring hidden")

-- note window, in a guild with a position
IsInGuild = function() return true end
GetGuildInfo = function() return "AZB" end
C_Map.GetBestMapForUnit = function() return 1429 end
C_Map.GetPlayerMapPosition = function() return CreateVector2D(0.4231, 0.6512) end
local MAPS = { [1429] = { name = "Elwynn Forest", mapType = 3 }, [1415] = { name = "Eastern Kingdoms", mapType = 2 } }
C_Map.GetMapInfo = function(id) return MAPS[id] or { name = "Map" .. id, mapType = 3 } end
GA.Positions:SetSharing(true)

-- guild secret: without it nothing is sent or read
local captured = {}
local realSendComm = GA.Comm.SendCommMessage
GA.Comm.SendCommMessage = function(_, prefix, text, chan, target) captured[#captured + 1] = { prefix = prefix, text = text, chan = chan } end
check(ringColor() == "orange" and not GA:CanUseNetwork() and GA:NetworkBlockReason():find("no guild secret", 1, true),
    "in a guild without a secret: orange ring, nothing can be sent")
check(GA.Comm:Send("H", { 0, 0 }) == false and GA.Comm:SendRaw("0") == false and #captured == 0, "no secret: Send and SendRaw send nothing")
check(pcall(ldb.OnTooltipShow, GameTooltip), "minimap tooltip builds without a secret")
GA.Crypto.KDF_ITER = 2   -- the real 1000 rounds are slow in plain Lua
GA:SlashCommand("secret")
local sd = GA.SecretDialog.GetFrame()
check(sd and sd:IsShown() and sd.status:GetText():find("not set", 1, true), "/sawit secret opens the window (not set)")
sd.edit:SetText("short")
sd.saveButton:Click()
check(sd:IsShown() and sd.error:GetText():find("too short", 1, true) and not GA:NetContext(), "a too-short secret is refused")
sd.generateButton:Click()
local generated = sd.edit:GetText()
check(generated:match("^%w+%-%w+%-%w+%-%w+$"), "Generate fills in a random secret: " .. generated)
sd.edit:SetText("  correct horse battery staple  ")
sd.saveButton:Click()
check(not sd:IsShown() and GA:NetContext() ~= nil and GA:GuildSecretCheck():match("^%x%x%x%-%x%x%x$"), "Save sets the secret and a check code")
check(GA.db.global.netKeys["AZB-Realm"] and not tostring(GA.db.global.netKeys["AZB-Realm"].key):find("horse"), "stored per guild as the derived key, not the text")
check(ringColor() == "green", "sharing on in a guild with a secret: green ring")

-- round trip: a message sealed by Bob is read; plaintext, tampering, a wrong secret and a re-sender are not
local got
GA.Comm:RegisterHandler("T", function(sender, payload) got = { sender, payload } end)
local function sealAs(name, fn)
    local me = GA.playerName
    GA.playerName = name
    captured = {}
    fn()
    GA.playerName = me
    return captured[1]
end
local msg = sealAs("Bob", function() GA.Comm:Send("T", { "hello", 42 }) end)
check(msg and msg.prefix == "GAtlasD" and msg.text:sub(1, 1) == "2" and not msg.text:find("hello", 1, true), "data message goes out sealed, text not readable")
GA.Comm:OnData("GAtlasD", msg.text, "GUILD", "Bob-Realm")
check(got and got[1] == "Bob-Realm" and got[2][1] == "hello" and got[2][2] == 42, "guildmate with the same secret: message read")
local st = GA.Comm.stats
local before = { st.plaintext, st.unreadable }
got = nil
GA.Comm:OnData("GAtlasD", "0" .. LibStub("AceSerializer-3.0"):Serialize(1, "T", { "plain" }), "GUILD", "Eve")
check(got == nil and st.plaintext == before[1] + 1, "unencrypted message (old client / no secret) ignored")
GA.Comm:OnData("GAtlasD", msg.text, "GUILD", "Carl")
check(got == nil and st.unreadable == before[2] + 1, "Bob's message re-sent by Carl rejected")
local flipped = msg.text:sub(1, 10) .. (msg.text:sub(11, 11) == "A" and "B" or "A") .. msg.text:sub(12)
GA.Comm:OnData("GAtlasD", flipped, "GUILD", "Bob")
check(got == nil and st.unreadable == before[2] + 2, "tampered message rejected")
local key = GA.db.global.netKeys["AZB-Realm"]
GA:SetGuildSecret("a different secret")
GA.Comm:OnData("GAtlasD", msg.text, "GUILD", "Bob")
check(got == nil and st.unreadable == before[2] + 3, "wrong secret: message unreadable")
GA.db.global.netKeys["AZB-Realm"] = key
local pos = sealAs("Dora", function() GA.Comm:SendRaw(GA.Positions.Encode(1429, 0.5, 0.5)) end)
check(pos and pos.prefix == "GAtlasP" and pos.text:sub(1, 1) == "E" and #pos.text < 255, "position packet goes out sealed (" .. #pos.text .. " bytes)")
GA.Comm:OnRaw("GAtlasP", pos.text, "GUILD", "Dora")
check(GA.Positions.players.Dora and GA.Positions.players.Dora.map == 1429, "sealed position from a guildmate shows up")
GA.Comm:OnRaw("GAtlasP", "10142945216033", "GUILD", "Eve")
check(GA.Positions.players.Eve == nil, "unencrypted position packet ignored")
GA.Positions:OnPacket("Dora", "0")
GA.Comm.SendCommMessage = realSendComm
GA.TEST_MODE = true; ringOwner:UpdateRing()
check(ringColor() == "orange", "sharing on in test mode: orange ring (local only)")
GA.TEST_MODE = false; GA.Positions:SetSharing(false)
check(ringColor() == "none", "sharing off: ring hidden")
check(pcall(ldb.OnClick, nil, "LeftButton"), "left-click in a guild runs")
local dlg = GA.NoteDialog.GetFrame()
check(dlg and dlg:IsShown(), "note window opens")
check(dlg and dlg.where:GetText() == "Elwynn Forest  42.3, 65.1", "window shows the captured position")
check(dlg and dlg.catButton:GetText():find("Other", 1, true), "default category is Other")
dlg.catButton:Click()
check(dlg.catList:IsShown(), "category button opens the list")
-- category buttons are created in CATEGORY_ORDER; find "Rare spawn" by its label
local rareButton
for _, f in ipairs(frames) do if f.parent == dlg.catList then
    for _, c in ipairs(frames) do
        local t = rawget(c, "text")
        if c.parent == f and type(t) == "string" and t:find("Rare spawn", 1, true) then rareButton = f end
    end
end end
rareButton:Click()
check(not dlg.catList:IsShown() and dlg.catButton:GetText():find("Rare spawn", 1, true), "picking a category closes the list and shows it")
dlg.addButton:Click()
check(dlg:IsShown(), "empty text is refused and the window stays open")
check(dlg.title and dlg.title:GetText() == "", "window has an empty Title field")
dlg.title:SetText("[Mother] Fang|")
dlg.edit:SetText("spawns  | at dusk")
dlg.addButton:Click()
check(not dlg:IsShown(), "Add closes the window")
local notes = {}
for _, rec in GA.POI:Iterate() do notes[#notes + 1] = rec end
local r = notes[1]
check(#notes == 1 and r.cat == "rare" and r.mapID == 1429 and r.x == 0.4231 and r.y == 0.6512 and r.author == "Marcus",
    "note saved with category, map, position and author")
check(r and r.title == "Mother Fang" and r.text == "spawns at dusk", "title and details saved and sanitised ('|', '[', ']' removed)")
check(pcall(ldb.OnClick, nil, "LeftButton") and dlg.catButton:GetText():find("Rare spawn", 1, true) and dlg.edit:GetText() == "" and dlg.title:GetText() == "",
    "reopening keeps the last category and clears the text")
dlg.edit.scripts.OnEscapePressed(dlg.edit)
check(not dlg:IsShown(), "Escape in the text field closes the window")

-- map drawing. The real HBD-Pins needs map geometry the stubs don't have, so record the calls instead.
local drawn = { world = {}, mini = {} }
GA.HBDPins = {
    AddWorldMapIconMap = function(_, ref, icon, map, x, y) drawn.world[icon] = { ref = ref, map = map, x = x, y = y }; return true end,
    AddMinimapIconMap = function(_, ref, icon, map, x, y) drawn.mini[icon] = { ref = ref, map = map, x = x, y = y }; return true end,
    RemoveWorldMapIcon = function(_, _, icon) drawn.world[icon] = nil end,
    RemoveMinimapIcon = function(_, _, icon) drawn.mini[icon] = nil end,
    RemoveAllWorldMapIcons = function(_, ref) for k, v in pairs(drawn.world) do if v.ref == ref then drawn.world[k] = nil end end end,
    RemoveAllMinimapIcons = function(_, ref) for k, v in pairs(drawn.mini) do if v.ref == ref then drawn.mini[k] = nil end end end,
}
local function count(t, ref) local n = 0; for _, v in pairs(t) do if not ref or v.ref == ref then n = n + 1 end end; return n end
local NOTES = "SawItNotes"
local function onlyPin(t) for icon, v in pairs(t) do if v.ref == NOTES then return icon, v end end end

GA.POIMap:Redraw()   -- C_Timer.After is a no-op here, so call the coalesced redraw directly
local wIcon, w = onlyPin(drawn.world)
local mIcon = onlyPin(drawn.mini)
check(count(drawn.world, NOTES) == 1 and count(drawn.mini, NOTES) == 1, "one note -> one world-map pin and one minimap pin")
check(wIcon ~= mIcon, "world-map and minimap pins are separate frames")
check(w and w.map == 1429 and w.x == 0.4231 and w.y == 0.6512, "pin placed at the note's map and position")
check(wIcon and wIcon.recs and wIcon.recs[1].cat == "rare", "pin carries the note (rare)")
check(pcall(wIcon.scripts.OnEnter, wIcon), "pin tooltip builds")
local sent
C_ChatInfo.SendChatMessage = function(msg, chan) sent = { msg, chan } end
wIcon.scripts.OnClick(wIcon, "LeftButton")
local PIN_LINK = "|cffffff00|Hworldmap:1429:4231:6512|h[|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a Map Pin Location]|h|r"
check(sent and sent[2] == "GUILD" and sent[1] == "[Rare spawn: Mother Fang] " .. PIN_LINK .. " spawns at dusk",
    "clicking a pin shares '[Category: Title] <map pin link> details' to guild chat: " .. tostring(sent and sent[1]))
local inserted
sent = nil
ChatEdit_InsertLink = function(t) inserted = t; return true end
shiftDown = true
wIcon.scripts.OnClick(wIcon, "LeftButton")
shiftDown = false
check(inserted == "[Rare spawn: Mother Fang] " .. PIN_LINK and sent == nil, "shift-click puts the link in the chat box, sends nothing")
local opened
inserted = nil
ChatEdit_InsertLink = function() return false end   -- no chat box open
ChatFrame_OpenChat = function(t) opened = t end
shiftDown = true
wIcon.scripts.OnClick(wIcon, "LeftButton")
shiftDown = false
check(opened == "[Rare spawn: Mother Fang] " .. PIN_LINK, "shift-click with no chat box open opens one with the link")
ChatEdit_InsertLink, ChatFrame_OpenChat = nil, nil

-- Ctrl-click: TomTom waypoint if installed, else WoW's map pin
local tt
TomTom = { AddWaypoint = function(_, map, x, y, opts) tt = { map, x, y, opts.title } end }
IsControlKeyDown = function() return true end
wIcon.scripts.OnClick(wIcon, "LeftButton")
check(tt and tt[1] == 1429 and tt[2] == 0.4231 and tt[4] == "Mother Fang" and sent == nil, "ctrl-click with TomTom: TomTom waypoint")
TomTom = nil
local pinned
C_Map.SetUserWaypoint = function(point) pinned = point end
wIcon.scripts.OnClick(wIcon, "LeftButton")
check(pinned ~= nil and sent == nil, "ctrl-click without TomTom: WoW's map pin is placed")
C_Map.SetUserWaypoint = function() error("no pins on this map") end
check(pcall(wIcon.scripts.OnClick, wIcon, "LeftButton"), "a map that refuses pins doesn't raise an error")
C_Map.SetUserWaypoint, IsControlKeyDown = nil, function() return false end

-- second note at the same spot shares the pin
GA.POI:Create("second note", "quest", 1429, 0.4231, 0.6512)
GA.POIMap:Redraw()
wIcon = onlyPin(drawn.world)
check(count(drawn.world, NOTES) == 1 and #wIcon.recs == 2 and rawget(wIcon.count, "text") == 2, "two notes at one spot share a pin with a count")

check(GA:SlashCommand("filter rare") == nil and not GA.db.profile.poi.filters.rare, "/sawit filter rare hides rare (Core forwards to POI)")
GA.POIMap:Redraw()
wIcon = onlyPin(drawn.world)
check(count(drawn.world, NOTES) == 1 and #wIcon.recs == 1 and wIcon.recs[1].cat == "quest", "hidden category is left off the pin")
GA.POI:SlashCommand("filter quest")
GA.POIMap:Redraw()
check(count(drawn.world, NOTES) == 0, "all categories at a spot hidden -> no pin")
GA.POI:SlashCommand("filter rare"); GA.POI:SlashCommand("filter quest")
GA.POI:SlashCommand("minimap")
GA.POIMap:Redraw()
check(count(drawn.world, NOTES) == 1 and count(drawn.mini, NOTES) == 0, "/sawit minimap hides minimap pins only")
GA.POI:SlashCommand("minimap")

-- /sawit my: only your own notes
local printed = {}
local realAdd = DEFAULT_CHAT_FRAME.AddMessage
DEFAULT_CHAT_FRAME.AddMessage = function(_, m) printed[#printed + 1] = tostring(m) end
local function said(pat) for _, l in ipairs(printed) do if l:find(pat) then return true end end end
local other = GA.POI:Create("not mine", "other", 1429, 0.1, 0.1, "Bob's note")
GA.POI:Get(other).author = "Bob"   -- as if synced from Bob
GA:SlashCommand("my")
check(said("Mother Fang", 1, true) and not said("Bob's note") and said("2 note%(s%) by you"), "/sawit my lists only your notes")
printed = {}
GA:SlashCommand("list")
check(said("Bob's note") and said("3 note%(s%)"), "/sawit list lists everyone's notes")
local before = 0; for _ in GA.POI:Iterate() do before = before + 1 end
printed = {}
GA:SlashCommand("stauts")
local after = 0; for _ in GA.POI:Iterate() do after = after + 1 end
check(after == before and said("unknown command"), "a mistyped /sawit command does not become a note")
GA:SlashCommand("add quest Hidden Cave; behind the waterfall")
local added
for _, rec in GA.POI:Iterate() do if rec.title == "Hidden Cave" then added = rec end end
check(added and added.cat == "quest" and added.text == "behind the waterfall", "/sawit add [cat] title; details")
printed = {}
GA:SlashCommand("help")
check(said("/sawit my") and said("/sawit status"), "/sawit help lists note and core commands")
DEFAULT_CHAT_FRAME.AddMessage = realAdd
check(not GA.POI:Remove(other), "you cannot delete someone else's note")
GA.POI:Get(other).author = "Marcus"   -- hand it back so the test can clean up
check(GA.POI:Remove(other) and GA.POI:Remove(added.id), "you can delete your own notes")

-- guildmate dots use two frames too
GA.Positions:OnPacket("Bob", "10142945216033")
local pw, pm
for icon, v in pairs(drawn.world) do if v.ref ~= NOTES then pw = icon end end
for icon, v in pairs(drawn.mini) do if v.ref ~= NOTES then pm = icon end end
check(pw and pm and pw ~= pm, "guildmate dot: separate world-map and minimap frames")
GA.Positions:OnPacket("Bob", "0")
check(count(drawn.world) == count(drawn.world, NOTES) and count(drawn.mini) == count(drawn.mini, NOTES), "stop packet removes both dot frames")

-- Shift+right-click on the world map opens the note window at the clicked spot
local handler = WorldMapFrame.clickHandlers[1]
check(#WorldMapFrame.clickHandlers == 1 and handler.priority == 80, "world map click handler registered once (priority 80)")
local function mapClick(mapID, button, shift, x, y)
    WorldMapFrame.mapID = mapID
    shiftDown = shift
    local handled = handler.fn(WorldMapFrame, button, x, y)
    shiftDown = false
    return handled
end
check(mapClick(1429, "RightButton", false, 0.5, 0.25) == false and not dlg:IsShown(), "plain right-click is left to the map (zoom out)")
check(mapClick(1429, "LeftButton", true, 0.5, 0.25) == false and not dlg:IsShown(), "shift-left-click is left to the map (world quests)")
check(mapClick(1415, "RightButton", true, 0.5, 0.25) == true and not dlg:IsShown(), "shift-right-click on a continent is consumed but opens nothing")
check(mapClick(1429, "RightButton", true, 0.5, 0.25) == true and dlg:IsShown(), "shift-right-click on a zone opens the note window")
check(dlg.where:GetText() == "Elwynn Forest  50.0, 25.0", "window shows the clicked spot, not the player's position")
dlg.edit:SetText("from the map")
dlg.addButton:Click()
local fromMap
for _, rec in GA.POI:Iterate() do if rec.text == "from the map" then fromMap = rec end end
check(fromMap and fromMap.mapID == 1429 and fromMap.x == 0.5 and fromMap.y == 0.25, "note saved at the clicked spot")
GA.POIMap:Redraw()
check(count(drawn.world, NOTES) == 2, "clicked note gets its own pin")
check(mapClick(1429, "RightButton", true, 0.5, 0.25) and dlg:IsShown() and GA.NoteDialog:Open() == nil and dlg.where:GetText() == "Elwynn Forest  42.3, 65.1",
    "minimap-button Open() still uses the player's position")
dlg:Hide()

-- show/hide button on the world map
local btn = GA.POIMap.mapButton
check(btn and btn.parent == WorldMapFrame, "notes toggle button created on the world map")
local worldBefore, miniBefore = count(drawn.world, NOTES), count(drawn.mini, NOTES)
check(pcall(btn.scripts.OnEnter, btn), "toggle button tooltip builds")
btn:Click()
GA.POIMap:Redraw()
check(GA.db.profile.poi.showWorldMap == false and count(drawn.world, NOTES) == 0 and count(drawn.mini, NOTES) == miniBefore,
    "click hides note pins on the world map, minimap pins stay")
btn:Click()
GA.POIMap:Redraw()
check(GA.db.profile.poi.showWorldMap == true and count(drawn.world, NOTES) == worldBefore, "second click shows them again")
GA.POI:SlashCommand("map"); GA.POIMap:Redraw()
check(count(drawn.world, NOTES) == 0, "/sawit map hides them too")
GA.POI:SlashCommand("map"); GA.POIMap:Redraw()
check(count(drawn.world, NOTES) == worldBefore, "/sawit map shows them again")

-- right-click a note pin: delete window, only for notes you may delete
local function pinOf(id)
    for icon, v in pairs(drawn.world) do
        if v.ref == NOTES then for _, rec in ipairs(icon.recs) do if rec.id == id then return icon end end end
    end
end
local bobsOwn = GA.POI:Create("", "other", 1429, 0.7, 0.7, "Bob only")
local bobsShared = GA.POI:Create("", "other", 1429, 0.5, 0.25, "Bob next to mine")
GA.POI:Get(bobsOwn).author, GA.POI:Get(bobsShared).author = "Bob", "Bob"   -- as if synced from Bob
GA.POIMap:Redraw()
local del = GA.DeleteDialog
local bobPin = pinOf(bobsOwn)
check(pcall(bobPin.scripts.OnEnter, bobPin), "tooltip builds on a pin you can't delete")
bobPin.scripts.OnClick(bobPin, "RightButton")
check(not (del.GetFrame() and del.GetFrame():IsShown()), "right-click on someone else's note opens nothing")
local function shownRows() return #del._listed end
local mixed = pinOf(fromMap.id)
mixed.scripts.OnClick(mixed, "RightButton")
local dd = del.GetFrame()
check(dd and dd:IsShown() and shownRows() == 1 and del._listed[1].id == fromMap.id, "right-click on a shared pin lists only your note")
check(dd.title:GetText() == "Delete this note?", "one note: 'Delete this note?'")
dd.cancelButton:Click()
check(not dd:IsShown() and GA.POI:Get(fromMap.id) and not GA.POI:Get(fromMap.id).deleted, "Cancel deletes nothing")
local pair = pinOf(r.id)
pair.scripts.OnClick(pair, "RightButton")
check(dd:IsShown() and shownRows() == 2 and dd.title:GetText() == "Delete which note?", "pin with two of your notes lists both")
local firstId = del._listed[1].id
del._rows[1].button:Click()
check(GA.POI:Get(firstId).deleted and dd:IsShown() and shownRows() == 1 and del._listed[1].id ~= firstId,
    "Delete removes that note only; the other stays listed")
local lastId = del._listed[1].id
del._rows[1].button:Click()
check(GA.POI:Get(lastId).deleted and not dd:IsShown(), "deleting the last listed note closes the window")
GA.POIMap:Redraw()
check(pinOf(r.id) == nil and pinOf(fromMap.id) ~= nil, "deleted notes disappear from the map")

-- test mode (GA.TEST_MODE): works without a guild, local only
local sends = 0
local realSend = GA.Comm.SendCommMessage
GA.Comm.SendCommMessage = function(...) sends = sends + 1; return realSend(...) end
check(GA.Comm:Send("H", { 0, 0 }) == true and sends == 1, "(control) in a real guild, Comm sends")
local realNotes = 0
for _ in GA.POI:Iterate() do realNotes = realNotes + 1 end

GA.TEST_MODE = true
sends = 0
check(GA:GetGuildKey() == "AZB Test-Realm", "test mode: guild key is the hardcoded test guild")
check(GA.Comm:Send("H", { 0, 0 }) == false and GA.Comm:SendRaw("0") == false and sends == 0,
    "test mode: nothing is sent, even while in a real guild")
local rx = GA.Comm.stats.rxData
GA.Comm:OnData("GAtlasD", "0x", "GUILD", "Bob")
check(GA.Comm.stats.rxData == rx, "test mode: incoming guild messages are ignored")

IsInGuild = function() return false end
GetGuildInfo = function() return nil end
check(pcall(ldb.OnClick, nil, "LeftButton") and dlg:IsShown(), "test mode: note window opens without a guild")
dlg.edit:SetText("test mode note")
dlg.addButton:Click()
check(not dlg:IsShown() and sends == 0, "test mode: note saved, nothing sent")
local testNotes = 0
for _, rec in GA.POI:Iterate() do testNotes = testNotes + 1; check(rec.text == "test mode note", "test mode: only test notes visible") end
check(testNotes == 1, "test mode: test notes stored separately from the real guild's")
check(mapClick(1429, "RightButton", true, 0.3, 0.3) and dlg:IsShown(), "test mode: world-map Shift+right-click works without a guild")
dlg:Hide()

GA.TEST_MODE = false
check(GA:GetGuildKey() == nil and not (pcall(ldb.OnClick, nil, "LeftButton") and dlg:IsShown()), "flag off again: no guild, no note window")
IsInGuild = function() return true end
GetGuildInfo = function() return "AZB" end
local after = 0
for _ in GA.POI:Iterate() do after = after + 1 end
check(after == realNotes, "flag off again: the real guild's notes are untouched")
check(#caught == 0, "no errors reported to the error handler")

print(fails == 0 and "\nALL PASSED" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
