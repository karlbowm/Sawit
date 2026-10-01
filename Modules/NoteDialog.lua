--[[
SawIt - NoteDialog: the window to add a note (category, title, details).
  Open()             at the player's position (minimap button left-click)
  OpenAt(map, x, y)  at a clicked world-map spot (Shift+right-click on the world map, hooked in POIMap.lua)

The position is captured when the window opens, so the note lands where you were (or clicked) at that moment.
The category picker is a hand-built list of buttons rather than a dropdown (UIDropDownMenu or the Menu API): fewer
moving parts, and it works the same on every client. Only InputBoxTemplate and UIPanelButtonTemplate are used.
]]
local _, ns = ...
local GA = ns.addon
local POI = GA.POI

local Dialog = GA:NewModule("NoteDialog")
GA.NoteDialog = Dialog

local FRAME_NAME = "SawItNoteDialog"
local frame
local pos           -- { map, x, y } captured on open
local cat = "other" -- selected category; kept between notes

-- In: key  category.  Out: "<icon> Label" in the category's colour
local function categoryText(key)
    local c = POI.CATEGORIES[key]
    return ("|T%s:14|t |cff%s%s|r"):format(c.icon, c.color, c.label)
end

-- Selects a category and closes the list.
local function setCategory(key)
    cat = key
    frame.catButton:SetText(categoryText(key))
    frame.catList:Hide()
end

-- Add button / Enter: creates the note; on success closes the window, otherwise keeps it open (e.g. no title).
local function submit()
    local id, why = POI:Create(frame.edit:GetText(), cat, pos.map, pos.x, pos.y, frame.title:GetText())
    if not id then
        GA:Print("cannot add: " .. tostring(why))   -- e.g. empty-text: keep the window open
        return
    end
    GA:Print(("added note %s: %s"):format(id, POI:Describe(POI:Get(id))))
    frame:Hide()
end

-- Out: the window frame (built once, on first open)
local function build()
    local f = CreateFrame("Frame", FRAME_NAME, UIParent)
    f:SetSize(320, 196)
    f:SetPoint("CENTER", 0, 120)
    f:SetFrameStrata("FULLSCREEN_DIALOG")   -- above the world map, which can be HIGH or FULLSCREEN
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, FRAME_NAME)   -- Escape closes it

    local border = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    border:SetAllPoints()
    border:SetColorTexture(0.5, 0.5, 0.5, 1)
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Add guild note")

    f.where = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.where:SetPoint("TOPRIGHT", -12, -12)

    local catLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    catLabel:SetPoint("TOPLEFT", 12, -38)
    catLabel:SetText("Category")

    f.catButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.catButton:SetSize(200, 22)
    f.catButton:SetPoint("TOPRIGHT", -12, -34)
    f.catButton:SetScript("OnClick", function()
        if f.catList:IsShown() then f.catList:Hide() else f.catList:Show() end
    end)

    -- category list, drawn over the rest of the window below the category button
    local list = CreateFrame("Frame", nil, f)
    list:SetFrameLevel(f:GetFrameLevel() + 10)
    list:SetPoint("TOPLEFT", f.catButton, "BOTTOMLEFT", 0, -2)
    list:SetSize(200, #POI.CATEGORY_ORDER * 20 + 4)
    local lbg = list:CreateTexture(nil, "BACKGROUND")
    lbg:SetAllPoints()
    lbg:SetColorTexture(0, 0, 0, 0.95)
    for i, key in ipairs(POI.CATEGORY_ORDER) do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(196, 20)
        b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 20)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.15)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        t:SetPoint("LEFT", 6, 0)
        t:SetText(categoryText(key))
        b:SetScript("OnClick", function() setCategory(key) end)
    end
    list:Hide()
    f.catList = list

    local function label(text, y)
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l:SetPoint("TOPLEFT", 12, y)
        l:SetText(text)
    end
    local function input(y, maxLetters)
        local e = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        e:SetSize(290, 22)
        e:SetPoint("TOPLEFT", 18, y)
        e:SetAutoFocus(false)
        e:SetMaxLetters(maxLetters)
        e:SetScript("OnEnterPressed", submit)
        e:SetScript("OnEscapePressed", function() f:Hide() end)
        return e
    end
    label("Title", -64)
    f.title = input(-78, POI.MAX_TITLE)
    label("Details (optional)", -106)
    f.edit = input(-120, 120)
    f.title:SetScript("OnTabPressed", function() f.edit:SetFocus() end)
    f.edit:SetScript("OnTabPressed", function() f.title:SetFocus() end)

    local add = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    add:SetSize(100, 22)
    add:SetPoint("BOTTOMRIGHT", -12, 12)
    add:SetText("Add")
    add:SetScript("OnClick", submit)
    f.addButton = add

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(100, 22)
    cancel:SetPoint("RIGHT", add, "LEFT", -8, 0)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function() f.catList:Hide(); f.title:ClearFocus(); f.edit:ClearFocus() end)
    return f
end

-- Notes only make sense on zone-level maps (zone, dungeon, micro, orphan); not on the world or a continent,
-- where the pin would sit on that overview map only.
-- In: mapID.  Out: true for zone-level maps
local function isZoneMap(mapID)
    local info = C_Map.GetMapInfo(mapID)
    return info ~= nil and info.mapType ~= nil and info.mapType >= Enum.UIMapType.Zone
end

-- Opens the window at the player's position (or says why it can't).
function Dialog:Open()
    local mapID, x, y = GA:GetPlayerPosition()
    if not mapID then return GA:Print("No position available here (" .. tostring(x) .. ").") end
    self:OpenAt(mapID, x, y)
end

-- Opens the window for a note at a spot; refuses outside a guild (test mode counts as one) and above zone level.
-- In: mapID, x, y (0..1)
function Dialog:OpenAt(mapID, x, y)
    if not GA:InGuild() then
        return GA:Print("You need to be in a guild to add notes (for testing: set GA.TEST_MODE = true in Core/Core.lua and /reload).")
    end
    if type(x) ~= "number" or type(y) ~= "number" or x < 0 or x > 1 or y < 0 or y > 1 then return end
    if not isZoneMap(mapID) then return GA:Print("Zoom in to a zone to add a note there.") end
    frame = frame or build()
    pos = { map = mapID, x = x, y = y }
    frame.where:SetText(("%s  %.1f, %.1f"):format(POI.MapName(mapID), x * 100, y * 100))
    setCategory(cat)                 -- keeps the last used category
    frame.title:SetText("")
    frame.edit:SetText("")
    frame:Show()
    frame.title:SetFocus()
end

-- Minimap button: closes the window if open, otherwise opens it at the player's position.
function Dialog:Toggle()
    if frame and frame:IsShown() then frame:Hide() else self:Open() end
end

Dialog.GetFrame = function() return frame end   -- for tests
