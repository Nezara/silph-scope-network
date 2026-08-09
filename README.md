# Rival Ghosts (test build 0.8.4)

Send your current character — map position + party — to a shared file that
lives outside every save. Load a **different** save file and your sent
characters appear as enemy trainers standing where you left them: they spot
you and force a battle, with optional dialogue you wrote. Once beaten,
interacting with them just replays their after-battle line — unless you turn
on repeatable battles, in which case they'll fight you again. Shared across
all saves (like Pokémon Bank's storage). Each save only ever has **one**
ghost out at a time — sending a new one replaces the old.

## Confirmed working live

- SEND GHOST (Start menu) captures position + party, written to
  `rival_ghosts/ghosts.lua` on the game's own save schedule.
- Ghost spawns in the correct spot, facing the right direction, on a
  different save FILE — see **Save identity** below for why *slot* is what
  matters, not just trainer name.
- Ghost is correctly excluded from the save it came from.
- Battles use the ghost's real species, levels, and moveset.
- The sight mechanic (stands still, spots you crossing its line of sight,
  "!" + sting, walks up via real BFS pathing, force-engages, player genuinely
  unable to walk away mid-approach) is confirmed working.
- Before/after-battle dialogue confirmed working around the fight.
- The full 0.7.0 redesign (unconditional sight-hunting, defeat tracking,
  interact-only post-defeat, GHOST COLLISION) and the 0.7.1 send-location
  restrictions are both confirmed working live — user: *"all appears to be
  working currently"* / *"that's perfect, exactly what I wanted."*
- 0.7.2 (one-ghost-per-save replacement) confirmed working live: *"works
  perfectly."*
- 0.8.1: excluding towns from allowed send locations confirmed working live:
  *"sending ghosts in towns is now blocked."*

**ONLINE MODE**: 0.8.1's live test found upload/download silently failing
every single time (`schannel: CRYPT_E_NO_REVOCATION_CHECK`, a Windows
certificate-revocation-check failure in curl, which the engine's networking
shells out to). Switched the server URL to plain HTTP in 0.8.2, which
sidesteps the problem entirely (no TLS handshake, nothing to revocation-check).
0.8.2's re-test: **upload confirmed working** (verified directly by reading
the server's KV store, not just the debug log — the sent ghost was genuinely
there, correct party/moves/position). Download also worked, but surfaced a
real bug: the same ghost showed up TWICE on the same map (once as a local
ghost, once downloaded), causing a double battle. Root cause and fix in
0.8.3 — see **Online mode** below. Not yet re-tested after the fix.

## How it works now

There's no more mode picker. Every ghost behaves the same way:

1. **Alive**: stands still watching its saved facing direction. Cross its
   line of sight and it shows "!" + a sting, walks up to you, and force-fights
   you — no button press needed, you can't just walk away mid-approach.
