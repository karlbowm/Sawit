--[[
SawIt - UI: building blocks shared by the windows (NoteDialog, DeleteDialog, SecretDialog), so they all look and
behave the same: a dark box with a grey edge, draggable, closed by Escape (UISpecialFrames), and drawn above the world
map (strata FULLSCREEN_DIALOG; the map itself can be HIGH or FULLSCREEN). Not StaticPopup: that sits below the map.
Each window adds its own content and its own OnHide.
]]
local _, ns = ...
local GA = ns.addon

-- Creates a hidden window in the middle of the screen.
-- In:  name  global frame name (Escape needs one);  width, height  pixels;  heading  text at the top left
-- Out: the frame; frame.heading is the heading's FontString
function GA.CreateWindow(name, width, height, heading)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(width, height)
    f:SetPoint("CENTER", 0, 120)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, name)

    local border = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    border:SetAllPoints()
    border:SetColorTexture(0.5, 0.5, 0.5, 1)
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)

    f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.heading:SetPoint("TOPLEFT", 12, -10)
    f.heading:SetText(heading)
    return f
end

-- Creates a standard button (UIPanelButtonTemplate, 22 px high); the caller places it.
-- In:  parent;  text;  width  pixels;  onClick  function
-- Out: the button
function GA.CreateButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end
