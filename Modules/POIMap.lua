--[[
SawIt - POIMap: draws the notes on the world map and minimap (HereBeDragons-Pins), and everything you can do with a
note pin. Also the notes button on the world map and Shift+right-click on the map to add a note.

Pins: notes at the same 4-digit coordinate share one pin; the tooltip lists all of them, the pin shows a count. Each pin
is TWO frames, one per map: HBD-Pins reparents an icon to the map it is shown on and hides it when the world map
closes, so one frame cannot be on both. Redraw: on any note or filter change, remove all our pins and add them again;
coalesced to once per 0.2 s, so a sync burst redraws once. Fine for a few hundred notes.

Clicks on a pin:
  Shift+left  put "[Category: Title] <map pin link>" into the chat box, like shift-clicking an item
  left        post the same to guild chat
  Ctrl+left   waypoint: TomTom if installed, else WoW's own map pin
  right       delete window for the notes there you may delete (DeleteDialog.lua)
The map pin link is WoW's own (what C_Map.GetUserWaypointHyperlink returns), built here so no pin gets placed. The
server only accepts it with Blizzard's exact colour and text (only map and coordinates may differ), so the note's
title goes in front of the link as plain text.

Shift+right-click on the world map opens the note window there, via WorldMapFrame:AddCanvasClickHandler; returning
true stops the click, so the map doesn't also zoom out. Other map bindings (1.60.1 source): right-click = zoom out,
Ctrl+left = Blizzard map pin, Shift+left = world quests, Alt+left = GM teleport.
]]
local _, ns = ...
local GA = ns.addon
local POI = GA.POI

local POIMap = GA:NewModule("POIMap", "AceEvent-3.0")
GA.POIMap = POIMap

local REF = "SawItNotes"           -- our pins' group in HBD-Pins
local WORLD_SIZE, MINI_SIZE = 22, 16
local MEDIA = "Interface\\AddOns\\SawIt\\Media\\"
local floor = math.floor

-- In: v  coordinate 0..1.  Out: integer 0..9999 (the precision notes are stored with)
local function q(v) return floor(v * 10000 + 0.5) end

-- In: c  "rrggbb".  Out: r, g, b  (0..1)
local function rgb(c) return tonumber(c:sub(1, 2), 16) / 255, tonumber(c:sub(3, 4), 16) / 255, tonumber(c:sub(5, 6), 16) / 255 end

---------------------------------------------------------------------------
-- chat links and waypoints
---------------------------------------------------------------------------
-- WoW's map pin link for a spot: the same string as C_Map.GetUserWaypointHyperlink() (format from the client
-- binary: "|c%s|Hworldmap:%d:%u:%u|h[%s]|h|r", coordinates x 10000). Must match exactly or the server drops it.
-- In: mapID, x, y (0..1).  Out: link string
local MAP_PIN_TEXT = "|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a Map Pin Location"   -- MAP_PIN_HYPERLINK in English
function POIMap.MapPinLink(mapID, x, y)
    return ("|cffffff00|Hworldmap:%d:%d:%d|h[%s]|h|r"):format(mapID, q(x), q(y), _G.MAP_PIN_HYPERLINK or MAP_PIN_TEXT)
end

-- In: rec.  Out: "[Rare spawn: Mother Fang] <map pin link>"
function POIMap.ChatText(rec)
    return ("[%s: %s] %s"):format(POI.CATEGORIES[rec.cat].label, POI.DisplayTitle(rec), POIMap.MapPinLink(rec.mapID, rec.x, rec.y))
end

-- Puts a note's chat text at the cursor in the open chat box, like shift-clicking an item; opens the box if needed.
-- In: rec
function POIMap.InsertInChat(rec)
    local text = POIMap.ChatText(rec)
    local CFU = _G.ChatFrameUtil
    local insert = (CFU and CFU.InsertLink) or _G.ChatEdit_InsertLink
    if insert and insert(text) then return end
    local open = (CFU and CFU.OpenChat) or _G.ChatFrame_OpenChat
    if open then open(text) end
end

-- Posts a note to guild chat: chat text, then the details, cut to the 255-byte chat limit.
-- In: rec
function POIMap.ShareToGuild(rec)
    local msg = POIMap.ChatText(rec)
    local details = POI.Details(rec)
    if details ~= "" then msg = msg .. " " .. details end
    if #msg > 255 then   -- the link comes first (~110 bytes), so only the details get cut; keep UTF-8 characters whole
        local i = 256
        while i > 1 and msg:byte(i) >= 128 and msg:byte(i) < 192 do i = i - 1 end
        msg = msg:sub(1, i - 1)
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    send(msg, "GUILD")
end

