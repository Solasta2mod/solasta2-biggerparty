BiggerParty 1.4.3 for Solasta II (Early Access builds CL-112340 / CL-112436)
============================================================
Lets a NEW campaign have up to 6 heroes and a hosted lobby up to 6 players.
Existing saves are untouched; loading a 4-hero save behaves exactly as vanilla.

INSTALL (one click)
  1. Close the game.
  2. Run BiggerParty-Installer.exe. It finds Solasta II through Steam (or asks you to pick the
     "Solasta 2" folder), installs the UE4SS script loader if you do not have it, and installs the mod.
     Press Enter for the default install, "s" to also get GiveSpellbook (fixes the missing
     spellbook when you multiclass into Wizard in multiplayer), "n" to also get the Narrator
     (reads the text-only world events aloud with an AI voice; needs internet), or "a" for both.
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
  Ctrl+Shift+Up / Down  enemy hit points +10% / -10% (hostile monsters; host applies it; 100 = vanilla;
                        the Narrator, if installed, says the new value)
  Ctrl+Shift+F          party heal (followers standing still); if they stay put, save and reload (game bug)

NARRATOR (if installed)
  World events are read aloud as the text appears; titles, options, your choice and rewards stay silent.
  Ctrl+Shift+N          next voice (it introduces itself; the choice is saved)
  Ctrl+Shift+M          mute / unmute
  Voices are Microsoft Edge's online neural voices: internet needed; heard lines are cached and replay
  offline. Settings: <game>\Brimstone\Binaries\Win64\Narrator\narrator.ini (Voice, Rate, Volume, Pitch).
  The helper SolastaNarrator.exe in that folder starts with the game and closes with it.

CONFIG   <game>\Brimstone\Binaries\Win64\BiggerParty.ini   (Enabled=1, PartySize=6, EnemyHitPointsPercent=100,
         CombatExperienceAsIfFour=1: the game splits a fight's XP by head count, so six heroes would level
         at two-thirds the pace; the host tops each hero up to a four-hero share. 0 keeps the game's split.)
LOGS     <game>\Brimstone\Binaries\Win64\BiggerParty.log   (patcher)  and  ue4ss\UE4SS.log (Lua)

UNINSTALL  run the installer again and choose "u" (removes the mod; asks about GiveSpellbook / Narrator / UE4SS).

AFTER A GAME UPDATE  the patcher refuses to touch code it does not recognise ("NOT patchable" in
BiggerParty.log) and the mod goes inert until a matching version is released. Your saves are safe.

HOW IT WORKS  version.dll (loaded by the game exe) flips four hard-coded "4" literals in memory at
start-up: character slots per session, hosted-lobby size, and the player-slot cap on loaded games.
The Lua half adds the extra spawn markers in the creation level, fits six cards on screen, widens
the camera, and extends the host screen's players selector. Nothing on disk is modified by the mod.
