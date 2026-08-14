# Design backlog

Parked designs and locked decisions that don't live anywhere else in the repo.
These were worked out in detail before implementation started; recording them
here so the reasoning (especially explicit overrides of an AI-recommended
approach) survives independently of any one chat session.

Status key: **DESIGNED** = decided, not built. **PARKED** = designed and
explicitly deferred with the maintainer's OK. None of the three below have
any code yet — check current `main.lua`/`worker.js` before assuming otherwise.

---

## Same-tile ghost collision

**BUILT (2026-08-14), not yet live-tested. Maintainer's call: 50/50 only,
not reposition-to-a-nearby-tile.** The relocation alternative was floated
and rejected -- it needs a reliable "is this adjacent tile actually walkable
terrain" check (not just "is another entity standing on it," which is all
`Collision.occupied` gives), an unconfirmed piece of engine surface on
either generation, and it would also change the server contract back to
"return both, let the client sort it out" instead of "pick one winner" --
more moving parts for a collision that's rare given today's ghost density.
If it ever needs revisiting, that's the upgrade path; the 50/50 below ships
first because it's fully designed against confirmed APIs.

Two *different* senders uploading at the same `mapId`+`x`+`y`
currently both spawn on one square and visually stack.

Not the same bug as the old local/online double-battle (that was one sender
seen twice — via the local `ghosts.lua` file and the online download at once
— fixed by the `mapOrigins` dedup table). `mapOrigins` tracks *sender*
identity per map; it has no way to catch two distinct senders who happen to
share coordinates.

Decision: **randomly pick one and show that.**

Shipped exactly as designed below — both halves built and deployed
2026-08-14 (server live, client synced to the local install, not yet
live-tested end-to-end).

- **Server side** — `/nearby` gains a positional partition:
  ```sql
  SELECT * FROM (
    SELECT <cols>,
           ROW_NUMBER() OVER (PARTITION BY mapId, x, y ORDER BY RANDOM()) AS rn
    FROM ghosts
    WHERE mapId IN (...) AND id != ? AND (password = '' OR password = ?)
  ) WHERE rn = 1
  ORDER BY RANDOM() LIMIT ?
  ```
  D1 window-function support (`ROW_NUMBER() OVER (PARTITION BY ...)`) was
  confirmed live against the production database — no need for a
  `MIN(RANDOM())`-plus-bare-column fallback.
- **Client side must ALSO guard** — the server can only dedupe among rows it
  stores. A ghost from the local `ghosts.lua` file is invisible to it, so a
  local ghost and a downloaded ghost can still land on the same tile (most
  likely on a dev machine where several saves share one local file). Add a
  per-map occupied-tile set, e.g. `mapTiles[mapId]["x,y"]`, registered in
  `spawnOneGhost` alongside the existing `mapGhosts`/`mapOrigins` tracking,
  and checked by `spawnOnlineGhost` before it spawns. Local ghosts spawn
  synchronously at map entry and register first, so they reliably win the
  race against any async online fetch — same ordering guarantee
  `mapOrigins` already depends on.
- **Keep both checks.** `mapOrigins` = same sender via two channels. The new
  tile guard = different senders, one square. They catch different bugs.
- Do the server half too, not just the client — `/nearby` returns up to N
  results, so discarding duplicates purely client-side would silently
  shrink the result below the requested count even when distinct,
  non-colliding ghosts exist elsewhere in the response.

---

## Water ghosts use the surf sprite

**ABANDONED (2026-08-13), reverted.** Tried two approaches, both live-tested
by the maintainer and rejected:

1. Replace the ghost's sprite outright with the surf blob (`SPRITE_SEEL`) on
   a water tile. Rejected: erases whichever GHOST SPRITE the sender picked,
   the ghost is just an anonymous rider.
2. Layer a second, decorative "mount" NPC (the surf blob) UNDER the ghost's
   own unchanged sprite on the same tile, mount spawned first hoping the
   engine's per-frame Y-sort would keep it underneath. **Did not work in
   practice** — the flagged caveat (two entities on one cell have identical
   pixel Y, and the sort has no documented tie-break except a Pikachu-
   follower special case) turned out to matter; confirmed live, not just
   theorized.

**Decided final behavior: do nothing special.** A ghost sent from/spawned on
a water tile just displays its normal GHOST SPRITE, standing on the water,
same as any other tile. Simpler, no extra NPC, no sort-order gamble. A real
composited sprite (bake the sender's look onto a mount graphic at spawn time
via a LÖVE canvas) would be the only way to do this properly, but is a much
bigger job and not planned unless separately requested.

