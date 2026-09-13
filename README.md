# BiggerParty — 6-hero parties and 6-player co-op for Solasta II

An unofficial mod for **Solasta II** (Early Access, build CL-112340) that lets a new campaign have up to
six heroes and a hosted multiplayer lobby seat up to six players. Existing saves are untouched: a
4-hero save loads exactly as vanilla.

| Host screen: players 2–6 | Lobby: six seats | Party creation: six slots |
|---|---|---|
| ![host screen with Maximum Players 6](docs/host-screen-6-players.jpg) | ![six-seat lobby](docs/lobby-6-seats.jpg) | ![six character slots in multiplayer party creation](docs/party-creation-6-slots-multiplayer.jpg) |

Also included: **GiveSpellbook**, a small fix for the multiplayer bug where multiclassing into Wizard
does not grant the spellbook.

> Early Access caveat: every game patch can change the code this mod patches. The mod checks the game
> build at start-up and simply goes inert (with a note in `BiggerParty.log`) when it does not recognise
> it — it never modifies game files on disk and cannot corrupt saves.

## Install (one click)

1. Download `BiggerParty-x.y.zip` from the [Releases](../../releases) page and unzip it.
2. Close the game and run **`BiggerParty-Installer.exe`**. It finds Solasta II through Steam (or asks for
   the folder), installs the [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) script loader if you do not
   have it, and installs the mod. Press **Enter** for the default install, **s** to also get GiveSpellbook.
3. Start the game normally. Everyone in a multiplayer session installs the same way.

Uninstall: run the installer again and press **u**.

## In game

| | |
|---|---|
| New Campaign | six character slots |
| Multiplayer → Host | the *Players* selector offers 2–6; in party creation the extra slots wait for players to claim them |
| **Ctrl+Shift+Tab** | toggle the mod on/off (applies to the next new campaign / lobby) |
| **Ctrl+Shift+End** | re-apply the card layout / camera on the creation screen |
| **Ctrl+Shift+Backspace** | status report into `ue4ss\UE4SS.log` |

Config: `<game>\Brimstone\Binaries\Win64\BiggerParty.ini` (`Enabled=1`, `PartySize=6`, up to 8 — the UI
was only tested with 6). Logs: `BiggerParty.log` (native patcher) and `ue4ss\UE4SS.log` (Lua).

GiveSpellbook (host / single player only): **Ctrl+Delete** grants a Wizard spellbook to any hero whose
spellcasting reports it missing; **Ctrl+Backspace** reports; **Ctrl+Shift+Delete** forces one on everyone
without a book.

## How it works

Solasta II hard-codes its party size in exactly four places, all of them entry gates — the runtime
(party, HUD, combat, saves) already handles any number of heroes:

1. the character-creation level contains four `PartyAvatarSpawn` marker actors (one hero per marker),
2. `UGameSessionViewModel::SetupDefaultSession` builds four character slots (`mov r13d, 4`),
3. `CreateOnlineHostSessionRequest` tells the online service `MaxPlayerCount = 4`,
4. `ReadRuntimeSessionFromGameState` caps player slots at 4 when a saved game is re-hosted.

`version.dll` (a proxy loaded by the game exe) flips literals 2–4 in memory at start-up, locating each by
byte signature. The Lua half (UE4SS) spawns the extra markers, fits the extra cards on screen, widens the
creation camera, extends the host screen's players selector and re-flows the lobby tiles, and owns the
on/off toggle (it rewrites the ini; the DLL's watcher thread follows within a second).

Full research notes are in [docs-workspace-notes.md](docs-workspace-notes.md).

## Building from source

Requires Visual Studio 2022 Build Tools (C++ workload) and Python 3.

```
BiggerParty\build.bat                                  -> dist\version.dll
python BiggerParty\installer\gen_payload.py <UE4SS dir> -> stages the installer payload
BiggerParty\installer\build.bat                        -> dist\BiggerParty-Installer.exe
```

`<UE4SS dir>` is an extracted UE4SS *experimental* release (UE 5.6 support), i.e. the folder that
contains `dwmapi.dll` and `ue4ss\`.

`tools\` holds the reverse-engineering helpers used to find the patch sites (PDB symbol/offset scanners,
a capstone-based disassembler, pak/utoc readers). After a game update, `pdb_pub.py` + `disasm.py` are how
the signatures get re-verified.

## Credits and license

Mod code: MIT (see `LICENSE`). Bundles [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT) in the
installer. Solasta II is © Tactical Adventures; this is an unofficial fan project, not affiliated with or
endorsed by Tactical Adventures or Kepler Interactive.
