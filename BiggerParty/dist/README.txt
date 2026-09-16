BiggerParty 1.3 for Solasta II (Early Access builds CL-112340 / CL-112436)
============================================================
Lets a NEW campaign have up to 6 heroes and a hosted lobby up to 6 players.
Existing saves are untouched; loading a 4-hero save behaves exactly as vanilla.

INSTALL (one click)
  1. Close the game.
  2. Run BiggerParty-Installer.exe. It finds Solasta II through Steam (or asks you to pick the
     "Solasta 2" folder), installs the UE4SS script loader if you do not have it, and installs the mod.
     Press Enter for the default install, or "s" to also get GiveSpellbook (fixes the missing
     spellbook when you multiclass into Wizard in multiplayer).
  3. Start the game normally. Nothing else to launch.
  Everyone in a multiplayer session installs the same way.

IN GAME
  New Campaign        -> six character slots
  Inventory/character -> six portraits (Tab or click to switch hero)
  Story dialogues     -> work with six heroes (four take a family role; two sit that scene out) (all "Create Character")
  Multiplayer > Host  -> "Players" offers 2..6
  Ctrl+Shift+Tab        toggle the mod on/off (applies to the next new campaign / lobby)
  Ctrl+Shift+End        re-apply the card layout / camera on the creation screen
  Ctrl+Shift+Backspace  status report into <game>\Brimstone\Binaries\Win64\ue4ss\UE4SS.log
  Ctrl+Shift+Up / Down  enemy hit points +10% / -10% (hostile monsters; host applies it; 100 = vanilla)

CONFIG   <game>\Brimstone\Binaries\Win64\BiggerParty.ini   (Enabled=1, PartySize=6, EnemyHitPointsPercent=100)
LOGS     <game>\Brimstone\Binaries\Win64\BiggerParty.log   (patcher)  and  ue4ss\UE4SS.log (Lua)

UNINSTALL  run the installer again and choose "u" (removes the mod; asks about GiveSpellbook / UE4SS).

AFTER A GAME UPDATE  the patcher refuses to touch code it does not recognise ("NOT patchable" in
BiggerParty.log) and the mod goes inert until a matching version is released. Your saves are safe.

HOW IT WORKS  version.dll (loaded by the game exe) flips four hard-coded "4" literals in memory at
start-up: character slots per session, hosted-lobby size, and the player-slot cap on loaded games.
The Lua half adds the extra spawn markers in the creation level, fits six cards on screen, widens
the camera, and extends the host screen's players selector. Nothing on disk is modified by the mod.
