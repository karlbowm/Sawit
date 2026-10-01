--[[
GuildAtlas - POI module: records, validation, permissions, sync, and the note part of /sawit (Core forwards to it).
Rendering lives in POIMap.lua (own HereBeDragons pins) so this file has no UI dependency.

Record (in memory and SavedVariables, GuildAtlasDB.global.guilds[<guild>-<realm>].pois[id]):
  id        string  [%w]{1,24}, base36(time)..3 random chars, unique enough for a 50-person guild
  rev       number  version counter. New rev = max(time(), old.rev + 1). Higher rev wins.
            ties (same rev) break on updatedBy (string compare) so every client converges.
  author    string  creator, immutable
  updatedBy string  who wrote this revision (author or an officer)
  mapID     number  uiMapID
  x, y      number  0..0.9999 (4 decimal places)
  title     string  <= 40 bytes, same cleaning plus '[' ']' stripped (it is shown as "[Category: Title]" in chat).
            "" on notes made before titles existed; displays fall back to the text (POI.DisplayTitle).
  text      string  <= 120 bytes, control chars and '|' stripped. Optional details when a title is set.
  cat       string  key of POI.CATEGORIES
  deleted   bool    tombstone; text is emptied. Tombstones sync like any record.

Wire form of a record (array, positional, no keys):
  { id, rev, author, updatedBy, mapID, xq, yq, text, cat, del, title }   xq,yq = 0..9999 ints, del = 0|1
  title is last so clients without it (standalone GuildAtlas) still accept the record; they drop it when relaying.

Message types (all carried by Comm, envelope (PROTO, type, payload)):
  U  live update            payload = packed record             GUILD,   ALERT
  H  hello (after login)    payload = { count, checksum }       GUILD,   NORMAL
  G  digest                 payload = { id1, rev1, id2, rev2 }  WHISPER, NORMAL   (answer to H)
  Q  request records        payload = { id1, id2, ... }         WHISPER, NORMAL
  R  records                payload = { packed, packed, ... }   WHISPER, NORMAL
]]
local ADDON, ns = ...
local GA = ns.addon

local POI = GA:NewModule("POI", "AceEvent-3.0", "AceConsole-3.0")
GA.POI = POI

local MAX_TEXT = 120
local MAX_TITLE = 40
local TOMBSTONE_TTL = 180 * 86400     -- known limitation: a peer that was offline longer can resurrect a note
local MAX_FUTURE = 86400              -- reject revs more than a day ahead of our clock (clock-skew guard)
local MAX_DIGEST_ENTRIES = 5000
local RECORDS_PER_MSG = 6
local IDS_PER_MSG = 40

