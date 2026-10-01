--[[
SawIt - POIMap: draws POIs on the world map and minimap ourselves via HereBeDragons-Pins (no HandyNotes).

Notes at the same 4-digit coordinate share one pin; the tooltip lists all of them. Each pin is TWO frames, one for
the world map and one for the minimap: HBD-Pins reparents an icon to whichever map it is shown on and hides it when the
world map closes, so one frame cannot be on both.

Redraw strategy: on any POI change or filter change, remove all our icons and re-add them from the index. Coalesced
to once per 0.2 s so a sync burst of many records redraws once. Fine for a few hundred notes.

Click actions: Right = delete window for the notes at that pin you may delete (DeleteDialog.lua); Shift+left = put "[Category: Title] <map pin link>" into the chat box (like shift-clicking an item);
left = post the same to guild chat; Ctrl+left = waypoint (TomTom if installed, else WoW's own map pin).
The map pin link is WoW's own (the one C_Map.GetUserWaypointHyperlink returns), built by us so no pin is placed.
The server only accepts it with Blizzard's exact colour and text (only map and coordinates may differ), so the
note's title goes in front of the link as plain text rather than inside it.
Adding from the map: Shift+right-click on the world map opens NoteDialog at that spot. Hooked with Blizzard's
WorldMapFrame:AddCanvasClickHandler; returning true stops the click, so the map does not also zoom out. Other map
bindings (1.60.1 source): right-click = zoom out, Ctrl+left = Blizzard map pin, Shift+left = world quests,
Alt+left = GM teleport.
]]
local _, ns = ...
local GA = ns.addon
local POI = GA.POI

local POIMap = GA:NewModule("POIMap", "AceEvent-3.0")
GA.POIMap = POIMap

local REF = "SawItNotes"
local WORLD_SIZE, MINI_SIZE = 22, 16
local MEDIA = "Interface\\AddOns\\SawIt\\Media\\"
local floor = math.floor

local function toCoord(x, y) return floor(x * 10000 + 0.5) * 10000 + floor(y * 10000 + 0.5) end

---------------------------------------------------------------------------
-- index: byMap[uiMapID][coord] = { rec, rec, ... }
---------------------------------------------------------------------------
function POIMap:Index()
    if self.byMap and not self.dirty then return self.byMap end
    local by = {}
    for _, rec in POI:Iterate() do
        local m = by[rec.mapID]
        if not m then m = {}; by[rec.mapID] = m end
        local c = toCoord(rec.x, rec.y)
        local l = m[c]
        if not l then l = {}; m[c] = l end
        l[#l + 1] = rec
    end
    self.byMap, self.dirty = by, false
    return by
end

-- Only the notes in a group whose category is not filtered out.
local function visible(list)
    local filters, out = GA.db.profile.poi.filters, {}
    for _, rec in ipairs(list) do if filters[rec.cat] then out[#out + 1] = rec end end
    return out
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------
-- Places WoW's own map pin (the one Ctrl+left-click on the world map places); used for waypoints without TomTom.
-- Returns true if it was placed. Side effect: replaces the player's own map pin; the game allows only one.
function POIMap.PlaceMapPin(mapID, x, y)
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then return false end
    return (pcall(function() C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y)) end))
end

-- Same string as C_Map.GetUserWaypointHyperlink() for a pin at this spot (format from the client binary:
-- "|c%s|Hworldmap:%d:%u:%u|h[%s]|h|r", coordinates x 10000). Must match it exactly or the server drops the message.
local MAP_PIN_TEXT = "|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a Map Pin Location"
function POIMap.MapPinLink(mapID, x, y)
    return ("|cffffff00|Hworldmap:%d:%d:%d|h[%s]|h|r"):format(mapID, floor(x * 10000 + 0.5), floor(y * 10000 + 0.5), _G.MAP_PIN_HYPERLINK or MAP_PIN_TEXT)
end

-- "[Rare spawn: Mother Fang] [Map Pin Location]"; the second part is the clickable map pin.
function POIMap.ChatText(rec)
    return ("[%s: %s] %s"):format(POI.CATEGORIES[rec.cat].label, POI.DisplayTitle(rec), POIMap.MapPinLink(rec.mapID, rec.x, rec.y))
end

-- Into the open chat box at the cursor, like shift-clicking an item; opens the chat box if none is open.
function POIMap.InsertInChat(rec)
    local text = POIMap.ChatText(rec)
    local CFU = _G.ChatFrameUtil
    local insert = (CFU and CFU.InsertLink) or _G.ChatEdit_InsertLink
    if insert and insert(text) then return end
    local open = (CFU and CFU.OpenChat) or _G.ChatFrame_OpenChat
    if open then open(text) end
end

function POIMap.ShareToGuild(rec)
    local msg = POIMap.ChatText(rec)
    if rec.title and rec.title ~= "" and rec.text ~= "" then msg = msg .. " " .. rec.text end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if #msg > 255 then   -- the link comes first and is ~110 bytes, so this only cuts the details; keep UTF-8 whole
        local i = 256
        while i > 1 and msg:byte(i) >= 128 and msg:byte(i) < 192 do i = i - 1 end
        msg = msg:sub(1, i - 1)
    end
    send(msg, "GUILD")
end

-- Waypoint: TomTom if installed, otherwise WoW's own map pin, tracked (on-screen marker with distance) where the
-- client has C_SuperTrack. Also used by Positions for guildmate dots.
function POIMap.WaypointTo(mapID, x, y, title)
    local TT = _G.TomTom
    if TT and TT.AddWaypoint then
        TT:AddWaypoint(mapID, x, y, { title = title, from = "SawIt", persistent = false })
    elseif POIMap.PlaceMapPin(mapID, x, y) then
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
        GA:Print(("Map pin set: %s %.1f, %.1f"):format(POI.MapName(mapID), x * 100, y * 100))
    else
        GA:Print("Could not set a waypoint: no TomTom and no map pin API on this client.")
    end
end

function POIMap.SetWaypoint(rec) POIMap.WaypointTo(rec.mapID, rec.x, rec.y, POI.DisplayTitle(rec)) end

---------------------------------------------------------------------------
-- pin frames
---------------------------------------------------------------------------
local function hex(c) return tonumber(c:sub(1, 2), 16) / 255, tonumber(c:sub(3, 4), 16) / 255, tonumber(c:sub(5, 6), 16) / 255 end

local function onEnter(self)
    local list = self.recs
    if not list then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    for i, rec in ipairs(list) do
        local c = POI.CATEGORIES[rec.cat]
        if i > 1 then GameTooltip:AddLine(" ") end
        GameTooltip:AddLine(c.label, hex(c.color))
        GameTooltip:AddLine(POI.DisplayTitle(rec), 1, 1, 1)
        if rec.title and rec.title ~= "" and rec.text ~= "" then GameTooltip:AddLine(rec.text, 0.85, 0.85, 0.85, true) end
        GameTooltip:AddLine("by " .. rec.author .. (rec.updatedBy ~= rec.author and (", edited by " .. rec.updatedBy) or ""), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.8, 0.5)
    GameTooltip:AddLine("Click: share to guild chat", 0.5, 0.8, 0.5)
    GameTooltip:AddLine("Ctrl-click: " .. (GA.IsAddOnLoaded("TomTom") and "TomTom waypoint" or "set map pin"), 0.5, 0.8, 0.5)
    for _, rec in ipairs(list) do
        if POI:CanModify(rec) then GameTooltip:AddLine("Right-click: delete", 0.5, 0.8, 0.5); break end
    end
    GameTooltip:Show()
end

local function onClick(self, button)
    local rec = self.recs and self.recs[1]
    if not rec then return end
    if button == "RightButton" then
        GameTooltip:Hide()
        return GA.DeleteDialog:Open(self.recs)
    end
    if button ~= "LeftButton" then return end
    if IsShiftKeyDown() then POIMap.InsertInChat(rec)
    elseif IsControlKeyDown() then POIMap.SetWaypoint(rec)
    else POIMap.ShareToGuild(rec) end
end

local pool, used = {}, {}

local function acquire(size)
    local f = table.remove(pool)
    if not f then
        f = CreateFrame("Button", nil, UIParent)
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetAllPoints()
        f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the icon's built-in border
        -- round pin: clip the square icon to a disc and draw a black-edged ring in the category colour over the edge
        if f.CreateMaskTexture and f.icon.AddMaskTexture then
            local mask = f:CreateMaskTexture()
            mask:SetTexture(MEDIA .. "circle", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(f.icon)
            f.icon:AddMaskTexture(mask)
        end
        f.ring = f:CreateTexture(nil, "OVERLAY")
        f.ring:SetTexture(MEDIA .. "pinring")   -- white band between black outlines; only the band takes the tint
        f.ring:SetAllPoints()
        f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.count:SetPoint("BOTTOMRIGHT", 3, -3)
        f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        f:SetScript("OnEnter", onEnter)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f:SetScript("OnClick", onClick)
    end
    f:SetSize(size, size)
    used[#used + 1] = f
    return f
end

local function setup(f, list)
    f.recs = list
    local c = POI.CATEGORIES[list[1].cat]
    f.icon:SetTexture(c.icon)
    f.ring:SetVertexColor(hex(c.color))
    f.count:SetText(#list > 1 and #list or "")
end

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------
function POIMap:Redraw()
    self.pending = false
    local pins = GA.HBDPins
    if not pins then return end
    pins:RemoveAllWorldMapIcons(REF)
    pins:RemoveAllMinimapIcons(REF)
    for i = #used, 1, -1 do
        local f = used[i]
        f:Hide()
        f.recs = nil
        pool[#pool + 1] = f
        used[i] = nil
    end
    local p = GA.db.profile.poi
    local drawn = 0
    for mapID, groups in pairs(self:Index()) do
        for _, list in pairs(groups) do
            local vis = visible(list)
            if #vis > 0 then
                local x, y = vis[1].x, vis[1].y
                if p.showWorldMap then
                    local w = acquire(WORLD_SIZE)
                    setup(w, vis)
                    if pins:AddWorldMapIconMap(REF, w, mapID, x, y) then drawn = drawn + 1 end
                end
                if p.showMinimap then
                    local m = acquire(MINI_SIZE)
                    setup(m, vis)
                    pins:AddMinimapIconMap(REF, m, mapID, x, y, false, false)
                end
            end
        end
    end
    GA:Debug("POIMap: drew", drawn, "note pin(s)")
end

function POIMap:Refresh()
    self.dirty = true
    if self.pending then return end
    self.pending = true
    C_Timer.After(0.2, function() self:Redraw() end)
end

---------------------------------------------------------------------------
-- filters (used by /sawit filter, /sawit map and /sawit minimap)
---------------------------------------------------------------------------
function POIMap:SetFilter(cat, on)
    GA.db.profile.poi.filters[cat] = on and true or false
    self:Refresh()
end

function POIMap:SetMinimap(on)
    GA.db.profile.poi.showMinimap = on and true or false
    self:Refresh()
end

function POIMap:SetWorldMap(on)
    GA.db.profile.poi.showWorldMap = on and true or false
    self:UpdateMapButton()
    self:Refresh()
end

---------------------------------------------------------------------------
-- show/hide button on the world map. Blizzard stacks its 32x32 buttons (tracking options, map pin) down the
-- top-right corner of the canvas at x -4; ours sits just left of that column so it never overlaps them.
---------------------------------------------------------------------------
function POIMap:UpdateMapButton()
    local b = self.mapButton
    if not b then return end
    local on = GA.db.profile.poi.showWorldMap
    b.icon:SetDesaturated(not on)
    b.icon:SetAlpha(on and 1 or 0.5)
end

function POIMap:CreateMapButton()
    local map = _G.WorldMapFrame
    if self.mapButton or not map then return end
    local canvas = map.GetCanvasContainer and map:GetCanvasContainer() or map
    local b = CreateFrame("Button", nil, map)
    b:SetSize(32, 32)
    b:SetFrameStrata("HIGH")
    b:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -40, -2)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexture("Interface\\AddOns\\SawIt\\Media\\icon")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function()
        POIMap:SetWorldMap(not GA.db.profile.poi.showWorldMap)
        if GameTooltip:IsOwned(b) then b:GetScript("OnEnter")(b) end
    end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(b, "ANCHOR_LEFT")
        GameTooltip:AddLine("Guild notes")
        local on = GA.db.profile.poi.showWorldMap
        GameTooltip:AddLine(on and "|cff40ff40Shown|r on the map" or "|cffff4040Hidden|r on the map", 1, 1, 1)
        GameTooltip:AddLine("Click: " .. (on and "hide" or "show") .. " notes", 0.5, 0.8, 0.5)
        GameTooltip:AddLine("Shift+right-click the map: add a note", 0.5, 0.8, 0.5)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.mapButton = b
    self:UpdateMapButton()
end

---------------------------------------------------------------------------
-- Shift+right-click on the world map: add a note there
---------------------------------------------------------------------------
local CLICK_PRIORITY = 80   -- below Blizzard's waypoint (90) and GM teleport (100) handlers; they use other buttons anyway

function POIMap.OnMapClick(canvas, button, x, y)
    if button ~= "RightButton" or not IsShiftKeyDown() then return false end
    GA.NoteDialog:OpenAt(canvas:GetMapID(), x, y)
    return true
end

function POIMap:HookWorldMap()
    local map = _G.WorldMapFrame
    if self.mapHooked or not (map and map.AddCanvasClickHandler) then return end
    map:AddCanvasClickHandler(POIMap.OnMapClick, CLICK_PRIORITY)
    self.mapHooked = true
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------
function POIMap:OnEnable()
    self:HookWorldMap()
    self:CreateMapButton()
    self.dirty = true
    self:RegisterMessage("GUILDATLAS_POI_CHANGED", "Refresh")
    -- the guild (and so the note store) is only known after login
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "Refresh")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "Refresh")
    if not GA.HBDPins then GA:Print("HereBeDragons-Pins missing: notes will not be drawn on the map.") end
end

POIMap._used = used   -- for tests
