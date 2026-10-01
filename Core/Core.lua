--[[
SawIt (Shared Atlas Worldwide Information Tracker) - Core (merged from GuildAtlas)
Addon object, saved variables, guild roster cache, position helper, /sawit slash command (note commands go to POI).
Modules (Comm, POI, POIMap, Positions, NoteDialog, MinimapButton) are AceAddon modules created in their own files; creation
order == enable order, so Comm is always enabled before the modules that use it. This is the only file that
creates the addon object and the only AceDB:New call; Modules/MinimapButton.lua is the minimap-button module.
]]
local ADDON, ns = ...

local GA = LibStub("AceAddon-3.0"):NewAddon(ADDON, "AceEvent-3.0", "AceConsole-3.0")
ns.addon = GA
_G.SawIt = GA

GA.VERSION = "0.1.0"

---------------------------------------------------------------------------
-- FEATURE FLAG: test mode without a guild.   true = on, false = off.  /reload after changing.
-- On: pretend to be in the guild TEST_GUILD_NAME, so the note window, /sawit add, the world-map Shift+right-click and
-- note pins work on a character without a guild. Test notes are saved under "<TEST_GUILD_NAME>-<realm>",
-- separate from any real guild's notes.
-- Test mode is LOCAL ONLY: nothing is sent or received (no note sync, no location sharing), so test notes can't
-- leak into, or mix with, a real guild's notes. A TEST MODE line prints at login and in /sawit status.
-- All code asks GA:IsTestMode() / GA:InGuild() / GA:CanUseNetwork() below; nothing else reads these two values.
---------------------------------------------------------------------------
GA.TEST_MODE = true
GA.TEST_GUILD_NAME = "AZB Test"

GA.HBD = LibStub("HereBeDragons-2.0", true)
GA.HBDPins = LibStub("HereBeDragons-Pins-2.0", true)

local defaults = {
    profile = {
        minimap = { hide = false }, -- LibDBIcon button position/visibility (Modules/MinimapButton.lua)
        comm = {
            compress = true,        -- LibDeflate on data messages (flag byte keeps it interoperable either way)
            debug = false,
        },
        poi = {
            officerRankIndex = 1, -- guild rank indexes 0..this may moderate others' notes (0 = guild master)
            filters = { rare = true, grind = true, quest = true, other = true },
            showWorldMap = true,  -- note pins on the world map (toggle button on the map, /sawit map)
            showMinimap = true,
            nearbyAlert = true, -- TODO(step 5) "nearby POIs on entering an area"
        },
        positions = {
            share = false,    -- opt-in: nothing is broadcast until the player turns this on
            hideInCombat = true,
            hideInPvP = true, -- battlegrounds / arenas
            showWorldMap = true,
            showMinimap = true,
            baseInterval = 4, -- seconds between position checks (adaptive, see Positions.lua)
            keepalive = 12,   -- resend an unchanged position this often so stationary players don't expire
            expire = 30,      -- receivers drop an entry after this many seconds of silence
        },
    },
    global = {
        guilds = {}, -- ["Guild Name-Realm"] = { pois = { [id] = record } }
        netKeys = {}, -- ["Guild Name-Realm"] = { key = hex master key, check = "B83-CC8" }  (see "guild secret" below)
    },
}

---------------------------------------------------------------------------
-- compat shims (WoW Forever is said to follow Mainline's API surface; Classic-era fallbacks kept)
---------------------------------------------------------------------------
function GA.IsAddOnLoaded(name)
    local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    return f and f(name) or false
end

local function isSecret(v) return issecretvalue and issecretvalue(v) end
GA.isSecret = isSecret

function GA:Debug(...)
    if self.db and self.db.profile.comm.debug then self:Print("|cff888888dbg|r", ...) end
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------
function GA:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("SawItDB", defaults, true)
    self.roster = {}
    self.rosterReady = false
    self:RegisterChatCommand("sawit", "SlashCommand")
    self:RegisterChatCommand("guildatlas", "SlashCommand")   -- old names, kept as aliases
    self:RegisterChatCommand("gatlas", "SlashCommand")
end

function GA:OnEnable()
    self.playerName = UnitName("player")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "RosterEvent")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "RequestRoster")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "RequestRoster")
    if self:IsTestMode() then
        self:Print("|cffff8000TEST MODE|r: pretending to be in guild '" ..
        self.TEST_GUILD_NAME .. "'. Local only, no sync or sharing. (GA.TEST_MODE in Core/Core.lua)")
    end
end

---------------------------------------------------------------------------
-- names
---------------------------------------------------------------------------
-- Canonical form used everywhere: Ambiguate(name, "none") -> "Name" on our realm, "Name-Realm" otherwise.
function GA:Normalize(name)
    if type(name) ~= "string" then return nil end
    return Ambiguate and Ambiguate(name, "none") or name
