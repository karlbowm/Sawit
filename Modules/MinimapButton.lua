--[[
SawIt - MinimapButton: the minimap button (LibDataBroker + LibDBIcon; position saved in profile.minimap).
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

-- Out: number of guildmates currently shown on the map
local function countPlayers()
    local n = 0
    for _ in pairs(GA.Positions.players) do n = n + 1 end
    return n
end

-- Out: number of notes (not deleted) of the current guild
local function countNotes()
    local n = 0
    for _ in GA.POI:Iterate() do n = n + 1 end
    return n
end

local SHARING_LABEL = { sent = "|cff40ff40ON|r", blocked = "|cffffa020ON (not sent)|r", off = "|cffff4040OFF|r" }

local dataObject = LDB:NewDataObject("SawIt", {
    type = "data source",
    text = "SawIt",
    icon = "Interface\\AddOns\\SawIt\\Media\\icon",
    OnClick = function(_, button)
        if button == "RightButton" then
            GA.Positions:SetSharing(not GA.db.profile.positions.share)
        elseif IsShiftKeyDown() then
            GA:SlashCommand("status")
        else
            GA.NoteDialog:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("SawIt")
        tooltip:AddLine("Location sharing: " .. SHARING_LABEL[GA.Positions:SharingState()], 1, 1, 1)
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
    local c = RING_COLORS[GA.Positions:SharingState()]
    if c then
        self.ring:SetVertexColor(c[1], c[2], c[3], 1)
        self.ring:Show()
    else
        self.ring:Hide()
    end
end

-- AceAddon callback: registers the button. Runs after Core's OnInitialize, so GA.db exists.
function Button:OnInitialize()
    icon:Register("SawIt", dataObject, GA.db.profile.minimap)
end

-- AceAddon callback: keeps the ring up to date.
function Button:OnEnable()
    self:RegisterMessage("GUILDATLAS_SHARING_CHANGED", "UpdateRing")
    -- guild membership decides green vs orange; it is only known after login and can change
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "UpdateRing")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "UpdateRing")
    self:UpdateRing()
end
