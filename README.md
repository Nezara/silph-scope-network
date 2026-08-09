# Silph Scope Network (test build 0.8.4)
-- Created with AI/Vibe Coding--

Send your current character to another save as enemy trainer you can fight!

Save your current player character's location and current pokemon party to an external file. Load a different save and engage with them as a enemy trainer! 
Mod Options allow you to repeat the fight if you wish. 

## How to Use
1. In the Start Menu there is an option to "Send Ghost" which sends your current player character and pokemon party to an external file.
2. you will be provided the option to leave both pre-fight and post-fight dialogue. 
3. Save Game
4. Load up a different save file, your previously sent ghost will be at the location the ghost was sent from ready to fight.

## Dialogue

When you **SEND GHOST**, you're asked:

1. *"Include dialogue with this ghost?"* (default **NO**). Say no and the
   ghost is sent with no lines.
2. If yes: a text-entry screen for the **before-battle line** (engine's own
   naming/keyboard screen, capped at 48 characters — comparable to a normal
   NPC's line length in this engine's own text data).
3. Then: *"Add an after-battle line too?"* (default **NO**) — only asked
   after the before-battle line is done, never if you said no to step 1.
4. If yes: a second text-entry screen for the **after-battle line**.

## Options (mod options menu)

- **GHOST COLLISION** — ON (default): ghost is solid, blocks movement like
  any trainer. OFF: non-solid, so it can never wall you into a softlock.
  Wired via the live NPC's underlying entity table (`.passable`).
- **REPEATABLE GHOST BATTLES** — OFF (default): a defeated ghost only
  replays dialogue on interact. ON: interacting with a defeated ghost starts
  a full rematch instead.
- **ONLINE MODE** — OFF (default). See below.
- **ONLINE GHOST COUNT** — 1-5, default 3. How many ghosts to request from
  the server per map (only matters with ONLINE MODE on). Uses
  `type = "number"` in the option definition — **confirmed working live**
  (0.8.1) after an 0.8.0 bug (see changelog) briefly made it look
  unsupported; it wasn't the type, it was a `mod.options:define()` call
  wiping out the other options.


**Sending is one-ghost-per-save.** SEND GHOST always replaces whatever this
save already has out there — it doesn't accumulate. The new ghost has a
fresh identity, so any other save that had already beaten the old one starts
undefeated against the replacement (it's a genuinely new encounter, not a
revival of the old one). The confirmation message says "Your old ghost was
recalled" instead of "sent to the void" when a replacement happens, so you
can tell the two cases apart.


## Where you can SEND a ghost from

Confirmed working live (0.7.1). Trying **SEND GHOST** outside an allowed spot
shows *"Unable to send ghost. Invalid location."* and stops there (no
dialogue prompts).

**Allowed**: routes (NOT town/city exteriors — allowed in 0.7.1 for easy
testing, deliberately excluded as of 0.8.0), caves (Mt Moon, Rock Tunnel,
Seafoam Islands, Victory Road, Diglett's Cave, Cerulean Cave), Viridian
Forest, the Safari Zone, Pokémon Tower, Pokémon Mansion, Silph Co, SS Anne,
Rocket Hideout, and Power Plant. Also Indigo Plateau grounds and the
Vermilion dock (neither is a town, both are open outdoor areas).

**Blocked**: towns/cities, houses, marts, Pokémon Centers, gyms, Elite Four
rooms, Oak's Lab, the Fighting Dojo, gates, and similar small interiors.

This is a per-map-id allowlist built from the actual game data
(`red/data/generated/maps.lua`), not a guess from tileset names — those
turned out to be misleading (the tileset literally called `"MANSION"` is a
Celadon side-quest building, *not* Pokémon Mansion; Pokémon Mansion is
tileset `"FACILITY"`, which it shares with Silph Co, Rocket Hideout, Power
Plant, *and* the Cinnabar/Saffron gyms — so gyms had to be excluded
individually, not by tileset). Rocket Hideout and Power Plant weren't named
explicitly in the request but fit the same "dungeon with trainers or wild
spawns, not a house" pattern as the three named exceptions — flag it if
either shouldn't be allowed. Any map id this list doesn't recognize is
blocked by default (safe-by-default, since this is a restriction).


## Online mode (experimental, 0.8.2)

A small server (Cloudflare Worker + KV) that ghosts can additionally upload
to and download from, layered on top of the local shared-file system (which
keeps working exactly as before regardless of this setting). Turn on
**ONLINE MODE** in the mod options to use it.

**Upload**: happens automatically whenever you **SEND GHOST** with ONLINE
MODE on, using the exact same captured position/party/dialogue as the local
send — no separate action. Fire-and-forget: you get your normal "ghost sent"
confirmation immediately; the upload itself completes in the background and
only shows up in the debug log.

**Download**: whenever you enter a map with ONLINE MODE on, the mod asks the
server for up to **ONLINE GHOST COUNT** ghosts on your current map or any
map directly connected to it (computed from the game's own already-loaded
map data — the server never needs to know the game's map layout), excluding
your own upload. Matching ghosts get spawned the same way local ones do.



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

## Known limitations:
- The server's own storage is a single JSON list, not a real database —
  fine for an experimental feature with a handful of testers, but concurrent
  uploads aren't perfectly atomic (a rare race could drop one).
- Downloaded ghosts don't carry exact IVs (same limitation local ghosts
  already have).
- If a download result arrives after you've already left the map it was
  requested for, it's discarded rather than spawned somewhere wrong.
- Plain HTTP means this traffic isn't encrypted. Given the payload (a
  ghost's map position and party) is meant to be shared publicly by design,
  this is judged an acceptable tradeoff — see above.
- IVs/DVs are not exact (only species/level/moves are) — the engine's trainer
  battle construction unconditionally overwrites DVs after building the mon,
  with no supported way around it short of bypassing trainer-battle
  construction entirely.
- Sight has no wall/obstruction *detection* for whether the player is in view
  (only `move_npc_to`'s own BFS pathing avoids obstacles once it's already
  approaching) — the sight-line check itself is a straight cardinal ray, not
  vision-blocked by scenery.
- Win-detection relies on `start_battle` setting `ctx.lastCheck` immediately
  on return and `jump_if_false`/`label` resolving by string name — both
  confirmed from source, but this exact combination hasn't been run live yet.
