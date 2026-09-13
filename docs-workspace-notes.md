# Solasta II modding workspace

Game: Solasta II (Steam app 2975950), Unreal Engine 5.6.1, project name `Brimstone`.
Install: `C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\` — exe + full PDB in `Brimstone\Binaries\Win64\`.
Build this was done against: CL-112340 (2026-09-10 Early Access patch).

## GiveSpellbook (UE4SS Lua mod)
Source of truth lives here; the installed copy is
`...\Brimstone\Binaries\Win64\ue4ss\Mods\GiveSpellbook\Scripts\main.lua`.
UE4SS experimental-latest (v3.0.1-1131-ga8ab88e1, needed for UE 5.6) is installed as
`Win64\dwmapi.dll` + `Win64\ue4ss\`. GUI console: Ctrl+O. Hot reload mods: Ctrl+R. Log: `Win64\ue4ss\UE4SS.log`.
To uninstall UE4SS entirely: delete `dwmapi.dll` and the `ue4ss` folder.

## tools/ (Python 3, no third-party deps)
- `strings_scan.py`  — dumps ASCII/UTF-16 strings from the shipping exe (reflected names, native gameplay tags).
- `pdb_scan.py`      — chunked keyword scan of the 2.4 GB PDB for symbol names (edit `keys`).
- `pdb_order.py`     — recovers UFunction parameter order (UHT `NewProp_*` static addresses) and enum values (LF_ENUMERATE) from raw PDB bytes.
- `pak_index.py`     — parses the unencrypted `Brimstone-Windows.pak` v11 index (config/ini/locres files).
- `pak_read.py`      — extracts pak entries; Oodle blocks decompressed through an `oo2core_*_win64.dll` (set `OODLE_DLL`; any Oodle game ships one).
- `utoc_index.py`    — parses the IoStore `.utoc` directory index to list every cooked asset path.

## extracted-config/
Tag inis and Default*.ini pulled from the pak (gameplay tags for equipment, classes, spellcasting, etc.).

## BiggerParty (the real mod) — 2026-09-13
`BiggerParty/src/version_proxy.cpp` + `build.bat` (MSVC Build Tools 2022) → `BiggerParty/dist/` = the installable package
(version.dll proxy patcher + BiggerParty.ini + ue4ss/Mods/BiggerParty Lua). Installed in the game's Win64 folder.
Patch sites (CL-112340, all found by unique byte signature, refused if the build changes):
- SetupDefaultSession `mov r13d,4` @0x146d69133 (+2) — character slots per new session
- CreateOnlineHostSessionRequest `mov [rax+0xa0],4` @0x146a9cb49 (+6) — lobby MaxPlayerCount
- ReadRuntimeSessionFromGameState `lea r12d,[rbx+4]` @0x146d5d20e (+3) and `cmp ebx,4` @0x146d5d74d (+2) — player-slot cap on loaded games
Load path rebuilds CharacterSlots from the saved party (empties them at 0x146d5dea6), so 4-hero saves are unaffected.
PartyProbe (disabled in mods.txt) is the research version; keep for reference.

### Installer (2026-09-13)
`BiggerParty/installer/` — `gen_payload.py <extracted UE4SS dir>` stages the payload (UE4SS + dist files + GiveSpellbook)
and generates `payload.rc`/`payload_index.h`; `build.bat` builds `dist/BiggerParty-Installer.exe` (MSVC, resources embedded).
Flags: /install /uninstall /spellbook /silent /game "<folder>". Tested on a fake game folder: install, update (ini kept), uninstall.
Share `dist/BiggerParty-1.0.zip` (installer + README). NOTE: never run the exe from Git Bash — MSYS rewrites "/install" into a path.

### v1.1 verification (2026-09-13)
Installer tested end to end against a throwaway copy of the game folder (exe only):
fresh install (27 files, UE4SS + BiggerParty + GiveSpellbook, mods.txt rewritten), update over an existing
install (4 files, BiggerParty.ini preserved), uninstall (nothing left behind but the exe). The embedded
`main.lua` / `version.dll` hash-match the copies verified in-game. The installer refuses to run while
Solasta II is open — that guard fired during the first attempt, which is intended.
