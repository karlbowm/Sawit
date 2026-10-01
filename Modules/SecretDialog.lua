--[[
SawIt - SecretDialog: window to enter the guild secret (/sawit secret).

A window rather than "/sawit secret <text>" so the secret never lands in the chat edit box history.
Generate makes a random 20-character secret for an officer to copy and hand out (outside public chat).
Save derives the key (a short pause, see Crypto.KDF_ITER) and shows the check code guildmates compare.
Key presses feed Crypto's entropy pool, so a generated secret gets some timing noise on top of the clock and cursor.
]]
local _, ns = ...
local GA = ns.addon

local Dialog = GA:NewModule("SecretDialog")
GA.SecretDialog = Dialog

local FRAME_NAME = "SawItSecretDialog"
local frame

-- Shows the guild, whether a secret is set (with its check code), and enables Remove only when one is.
local function refresh()
    local check = GA:GuildSecretCheck()
    frame.guild:SetText(GA:GetGuildName() or "")
    frame.status:SetText(check and ("Current secret: |cff40ff40set|r, check code |cffffffff%s|r"):format(check)
        or "Current secret: |cffff4040not set|r - nothing is shared with your guild")
    frame.removeButton:SetEnabled(check ~= nil)
end

-- Save button / Enter: sets the secret and closes the window, or shows why not (e.g. too short).
local function save()
    local check, why = GA:SetGuildSecret(frame.edit:GetText())
    if not check then
        frame.error:SetText("|cffff4040" .. tostring(why) .. "|r")
        return
    end
    GA:Print(("Guild secret saved. Check code |cffffffff%s|r - guildmates with the same secret see the same code."):format(check))
    frame:Hide()
end

-- Out: the window frame (built once, on first open)
local function build()
    local f = CreateFrame("Frame", FRAME_NAME, UIParent)
    f:SetSize(360, 196)
    f:SetPoint("CENTER", 0, 120)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
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
    title:SetText("Guild secret")
    f.guild = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.guild:SetPoint("TOPRIGHT", -12, -12)

    local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", 12, -32)
    help:SetWidth(336)
    help:SetJustifyH("LEFT")
    help:SetText("Everyone in your guild who uses SawIt enters the same secret. Notes and locations are encrypted "
        .. "with it; guild members without it see nothing. Hand it out privately, not in guild chat.")

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("TOPLEFT", 12, -82)

    f.edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.edit:SetSize(320, 22)
    f.edit:SetPoint("TOPLEFT", 18, -100)
    f.edit:SetAutoFocus(false)
    f.edit:SetMaxLetters(64)
    f.edit:SetScript("OnEnterPressed", save)
    f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
    f.edit:SetScript("OnChar", function(_, c) GA.Crypto.AddEntropy(c) end)
    f.edit:SetScript("OnTextChanged", function() f.error:SetText("") end)

    f.error = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.error:SetPoint("TOPLEFT", 12, -128)

    local function button(text, w, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    f.saveButton = button("Save", 80, save)
    f.saveButton:SetPoint("BOTTOMRIGHT", -12, 12)
    local cancel = button("Cancel", 80, function() f:Hide() end)
    cancel:SetPoint("RIGHT", f.saveButton, "LEFT", -6, 0)
    f.generateButton = button("Generate", 90, function()
        f.edit:SetText(GA.Crypto.RandomSecret(GA.playerName))
        f.edit:SetFocus()
        f.edit:HighlightText()   -- ready for Ctrl+C
    end)
    f.generateButton:SetPoint("BOTTOMLEFT", 12, 12)
    f.removeButton = button("Remove", 80, function()
        GA:ClearGuildSecret()
        GA:Print("Guild secret removed: nothing is shared until one is set again.")
        refresh()
    end)
    f.removeButton:SetPoint("LEFT", f.generateButton, "RIGHT", 6, 0)

    f:SetScript("OnHide", function() f.edit:SetText(""); f.edit:ClearFocus() end)   -- the secret never stays on screen
    return f
end

-- /sawit secret: opens the window (not in test mode, and only in a guild).
function Dialog:Open()
    if GA:IsTestMode() then return GA:Print("Test mode is local only; the guild secret is not used (GA.TEST_MODE in Core/Core.lua).") end
    if not GA:GetGuildName() then return GA:Print("You need to be in a guild to set its secret.") end
    frame = frame or build()
    frame.error:SetText("")
    refresh()
    frame:Show()
    frame.edit:SetFocus()
end

Dialog.GetFrame = function() return frame end   -- for tests
