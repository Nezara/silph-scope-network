# Silph Scope Network (test build 0.14.0)
-- Created with AI/Vibe Coding--

Send your current character to another player online, either as an enemy
trainer they can fight, or as a friendly NPC who just talks to them (and can
leave them an item). Works on **Pokemon Red/Blue/Yellow**, and now on
**Pokemon Gold (Beta)** too — Gold ghosts and Red-family ghosts are kept in
completely separate pools, so they never mix.

## How to Use

**Start Menu** has one new option: **SILPH NET**. Opening it shows a submenu
with everything the mod does:

1. **MODE** — how downloaded ghosts are filtered/scaled for your level (see below).
2. **SEND GHOST** — capture your current position (and party, for a PokeTrainer ghost) and send it out.
3. **GHOST SPRITE** — pick the look your next sent ghost uses.
4. **GHOST REPORT** — check how your currently-out ghost is doing.
5. **GHOST TYPE** — PokeTrainer (battle) or Friendly (no battle, just talk + optional gift).
6. **ONLINE PASSWORD** — join or leave a private password pool without sending a ghost.

The regular mod options menu still has four settings of its own: **GHOST
COLLISION**, **REPEATABLE GHOST BATTLES**, **ONLINE GHOST COUNT**, and
**OFFLINE MODE** — see the Options section below.

## GHOST TYPE

Pick this from the SILPH NET menu *before* you SEND GHOST — it decides which
flavor your next send is. **You only ever have one ghost out at a time**,
regardless of type — sending a new one (of either type) always replaces
whatever this save currently has out there.

### PokeTrainer (default)

The original mode: sends your current party. Whoever finds it gets ambushed
(sight-triggered) or can walk up and interact with it, and fights your team.
Beating it pays out money exactly like a real trainer battle would for
whichever **GHOST SPRITE** class it's wearing.

### Friendly

No battle at all. A plain NPC of yourself, standing where you sent it — walk
up and interact to talk to it. No party is captured (you can send one with
an empty box). You can:

- Leave a **greeting line** and a separate **return-visit line** — the
  greeting shows the first time any given save talks to it, the return line
  every time after that (per receiving save — someone else's save meeting it
  for the first time still gets the greeting).
- Optionally **leave one item**, picked from your own bag (no key items, no
  HMs — TMs are allowed) and a quantity you choose. It's deducted from your
  bag the moment you pick it, at send time. Each *receiving* save gets one
  copy of it, once, the first time they successfully talk to your ghost — if
  their bag is full at that moment, the visit doesn't "complete," so they can
  come back once they've made room instead of losing the gift.

A Friendly ghost is never subject to **MODE**'s level filtering (it has no
party/levels for that to mean anything about), and is allowed in towns and
cities in addition to everywhere a PokeTrainer ghost can go — see "Where you
can SEND a ghost from" below.

## MODE (formerly a plain LEVEL PROTECTION toggle)

Controls which downloaded **PokeTrainer** ghosts you actually see (Friendly
ghosts are never affected):

- **LEVEL/ZONE** (default) — hides any ghost whose team is well above the
  area you're currently in, read from the game's own wild-encounter and
  trainer data (no hand-maintained table, so it's exact and self-corrects if
  anything patches encounters). A couple of areas get extra leeway: the
  final approach to Victory Road is exempt from the cap entirely, and the
  handful of mid-game routes connecting Celadon/Fuchsia/Saffron/Cinnabar
  (tackleable in almost any order) get a wider margin, so revisiting one
  "out of order" after leveling up elsewhere doesn't lock you out.
- **SCALE TO PLAYER** — see every ghost regardless of area, but each one's
  party levels are set to match your own party's average right before the
  fight. Move sets don't scale with it — a scaled-up mon can still only know
  what it was actually sent with — that's a known, accepted tradeoff for an
  opt-in mode.
- **OFF** — no filtering, no scaling, ghosts exactly as sent. The escape
  hatch if you specifically want a real fight against an overleveled team in
  an early area.

If your own PokeTrainer team is above the LEVEL/ZONE cap for wherever you're
sending from, SEND GHOST tells you the actual cap number and asks "send it
anyway?" before doing anything else — declining cancels the send cleanly.

## Beating a ghost pays out

