# Internals

How BiggerParty works, and what to do when a game patch breaks it.

Everything below was derived from the shipping build **CL-112340** (Solasta II Early Access, 2026-09-10; the
14 Sep 2026 patch, **CL-112436**, kept every signature and class name used here; the 21 Sep 2026 patch,
**CL-113670**, moved the game-state pointer of `ReadRuntimeSessionFromGameState` from `rdi` to `rsi`, so that
ModRM byte is a wildcard in both of its signatures; the 1 Oct 2026 patch, **CL-114967**, kept them all —
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
- **Turns that cannot be ended.** Sometimes a player's End Turn does nothing until they are kicked and
  rejoin, or the game is reloaded. Whose turn it is lives in `UTurnBasedManagerComponent::ActiveActor`
  (replicated, `OnRep_ActiveActor`); a player's End Turn sits in `UTurnControlPanel`, whose `WidgetSwitcher`
  shows `EndTurnGroup`, `BackToActiveGroup`, `NextPlayableCharacterGroup` or `EmptyGroup`, with
  `EndTurnButton` and the hero the panel is on (`GuiRulesetActor`). On every machine the script writes each
  party member's turn to `BiggerParty-history.log` with the controlling player as that machine sees it, the
  hero its player is on and the panel's state, again 45, 90, 135 and 180 s into the same turn. A stuck
  player's own hero holding the turn while their panel shows anything but an enabled End Turn would mean
  their game disagrees about whose turn it is; their lines next to the host's show which side drifted.
  The stuck heroes had been dealt to one player and moved to another a moment after a load, and handing such
  a hero to the host and back cleared it. The host now does that itself: it watches every party member's
  controlling player state ten times a second, and a hero that moves straight from one remote player to
  another, then stays put for 3 s, is handed over with `UGameSessionViewModel::ChangeCharacterController
  (UCharacterSlotViewModel*, UPlayerSlotViewModel*)` — first to the host's slot (`GetIsMySlot`), 1.5 s later
  back to the slot whose `GetBoundPlayerState` is its player. The view model's `CharacterSlots` follow the
  party's hero order; that is used only when every slot's `GetControllingPlayer` agrees with
  `FindPlayerStateControllingActor` for the hero at the same position. Guests have no character slot and are
  left alone; nothing happens during a dialogue, and a hero is handed over at most once every 90 s.

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

## Mod options in the game's menus

The title screen (`WBP_MainMenuScreen`) and the pause menu (`WBP_PauseMenuScreen`) both hold a
`WBP_GameMenuPanel` (native `UGameMenuPanel`) whose entries are `WBP_GameMenuButton`s (native `UGameMenuButton` <-
`UBrimstoneButtonBase` <- CommonUI's `UCommonButtonBase`) in a `VerticalBox` named `MenuOptions`; the panel maps
gameplay tags (`MenuItemTags`, `GetMenuItemByTag`) to its entries. The mod creates more buttons of the same class
(`UWidgetBlueprintLibrary::Create`) and labels them with `UBrimstoneButtonBase::SetButtonText`: a "Mod options"
entry right after the entry whose tag names Settings (labels are translated, tags are not), and one button per
setting plus Back, collapsed. A `VerticalBox` only appends, so the entries after the insertion point are taken off
and put back after the new ones, each with its slot's padding, alignment and size. A click on any CommonUI button
runs `UCommonButtonBase::HandleButtonClicked`; one hook on it recognises the mod's buttons by address and leaves the
work to the next game-thread tick. "Mod options" collapses the menu's own entries and shows the settings, each label
carrying its current value; a click changes the value through the same code as the keys (`ToggleEnabled`,
`AdjustEnemyHitPoints`, the ini writer; the Narrator's settings through `narrator.ini` and its queue), and Back, or the
menu closing, restores the entries' own visibility. The panel's own handlers never see the new buttons: they are not
in its tag map. Widgets are only ever touched as live children of a menu the game still lists: a menu's screen is
destroyed on a level change and its memory reused, so a widget (or an address) remembered from a menu that is gone
must never be used again — a pause-menu click once matched a dead title-screen button by address, and relabelling
that button crashed the game. A menu's state is dropped on the tick the menu leaves the game's object list, a click
only counts when the button is a current child of its menu, and a menu whose list was rebuilt gets the entry again.

## Stuck turns

Now and then a client cannot end their hero's turn while the host can, and handing the hero to the host and back
(`UGameSessionViewModel::ChangeCharacterController` twice, what the session screen's take and give do) clears it.
The hand-out repair does that unasked when the game moves a hero from one remote player straight to another; the
character slots it needs follow the party's order, either its heroes or every member including a guest (both
layouts are tried, each only used when every slot's controller is the game's owner of the member at that
position). For the other cases the stuck player's own copy notices it: the turn panel's End Turn clicked
(`UCommonButtonBase::HandleButtonClicked` on the panel's `EndTurnButton`, or `UTurnControlPanel::DoEndTurn`) and the
same turn (round and member) still running 6 s later, or 30 s of the player's own hero's turn with the turn panel on
screen offering neither an enabled End Turn nor Back To Active. It then asks the host over the version check's
channel (`BiggerPartyAsk:unstick` as the world name of `ServerNotifyLoadedWorld`, which a host before 1.4.14
ignores), once per turn; Mod options' "Fix a stuck turn" asks by hand. The host hands the hero over only when it
is that player's hero's turn, never during a dialogue and at most once a minute per hero; the hand-back 1.5 s later
looks the session, the slots and the hero up again by address instead of keeping them across the wait.

A click seen in the same look (four a second) as a change of turn is put down to the turn before, which it ended:
1.4.14 and 1.4.15 counted it against the new turn, so when a player's next hero came straight after, ending the
first hero's turn asked for a hand-over 6 s into the second's (and used up that turn's one request). From 1.4.16
each request is followed by the player's view of the turn, the turn diagnostic's line, sent the same way as
`BiggerPartyInfo:<text>`; the host writes it to its `BiggerParty-history.log` ("stuck turn: <player>'s game at the
request: ..."), since a stuck player's own log is often out of reach. A host before 1.4.16 ignores it.

## Version check between players

Every copy of the mod carries its version (`BIGGERPARTY_VERSION` at the top of the script, bumped with the
installer's `kVersion`), and the players of a session compare theirs without any chat to carry it. A client sends
`BiggerParty:<version>` to the host as the world name of `APlayerController::ServerNotifyLoadedWorld`, a server RPC
the engine only acts on while that player is in the middle of a seamless level change (it compares the name with the
world it expects; the game's override, `ABrimstonePlayerController`, only adds a log of client travel states), so it
goes out 20 s after each load. The host hooks that call (the hook runs where the RPC is executed, with the sending
player's controller as its object) and answers every player with its own version through
`APlayerController::ClientMessage`, a client RPC the engine prints to the console only; the clients hook that.
A version that differs, or a player who reports nothing within three minutes (a version before 1.4.13, or no
BiggerParty), goes to the history log and once into the game's information dialog,
`UBrimstoneUIBlueprintLibrary::ShowInformationDialog(WorldContext, Text, Text)` (the two texts matched to their
parameter names), when no dialogue or world event is on screen. The hooks only note an address and a string; the
work is done on the next tick, and controllers are looked up again among the live ones.

## Narrator: voicing the world events

World events are `UWorldEventResponseScreen` widgets (`WBP_WorldEventResponseScreen`): `TitleText`, a
`DescriptionText` that the game types out letter by letter across several text blocks (visual lines), an
`OutcomeLinesContainer` that gains one rich-text block per outcome (`<img id="WorldEventChoice"/>
<Default.Gold>Search</> Among the items…`), and `ButtonsContainer` with the options. Native hooks on the
screen's `Bind` / `AddOutcomeMessage` / `ShowResponses` never fire (called from C++), so the mod polls the
visible screen every 250 ms on the game thread instead.

The description is streamed as *sentences*: the text seen so far is split at `.!?` followed by a space and
each complete sentence is sent once it is there; the remainder is sent once the text has been stable for
four polls (the typewriter finished). Outcome blocks are stripped of the icon tag, the styled label of the
chosen option, and any leading short label block. The game puts an icon in front of each outcome block:
`WorldEventChoice` on the outcome of a chosen option, an icon of its own (`HeroicInspiration`, …) on a
reward line, which is dropped; a block without an icon is dropped as a reward by pattern ("Each party member
receives 125 XP", "… gold", "treasury"). Titles, options and tooltips are never sent. Closing the screen
writes a stop. A new block with the choice icon means an option was chosen: a stop is written before any of
its text, and whatever the earlier blocks still had to say is dropped, so the narration moves straight on.
A block without an icon counts once it reaches five words of non-reward text (so a reward line still typing
out does not), and is held back until then or until it has finished typing, so that the stop never cuts its
own first sentence. While a block's first sentence is still being typed, its opening also goes out as a
`probe` every two words from six on, so that its recording can start before the sentence is finished.

Playback is out of process: the mod appends one JSON line per sentence to `Narrator\queue.txt` next to the
game exe and starts `Narrator\SolastaNarrator.exe` once (single-instance lock; it polls for the game process
and exits when it is gone). The companion (`Narrator/companion/narrator.py`, packaged with PyInstaller) plays
the recordings through `winmm` MCI from one worker thread. An MCI device belongs to the thread that opened
it — a `stop` sent from any other thread fails (error 263) and the clip plays on — so the worker opens,
plays without waiting, polls `status … mode` every 100 ms and closes each clip itself; a stop only empties
the queue and bumps a generation counter, which the worker sees and cuts the clip on. Queue commands:
`mute` / `unmute`, `stop`, `probe`, `volume` (playback level, applied by the worker with `setaudio … volume`
to the clip playing too); `sample` lines (announcements: the volume keys, BiggerParty's enemy hit points)
play even when muted — the pack's recording of that exact text if it has one, a short chime otherwise.
`Ctrl+Shift+M` and `Ctrl+Shift+= / -` are key binds that only set flags, polled on the game thread; the
values are written to `narrator.ini`, which the companion reads at start-up. A PyInstaller one-file program
reads its embedded modules from its own file at each first import, so the companion must never be replaced
while it runs (the installer stops it first).

**The voice pack.** All the event text is in the pak (`ST_MainCampaignIngredients.csv`, keys `DA_EV_*`;
131 events, 490 passages, ~88k characters, ≈100 minutes), and what the game displays is the English locres,
which corrects the CSV in places; `Narrator/tools/extract_events.py` pulls the displayed text from your own
copy of the game. A pack is `Narrator\pack\index.json` — `passages` (key, normalised text, MP3 file) and
`all` (the normalised text of every passage, recorded or not) — plus one MP3 per passage. The companion
matches what the screen shows to a passage by its normalised text (lower-case letters and digits, single
spaces): a passage plays whole from its opening and the sentences after it are skipped, allowing a word or
two to differ, because patches reword lines; when several passages open alike, the next sentence decides; a
typed opening (`probe`) starts its passage once it is at least six words long and no other passage in the
game begins that way, which is what `all` is for; a line of under five words in the middle of a block never
starts a recording (a block starts with a new screen, a stop, or a pause of over 2.5 s); anything without a
recording is not read. `Narrator/tools/render_pack.py` records a pack with Gemini TTS — one designed voice
per speaker, narration and quoted speech split by `cast_split.py`, `gemini_tts.py` as the API client — from
a cast file made from the extracted text, pacing itself to the API's request limits and resuming where it
stopped. The extracted text, the cast and the recordings stay out of the repository (they are the game's
text); the recordings ship inside the release's installer.

## Combat experience

`ABattle::ConcludeBattle` divides the battle's `EncounterXPAmount` by the contenders on the party's team and
gives each of them that share. The host watches the battles (ten times a second, and the game's end-of-battle
call) and, once one has ended, grants each hero the difference to a four-hero share through the game's
`FunctorAsync_GrantExperience`. Heroes are the party-team contenders with a `HeroProgressComponent`; the rest
(story guests, summons) are companions, who count in the game's divisor and get nothing either way. The share is
therefore `pool / (4 + companions)`, what a party of four heroes with the same companions would get, and a party
of four heroes or fewer gets nothing added.

## The Kobold race

The game ships a gnome ancestry it does not offer (`bEnumerableForUser` false) and kobold monster models. The
Kobold mod (`Kobold/Scripts/main.lua`) offers the gnome as Kobold, with its own title, texts and picture, and
builds its traits at runtime from cloned game definitions added to the asset manager's `DefinitionsMap`:
Draconic Cry is a power whose ability takes over the hidden Dragonborn's silver breath (built only while the
game keeps the Dragonborn hidden), and the Kobold Legacy is a choice of three feature sets (Craftiness;
Defiance, the halfling's Brave effect; Draconic Sorcery, a Sorcerer cantrip). A kobold hero's own body keeps
animating but is not drawn: a second skeletal mesh with the kobold body and armour, driven by the kobold
animation blueprint, rides on it, mirrors its montages and carries its weapons. Dialogue cameras and the
portrait capture aim at the hidden body's bones, so that body is lowered while one of them looks at it. Only
heroes become kobolds — an actor whose simulation actor owns a `HeroIdentityComponent` — because the game
draws some of its own NPCs on the gnome body too.

**The kobold voice.** A cutscene's speakers are dialogue roles (`Dialogue.Participant.Party.A`–`D`), bound to
heroes by the scene's participant plan, so the lines a hero speaks depend on its seat and family role. Each
take is a 2D `AudioComponent`; the scene's `MovieSceneVoiceTrack` gives the take's role and the dialogue
manager's bindings the hero playing it. For a kobold the mod turns the game's take down with `AdjustVolume`
(the sequencer sets `VolumeMultiplier` again every frame) and queues the kobold's recording to the Narrator's
helper, which plays it from an add-on pack: `Narrator\packs\kobold` (`index.json`, `lines.txt` with each
line's normalised text, take name and length, `roles.txt`). A line without a recording keeps the game's take.

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