-- TODO(verify icons): these are classic Interface\Icons names; confirm they exist on the WoW Forever client.
-- Colours tint the map pin ring, so they are saturated hues that the map's parchment/tan/brown/green/desert-yellow
-- palette doesn't use: magenta, red, cyan, white (the black ring outline keeps white readable on snow).
POI.CATEGORIES = {
    rare  = { label = "Rare spawn",      icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", color = "ff50ff" },
    grind = { label = "Good grind spot", icon = "Interface\\Icons\\INV_Sword_04",                 color = "ff2828" },
    quest = { label = "Hidden quest",    icon = "Interface\\Icons\\INV_Scroll_03",                color = "20e8ff" },
    other = { label = "Other",           icon = "Interface\\Icons\\INV_Misc_Note_01",             color = "ffffff" },
}
POI.CATEGORY_ORDER = { "rare", "grind", "quest", "other" }

---------------------------------------------------------------------------
-- small helpers (pure: no WoW API, unit-testable)
---------------------------------------------------------------------------
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
    local s = ""
    repeat
        local d = n % 36
        s = B36:sub(d + 1, d + 1) .. s
        n = math.floor(n / 36)
    until n == 0
    return s
end

local function newID() return b36(time()) .. ("000" .. b36(math.random(0, 46655))):sub(-3) end

local function clampQ(v) return math.max(0, math.min(9999, math.floor(v * 10000 + 0.5))) end

local function cleanText(s, max)
    max = max or MAX_TEXT
    s = tostring(s or ""):gsub("[%c|]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if #s > max then
        s = s:sub(1, max)
        -- don't leave half of a multi-byte UTF-8 character at the end
        local i = #s
        while i > 0 and s:byte(i) >= 128 and s:byte(i) < 192 do i = i - 1 end
        if i > 0 and s:byte(i) >= 192 then s = s:sub(1, i - 1) end
    end
    return s
end
POI._cleanText = cleanText

local function cleanTitle(s) return cleanText(tostring(s or ""):gsub("[%[%]]", ""), MAX_TITLE) end
POI.MAX_TITLE = MAX_TITLE

-- Title for display: the title, or for untitled (older) notes the start of the text.
function POI.DisplayTitle(rec)
    if rec.title and rec.title ~= "" then return rec.title end
    return cleanTitle(rec.text or "")
end

local function hashEntry(id, rev)
    local h, s = 5381, id .. ":" .. rev
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

-- true when a is a newer revision than b
local function isNewer(a, b)
    if a.rev ~= b.rev then return a.rev > b.rev end
    return a.updatedBy > b.updatedBy
end

---------------------------------------------------------------------------
-- store access
---------------------------------------------------------------------------
function POI:Store()
    local g = GA:GuildStore()
    return g and g.pois
end

function POI:Get(id) local s = self:Store(); return s and s[id] end

-- Iterates live (non-tombstoned) records.
function POI:Iterate()
    local s = self:Store() or {}
    local id, rec
    return function()
        repeat
            id, rec = next(s, id)
        until not id or not rec.deleted
        return id, rec
    end
end

function POI:Checksum()
    local s, count, sum = self:Store() or {}, 0, 0
    for id, rec in pairs(s) do count = count + 1; sum = (sum + hashEntry(id, rec.rev)) % 4294967296 end
    return count, sum
end

---------------------------------------------------------------------------
-- pack / unpack / validate
---------------------------------------------------------------------------
local function pack(r)
    return { r.id, r.rev, r.author, r.updatedBy, r.mapID, clampQ(r.x), clampQ(r.y), r.text, r.cat, r.deleted and 1 or 0, r.title or "" }
end
POI._pack = pack

local function isName(s) return type(s) == "string" and #s >= 2 and #s <= 48 and not s:find("[%c|]") end

-- Returns a sanitised local-format record or nil, reason. Never trusts types or ranges.
local function unpackRec(a)
    if type(a) ~= "table" then return nil, "not-table" end
    local id, rev, author, updatedBy, mapID, xq, yq, text, cat, del, title = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11]
    if type(id) ~= "string" or not id:match("^%w+$") or #id > 24 then return nil, "id" end
    if type(rev) ~= "number" or rev ~= math.floor(rev) or rev < 1 or rev > time() + MAX_FUTURE then return nil, "rev" end
    if not isName(author) or not isName(updatedBy) then return nil, "name" end
    if type(mapID) ~= "number" or mapID ~= math.floor(mapID) or mapID < 1 or mapID > 99999 then return nil, "map" end
    if type(xq) ~= "number" or type(yq) ~= "number" or xq < 0 or xq > 9999 or yq < 0 or yq > 9999 then return nil, "xy" end
    if type(text) ~= "string" or type(cat) ~= "string" then return nil, "text" end
    local deleted = (del == 1)
    return {
        id = id, rev = rev, author = author, updatedBy = updatedBy, mapID = mapID,
        x = math.floor(xq) / 10000, y = math.floor(yq) / 10000,
        text = deleted and "" or cleanText(text),
        title = (deleted or type(title) ~= "string") and "" or cleanTitle(title),
        cat = POI.CATEGORIES[cat] and cat or "other",
        deleted = deleted or nil,
    }
end
POI._unpack = unpackRec

---------------------------------------------------------------------------
-- permissions + apply
---------------------------------------------------------------------------
-- actor == rec.updatedBy (claimed). For live updates the caller has already checked actor == sender;
-- for relayed sync records the claim is only as trustworthy as the relaying peer (see README, "Trust").
function POI:MayWrite(rec, existing)
    local actor = rec.updatedBy
    if existing then
        if existing.author ~= rec.author then return false, "author-changed" end
        return actor == existing.author or GA:IsOfficer(actor), "not-allowed"
    end
    return actor == rec.author or GA:IsOfficer(actor), "not-allowed"
end

-- May the local player edit/delete this note? Same rule MayWrite applies on every receiving client.
function POI:CanModify(rec)
    return rec ~= nil and not rec.deleted and (rec.author == GA.playerName or GA:IsOfficer(GA.playerName))
end

-- sender: who delivered it. live: true when sender must also be the claimed updatedBy (U messages / local edits).
function POI:Apply(packedOrRec, sender, live)
    local store = self:Store()
    if not store then return false, "no-guild" end
    local rec, why
    if packedOrRec.id and not packedOrRec[1] then   -- already local format (own edits)
        rec, why = unpackRec(pack(packedOrRec))
    else
        rec, why = unpackRec(packedOrRec)
    end
    if not rec then return false, why end
    if live and GA:Normalize(sender) ~= rec.updatedBy then return false, "sender-mismatch" end
    local existing = store[rec.id]
    if existing and not isNewer(rec, existing) then return false, "stale" end
    local ok, reason = self:MayWrite(rec, existing)
    if not ok then return false, reason end
    store[rec.id] = rec
    self:SendMessage("GUILDATLAS_POI_CHANGED", rec.id)
    return true
end

---------------------------------------------------------------------------
-- local mutations (each applies locally, then broadcasts a live update)
---------------------------------------------------------------------------
local function broadcast(rec)
    local comm = GA.Comm
    if comm then comm:Send("U", pack(rec), "GUILD", nil, "ALERT") end
end

-- title is optional for callers that predate it; a note needs a title or a text.
function POI:Create(text, cat, mapID, x, y, title)
    text, title = cleanText(text), cleanTitle(title)
    if text == "" and title == "" then return nil, "empty-text" end
    local rec = {
        id = newID(), rev = time(), author = GA.playerName, updatedBy = GA.playerName,
        mapID = mapID, x = clampQ(x) / 10000, y = clampQ(y) / 10000,
        text = text, title = title, cat = POI.CATEGORIES[cat] and cat or "other",
    }
    local ok, why = self:Apply(rec, GA.playerName, true)
    if not ok then return nil, why end
    broadcast(self:Get(rec.id))
    return rec.id
end

function POI:Edit(id, changes)
    local old = self:Get(id)
    if not old or old.deleted then return false, "unknown-id" end
    local rec = {}
    for k, v in pairs(old) do rec[k] = v end
    rec.rev = math.max(time(), old.rev + 1)
    rec.updatedBy = GA.playerName
    if changes.text then rec.text = cleanText(changes.text) end
    if changes.title then rec.title = cleanTitle(changes.title) end
    if changes.cat and POI.CATEGORIES[changes.cat] then rec.cat = changes.cat end
    if rec.text == "" and (rec.title or "") == "" then return false, "empty-text" end
    local ok, why = self:Apply(rec, GA.playerName, true)
    if ok then broadcast(self:Get(id)) end
    return ok, why
end

function POI:Remove(id)
    local old = self:Get(id)
    if not old or old.deleted then return false, "unknown-id" end
    local rec = {}
    for k, v in pairs(old) do rec[k] = v end
    rec.rev, rec.updatedBy, rec.deleted, rec.text, rec.title = math.max(time(), old.rev + 1), GA.playerName, true, "", ""
    local ok, why = self:Apply(rec, GA.playerName, true)
    if ok then broadcast(self:Get(id)) end
    return ok, why
end

---------------------------------------------------------------------------
-- sync
---------------------------------------------------------------------------
local lastHelloAt, answered = 0, {}

function POI:PurgeTombstones()
    local s, cutoff = self:Store(), time() - TOMBSTONE_TTL
    if not s then return end
    for id, rec in pairs(s) do if rec.deleted and rec.rev < cutoff then s[id] = nil end end
end

function POI:SendHello()
    local comm = GA.Comm
    if not (comm and self:Store()) then return false end
    self:PurgeTombstones()
    local count, sum = self:Checksum()
    lastHelloAt = GetTime()
    self.syncUntil = lastHelloAt + 180          -- digests are only accepted inside this window
    if not comm:Send("H", { count, sum }, "GUILD", nil, "NORMAL") then return false end
    GA:Debug("hello sent", count, sum)
    return true
end

-- Login: wait for the roster, then a random 5-15 s so 50 people logging in together don't all hello at once.
function POI:ScheduleHello(attempt)
    attempt = attempt or 1
    C_Timer.After(attempt == 1 and math.random(5, 15) or 5, function()
        if GA.rosterReady and GA:InGuild() then
            self:SendHello()
        elseif attempt < 6 then
            GA:RequestRoster()
            self:ScheduleHello(attempt + 1)
        end
    end)
end

local function sendRecords(to, recs)
    local chunk = {}
    for _, rec in ipairs(recs) do
        chunk[#chunk + 1] = pack(rec)
        if #chunk >= RECORDS_PER_MSG then GA.Comm:Send("R", chunk, "WHISPER", to, "NORMAL"); chunk = {} end
    end
    if #chunk > 0 then GA.Comm:Send("R", chunk, "WHISPER", to, "NORMAL") end
end

function POI:OnHello(sender, payload)
    if type(payload) ~= "table" or type(payload[1]) ~= "number" or type(payload[2]) ~= "number" then return end
    local count, sum = self:Checksum()
    if payload[1] == count and payload[2] == sum then return end          -- identical state: stay silent
    if answered[sender] and GetTime() - answered[sender] < 60 then return end
    answered[sender] = GetTime()
    -- Random delay spreads up-to-49 simultaneous answers. TODO(optimisation): suppress when another peer already answered.
    C_Timer.After(1 + math.random() * 5, function()
        local store = self:Store()
        if not store then return end
        local d = {}
        for id, rec in pairs(store) do d[#d + 1] = id; d[#d + 1] = rec.rev end
        GA.Comm:Send("G", d, "WHISPER", sender, "NORMAL")
    end)
end

function POI:OnDigest(sender, payload)
    if not (self.syncUntil and GetTime() < self.syncUntil) then return end
    local store = self:Store()
    if not store or type(payload) ~= "table" or #payload > MAX_DIGEST_ENTRIES * 2 then return end
    local remote, need, offer = {}, {}, {}
    for i = 1, #payload - 1, 2 do
        local id, rev = payload[i], payload[i + 1]
        if type(id) == "string" and type(rev) == "number" then remote[id] = rev end
    end
    for id, rev in pairs(remote) do
        local mine = store[id]
        if not mine or rev > mine.rev then need[#need + 1] = id end
    end
    for id, rec in pairs(store) do
        local theirs = remote[id]
        if not theirs or rec.rev > theirs then offer[#offer + 1] = rec end
    end
    GA:Debug("digest from", sender, "need", #need, "offer", #offer)
    for i = 1, #need, IDS_PER_MSG do
        local chunk = {}
        for j = i, math.min(i + IDS_PER_MSG - 1, #need) do chunk[#chunk + 1] = need[j] end
        GA.Comm:Send("Q", chunk, "WHISPER", sender, "NORMAL")
    end
    sendRecords(sender, offer)
end

function POI:OnRequest(sender, payload)
    local store = self:Store()
    if not store or type(payload) ~= "table" then return end
    local recs = {}
    for i = 1, math.min(#payload, 100) do
        local rec = type(payload[i]) == "string" and store[payload[i]]
        if rec then recs[#recs + 1] = rec end
    end
    sendRecords(sender, recs)
end

function POI:OnRecords(sender, payload)
    if type(payload) ~= "table" then return end
    local applied = 0
    for i = 1, math.min(#payload, 20) do
        local ok = self:Apply(payload[i], sender, false)
        if ok then applied = applied + 1 end
    end
    if applied > 0 then GA:Debug("sync: applied", applied, "from", sender) end
end

function POI:OnUpdate(sender, payload)
    local ok, why = self:Apply(payload, sender, true)
    if not ok and why ~= "stale" then GA:Debug("U rejected from", sender, why) end
end

---------------------------------------------------------------------------
-- lifecycle + slash
---------------------------------------------------------------------------
function POI:OnEnable()
    local comm = GA.Comm
    comm:RegisterHandler("U", function(s, p) self:OnUpdate(s, p) end)
    comm:RegisterHandler("H", function(s, p) self:OnHello(s, p) end)
    comm:RegisterHandler("G", function(s, p) self:OnDigest(s, p) end)
    comm:RegisterHandler("Q", function(s, p) self:OnRequest(s, p) end)
    comm:RegisterHandler("R", function(s, p) self:OnRecords(s, p) end)
    -- secret entered or changed: sync with the guildmates who share it
    self:RegisterMessage("SAWIT_GUILD_SECRET_CHANGED", function() if GA:CanUseNetwork() then self:SendHello() end end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        self:ScheduleHello(1)
    end)
end

local function mapName(mapID)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    return info and info.name or ("map " .. mapID)
end
POI.MapName = mapName

function POI:Describe(rec)
    local c = POI.CATEGORIES[rec.cat]
    local body = (rec.title ~= nil and rec.title ~= "") and (rec.title .. (rec.text ~= "" and (" - " .. rec.text) or "")) or rec.text
    return ("|cff%s[%s]|r %s  (%s %.1f, %.1f)  by %s  id %s"):format(c.color, c.label, body, mapName(rec.mapID), rec.x * 100, rec.y * 100, rec.author, rec.id)
end

-- "Title; details" -> title, details. Without ';' the whole input is the title and details is nil
-- (so /sawit edit <id> <title> keeps the existing details; "title;" clears them).
local function splitTitle(s)
    local title, text = s:match("^(.-)%s*;%s*(.*)$")
    if title then return title, text end
    return s, nil
end
POI._splitTitle = splitTitle

function POI:SlashCommand(input)
    local cmd, rest = (input or ""):match("^(%S*)%s*(.-)$")
    local lc = cmd:lower()
    if lc == "" or lc == "help" then
        self:Print("/sawit status | share [on|off] | pause | debug | secret [clear]")
        self:Print("/sawit add [category] <title>[; details]   add a note here. Or Shift+right-click the world map.")
        self:Print("/sawit my [here]   your own notes      /sawit list [here]   all notes      /sawit cats   categories")
        self:Print("/sawit edit <id> [category] <title>[; details]      /sawit del <id>      /sawit sync      /sawit stats")
        self:Print("/sawit filter [category]   show/hide a category      /sawit map   notes on the world map      /sawit minimap   notes on the minimap")
    elseif lc == "cats" then
        for _, k in ipairs(POI.CATEGORY_ORDER) do self:Print(k, "-", POI.CATEGORIES[k].label) end
    elseif lc == "filter" then
        local key = rest:lower()
        local filters = GA.db.profile.poi.filters
        if POI.CATEGORIES[key] then
            GA.POIMap:SetFilter(key, not filters[key])
        elseif key ~= "" then
            return self:Print("unknown category '" .. rest .. "' (see /sawit cats)")
        end
        for _, k in ipairs(POI.CATEGORY_ORDER) do
            self:Print(("%-6s %s"):format(k, filters[k] and "|cff40ff40shown|r" or "|cffff4040hidden|r"))
        end
    elseif lc == "map" then
        GA.POIMap:SetWorldMap(not GA.db.profile.poi.showWorldMap)
        self:Print("notes on world map: " .. (GA.db.profile.poi.showWorldMap and "shown" or "hidden"))
    elseif lc == "minimap" then
        GA.POIMap:SetMinimap(not GA.db.profile.poi.showMinimap)
        self:Print("notes on minimap: " .. (GA.db.profile.poi.showMinimap and "shown" or "hidden"))
    elseif lc == "list" or lc == "my" then
        local here = GA:GetPlayerPosition()
        local mine = (lc == "my")
        local n = 0
        for _, rec in self:Iterate() do
            if (rest ~= "here" or rec.mapID == here) and (not mine or rec.author == GA.playerName) then
                n = n + 1; self:Print(self:Describe(rec))
            end
        end
        if mine then
            self:Print(n .. " note(s) by you" .. (n > 0 and "   change: /sawit edit <id> ...   remove: /sawit del <id>" or ""))
        else
            self:Print(n .. " note(s)")
        end
    elseif lc == "del" then
        local ok, why = self:Remove(rest)
        self:Print(ok and "deleted" or ("cannot delete: " .. tostring(why)))
    elseif lc == "edit" then
        local id, tail = rest:match("^(%S+)%s*(.-)$")
        local first, text = tail:match("^(%S+)%s*(.-)$")
        local changes = {}
        if first and POI.CATEGORIES[first:lower()] then changes.cat = first:lower() else text = tail end
        if text ~= "" then changes.title, changes.text = splitTitle(text) end
        local ok, why = self:Edit(id or "", changes)
        self:Print(ok and "updated" or ("cannot edit: " .. tostring(why)))
    elseif lc == "sync" then
        self:Print(self:SendHello() and "sync hello sent" or ("cannot sync: " .. (GA:NetworkBlockReason() or "not ready")))
    elseif lc == "stats" then
        local count, sum = self:Checksum()
        local live = 0
        for _ in self:Iterate() do live = live + 1 end
        self:Print(("records=%d (live %d) checksum=%d"):format(count, live, sum))
        local st = GA.Comm.stats
        self:Print(("comm: tx %d msgs/%dB, rx %d msgs/%dB, dropped %d, bad-proto %d"):format(st.txData, st.txBytes, st.rxData, st.rxBytes, st.dropped, st.badProto))
    elseif lc == "add" then
        -- /sawit add [category] title[; details]. Needs the word "add", so a mistyped command never becomes a note.
        local text = rest
        local first, tail = text:match("^(%S+)%s*(.-)$")
        local cat = "other"
        if first and POI.CATEGORIES[first:lower()] then cat, text = first:lower(), tail end
        local mapID, x, y = GA:GetPlayerPosition()
        if not mapID then return self:Print("no position available here (" .. tostring(x) .. ")") end
        local title, details = splitTitle(text)
        local id, why = self:Create(details or "", cat, mapID, x, y, title)
        self:Print(id and ("added " .. id) or ("cannot add: " .. tostring(why)))
    else
        self:Print("unknown command '" .. cmd .. "' (/sawit help)")
    end
end
