For Solasta II Early Access build **CL-112340**.

**New in 1.2 — story dialogues work with six heroes.**
- Scenes with choices (the family-roles scene after the first short rest, and everything after it) now open
  and accept your choices with a six-hero party. Two things happen under the hood while a dialogue runs:
  the mod possesses a hero who is part of the scene and keeps them in party slot #1, then restores the party
  order afterwards. Details in `docs/internals.md`.
- New `MaxPlayers` option in `BiggerParty.ini`: the number of human players a hosted session accepts
  (default = `PartySize`). `MaxPlayers=4` keeps the vanilla lobby with a six-hero party.
- The short/long rest screens fit six heroes.

**Known limitation:** the family-roles scene has four slots, so two of six heroes hold no family role.

**Install:** unzip, close the game, run `BiggerParty-Installer.exe` (installs UE4SS if needed), start the game.
Everyone in a session installs the same way. `u` in the installer uninstalls.

After a game patch the mod refuses to touch code it doesn't recognise and goes inert (see `BiggerParty.log`);
your saves are safe either way.