end

function GA:IsMe(name) return self:Normalize(name) == self.playerName end

---------------------------------------------------------------------------
-- guild membership: the ONLY place that decides "are we in a guild". Use these instead of IsInGuild().
--   IsTestMode()     the TEST_MODE flag is on
--   InRealGuild()    the character really is in a guild (roster, officer ranks)
--   InGuild()        guild features usable (notes, note window, map pins): real guild or test mode
--   CanUseNetwork()  addon messages may be sent/received: real guild, NOT test mode, and a guild secret is set
--   NetworkBlockReason()  why CanUseNetwork() is false, as a sentence
--   GetGuildKey()    "<guild>-<realm>" that notes are stored under, or nil
---------------------------------------------------------------------------
function GA:IsTestMode() return self.TEST_MODE == true end

function GA:InRealGuild() return IsInGuild() and true or false end

function GA:InGuild() return self:GetGuildKey() ~= nil end

function GA:CanUseNetwork() return not self:IsTestMode() and self:InRealGuild() and self:NetContext() ~= nil end

function GA:NetworkBlockReason()
    if self:IsTestMode() then return "test mode is local only." end
    if not self:InRealGuild() then return "you are not in a guild." end
    if not self:NetContext() then return "no guild secret set (/sawit secret)." end
    return nil
end

-- The real guild's name (never the test guild), or nil.
function GA:GetGuildName()
    if not self:InRealGuild() then return nil end
    local g = GetGuildInfo and GetGuildInfo("player")
    if not g or isSecret(g) then return nil end
    return g
end

function GA:GetGuildKey()
    if self:IsTestMode() then return tostring(self.TEST_GUILD_NAME) .. "-" .. GetRealmName() end
    local g = self:GetGuildName()
    return g and (g .. "-" .. GetRealmName())
end

---------------------------------------------------------------------------
-- guild secret. Every addon message is encrypted and authenticated with a key derived from a secret the guild's
-- members enter themselves (Core/Crypto.lua). Without it nothing is sent and nothing received can be read, so
-- being in the guild (or a client that only claims to be) is not enough to see notes or locations.
-- Stored per guild and realm, account-wide (the key itself is salted with the guild name only), as the derived key (not the secret text) plus a check code guildmates
-- compare to confirm they typed the same secret.
---------------------------------------------------------------------------
GA.MIN_SECRET = 8
local netCtx, netCtxKey

-- The real guild's netKeys entry, or nil. Never the test guild: test mode is local only.
local function netEntry(self)
    local g = self:GetGuildName()
    return g and self.db.global.netKeys[g .. "-" .. GetRealmName()], g
end

-- Crypto context for the current guild, or nil (no guild or no secret). Cached; rebuilt when the key changes.
function GA:NetContext()
    local e = netEntry(self)
    if not e then return nil end
    if netCtxKey ~= e.key then netCtx, netCtxKey = self.Crypto.NewContext(self.Crypto.unhex(e.key)), e.key end
    return netCtx
end

function GA:GuildSecretCheck()
    local e = netEntry(self)
    return e and e.check
end

local function secretChanged(self)
    self:SendMessage("SAWIT_GUILD_SECRET_CHANGED")
    self:SendMessage("GUILDATLAS_SHARING_CHANGED", self.db.profile.positions.share)   -- minimap ring state
end

-- Returns the check code, or nil, reason. Takes a moment: the key derivation is deliberately slow.
function GA:SetGuildSecret(text)
    local g = self:GetGuildName()
    if not g then return nil, "you are not in a guild" end
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text < self.MIN_SECRET then return nil, ("too short (at least %d characters)"):format(self.MIN_SECRET) end
    local master = self.Crypto.DeriveMaster(text, g)
    local check = self.Crypto.CheckCode(master)
    self.db.global.netKeys[g .. "-" .. GetRealmName()] = { key = self.Crypto.hex(master), check = check }
    secretChanged(self)
    return check
end

function GA:ClearGuildSecret()
    local e, g = netEntry(self)
    if not e then return false end
    self.db.global.netKeys[g .. "-" .. GetRealmName()] = nil
    secretChanged(self)
    return true
end

-- Returns the saved-variable table for the current guild (created on demand), or nil when unguilded.
function GA:GuildStore()
    local key = self:GetGuildKey()
    if not key then return nil end
    local guilds = self.db.global.guilds
    guilds[key] = guilds[key] or { pois = {} }
    return guilds[key]
end

---------------------------------------------------------------------------
-- roster cache: name -> { rank = rankIndex, level, class (file token), online }
---------------------------------------------------------------------------
local lastRosterRequest = 0
function GA:RequestRoster()
    if not self:InRealGuild() then return end
    local now = GetTime()
    if now - lastRosterRequest < 15 then return end -- the server throttles roster requests too
    lastRosterRequest = now
    local f = (C_GuildInfo and C_GuildInfo.GuildRoster) or _G.GuildRoster
    if f then f() end
