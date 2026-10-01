# HANDOFF: context for the new session

> Start with `CLAUDE.md` (current state, layout, conventions, how to test) and `TODO.md` (everything still to verify in
> game). This file is the dated history; older sections describe superseded states (MarcusAddon, HandyNotes, `/poi`).

## Renamed to SawIt (2026-09-30): Shared Atlas Worldwide Information Tracker
- Folder `AddOns/SawIt`, `SawIt.toc`, AceAddon name `SawIt`, global `_G.SawIt` (`_G.MyAddon`/`_G.GuildAtlas` removed),
  SavedVariables `SawItDB` (migrated from `MyAddonDB` in `WTF/.../SavedVariables/MarcusAddon.lua`), slash `/sawit`
  (`/guildatlas`, `/gatlas` kept as aliases), minimap module moved to `Modules/MinimapButton.lua` (LDB/LibDBIcon name `SawIt`).
- Frame/pin names: `SawItNoteDialog`, HBD ref `SawItNotes`. Texture paths `Interface\AddOns\SawIt\Media\...`.
- Unchanged on purpose: comm prefixes `GAtlasD`/`GAtlasP` and PROTO 1 (invisible to players; changing them only breaks
  compatibility). Internal AceEvent messages were renamed to `SAWIT_*` on 2026-10-01 (they never leave the client, so that was
  safe; see CLAUDE.md for the list). Everything below written before the rename says MarcusAddon.

## Client research (2026-09-30): see NOTES-client-research.md
WoW Forever = game type `camelot`, build 1.60.1.70124, Interface 16001 (confirmed from the build number). It runs the
Mainline (Midnight 12.x) UI and API with secret values and messaging lockdown active, not the Classic API. Every Blizzard
API our code calls exists in the client. Open items 1 (Interface number) and 2 (Retail-like client) below are answered
by that note; the in-game limits (message size, throttle, lockdown timing) still need the prototype run.

## Update 2026-09-30: merged into MarcusAddon
- GuildAtlas was merged into Marcus's existing `MarcusAddon` (at `_classic_beta_/Interface/AddOns/MarcusAddon`). One addon
  object (`MarcusAddon`, alias `MyAddon`), one SavedVariable (`MyAddonDB`). Core creates the object; `MarcusAddon.lua` is a
  `MinimapButton` module using LDB + LibDBIcon with the AZB server icon (`Media/icon.tga`).
- Minimap button: left-click prints status, right-click toggles location sharing, tooltip shows sharing state, dots and notes.
- Wire format unchanged (`GAtlasD`/`GAtlasP`, PROTO 1).
- Libraries: MarcusAddon's Ace3 (Release-r1403, identical code to the pinned copy apart from line endings and `$Id$`) plus
  HereBeDragons and LibDeflate copied from GuildAtlas.
- New `tests/test_load.lua`: loads the real files in .toc order against a stubbed WoW API and fires login events; passes.
  `tests/test_poi.lua` still passes. Lua 5.1 is installed user-locally in `~/.local/opt/lua5.1` with wrappers `lua`, `luac`, `lua5.1`, `luac5.1` in
  `~/.local/bin` (extracted from the Ubuntu packages, no root; `sudo apt install lua5.1` would replace it).
- Open question 7 answered for this machine: the AddOns folder is `_classic_beta_`.
- TomTom is not installed on this client; the prototype `GuildAtlasProto` was not installed.
- **HandyNotes dropped (2026-09-30).** Notes are drawn by `Modules/POIMap.lua` with HereBeDragons-Pins: one pin per
  4-digit coordinate (tooltip lists all notes there, count on the pin), separate frames for world map and minimap,
  redraw coalesced to 0.2 s. Filters via `/sawit filter [category]` and `/sawit minimap`. Open items 4 and 6 below are obsolete
  (a map-click add is now possible because we own the pins).
- **Bug fixed in Positions:** it used one frame for both the world-map and minimap dot. HBD-Pins reparents an icon to the
  map it's shown on and hides it when the world map closes, so each player now has two frames.
- Left-click on the minimap button opens `Modules/NoteDialog.lua` (add a note at your position: category list + text).
- **Feature flag `GA.TEST_MODE`** (top of `Core/Core.lua`, `true`/`false`, ships `false`): pretend to be in guild
  `GA.TEST_GUILD_NAME` ("AZB Test") to test notes, the note window and map pins without a guild. Notes are stored under
  "<name>-<realm>". Local only: Comm sends and receives nothing while it's on, even in a real guild. A TEST MODE line prints
  at login and in /sawit status.