-- Places WoW's own map pin (as Ctrl+left-click on the map does). Replaces the player's own pin: there is only one.
-- In: mapID, x, y (0..1).  Out: true if placed (false on maps that don't allow pins, or if the API is missing)
function POIMap.PlaceMapPin(mapID, x, y)
    return (pcall(function() C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y)) end))
end

-- Sets a waypoint: TomTom if installed, otherwise WoW's map pin, tracked (on-screen marker with distance) where the
-- client allows it. Also used for guildmate dots (Positions.lua).
-- In: mapID, x, y (0..1), title  shown by TomTom
function POIMap.WaypointTo(mapID, x, y, title)
    local TT = _G.TomTom
    if TT and TT.AddWaypoint then
        TT:AddWaypoint(mapID, x, y, { title = title, from = "SawIt", persistent = false })
    elseif POIMap.PlaceMapPin(mapID, x, y) then
        pcall(function() C_SuperTrack.SetSuperTrackedUserWaypoint(true) end)
        GA:Print(("Map pin set: %s %.1f, %.1f"):format(POI.MapName(mapID), x * 100, y * 100))
    else
        GA:Print("Could not set a waypoint here (no TomTom, and WoW allows no map pin on this map).")
    end
end

---------------------------------------------------------------------------
-- pin frames
---------------------------------------------------------------------------
-- Tooltip of a pin: every note there, then what the clicks do.
local function onEnter(f)
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    local mayDelete = false
    for i, rec in ipairs(f.recs) do
        local c, details = POI.CATEGORIES[rec.cat], POI.Details(rec)
        if i > 1 then GameTooltip:AddLine(" ") end
        GameTooltip:AddLine(c.label, rgb(c.color))
        GameTooltip:AddLine(POI.DisplayTitle(rec), 1, 1, 1)
        if details ~= "" then GameTooltip:AddLine(details, 0.85, 0.85, 0.85, true) end
        local by = rec.updatedBy ~= rec.author and (", edited by " .. rec.updatedBy) or ""
        GameTooltip:AddLine("by " .. rec.author .. by, 0.6, 0.6, 0.6)
        mayDelete = mayDelete or POI:CanModify(rec)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.8, 0.5)
    GameTooltip:AddLine("Click: share to guild chat", 0.5, 0.8, 0.5)
    GameTooltip:AddLine("Ctrl-click: " .. (GA.IsAddOnLoaded("TomTom") and "TomTom waypoint" or "set map pin"), 0.5, 0.8, 0.5)
    if mayDelete then GameTooltip:AddLine("Right-click: delete", 0.5, 0.8, 0.5) end
    GameTooltip:Show()
end

-- Click on a pin; the actions use the first note there (the delete window lists all of them).
local function onClick(f, button)
    local rec = f.recs[1]
    if button == "RightButton" then
        GameTooltip:Hide()
        GA.DeleteDialog:Open(f.recs)
    elseif IsShiftKeyDown() then
        POIMap.InsertInChat(rec)
    elseif IsControlKeyDown() then
        POIMap.WaypointTo(rec.mapID, rec.x, rec.y, POI.DisplayTitle(rec))
    else
        POIMap.ShareToGuild(rec)
    end
end

local pool, used = {}, {}   -- pin frames: free ones, and the ones on the maps now

