# SawIt: Shared Atlas Worldwide Information Tracker

Formerly MarcusAddon (renamed 2026-09-30), with GuildAtlas merged in.

> **Merged layout.** GuildAtlas now lives inside `SawIt/` as modules of the one `SawIt` addon object:
> `Core/Core.lua` creates the addon and the only AceDB (`SawItDB`), `Core/Comm.lua` + `Modules/*.lua` started as
> GuildAtlas code (Comm now encrypts with the guild secret), `Modules/NoteDialog.lua` is the add-note window, and `Modules/MinimapButton.lua` is the minimap button
> (left-click add note at your position, shift-left-click status, right-click toggle sharing).
> Since the guild secret (2026-09-30) every message is encrypted, so SawIt no longer talks to standalone GuildAtlas or
> older SawIt versions: every guildmate needs this version and the same guild secret.
> Where this README says `GuildAtlas/`, read `SawIt/`. The prototype `GuildAtlasProto/` is not part of this folder.


Guild-only addon for a small guild (50 or fewer) on **WoW Forever** (beta). Two modules on one comm layer:

0. **Guild secret**: all addon traffic is encrypted and authenticated with a secret the guild's members enter
   (`/sawit secret`). Without it SawIt shares and receives nothing, so the addon can be published and each guild's data
   stays readable only by members who have their secret. See "Guild secret" below.

1. **Live locations** (ephemeral): guildmates as class-colored dots on the world map and minimap.
2. **Points of Interest** (persistent): short notes with a category at map coordinates, synced to every
   addon user, drawn as our own map pins (HereBeDragons). HandyNotes is no longer used.

This repo currently contains:

| Folder | What | State |
|---|---|---|
| `GuildAtlasProto/` | Build step 2: standalone prototype with no Ace dependency, used to test the beta's API assumptions | complete |
| `GuildAtlas/` | The real addon: Core, Comm, POI (records and sync), POIMap (own HBD pins), Positions | Comm and POI are real; Positions and POIMap are first-pass and untested in game |
| `tests/test_poi.lua` | Offline tests (plain Lua 5.1) for POI permissions, validation, sync convergence and the position packet | passing |
| `tests/test_crypto.lua` | SHA-256/HMAC (LibHash), PBKDF2 and seal/open against Python `hashlib`/`hmac` reference values | passing |

> Nothing here has been run inside a WoW client yet. Code was syntax-checked with `luac5.1`, and the
> record/sync logic plus the serializer/compression round trip were exercised offline. Every in-game
> assumption is listed in the checklist and in "Unverified" below.

---

## Installation

1. Copy the folder(s) into the game's AddOns directory. On this install the folder is
   `World of Warcraft/_classic_beta_/Interface/AddOns/` (the client loads SawIt from there). Other installs may
   differ (other flavors use `_classic_`, `_classic_era_`, `_retail_`).
   - `SawIt/` for the full addon (GuildAtlas merged in).
   - `GuildAtlasProto/` for the prototype (optional; separate prefix, runs fine next to SawIt).