2. **You win**: the ghost is marked defeated (tracked per receiving save, so
   it's independent across every save that fights it). It stops hunting.
3. **Defeated**: it just stands there. Walk up, face it, and press the
   interact button:
   - **REPEATABLE GHOST BATTLES off (default)**: replays its
     after-battle line (or a generic line if it has none) — no fight.
   - **REPEATABLE GHOST BATTLES on**: fights you again in full,
     before-line → battle → after-line, same as the first encounter.
4. **You lose or flee**: the ghost is *not* marked defeated — it keeps
   hunting, same as a real trainer you didn't beat.

**Sending is one-ghost-per-save.** SEND GHOST always replaces whatever this
save already has out there — it doesn't accumulate. The new ghost has a
fresh identity, so any other save that had already beaten the old one starts
undefeated against the replacement (it's a genuinely new encounter, not a
revival of the old one). The confirmation message says "Your old ghost was
recalled" instead of "sent to the void" when a replacement happens, so you
can tell the two cases apart.

## How to test

1. Load save slot **A**. Out in the overworld, **Start → SEND GHOST**. You'll
   be asked whether to include dialogue (default NO — see **Dialogue**
   below); then the ghost is captured. **Save the game.**
2. Load save slot **B**. Walk into the ghost's line of sight from a few tiles
   away and let it spot you — confirm it walks up and force-engages.
3. **Lose or flee on purpose** — confirm the ghost is still hunting
   afterward (not marked defeated).
4. **Win** — confirm the ghost stops hunting and just stands there.
5. Face it and press interact — confirm it replays its after-battle line
   (or the generic fallback if it has none), with no fight.
6. Turn on **REPEATABLE GHOST BATTLES**, interact again — confirm it
   fights you in full this time.

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

## Online mode (experimental, new in 0.8.0, options bug fixed in 0.8.1, transport fixed in 0.8.2)

A small server (Cloudflare Worker + KV) that ghosts can additionally upload
to and download from, layered on top of the local shared-file system (which
keeps working exactly as before regardless of this setting). Turn on
**ONLINE MODE** in the mod options to use it.

**Server**: `http://silph-scope-network.silphscopenetwork.workers.dev` —
source and setup instructions in a separate `rival-ghosts-server` project
(`C:\Users\skipp\Documents\Wills Junk\rival-ghosts-server\`), not part of
this mod's files. Manually tested end-to-end (upload → nearby → replace →
validation) via `curl`/PowerShell before any mod code was written against
it — confirmed working independent of the game.

**Plain HTTP, deliberately.** 0.8.1's live test showed every single upload
and download attempt failing with
`curl: schannel: CRYPT_E_NO_REVOCATION_CHECK` — a Windows certificate
revocation-check failure in curl (confirmed via `rival_ghosts/debug.log`),
which this engine's `Fetch` module shells out to on desktop. This is a
machine/network-level curl problem, not a bug in the server or this mod's
code — the exact same error independently hit unrelated tooling earlier in
this project against a completely different site. Plain HTTP has no TLS
handshake at all, so there's nothing to revocation-check — confirmed the
server answers identically over HTTP with no redirect. There's no sensitive
data in a ghost's payload (map position and party — the whole point is
sharing it with other players), so dropping transport encryption is an
acceptable tradeoff for a feature that otherwise doesn't work at all on an
affected machine. If this ever needs to move back to HTTPS, the real fix is
on the affected player's machine: Control Panel → Internet Options →
Advanced → Security → uncheck "Check for server certificate revocation".

**Why GET-only**: this engine's networking (`src/net/Fetch.lua`, wrapping
`HostShell.httpGet`/`httpDownload`) has no POST or request-body support
anywhere in the stack — confirmed by reading all the way down to the curl
transport layer. So "upload" is a GET request with the ghost's data
base64-encoded into a query parameter (`/upload?data=...`), not a normal
REST call. Downloads use the same `Fetch.get` — an async, non-blocking call
that returns a job id to poll, so neither direction can freeze the game even
if the server is slow or unreachable.

**Upload**: happens automatically whenever you **SEND GHOST** with ONLINE
MODE on, using the exact same captured position/party/dialogue as the local
send — no separate action. Fire-and-forget: you get your normal "ghost sent"
confirmation immediately; the upload itself completes in the background and
only shows up in the debug log.

**Download**: whenever you enter a map with ONLINE MODE on, the mod asks the
server for up to **ONLINE GHOST COUNT** ghosts on your current map or any
map directly connected to it (computed from the game's own already-loaded
map data — the server never needs to know the game's map layout), excluding
your own upload. Matching ghosts get spawned the same way local ones do
(GHOST SIGHT hunting, defeat tracking via `Flags`, dialogue, everything) —
they're just a second source feeding the same spawn system. Downloaded
ghosts refresh every time you re-enter the map (old ones despawn, a fresh
request goes out), so they can't go stale, but there's no live "someone just
appeared nearby" push — it's pull-on-entry only, a first-version
simplification.

**Local/online dedup (fixed in 0.8.3)**: a SEND GHOST with ONLINE MODE on
writes to both the local shared file *and* the server, so the identical
ghost can be visible through both channels at once — on a single machine
testing both saves and one online account, a different save could see the
same ghost twice on the same map (once local, once downloaded), spawning two
overlapping NPCs and causing a double battle (confirmed live). Fixed: each
map tracks which senders' ghosts are already spawned on it (by their raw
identity, regardless of which channel spawned them); the local copy always
spawns first and wins, and a download that would duplicate an already-spawned
sender is skipped (logged, not silently dropped).

**Known limitations**:
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

**Separate observation (not yet fixed, noticed while diagnosing the above)**:
the debug log from the same test session showed GHOST SIGHT's re-arming
firing early — dozens of `"sight-triggered script refused (a script is
already running)"` lines logged every ~0.35s throughout an entire walk-up +
battle sequence, instead of just going quiet until it was truly over. The
battle itself completed correctly (confirmed: the ghost ended up properly
defeated and interactable afterward) — this looks like log noise and wasted
retry attempts, not a functional break, but hasn't been root-caused or
fixed yet.

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

Confirming an empty line at the text-entry screen (just pressing START
without typing) counts as "no line" — it has no separate cancel button (B
only backspaces), so this is the way out if you change your mind mid-typing.

The before-line plays right after the ghost walks up to you (before the
fight); the after-line plays once the battle ends, and is also what replays
on interact after the ghost is defeated (if it has one — otherwise a generic
fallback line is used instead).

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

## Known limitations

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

## Debug log

`rival_ghosts/debug.log`, next to `ghosts.lua`. Every material step (identity
resolution, spawn results, engagement, sight triggers, now-defeated counts on
load) is logged there — check it first before assuming something new is
broken. Also check `lua-error.log` (same folder) on any crash — that's where
this engine writes the actual Lua traceback, not the mod's own log.

## Changelog (condensed)

- **0.8.4** — Naming cleanup ahead of the first public release: renamed the
  `ghost_repeatable` option label from "ENABLE REPEATABLE GHOST BATTLES" to
  "REPEATABLE GHOST BATTLES" for consistency with the mod's other option
  labels (GHOST COLLISION, ONLINE MODE, ONLINE GHOST COUNT), which are all
  short noun phrases. No behavior change.
- **0.8.3** — Verified the 0.8.2 upload fix by reading the server's KV store
  directly (`wrangler kv key get`), not just the debug log — the sent ghost
  was genuinely stored, correct party/moves/position. Fixed a real bug found
  in the same live test: the same ghost appeared TWICE on one map (local +
  downloaded) when the sender both writes locally and uploads, causing a
  double battle. Fixed with a per-map "which senders are already spawned
  here" set (`mapOrigins`) — the local copy always spawns first and wins; a
  download that would duplicate it is skipped instead of spawned alongside.
- **0.8.2** — Fixed online mode silently failing 100% of the time: every
  upload/download attempt errored with
  `curl: schannel: CRYPT_E_NO_REVOCATION_CHECK` (confirmed via debug log) —
  a Windows certificate revocation-check failure in curl, which this
  engine's networking shells out to on desktop. Not a bug in the server or
  this mod's code (the exact same error hit unrelated tooling earlier in
  this project against a different site entirely) — switched the server URL
  to plain HTTP, which has no TLS handshake and therefore nothing to
  revocation-check. Confirmed the server answers identically over HTTP with
  no redirect. Also noted (not yet fixed) a separate log-noise issue found
  while diagnosing: GHOST SIGHT's re-arming appears to fire early during a
  walk-up/battle sequence, causing repeated harmless "script already
  running" retries instead of going quiet until it's truly over.
