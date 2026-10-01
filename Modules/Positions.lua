--[[
SawIt - Positions: live guildmate locations as round class-coloured dots on the world map and minimap.
Nothing here is ever saved. Sharing your own location is opt-in (/sawit share, or right-click the minimap button).

Packet (plain text, fixed width; Comm encrypts it and sends it on the positions prefix; the sender is implicit):
  "1" <mapID:5 digits> <x:4 digits> <y:4 digits>   14 bytes  e.g. "10142945216033"  (x, y = 0..9999 of the map)
  "0"                                              1 byte    "I stopped sharing": receivers remove the dot at once
  "2" ...                                          reserved: several players per packet, for when a guild outgrows one
                                                   GUILD stream. Ignored by receivers.

Sending: every `interval` seconds (4 s, slower with many members online) check the position. Send it when the player
moved more than MOVE_EPS (fraction of the map) or changed map; otherwise resend the same position only every
`keepalive` seconds, so standing still doesn't look like being gone. Receivers drop a dot after `expire` seconds of
silence (30 = 2.5 x keepalive). Nothing is sent in instances, and by default not in combat or battlegrounds/arenas.

Level and class come from the guild roster, never from the packet.
]]
local _, ns = ...
local GA = ns.addon

local Pos = GA:NewModule("Positions", "AceEvent-3.0")
GA.Positions = Pos

local MOVE_EPS = 0.002
local REF = "SawItDots"   -- our dots' group in HBD-Pins
local CIRCLE = "Interface\\AddOns\\SawIt\\Media\\circle"
local WHITE = { r = 1, g = 1, b = 1 }

-- name -> { map, x, y, seen = GetTime(), world = dot frame, mini = dot frame }. Two frames per player: HBD-Pins
-- reparents a frame to the map it is on and hides it when the world map closes, so one frame can't be on both.
local players = {}
Pos.players = players   -- for tests
local pool = {}         -- dot frames not in use

---------------------------------------------------------------------------
-- packet format (no WoW API)
---------------------------------------------------------------------------
local function q(v) return math.max(0, math.min(9999, math.floor(v * 10000 + 0.5))) end

-- In: mapID, x, y (0..1).  Out: 14-byte packet
function Pos.Encode(mapID, x, y) return ("1%05d%04d%04d"):format(mapID, q(x), q(y)) end

-- In: text  a received packet.  Out: mapID, x, y;  or "leave" for the stop packet;  or nil if it isn't valid
function Pos.Decode(text)
    if text == "0" then return "leave" end
    local m, x, y = text:match("^1(%d%d%d%d%d)(%d%d%d%d)(%d%d%d%d)$")
    if not m then return nil end
    return tonumber(m), tonumber(x) / 10000, tonumber(y) / 10000
end

---------------------------------------------------------------------------
-- sending
---------------------------------------------------------------------------
-- Turns sharing our own location on or off, and says so in chat. Off also tells guildmates to remove our dot now.
-- In: on  true or false
function Pos:SetSharing(on)
    on = on and true or false
    GA.db.profile.positions.share = on
    if not on then
        GA.Comm:SendRaw("0")
        self.last = nil
    end
    local msg = "OFF."
    if on then
        local blocked = GA:NetworkBlockReason()
        msg = blocked and ("ON, but nothing is sent: " .. blocked) or "ON - guildmates running SawIt can see you on their map."
    end
    GA:Print("Location sharing " .. msg)
    self:SendMessage("GUILDATLAS_SHARING_CHANGED", on)
end

-- Out: "sent" (on, and messages go out) | "blocked" (on, but test mode, no guild or no guild secret) | "off"
function Pos:SharingState()
    if not GA.db.profile.positions.share then return "off" end
    return GA:CanUseNetwork() and "sent" or "blocked"
end

-- Out: seconds between position checks: the base interval, slower with more than 10 members online, at most 10 s
function Pos:Interval()
    local online = GA.onlineCount or 0
    return math.min(10, GA.db.profile.positions.baseInterval + math.max(0, online - 10) * 0.04)
end

-- Out: true while our position must not be sent (combat or battleground/arena, as configured)
function Pos:Hidden()
    local p = GA.db.profile.positions
    if p.hideInCombat and UnitAffectingCombat("player") then return true end
    local _, kind = IsInInstance()
    return p.hideInPvP and (kind == "pvp" or kind == "arena")
end

-- Runs every Interval() seconds: sends our position when it changed, or as a keepalive.
function Pos:Tick()
    C_Timer.After(self:Interval(), function() self:Tick() end)
    local p = GA.db.profile.positions
    if not p.share or not GA:CanUseNetwork() or self:Hidden() then return end
    local mapID, x, y = GA:GetPlayerPosition()   -- nil in instances: nothing is sent there
    if not mapID then return end
    local l, now = self.last, GetTime()
    local moved = not l or l.map ~= mapID or math.abs(l.x - x) > MOVE_EPS or math.abs(l.y - y) > MOVE_EPS
    if not moved and now - l.t < p.keepalive then return end
    if GA.Comm:SendRaw(Pos.Encode(mapID, x, y)) then self.last = { map = mapID, x = x, y = y, t = now } end