2. Optionally install **TomTom** (Ctrl-click waypoints; without it Ctrl-click places WoW's own map pin) from
   CurseForge/Wago like any other addon. They are deliberately **not** embedded: they are full addons, not libraries.
3. At the character select screen open **AddOns** and tick **Load out of date AddOns** if anything is greyed out
   (see the Interface version note).
4. Every guild member who wants to participate needs the same addon folder.
5. **Do not install standalone `GuildAtlas/` next to `SawIt/`** on the same client: both register the same prefixes,
   `_G.GuildAtlas`, so messages are handled twice. `GuildAtlasProto` is fine (own prefix).

### Libraries

Vendored unmodified in `GuildAtlas/Libs/` (and the HBD/LibStub subset in `GuildAtlasProto/Libs/`):

| Library | Source / revision | Use |
|---|---|---|
| LibStub, CallbackHandler-1.0 | Ace3 `a360495` | plumbing |
| AceAddon, AceEvent, AceConsole, AceDB | Ace3 `a360495` | addon object, events, slash, SavedVariables |
| AceComm-3.0 + ChatThrottleLib | Ace3 `a360495` | throttled sending, multi-part split/reassembly |
| AceSerializer-3.0 | Ace3 `a360495` | POI payload serialization |
| LibDeflate | SafeteeWoW/LibDeflate `afc3b78` | compression of data messages over 80 bytes, and the addon-channel encoding of sealed messages |
| HereBeDragons-2.0, -Pins-2.0 | Nevcairiel/HereBeDragons `0547c95` (MINOR 33) | coordinates and map/minimap icons |
| LibHash-1.0 | CurseForge project 383484, file 1.0.0 (2020-05-14), port of Egor Skriptunoff's pure_lua_SHA v9, MIT | SHA-256 and HMAC for the guild secret (`Core/Crypto.lua`) |

`Libs/embeds.xml` is the single load list. Ace3's own `.toc` (checked when this was written) already lists
interface `16001`, so Ace3 is known to target this client. HereBeDragons' and HandyNotes' own `.toc` files did not list 16001,
only `11509`/`120100` etc.; embedded copies are not affected by that, the standalone HandyNotes addon may show as "out of date".

---

## Slash commands

### Prototype (`/gap`)
| Command | Does |
|---|---|
| `/gap probe` | Prints build/TOC number, API presence, prefix registration, position result, library status. Run this first. |
| `/gap pos` | Prints your current map position and the exact packet that would be sent |
| `/gap ping` | Sends a GUILD message; every other prototype client answers; prints RTT |
| `/gap sizes` | Sends 50/100/200/255/256/300-byte messages to GUILD, 2 s apart; receivers print the length they got |
| `/gap burst [n]` | Sends n (default 30, max 200) messages back to back; prints the send result histogram; receivers print how many arrived |
| `/gap start`, `/gap stop` | Position broadcast every 4 s when moved (keepalive 12 s); skipped in instances |
| `/gap pin` | Puts a red world-map square and a green minimap square slightly east of you for 60 s (HereBeDragons pins) |
| `/gap hn` | Registers a test HandyNotes plugin and drops a note at your position |

### Full addon
| Command | Does |
|---|---|
| `/sawit` (old aliases `/guildatlas`, `/gatlas`) `status` | version, guild, roster size, guild secret and check code, unreadable-message counts, TomTom, sharing state |
| `/sawit help` | lists all commands |
| `/sawit secret` | window to enter, generate or remove the guild secret; shows the check code. `/sawit secret clear` removes it |
| `/sawit share [on\|off]`, `pause` | location sharing is **opt-in and off by default** |
| `/sawit debug` | toggles debug output |
| `/sawit add [category] <title>[; details]` | add a note at your current position (categories: `rare`, `grind`, `quest`, `other`), e.g. `/sawit add rare Mother Fang; near the cave`. Needs the word `add`, so a mistyped command never becomes a note |
| Note pin clicks | Shift-click: put `[Category: Title] [Map Pin Location]` in the chat box (like an item link). Click: post it to guild chat. Ctrl-click: waypoint. Right-click: delete window for your own notes at that pin (any note for officers) |
| `/sawit my [here]` | your own notes (the ones you can edit and delete), with their ids |
| `/sawit list [here]`, `/sawit del <id>`, `/sawit edit <id> [category] <title>[; details]` | all notes; manage notes (only the author or an officer may edit/delete) |
| Shift+right-click on the world map | add a note at the clicked spot (zone maps; on a continent it says to zoom in) |
| `/sawit filter [category]`, `/sawit map`, `/sawit minimap` | show/hide a category; show/hide note pins on the world map (same as the AZB button in the map's top-right corner) or the minimap |
| `/sawit sync`, `/sawit stats`, `/sawit cats` | force a hello/sync, show counts and traffic, list categories |

---

## In-game test checklist (the three beta assumptions)

Setup: install `GuildAtlasProto` on **two characters in the same guild** (two accounts, or a guildmate).
With one character you can only prove the send/echo path, not loss, throttling or cross-client behavior. Log in, both
should print `[GAProto] loaded`. Paste the output lines you get back; PASS/FAIL lines are colored.

### First: what build is this?
```
/run print(GetBuildInfo())
```
Record the 4th value (TOC/interface number). If it is not `16001`, edit the `## Interface:` line in both `.toc` files.

### (a) Addon messages on GUILD, and the limits
1. `/gap probe` on both. Expect PASS for `player is in a guild` and `prefix 'GAProto' registration`. Note whether
   `C_ChatInfo.InChatMessagingLockdown` exists (Midnight-style lockdown API) and its value.
2. `/gap ping` on A. Expect on A: an immediate `RX GUILD PING ... (self-echo)` (proves GUILD echo behavior), then
   `PONG from B` with an RTT. On B: `RX GUILD PING from A`.
   - FAIL here means GUILD addon messages do not work, or the prefix was not registered. Everything else depends on this.
3. `/gap sizes` on A. Expect B to print PASS for 50/100/200/255. Observe what happens at **256 and 300**: a thrown
   error, a result like `InvalidMessage`, or silent truncation. This confirms the 255-byte limit.
4. `/gap burst 30` on A, then `/gap burst 100`. Observe (i) the send-result histogram on A (`Success` vs
   `AddonMessageThrottle`/`ChannelThrottled`/other), (ii) B's summary `received X of N`. This shows the burst budget and
   whether throttled messages are dropped (what we assume) or delayed. ChatThrottleLib paces to stay under this, so the
   answer sets our safe rate.
5. While in combat (attack a mob), repeat `/gap ping`. If the send result says something like `AddOnMessageLockdown`, the
   client locks addon comms in combat/encounters; note exactly when.
6. `/gap probe` and look at `secret` lines: if received text or sender shows `secret-value ... ignored`, the client
   hides message contents in some contexts.

### (b) Position APIs in the open world
1. Stand in a zone: `/gap pos`. Expect `map=<id> x=0.xxxx y=0.xxxx` and a 14-ish byte packet. Also check that the
   `HereBeDragons:GetPlayerZonePosition` line in `/gap probe` agrees.
2. Walk: values change, x/y within 0..1. Open the world map and compare with the map's own coordinates display (if any).
3. `/gap start` on A, walk around. B should print `POSITION map=... x=... y=...` about every 4 s, and every 12 s
   while A stands still.
4. Enter a dungeon/instance and `/gap pos`: expect `no position` and `/gap start` to send nothing. Also try a
   battleground/arena if available. Also check a city, a capital sub-zone and a cave (nested maps).
5. Note any `nil`/`secret`/`0,0` result outside instances.

### (c) HereBeDragons and HandyNotes
1. `/gap probe`: `HereBeDragons-2.0 (embedded)` and `-Pins-2.0` PASS (shows MINOR 33). `HandyNotes addon loaded` PASS.
2. `/gap pin`, open the world map: a red square next to your arrow; minimap: a green square. Walk away from it on the
   minimap and check the green square pins to the edge. Both vanish after 60 s.
3. `/gap hn`: expect PASS for `RegisterPluginDB`, then a `GetNodes2(uiMapID=..., minimap=...)` line when you open the
   map. A note icon appears on the world map and minimap. Hover it: `OnEnter(self=Button, ...)` line and a tooltip;
   click: `OnClick` line.
   - If you see nothing, open HandyNotes' options, Plugins, and make sure `GuildAtlasProto` is enabled.
   - No `GetNodes2` line at all means this client's HandyNotes only uses the legacy API: tell me.

Write the results into the table below before we build step 4 and 5.

| Check | Result | Notes |
|---|---|---|
| TOC number | | |
| GUILD send + self-echo | | |
| 255-byte limit / behavior at 256 | | |
| Burst: sent / received | | |
| Combat or encounter lockdown | | |
| C_Map position in open world | | |
| nil in instance | | |
| HBD pins world map / minimap | | |
| HandyNotes GetNodes2 / OnEnter / OnClick | | |

---

## Formats

### Transport
- Prefixes: `GAtlasD` (data) and `GAtlasP` (positions). Channel `GUILD`, or `WHISPER` for directed sync replies.
- Priorities (ChatThrottleLib): `ALERT` live POI edits, `NORMAL` sync traffic, `BULK` positions. Each priority has its
  own queue, so positions never queue in front of POI data.

### Data message (`GAtlasD`)
```
<flag><body>
  flag "0": body = AceSerializer:Serialize(PROTO, msgType, payload)
  flag "1": body = EncodeForWoWAddonChannel(CompressDeflate(that string))
```
`PROTO` is currently **1**. A receiver drops anything whose PROTO differs and, if it is newer than its own, prints a
one-time "update the addon" note. Flag "1" is only produced when it is actually smaller; a client without LibDeflate
drops flag-"1" messages instead of erroring. Measured offline: one live-update envelope is about 175 bytes
(143 compressed), six records batched about 1 KB (163 compressed).

| type | direction | payload | meaning |
|---|---|---|---|
| `U` | GUILD | packed record | live create/edit/delete |
| `H` | GUILD | `{count, checksum}` | "hello" after login; checksum = sum of `hash(id:rev)` mod 2^32 over all records incl. tombstones |
| `G` | WHISPER to requester | `{id1, rev1, id2, rev2, ...}` | digest, sent by peers whose state differs, after a random 1-6 s delay |
| `Q` | WHISPER | `{id, ...}` (max 100 read) | "send me these" |
| `R` | WHISPER | `{packed, ...}` (6 per message, max 20 read) | records |

### Sync flow
Login, random 5-15 s, once the roster is known: broadcast `H`. Peers with an identical `{count, checksum}` stay silent.
Others answer with `G`. The requester replies to each digest with `Q` for what it lacks or what is older, and pushes `R`
for what it has that the peer lacks or has older (so sync is two-way). Live changes go out immediately as `U`.
Conflicts: higher `rev` wins; equal `rev` breaks on `updatedBy`. Digests are only accepted for 180 s after our own hello.

### POI record
```
id        string  [%w]{1,24}
rev       number  max(time(), old.rev + 1)
author    string  immutable
updatedBy string  author or an officer
mapID     number  uiMapID
x, y      number  0..0.9999, 4 decimals
text      string  <= 120 bytes; control characters and '|' removed
cat       string  rare | grind | quest | other
deleted   bool    tombstone (text emptied)
```
Packed (positional array): `{ id, rev, author, updatedBy, mapID, xq, yq, text, cat, del }`, `xq/yq` integers 0..9999,
`del` 0 or 1. Every field is type- and range-checked on receipt; unknown categories become `other`.

### Position packet (`GAtlasP`, no serializer)
```
"1" mapID(5) x(4) y(4)     14 bytes, e.g. 10142945216033 = map 1429, x 0.4521, y 0.6033
"0"                        stopped sharing; receivers remove the dot immediately
"2"...                     reserved for a batch/relay format; ignored today
```
Send policy: check every 4 s (up to 10 s with many members online); send when moved more than 0.2 % of the map or the
map changed; else resend an unchanged position only every 12 s. Receivers expire entries after 30 s.
Never saved. Skipped in instances, optionally in combat and PvP. Level and class come from the guild roster.

---

## Guild secret

Every guildmate using SawIt enters the same secret (`/sawit secret`; an officer can press Generate and hand the result
out privately, e.g. in a Discord officer channel, never in guild chat). SawIt then:

- derives a key from it (PBKDF2-HMAC-SHA256, 1000 rounds, salted with the guild name) and stores only that key and a
  check code in `SawItDB`, per guild and realm, account-wide. Guildmates compare check codes (`/sawit status`) to confirm they
  typed the same secret;
- encrypts every message on both prefixes (HMAC-SHA256 in counter mode) and adds an 80-bit tag bound to the channel
  and the sender's name, checked before anything else is done with a message (`Core/Crypto.lua`, `Core/Comm.lua`).
  SHA-256 and HMAC come from the LibHash-1.0 library; SawIt only combines them;
- sends nothing without a secret, and drops everything that isn't sealed with its key: unencrypted messages (older
  versions, or a member without the secret), a wrong secret, tampering, a message re-sent by another player.
  `/sawit status` counts these, so a mistyped secret is visible.

What it protects: guild members who don't have the secret (alts, recruits, a public guild) and anyone whispering sync
requests with a client that claims to be in the guild. Neither can read notes or positions or inject any.
What it does not:
- Everyone with the secret is equally trusted by the crypto: the tag proves "a secret holder sent this", not which
  member wrote a note. Note permissions (author/officer) still rest on the server's sender name, with the relay
  limitation below.
- Notes are stored unencrypted in your own SavedVariables.
- Someone who leaves or is removed keeps what they already received, and the secret, until an officer sets a new one
  (everyone then enters the new secret).
- A weak secret can be guessed offline by someone who recorded guild traffic, which only guild members can. Use
  Generate (100 bits) or a long passphrase.
- Randomness: nonces and generated secrets come from SHA-256 over the clock, a high-resolution timer, `math.random`,
  cursor position, key-press timing and message timing. WoW has no secure random API for addons; a generated secret is
  as unpredictable as those sources.

## Trust model and known limits

- **Sender names are authentic, content is not.** The server attaches the real sender name; the guild secret proves
  the sender holds the secret, nothing more. `U` messages must have `updatedBy == sender`. Permissions: only the author
  or an officer (guild rank index 0..`poi.officerRankIndex`, default 1) may change a note.
- **Relayed sync records cannot be verified.** In `R` messages the sender is the peer relaying, not the author, so
  `updatedBy` is a claim. A modified client *with the guild secret* could therefore forge a record "by" an officer during
  sync. Fixing that needs per-player signatures, which a shared secret cannot provide.
- **Connected realms are not handled.** Names are stored without realm; a guildmate from another realm would have
  their live edits rejected (notes still arrive through sync) and wouldn't count as an officer. Details and the fix
  in `TODO.md` section 7.
- Tombstones are kept 180 days. A member offline for longer than that could resurrect a deleted note.
- `rev` is wall-clock based; revs more than 24 h ahead of the receiver's clock are rejected.
- Two notes at the same 4-digit coordinate share one map pin (tooltip lists all, pin shows a count).
- Digest size grows with the number of notes (about 18 bytes each). Fine up to a few hundred; switch to per-map hashes if it grows.
- Hello answers are not deduplicated across peers (up to 49 digests to a fresh install). Marked TODO in `POI.lua`.

## Differences from the original spec

- **Expiry 30 s, plus a 12 s keepalive.** "Send only when moved" together with "expire after 15-20 s" would make every
  standing player vanish. Stationary players resend every 12 s; expiry is 2.5x that.
- **Stop packet `"0"`** added so turning sharing off removes your dot at once.
- Timers use `C_Timer` (no AceTimer), so the full addon assumes a client with `C_Timer`.
- Adding from the map: **Shift+right-click** on the world map opens the note window at that spot (zone-level maps only). The minimap button
  (left-click) and `/sawit add` add at your own position.

## Unverified (TODO markers in the code)

The step-by-step in-game checklist for all of this is **`TODO.md`**.

| Item | Status |
|---|---|
| **Interface number** | **Confirmed 16001**: installed build is 1.60.1.70124 (1×10000 + 60×100 + 1). See `NOTES-client-research.md`. |
| Client API surface | **Confirmed Mainline (Midnight 12.x) family**, game type `camelot`, secret values and messaging lockdown present; every Blizzard API we call exists in the client. Behaviour (limits, when lockdown triggers) still untested. See `NOTES-client-research.md`. |
| Addon message limits | 255 bytes per message and a burst/regen throttle are the standard values; Forever's are what the `sizes`/`burst` tests measure. |
| Lockdown | `C_ChatInfo.InChatMessagingLockdown` exists on recent Mainline; `Comm:IsLockedDown()` uses it if present. Dropped messages are recovered by the next hello/sync. |
| Guild roster API | `GetGuildRosterInfo`, `C_GuildInfo.GuildRoster` assumed. Names may carry a realm suffix; all names go through `Ambiguate(name, "none")`. |
| POI icons | Classic `Interface\Icons\...` texture names in `POI.CATEGORIES`; confirm they exist. |
| Map pin link | Built by `POIMap.MapPinLink` as `\|cffffff00\|Hworldmap:<map>:<x*10000>:<y*10000>\|h[MAP_PIN_HYPERLINK]\|h\|r`, i.e. the same string `C_Map.GetUserWaypointHyperlink` returns, so no pin is placed. The server rejects the message if colour or text differ (only map and coordinates may), so the note title is plain text before the link. Check: `/dump C_Map.GetUserWaypointHyperlink()` after placing a pin should match, and a shift-clicked note sent in /say should arrive. Chat box insert uses `ChatFrameUtil.InsertLink`/`OpenChat` or `ChatEdit_InsertLink`/`ChatFrame_OpenChat`, whichever exists. |
| Waypoint without TomTom | `C_Map.SetUserWaypoint` + `UiMapPoint` (replaces your own map pin), plus `C_SuperTrack.SetSuperTrackedUserWaypoint` to track it (skipped if missing). |
| Note pins | Drawn by `Modules/POIMap.lua` with HereBeDragons-Pins (HandyNotes dropped). Round (mask texture), black-edged ring in the category colour, 22 px world map / 16 px minimap. Look and click behaviour untested in game. |
| Dot rendering | Round class-colored dots with a black edge (`Media/circle.tga`). Combat-safe frame handling not done. |
| Guild secret | Crypto verified offline against Python; key-derivation time on Save, sealing cost during sync, and the encoded messages on GUILD are untested in game. |
| Install path | `_classic_beta_` on this install (the client loads addons from there); may differ elsewhere. |

## Running the offline tests
```
lua5.1 tests/test_poi.lua     # POI records, permissions, sync, position packet
lua5.1 tests/test_load.lua    # loads every file in .toc order with stubbed WoW API, fires login events
lua5.1 tests/test_crypto.lua  # crypto (LibHash + our constructions) vs Python reference values
```

## Layout
```
SawIt/
  SawIt.toc      load order: embeds.xml, Core, Comm, POI, POIMap, Positions, Modules/MinimapButton.lua
  embeds.xml           single library load list
  Libs/                Ace3 (full), LibDataBroker, LibDBIcon, HereBeDragons, LibDeflate
  Media/icon.tga       minimap/addon-list icon
  Core/Core.lua        addon object, AceDB, roster cache, position helper, /sawit
  Core/Crypto.lua      PBKDF2, seal/open with the guild secret, built on LibHash's SHA-256/HMAC
  Core/Comm.lua        prefixes, sealed envelope, compression flag, rate limit, handler registry
  Core/UI.lua          shared window and button builders for the dialogs
  Modules/POI.lua      records, validation, permissions, sync, note commands of /sawit
  Modules/POIMap.lua   note pins on world map + minimap (HBD-Pins), tooltips, click actions, category filters
  Modules/Positions.lua live positions: packet, send policy, expiry, HBD pins
  Modules/NoteDialog.lua add-note window (category list + text field) opened from the minimap button
  Modules/SecretDialog.lua guild secret window (/sawit secret): enter, generate, remove, check code
  Modules/DeleteDialog.lua delete window opened by right-clicking a note pin (your own notes; officers: any)
  Modules/MinimapButton.lua      minimap button module (LDB + LibDBIcon)
  tests/               offline tests (not loaded by the game)
  Utils.lua            not in the .toc, not loaded
```
