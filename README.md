# Silph Scope Network (test build 0.12.0)
-- Created with AI/Vibe Coding--

Send your current character to another player online as enemy trainer they can fight!

## How to Use

**Start Menu** now has 3 new options.
1. Send Ghost
2. Online Password
3. Ghost Report

## 1. SEND GHOST

*"Include dialogue with this ghost?"* (default "No").
    -If **NO** and the ghost is sent with no lines.
   - If **YES**: a text-entry screen for the **before-battle line** (capped at 48 characters)
Then: *"Add an after-battle line too?"* (default "No") 
   - If **YES**: a second text-entry screen for the **after-battle line**. (capped at 48 characters)

   *"Set an online Password?"* (default "No").
   Password is used for connecting your ghost with players use set an ONLINE PASSWORD (see below) 

   **Then your ghost is sent online** 

**Your "GHOST" will attempt to be sent to the server that others can see and interreact with as a hostile enemy trainer. 

## 2. ONLINE PASSWORD

**Password (private pools)**: at SEND GHOST time, after the dialogue
prompts, you're asked *"Set an online password?"* (default **NO**, keeps
whatever password this save last set — starts blank/public if you've never
set one). Say yes to type a room code:

- A ghost sent with **no password** is public — every downloader can see it,
  regardless of their own password.
- A ghost sent **with a password** is only visible to downloaders whose own
  currently-remembered password matches it exactly — a private pool for a
  friend group or a streamer's run, separate from the public one.

The password also becomes this save's remembered password for its own
`/nearby` downloads going forward, until you change it at a later send.

## 3 GHOST REPORT 

**GHOST REPORT (Start Menu)**: find out how your ghost is doing out there.
Shows the map it's waiting on, how many trainers have found it, and its
win/loss record:

> Your ghost on ROUTE_1 has been found by 7 trainer(s)!
> It won 4 and lost 3.

- An **encounter** is counted the moment a battle actually starts (the
  ghost has spotted someone and they can no longer walk away) — not every
  time someone wanders past.
- A **loss** means someone actually **beat** your ghost. A **win** is
  everything else — they lost, they ran, or they quit mid-battle. Walking
  out on a fight concedes it to your ghost.
- **The tally resets every time you send a new ghost.** It belongs to the
  ghost that's currently out, not to you forever, so a fresh send always
  starts at zero.

## Options (mod options menu)

- **GHOST COLLISION** — ON (default): ghost is solid, blocks movement like
  any trainer. OFF: non-solid, so it can never wall you into a softlock.
  Wired via the live NPC's underlying entity table (`.passable`).
- **REPEATABLE GHOST BATTLES** — OFF (default): a defeated ghost only
  replays dialogue on interact. ON: interacting with a defeated ghost starts
  a full rematch instead.
- **OFFLINE MODE** — OFF (default), meaning ONLINE MODE is active out of the
  box. Turn OFFLINE MODE **ON** to opt a save out entirely and keep it
  local-only (no server upload, no download) — see below.
- **ONLINE GHOST COUNT** — 1-5, default 3. How many ghosts to request from
  the server per map (only matters unless OFFLINE MODE is on).
- **GHOST SPRITE** — a single dropdown (cycle with left/right), default
  **RED (DEFAULT)**. Picks which overworld sprite + battle art your NEXT sent
  ghost uses; doesn't change one already out there (same rule as
  party/position, which are also only captured at SEND GHOST time).
  **All 45 trainer portraits in the game are available** as of 0.11.0, each
  labelled with its gender:
  - **Classes (M)**: Bug Catcher, Youngster, Jr.Trainer, Cooltrainer,
    Bird Keeper, Hiker, Blackbelt, Biker, Cue Ball, Super Nerd, Pokemaniac,
    Burglar, Engineer, Rocker, Juggler, Tamer, Psychic, Fisherman, Swimmer,
    Sailor, Gambler, Gentleman, Scientist, Rocket Grunt.
  - **Classes (F)**: Lass, Jr.Trainer, Cooltrainer, Beauty, Channeler.
  - **Gym leaders** (badge order): Brock, Misty, Lt. Surge, Erika, Koga,
    Sabrina, Blaine, Giovanni.
  - **Elite Four**: Lorelei, Bruno, Agatha, Lance.
  - **Rival** — all three battle portraits (early / mid / champion) — and
    **Prof. Oak**.
  - **several looks share an overworld sprite** — a Super Nerd, Pokemaniac,
    Burglar, Engineer, Rocker and Brock all walk around identically and only
    differ once the battle starts. That's how the original game does it.

**Sending is one-ghost-per-save.** SEND GHOST always replaces whatever this
save already has out there — it doesn't accumulate. The new ghost has a
fresh identity, so any other save that had already beaten the old one starts
undefeated against the replacement (it's a genuinely new encounter, not a
revival of the old one). The confirmation message says "Your old ghost was
recalled" instead of "sent to the void" when a replacement happens, so you
can tell the two cases apart.


## Where you can SEND a ghost from

**Allowed**: routes (NOT town/city exteriors — allowed in 0.7.1 for easy
testing, deliberately excluded as of 0.8.0), caves (Mt Moon, Rock Tunnel,
Seafoam Islands, Victory Road, Diglett's Cave, Cerulean Cave), Viridian
Forest, the Safari Zone, Pokémon Tower, Pokémon Mansion, Silph Co, SS Anne,
Rocket Hideout, and Power Plant. Also Indigo Plateau grounds and the
Vermilion dock (neither is a town, both are open outdoor areas).

**Blocked**: towns/cities, houses, marts, Pokémon Centers, gyms, Elite Four
rooms, Oak's Lab, the Fighting Dojo, gates, and similar small interiors.

## Online mode (on by default)

A small server (Cloudflare Worker + D1) that ghosts additionally upload to
and download from, layered on top of the local shared-file system (which
keeps working exactly as before, regardless of this setting — local ghosts
never leave the machine either way). **ONLINE MODE is on by default.**

**OFFLINE MODE** (mod option, OFF by default) is the opt-out: turn it **ON**
to keep a save entirely local — no uploads, no downloads, identical to how
the mod behaved before online mode existed. Good for a save you don't want
appearing on other players' machines, or for playing with no network at all.

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




Each one shows the underlying reason on a second page. **If you're testing
and an upload fails, please screenshot that reason** — it names the actual
cause and is the fastest way to get it fixed.



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
forever after. **Fixed in 0.10.7** — the old fallback regenerated itself
every session, which meant each send created an *extra* ghost on the server
instead of replacing your previous one, and GHOST REPORT could never find
your own ghost ("you have no ghost out there" right after a successful
upload). One caveat: a freshly-minted id only sticks once you **save the
game** — send a ghost and quit without saving and you'll get a new identity
next time. Saves where `activeSlot` works are completely unaffected and keep
their existing identity.

## Known limitations:
- Downloaded ghosts don't carry exact IVs (same limitation local ghosts
  already have).
- If a download result arrives after you've already left the map it was
  requested for, it's discarded rather than spawned somewhere wrong.
- IVs/DVs are not exact (only species/level/moves are) — the engine's trainer
  battle construction unconditionally overwrites DVs after building the mon,
  with no supported way around it short of bypassing trainer-battle
  construction entirely.
- Win-detection relies on `start_battle` setting `ctx.lastCheck` immediately
  on return and `jump_if_false`/`label` resolving by string name — both
  confirmed from source, but this exact combination hasn't been run live yet.

## Coming Soon
- Level locking per region, players wont be able to spawn ghosts with high levels near low level areas.