- **Guild checks are centralized** in `Core/Core.lua`: `GA:IsTestMode()`, `GA:InRealGuild()` (the only `IsInGuild()` call),
  `GA:InGuild()` (guild features usable), `GA:CanUseNetwork()` (may send/receive), `GA:GetGuildKey()`. New code should use
  these, never `IsInGuild()` or the flag directly.
- **Sharing ring on the minimap button** (`Modules/MinimapButton.lua`, texture `Media/ring.tga`, generated white ring tinted in code):
  green = sharing on and sent, orange = on but blocked (test mode / no guild), hidden = off. State from
  `Positions:SharingState()`, updated on the `SAWIT_SHARING_CHANGED` / `SAWIT_SECRET_CHANGED` messages and on login/guild change. Anchored to the
  LibDBIcon icon, not the button, because LibDBIcon's layout depends on the unverified WOW_PROJECT_ID.
- **Code review pass** (2026-10-01): every Core and Modules file has In/Out comments per function. Cross-file:
  shared window builder (`Core/UI.lua`), HereBeDragons-Pins required (no nil checks), internal messages renamed to
  `SAWIT_*` (table in CLAUDE.md), one exact UTF-8 cut (`POI.Truncate`), three unreachable settings removed, `Utils.lua`
  deleted. Bugs fixed on the way: `POI:Apply` threw on non-table payloads (aborting a sync batch), `/sawit edit` without
  arguments errored, a delete-window row of a note deleted meanwhile lost its title, the old UTF-8 cut dropped a
  complete character at the limit, untitled long notes were cut off in tooltips. Known, not fixed: connected realms
  (TODO.md section 7).
- **Crypto primitives from a library** (2026-10-01): our own SHA-256/HMAC (and the bit-op code) were replaced by
  LibHash-1.0 (`Libs/LibHash-1.0`, unmodified, loaded from `embeds.xml`). Output is byte-identical (same Python
  vectors). Cost in plain Lua: key derivation 0.76 -> 0.99 s, a 2 KB sync message ~120 -> ~140 ms. LibHash never uses
  WoW's native `bit` library and recomputes the HMAC key pads per call: first places to optimise.
- **Guild secret** (2026-09-30, so the addon can be published): `Core/Crypto.lua` (pure-Lua SHA-256/HMAC/PBKDF2, HMAC-CTR
  encryption, 80-bit tag bound to channel + sender without realm), used by `Core/Comm.lua` on BOTH prefixes. No secret =
  `CanUseNetwork()` false (nothing sent, nothing read); plaintext is always dropped. Key stored per guild+realm in
  `db.global.netKeys` (salt: guild name only) (derived key + check code, not the text). `/sawit secret` opens `Modules/SecretDialog.lua`.
  Breaks interop with standalone GuildAtlas / older SawIt on purpose. Unverified in game: speed of the 1000-round KDF
  on Save (0.8 s in plain Lua without `bit`) and of sealing sync messages; `EncodeForWoWAddonChannel` output on GUILD.
  Tests: `tests/test_crypto.lua` (vectors from Python), secret/round-trip section in `tests/test_load.lua`.
- **Delete from the map** (`Modules/DeleteDialog.lua`): right-click a note pin opens a small window listing only the notes at
  that pin the player may delete (`POI:CanModify`: author, or officer), one Delete button per note. The window is the
  confirmation; right-click alone deletes nothing. Own frame at FULLSCREEN_DIALOG strata, not StaticPopup (below the map).
