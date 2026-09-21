# Internals

How BiggerParty works, and what to do when a game patch breaks it.

Everything below was derived from the shipping build **CL-112340** (Solasta II Early Access, 2026-09-10; the
14 Sep 2026 patch, **CL-112436**, kept every signature and class name used here; the 21 Sep 2026 patch,
**CL-113670**, moved the game-state pointer of `ReadRuntimeSessionFromGameState` from `rdi` to `rsi`, so that
ModRM byte is a wildcard in both of its signatures —
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

## Multiplayer: whose heroes are whose

The first real three-player session (two heroes each) showed where single-player assumptions hide:

- **Followers.** Each player's AI followers follow *that player's* selected hero; the formation report
  shows three leaders and three groups of anchors. The watchdog that re-selects on a stale leader now runs
  on the host only (followers' AI controllers exist nowhere else) and only over the heroes the local player
  controls. It had been "healing" other players' correct followers every ten seconds.
- **Who controls a hero** comes from `ABrimstoneGameState::FindPlayerStateControllingActor(actor)` compared
  with the local `PlayerController.PlayerState`; the character slot's `GetIsControlledByMe()` is the
  fallback. `ABrimstonePlayerState.ControlledActors` is *not* that list — after a drop and rejoin it named
  the wrong heroes. `GetPlayerName()` on a player state is the save's slot name, not who is at the keyboard.
- **Story scenes.** Each client only possesses a participant it controls (`IsMine`); the host still moves
  the first participant it sees into party slot 1, because the server resolves the vote through
  `GetParty()[0]`. The host used to possess other players' followers, which is one way a follower ends up
  with a stale leader. A player whose heroes were all left out of a scene's participant set gets no
  choice; spreading roles across players would need a hook on
  `UBrimstoneDialogueManagerComponent::GetBestActorForParticipant` and is not done.
- **The party strip.** When a player drops, the game hands their heroes to the others and grows their
  groups by a plate; on rejoin it takes them back and hides the plate. The strip code no longer un-hides
  plates in multiplayer (and in single player only while fewer plates are visible than there are heroes).
- **Hot-reload traces.** `trace:` lines on `BeforePushDialogueScreen` / `AfterPushDialogueScreen` and the
  `DialogueScreen` start/bind functions show the game's own screen push relative to the mod's possession.
  Do not trace `OnPossessedPawnChanged`: every participant component in the level receives it.

## Followers that stop walking (not fixed)

Reproduced with four heroes and with the mod's script disabled from a clean load, so it is the game's:
after a run of leader changes, some followers stand still although every state the mod can read matches a
healthy follower (brain running, path status "moving" with a valid destination, movement component active,
animation running, no time dilation, move input not ignored). Resetting the AI controller, the movement
component or the formation anchors does nothing; a save and reload always fixes it, and a manual leader
change often does. Two real faults were found on the way and are fixed: the formation manager component is
sometimes left inactive after a load (`UPartyFormationManagerComponent:IsActive()`; the mod re-activates it),
and a watchdog of the mod's own that re-selected the leader on a timer took control away from the player
(never re-select on a timer). `Ctrl+Shift+F` bundles the harmless nudges. Whatever a reload resets lives in
the character itself and was not reachable through reflection; the next step, if ever, is the binary: what
the game's own selection path does that a plain possess does not.

## Threads: everything on the game thread

UE4SS runs `LoopAsync` and `ExecuteWithDelay` callbacks on its own async thread, and key-bind callbacks on
its input thread. Of all the paths that run a mod's Lua, only the key-bind one takes UE4SS's
`m_thread_actions_mutex`; hooks, `ExecuteInGameThread` actions and the game-thread timers run without it,
and the async path takes no lock at all (`LuaMod::process_delayed_actions`). A Lua state is not thread-safe,
and two threads inside one state for even a few microseconds — creating the closure handed to
`ExecuteInGameThread` is enough — corrupt its heap. That was the "crash dump when looting" and the earlier
random crash during the 1.2.1 work: both minidumps died inside UE4SS.dll with garbage in the Lua stack, one
in the garbage collector on a `Proto` whose upvalue-name pointer was `2`, one in the `__index` metamethod on
a userdata that had lost its metamethod container. The crashing thread was the game thread inside the mod's
one-second pass, which is at its heaviest while a screen full of widgets (a loot bag) is open, and the mod's
async timers and mouse key bind were the other side of the race.

The rule in `main.lua`: nothing runs off the game thread. Timers go through the `Every`/`After` helpers,
which use `LoopInGameThreadWithDelay`/`ExecuteInGameThreadWithDelay` (present in the bundled UE4SS build;
the helpers fall back to the async calls if a build lacks them), and key binds only set a field of a
pre-built table that a 50 ms game-thread poll reads — a write into an existing key allocates nothing, which is
as little Lua as a key bind can do. Do not add `LoopAsync`, `ExecuteWithDelay`, or work inside a
`RegisterKeyBind` callback.

Reading a crash without a debugger: `tools/minidump.py <dmp>` prints the exception, the registers, the
module bases and a return-address scan of the crashing thread's stack; `tools/pdb_pubs_scan.py` (once, about
15 s) followed by `tools/pdb_addr.py <rva>...` names the game frames; `tools/ue4ss_fn.py <UE4SS.dll> <rva>...`
prints a UE4SS function's bounds and the strings it references (UE4SS ships no PDB, so its error strings are
what identify a function); `tools/luawalk.py <dmp>` walks the Lua call stack and prints the values around
the top when the state's memory made it into the dump. The UE4SS source on GitHub then explains what the
function does with them.

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

