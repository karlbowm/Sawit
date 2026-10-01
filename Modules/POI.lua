--[[
SawIt - POI: guild notes ("points of interest"). Records, validation, permissions, sync, and the note commands of
/sawit (Core forwards every command it doesn't handle itself). Drawing is in POIMap.lua, so this file has no UI.

Record (in memory and in SawItDB.global.guilds["Guild-Realm"].pois[id]):
  id        string  [%w]{1,24}: base36(time) .. 3 random base36 chars; unique enough for a 50-person guild
  rev       number  version. A new revision gets max(time(), old.rev + 1). The higher rev wins; equal revs are decided
                    by updatedBy (string compare), so every client ends up with the same record.
  author    string  creator, never changes
  updatedBy string  who wrote this revision (the author or an officer)
  mapID     number  uiMapID
  x, y      number  0..0.9999 (4 decimals)
  title     string  <= 40 bytes; control chars, '|', '[' and ']' removed (it is shown as "[Category: Title]" in chat).
                    "" (nil in old saved data) when the note has none: DisplayTitle() then shows the text.
  text      string  <= 120 bytes, control chars and '|' removed. The details, when there is a title.
  cat       string  key of POI.CATEGORIES (unknown keys become "other")
  deleted   true|nil  tombstone: text and title emptied. Synced like any record, purged after 180 days.

Wire form (positional array): { id, rev, author, updatedBy, mapID, xq, yq, text, cat, del, title }
  xq, yq = 0..9999 integers, del = 0|1. title is last, so clients that only know 10 fields still accept the record.

Messages (sent through Comm):
  U  live update      payload = packed record                GUILD,   ALERT
  H  hello (login)    payload = { count, checksum }          GUILD,   NORMAL
  G  digest           payload = { id1, rev1, id2, rev2, .. } WHISPER, NORMAL   (answer to H)
  Q  request records  payload = { id1, id2, ... }            WHISPER, NORMAL
  R  records          payload = { packed, packed, ... }      WHISPER, NORMAL
Sync: after login (and when the guild secret is set) we send H. Every guildmate whose checksum differs whispers us a
digest G; from it we request what is newer there (Q) and send what is newer here (R).
]]
local _, ns = ...
local GA = ns.addon

local POI = GA:NewModule("POI", "AceEvent-3.0")
GA.POI = POI

local MAX_TEXT, MAX_TITLE = 120, 40
POI.MAX_TITLE = MAX_TITLE
local TOMBSTONE_TTL = 180 * 86400   -- known limit: a peer offline for longer can bring a deleted note back
local MAX_FUTURE = 86400            -- revs more than a day ahead of our clock are rejected (clock-skew guard)
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
-- helpers (no WoW API, so the tests can use them)
---------------------------------------------------------------------------
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

-- In: n  integer >= 0.  Out: n in base 36, e.g. "tm751s"
local function b36(n)
    local s = ""
    repeat
        local d = n % 36
        s = B36:sub(d + 1, d + 1) .. s
        n = math.floor(n / 36)
    until n == 0
    return s
end

-- Out: a new note id
local function newID() return b36(time()) .. ("000" .. b36(math.random(0, 46655))):sub(-3) end

-- In: v  coordinate 0..1.  Out: integer 0..9999, as sent on the wire
local function quantize(v) return math.max(0, math.min(9999, math.floor(v * 10000 + 0.5))) end

-- Cuts s to at most max bytes without splitting a UTF-8 character: when the first byte that falls off is the middle
-- of a character (a continuation byte, 0x80-0xBF), that whole character goes too. Also used for chat (POIMap).
-- In: s  string;  max  bytes.  Out: string
function POI.Truncate(s, max)
    if #s <= max then return s end
    local i = max + 1   -- first byte that falls off
    while i > 1 and s:byte(i) >= 128 and s:byte(i) < 192 do i = i - 1 end
    return s:sub(1, i - 1)
end

-- Makes text safe to store and show: control chars and '|' (WoW's escape character) become spaces, runs of spaces
-- collapse, and it is cut to max bytes (POI.Truncate).
-- In:  s  anything (nil -> "");  max  bytes, default MAX_TEXT.  Out: string
local function cleanText(s, max)
    s = tostring(s or ""):gsub("[%c|]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return POI.Truncate(s, max or MAX_TEXT)
end

-- In: s  anything.  Out: cleaned title: like cleanText, also without '[' and ']', at most MAX_TITLE bytes
local function cleanTitle(s) return cleanText(tostring(s or ""):gsub("[%[%]]", ""), MAX_TITLE) end

-- The title to show. A note without a title (older notes, or added with details only) shows the start of its text.
-- In: rec.  Out: string
function POI.DisplayTitle(rec)
    if rec.title and rec.title ~= "" then return rec.title end
    return cleanTitle(rec.text)
end

-- The details to show below or after the title: the text, unless DisplayTitle already shows all of it.
-- In: rec.  Out: string, "" when there is nothing more to show
function POI.Details(rec)
    if rec.title and rec.title ~= "" then return rec.text end
    return POI.DisplayTitle(rec) == rec.text and "" or rec.text
end

-- In: id, rev.  Out: 32-bit hash of the pair, summed up by Checksum()
local function hashEntry(id, rev)
    local h, s = 5381, id .. ":" .. rev
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

-- In: a, b  records with the same id.  Out: true when a is the newer revision
local function isNewer(a, b)
    if a.rev ~= b.rev then return a.rev > b.rev end
    return a.updatedBy > b.updatedBy
end

-- "Title; details" -> "Title", "details". Without ';' everything is the title and details is nil, so
-- "/sawit edit <id> <title>" keeps the existing details and "<title>;" clears them.
local function splitTitle(s)
    local title, text = s:match("^(.-)%s*;%s*(.*)$")
    if title then return title, text end
    return s, nil
end
POI._splitTitle = splitTitle   -- for tests

-- "rare Mother Fang" -> "rare", "Mother Fang". When the first word isn't a category: nil, the whole string.
local function splitCategory(s)
    local first, rest = s:match("^(%S+)%s*(.-)$")
    if first and POI.CATEGORIES[first:lower()] then return first:lower(), rest end
    return nil, s
end

---------------------------------------------------------------------------
-- store
---------------------------------------------------------------------------
-- Out: the current guild's notes table { [id] = record } (tombstones included), or nil when not in a guild
function POI:Store()
    local g = GA:GuildStore()
    return g and g.pois
end

-- In: id.  Out: the record (possibly a tombstone), or nil
function POI:Get(id)
    local s = self:Store()
    return s and s[id]
end

-- Iterates over the notes that aren't deleted:  for id, rec in POI:Iterate() do ... end
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

-- Out: count, checksum over every record's (id, rev), tombstones included. Equal on two clients = same notes.
function POI:Checksum()
    local count, sum = 0, 0
    for id, rec in pairs(self:Store() or {}) do
        count = count + 1
        sum = (sum + hashEntry(id, rec.rev)) % 4294967296
    end
    return count, sum
end

---------------------------------------------------------------------------
-- wire form
---------------------------------------------------------------------------
-- In: r  record.  Out: its wire form
local function pack(r)
    return { r.id, r.rev, r.author, r.updatedBy, r.mapID, quantize(r.x), quantize(r.y), r.text, r.cat,
             r.deleted and 1 or 0, r.title or "" }
end
POI._pack = pack   -- for tests

local function isName(s) return type(s) == "string" and #s >= 2 and #s <= 48 and not s:find("[%c|]") end

-- Checks and cleans a record in wire form. Trusts nothing: every type, range and text is checked.
-- In: a  anything.  Out: the record, or nil, reason (the name of the bad field)
local function unpackRecord(a)
    if type(a) ~= "table" then return nil, "not-table" end
    local id, rev, author, updatedBy, mapID, xq, yq, text, cat, del, title = unpack(a, 1, 11)
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

---------------------------------------------------------------------------
-- permissions and applying records
---------------------------------------------------------------------------
-- The write rule every client enforces: only the author or an officer may write a note, and the author never changes.
-- rec.updatedBy is checked against the real sender for live updates (Apply); for relayed sync records it is only
-- as trustworthy as the relaying peer (README, "Trust model").
-- In: rec (new revision), existing (our current one, or nil).  Out: true, or false, reason
local function mayWrite(rec, existing)
    if existing and existing.author ~= rec.author then return false, "author-changed" end
    if rec.updatedBy == rec.author or GA:IsOfficer(rec.updatedBy) then return true end
    return false, "not-allowed"
end

-- The same rule for the local UI: may we edit or delete this note?
-- In: rec.  Out: true or false
function POI:CanModify(rec)
    return rec ~= nil and not rec.deleted and (rec.author == GA.playerName or GA:IsOfficer(GA.playerName))
end

-- Stores a record if it is valid, newer than ours and allowed, then sends SAWIT_NOTES_CHANGED (the map redraws).
-- In:  packed  wire form (from a message, or pack() of our own new revision)
--      sender  who delivered it
--      live    true for live updates and our own edits: the sender must be the record's updatedBy.
--              false for relayed sync records (R), where the relaying peer isn't the writer.
-- Out: true, or false, reason
function POI:Apply(packed, sender, live)
    local store = self:Store()
    if not store then return false, "no-guild" end
    local rec, why = unpackRecord(packed)
    if not rec then return false, why end
    if live and GA:Normalize(sender) ~= rec.updatedBy then return false, "sender-mismatch" end
    local existing = store[rec.id]
    if existing and not isNewer(rec, existing) then return false, "stale" end
    local ok, reason = mayWrite(rec, existing)
    if not ok then return false, reason end
    store[rec.id] = rec
    self:SendMessage("SAWIT_NOTES_CHANGED", rec.id)
    return true
end

---------------------------------------------------------------------------
-- local changes: applied here first, then sent to the guild as a live update
---------------------------------------------------------------------------
-- In: rec  our new revision.  Out: true, or false, reason (from Apply)
local function commit(self, rec)
    local packed = pack(rec)
    local ok, why = self:Apply(packed, GA.playerName, true)
    if ok then GA.Comm:Send("U", packed, "GUILD", nil, "ALERT") end
    return ok, why
end

-- In: old record.  Out: a copy of it as the next revision, written by us
local function nextRevision(old)
    local rec = {}
    for k, v in pairs(old) do rec[k] = v end
    rec.rev, rec.updatedBy = math.max(time(), old.rev + 1), GA.playerName
    return rec
end

-- Adds a note. It needs a title or a text.
-- In:  text (the details), cat, mapID, x, y (0..1), title
-- Out: the new id, or nil, reason ("empty-text", or from Apply)
function POI:Create(text, cat, mapID, x, y, title)
    local rec = {
        id = newID(), rev = time(), author = GA.playerName, updatedBy = GA.playerName,
        mapID = mapID, x = x, y = y, text = cleanText(text), title = cleanTitle(title), cat = cat,
    }
    if rec.text == "" and rec.title == "" then return nil, "empty-text" end
    local ok, why = commit(self, rec)
    if not ok then return nil, why end
    return rec.id
end

-- Changes a note (author or officer).
-- In:  id;  changes = { title = , text = , cat = }, each optional
-- Out: true, or false, reason ("unknown-id" | "empty-text", or from Apply)
function POI:Edit(id, changes)
    local old = self:Get(id)
    if not old or old.deleted then return false, "unknown-id" end
    local rec = nextRevision(old)
    if changes.title then rec.title = cleanTitle(changes.title) end
    if changes.text then rec.text = cleanText(changes.text) end
    if POI.CATEGORIES[changes.cat] then rec.cat = changes.cat end
    if rec.text == "" and (rec.title or "") == "" then return false, "empty-text" end
    return commit(self, rec)
end

-- Deletes a note (author or officer) by replacing it with a tombstone, which syncs like any record.
-- In: id.  Out: true, or false, reason ("unknown-id", or from Apply)
function POI:Remove(id)
    local old = self:Get(id)
    if not old or old.deleted then return false, "unknown-id" end
    local rec = nextRevision(old)
    rec.deleted, rec.text, rec.title = true, "", ""
    return commit(self, rec)
end

---------------------------------------------------------------------------
-- sync
---------------------------------------------------------------------------
local answered = {}   -- sender -> GetTime() of our last digest to them

-- Forgets tombstones older than TOMBSTONE_TTL.
function POI:PurgeTombstones()
    local s, cutoff = self:Store(), time() - TOMBSTONE_TTL
    if not s then return end
    for id, rec in pairs(s) do
        if rec.deleted and rec.rev < cutoff then s[id] = nil end
    end
end

-- Sends a hello (count + checksum) to the guild. Guildmates whose notes differ answer with a digest, which we
-- accept for the next 3 minutes.
-- Out: true if sent
function POI:SendHello()
    if not self:Store() then return false end
    self:PurgeTombstones()
    local count, sum = self:Checksum()
    self.syncUntil = GetTime() + 180
    if not GA.Comm:Send("H", { count, sum }, "GUILD", nil, "NORMAL") then return false end
    GA:Debug("hello sent", count, sum)
    return true
end

-- After login: waits for the roster, then 5-15 s at random so a guild logging in together doesn't hello at once.
-- In: attempt  1 (default) .. 6; retried every 5 s while the roster isn't known
function POI:ScheduleHello(attempt)
    attempt = attempt or 1
    C_Timer.After(attempt == 1 and math.random(5, 15) or 5, function()
        if GA.rosterReady then
            self:SendHello()
        elseif attempt < 6 then
            GA:RequestRoster()
            self:ScheduleHello(attempt + 1)
        end
    end)
end

-- Whispers records to a player, RECORDS_PER_MSG per message.
-- In: to  player name;  recs  list of records
local function sendRecords(to, recs)
    local chunk = {}
    for _, rec in ipairs(recs) do
        chunk[#chunk + 1] = pack(rec)
        if #chunk >= RECORDS_PER_MSG then GA.Comm:Send("R", chunk, "WHISPER", to, "NORMAL"); chunk = {} end
    end
    if #chunk > 0 then GA.Comm:Send("R", chunk, "WHISPER", to, "NORMAL") end
end

-- H: someone logged in. If their checksum differs from ours, whisper them our digest (at most once a minute each).
function POI:OnHello(sender, payload)
    if type(payload) ~= "table" or type(payload[1]) ~= "number" or type(payload[2]) ~= "number" then return end
    local count, sum = self:Checksum()
    if payload[1] == count and payload[2] == sum then return end   -- same notes: stay silent
    if answered[sender] and GetTime() - answered[sender] < 60 then return end
    answered[sender] = GetTime()
    -- A random delay spreads up to 49 simultaneous answers. TODO(optimisation): skip if another peer already answered.
    C_Timer.After(1 + math.random() * 5, function()
        local store = self:Store()
        if not store then return end
        local d = {}
        for id, rec in pairs(store) do d[#d + 1] = id; d[#d + 1] = rec.rev end
        GA.Comm:Send("G", d, "WHISPER", sender, "NORMAL")
    end)
end

-- G: a digest in answer to our hello. Request what is newer there, send what is newer (or missing) there.
function POI:OnDigest(sender, payload)
    if not (self.syncUntil and GetTime() < self.syncUntil) then return end   -- only shortly after our own hello
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

-- Q: someone asks for records by id (at most 100 per request).
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

-- R: records relayed by a peer (at most 20 per message).
function POI:OnRecords(sender, payload)
    if type(payload) ~= "table" then return end
    local applied = 0
    for i = 1, math.min(#payload, 20) do
        if self:Apply(payload[i], sender, false) then applied = applied + 1 end
    end
    if applied > 0 then GA:Debug("sync: applied", applied, "from", sender) end
end

-- U: a live update from its writer.
function POI:OnUpdate(sender, payload)
    local ok, why = self:Apply(payload, sender, true)
    if not ok and why ~= "stale" then GA:Debug("U rejected from", sender, why) end
end

-- AceAddon callback: message handlers, and the first hello after login.
function POI:OnEnable()
    local comm = GA.Comm
    comm:RegisterHandler("U", function(s, p) self:OnUpdate(s, p) end)
    comm:RegisterHandler("H", function(s, p) self:OnHello(s, p) end)
    comm:RegisterHandler("G", function(s, p) self:OnDigest(s, p) end)
    comm:RegisterHandler("Q", function(s, p) self:OnRequest(s, p) end)
    comm:RegisterHandler("R", function(s, p) self:OnRecords(s, p) end)
    -- secret entered or changed: sync with the guildmates who share it
    self:RegisterMessage("SAWIT_SECRET_CHANGED", function() self:SendHello() end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        self:ScheduleHello()
    end)
end

---------------------------------------------------------------------------
-- text output and /sawit note commands
---------------------------------------------------------------------------
-- In: mapID.  Out: the map's name, or "map <id>"
function POI.MapName(mapID)
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name or ("map " .. tostring(mapID))
end

-- One line for chat: "[Rare spawn] Title - details  (Zone 45.2, 60.3)  by Name  id tm751se74"
-- In: rec.  Out: string
function POI:Describe(rec)
    local c, details = POI.CATEGORIES[rec.cat], POI.Details(rec)
    return ("|cff%s[%s]|r %s%s  (%s %.1f, %.1f)  by %s  id %s"):format(c.color, c.label, POI.DisplayTitle(rec),
        details ~= "" and (" - " .. details) or "", POI.MapName(rec.mapID), rec.x * 100, rec.y * 100, rec.author, rec.id)
end

local HELP = {
    "/sawit status | share [on|off] | pause | debug | secret [clear]",
    "/sawit add [category] <title>[; details]   add a note here. Or Shift+right-click the world map.",
    "/sawit my [here]   your own notes      /sawit list [here]   all notes      /sawit cats   categories",
    "/sawit edit <id> [category] <title>[; details]      /sawit del <id>      /sawit sync      /sawit stats",
    "/sawit filter [category]   show/hide a category      /sawit map   notes on the world map      /sawit minimap   notes on the minimap",
}

-- Handles the note commands of /sawit and help (Core:SlashCommand forwards them).
-- In: input  text after "/sawit", e.g. "add rare Mother Fang; near the cave"
function POI:SlashCommand(input)
    local cmd, rest = (input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "help" then
        for _, line in ipairs(HELP) do GA:Print(line) end
    elseif cmd == "add" then
        -- needs the word "add", so a mistyped command never becomes a note
        local cat, text = splitCategory(rest)
        local mapID, x, y = GA:GetPlayerPosition()
        if not mapID then return GA:Print("no position available here (" .. tostring(x) .. ")") end
        local title, details = splitTitle(text)
        local id, why = self:Create(details or "", cat or "other", mapID, x, y, title)
        GA:Print(id and ("added " .. id) or ("cannot add: " .. tostring(why)))
    elseif cmd == "edit" then
        local id, tail = rest:match("^(%S*)%s*(.-)$")
        local cat, text = splitCategory(tail)
        local changes = { cat = cat }
        if text ~= "" then changes.title, changes.text = splitTitle(text) end
        local ok, why = self:Edit(id, changes)
        GA:Print(ok and "updated" or ("cannot edit: " .. tostring(why)))
    elseif cmd == "del" then
        local ok, why = self:Remove(rest)
        GA:Print(ok and "deleted" or ("cannot delete: " .. tostring(why)))
    elseif cmd == "list" or cmd == "my" then
        local here, mine, n = GA:GetPlayerPosition(), cmd == "my", 0
        for _, rec in self:Iterate() do
            if (rest ~= "here" or rec.mapID == here) and (not mine or rec.author == GA.playerName) then
                n = n + 1
                GA:Print(self:Describe(rec))
            end
        end
        if not mine then
            GA:Print(n .. " note(s)")
        else
            GA:Print(n .. " note(s) by you" .. (n > 0 and "   change: /sawit edit <id> ...   remove: /sawit del <id>" or ""))
        end
    elseif cmd == "cats" then
        for _, k in ipairs(POI.CATEGORY_ORDER) do GA:Print(k, "-", POI.CATEGORIES[k].label) end
    elseif cmd == "filter" then
        local key, filters = rest:lower(), GA.db.profile.poi.filters
        if POI.CATEGORIES[key] then
            GA.POIMap:SetFilter(key, not filters[key])
        elseif key ~= "" then
            return GA:Print("unknown category '" .. rest .. "' (see /sawit cats)")
        end
        for _, k in ipairs(POI.CATEGORY_ORDER) do
            GA:Print(("%-6s %s"):format(k, filters[k] and "|cff40ff40shown|r" or "|cffff4040hidden|r"))
        end
    elseif cmd == "map" then
        GA.POIMap:SetWorldMap(not GA.db.profile.poi.showWorldMap)
        GA:Print("notes on world map: " .. (GA.db.profile.poi.showWorldMap and "shown" or "hidden"))
    elseif cmd == "minimap" then
        GA.POIMap:SetMinimap(not GA.db.profile.poi.showMinimap)
        GA:Print("notes on minimap: " .. (GA.db.profile.poi.showMinimap and "shown" or "hidden"))
    elseif cmd == "sync" then
        GA:Print(self:SendHello() and "sync hello sent" or ("cannot sync: " .. (GA:NetworkBlockReason() or "not ready")))
    elseif cmd == "stats" then
        local count, sum = self:Checksum()
        local live = 0
        for _ in self:Iterate() do live = live + 1 end
        GA:Print(("records=%d (live %d) checksum=%d"):format(count, live, sum))
        local st = GA.Comm.stats
        GA:Print(("comm: tx %d msgs/%dB, rx %d msgs/%dB, dropped %d, bad-proto %d"):format(st.txData, st.txBytes,
            st.rxData, st.rxBytes, st.dropped, st.badProto))
    else
        GA:Print("unknown command '" .. cmd .. "' (/sawit help)")
    end
end