- **One slash command** (2026-09-30): `/poi` is gone; all note commands are `/sawit <cmd>` (Core forwards anything it
  doesn't handle to `POI:SlashCommand`). Adding needs `/sawit add ...` so typos never become notes. `/sawit my [here]`
  lists your own notes with ids for edit/del.
- **Note titles and chat links** (2026-09-30): records have a `title` (<= 40 bytes, wire field 11, so old 10-field clients
  still interoperate but drop it when relaying; untitled notes display their text). Shift-click a note pin puts
  `[Category: Title] <WoW map pin link>` in the chat box; click posts it to guild. The link is built to match
  `C_Map.GetUserWaypointHyperlink()` exactly (no pin placed): per Wowpedia the server rejects map pin links whose colour or
  text were changed, so the title cannot go inside the link. Unverified in game.
- **Notes toggle button on the world map** (`POIMap:SetupWorldMap`, which also adds the Shift+right-click handler): 32x32 AZB icon, top-right of the canvas at x -40, just
  left of Blizzard's tracking-options/map-pin column (x -4). Toggles `profile.poi.showWorldMap` (also `/sawit map`); greyed out
  when hidden. Minimap note pins are separate (`/sawit minimap`).
- **Shift+right-click on the world map** opens the same window at the clicked spot (`NoteDialog:OpenAt`). Hooked via
  `WorldMapFrame:AddCanvasClickHandler(fn, 80)` in `POIMap.lua`; returning true stops the map zooming out. Only zone-level
  maps (`mapType >= Enum.UIMapType.Zone`). The window uses strata FULLSCREEN_DIALOG so it sits above the world map.

## Who and what
Marcus is building **GuildAtlas**, a custom addon for his guild (50 or fewer members) on **WoW Forever** (currently in beta, so its addon API is unverified). He is an engineering manager, so technical depth is fine.

The addon combines two modules on one shared comm layer:
1. **Live guildmate locations** as class-colored dots on the world map and minimap (ephemeral, never persisted).
2. **Persistent Points of Interest**: short notes plus a category at map coordinates, synced to all addon users, shown as HandyNotes pins.

## Decisions already made
- Transport is addon messages on the GUILD channel (`C_ChatInfo.SendAddonMessage`), 255 bytes max, throttled. AceComm and ChatThrottleLib handle the throttling and splitting. AceDB handles SavedVariables.
- **No zone-channel sharding, relay election or interest tiers.** At 50 or fewer members, one GUILD stream is enough (~250 bytes/s inbound worst case). Revisit only if the guild grows past ~100. The packet format is kept batch-friendly for that case.
- Live positions: a 14-byte packed string, not the serializer. Sent only when moved (every 3-5 s), plus a 12 s keepalive for unchanged positions. Entries expire after 30 s. A 1-byte stop packet removes your dot at once. Sharing is **opt-in and off by default**. Low-priority (BULK) queue, so POI sync is never starved.
- POIs: records have `id, rev, author, updatedBy, mapID, x, y, text, category`. Sync is login digest, then diff, then single-record live updates. Conflicts are last-write-wins by `rev`. Tombstones handle deletes. Authors edit and delete their own notes. Officers moderate.
- Rendering goes through HandyNotes (a plugin) and HereBeDragons pins.
- TomTom is optional, for waypoints; without it Ctrl-click places WoW's own map pin (C_Map.SetUserWaypoint, tracked via C_SuperTrack when present).

## State of the code
Nothing has run in a WoW client. The code is syntax-checked with `luac5.1`, and `lua5.1 tests/test_poi.lua` passes offline (permissions, validation, 4-client sync convergence, the position packet). See README.md for the layout, commands, formats and the in-game checklist.

## Known issues and open questions (be honest about these)
1. **Interface version `16001` is unverified.** It came from a community guide, not Blizzard. Confirm in-game with `/run print((select(4,GetBuildInfo())))`. The `.toc` files have a TODO.
2. **The client may behave like current Retail.** That could mean addon messaging is restricted in combat or encounters (secret values, a disabled combat log). The code guards for it. The prototype's probe and combat ping test settle it.
3. **Relayed sync records can't be authenticated per player.** In sync replies the sender is the relaying peer, not the author. Since the guild secret, only a secret holder with a modified client could forge a note "by" an officer; per-player signatures would be the real fix.
4. ~~No right-click "add note" on the map.~~ Done: Shift+right-click on the world map.
5. ~~Rendering is first-pass.~~ Pins and dots are round now; whether the POI icon textures exist is still in `TODO.md`.
6. ~~HandyNotes handler signature.~~ Obsolete, HandyNotes dropped.
7. ~~AddOns folder name.~~ `_classic_beta_` on this install.

## Build order and where we are
1. Comm layer: done (untested in game)
2. Prototype (`GuildAtlasProto`) to verify the three beta assumptions: **written, needs to be run in game**
3. POI notes with sync: done offline
4. Live positions: first pass
5. Polish: filters, settings panel, waypoints, map-click add, better icons. Not started.

## Next steps
1. Marcus runs the prototype checklist in the README (needs a second character or a guildmate for loss, throttle and cross-client behavior) and fills in the results table.
2. Tune Positions and Comm to the measured limits.
3. Step 5 polish.
4. Consider HMAC signing for synced records.

## Notes
- The libraries in `GuildAtlas/Libs` are vendored unmodified from pinned commits (listed in the README). HandyNotes and TomTom are separate addons the user installs.
- Git attribution, if commits are made, follows the session's commit reminder.
