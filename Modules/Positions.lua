--[[
GuildAtlas - Positions: ephemeral live locations. NOTHING here is ever saved to SavedVariables.

Packet (prefix GAtlasP, plain text, fixed width, sender is implicit):
  "1" <mapID:5 digits> <x:4 digits> <y:4 digits>     14 bytes   e.g. "10142945216033"  (x,y = 0..9999 of the map)
  "0"                                                 1 byte    "I stopped sharing" - receivers drop the dot now
  "2" ...                                             reserved: batch/relay format (several players per packet) for
                                                      when the guild outgrows one GUILD stream. Receivers ignore it.

Send policy: check every `interval` seconds (4 s base, slower with more members online). Send when the player
moved more than MOVE_EPS (fraction of the map) or changed map; otherwise resend the unchanged position only every
`keepalive` seconds so standing still doesn't look like going offline. Receivers expire entries after `expire` s
(default 30 = 2.5 x keepalive; the spec's 15-20 s would make every idle player blink out).

Level/class come from the guild roster, never the wire.
]]
local ADDON, ns = ...
local GA = ns.addon

local Pos = GA:NewModule("Positions", "AceEvent-3.0")
GA.Positions = Pos

local MOVE_EPS = 0.002
local REF = "GuildAtlasPos"
local CIRCLE = "Interface\\AddOns\\SawIt\\Media\\circle"
local players = {}          -- name -> { map, x, y, seen }
local icons = {}            -- name -> { world = frame, mini = frame }. Two frames: HBD-Pins reparents an icon to the
                            -- map it is on and hides it when the world map closes, so one frame can't be on both.
local pool = {}
Pos.players = players

---------------------------------------------------------------------------
-- packet format (pure)
---------------------------------------------------------------------------
local function q(v) return math.max(0, math.min(9999, math.floor(v * 10000 + 0.5))) end
function Pos.Encode(mapID, x, y) return ("1%05d%04d%04d"):format(mapID, q(x), q(y)) end
function Pos.Decode(text)
    if text == "0" then return "leave" end
    local m, x, y = text:match("^1(%d%d%d%d%d)(%d%d%d%d)(%d%d%d%d)$")
    if not m then return nil end
    return tonumber(m), tonumber(x) / 10000, tonumber(y) / 10000
end

---------------------------------------------------------------------------
-- sending
---------------------------------------------------------------------------
function Pos:SetSharing(on)
    GA.db.profile.positions.share = on and true or false
    if not on then GA.Comm:SendRaw("0") ; self.last = nil end
    local msg = "OFF."
    if on and GA:CanUseNetwork() then
        msg = "ON - guildmates running SawIt can see you on their map."
    elseif on then
        msg = "ON, but nothing is sent: " .. (GA:NetworkBlockReason() or "")
    end
    GA:Print("Location sharing " .. msg)
    self:SendMessage("GUILDATLAS_SHARING_CHANGED", on and true or false)
end

-- "sent": sharing on and messages can go out; "blocked": on, but test mode, no guild or no guild secret; "off"
function Pos:SharingState()
    if not GA.db.profile.positions.share then return "off" end
    return GA:CanUseNetwork() and "sent" or "blocked"
end

function Pos:Interval()
    local p = GA.db.profile.positions
    local online = GA.onlineCount or 0
    return math.min(10, p.baseInterval + math.max(0, online - 10) * 0.04)
end

function Pos:Hidden()
    local p = GA.db.profile.positions
    if p.hideInCombat and UnitAffectingCombat("player") then return true end
    if p.hideInPvP then
        local _, t = IsInInstance()
        if t == "pvp" or t == "arena" then return true end
    end
    return false
end

function Pos:Tick()
    C_Timer.After(self:Interval(), function() self:Tick() end)
    local p = GA.db.profile.positions
    if not p.share or not GA:CanUseNetwork() or self:Hidden() then return end
    local mapID, x, y = GA:GetPlayerPosition()         -- nil in instances: nothing is sent there
    if not mapID then return end
    local l, now = self.last, GetTime()
    local moved = not l or l.map ~= mapID or math.abs(l.x - x) > MOVE_EPS or math.abs(l.y - y) > MOVE_EPS
    if not moved and now - l.t < p.keepalive then return end
    if GA.Comm:SendRaw(Pos.Encode(mapID, x, y)) then self.last = { map = mapID, x = x, y = y, t = now } end
end

---------------------------------------------------------------------------
-- receiving
---------------------------------------------------------------------------
local function mapExists(id) return C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id) ~= nil end

