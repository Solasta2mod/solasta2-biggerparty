# Internals

How BiggerParty works, and what to do when a game patch breaks it.

Everything below was derived from the shipping build **CL-112340** (Solasta II Early Access, 2026-09-10,
Unreal Engine 5.6.1, internal project name `Brimstone`). Tactical Adventures ship full debug symbols
(`Brimstone-Win64-Shipping.pdb`) next to the executable, which is what made this tractable — no signature
guessing was needed to find the functions, only to locate them at runtime.

## Where the party size actually lives

The game hard-codes "4" in four places, and all four are *entry gates*. The runtime — party management,
HUD, combat, initiative, saves — already handles any number of heroes, which is why a six-hero campaign
works without touching gameplay code.

| # | Where | Instruction | What it gates |
|---|---|---|---|
| 1 | the character-creation level | — | one hero per actor tagged `PartyAvatarSpawn` |
| 2 | `UGameSessionViewModel::SetupDefaultSession` | `mov r13d, 4` | character slots built per session |
| 3 | `UBrimstoneCommonSessionSubsystem::CreateOnlineHostSessionRequest` | `mov [rax+0xA0], 4` | `MaxPlayerCount` announced to the online service |
| 4 | `UGameSessionViewModel::ReadRuntimeSessionFromGameState` | `lea r12d, [rbx+4]` and `cmp ebx, 4` | player-slot cap when a saved game is re-hosted |

Item 1 is level content and is handled by the Lua half (it spawns extra `TargetPoint` actors with that
tag). Items 2–4 are the byte patches applied by `version.dll`.

Loading a save is unaffected by the patches: `ReadRuntimeSessionFromGameState` empties `CharacterSlots`
and rebuilds them from `PartyComponent::GetParty()`, so a 4-hero save loads as four heroes whether or not
the mod is installed.

## The two halves

### `version.dll` — the native patcher

A `version.dll` proxy (it forwards every `version.dll` export to the real one in `System32`), loaded by the
game executable itself. At start-up it:

1. scans `.text` for each patch site by byte signature — the signature must match **exactly once** and the
   literal must still be `4`, otherwise that site is refused and logged;
2. writes the configured `PartySize` over those literals in memory;
3. starts a watcher thread that re-reads `BiggerParty.ini` once a second, so the in-game toggle applies
   without a restart (setting `Enabled=0` restores the original bytes).

Nothing is written to disk and no game file is modified. After a game update, unrecognised code means the
mod goes inert rather than corrupting anything.

Source: [`BiggerParty/src/version_proxy.cpp`](../BiggerParty/src/version_proxy.cpp).

### The Lua half (UE4SS)

Everything that is level content or UI, none of which can be done by patching a literal:

- **Creation level:** spawns extra `PartyAvatarSpawn`-tagged `TargetPoint`s, extrapolating the row of the
  existing four markers so heroes 5+ stand in line. Host only.
- **Creation screen:** shrinks the `SizeBox` width overrides inside the character cards so the row fits, and
  widens the creation camera's FOV so the outer models stay in frame.
- **Multiplayer host screen:** extends the *Players* radio group to `2..PartySize`.
- **Lobby:** re-flows the player tiles into three columns (four for 7–8) so a third row does not overflow.
- **Inspection screen** (inventory / character sheet / spells): creates portraits for heroes 5+, binds each
  to its hero's portrait texture, drives the selection ring, and emulates clicking them. See below.
- **Toggle:** `Ctrl+Shift+Tab` rewrites `Enabled` in the ini; the DLL's watcher picks it up.

Source: [`BiggerParty/dist/ue4ss/Mods/BiggerParty/Scripts/main.lua`](../BiggerParty/dist/ue4ss/Mods/BiggerParty/Scripts/main.lua).

## The inspection screen portrait strip

The four portraits in that screen are hand-placed `WBP_InspectionPortrait` widgets in the screen Blueprint,
not a data-driven list, so extras have to be created and wired by hand. Three details cost the most time and
are worth writing down:

- **The portrait image is a material parameter named `PortraitTexture`.** Do *not* discover a parameter name
  by setting a guess and reading it back: a `MaterialInstanceDynamic` stores an override even for a parameter
  its material does not have, so every guess "succeeds" and the picture silently stays at the default. Read
  the name off a working original instead — `MID.TextureParameterValues[n].ParameterInfo.Name`.
- **The selection ring** is `WBP_PortraitSmallCircle_C:SetSelected(bIsSelected: bool)`. Which hero is
  currently inspected is derived from the screen's bound component
  (`InspectionScreen:GetGuiRulesetActor()` → owner → index in `PartyComponent.Party`), not from any tab index.
- **Clicking** is emulated: no portrait widget implements a mouse event, and the game's own click ends in
  `InspectionScreen:Bind(guiComponent, false)`. On a left click the mod finds the hovered extra portrait and
  makes the same call — skipping the currently-selected portrait, because the selected one is enlarged and
  would otherwise swallow a click aimed at its neighbour.

## Re-signing after a game patch

1. Point the tools at the new build and confirm each signature still matches exactly once:
   `python tools/pdb_pub.py "SetupDefaultSession@UGameSessionViewModel"` finds the function,
   `python tools/disasm.py <seg> <offset>` disassembles it. The four signatures are listed in
   `version_proxy.cpp`; a changed instruction means a new signature, not a new address — the DLL scans.
2. Rebuild: `BiggerParty\build.bat`, then `python BiggerParty\installer\gen_payload.py <UE4SS dir>` and
   `BiggerParty\installer\build.bat`.
3. Check the Lua half still finds what it needs — `Ctrl+Shift+Backspace` in game prints the config, the
   patcher's log, party/slot counts and the portrait strip state.

## The tools

Python 3, no third-party dependencies except `capstone` for the disassembler.

| Tool | Purpose |
|---|---|
| `strings_scan.py` | ASCII/UTF-16 strings from the shipping exe — reflected names and native gameplay tags |
| `pdb_scan.py` | chunked keyword scan of the 2.4 GB PDB for symbol names (edit `keys`) |
| `pdb_pub.py` | resolve mangled symbols to segment/offset, and offsets back to names |
| `pdb_order.py` | UFunction parameter *declaration order* (UHT `NewProp_*` statics) and enum values |
| `pdb_members.py` | class field offsets from PDB `LF_MEMBER` records |
| `disasm.py` / `fnview.py` | disassemble a function; `fnview` resolves call targets to symbol names |
| `callers.py` | find direct call sites of a function |
| `pak_index.py` / `pak_read.py` | parse and extract the unencrypted `Brimstone-Windows.pak` (set `OODLE_DLL` to any `oo2core_*_win64.dll`) |
| `utoc_index.py` | parse the IoStore `.utoc` directory index to list cooked asset paths |

Two gotchas worth keeping: UE4SS Lua `TArray` appends invalidate element references taken before the append
(hold values, not references), and `RegisterHook` only sees functions called through `ProcessEvent` — a
function invoked directly from C++, like `InitEditionActors`, will never fire a hook.