A PokeTrainer ghost battle pays out just like a normal trainer battle: beat
it and you get money for winning, same as fighting any other trainer in the
game. The amount depends on which **GHOST SPRITE** the sender picked — under
the hood, a ghost pays out exactly what a real trainer of that class would
(a Youngster's ghost is a small win, a Gym Leader's or Elite Four member's is
a bigger one).

## ONLINE PASSWORD

**Password (private pools)**: at SEND GHOST time, after the dialogue
prompts, you're asked *"Set an online password?"* (default **NO**, keeps
whatever password this save last set — starts blank/public if you've never
set one). Say yes to type a room code. You can also set/clear it directly
from SILPH NET's own **ONLINE PASSWORD** row, without sending a ghost.

- A ghost sent with **no password** is public — every downloader can see it,
  regardless of their own password.
- A ghost sent **with a password** is only visible to downloaders whose own
  currently-remembered password matches it exactly — a private pool for a
  friend group or a streamer's run, separate from the public one.

## GHOST REPORT

Find out how your ghost is doing out there. For a **PokeTrainer** ghost it
shows the map it's waiting on, how many trainers have found it, and its
win/loss record:

> Your ghost on ROUTE_1 has been found by 7 trainer(s)!
> It won 4 and lost 3.

For a **Friendly** ghost, there's no win/loss concept — just how many
distinct visitors have talked to it:

> Your ghost on PALLET_TOWN has been visited by 3 trainer(s)!

- An **encounter**/**visit** is counted once per new, distinct interaction —
  for a PokeTrainer ghost, the moment a battle actually starts (not every
  time someone wanders past); for a Friendly ghost, the first time each
  receiving save talks to it.
- A **loss** (PokeTrainer only) means someone actually **beat** your ghost. A
  **win** is everything else — they lost, they ran, or they quit mid-battle.
  Walking out on a fight concedes it to your ghost.
- **The tally resets every time you send a new ghost.** It belongs to the
  ghost that's currently out, not to you forever, so a fresh send always
  starts at zero.

## Options (mod options menu)

- **GHOST COLLISION** — ON (default): ghost is solid, blocks movement like
  any trainer. OFF: non-solid, so it can never wall you into a softlock.
- **REPEATABLE GHOST BATTLES** — OFF (default), PokeTrainer only: a defeated
  ghost only replays dialogue on interact. ON: interacting with a defeated
  ghost starts a full rematch instead.
- **ONLINE GHOST COUNT** — 1-5, default 3. How many ghosts to request from
  the server per map (only matters unless OFFLINE MODE is on).
- **OFFLINE MODE** — OFF (default), meaning ONLINE MODE is active out of the
  box. Turn OFFLINE MODE **ON** to opt a save out entirely and keep it
  local-only (no server upload, no download) — see below.

**GHOST SPRITE** and **MODE**/**GHOST TYPE** moved out of this menu and into
the SILPH NET hub itself (see above) — pick which overworld sprite + battle
art your NEXT sent ghost uses; doesn't change one already out there (same
rule as party/position, which are also only captured at SEND GHOST time).