The temporary "SPAWN TEST GHOST" Start Menu debug tool (added to preview
this) was removed along with it — it had no purpose beyond eyeballing this
feature.

A ghost sent while surfing currently spawns as a trainer standing on open
water. Sea routes (e.g. Route 19/20/21) are already sendable, so this is
reachable today, not hypothetical.

Both engine pieces needed are confirmed present:
- `Map:isWaterCell(cx, cy)` — a public instance method (`src/world/Map.lua`).
  Reachable via `mod.world:overworld().map`.
- `SPRITE_SEEL` is the vanilla surf-blob sprite —
  `FieldDefaults.PLAYER_SPRITES.surf` (`src/world/FieldDefaults.lua`), the
  same "Pokémon under the player while surfing" the game already shows for
  the player themself.

Decision: **detect receiver-side, in `spawnOneGhost`**, not sender-side.

Deliberately *not* the more obvious approach (read `player.surfing` at SEND
GHOST time, store a flag on the ghost record). Receiver-side wins on every
axis that matters here:
- No new column, no migration, no protocol change.
- Works retroactively on rows already sitting on the server.
- Works for older sender clients that never set any such flag.
- Can't be forged, can't go stale.
- Never crosses the wire, so the existing `SPRITE_PAIR_OK` allowlist
  (client-side validation of sprite/pic pairs from the network) doesn't even
  need to know about it.

Mechanically: check `isWaterCell(rec.x, rec.y)` on the already-loaded current
map at spawn time; if true, override `objDef.sprite` to `SPRITE_SEEL`,
ignoring whatever GHOST SPRITE the sender picked. Battle portrait is
unaffected — still the sender's chosen trainer class — so it reads as Seel
blob in the overworld, proper trainer portrait once the battle starts,
mirroring how the player's own surfing already looks.

Open, unresolved details:
- Whether to honor Pokémon Yellow's `surfPikachu = "SPRITE_SURFING_PIKACHU"`
  instead of always using Seel. Simplest option is "always Seel" regardless
  of the receiving save's version.
