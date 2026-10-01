--[[
SawIt - DeleteDialog: small window to delete notes, opened by right-clicking a note pin (POIMap.lua).
  Open(recs)   recs = the notes at that pin; only the ones the player may delete (author, or officer) are listed,
               at most MAX_ROWS

The window is the confirmation: right-click only opens it, a note goes only when its Delete button is pressed.
One row per note, so a pin holding several notes can have just one of them removed. The list holds note ids, not
records, so a note changed or deleted by sync while the window is open is handled by POI:Remove's own checks.
Built with GA.CreateWindow (Core/UI.lua), like the other windows.
]]
local _, ns = ...
local GA = ns.addon
local POI = GA.POI

local Dialog = GA:NewModule("DeleteDialog")
GA.DeleteDialog = Dialog

local FRAME_NAME = "SawItDeleteDialog"
local WIDTH, ROW_H, MAX_ROWS = 340, 26, 8
local frame
local rows = {}      -- row frames, created as needed and reused
local listed = {}    -- { id, label } per note in the window, in row order

-- In: e  a listed entry.  Out: "Category  Title" in the category's colour; just the label if the note is gone
local function rowText(e)
    local rec = POI:Get(e.id)
    if not rec or rec.deleted then return e.label end   -- deleted by sync while the window is open
    local c = POI.CATEGORIES[rec.cat]
    return ("|cff%s%s|r  %s"):format(c.color, c.label, POI.DisplayTitle(rec))
end

-- Shows one row per listed note and sizes the window; closes it when none is left.
local function layout()
    if #listed == 0 then return frame:Hide() end
    for i, row in ipairs(rows) do
        if listed[i] then row.text:SetText(rowText(listed[i])); row:Show() else row:Hide() end
    end
    frame.heading:SetText(#listed == 1 and "Delete this note?" or "Delete which note?")
    frame:SetHeight(34 + #listed * ROW_H + 44)
end

-- Delete button of row i: removes that note (POI:Remove checks permission and existence again).
local function deleteRow(i)
    local e = table.remove(listed, i)
    if not e then return end
    local ok, why = POI:Remove(e.id)
    GA:Print(ok and ("deleted note: " .. e.label) or ("cannot delete: " .. tostring(why)))
    layout()
end

-- In: i.  Out: row frame i (text + Delete button), created on first use
local function getRow(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, frame)
    row:SetSize(WIDTH - 24, ROW_H)
    row:SetPoint("TOPLEFT", 12, -34 - (i - 1) * ROW_H)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", 0, 0)
    row.text:SetPoint("RIGHT", -88, 0)
    row.text:SetJustifyH("LEFT")
    row.button = GA.CreateButton(row, "Delete", 80, function() deleteRow(i) end)
    row.button:SetPoint("RIGHT", 0, 0)
    rows[i] = row
    return row
end

-- Out: the window frame (built once, on first open)
local function build()
    local f = GA.CreateWindow(FRAME_NAME, WIDTH, 120, "")   -- heading and height are set by layout()
    f.cancelButton = GA.CreateButton(f, "Cancel", 100, function() f:Hide() end)
    f.cancelButton:SetPoint("BOTTOMRIGHT", -12, 12)
    return f
end

-- Opens the window for the notes at a pin, or says that none of them may be deleted by us.
-- In: recs  the notes at the pin
function Dialog:Open(recs)
    local mine = {}
    for _, rec in ipairs(recs) do
        if POI:CanModify(rec) and #mine < MAX_ROWS then mine[#mine + 1] = rec end
    end
    if #mine == 0 then return GA:Print("Only the note's author or a guild officer can delete it.") end
    frame = frame or build()
    wipe(listed)
    for i, rec in ipairs(mine) do
        getRow(i)
        listed[i] = { id = rec.id, label = POI.DisplayTitle(rec) }
    end
    frame:Show()
    layout()
end

Dialog.GetFrame = function() return frame end   -- for tests
Dialog._rows, Dialog._listed = rows, listed     -- for tests