end

function GA:RosterEvent()
    if not self:InRealGuild() then
        self.roster = {}; self.rosterReady = false; return
    end
    local roster, online = {}, 0
    for i = 1, (GetNumGuildMembers() or 0) do
        -- name, rankName, rankIndex, level, classDisplayName, zone, note, officerNote, isOnline, status, classFileName
        local name, _, rankIndex, level, _, _, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
        if name and not isSecret(name) then
            roster[self:Normalize(name)] = { rank = rankIndex, level = level, class = classFile, online = isOnline and
            true or false }
            if isOnline then online = online + 1 end
        end
    end
    self.roster, self.onlineCount, self.rosterReady = roster, online, next(roster) ~= nil
    if self.rosterReady and not self.warnedNoSecret and not self:IsTestMode() and not self:NetContext() then
        self.warnedNoSecret = true
        self:Print("No guild secret set: notes and locations are not shared with your guild. Type /sawit secret to enter it.")
    end
    self:SendMessage("GUILDATLAS_ROSTER_UPDATED")
end

function GA:IsGuildMember(name) return self.roster[self:Normalize(name)] ~= nil end

-- Officer == rank index 0..officerRankIndex in the guild's rank table. Unknown names are never officers.
function GA:IsOfficer(name)
    local r = self.roster[self:Normalize(name)]
    return r ~= nil and r.rank ~= nil and r.rank <= self.db.profile.poi.officerRankIndex
end

---------------------------------------------------------------------------
-- player position. Returns mapID, x, y (x,y in 0..1)  or  nil, reason.
-- Returns nil in instances (documented API behaviour, to be confirmed by the prototype).
---------------------------------------------------------------------------
function GA:GetPlayerPosition()
    if IsInInstance() then return nil, "instance" end
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then return nil, "nomap" end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil, "nopos" end
    local x, y = pos:GetXY()
    if isSecret(x) or isSecret(y) then return nil, "secret" end
    if not x or (x == 0 and y == 0) then return nil, "nopos" end
    return mapID, x, y
end

---------------------------------------------------------------------------
-- slash
---------------------------------------------------------------------------
function GA:SlashCommand(input)
    local cmd, arg = (input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local pos = self:GetModule("Positions", true)
    if cmd == "share" then
        if pos then pos:SetSharing(arg ~= "off" and arg ~= "0") end
    elseif cmd == "pause" then
        if pos then pos:SetSharing(false) end
    elseif cmd == "debug" then
        local c = self.db.profile.comm
        c.debug = not c.debug
        self:Print("debug", c.debug and "on" or "off")
    elseif cmd == "secret" then
        if arg:lower() == "clear" then
            self:Print(self:ClearGuildSecret() and "Guild secret removed: nothing is shared until one is set again." or "No guild secret was set.")
        elseif self.SecretDialog then
            self.SecretDialog:Open()
        end
    elseif cmd == "status" or cmd == "" then
        local comm = self:GetModule("Comm", true)
        self:Print(("v%s  guild=%s  roster=%d online=%d  protocol=%d"):format(self.VERSION, tostring(self:GetGuildKey()),
            (function()
                local n = 0; for _ in pairs(self.roster) do n = n + 1 end; return n
            end)(),
            self.onlineCount or 0, comm and comm.PROTO or 0))
        if self:IsTestMode() then self:Print(
            "|cffff8000TEST MODE|r (GA.TEST_MODE): local only, nothing sent or received") end
        local check = self:GuildSecretCheck()
        self:Print(check and ("Guild secret: |cff40ff40set|r, check code |cffffffff%s|r (compare with guildmates)"):format(check)
            or "Guild secret: |cffff4040not set|r - nothing is shared or received (/sawit secret)")
        local st = comm and comm.stats
        if st and (st.unreadable > 0 or st.plaintext > 0 or st.noKey > 0) then
            self:Print(("Unreadable guild messages: %d wrong secret, %d unencrypted (old SawIt/GuildAtlas), %d while no secret was set")
                :format(st.unreadable, st.plaintext, st.noKey))
        end
        self:Print(("HereBeDragons=%s Pins=%s TomTom=%s LibDeflate=%s"):format(
            tostring(self.HBD ~= nil), tostring(self.HBDPins ~= nil),
            tostring(self.IsAddOnLoaded("TomTom")), tostring(LibStub("LibDeflate", true) ~= nil)))
        if pos then pos:PrintStatus() end
    elseif self.POI then
        self.POI:SlashCommand(input)   -- note commands (add, list, my, edit, del, filter, ...) and help
    else
        self:Print("/sawit status | share [on|off] | pause | debug | secret [clear]")
    end
end