- **Red/Blue/Yellow**: all 45 trainer portraits in the game are available,
  each labelled with its gender — every regular class, all 8 gym leaders,
  the Elite Four, all three rival stages, and Prof. Oak. Several looks share
  an overworld sprite (a Super Nerd, Pokemaniac, Burglar, Engineer, Rocker
  and Brock all walk around identically and only differ once the battle
  starts — that's how the original game does it).
- **Gold (Beta)**: 4 looks — Beauty, Rocket Grunt, Kimono Girl, plus the
  default Chris lookalike.

**Sending is one-ghost-per-save.** SEND GHOST always replaces whatever this
save already has out there — it doesn't accumulate. The new ghost has a
fresh identity, so any other save that had already beaten the old one starts
undefeated against the replacement (it's a genuinely new encounter, not a
revival of the old one). The confirmation message says "Your old ghost was
recalled" instead of "sent to the void" when a replacement happens, so you
can tell the two cases apart.

## Where you can SEND a ghost from

**PokeTrainer ghosts** — outdoor/dungeon areas only, never a town or a
regular building interior, so the sight-ambush never surprises anyone in a
Pokemon Center:

- **Red/Blue/Yellow**: routes, caves (Mt Moon, Rock Tunnel, Seafoam Islands,
  Victory Road, Diglett's Cave, Cerulean Cave), Viridian Forest, the Safari
  Zone, Pokémon Tower, Pokémon Mansion, Silph Co, SS Anne, Rocket Hideout,
  Power Plant, Indigo Plateau grounds, and the Vermilion dock.
- **Gold (Beta)**: any map whose own data marks it as a route, cave, or
  dungeon — derived from the cart's own data, not a hand-built list.

**Friendly ghosts** — everywhere a PokeTrainer ghost can, **plus** every
town/city exterior (it never ambushes anyone, so towns are fair game). Still
never a regular building interior (houses, marts, Pokemon Centers, gyms).

**Blocked either way**: houses, marts, Pokémon Centers, gyms, Elite Four
rooms, Oak's Lab, the Fighting Dojo, gates, and similar small interiors.

## Online mode (on by default)

A small server (Cloudflare Worker + D1) that ghosts additionally upload to
and download from, layered on top of the local shared-file system (which
keeps working exactly as before, regardless of this setting — local ghosts
never leave the machine either way). **ONLINE MODE is on by default.**

**OFFLINE MODE** (mod option, OFF by default) is the opt-out: turn it **ON**
to keep a save entirely local — useful for sending your player character
across your own saves. Got multiple playthroughs? Now you can battle your
own different teams against each other.

**Upload**: happens automatically whenever you **SEND GHOST**, unless
OFFLINE MODE is on, using the exact same captured position/party/dialogue as
the local send — no separate action. Fire-and-forget: you get your normal
"ghost sent" confirmation immediately, and the upload itself completes in
the background — once the server confirms it, you'll see a second "Ghost
uploaded online!" message pop up. With OFFLINE MODE on, the send
confirmation says so explicitly, so it's never ambiguous whether a ghost
went anywhere.

**Download**: whenever you enter a map, unless OFFLINE MODE is on, the mod
asks the server for up to **ONLINE GHOST COUNT** ghosts on your current map
or any map directly connected to it (computed from the game's own
already-loaded map data — the server never needs to know the game's map
layout), excluding your own upload. Matching ghosts get spawned the same way
local ones do.

**Same-tile collision**: if two different senders' ghosts happen to land on
the exact same tile, only one of them is ever shown to a given viewer (a
50/50 pick) rather than both stacking visually on one square.

Each upload failure shows the underlying reason on a second page. **If
you're testing and an upload fails, please screenshot that reason** — it
names the actual cause and is the fastest way to get it fixed.

## Nicknames

If you've nicknamed a Pokemon in your party, its nickname travels with it —
downloaders see and fight (or, for a Gold ghost, receive) your mon under the
name you gave it, not just its species.

## Save identity (why "different save" means different SLOT)

Ghosts are excluded from their own save using an identity string built from
**which save slot is active** (`SaveData.activeSlot`, the engine's own
"which file is this") combined with the trainer's name+id. Trainer name+id
*alone* isn't reliable — two genuinely different save files can share the
same trainer id in this engine — so slot number is the part that actually
distinguishes "your other save" from "this one." Defeat state is tracked the
same way it should be: per receiving save, via the engine's own `Flags`
module (`save.flags`), not shared globally across every save that fights
this ghost.

**If `SaveData.activeSlot` isn't available on your build** (it failed on at
least one real tester's client), the mod falls back to a random id minted
**once** and stored as a flag inside your save file, so it stays the same
forever after. One caveat: a freshly-minted id only sticks once you **save
the game** — send a ghost and quit without saving and you'll get a new
identity next time. Saves where `activeSlot` works are completely unaffected
and keep their existing identity.

## Known limitations

- **Red/Blue/Yellow**: downloaded ghosts don't carry exact IVs (DVs are
  overwritten by the engine's own trainer-battle construction, with no
  supported way around it) — only species/level/moves/nickname are exact.
- **Gold (Beta)**: exact DVs (and therefore gender/shininess, which are
  derived from them) DO carry through — full fidelity, not just
  species/level/moves.
- If a download result arrives after you've already left the map it was
  requested for, it's discarded rather than spawned somewhere wrong.
- GHOST REPORT's tallies are unauthenticated and technically forgeable —
  fine for bragging-rights numbers on a small test build, not load-bearing
  for anything.
