# WoW Forever client: what the addon is running on

Researched 2026-09-30 against the installed beta client. Re-check after every client patch (see "How to redo this").

## Short answer

WoW Forever (internal game type **`camelot`**) runs the **modern retail (Mainline, Midnight / 12.x) UI and API**,
not the Classic Era one. It is a Mainline-family client with its own Camelot overrides, only the 9 original classes,
and Midnight's addon restrictions (secret values, messaging lockdown, no classic combat log) switched on.
Classic-era addon habits (old globals, `UIDropDownMenu` as the main dropdown, `CombatLogGetCurrentEventInfo`) cannot be assumed.

## Evidence

| What | Finding | Source |
|---|---|---|
| Installed build | `1.60.1.70124`, product `wow_classic_beta`, folder `_classic_beta_` | `World of Warcraft/.build.info`, `_classic_beta_/.flavor.info` |
| Interface number | **16001** = 1×10000 + 60×100 + 1 for 1.60.1. Our `.toc` value is right. | build number above; community guides agree |
| Blizzard UI source for this exact build | Tag `1.60.1` (commit `41fdb63`, message "1.60.1 (70124)"), branch `forever` | [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) |
| Game type name | `camelot`. Blizzard's `.toc` files use `[AllowLoadGameType camelot]` and `Camelot\` override folders (EditMode, DamageMeter, CharacterCreate, WorldMap, Menu, ...) | wow-ui-source 1.60.1 |
| UI family | Mainline: only `Blizzard_WorldMap_Mainline.toc` exists, and `[Family]\...` paths resolve to the `Mainline\` folders (e.g. `Blizzard_SharedXML/Mainline/UIDropDownMenu.lua`) | wow-ui-source 1.60.1 |
| Midnight APIs in the engine | `issecretvalue`, `canaccessvalue`, `secretwrap`, `C_Secrets`, `C_RestrictedActions`, `C_DamageMeter`, `C_CombatLog`, `C_ChatInfo.InChatMessagingLockdown` are present | `strings WowB.exe` |
| Classic combat log | `CombatLogGetCurrentEventInfo` is **absent** | `strings WowB.exe` |
| Modern Blizzard modules | `Blizzard_ClassTalentUI`, `Blizzard_Professions`, `Blizzard_PerksProgram`, `Blizzard_Settings`, `Blizzard_Communities`, ... | `strings WowB.exe` |
| Classes | `CLASS_SORT_ORDER` lists only Warrior, Paladin, Priest, Shaman, Druid, Rogue, Mage, Warlock, Hunter | `Blizzard_FrameXMLBase/Camelot/Constants.lua` |
| Community consensus | "Mainline's UI architecture, the vast majority of 12.1.5 APIs, Midnight's addon disarmament incl. secrets active" | [realmlist.org census](https://realmlist.org/resources/guides/wow-forever-beta-addons-what-works/), [Icy Veins](https://www.icy-veins.com/wow-forever/news/addons-in-wow-forever-blizzard-devs-just-addressed-the-big-question/), [wowforeverguides.com](https://wowforeverguides.com/addons) |

## What this means for SawIt

| Topic | Status on 1.60.1 | Effect on our code |
|---|---|---|
| **Dropdowns** | Both exist. The **Menu API** (`Blizzard_Menu`, `MenuUtil`, `WowStyle1DropdownTemplate`) has a Camelot-specific `Camelot/Menu.xml`, so it's the current system. `UIDropDownMenu` (Mainline copy) still loads, but it's the legacy path. | The note window's hand-built category list works either way. If we want a native dropdown later, use `WowStyle1DropdownTemplate` + `MenuUtil`, not `UIDropDownMenu`. |
| Templates used by the note window | `InputBoxTemplate` (`Blizzard_SharedXML/Shared/InputBox`), `UIPanelButtonTemplate` (`Blizzard_SharedXML/Mainline`, with a Camelot `.lua` override), `GameFontNormal/Highlight/HighlightSmall`, `UISpecialFrames` (`Blizzard_UIParentPanelManager/Shared`) all present. | OK as written. |
| Blizzard C APIs we call | Every WoW API function in `Core/`, `Modules/` and `Modules/MinimapButton.lua` appears in `WowB.exe` (checked with a grep script, see below). | No missing functions. |
| Addon messages | `C_ChatInfo.SendAddonMessage` returns a `SendAddonMessageResult` enum: `Success, InvalidPrefix, InvalidMessage, AddonMessageThrottle, InvalidChatType, NotInGroup, TargetRequired, InvalidChannel, ChannelThrottle, GeneralError, NotInGuild, AddOnMessageLockdown, TargetOffline`. It does **not** accept secret values (`SecretArguments = "NotAllowed"`). | `AddOnMessageLockdown` confirms messages can be blocked in restricted contexts, so `Comm:IsLockedDown()` is needed. We only send strings we build ourselves, so the secret-argument rule is fine. |
| Lockdown check | `C_ChatInfo.InChatMessagingLockdown()` exists ("true if API security restrictions regarding chat messaging are in effect"). | `Comm:IsLockedDown()` works as intended. |
| `CHAT_MSG_ADDON` payload | prefix, text, channel, sender, target, zoneChannelID, localID, name, instanceID (same as retail). | AceComm handles it. Our `issecretvalue` guards are still worth keeping. |
| Player position | `C_Map.GetBestMapForUnit` / `GetPlayerMapPosition`: "Only works for the player and party members", `SecretArguments = AllowedWhenUntainted`. | We only ask for `"player"`: OK. Positions of guildmates must come over addon messages, as designed. |
| Secret values | `issecretvalue` exists. | The existing `GA.isSecret` guards are real, not dead code. |
| Deprecated shims | `Blizzard_Deprecated` shims for 12.x load for game type `mainline`. **Unknown** whether `camelot` counts as `mainline` for that rule. `Blizzard_DeprecatedChatInfo` (global `SendChatMessage`, etc.) has no game-type filter. | Prefer `C_*` namespaced APIs (the code already does, with fallbacks). Don't add new calls to old globals without checking. |
| Classes | Only the 9 original classes. | `RAID_CLASS_COLORS` lookups are fine. |

## Still unknown (check in game)

1. `WOW_PROJECT_ID` value on Forever: `/dump WOW_PROJECT_ID`. It isn't set in the Camelot Lua constants, so the engine probably provides it.
   HereBeDragons and other libraries branch on it.
2. Whether `[AllowLoadGameType mainline]` content also loads on `camelot` (affects deprecated globals):
   `/dump C_AddOns.IsAddOnLoaded("Blizzard_Deprecated")`.
3. Real addon message size and throttle limits, and when lockdown triggers: the `GuildAtlasProto` checklist in README.md.
4. Whether HandyNotes and TomTom run on Forever (third-party; see the community census above).
5. Whether the classic `Interface\Icons\...` names used for POI categories exist.

## How to redo this

```sh
# 1. installed build
cat "World of Warcraft/.build.info" | grep wow_classic_beta
# 2. Blizzard UI source for that build (tag = build version)
git ls-remote https://github.com/Gethe/wow-ui-source.git | grep -iE "forever|1\.60"
git clone --depth 1 --branch 1.60.1 https://github.com/Gethe/wow-ui-source.git
# 3. does the engine export an API name?
strings -n 5 _classic_beta_/WowB.exe | grep -cw issecretvalue
# 4. every WoW API our code calls, checked against the exe (from the SawIt folder)
strings -n 5 ../../../WowB.exe > /tmp/wowb.txt
for f in $(grep -rhoE "\b(C_[A-Za-z]+\.[A-Za-z]+|[A-Z][A-Za-z]+)\(" Core Modules Modules/MinimapButton.lua | sed 's/($//' | sort -u); do
  grep -qw "${f##*.}" /tmp/wowb.txt || echo "not in exe: $f"; done   # expect only our own/library methods
```
API docs for a function: `Interface/AddOns/Blizzard_APIDocumentationGenerated/*Documentation.lua` in that tag.
The same repo is also indexed on Context7 as `gethe/wow-ui-source`.
