--[[
SawIt (Shared Atlas Worldwide Information Tracker) - Core
Creates the addon object (the only NewAddon and the only AceDB:New), and holds what every module shares: guild and
network state, the guild secret, the guild roster, the player's position, and the /sawit command.
Modules live in their own files (Comm, POI, POIMap, Positions, the dialogs, MinimapButton). AceAddon enables them in
creation order (= SawIt.toc order), so Comm is enabled before the modules that use it.
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

GA.HBDPins = LibStub("HereBeDragons-Pins-2.0", true)

local MIN_SECRET = 8   -- characters

local defaults = {
    profile = {
        minimap = { hide = false }, -- LibDBIcon button position/visibility (Modules/MinimapButton.lua)
        comm = {
            compress = true,        -- deflate data messages over 80 bytes (Comm.lua)
            debug = false,
        },
        poi = {
            officerRankIndex = 1, -- guild rank indexes 0..this may moderate others' notes (0 = guild master)
            filters = { rare = true, grind = true, quest = true, other = true },
            showWorldMap = true,  -- note pins on the world map (toggle button on the map, /sawit map)
            showMinimap = true,
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
        guilds = {},  -- ["Guild-Realm"] = { pois = { [id] = record } }
        netKeys = {}, -- ["Guild-Realm"] = { key = hex master key, check = "B83-CC8" }  (see "guild secret" below)
    },
}

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------
-- Is another addon loaded? Uses C_AddOns (Mainline), falling back to the old global.
-- In:  name  addon folder name, e.g. "TomTom"
-- Out: true or false
function GA.IsAddOnLoaded(name)
    local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    return f ~= nil and f(name) and true or false
end

-- Is v one of WoW's "secret values" (hidden from addons in restricted contexts)? Such values must not be used.
-- In:  any value
-- Out: true if secret; false/nil otherwise or on clients without secret values
local function isSecret(v) return issecretvalue and issecretvalue(v) end
GA.isSecret = isSecret

-- Prints its arguments in grey when debug output is on (/sawit debug).
function GA:Debug(...)
    if self.db and self.db.profile.comm.debug then self:Print("|cff888888dbg|r", ...) end
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------
-- AceAddon callback (SavedVariables are loaded): database, empty roster, slash commands.
function GA:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("SawItDB", defaults, true)
    self.roster = {}
    self.rosterReady = false
    self:RegisterChatCommand("sawit", "SlashCommand")
    self:RegisterChatCommand("guildatlas", "SlashCommand")   -- old names, kept as aliases
    self:RegisterChatCommand("gatlas", "SlashCommand")
end

-- AceAddon callback (player is logging in): player name and roster events.
function GA:OnEnable()
    self.playerName = UnitName("player")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "RosterEvent")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "RequestRoster")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "RequestRoster")
    if self:IsTestMode() then
        self:Print("|cffff8000TEST MODE|r: pretending to be in guild '" .. self.TEST_GUILD_NAME
            .. "'. Local only, no sync or sharing. (GA.TEST_MODE in Core/Core.lua)")
    end
end

---------------------------------------------------------------------------
-- names
---------------------------------------------------------------------------
-- The one name format used everywhere.
-- In:  name  as the client gives it ("Name" or "Name-Realm"), or anything else
-- Out: "Name" for our realm, "Name-Realm" for others (Ambiguate "none"); nil if name isn't a string
function GA:Normalize(name)
    if type(name) ~= "string" then return nil end
    return Ambiguate and Ambiguate(name, "none") or name
end

-- In:  name  any player name format
-- Out: true if it is the logged-in character
function GA:IsMe(name) return self:Normalize(name) == self.playerName end

---------------------------------------------------------------------------
-- guild and network state: the ONLY place that decides these. Use the functions, never IsInGuild() or the flag.
---------------------------------------------------------------------------
-- Out: true if the TEST_MODE flag is on
function GA:IsTestMode() return self.TEST_MODE == true end

-- Out: true if the character really is in a guild (test mode doesn't count)
function GA:InRealGuild() return IsInGuild() and true or false end   -- older clients returned 1/nil

-- Out: the real guild's name, or nil (no guild, test mode doesn't count, or the name is a secret value)
function GA:GetGuildName()
    if not self:InRealGuild() then return nil end
    local g = GetGuildInfo and GetGuildInfo("player")
    if not g or isSecret(g) then return nil end
    return g
end

-- "Guild-Realm" of the real guild, or nil. Key for the real guild's netKeys entry.
local function realGuildKey(self)
    local g = self:GetGuildName()
    return g and (g .. "-" .. GetRealmName())
end