- **0.8.1** — Fixed a real bug found in the 0.8.0 live test: `mod.options:define()`
  REPLACES the whole option set on each call rather than adding to it, so
  0.8.0's second call (registering ONLINE GHOST COUNT separately, to isolate
  risk from what was then an unconfirmed numeric option type) silently wiped
  out GHOST COLLISION/REPEATABLE GHOST BATTLES/ONLINE MODE. Fixed by
  merging all four options into one `:define()` call. Silver lining: this
  proved `type = "number"` (with `min`/`max`/`step`) genuinely works in this
  engine — it wasn't rejected, the two-call split just took the others down
  with it.
- **0.8.0** — Added experimental ONLINE MODE (see above): upload on send,
  download on map entry, via a Cloudflare Worker server and the engine's
  GET-only `Fetch`/`Json` internals. Also removed town/city exteriors from
  SEND GHOST's allowed locations (routes and dungeons only now) — they were
  left in during 0.7.1 for easy testing.
- **0.7.2** — SEND GHOST is now one-per-save: a new send removes any
  ghost(s) already out there from this save (matched by origin) before
  adding the replacement, instead of accumulating alongside them.
- **0.7.1** — Added SEND GHOST location restrictions: outdoor overworld +
  dungeons (caves, Pokémon Tower, Viridian Forest, Safari Zone) + Pokémon
  Mansion/Silph Co/SS Anne/Rocket Hideout/Power Plant only, everything else
  (houses, marts, centers, gyms, labs, gates) blocked with an "Unable to send
  ghost. Invalid location." message. Built as a per-map-id allowlist from the
  real game data, not tileset names (which are misleading — see above).