function Pos:OnPacket(sender, text)
    local m, x, y = Pos.Decode(text)
    if m == "leave" then return self:Drop(sender) end
    if not m or x > 0.9999 or not mapExists(m) then return end
    local e = players[sender]
    if not e then e = {}; players[sender] = e end
    e.map, e.x, e.y, e.seen = m, x, y, GetTime()
    self:UpdateIcon(sender)
end

function Pos:Drop(name)
    players[name] = nil
    self:ReleaseIcon(name)
end

function Pos:Expire()
    local cutoff = GetTime() - GA.db.profile.positions.expire
    for name, e in pairs(players) do if e.seen < cutoff then self:Drop(name) end end
end

---------------------------------------------------------------------------
-- rendering (HereBeDragons-Pins-2.0). Class-colored round dots with a black edge.
-- TODO(step 5): combat-safe hiding, per-class shapes, size option.
---------------------------------------------------------------------------
local function newDot()
    local f = table.remove(pool)
    if f then return f end
    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(10, 10)
    f:EnableMouse(true)
    f.border = f:CreateTexture(nil, "OVERLAY", nil, 0)
    f.border:SetAllPoints()
    f.border:SetTexture(CIRCLE)
    f.border:SetVertexColor(0, 0, 0, 1)
    f.fill = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.fill:SetPoint("TOPLEFT", 1, -1)
    f.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    f.fill:SetTexture(CIRCLE)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local r = GA.roster[self.player]
        GameTooltip:AddLine(self.player)
        if r then GameTooltip:AddLine(("Level %s %s"):format(tostring(r.level), tostring(r.class)), 1, 1, 1) end
        GameTooltip:AddLine("Click: " .. (GA.IsAddOnLoaded("TomTom") and "TomTom waypoint" or "set map pin"), 0.5, 0.8, 0.5)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:SetScript("OnMouseUp", function(self)
        local e = players[self.player]
        if e and GA.POIMap then GA.POIMap.WaypointTo(e.map, e.x, e.y, self.player) end
    end)
    return f
end

function Pos:ReleaseIcon(name)
    local pair = icons[name]
    if not pair then return end
    if GA.HBDPins then GA.HBDPins:RemoveWorldMapIcon(REF, pair.world); GA.HBDPins:RemoveMinimapIcon(REF, pair.mini) end
    pair.world:Hide(); pair.mini:Hide()
    icons[name] = nil
    pool[#pool + 1] = pair.world
    pool[#pool + 1] = pair.mini
end

function Pos:UpdateIcon(name)
    local e, pins = players[name], GA.HBDPins
    if not e or not pins then return end
    local pair = icons[name]
    if not pair then pair = { world = newDot(), mini = newDot() }; icons[name] = pair end
    local r = GA.roster[name]
    local c = (r and r.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[r.class]) or { r = 1, g = 1, b = 1 }
    for _, f in pairs(pair) do
        f.player = name
        f.fill:SetVertexColor(c.r, c.g, c.b, 1)
    end
    local p = GA.db.profile.positions
    if p.showWorldMap then pins:AddWorldMapIconMap(REF, pair.world, e.map, e.x, e.y, HBD_PINS_WORLDMAP_SHOW_CONTINENT) else pins:RemoveWorldMapIcon(REF, pair.world) end
    if p.showMinimap then pins:AddMinimapIconMap(REF, pair.mini, e.map, e.x, e.y, false, true) else pins:RemoveMinimapIcon(REF, pair.mini) end
end

function Pos:RefreshAllIcons() for name in pairs(players) do self:UpdateIcon(name) end end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------
function Pos:PrintStatus()
    local n = 0
    for _ in pairs(players) do n = n + 1 end
    GA:Print(("sharing=%s  tracking %d player(s)  send interval %.1fs"):format(tostring(GA.db.profile.positions.share), n, self:Interval()))
end

function Pos:OnEnable()
    GA.Comm:RegisterRawHandler(function(sender, text) self:OnPacket(sender, text) end)
    self:RegisterMessage("GUILDATLAS_ROSTER_UPDATED", "RefreshAllIcons")   -- class colours arrive with the roster
    C_Timer.NewTicker(5, function() self:Expire() end)
    C_Timer.After(10, function() self:Tick() end)
    if not GA.HBDPins then GA:Print("HereBeDragons-Pins missing: positions will not be drawn.") end
end
