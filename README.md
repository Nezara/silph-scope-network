# Silph Scope Network (test build 0.10.0)
-- Created with AI/Vibe Coding--

Send your current character to another save as enemy trainer you can fight!

Save your current player character's location and current pokemon party to an external file. Load a different save and engage with them as a enemy trainer! 
Mod Options allow you to repeat the fight if you wish. 

## How to Use
1. In the Start Menu there is an option to "Send Ghost" which sends your current player character and pokemon party to an external file.
2. you will be provided the option to leave both pre-fight and post-fight dialogue, then to set an online password (see Online mode below).
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
- **GHOST SPRITE: \<name\>**
— six toggles, Male - Biker, Cool Trainer, Hiker, Female - Beauty, Cool Trainer and Channeler
- all OFF by default.
- Turn one ON to make your NEXT sent ghost use that overworld sprite and matching battle
  art instead of the default (Red). Turning on more than one may invalidate your ghost. 

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

A small server (Cloudflare Worker + D1) that ghosts can additionally upload
to and download from, layered on top of the local shared-file system (which
keeps working exactly as before regardless of this setting). Turn on
**ONLINE MODE** in the mod options to use it.

**Upload**: happens automatically whenever you **SEND GHOST** with ONLINE
MODE on, using the exact same captured position/party/dialogue as the local
send — no separate action. Fire-and-forget: you get your normal "ghost sent"
confirmation immediately, and the upload itself completes in the background
— once the server confirms it, you'll see a second "Ghost uploaded online!"
message pop up.

**Download**: whenever you enter a map with ONLINE MODE on, the mod asks the
server for up to **ONLINE GHOST COUNT** ghosts on your current map or any
map directly connected to it (computed from the game's own already-loaded
map data — the server never needs to know the game's map layout), excluding
your own upload. Matching ghosts get spawned the same way local ones do.

**GHOST REPORT (Start Menu)**: find out how your ghost is doing out there.
Shows the map it's waiting on, how many trainers have found it, and its
win/loss record:

> Your ghost on ROUTE_1 has been found by 7 trainer(s)!
> It won 4 and lost 3.

- An **encounter** is counted the moment a battle actually starts (the
  ghost has spotted someone and they can no longer walk away) — not every
  time someone wanders past.
- A **win** is your ghost beating them. **Losses** are everything else —
  they beat your ghost, ran, or quit mid-battle.
- **The tally resets every time you send a new ghost.** It belongs to the
  ghost that's currently out, not to you forever, so a fresh send always
  starts at zero.

Requires ONLINE MODE (a local-only ghost has nothing to report). Only
downloaded ghosts report battles — fighting your own ghost from another
save on the same machine doesn't count.

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
`/nearby` downloads going forward, until you change it at a later send. Like
everything else this mod sends, it travels in a plain-HTTP query string —
treat it as a room code, not a real credential.

**Setting a password without sending a ghost**: the Start Menu also has an
**ONLINE PASSWORD** entry, separate from SEND GHOST — for a player who only
wants to *download* ghosts from a private pool and doesn't need to send
their own. Opens the same text-entry screen, prefilled with whatever this
save currently has set; typing a new value (or clearing it to blank)
updates it immediately, no ghost upload involved. Whichever was set most
recently — here or at a SEND GHOST — is what's currently in effect.

**Careful — passwords are not symmetric.** This trips people up: if save A
sends with password `TEST` and save B has no password, **B will not see A's
ghost** (A's ghost is private to the `TEST` pool), but A *will* still see
B's public ghost. If you're testing between two of your own saves and one
of them has a password set, that alone can look exactly like "online mode
is broken." Set both to the same password, or clear both to blank.

**Diagnosing "I see no online ghosts"**: check
`silphscope_network/debug.log` in your save folder. Every map entry with
ONLINE MODE on now logs the request (including whether a password is in
play) and the result, e.g.:

```
online: requesting ghosts for map ROUTE_1 (password SET)
online: server returned 0 ghost(s), spawned 0 on map ROUTE_1
```

`returned 0` means the server had nothing matching those maps *and* that
password — usually the password mismatch above, or genuinely nobody else
nearby. `returned 2, spawned 0` instead means the records arrived but were
skipped client-side (already present locally, or malformed).

## "I sent a ghost but nobody else can see it"

Read this first if you're testing with other people — in practice almost
every report of this has one of two causes, and neither is a network fault:

1. **ONLINE MODE was off.** It defaults to **off**, and before 0.9.4 a send
   with it off gave you the *exact same* "sent to the void!" confirmation as
   a real upload — so it looked like it worked while the ghost never left
   your machine. Turn ONLINE MODE on in the mod options, then send again.
   As of 0.9.4 the confirmation says so outright, and `debug.log` records
   `online upload skipped: ONLINE MODE option is OFF`.
2. **You sent from a town.** Town and city exteriors are blocked send
   locations (see above), and the early game is mostly towns — a brand new
   save standing in Pallet Town can't send at all. You'll get *"Unable to
   send ghost. Invalid location."* Walk out to a route and try there.

A successful online send logs `online upload started` followed by
`online upload finished: {"ok":true}`, and shows a second **"Ghost uploaded
online!"** message in game. If you see neither, it never went out.

**As of 0.9.5 a failed upload says so on screen.** Before that, *only*
success was shown — every failure was written to the log and nothing else,
so a send that failed looked identical to one that never tried to upload at
all. That made it impossible to tell apart remotely. Now you'll get one of:

- **"Upload failed to start."** — the ghost couldn't even be packaged
  (payload too big, or something in the name/dialogue the encoder rejected).
- **"Ghost upload failed."** — the request went out and errored (no network,
  timeout, DNS).
- **"Server rejected the ghost."** — it reached the server and was refused,
  with the server's own reason.

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