The chest, loot-bag and merchant screens carry the same kind of strip with a different template
(`WBP_PortraitSmallCircle_WithEncumbrance`) and other widgets in the same row (the Tab badge, the weight icon), so
the extra portraits are tracked by widget rather than by child index, and anything that sat after the last
original portrait is moved back to the end of the row. Those screens follow the party selection: the ring
comes from `BrimstoneSelectionStateComponent:GetSelectedCharacter` and a click is `SelectCharacter(pawn, pc, true, true)`.
Selection alone is not enough there: the chest Blueprint binds each of its portraits to a hero through the
portrait's own `BindToGameplay(RulesetActor)` (that hangs the `CharacterSummaryViewModel` behind the
carried-weight gauge on it), and a click on one of its portraits runs the screen's
`OnPortraitClicked(BoundRulesetActor)`, which makes that hero the looter. The mod calls both on the extra
portraits, reading the parameter list off the `UFunction` at run time (`FunctionOf` / `ParamsOf` /
`CallByParams` in `main.lua`) and passing the hero or the widget by parameter type, so a renamed parameter
in a patch shows up in the log instead of a silent no-op. `Ctrl+Shift+Backspace` with a loot bag open dumps
the portrait and screen classes with property values and function signatures.

## Story dialogues with more than four heroes

Three separate things had to be true for a six-hero party to get through a story scene; each was found by
tracing the conversation pipeline at runtime with hooks on the reflected functions, then reading the native
code around the failure.

1. **The dialogue screen is pushed by the participant on the possessed pawn.** A scene binds a fixed set
   of party participants (the family scene binds `Dialogue.Participant.Party.A–D`, i.e. the *last four*
   party members). `UBrimstoneDialogueParticipantComponent::ReadySelfForConversationInternal` pushes the
   screen only when its pawn is the one the player controller possesses, and each participant readies
   itself exactly once. If the possessed hero is not bound, no screen ever appears — and possessing a
   bound hero afterwards does nothing, because the one-shot readiness is already consumed. The mod
   therefore possesses the first bound hero **synchronously inside the pre-hook of
   `ClientInitParticipantContext`**, before the game's own code runs. The game's `SelectCharacter` refuses
   selection changes once a dialogue is starting, so this has to be `AController::Possess` directly.
