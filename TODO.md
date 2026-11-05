# SawIt: to validate in game

Everything below is written and passes the offline tests (`tests/`), but has **not run in a WoW client**.
Tick items off as they are confirmed; write what you saw next to anything that fails.

**Before starting:** `GA.TEST_MODE` in `Core/Core.lua` is now `false` (2026-11-05); `/reload` after updating. With test mode on, nothing is sent,
and `/sawit secret` refuses to open. For the network items you need **two characters in the same guild**, both on this
SawIt version.

---

## 1. Guild secret and encryption (`Core/Crypto.lua`, `Core/Comm.lua`, `Modules/SecretDialog.lua`)

- [ ] **Login reminder.** In a guild with no secret set, you get one chat line: "No guild secret set ... /sawit secret".
- [ ] **Window.** `/sawit secret` opens above the world map (open the map first to check). Generate fills in a secret like
      `K7QWM-3PZXA-...` and highlights it; Ctrl+C copies it. Escape and Cancel close it and clear the box.
- [ ] **Save time.** Save runs the 1000-round key derivation. Note how long the game freezes. It takes ~1 s in plain Lua
      (LibHash uses pure arithmetic, not WoW's `bit` library, so the game may not be much faster).
      *If it's noticeable:* spread `Crypto.PBKDF2` over several frames (coroutine plus `C_Timer`). Don't lower
      `KDF_ITER` without also changing the salt version.
- [ ] **Check code.** Both characters enter the same secret. `/sawit status` shows the same check code (e.g. `6FA-40D`) on
      both.
- [ ] **Notes from a guildmate don't arrive** (reported 2026-11-05: both added notes in the same guild, neither sees
      the other's). On **both** characters, `/reload`, then `/sawit status` and compare:
      - a `TEST MODE` line: that copy is still old (`GA.TEST_MODE = true`); it sends and reads nothing.
      - "N note(s) from test mode": notes added in test mode are stored apart and are never shared. Add them again.
      - "Guild secret: not set", or different check codes: set the same secret on both (`/sawit secret`).
      - `roster=0`: the roster never loaded, so no sync hello goes out at login; `/sawit sync` sends one by hand.
      - "refused by the client" (with a result name) or "locked down": the client blocks our addon messages.
      - "not in the roster": the sender's name doesn't match the roster format (see section 7).
      Then `/sawit debug` on both, `/sawit sync` on A: A should print `tx H`, B `rx H` then `tx G`, A `rx G`, `tx Q`/`tx R`,
      and B `rx R`. The first side that misses a line is where it breaks; any `drop ... <reason>` line names the cause.
      Result (2026-11-05): same secret on both, yet each side's status counts the other's messages as "wrong secret"
      (unreadable: the seal doesn't open). Suspected: the server changes raw bytes, so the wire encoding is now
      printable only (`EncodeForPrint`, markers "3"/"F"). Re-test with the new copy on **both** sides:
      - [ ] check codes identical on both (`/sawit status`), not only the secret text.
      - [ ] "Own messages back from the server: N unchanged, 0 changed".
      - [ ] no "failed the seal" count; notes from the other side appear after `/sawit sync`.
      - [ ] if not: `/sawit debug`, `/sawit sync`, wait ~20 s, `/reload`, then run `tools/analyse_log.lua` on the
            SavedVariables (README, "Analysing real addon traffic"). Ask the guildmate for their `SawIt.lua` too.
- [ ] **Notes sync.** Add a note on A. It appears on B within a second or two (live `U` message). `/reload` B; the notes
      are still there, and sync after login works (`/sawit sync`, `/sawit stats`).
- [ ] **Positions.** `/sawit share on` on A (the minimap ring turns green). B sees A's dot. `/sawit share off` removes it at
      once.
- [ ] **Encoded messages go through.** Sealed messages go out as printable text (`LibDeflate:EncodeForPrint`, since
      2026-11-05; the raw-byte encoding before it was reported unreadable). `/sawit status` should show own messages
      back from the server as unchanged, and nothing that "failed the seal".
- [ ] **Wrong secret.** Give B a different secret. Nothing from A appears on B, and B's `/sawit status` shows the
      "failed the seal" count going up.
- [ ] **No secret.** `/sawit secret clear` on B. B sends nothing (A sees no dot or notes from B), and B's status shows
      "while no secret was set" counts.
- [ ] **Sync bursts.** With a few dozen notes, `/sawit sync` on a fresh character. Watch for frame hitches while records
      arrive (each message is sealed and opened: a few ms per 600-byte chunk offline).
- [ ] **Changing the secret.** Change it on both; notes made afterwards sync. Old notes stay local on each side (expected).

## 2. Chat link for notes (`POIMap.MapPinLink`, `ChatText`, `InsertInChat`, `ShareToGuild`)

- [ ] **Link format.** Ctrl+click the world map to place a Blizzard pin, then `/dump C_Map.GetUserWaypointHyperlink()`.
      Compare it with what Shift+clicking a note puts in the chat box. Colour (`ffffff00`), coordinate scale (`x*10000`)
      and the `[...Map Pin Location]` text with the atlas icon must match exactly.
      *If not:* adjust `POIMap.MapPinLink` (the only place the link is built).
- [ ] **It arrives.** Send a Shift+clicked note in /say and in a whisper. The message arrives and isn't silently dropped;
      per Wowpedia, the server rejects map-pin links whose text or colour were changed.
- [ ] **It works for others.** Clicking the link, on a character without SawIt too, places the pin at the note's spot.
- [ ] **Chat box handling.** Shift+click with the chat box open inserts at the cursor; with it closed, it opens the box.
      This uses `ChatFrameUtil.InsertLink`/`OpenChat`, falling back to `ChatEdit_InsertLink`/`ChatFrame_OpenChat`.
- [ ] **Plain click.** It posts `[Category: Title] <link> details` to guild chat and does **not** replace your own map pin.
- [ ] **Other languages.** On a non-English client the link text comes from `MAP_PIN_HYPERLINK`; confirm the global
      exists (`/dump MAP_PIN_HYPERLINK`).

## 3. Waypoints without TomTom (`POIMap.WaypointTo`, `PlaceMapPin`)

- [ ] **Ctrl+click a note.** It places WoW's map pin at the note and prints "Map pin set: ...". It replaces any pin you
      had (expected).
- [ ] **Tracking.** `C_SuperTrack.SetSuperTrackedUserWaypoint(true)` shows the on-screen marker with distance. If
      `C_SuperTrack` is missing, the pin still appears on the map.
- [ ] **Guildmate dots.** Clicking a dot does the same, at their position.
- [ ] **With TomTom installed.** Both use a TomTom waypoint instead.

## 4. Note pins on the map (`Modules/POIMap.lua`, `Media/circle.tga`, `Media/pinring.tga`)

- [ ] **Round.** The icon is clipped to a circle. `CreateMaskTexture`/`AddMaskTexture` should exist on this Mainline
      client; if not, the code falls back to square icons inside the ring.
- [ ] **Contrast.** The black-edged ring in the category colour (magenta rare, red grind, cyan quest, white other) reads
      well on parchment, desert, forest, snow and water maps.
- [ ] **Sizes.** 22 px on the world map and 16 px on the minimap look right, at different map zooms and UI scales.
- [ ] **Icons exist.** The category icons in `POI.CATEGORIES` exist on this client (a missing one shows as a green
      square/circle).
- [ ] **Stacked notes.** Two notes at one spot share a pin with a count; the tooltip lists both with title and details.
- [ ] **Map button.** The world-map toggle button (top right, x -40) doesn't overlap Blizzard's buttons; click hides and
      shows pins.
- [ ] **Minimap pins.** They follow the minimap and hide at the edge (`AddMinimapIconMap(..., false, false)`).

## 5. Note windows and commands

- [ ] **Add-note window.** It has Title and Details fields, Tab switches between them, Enter saves. It opens from the
      minimap button (your position) and from Shift+right-click on a zone map (clicked spot). On a continent map it says
      to zoom in.
- [ ] **Map clicks.** Shift+right-click adds a note and does not also zoom the map out. Plain right-click still zooms out.
- [ ] **Delete window.** Right-click a pin holding your note: the window lists only your notes (officers: all) and
      appears above the world map. The right-click itself doesn't zoom the map out. Delete removes the note on both
      characters; right-click on someone else's note prints the author/officer message.
- [ ] **Slash commands.** `/sawit my`, `/sawit my here`, `/sawit list`, `/sawit add rare Title; details`,
      `/sawit edit <id> New title` (details kept), `/sawit del <id>`, `/sawit help`. A typo such as `/sawit stauts`
      prints "unknown command" and adds nothing.
- [ ] **Officer rank.** Officer detection uses `poi.officerRankIndex` (default 1 = GM and the first officer rank). Check
      it matches the guild's ranks.

## 6. Live positions (`Modules/Positions.lua`)

- [ ] **Dots.** They're round and class-coloured with a black edge, on the world map and minimap.
- [ ] **Timing.** A send every ~4 s while moving, a 12 s keepalive when standing, expiry after 30 s. Nothing is sent in
      instances, battlegrounds or combat (defaults).
- [ ] **Roster data.** `GetGuildRosterInfo` returns class and rank as expected (tooltip: level and class).

## 7. Client and transport limits (from the original prototype checklist in the README)

- [ ] **Message size.** The 255-byte addon message limit and what happens at 256 (AceComm splits larger messages).
- [ ] **Throttling.** Burst and regeneration throttle, and whether throttled messages are dropped or delayed. Tune
      `RECORDS_PER_MSG` and the position interval to it.
- [ ] **Messaging lockdown.** When `C_ChatInfo.InChatMessagingLockdown()` turns on (combat, encounters). Messages
      dropped then should be recovered by the next sync.
- [ ] **Secret values.** Whether received text or sender names ever arrive as secret values (`issecretvalue` guards).
- [ ] **Connected realms (known limitation, decide after checking).** Find out whether Forever guilds can have members
      from another (connected) realm: `/dump GetGuildRosterInfo(1)` shows "Name-Realm" for them. If they can:
      authors and `updatedBy` are stored as `UnitName("player")` (no realm), but POI's live check compares them with
      `GA:Normalize(sender)`, which keeps the realm for other-realm players, and `GA:IsOfficer` looks the realm-less
      name up in a roster keyed with realms. So a cross-realm guildmate's live edits are rejected (their notes only
      arrive through sync relays) and cross-realm officers aren't treated as officers. Fix: one name format
      everywhere ("Name-Realm" for storage, roster and checks). The encryption is unaffected (it binds the name
      without realm on both ends).

## 8. Before sharing the addon

- [x] `GA.TEST_MODE = false` in `Core/Core.lua` (2026-11-05).
- [ ] Bump `## Version` in `SawIt.toc` and `GA.VERSION` in `Core/Core.lua`.
- [ ] Replace the placeholder `## X-Curse-Project-ID: 999999` in `SawIt.toc`, or remove it.
- [ ] Every guildmate on the same version. Older SawIt and standalone GuildAtlas can't talk to this version.

---

## Later: crypto performance (review once in-game timings from section 1 are known)

Measured offline (plain Lua) since switching to LibHash-1.0: key derivation on Save ~1 s, seal + open of a 2 KB sync
message ~140 ms, a position packet ~4 ms. Options, without modifying LibHash (keep it a drop-in dependency):
- [ ] **Precompute the HMAC key pads.** `LH.hmac` re-hashes the padded key on every call; `Crypto.lua` calls it with the
      same two keys over and over (one call per 32 keystream bytes, plus the tag). LibHash's chunked API
      (`LH.sha256()` returns an appender) may allow keeping the inner/outer states, or cache per context.
- [ ] **Avoid hex round trips.** Every LibHash result is hex and goes through `hex2bin`.
- [ ] **Native `bit` library.** LibHash uses arithmetic lookup tables, never WoW's `bit`. Compare with upstream
      pure_lua_SHA (newer than the 2020 port, detects `bit`) before considering a swap.
- [ ] **Spread work over frames.** PBKDF2 on Save and big sync bursts could run in a coroutine via `C_Timer`.
Any change must keep `tests/test_crypto.lua` passing (Python reference values), so output stays byte-identical.