end

---------------------------------------------------------------------------
-- dots
---------------------------------------------------------------------------
local function dotTooltip(f)
    local r = GA.roster[f.player]
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    GameTooltip:AddLine(f.player)
    if r then GameTooltip:AddLine(("Level %s %s"):format(tostring(r.level), tostring(r.class)), 1, 1, 1) end
    GameTooltip:AddLine("Click: " .. (GA.IsAddOnLoaded("TomTom") and "TomTom waypoint" or "set map pin"), 0.5, 0.8, 0.5)
    GameTooltip:Show()
end

local function dotClick(f)
    local e = players[f.player]
    if e then GA.POIMap.WaypointTo(e.map, e.x, e.y, f.player) end
end

-- Out: a dot frame (from the pool or new): a black circle with a smaller class-coloured circle on top
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
    f:SetScript("OnEnter", dotTooltip)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:SetScript("OnMouseUp", dotClick)
    return f
end

-- Puts a player's two dots on the maps (or takes them off, if a map's dots are switched off), in class colour.
-- In: name, e  the player's entry
local function draw(name, e)
    local pins = GA.HBDPins
    if not pins then return end
    local r = GA.roster[name]
    local c = r and RAID_CLASS_COLORS[r.class] or WHITE
    for _, f in ipairs({ e.world, e.mini }) do
        f.player = name
        f.fill:SetVertexColor(c.r, c.g, c.b, 1)
    end
    local p = GA.db.profile.positions
    if p.showWorldMap then
        pins:AddWorldMapIconMap(REF, e.world, e.map, e.x, e.y, HBD_PINS_WORLDMAP_SHOW_CONTINENT)
    else
        pins:RemoveWorldMapIcon(REF, e.world)
    end
    if p.showMinimap then
        pins:AddMinimapIconMap(REF, e.mini, e.map, e.x, e.y, false, true)
    else
        pins:RemoveMinimapIcon(REF, e.mini)
    end
end

-- Redraws every dot, e.g. when class colours arrive with the roster.
function Pos:RefreshAllIcons()
    for name, e in pairs(players) do draw(name, e) end
end

---------------------------------------------------------------------------
-- receiving
---------------------------------------------------------------------------
-- Removes a player's dots and forgets them.
-- In: name
function Pos:Drop(name)
    local e = players[name]
    if not e then return end
    if GA.HBDPins then
        GA.HBDPins:RemoveWorldMapIcon(REF, e.world)
        GA.HBDPins:RemoveMinimapIcon(REF, e.mini)
    end
    e.world:Hide()
    e.mini:Hide()
    pool[#pool + 1] = e.world
    pool[#pool + 1] = e.mini
    players[name] = nil
end

-- Comm's handler for position packets.
-- In: sender  normalized name;  text  the decrypted packet
function Pos:OnPacket(sender, text)
    local m, x, y = Pos.Decode(text)
    if m == "leave" then return self:Drop(sender) end
    if not m or not C_Map.GetMapInfo(m) then return end   -- garbage, reserved format, or a map we don't know
    local e = players[sender]
    if not e then
        e = { world = newDot(), mini = newDot() }
        players[sender] = e
    end
    e.map, e.x, e.y, e.seen = m, x, y, GetTime()
    draw(sender, e)
end

-- Drops players not heard from for `expire` seconds (runs every 5 s).
function Pos:Expire()
    local cutoff = GetTime() - GA.db.profile.positions.expire
    for name, e in pairs(players) do
        if e.seen < cutoff then self:Drop(name) end
    end
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------
-- Prints one status line for /sawit status.
function Pos:PrintStatus()
    local n = 0
    for _ in pairs(players) do n = n + 1 end
    GA:Print(("sharing=%s  tracking %d player(s)  send interval %.1fs"):format(tostring(GA.db.profile.positions.share),
        n, self:Interval()))
end

-- AceAddon callback: packet handler, roster colours, expiry ticker, and the first send check after 10 s.
function Pos:OnEnable()
    GA.Comm:RegisterRawHandler(function(sender, text) self:OnPacket(sender, text) end)
    self:RegisterMessage("GUILDATLAS_ROSTER_UPDATED", "RefreshAllIcons")   -- class colours arrive with the roster
    C_Timer.NewTicker(5, function() self:Expire() end)
    C_Timer.After(10, function() self:Tick() end)
    if not GA.HBDPins then GA:Print("HereBeDragons-Pins missing: positions will not be drawn.") end
end