2. **The vote is resolved through party member #1.** `UMultiplayerCheckpointManagerComponent::
   SelectFinalConversationChoice` takes `GetParty()[0]`, finds that hero's conversation-participant
   component and calls `RequestServerAdvanceConversation` on it. With six heroes, member #1 is not a
   participant, the request goes to a component outside the conversation, and the scene stalls after the
   first click (the vote window closes with the vote). The mod moves the first bound hero to party slot 1
   for the duration of the dialogue and restores the order on `ClientExitConversation`.
3. **Votes only count for "joined" players**, i.e. player states with both `bHasCompletedHotJoinGate` and
   `bReadyForHotJoin` set (`ABrimstoneGameState::HasPlayerJoinedGameplay`), and the expected number of votes
   is `GetGameplayJoinedPlayerCount()`. This turned out to be fine for a solo host — worth knowing because
   it is the first thing to check if a real six-player session ever refuses a choice.

Two dead ends worth recording so nobody repeats them: the multiplayer *vote panel* (`UMultiplayerVotePanel`)
is for rests, checkpoints and fast travel, not dialogue choices; and pre-assigning family roles to the extra
heroes does not help — the scene's participant count is what matters, not the roles.

## Party formation with more than four heroes

Followers walk to *anchors* that the formation manager arranges around the party leader, and each follower's
AI keeps its own idea of who the leader is (`ABrimstoneAIController::GetLeaderToFollow`). That leader is
refreshed only by the game's selection path (`UBrimstoneSelectionStateComponent::SelectActor`), never by a
possession change on its own. The mod's raw `Possess` at dialogue start therefore left every follower with a
stale leader; the hero who was still recorded as leader followed anchors arranged around *himself* — which
looks like an NPC wandering at random — until any selection change put things right.

Two fixes: after a dialogue the mod hands control back through `SelectCharacter` as a *real* change (to the
hero selected before the scene), and a two-second watchdog compares each follower's `GetLeaderToFollow()`
with the controlled pawn and, on a mismatch, performs a selection switch to another hero and back (a
programmatic Tab), at most every ten seconds and never during a dialogue.

Two things that must not be done, both learned the hard way: do not call the formation manager's
`PossessedPawnChanged` or hand-assign anchors (`SetAnchorToFollow` / `FollowingActor`) from Lua. The game
frees and re-spawns its anchors on the next real selection change, an AI left pointing at a destroyed anchor
crashes the game about half a minute later, and neither call refreshes the followers' leader anyway.

Also worth knowing: `ReassignAnchors` only has designed formation slots for three followers; the fourth and
fifth are assigned in a plain loop, and the anchor count comes from the party, so six heroes do get six
anchors — the missing-anchor symptom seen during the investigation was a consequence of the stale leader,
not of the anchor count.

## Enemy hit points

A monster's maximum hit points come from `UCharacterBuildingComponent::InitMonsterHitPoints`: it makes an
outgoing spec of the "init health" effect (`URulesetImplementationSettings.InitHealthClass`, the asset
`GE_SetMaxHealth`: instant, override, set-by-caller tag `Ruleset.Health.Max`), sets the definition's
`MaxHitPoints` as the magnitude and applies it. `LostHitPoints` is a separate attribute, so current hit
points follow the maximum.

Re-applying that effect from Lua does not work, and the reason is worth remembering: for a UFunction's
struct *return value* UE4SS does not hand back a struct userdata but converts the struct into a Lua table
field by field (`Operation::GetNonTrivialLocal` in `LuaUObject.cpp`). `FGameplayEffectSpecHandle` and
`FGameplayEffectContextHandle` have no reflected fields, so `MakeOutgoingSpec` returns `{}` and every call
that takes the handle back receives a zeroed, invalid one — silently, without an error. Any Blueprint API
that threads opaque handles between calls is out of reach of UE4SS Lua.

What works instead (`ScaleEnemyHitPoints` in `main.lua`): find the `HealthAttributeSet` in the monster's
`BrimstoneAbilitySystemComponent.SpawnedAttributes`, write `MaxHitPoints.BaseValue` and `CurrentValue`
directly, call the set's own `OnRep_MaxHitPoints(OldValue)` — the rep-notify path integrates a new base
the way a replicated update is integrated (aggregator base if one exists, change listeners, so the HP bar
and the health conditions refresh) — and `UNetPushModelHelpers::MarkPropertyDirty` so push-model
replication sends it to the clients. Monsters are the `RulesetActor`s whose `GetBaseDefinition()` is a
`MonsterDefinition` (the `BaseDefinition` property is not a plain object reference in Lua; use the getter);
hostility is the actor's `GetTeamAttitudeTowardsParty()` (0 friendly, 1 neutral, 2 hostile); only the host
(`HasAuthority`) writes, every three seconds. A monster is touched only while its base equals the
definition's value or a value the mod set, so nothing compounds and a loaded save is recognised.

The Difficulty screen's rows are built in C++ (`UBrimstoneGameSettingRegistry::InitializeGameSettings`):
`NewObject` of a `UGameSettingValueScalarDynamic` subclass, data sources made of reflected getter/setter
function names on `UBrimstoneSettingsLocal`, per-preset values from a `FGameDifficultyData` table. A real
"enemy hit points" row means native code that adds two UFunctions to that class and builds those objects
after the registry initialises — not done; the value lives in the ini and on two hotkeys.

## Narrator: voicing the world events

World events are `UWorldEventResponseScreen` widgets (`WBP_WorldEventResponseScreen`): `TitleText`, a
`DescriptionText` that the game types out letter by letter across several text blocks (visual lines), an
`OutcomeLinesContainer` that gains one rich-text block per outcome (`<img id="WorldEventChoice"/>
<Default.Gold>Search</> Among the items…`), and `ButtonsContainer` with the options. Native hooks on the
screen's `Bind` / `AddOutcomeMessage` / `ShowResponses` never fire (called from C++), so the mod polls the
visible screen every 250 ms on the game thread instead.

The description is streamed as *sentences*: the text seen so far is split at `.!?` followed by a space and
each complete sentence is spoken once it is there; the remainder is spoken once the text has been stable
for four polls (the typewriter finished). Outcome blocks are stripped of the icon tag, the styled label of
the chosen option, and any leading short label block; reward lines ("Each party member receives 125 XP",
"… gold", "treasury") are dropped by pattern. Titles, options and tooltips are never spoken. Closing the
screen writes a stop.

Speech is done out of process: the mod appends one JSON line per utterance to
`Narrator\queue.txt` next to the game exe and starts `Narrator\SolastaNarrator.exe` once (single-instance lock;
it polls for the game process and exits when it is gone). The companion is a small Python program
(`Narrator/companion/narrator.py`, packaged with PyInstaller): it synthesizes with `edge-tts`
(Microsoft Edge's neural voices, free, online), caches MP3s by `sha1(voice + rate + pitch + text)` and plays
them through `winmm` MCI in a queue that a stop empties. Queue commands: `voice` (switch at once),
`mute` / `unmute`, `stop`; `sample` lines play even when muted (the voice introducing itself).
`Ctrl+Shift+N` / `Ctrl+Shift+M` are key binds that only set flags, polled on the game thread; the choice is
written to `narrator.ini`, which the companion also reads at start-up.

Saved for a later version: all the event text is in the pak (`ST_MainCampaignIngredients.csv`, keys
`DA_EV_*`; 131 events, 490 passages, ~88k characters, ≈100 minutes) and `Narrator/tools/extract_events.py`
pulls it. Pre-rendering every passage once with a better engine (ElevenLabs, or a local model) would make
narration instant and offline and allow a designed voice; the companion would check a pack folder keyed by
the text before falling back to Edge. The extracted text and any audio pack stay out of the repository.

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
| `vtable.py` | read a vtable slot from the exe and map it back to a PDB symbol (resolves virtual calls in disassembly) |
| `pak_index.py` / `pak_read.py` | parse and extract the unencrypted `Brimstone-Windows.pak` (set `OODLE_DLL` to any `oo2core_*_win64.dll`) |
| `pakread.py` | the same as an importable class (`Pak(path).read(name)`, `OODLE_DIR`); used by `Narrator/tools/extract_events.py` |
| `utoc_index.py` | parse the IoStore `.utoc` directory index to list cooked asset paths |
| `minidump.py` | crash dump triage: exception, registers, module bases, return-address scan of the crashing thread |
| `pdb_pubs_scan.py` / `pdb_addr.py` | build a lookup of every public symbol once, then name game-exe addresses (RVA) from a dump |
| `ue4ss_fn.py` | function bounds (from `.pdata`) and referenced strings for addresses inside UE4SS.dll |
| `luawalk.py` / `dumplib.py` | walk the Lua call stack inside a minidump (frames, current line, values near the top) |

Three gotchas worth keeping: a UFunction's struct return value comes back as a plain table, so opaque
handles cannot be passed on (see *Enemy hit points*); UE4SS Lua `TArray` appends invalidate element references taken before the append
(hold values, not references), and `RegisterHook` only sees functions called through `ProcessEvent` — a
function invoked directly from C++, like `InitEditionActors`, will never fire a hook.
