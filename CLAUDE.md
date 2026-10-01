# CLAUDE.md: SawIt

SawIt (Shared Atlas Worldwide Information Tracker) is a WoW addon for **WoW Forever** (beta, game type `camelot`, build
1.60.1, Interface 16001). It shares two things between guildmates over encrypted addon messages:
- **notes**: persistent points of interest with a category, title and details;
- **live locations**: guildmates as dots on the world map and minimap.

Owner: Marcus (engineering manager; technical depth is fine, keep answers direct).

**Nothing has run in a WoW client yet.** Everything is verified only by the offline tests. The in-game checklist is
**`TODO.md`**: read it first, add to it whenever you write something that can only be verified in game, and tick items
off when Marcus reports results.

## Docs in this folder

| File | What |
|---|---|
| `TODO.md` | in-game validation checklist (everything untested), plus the pre-release steps |
| `README.md` | user-facing docs: commands, guild secret, trust model, wire formats, file layout, "Unverified" table |
| `HANDOFF.md` | chronological history of decisions (oldest parts mention MarcusAddon/GuildAtlas/HandyNotes: superseded) |
| `NOTES-client-research.md` | what the Forever client is (Mainline/Midnight API with secret values and lockdown), with evidence |

Keep README, HANDOFF and TODO in sync with code changes. Existing docs use dated bullets ("(2026-09-30)").

## Layout (load order = `SawIt.toc`; modules are enabled in creation order)

```
embeds.xml               libraries: Ace3 (Addon, Event, Console, DB, Serializer, Comm+ChatThrottleLib), LDB, LibDBIcon,
                         HereBeDragons-2.0 + Pins, LibDeflate, LibHash-1.0 (all vendored unmodified; all required:
                         loaded with LibStub(name), no "is it there?" checks in the code)
Core/Core.lua            addon object GA (= ns.addon = _G.SawIt), AceDB "SawItDB", TEST_MODE flag, guild helpers,
                         guild secret storage, roster cache, player position, /sawit (+ aliases /guildatlas, /gatlas)
Core/Crypto.lua          PBKDF2, Seal/Open (encrypt + 80-bit tag), nonces, RandomSecret on top of LibHash's SHA-256/HMAC
Core/Comm.lua            prefixes GAtlasD (data) and GAtlasP (positions); seal/open, compression, rate limits, handlers
Core/UI.lua              GA.CreateWindow / GA.CreateButton: the look and behaviour every SawIt window shares
Modules/POI.lua          note records, validation, permissions, sync (hello/digest/request/records), note subcommands
Modules/POIMap.lua       note pins (HBD-Pins), tooltips, clicks, chat link, waypoints, filters, world-map button + click hook
Modules/Positions.lua    14-byte position packet, send policy, expiry, round class-colored dots
Modules/NoteDialog.lua   add-note window (category list, Title, Details)
Modules/DeleteDialog.lua right-click delete window (only notes you may delete)
Modules/SecretDialog.lua /sawit secret window (enter, Generate, Remove, check code)
Modules/MinimapButton.lua LDB/LibDBIcon button, sharing ring (green sent / orange blocked / hidden off)
Media/                   icon.tga (AZB), ring.tga (minimap ring), circle.tga (pin mask), pinring.tga (black-edged pin ring)
tests/                   offline tests, see below
Utils.lua                stray one-liner, not in the .toc (unused)
```

## Running the tests (always, after any change)

Lua 5.1 is installed user-locally: `~/.local/bin/lua5.1`, `luac5.1` (from `~/.local/opt/lua5.1`). Run from this folder:
```
luac5.1 -p <changed files>       # syntax
lua5.1 tests/test_crypto.lua     # crypto (LibHash + our constructions) vs Python hashlib/hmac vectors
lua5.1 tests/test_poi.lua        # records, permissions, titles, 4-client sync convergence, position packet
lua5.1 tests/test_load.lua       # loads every .toc file against stubbed WoW API; UI, clicks, commands, secret, round trip
```
Every suite ends with `ALL PASSED`. `test_load` prints "note: GA.TEST_MODE is ON" while the flag is on; that's fine.
Test-harness quirks:
- The stub `Frame` metatable returns a function for **any unset field**. Never keep state in a nilable field on a frame
  (e.g. `row.id = nil`); keep it in plain Lua tables.
- `C_Timer.After` is a no-op in `test_load`; call `POIMap:Redraw()` directly.
- Tests set `GA.Crypto.KDF_ITER = 2`; the real 1000 rounds are slow in plain Lua.
- New crypto test vectors must be generated with Python (`hashlib`, `hmac`), never typed from memory.

## Conventions

- **Guild/network state only through Core helpers:** `GA:IsTestMode()`, `InRealGuild()` (the only `IsInGuild()` call),
  `InGuild()`, `GetGuildName()`, `GetGuildKey()` (store key "Guild-Realm"), `CanUseNetwork()` (real guild, not test mode,
  secret set), `NetworkBlockReason()`, `NetContext()`.
- **"secret" is taken.** `GA.isSecret` means WoW's *secret values* (`issecretvalue`). The guild secret uses GuildSecret /
  netKeys / NetContext naming.
- **No home-made crypto primitives.** SHA-256 and HMAC come from LibHash-1.0; `Crypto.lua` only combines them
  (PBKDF2, HMAC counter-mode stream, encrypt-then-MAC). Keep it that way; any change must keep the Python vectors.