- A water ghost still applies collision, so it blocks that surf tile like
  any other ghost — confirm this is actually desired before shipping (it
  wasn't separately re-litigated after being raised).
- Unverified assumption: `overworld().map` is reachable and populated at the
  moment `spawnOneGhost` runs.

---

## Level/zone protection (anti-smurf filter)

**BUILT (2026-08-14), not yet live-tested.** Goal: stop smurfing —
high-level players parking level-100 teams as unbeatable "ghosts" in
early-game areas. Gen 1 only for now — `zoneLevel` always returns nil on
Gold, so GHOST LEVELING's REGION LOCK mode is a harmless no-op there until
Gen 2's equivalent wild/trainer data shapes get the same research pass.

Follow-up refinements past the original design below, both maintainer calls:
- **ROUTE_23 exempt** (`LEVEL_PROTECTION_EXEMPT_MAPS`) — the final approach
  to Victory Road/Elite Four, where legitimate late-game teams cluster and
  team power swings more with moveset/skill than the handful of levels a cap
  would gatekeep.
- **Branch-route leeway** (`LEVEL_PROTECTION_BRANCH_MAPS`, +8 flat margin
  replacing the default +2, not stacked) — Routes 7/8/16/17/18/19/20, the
  connective routes between Celadon/Fuchsia/Saffron/Cinnabar (tackleable in
  almost any order once you have the right HMs), so looping back through one
  "out of order" after leveling up elsewhere doesn't quietly hide a player's
  ghost. Measured against real data: zone levels there run 22 (Route 7) to
  40 (Route 19/20) on their own, before margin — a judgment call, not tuned
  live yet.
- The send-time sender warning (item 1 below) now fires **first**, before
  any dialogue prompts, with the actual cap number and a yes/no "send it
  anyway?" gate instead of a footnote after the fact.

### Key research finding: no external wiki/database needed

The original instinct was to scrape a wiki for per-area levels and bundle a
condensed table into the mod. That's unnecessary and strictly worse — the
game already has every number needed at runtime, for free:

- **Wild levels**: `game.data.encounters[mapId].grass.slots[i].level` and
  `.water.slots[i].level` (shape confirmed via `src/mods/Schemas.lua`'s
  `R.encounters` and `src/world/Encounter.lua`'s `roll`).
- **Trainer levels**: `game.data.maps[mapId].objects[i].trainerClass` +
  `.trainerParty`, indexing into
  `game.data.trainers[class].parties[partyIndex][j].level`
  (`R.trainers` schema). Verified against `tools/rom_manifest.json`
  (e.g. Route 3 has 8 trainer objects, Viridian Forest 3, Route 1 zero —
  matches vanilla Red).

So `zoneLevel(mapId) = max(all wild slot levels, all trainer party levels)`,
computed client-side, no data file to ship or keep in sync. It's exact for
whatever ROM the player actually has loaded, and auto-corrects if another
mod patches encounters via `mod.content.encounters:patch` — nothing here
can drift out of date the way a bundled table would.

### Locked decision: zone-based cap only, with an off switch

`cap = zoneLevel(mapId) + margin` (margin ≈ 1-2), as a toggle **defaulting
ON**.

**This overrides an earlier AI recommendation — do not re-propose the
alternative.** The originally-recommended formula was
`max(zoneLevel, playerMaxPartyLevel) + margin`, reasoning that an
endgame player revisiting an early area should still be able to see a
challenging ghost there. The maintainer explicitly rejected this:

> "an end game player visiting early areas can realistically just turn off
> the filter... protects people from being smurfed and end game players can
> seek a challenge at their choosing, when they want to."

The toggle **is** the escape hatch. The player-relative formula solves a
problem the toggle already solves, at the cost of making the *default*
experience worse for the people the feature exists to protect. Any future
change to this formula needs a fresh, explicit ask — this isn't an
oversight to "fix" on sight.

### Level-scaling: originally rejected, later BUILT as an opt-in mode

The option floated early on (scale a ghost's Pokémon to match the viewer's
own level) was rejected outright at design time:

- Produces impossible combinations — a level-5 Blastoise, for instance.
- Moves don't scale with level, so a downscaled mon can still carry a move
  it shouldn't have yet (level-8 with Hyper Beam).
- Silently misrepresents another player's actual team.
- Corrupts that sender's win/loss record — their ghost would lose fights it
  was never actually sent to fight, since the fight itself wasn't the team
  they built.

**Built anyway on 2026-08-14, maintainer's explicit call**, as the third
`GHOST LEVELING` choice alongside REGION LOCK (the filter above) and OFF:
**SCALE TO ME**. Every downloaded ghost's mons get leveled to the viewer's
own party average (species/moves/dvs untouched) right before the fight, on
the viewer's own client — never mutates the stored ghost record, so a
different viewer with REGION LOCK or OFF still sees the sender's real team.
The move-power and win/loss-record caveats above are known and accepted for
this opt-in mode specifically ("I know move power does not scale, but its a
choice people can make") — they were never solved, just judged acceptable
once the player is choosing it deliberately rather than having it forced on
by default. REGION LOCK stays the default; SCALE and OFF are both opt-in.

### Enforcement point: server-side, mirroring `password`

Client-side post-download filtering is the wrong shape here: `/nearby`
already returns up to N results, and discarding some locally after the fact
yields fewer than N even when other eligible ghosts exist elsewhere on the
server. So:

- Store a `maxLevel` column on the `ghosts` table, computed **at upload
  time** from the party JSON the worker already parses.
- `/nearby` takes a `maxLevel` param (the requester's own current cap) and
  filters `WHERE maxLevel <= ?`.
- Unlike `/report` (unauthenticated, forgeable — see the accepted-gaps
  note), this one is genuinely robust: `maxLevel` is derived server-side
  from the sender's actual uploaded party, so a sender can't understate it,
  and the requester's own cap only gates what *they* see — lying about your
  own cap gains a smurf nothing.

### Two details flagged at design time — both RESOLVED in the build

1. **Warn the sender at send time** when their team exceeds the *local*
   zone cap for the tile they're sending from. Done: fires FIRST in the
   SEND GHOST sequence (before any dialogue prompts), names the actual cap
   level, and gates the send behind a yes/no "send it anyway?" choice
   rather than a silent footnote.
2. **Fallback for sendable maps with neither wild nor trainer data.**
   Done: `zoneLevel` inherits the max across directly-connected neighbors
   (via `nearbyMapIds`, the same list `/nearby` already builds) when a map
   has no wild/trainer data of its own.