- **0.7.0** — Major redesign per request: no more mode options. Every ghost
  is always a sight-hunter until defeated; once beaten it becomes an
  interact-only NPC that replays its after-battle line, or fully rematches if
  **REPEATABLE GHOST BATTLES** is on. Defeat state is tracked per
  receiving save via the engine's `Flags` module (`save.flags[name] = true`,
  confirmed a real, directly-callable part of the save's own data — unlike
  `game.save.modData`, which never reliably persisted). Win-only detection
  uses `start_battle`'s own `ctx.lastCheck = (result == "win")` (set
  immediately on return, no separate `check_battle_result` row needed) plus
  `jump_if_false`/`label` to skip the `set_flag` row on a loss or flee.
  **GHOST COLLISION is back and actually wired this time**: `spawnNpc` only
  ever returned a runtime id string, never the entity table, so this build
  looks the live NPC back up via `mod.world:npc()` to reach its underlying
  `.npc.passable` field (confirmed from `Collision.occupied()`'s source: an
  entity only blocks movement when `not e.passable`). GHOST SIGHT and TALK TO
  ENGAGE as separate opt-in modes are gone — sight is now unconditional,
  interact is now exclusively the post-defeat trigger.
- **0.6.1** — TALK TO ENGAGE became the default option. Fixed GHOST SIGHT's
  queued script missing the before/after-text rows that the facing-triggered
  path already had.
- **0.6.0** — Removed GHOST COLLISION, USE RIVAL SPRITE, GHOST WANDERS, GHOST
  CHASES per request, down to GHOST SIGHT and TALK TO ENGAGE. Added
  sender-authored before/after-battle dialogue.
- **0.5.0** — GHOST SIGHT rebuilt around the engine's own `move_npc_to`
  (BFS-pathing) + `start_battle` bundled into ONE queued script. Both verbs
  yield the script runner, and `queueScript` refuses a second script while
  one's running — that's the actual mechanism vanilla trainer/cutscene
  sequences use to freeze the player, so bundling the whole approach+battle
  sequence gets the freeze for free instead of needing to be reimplemented.
- **0.4.x** — Added the "!" + `Trainer_Appeared` sting flourish, then GHOST
  SIGHT as a mechanic distinct from the old GHOST CHASES (which re-aimed at
  the player's live position every tick, reading as active stalking rather
  than a one-time "spotted you").
- **0.3.x** — Fixed ghost facing (orientation is the `range` field, not a
  `facing` field), exact movesets (`BattleState.newTrainer` honors a party
  slot's `moves` list), and a crash from mixing this engine's two opposite
  direction-casing conventions (uppercase for static spawn orientation,
  lowercase for live movement/collision).
- **0.2.x** — Fixed self-exclusion: identity needed to include the save
  *slot*, not just trainer name+id, since two different save files can share
  a trainer id in this engine.