- **Addon-message security:** every message on both prefixes is sealed. Never add a path that accepts plaintext, and
  check the seal (`Crypto.Open`) before decompressing or deserializing. Rate limits run before any crypto work. The tag
  binds kind (`"D"`/`"P"`) and the sender name without realm (`short()` in Comm.lua).
- **Note permissions:** author or officer (`POI:MayWrite` on receive, `POI:CanModify` for local UI).
- **UI windows:** build them with `GA.CreateWindow` / `GA.CreateButton` (Core/UI.lua: strata `FULLSCREEN_DIALOG` above
  the world map, draggable, Escape via `UISpecialFrames`). **No StaticPopup** (it sits below the map) and no
  UIDropDownMenu/Menu API (hand-built lists instead).
- **Guard uncertain APIs** with fallbacks: `C_*` namespaced first, then old globals (e.g. `ChatFrameUtil.InsertLink` →
  `ChatEdit_InsertLink`). The client is Mainline; Classic-only globals can't be assumed.
- **Chat map-pin links** must stay byte-identical to `C_Map.GetUserWaypointHyperlink()`; only map and coordinates may
  differ, or the server drops the message. Custom text goes outside the link.
- **Code style:** match the surrounding code. File header block comment explaining the *why*, section rulers
  (`-----` + `-- title`), short comments on non-obvious lines only, `local` helpers, 4-space indent, lines ≤ ~120 chars.
  Pure logic stays WoW-API-free where possible so `test_poi`/`test_crypto` can load it.
- Adding a file: add it to `SawIt.toc` in dependency order and to the README layout list.

## How the files work together

Dependencies point downwards; nothing in Core depends on a module at load time.
```
Core (state, guild secret, roster, /sawit)   Crypto (pure)   UI (window builders)
  └─ Comm (sealed transport, two prefixes)
       ├─ POI (note data, sync, note commands) ──calls──> POIMap setters (filter/map/minimap commands)
       │    └─ POIMap (pins, pin actions, map button)   NoteDialog   DeleteDialog
       └─ Positions (location packets, dots) ──calls──> POIMap.WaypointTo (dot click)
SecretDialog -> Core secret functions          MinimapButton -> Positions, POI, NoteDialog
```
Internal messages (AceEvent, in-process only):

| Message | Sent by | Listened to by |
|---|---|---|
| `SAWIT_NOTES_CHANGED` (id) | POI:Apply | POIMap (redraw) |
| `SAWIT_ROSTER_UPDATED` | Core:RosterEvent | Positions (class colours) |
| `SAWIT_SHARING_CHANGED` (on) | Positions:SetSharing | MinimapButton (ring) |
| `SAWIT_SECRET_CHANGED` | Core (set/clear secret) | POI (sync hello), MinimapButton (ring) |

## Formats (details in README and file headers)

- **Note record:** `id, rev, author, updatedBy, mapID, x, y, text (<=120), cat, deleted, title (<=40)`.
  - Wire form: a positional array; `title` is field 11, so old 10-field records are still accepted with an empty title.
  - Conflicts: highest `rev` wins, ties broken by `updatedBy`. Deletes are tombstones, kept 180 days.
- **Data messages:** `"2" .. EncodeForWoWAddonChannel(Seal("D", "0"|"1" .. AceSerializer(PROTO=1, type, payload)))`,
  where `"1"` means deflated. Types: `U` live update, `H` hello, `G` digest, `Q` request, `R` records.
- **Position packets:** `"E" .. EncodeForWoWAddonChannel(Seal("P", packet))`, where the packet is `"1"` + mapID(5) + x(4)
  + y(4), or `"0"` for "stopped sharing".
- **Guild secret:** PBKDF2-HMAC-SHA256 (1000 rounds, salt `"SawIt guild secret v1|" .. guildName`) gives the master key,
  from which K_enc, K_mac and the check code are derived by HMAC labels. Stored in
  `SawItDB.global.netKeys["Guild-Realm"] = { key = hex, check = "ABC-DEF" }`; never the secret text itself.

## Environment and research

- Addon path: `.../World of Warcraft/_classic_beta_/Interface/AddOns/SawIt` (Proton prefix under Steam). Git repo
  (local only, branch `main`, no remote). Commit only when Marcus asks; Libs/ are vendored and committed.
- The client's own Lua (FrameXML) isn't extracted. To check whether an API or string exists, run
  `strings -n 5 ../../../WowB.exe | grep ...` (from this folder). The matching Blizzard UI source is
  [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source), tag `1.60.1`, branch `forever`. For API docs:
  warcraft.wiki.gg.
- **TEST_MODE** (`Core/Core.lua`) is currently `true` for solo testing. It pretends to be in guild "AZB Test", and nothing
  is sent or read. It must be `false` for any network or guild-secret testing and before release.

## Open ideas (not built; offered to Marcus)

- An Edit button in the delete window (reusing the add-note window prefilled).
- A chat filter so SawIt users see `[Cat: Title]` as the clickable part of shared links (local display only).
- Crypto performance review (HMAC key-pad caching, hex round trips, native `bit`, spreading work over frames):
  see the "Later: crypto performance" section of `TODO.md`.
- Per-player signatures for relayed sync records (a shared secret can't prove authorship).
