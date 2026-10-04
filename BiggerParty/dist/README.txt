BiggerParty 1.5.1 for Solasta II (Early Access builds CL-112340 / CL-112436 / CL-113670 / CL-114967)
============================================================
Lets a NEW campaign have up to 6 heroes and a hosted lobby up to 6 players.
Existing saves are untouched; loading a 4-hero save behaves exactly as vanilla.

INSTALL (one click)
  1. Close the game.
  2. Run BiggerParty-Installer.exe. It finds Solasta II through Steam (or asks you to pick the
     "Solasta 2" folder), installs the UE4SS script loader if you do not have it, and installs the mod.
     Press Enter for the default install (BiggerParty and the Narrator), "k" to also get the Kobold race,
     or "n" for BiggerParty without the Narrator. (GiveSpellbook is retired: the game fixed the bug it
     worked around. The installer offers to remove an old copy.)
  3. Start the game normally. Nothing else to launch.
  Everyone in a multiplayer session installs the same way.

IN GAME
  Mod options         -> in the title screen and pause menu, after Settings: the version (click it for every
                         player's in multiplayer), "Fix a stuck turn" (multiplayer: the host hands your hero to
                         itself and back, which frees a turn you cannot end; the mod also does it by itself when
                         End Turn does nothing), then the mod's settings as buttons showing their values (the
                         mod on/off, party size, players, enemy hit points, four-hero XP, Narrator on/off and
                         volume, Kobold race on/off and the kobold voice); a click changes one, Back returns
  Version check       -> in multiplayer, a player whose BiggerParty differs from the host's (or is older than
                         1.4.13) gets a message; everyone in a session needs the same version, and the same
                         Kobold race setting (the version reads "1.5.1+kobold" while the race is on)
  New Campaign        -> six character slots
  Inventory/character -> six portraits (Tab or click to switch hero)
  Story dialogues     -> work with six heroes (four take a family role; two sit that scene out) (all "Create Character");
                         when a scene takes its heroes somewhere, the host brings the two who sat it out along
  Multiplayer > Host  -> "Players" offers 2..6
  Ctrl+Shift+Tab        toggle the mod on/off (applies to the next new campaign / lobby)
  Ctrl+Shift+End        re-apply the card layout / camera on the creation screen
  Ctrl+Shift+Backspace  status report into <game>\Brimstone\Binaries\Win64\ue4ss\UE4SS.log
  Ctrl+Shift+Up / Down  enemy hit points +10% / -10% (hostile monsters; host applies it; 100 = vanilla)
  Ctrl+Shift+F          party heal (followers standing still); if they stay put, save and reload (game bug)

NARRATOR (installed by default)
  World events are read aloud by a cast of recorded voices as the text appears; titles, options, your
  choice and rewards stay silent. Picking an option moves straight on to the outcome; closing the event
  stops it. No internet needed.
  Ctrl+Shift+M          mute / unmute
  Ctrl+Shift+= / -      narrator volume up / down (10 to 100%, saved; a chime plays at the new level)
  The recordings (made with Google's Gemini text-to-speech from the game's own text) are in
  <game>\Brimstone\Binaries\Win64\Narrator\pack; settings in Narrator\narrator.ini (Enabled,
  PlaybackVolume). The helper SolastaNarrator.exe in that folder starts with the game and closes with it.

KOBOLD RACE (optional: "k" in the installer)
  A playable kobold: pick Kobold in character creation. It looks like the game's kobolds, carries its weapons
  and gear, and has Draconic Cry and the Kobold Legacy. In cutscenes a kobold hero's lines are spoken in a
  kobold voice (recorded with ElevenLabs; played by the Narrator's helper, so it needs the Narrator).
  Mod options       -> "Kobold race: On/Off" (from the next start; while it is off, kobold heroes show as gnomes)
                       and "Kobold voice" (each click steps it down, 50% to 10%, then back to 50%)
  Ctrl+Shift+, / .      kobold voice quieter / louder
  Settings in <game>\Brimstone\Binaries\Win64\Kobold.ini (Enabled, VoiceLevel); log in Kobold.log (this launch;
  the one before is Kobold-previous.log). The voice is in Narrator\packs\kobold. It changes the game's rules
  (an ancestry): everyone in a session needs it.

CONFIG   <game>\Brimstone\Binaries\Win64\BiggerParty.ini   (Enabled=1, PartySize=6, EnemyHitPointsPercent=100,
         CombatExperienceAsIfFour=1: the game splits a fight's XP by head count, so six heroes would level
         at two-thirds the pace; the host tops each hero up to what four heroes would get, counting any
         companions who fought along (story guests, summons) as the game does. 0 keeps the game's split.)
LOGS     <game>\Brimstone\Binaries\Win64\BiggerParty.log   (patcher)  and  ue4ss\UE4SS.log (Lua; wiped at
         every launch)  and  BiggerParty-history.log (the key lines, kept across launches, including every
         party turn in a fight: send this one when something went wrong before a restart)

UNINSTALL  run the installer again and choose "u" (removes the mod; asks about GiveSpellbook / Kobold / Narrator /
           UE4SS).

AFTER A GAME UPDATE  the patcher refuses to touch code it does not recognise ("NOT patchable" in
BiggerParty.log) and the mod goes inert until a matching version is released. Your saves are safe.

HOW IT WORKS  version.dll (loaded by the game exe) flips four hard-coded "4" literals in memory at
start-up: character slots per session, hosted-lobby size, and the player-slot cap on loaded games.
The Lua half adds the extra spawn markers in the creation level, fits six cards on screen, widens
the camera, and extends the host screen's players selector. Nothing on disk is modified by the mod.
