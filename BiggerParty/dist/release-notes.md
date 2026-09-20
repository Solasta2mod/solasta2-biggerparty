For Solasta II Early Access builds **CL-112340** and **CL-112436** (14 Sep 2026 patch).

**1.4.3** — combat XP no longer shrinks with party size. The game pools a fight's XP and divides it by the
number of contenders on the party's side, so six heroes each got a sixth instead of a quarter (and a guest
such as Jebfa takes a share that goes nowhere). The host now tops every hero up to a four-hero share when a
battle ends, through the game's own XP grant, so the console shows the extra gain. `CombatExperienceAsIfFour=1`
in `BiggerParty.ini` (0 restores the game's split). Quest and world-event XP were never split and are unchanged.

**1.4.2** — "Transfer to …" entries beyond the third now work for the other players too, not only the
host. The fallback matched the receiver by the hero's actor name, which only carries the name on the host's
machine (clients see `RulesetActor_<id>`); it now reads the first name from the replicated identity
component. Client logs also name heroes properly. Everyone should update.

**1.4.1** — the Narrator, when installed, says the enemy hit-point percentage aloud on Ctrl+Shift+Up / Down
(the value was only visible in the log, and it persists between sessions, so it was easy to lose track of
where it stood). Ten seconds after every level load the mod now logs one "after load" line (possessed pawn,
own heroes, any loading widget still up) on every machine, to diagnose a player left with a dead screen
after zoning. No other changes.

**1.4** — new optional extra: the **Narrator**. The game's text-only world events are read aloud with a
neural voice as the text appears, and the outcome after your choice too; titles, options, the choice and
reward lines stay silent. Ctrl+Shift+N steps through fifteen English voices (Emily, Irish, by default; each introduces itself; the
choice is saved), Ctrl+Shift+M mutes. Uses Microsoft Edge's free online voices through a small helper
program the mod starts with the game, so it needs internet; lines already heard are cached and replay
offline. Pick "n" (or "a" with GiveSpellbook) in the installer; existing installs keep their extras on
update. No change to BiggerParty itself.

**1.3.1** — multiplayer fixes from the first three-player session. The party-following watchdog treated every
follower as the host's and re-selected the host's hero every ten seconds (other players' followers follow
their own leader; the mod now only looks at the heroes your player state controls, on the host). At a story
scene each player now only possesses a hero of their own; the host used to grab other players' followers.
The party strip no longer un-hides plates the game hid, which duplicated a portrait after a player rejoined.
Also: "Transfer to …" now works for every hero (the game's item menu only handled three receivers); the
inventory strip lists heroes only, so an NPC guest no longer adds spare portraits (which could crash when
clicked); the game's party-formation manager is switched back on when a load leaves it off (followers stood
still); Ctrl+Shift+F is a manual party heal. Known game bug: followers can stop after many leader changes
even in an unmodded four-hero party; save and reload clears it. Everyone in a session should update.

**1.3** — enemy hit points. `EnemyHitPointsPercent` in `BiggerParty.ini` (default 100) scales hostile monsters'
maximum hit points; Ctrl+Shift+Up / Down change it in game by 10. The host applies it to every hostile monster
whose maximum is still its book value (later spawns and loaded saves included), damage already taken is kept,
and 100 puts the monsters the mod raised back. No Difficulty-screen row for it yet: that is native work for a
later release.

**1.2.1** — the 14 Sep patch (CL-112436) is verified; the short/long rest screens now show all six heroes (the row is
scaled as a whole so the text stays readable); the crate/chest and merchant screens get six portraits like the
inventory, with the carried weight under them, and heroes 5 and 6 can loot; after a story scene control goes back to the hero you had selected, through the game's own selection;
and a watchdog fixes a follower that has lost track of the party leader (the "hero wandering like an NPC" report).
This also covers the reported focus problems after story scenes in 1.2 — the selection jumping to another hero,
clicking the current hero doing nothing until you Tab away and back, and combat turn focus getting confused: all
of them came from the mod's temporary possession at scene start not being handed back through the game's own
selection. 1.2.1 hands it back properly and never touches selection during combat.

Also in 1.2.1, a crash fix: everything the mod does now runs on the game thread. UE4SS ran the mod's timers on
its own thread and its hotkeys on the input thread with no lock against the game thread, and a Lua state used
from two threads corrupts itself — the "crash while looting" (and the odd random crash before it) was that,
worst with a loot bag open because that is when the mod's per-second pass is busiest.

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
