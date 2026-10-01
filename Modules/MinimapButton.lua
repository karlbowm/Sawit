--[[
SawIt - minimap button (LibDataBroker + LibDBIcon).
The addon object and saved variables are created in Core\Core.lua; this file is only a module, loaded last.
  Left-click        add a note at your position (NoteDialog)
  Shift-left-click  status (same as /sawit status)
  Right-click       toggle live location sharing
Ring around the icon: green = your location is being shared, orange = sharing is on but nothing can be sent
(test mode, no guild or no guild secret), none = sharing off.
]]
local _, ns = ...
local GA = ns.addon

local Button = GA:NewModule("MinimapButton", "AceEvent-3.0")

local LDB = LibStub("LibDataBroker-1.1")
local icon = LibStub("LibDBIcon-1.0")

local function countPlayers()
    local n = 0
    for _ in pairs(GA.Positions and GA.Positions.players or {}) do n = n + 1 end
    return n
end

local function countNotes()
    local n = 0
    if GA.POI then for _ in GA.POI:Iterate() do n = n + 1 end end
    return n
end

local dataObject = LDB:NewDataObject("SawIt", {
    type = "data source",
    text = "SawIt",
    icon = "Interface\\AddOns\\SawIt\\Media\\icon",
    OnClick = function(_, button)
        if button == "RightButton" then
            if GA.Positions then GA.Positions:SetSharing(not GA.db.profile.positions.share) end
        elseif IsShiftKeyDown() then
            GA:SlashCommand("status")
        else
            GA.NoteDialog:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        local share = GA.db.profile.positions.share
        tooltip:AddLine("SawIt")
        local state = GA.Positions and GA.Positions:SharingState() or (share and "sent" or "off")
        local label = { sent = "|cff40ff40ON|r", blocked = "|cffffa020ON (not sent)|r", off = "|cffff4040OFF|r" }
        tooltip:AddLine("Location sharing: " .. label[state], 1, 1, 1)
        local blocked = GA:NetworkBlockReason()
        if blocked then tooltip:AddLine("Not connected to guildmates: " .. blocked, 1, 0.63, 0.13, true) end
        tooltip:AddLine(("Guildmates on map: %d   Notes: %d"):format(countPlayers(), countNotes()), 1, 1, 1)
        tooltip:AddLine(" ")
        tooltip:AddLine("Left-click: add note here", 0.5, 0.8, 0.5)
        tooltip:AddLine("Shift-left-click: status", 0.5, 0.8, 0.5)
        tooltip:AddLine("Right-click: toggle sharing", 0.5, 0.8, 0.5)
        tooltip:AddLine("Shift-right-click the world map: add note there", 0.5, 0.8, 0.5)
        tooltip:AddLine("/sawit help for commands", 0.5, 0.8, 0.5)
    end,
})

local RING_COLORS = { sent = { 0.25, 1, 0.25 }, blocked = { 1, 0.63, 0.13 } }

-- Ring texture on the LibDBIcon button, centred on its icon. Anchored to the icon (not the button) because LibDBIcon
-- places the icon differently on Mainline and Classic layouts (WOW_PROJECT_ID), which is unverified on Forever.
function Button:UpdateRing()
    local b = icon:GetMinimapButton("SawIt")
    if not b then return end
    if not self.ring then
        self.ring = b:CreateTexture(nil, "OVERLAY", nil, 1)
        self.ring:SetTexture("Interface\\AddOns\\SawIt\\Media\\ring")
        self.ring:SetSize(26, 26)
        self.ring:SetPoint("CENTER", b.icon, "CENTER")
    end
    local c = RING_COLORS[GA.Positions and GA.Positions:SharingState() or "off"]
    if c then
        self.ring:SetVertexColor(c[1], c[2], c[3], 1)
        self.ring:Show()
    else
        self.ring:Hide()
    end
end

function Button:OnInitialize()
    -- Module init runs after the addon's OnInitialize, so GA.db exists here.
    icon:Register("SawIt", dataObject, GA.db.profile.minimap)
end

function Button:OnEnable()
    self:RegisterMessage("GUILDATLAS_SHARING_CHANGED", "UpdateRing")
    -- guild membership decides green vs orange; it is only known after login and can change
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "UpdateRing")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "UpdateRing")
    self:UpdateRing()
end