-- Out: "Guild-Realm" that notes are stored under (the test guild's in test mode), or nil when not in a guild
function GA:GetGuildKey()
    if self:IsTestMode() then return self.TEST_GUILD_NAME .. "-" .. GetRealmName() end
    return realGuildKey(self)
end

-- Out: true if guild features (notes, note window, map pins) can be used: in a real guild, or in test mode
function GA:InGuild() return self:GetGuildKey() ~= nil end

-- Out: nil if addon messages may be sent and received; otherwise the reason, as a sentence for the player
function GA:NetworkBlockReason()
    if self:IsTestMode() then return "test mode is local only." end
    if not self:InRealGuild() then return "you are not in a guild." end
    if not self:NetContext() then return "no guild secret set (/sawit secret)." end
    return nil
end

-- Out: true if addon messages may be sent and received (real guild, not test mode, guild secret set)
function GA:CanUseNetwork() return self:NetworkBlockReason() == nil end

-- The saved notes table for the current guild, created on first use.
-- Out: { pois = { [id] = record } }, or nil when not in a guild
function GA:GuildStore()
    local key = self:GetGuildKey()
    if not key then return nil end
    local guilds = self.db.global.guilds
    guilds[key] = guilds[key] or { pois = {} }
    return guilds[key]
end

---------------------------------------------------------------------------
-- guild secret. Every addon message is encrypted and authenticated with a key derived from a secret the guild's
-- members enter themselves (Core/Crypto.lua). Without it nothing is sent and nothing received can be read, so
-- being in the guild (or a client that only claims to be) is not enough to see notes or locations.
-- Stored per "Guild-Realm", account-wide, as the derived key (never the secret text) plus a check code that
-- guildmates compare to confirm they typed the same secret. The key is salted with the guild name only.
---------------------------------------------------------------------------
local netCtx, netCtxKey   -- cached crypto context and the hex key it was built from

-- The crypto context Comm seals and opens messages with.
-- Out: context for the real guild's secret, or nil (no guild or no secret). Rebuilt only when the key changes.
function GA:NetContext()
    local key = realGuildKey(self)
    local e = key and self.db.global.netKeys[key]
    if not e then return nil end
    if netCtxKey ~= e.key then netCtx, netCtxKey = self.Crypto.NewContext(self.Crypto.unhex(e.key)), e.key end
    return netCtx
end

-- Out: the check code of the current guild's secret ("B83-CC8"), or nil if none is set
function GA:GuildSecretCheck()
    local key = realGuildKey(self)
    local e = key and self.db.global.netKeys[key]
    return e and e.check
end

-- Tells the modules the secret changed: POI syncs, the minimap ring recolours.
local function secretChanged(self)
    self:SendMessage("SAWIT_GUILD_SECRET_CHANGED")
    self:SendMessage("GUILDATLAS_SHARING_CHANGED", self.db.profile.positions.share)
end

-- Sets the current guild's secret. Takes a moment: the key derivation is deliberately slow.
-- In:  text  the secret; surrounding spaces are ignored
-- Out: the check code, or nil, reason (a sentence for the player)
function GA:SetGuildSecret(text)
    local g, key = self:GetGuildName(), realGuildKey(self)
    if not g then return nil, "you are not in a guild" end
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text < MIN_SECRET then return nil, ("too short (at least %d characters)"):format(MIN_SECRET) end
    local master = self.Crypto.DeriveMaster(text, g)
    local check = self.Crypto.CheckCode(master)
    self.db.global.netKeys[key] = { key = self.Crypto.hex(master), check = check }
    secretChanged(self)
    return check
end

-- Removes the current guild's secret; from then on nothing is shared.
-- Out: true if one was set
function GA:ClearGuildSecret()
    local key = realGuildKey(self)
    if not (key and self.db.global.netKeys[key]) then return false end
    self.db.global.netKeys[key] = nil
    secretChanged(self)
    return true
end

---------------------------------------------------------------------------
-- roster cache: self.roster[name] = { rank = rankIndex, level, class (file token), online }
---------------------------------------------------------------------------
local lastRosterRequest = 0

-- Asks the server for a fresh guild roster (answered by GUILD_ROSTER_UPDATE). At most every 15 s, since the
-- server throttles these too.
function GA:RequestRoster()
    if not self:InRealGuild() then return end
    local now = GetTime()
    if now - lastRosterRequest < 15 then return end
    lastRosterRequest = now
    local f = (C_GuildInfo and C_GuildInfo.GuildRoster) or _G.GuildRoster
    if f then f() end
end

-- GUILD_ROSTER_UPDATE: rebuilds self.roster and self.onlineCount, then sends GUILDATLAS_ROSTER_UPDATED.
-- The first time the roster is known and no secret is set, tells the player once how to set it.
function GA:RosterEvent()
    local roster, online = {}, 0
    if self:InRealGuild() then
        for i = 1, (GetNumGuildMembers() or 0) do
            -- name, rankName, rankIndex, level, classDisplayName, zone, note, officerNote, isOnline, status, classFileName
            local name, _, rankIndex, level, _, _, _, _, isOnline, _, classFile = GetGuildRosterInfo(i)
            if name and not isSecret(name) then
                roster[self:Normalize(name)] = { rank = rankIndex, level = level, class = classFile, online = isOnline and true or false }
                if isOnline then online = online + 1 end
            end
        end
    end
    self.roster, self.onlineCount, self.rosterReady = roster, online, next(roster) ~= nil
    if self.rosterReady and not self.warnedNoSecret and not self:IsTestMode() and not self:NetContext() then
        self.warnedNoSecret = true
        self:Print("No guild secret set: notes and locations are not shared with your guild. Type /sawit secret to enter it.")
    end
    self:SendMessage("GUILDATLAS_ROSTER_UPDATED")
end

-- In:  name  any player name format
-- Out: true if the name is in the cached roster
function GA:IsGuildMember(name) return self.roster[self:Normalize(name)] ~= nil end

-- In:  name  any player name format
-- Out: true if their rank index is 0..poi.officerRankIndex. Names not in the roster are never officers.
function GA:IsOfficer(name)
    local r = self.roster[self:Normalize(name)]
    return r ~= nil and r.rank ~= nil and r.rank <= self.db.profile.poi.officerRankIndex
end

---------------------------------------------------------------------------
-- player position
---------------------------------------------------------------------------
-- Where the player is on the most detailed map.
-- Out: mapID, x, y (x and y 0..1), or nil, reason: "instance" | "nomap" | "nopos" | "secret"
function GA:GetPlayerPosition()
    if IsInInstance() then return nil, "instance" end   -- position APIs return nothing useful inside instances
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil, "nomap" end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil, "nopos" end
    local x, y = pos:GetXY()
    if isSecret(x) or isSecret(y) then return nil, "secret" end
    if not x or (x == 0 and y == 0) then return nil, "nopos" end
    return mapID, x, y
end

---------------------------------------------------------------------------
-- /sawit
---------------------------------------------------------------------------
-- Prints the status lines for "/sawit" and "/sawit status".
local function printStatus(self)
    local members = 0
    for _ in pairs(self.roster) do members = members + 1 end
    self:Print(("v%s  guild=%s  roster=%d online=%d  protocol=%d"):format(self.VERSION, tostring(self:GetGuildKey()),
        members, self.onlineCount or 0, self.Comm.PROTO))
    if self:IsTestMode() then self:Print("|cffff8000TEST MODE|r (GA.TEST_MODE): local only, nothing sent or received") end
    local check = self:GuildSecretCheck()
    self:Print(check and ("Guild secret: |cff40ff40set|r, check code |cffffffff%s|r (compare with guildmates)"):format(check)
        or "Guild secret: |cffff4040not set|r - nothing is shared or received (/sawit secret)")
    local st = self.Comm.stats
    if st.unreadable > 0 or st.plaintext > 0 or st.noKey > 0 then
        self:Print(("Unreadable guild messages: %d wrong secret, %d unencrypted (old SawIt/GuildAtlas), %d while no secret was set")
            :format(st.unreadable, st.plaintext, st.noKey))
    end
    self:Print(("Map pins library=%s  TomTom=%s"):format(tostring(self.HBDPins ~= nil), tostring(self.IsAddOnLoaded("TomTom"))))
    self.Positions:PrintStatus()
end

-- Handles /sawit (and the aliases). Its own commands are below; everything else goes to POI:SlashCommand
-- (add, list, my, edit, del, filter, map, minimap, sync, stats, cats, help).
-- In:  input  text after the command, e.g. "share off"
function GA:SlashCommand(input)
    local cmd, arg = (input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "share" then
        self.Positions:SetSharing(arg ~= "off" and arg ~= "0")
    elseif cmd == "pause" then
        self.Positions:SetSharing(false)
    elseif cmd == "debug" then
        local c = self.db.profile.comm
        c.debug = not c.debug
        self:Print("debug", c.debug and "on" or "off")
    elseif cmd == "secret" then
        if arg:lower() == "clear" then
            self:Print(self:ClearGuildSecret() and "Guild secret removed: nothing is shared until one is set again."
                or "No guild secret was set.")
        else
            self.SecretDialog:Open()
        end
    elseif cmd == "status" or cmd == "" then
        printStatus(self)
    else
        self.POI:SlashCommand(input)
    end
end