-- A pin frame showing these notes, from the pool or new: round icon of the first note's category, ring in its
-- colour, and a count when there are several.
-- In: size  pixels;  recs  the notes at this spot.  Out: frame
local function acquire(size, recs)
    local f = table.remove(pool)
    if not f then
        f = CreateFrame("Button", nil, UIParent)
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetAllPoints()
        f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the icon's built-in border
        if f.CreateMaskTexture and f.icon.AddMaskTexture then   -- clip to a disc; without masks the icon stays square
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
    local c = POI.CATEGORIES[recs[1].cat]
    f.recs = recs
    f:SetSize(size, size)
    f.icon:SetTexture(c.icon)
    f.ring:SetVertexColor(rgb(c.color))
    f.count:SetText(#recs > 1 and #recs or "")
    used[#used + 1] = f
    return f
end

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------
-- Out: the notes whose category isn't filtered out, grouped by spot: groups[mapID][coordKey] = { rec, ... }
local function visibleGroups()
    local filters, groups = GA.db.profile.poi.filters, {}
    for _, rec in POI:Iterate() do
        if filters[rec.cat] then
            local spots = groups[rec.mapID] or {}
            groups[rec.mapID] = spots
            local key = q(rec.x) * 10000 + q(rec.y)
            spots[key] = spots[key] or {}
            table.insert(spots[key], rec)
        end
    end
    return groups
end

-- Removes all our pins and draws them again from the notes, filters and show settings.
function POIMap:Redraw()
    self.pending = false
    local pins = GA.HBDPins
    pins:RemoveAllWorldMapIcons(REF)
    pins:RemoveAllMinimapIcons(REF)
    for i = #used, 1, -1 do
        used[i]:Hide()
        pool[#pool + 1] = table.remove(used, i)
    end
    local p = GA.db.profile.poi
    for mapID, spots in pairs(visibleGroups()) do
        for _, recs in pairs(spots) do
            local x, y = recs[1].x, recs[1].y
            if p.showWorldMap then pins:AddWorldMapIconMap(REF, acquire(WORLD_SIZE, recs), mapID, x, y) end
            if p.showMinimap then pins:AddMinimapIconMap(REF, acquire(MINI_SIZE, recs), mapID, x, y, false, false) end
        end
    end
    GA:Debug("POIMap: drew", #used, "pin frame(s)")
end

-- Redraws soon (0.2 s), once, however often it is called in between.
function POIMap:Refresh()
    if self.pending then return end
    self.pending = true
    C_Timer.After(0.2, function() self:Redraw() end)
end

---------------------------------------------------------------------------
-- settings (/sawit filter, /sawit map, /sawit minimap and the map button)
---------------------------------------------------------------------------
-- In: cat  category key;  on  true = show its notes
function POIMap:SetFilter(cat, on)
    GA.db.profile.poi.filters[cat] = on and true or false
    self:Refresh()
end

-- In: on  true = show note pins on the minimap
function POIMap:SetMinimap(on)
    GA.db.profile.poi.showMinimap = on and true or false
    self:Refresh()
end

-- In: on  true = show note pins on the world map
function POIMap:SetWorldMap(on)
    GA.db.profile.poi.showWorldMap = on and true or false
    self:UpdateMapButton()
    self:Refresh()
end

---------------------------------------------------------------------------
-- world map: notes button and Shift+right-click
---------------------------------------------------------------------------
-- Greys the map button out while note pins are hidden on the world map.
function POIMap:UpdateMapButton()
    local on = GA.db.profile.poi.showWorldMap
    self.mapButton.icon:SetDesaturated(not on)
    self.mapButton.icon:SetAlpha(on and 1 or 0.5)
end

local function mapButtonTooltip(b)
    local on = GA.db.profile.poi.showWorldMap
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    GameTooltip:AddLine("Guild notes")
    GameTooltip:AddLine(on and "|cff40ff40Shown|r on the map" or "|cffff4040Hidden|r on the map", 1, 1, 1)
    GameTooltip:AddLine("Click: " .. (on and "hide" or "show") .. " notes", 0.5, 0.8, 0.5)
    GameTooltip:AddLine("Shift+right-click the map: add a note", 0.5, 0.8, 0.5)
    GameTooltip:Show()
end

-- Shift+right-click on the map canvas opens the note window at that spot.
-- In: canvas, button, x, y (as Blizzard's canvas click handlers get them).  Out: true when the click was ours
function POIMap.OnMapClick(canvas, button, x, y)
    if button ~= "RightButton" or not IsShiftKeyDown() then return false end
    GA.NoteDialog:OpenAt(canvas:GetMapID(), x, y)
    return true
end

-- Adds the notes button (top right of the map canvas, just left of Blizzard's column of 32x32 buttons at x -4) and
-- the Shift+right-click handler. Once.
local CLICK_PRIORITY = 80   -- below Blizzard's waypoint (90) and GM teleport (100) handlers; they use other buttons
function POIMap:SetupWorldMap()
    if self.mapButton then return end
    local map = WorldMapFrame   -- exists at load: HereBeDragons-Pins already uses it
    map:AddCanvasClickHandler(POIMap.OnMapClick, CLICK_PRIORITY)
    local b = CreateFrame("Button", nil, map)
    b:SetSize(32, 32)
    b:SetFrameStrata("HIGH")
    b:SetPoint("TOPRIGHT", map.GetCanvasContainer and map:GetCanvasContainer() or map, "TOPRIGHT", -40, -2)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    b.icon:SetTexture(MEDIA .. "icon")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function()
        POIMap:SetWorldMap(not GA.db.profile.poi.showWorldMap)
        if GameTooltip:IsOwned(b) then mapButtonTooltip(b) end
    end)
    b:SetScript("OnEnter", mapButtonTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.mapButton = b
    self:UpdateMapButton()
end

-- AceAddon callback: world map setup, and redraws on note changes and once the guild is known.
function POIMap:OnEnable()
    self:SetupWorldMap()
    self:RegisterMessage("SAWIT_NOTES_CHANGED", "Refresh")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "Refresh")   -- the guild (and so its notes) is only known after login
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "Refresh")
end
