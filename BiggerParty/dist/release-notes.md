For Solasta II Early Access builds **CL-112340**, **CL-112436** (14 Sep 2026), **CL-113670** (21 Sep 2026 "Stabilization" patch) and **CL-114967** (1 Oct 2026).

**1.4.14** — stuck turns are freed by themselves, and two fixes for Mod options. When a player cannot end their
hero's turn (End Turn clicked and nothing happening, or half a minute of their turn with no usable End Turn), their
BiggerParty asks the host's, which hands the hero to itself and back — what the session screen's take and give
did by hand. **Mod options → Fix a stuck turn** asks for it by hand. The host's automatic hand-over after a load
now also works in sessions where the guest has a character slot of their own (it refused there before). Mod
options now sits after Settings in a hosted game too (it went after Multiplayer Settings), and comes back after a
player joins (the game rebuilds the pause menu then, and it stayed away). The player and the host both need 1.4.14. The voice
pack is unchanged (474 of the 490 passages; the rest follow in the next update).

**1.4.13** — the version in Mod options, and a version check between players. Mod options' first row shows the
BiggerParty version; click it to see every player's in a multiplayer session. In multiplayer, each player's
BiggerParty tells the host its version after every load and the host answers with its own: a player whose version
differs, or who reports none (a version before 1.4.13, or no BiggerParty), gets a message in the game's information
dialog, and the line goes to `BiggerParty-history.log`. Everyone in a session needs the same version. The voice
pack is unchanged (474 of the 490 passages; the rest follow in the next update).

**1.4.12** — Mod options in the game's menus. The title screen and the pause menu get a **Mod options** entry
after Settings: the mod's settings as menu buttons, each showing its value — the mod on/off, party size and
players (for the next new campaign / hosted lobby; the players follow the party size while at its maximum),
enemy hit points +10% / −10% (applied at once by the host), four-hero XP, and the Narrator's on/off and volume.
A click changes one; **Back**, or closing the menu, returns to the menu's own entries. The keys and
`BiggerParty.ini` work as before, and **Ctrl+Shift+M** now follows the setting in `narrator.ini`, so it stays in
step with the menu. The voice pack is unchanged (474 of the 490 passages; the rest follow in the next update).

**1.4.11** — the Narrator speaks with recorded voices; a diagnostic and a repair for multiplayer turns.
The Narrator now reads world events with a full recorded cast — a narrator, and a voice of its own for each
character who speaks — made with Google's Gemini text-to-speech from the game's own text: 474 of the 490
passages so far; the last 16 (silent until then) and new takes of 10 that the game words slightly
differently follow in the next update. Microsoft Edge's online voices are gone, and with them the need for an internet connection and the
voice-switching key. The installer now installs the Narrator by default (**n** in its menu leaves it out).
**Ctrl+Shift+=** / **Ctrl+Shift+-** turn the narration up or down in 10% steps (10–100%, saved as
`PlaybackVolume` in `narrator.ini`; a chime plays at the new level, and the line playing follows at once).
Picking an option no longer cuts the start of its own outcome (a short first sentence used to be stopped
along with the narration before it), and a reward line no longer interrupts the outcome it follows: both are
now told apart by the icon the game puts in front of each line. For the occasional multiplayer turn a player cannot end (kicking that player and letting them rejoin, or reloading, frees it):
every machine now writes each party member's turn to `BiggerParty-history.log` — who that machine thinks
controls the hero, which hero its player is on, and what its turn panel offers — and again if the turn is
still running after 45 s. If it happens, send that file from the stuck player's game folder and say which
hero it was. The host also repairs what looks like the cause: after a load the game sometimes deals a hero
to one player and moves it to another a moment later, and that hero's player could then not end its turn,
while handing the hero to the host and back (the session screen's take and give) cleared it. The host now
does that by itself, 3 s after such a move, and logs it as a `handout:` line. Everyone should update, so
that every machine keeps the turn lines; the repair itself only needs the host's copy.

**1.4.10** — Narrator improvements; the party mod itself is unchanged. Picking an option now moves the
narration straight on to the outcome, and closing a world event (or muting) stops the voice at once:
before, a stop let the line already playing finish. The Narrator can also play a recorded voice pack: if
`Narrator\pack` holds one (an MP3 per world-event passage plus `index.json`), its recordings are used
instead of the live voice, matched to the passage on screen, tolerant of small wording changes from game
patches, and starting while the first sentence is still being typed; anything the pack lacks is read live
as before. No pack ships with the mod (recordings are made from the game's own text). The installer now
recognises an earlier BiggerParty `version.dll` and updates it without asking whether to replace "a
different version.dll". Everyone with the Narrator should update (the installer replaces the script and
its helper together). Verified on the 1 Oct 2026 patch (CL-114967): the patch sites, the script half and
the Narrator work unchanged, so 1.4.10 needs no update for it.

**1.4.9** — the 21 Sep 2026 patch (CL-113670). Two of the four patch sites had moved by one register (the
player-slot cap when a saved game is re-hosted), so 1.4.8 ran with only the character-slot and lobby-size
patches on the new build; the signatures now wildcard that byte and all four sites patch again. Every
class, function and property the script half relies on is unchanged in the new build, and the game still
splits combat XP by head count, so the top-up stays correct. Everyone should update.

**1.4.8** — `BiggerParty-history.log` next to the ini keeps the diagnostic lines (loads, "after load", party
ownership, transfers, XP, errors) across launches, because UE4SS wipes its own log at every start and a
player who restarts after a hang or crash had nothing left to send. Trimmed automatically. Nothing else
changes; install it on every machine so the next stuck load can be read.

**1.4.7** — the combat XP top-up (verified in play: a 325 XP fight split seven ways became 81 per hero, as
with four) no longer attempts a grant on an NPC guest; the game's criterion, a hero progress component, is
used. Host-side only. Battles are logged by actor name.

**1.4.6** — "Transfer to …" beyond the third entry moved the worn robe instead of the scale mail that was
right-clicked. The tile you right-click keeps only a scratch view model, re-bound to the *worn* item for
the comparison tooltip while an equippable item is hovered, and the fallback transferred through that.
The tile's real item is now found by other means (the tile blueprint's own view model, the list entry, or
the carried item whose icon the tile shows), and when none is certain the transfer is refused and logged
rather than moving the wrong thing.

**1.4.5** — first attempt at the same bug (the tile's native item slot, which the inventory grid does not
use); superseded.

**1.4.4** — the fallback took the inventory's *selected* item (the last tile left-clicked) as a last resort;
it now reads the right-clicked tile and logs which item it moved and how it found it.

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
