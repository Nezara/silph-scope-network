-- silphscope_network -- send your current character to a shared file so it
-- can be battled as an enemy trainer in your OTHER saves.
--
-- Persistence, capture (Start-menu "SEND GHOST"), and the shared-file model
-- mirror vrm_pokemon_bank. Every ghost is a GHOST SIGHT trainer by default:
-- stands still, spots you crossing its line of sight, walks up, forces a
-- battle (with optional before/after dialogue the sending player wrote).
-- Once beaten (per receiving save, via the engine's Flags module), it stops
-- hunting and becomes an interact-only NPC: pressing the interact button
-- while facing it just replays its after-battle line, unless
-- REPEATABLE GHOST BATTLES is on, in which case it fights you again in full.
-- Overworld spawning + battle wiring use mod.world plus game.data.trainers
-- injection and the engine's own script verbs (start_battle, move_npc_to,
-- emote, show_text, set_flag/jump_if_false for win-detection).
--
-- ONLINE MODE (on by default): additionally uploads a sent ghost to a small
-- server and downloads other players' ghosts near the current map, via the
-- engine's async GET-only Fetch module (src/net/Fetch.lua) and JSON codec
-- (src/link/Json.lua) -- no POST exists anywhere in this engine's
-- networking, so "upload" is a GET with a base64-encoded payload. OFFLINE
-- MODE (option, default off) opts a save out entirely, back to the original
-- local-shared-file-only behavior. See README.md for the server side and
-- full writeup.
--
-- See README.md for what's confirmed working live vs. still first-cut.
-- Search the debug log (silphscope_network/debug.log) for "[silphscope_network]".

local MOD_ID          = "silphscope_network"
local STORAGE_DIR     = "silphscope_network"
local STORAGE_FILE    = STORAGE_DIR .. "/ghosts.lua"
local STORAGE_BACKUP  = STORAGE_FILE .. ".bak"
local STORAGE_TMP     = STORAGE_FILE .. ".tmp"
local STORAGE_VERSION = 1

-- Keys/prefixes for the runtime objects we create. Kept namespaced so nothing
-- collides with vanilla data.
local TRAINER_PREFIX  = "OPP_SSN_"     -- injected game.data.trainers[...] key
local NPC_NAME_PREFIX = "SSN_NPC_"

-- The player's own likeness (default, used when no GHOST SPRITE option is
-- toggled on). trainer_card/red.png is RED's front art -- the closest thing
-- to "the player as an opponent".
local PLAYER_PIC    = "assets/generated/trainer_card/red.png"
local PLAYER_SPRITE = "SPRITE_RED"        -- overworld sprite for the ghost NPC

-- Selectable ghost sprites, picked via the GHOST SPRITE mod option (a
-- type="choice" dropdown -- see mod.options:define below); PLAYER_PIC/
-- PLAYER_SPRITE above are the fallback ("RED (DEFAULT)" is itself the first
-- choice).
--
-- COMPLETE as of v0.11.0: all 45 trainer battle portraits this game ships
-- (assets/generated/battle/trainers/*.png) -- every regular class, all 8 gym
-- leaders, the Elite Four, all three rival stages and Prof. Oak.
--
-- Each overworld<->battle-art pairing is GROUND TRUTH extracted from the
-- game's own map data, not inferred from name similarity: every object in
-- red/data/generated/maps.lua that carries BOTH a `sprite` and a
-- `trainerClass` was tallied, giving the sprite the real game actually uses
-- to represent each class in the overworld, then joined to that class's own
-- `pic` field in red/data/generated/trainers.lua. That mattered -- two
-- earlier name-based guesses were flat WRONG: OPP_BIRD_KEEPER walks around
-- as SPRITE_COOLTRAINER_M (15/15 placements), NOT "SPRITE_BIRD" (which is a
-- bird POKEMON, not a trainer), and OPP_LASS is SPRITE_COOLTRAINER_F
-- (18/18), NOT SPRITE_GIRL (that one is Sabrina). Both are fixed here.
--
-- Consequences of using real data, both intentional:
--   * MANY classes share one overworld sprite (Gen 1 has ~45 portraits but
--     only ~28 humanoid walker sprites) -- e.g. SPRITE_SUPER_NERD covers
--     Super Nerd, Pokemaniac, Burglar, Engineer, Rocker AND Brock. So the
--     sprite alone can no longer identify a look; see SPRITE_PAIR_OK below,
--     which is why validation moved to matching the (sprite, pic) PAIR.
--   * Where the data showed a class split across two sprites (Beauty is 7x
--     SPRITE_BEAUTY / 7x SPRITE_SWIMMER, Cue Ball 8x BIKER / 1x SWIMMER),
--     the most-used one wins -- the minority placements are the game
--     reusing a class for a themed area (swimming Beauties on the water
--     routes), not a different look for the class itself.
--
-- Every sprite listed here was checked to exist in sprites.lua AND have
-- `walker = true` -- a non-walker (3-frame) sprite would look broken during
-- GHOST SIGHT's move_npc_to walk-up. `gender` ("M"/"F") is shown in the
-- label so the dropdown reads as a gendered list.
local PIC_DIR = "assets/generated/battle/trainers/"
local GHOST_SPRITES = {
  -- ---- Trainer classes, male --------------------------------------------
  { key = "sprite_bugcatcher",   gender = "M", label = "BUG CATCHER (M)",
    sprite = "SPRITE_YOUNGSTER",     pic = PIC_DIR .. "bugcatcher.png" },
  { key = "sprite_youngster",    gender = "M", label = "YOUNGSTER (M)",
    sprite = "SPRITE_YOUNGSTER",     pic = PIC_DIR .. "youngster.png" },
  { key = "sprite_jrtrainerm",   gender = "M", label = "JR.TRAINER (M)",
    sprite = "SPRITE_COOLTRAINER_M", pic = PIC_DIR .. "jr.trainerm.png" },
  { key = "sprite_cooltrainerm", gender = "M", label = "COOLTRAINER (M)",
    sprite = "SPRITE_COOLTRAINER_M", pic = PIC_DIR .. "cooltrainerm.png" },
  { key = "sprite_birdkeeper",   gender = "M", label = "BIRD KEEPER (M)",
    sprite = "SPRITE_COOLTRAINER_M", pic = PIC_DIR .. "birdkeeper.png" },
  { key = "sprite_hiker",        gender = "M", label = "HIKER (M)",
    sprite = "SPRITE_HIKER",         pic = PIC_DIR .. "hiker.png" },
  { key = "sprite_blackbelt",    gender = "M", label = "BLACKBELT (M)",
    sprite = "SPRITE_HIKER",         pic = PIC_DIR .. "blackbelt.png" },
  { key = "sprite_biker",        gender = "M", label = "BIKER (M)",
    sprite = "SPRITE_BIKER",         pic = PIC_DIR .. "biker.png" },
  { key = "sprite_cueball",      gender = "M", label = "CUE BALL (M)",
    sprite = "SPRITE_BIKER",         pic = PIC_DIR .. "cueball.png" },
  { key = "sprite_supernerd",    gender = "M", label = "SUPER NERD (M)",
    sprite = "SPRITE_SUPER_NERD",    pic = PIC_DIR .. "supernerd.png" },
  { key = "sprite_pokemaniac",   gender = "M", label = "POKEMANIAC (M)",
    sprite = "SPRITE_SUPER_NERD",    pic = PIC_DIR .. "pokemaniac.png" },
  { key = "sprite_burglar",      gender = "M", label = "BURGLAR (M)",
    sprite = "SPRITE_SUPER_NERD",    pic = PIC_DIR .. "burglar.png" },
  { key = "sprite_engineer",     gender = "M", label = "ENGINEER (M)",
    sprite = "SPRITE_SUPER_NERD",    pic = PIC_DIR .. "engineer.png" },
  { key = "sprite_rocker",       gender = "M", label = "ROCKER (M)",
    sprite = "SPRITE_SUPER_NERD",    pic = PIC_DIR .. "rocker.png" },
  { key = "sprite_juggler",      gender = "M", label = "JUGGLER (M)",
    sprite = "SPRITE_ROCKER",        pic = PIC_DIR .. "juggler.png" },
  { key = "sprite_tamer",        gender = "M", label = "TAMER (M)",
    sprite = "SPRITE_ROCKER",        pic = PIC_DIR .. "tamer.png" },
  { key = "sprite_psychic",      gender = "M", label = "PSYCHIC (M)",
    sprite = "SPRITE_YOUNGSTER",     pic = PIC_DIR .. "psychic.png" },
  { key = "sprite_fisherman",    gender = "M", label = "FISHERMAN (M)",
    sprite = "SPRITE_FISHER",        pic = PIC_DIR .. "fisher.png" },
  { key = "sprite_swimmer",      gender = "M", label = "SWIMMER (M)",
    sprite = "SPRITE_SWIMMER",       pic = PIC_DIR .. "swimmer.png" },
  { key = "sprite_sailor",       gender = "M", label = "SAILOR (M)",
    sprite = "SPRITE_SAILOR",        pic = PIC_DIR .. "sailor.png" },
  { key = "sprite_gambler",      gender = "M", label = "GAMBLER (M)",
    sprite = "SPRITE_GAMBLER",       pic = PIC_DIR .. "gambler.png" },
  { key = "sprite_gentleman",    gender = "M", label = "GENTLEMAN (M)",
    sprite = "SPRITE_GENTLEMAN",     pic = PIC_DIR .. "gentleman.png" },
  { key = "sprite_scientist",    gender = "M", label = "SCIENTIST (M)",
    sprite = "SPRITE_SCIENTIST",     pic = PIC_DIR .. "scientist.png" },
  { key = "sprite_rocket",       gender = "M", label = "ROCKET GRUNT (M)",
    sprite = "SPRITE_ROCKET",        pic = PIC_DIR .. "rocket.png" },
  -- ---- Trainer classes, female ------------------------------------------
  { key = "sprite_lass",         gender = "F", label = "LASS (F)",
    sprite = "SPRITE_COOLTRAINER_F", pic = PIC_DIR .. "lass.png" },
  { key = "sprite_jrtrainerf",   gender = "F", label = "JR.TRAINER (F)",
    sprite = "SPRITE_COOLTRAINER_F", pic = PIC_DIR .. "jr.trainerf.png" },
  { key = "sprite_cooltrainerf", gender = "F", label = "COOLTRAINER (F)",
    sprite = "SPRITE_COOLTRAINER_F", pic = PIC_DIR .. "cooltrainerf.png" },
  { key = "sprite_beauty",       gender = "F", label = "BEAUTY (F)",
    sprite = "SPRITE_BEAUTY",        pic = PIC_DIR .. "beauty.png" },
  { key = "sprite_channeler",    gender = "F", label = "CHANNELER (F)",
    sprite = "SPRITE_CHANNELER",     pic = PIC_DIR .. "channeler.png" },
  -- ---- Gym leaders (badge order) ----------------------------------------
  { key = "sprite_brock",        gender = "M", label = "BROCK (M)",
    sprite = "SPRITE_SUPER_NERD",    pic = PIC_DIR .. "brock.png" },
  { key = "sprite_misty",        gender = "F", label = "MISTY (F)",
    sprite = "SPRITE_BRUNETTE_GIRL", pic = PIC_DIR .. "misty.png" },
  { key = "sprite_ltsurge",      gender = "M", label = "LT. SURGE (M)",
    sprite = "SPRITE_ROCKER",        pic = PIC_DIR .. "lt.surge.png" },
  { key = "sprite_erika",        gender = "F", label = "ERIKA (F)",
    sprite = "SPRITE_SILPH_WORKER_F", pic = PIC_DIR .. "erika.png" },
  { key = "sprite_koga",         gender = "M", label = "KOGA (M)",
    sprite = "SPRITE_KOGA",          pic = PIC_DIR .. "koga.png" },
  { key = "sprite_sabrina",      gender = "F", label = "SABRINA (F)",
    sprite = "SPRITE_GIRL",          pic = PIC_DIR .. "sabrina.png" },
  { key = "sprite_blaine",       gender = "M", label = "BLAINE (M)",
    sprite = "SPRITE_MIDDLE_AGED_MAN", pic = PIC_DIR .. "blaine.png" },
  { key = "sprite_giovanni",     gender = "M", label = "GIOVANNI (M)",
    sprite = "SPRITE_GIOVANNI",      pic = PIC_DIR .. "giovanni.png" },
  -- ---- Elite Four -------------------------------------------------------
  { key = "sprite_lorelei",      gender = "F", label = "LORELEI (F)",
    sprite = "SPRITE_LORELEI",       pic = PIC_DIR .. "lorelei.png" },
  { key = "sprite_bruno",        gender = "M", label = "BRUNO (M)",
    sprite = "SPRITE_BRUNO",         pic = PIC_DIR .. "bruno.png" },
  { key = "sprite_agatha",       gender = "F", label = "AGATHA (F)",
    sprite = "SPRITE_AGATHA",        pic = PIC_DIR .. "agatha.png" },
  { key = "sprite_lance",        gender = "M", label = "LANCE (M)",
    sprite = "SPRITE_LANCE",         pic = PIC_DIR .. "lance.png" },
  -- ---- Rival (all three battle arts) + Oak -------------------------------
  { key = "sprite_rival1",       gender = "M", label = "RIVAL - EARLY (M)",
    sprite = "SPRITE_BLUE",          pic = PIC_DIR .. "rival1.png" },
  { key = "sprite_rival2",       gender = "M", label = "RIVAL - MID (M)",
    sprite = "SPRITE_BLUE",          pic = PIC_DIR .. "rival2.png" },
  { key = "sprite_rival3",       gender = "M", label = "RIVAL - CHAMP (M)",
    sprite = "SPRITE_BLUE",          pic = PIC_DIR .. "rival3.png" },
  { key = "sprite_profoak",      gender = "M", label = "PROF. OAK (M)",
    sprite = "SPRITE_OAK",           pic = PIC_DIR .. "prof.oak.png" },
}

-- Valid (sprite, pic) COMBINATIONS, used to validate a DOWNLOADED ghost's
-- look. A downloaded ghost's sprite/pic arrive as arbitrary strings from
-- another player's client and are never trusted: a pair is only honoured if
-- it exactly matches one this table itself defines. Without that check, a
-- malformed/hostile value reaches spawnNpc as an unknown sprite (ghost
-- silently fails to spawn) or the battle renderer as an arbitrary asset path
-- (which crashes to lua-error.log, a file a mod cannot even read). Anything
-- unrecognised falls back to the Red default.
--
-- This replaced a plain sprite -> pic lookup in v0.11.0, and HAD to: with
-- the full 45-portrait roster many classes legitimately share one overworld
-- sprite (SPRITE_SUPER_NERD alone backs six of them), so keying on the
-- sprite name would collapse them and hand every Super Nerd-sprited ghost
-- whichever pic happened to be defined last. Matching the pair keeps the
-- exact look the sender chose while giving the same safety guarantee, since
-- both halves still have to be strings we ship ourselves.
local SPRITE_PAIR_OK = {}
for _, s in ipairs(GHOST_SPRITES) do SPRITE_PAIR_OK[s.sprite .. "|" .. s.pic] = true end

-- =========================================================================
-- GEN 2 (Pokemon Gold) DETECTION -- GameVersion is a process-global set at
-- boot from the launcher's column choice, before ANY mod loads ("zero
-- requires, loads during love.conf" per its own header) -- so this is safe
-- to read right here at module load, no game object needed. generation()
-- returns 1 (Red/Blue/Yellow) or 2 (Gold); everything below that differs
-- between them branches on IS_GEN2, with the Gen 1 branch always matching
-- this mod's existing, already-shipped behavior unchanged.
--
-- Design + live validation: see the silphscope-gen2-scope memory and the
-- throwaway ssn_gen2_spike mod (2026-08-13) this port is built from. The
-- engine's OWN native sight-trainer mechanic (a map object carrying a
-- `trainer` struct + `sight` range) drives GHOST SIGHT for free on Gold --
-- World:checkTrainerBattle walks live npcs and runs the cart's own
-- emote/approach/dialogue/battle/after-text script, so there is no
-- Gen 1-style hand-rolled move_npc_to/queueScript sequence on this side.
-- =========================================================================
local GameVersion
do
  local ok, gv = pcall(require, "src.core.GameVersion")
  if ok then GameVersion = gv end
end
local GENERATION = 1
do
  local ok, gen = pcall(function() return GameVersion and GameVersion.generation() end)
  if ok and gen then GENERATION = gen end
end
local IS_GEN2 = GENERATION == 2
local RECORD_GAME = IS_GEN2 and "gold" or "red"  -- travels as the server's `game` field

-- CONFIRMED LIVE (2026-08-14, real player report + debug.log): on a Gen 2
-- boot, a MOD's own `game.data.maps` is nil -- Gen2Compat.lua's own
-- DATA_RENAMES table (sprites/maps/tilesets/text/encounters/palettes/icons/
-- battle_anims all point at a gen2-prefixed field, e.g. maps -> gen2Maps)
-- describes an INTERNAL engine proxy, not something that reaches a mod's
-- own `game.data` reference as handed to it -- a mod has to do that rename
-- itself. `trainers` is NOT in that rename list, so `game.data.trainers`
-- (used by gen2InjectGhost/gen2ClassByIndexTable) is unaffected. Only
-- `maps` and `encounters` are actually read anywhere in this mod's Gen 2
-- code today; add more pairs here if a future feature needs
-- sprites/tilesets/text/palettes/icons/battle_anims too.
local GEN2_DATA_RENAMES = { maps = "gen2Maps", encounters = "gen2Encounters" }
local function dataTable(game, key)
  local data = game and game.data
  if not data then return nil end
  if IS_GEN2 and GEN2_DATA_RENAMES[key] then
    return data[GEN2_DATA_RENAMES[key]] or data[key]
  end
  return data[key]
end

-- Gold has NO `pic` field on trainer records -- portraits resolve from
-- menu_gfx.trainerPics[classId] by CLASS CONSTANT instead, so a Gen 2
-- "look" is (overworld sprite, class id) rather than (sprite, art path).
-- Reuses rec.pic to carry the class id (never both generations at once, so
-- no field-name collision) -- see selectedSprite/spawnOneGen2Ghost below.
-- All 4 verified `walker = true` against gold/data/generated/sprites.lua;
-- classes verified to exist against gold/data/generated/trainers.lua.
local GEN2_PLAYER_SPRITE = "SPRITE_CHRIS"
local GEN2_PLAYER_CLASS  = "RED"  -- Gold has no player portrait; Red's is the lookalike, same logic as PLAYER_PIC above
local GEN2_GHOST_SPRITES = {
  { key = "sprite_beauty", gender = "F", label = "BEAUTY (F)",       sprite = "SPRITE_BEAUTY",      classId = "BEAUTY" },
  { key = "sprite_rocket", gender = "M", label = "ROCKET GRUNT (M)", sprite = "SPRITE_ROCKET",      classId = "GRUNTM" },
  { key = "sprite_kimono", gender = "F", label = "KIMONO GIRL (F)",  sprite = "SPRITE_KIMONO_GIRL", classId = "KIMONO_GIRL" },
}
local GEN2_SPRITE_PAIR_OK = {}
for _, s in ipairs(GEN2_GHOST_SPRITES) do GEN2_SPRITE_PAIR_OK[s.sprite .. "|" .. s.classId] = true end

-- Optional before/after-battle dialogue, authored by the SENDING player at
-- SEND GHOST time (see sendSelf). Comparable to a normal NPC's line length --
-- vanilla trainer battle lines in this engine's own text data commonly run
-- 30-60 characters (see red/data/generated/text.lua) -- so this caps a single
-- line rather than a full multi-page speech.
local DIALOGUE_MAX_LEN = 48

-- =========================================================================
-- ONLINE MODE: upload/download ghosts via a small server (Cloudflare Worker
-- + KV, see the mod's README for the full writeup) instead of/alongside the
-- local shared file. The engine's own networking (src/net/Fetch.lua) is
-- GET-only all the way down -- confirmed no POST/body support anywhere in
-- the stack -- so "upload" is a GET with the payload base64-encoded into a
-- query param, not a normal REST call. Fetch.get is async (returns a job id,
-- poll Fetch.poll(id) for the result) and never blocks the game.
--
-- PLAIN HTTP, deliberately (v0.8.2): every HTTPS request from this engine's
-- Fetch (which shells out to curl on desktop, confirmed from source) failed
-- live with "schannel: CRYPT_E_NO_REVOCATION_CHECK" -- a Windows certificate
-- revocation-check failure, confirmed to be a machine/network-level curl
-- problem (the exact same error independently hit this session's own tooling
-- against an unrelated site), not anything wrong with the server or this
-- code. Plain HTTP has no TLS handshake at all, so there's no revocation
-- check to fail -- confirmed the server answers cleanly over HTTP with no
-- redirect. There's no sensitive data in this payload (a ghost's map
-- position and party -- the whole point is sharing it with other players),
-- so the lost transport encryption is an acceptable tradeoff for a feature
-- that doesn't work at all otherwise on an affected machine. If this ever
-- needs to move back to HTTPS (e.g. a stricter host that forces it), the fix
-- is on the PLAYER's machine, not here: Control Panel -> Internet Options ->
-- Advanced -> Security -> uncheck "Check for server certificate revocation".
-- =========================================================================
local ONLINE_SERVER_URL = "http://silph-scope-network.silphscopenetwork.workers.dev"
local ONLINE_UPLOAD_MAX_BYTES = 6000  -- stay under the server's own 8000-byte cap after overhead
local ONLINE_DEFAULT_COUNT = 3        -- used if the numeric option type isn't supported (see below)

-- =========================================================================
-- Where a ghost is allowed to be SENT from: outdoor routes (NOT town/city
-- exteriors -- those were allowed in 0.7.1 for easy testing, deliberately
-- excluded since) and "dungeon" areas (caves, Pokémon Tower, Viridian
-- Forest/Safari Zone, Power Plant) plus the three explicitly-requested
-- exceptions (Pokémon Mansion, Silph Co, SS Anne) -- NOT regular building
-- interiors (houses, marts, Pokémon Centers, gyms, labs, gates, tunnels).
--
-- Built from the REAL per-map id<->tileset pairing in red/data/generated/
-- maps.lua, not the tileset NAME alone -- tileset names are misleading here:
-- the tileset literally called "MANSION" is the Celadon side-quest mansion,
-- NOT Pokémon Mansion (which is tileset "FACILITY", shared with Silph Co,
-- Rocket Hideout, Power Plant, AND the Cinnabar/Saffron gyms -- so gyms had
-- to be excluded by individual map id, not by tileset, or Cinnabar/Saffron
-- gyms would have been wrongly allowed alongside Pokémon Mansion). Likewise
-- "SHIP" tileset includes two ordinary houses (CERULEAN_BADGE_HOUSE,
-- FUCHSIA_GOOD_ROD_HOUSE) alongside the real SS Anne rooms.
--
-- Judgment calls beyond the user's three named exceptions, since they fit
-- the same "dungeon-like, not a house, has trainers or wild spawns" pattern:
-- ROCKET_HIDEOUT (trainers, multi-floor secret base, same FACILITY tileset
-- as Silph Co) and POWER_PLANT (has wild Electric-type encounters, the
-- literal "pokemon can spawn" criterion) are both included. Elite Four rooms
-- (BRUNOS_ROOM/LORELEIS_ROOM/AGATHAS_ROOM/CHAMPIONS_ROOM/LANCES_ROOM),
-- HALL_OF_FAME, and the Fighting Dojo are treated like gyms (single fixed
-- battle room, no wild spawns) and excluded.
--
-- Unrecognized map ids (a different game version's maps, or anything this
-- list missed) are BLOCKED by default -- this is a safety restriction, so
-- the safe default on doubt is to deny, not allow.
-- =========================================================================
local SEND_ALLOWED_MAPS = {}
do
  local function allow(list)
    for _, id in ipairs(list) do SEND_ALLOWED_MAPS[id] = true end
  end
  -- Outdoor overworld: routes only -- town/city exteriors were allowed in
  -- 0.7.1 for easy testing, now deliberately excluded (2026-08-09). Indigo
  -- Plateau grounds and the Vermilion dock stay allowed: neither is a town,
  -- both are open outdoor areas in the same spirit as a route.
  allow({
    "ROUTE_1", "ROUTE_2", "ROUTE_3", "ROUTE_4", "ROUTE_5", "ROUTE_6",
    "ROUTE_7", "ROUTE_8", "ROUTE_9", "ROUTE_10", "ROUTE_11", "ROUTE_12",
    "ROUTE_13", "ROUTE_14", "ROUTE_15", "ROUTE_16", "ROUTE_17", "ROUTE_18",
    "ROUTE_19", "ROUTE_20", "ROUTE_21", "ROUTE_22", "ROUTE_23", "ROUTE_24",
    "ROUTE_25",
    "INDIGO_PLATEAU", "VERMILION_DOCK",
  })
  -- Caves (tileset CAVERN).
  allow({
    "MT_MOON_1F", "MT_MOON_B1F", "MT_MOON_B2F",
    "ROCK_TUNNEL_1F", "ROCK_TUNNEL_B1F",
    "SEAFOAM_ISLANDS_1F", "SEAFOAM_ISLANDS_B1F", "SEAFOAM_ISLANDS_B2F",
    "SEAFOAM_ISLANDS_B3F", "SEAFOAM_ISLANDS_B4F",
    "VICTORY_ROAD_1F", "VICTORY_ROAD_2F", "VICTORY_ROAD_3F",
    "DIGLETTS_CAVE", "DIGLETTS_CAVE_ROUTE_2", "DIGLETTS_CAVE_ROUTE_11",
    "CERULEAN_CAVE_1F", "CERULEAN_CAVE_2F", "CERULEAN_CAVE_B1F",
  })
  -- Forest/Safari Zone (tileset FOREST) and Pokémon Tower (tileset CEMETERY,
  -- tower floors only -- not AGATHAS_ROOM, which shares the tileset but is
  -- an Elite Four fixed-battle room, excluded like the other E4 rooms).
  allow({
    "VIRIDIAN_FOREST",
    "SAFARI_ZONE_CENTER", "SAFARI_ZONE_EAST", "SAFARI_ZONE_NORTH", "SAFARI_ZONE_WEST",
    "POKEMON_TOWER_1F", "POKEMON_TOWER_2F", "POKEMON_TOWER_3F", "POKEMON_TOWER_4F",
    "POKEMON_TOWER_5F", "POKEMON_TOWER_6F", "POKEMON_TOWER_7F",
  })
  -- Explicit exceptions (Mansion, Silph Co, SS Anne) plus the two judgment
  -- calls noted above (Rocket Hideout, Power Plant) -- see comment block.
  allow({
    "POKEMON_MANSION_1F", "POKEMON_MANSION_2F", "POKEMON_MANSION_3F", "POKEMON_MANSION_B1F",
    "SILPH_CO_1F", "SILPH_CO_2F", "SILPH_CO_3F", "SILPH_CO_4F", "SILPH_CO_5F",
    "SILPH_CO_6F", "SILPH_CO_7F", "SILPH_CO_8F", "SILPH_CO_9F", "SILPH_CO_10F",
    "SILPH_CO_11F", "SILPH_CO_ELEVATOR",
    "SS_ANNE_1F", "SS_ANNE_1F_ROOMS", "SS_ANNE_2F", "SS_ANNE_2F_ROOMS",
    "SS_ANNE_3F", "SS_ANNE_B1F", "SS_ANNE_B1F_ROOMS", "SS_ANNE_BOW",
    "SS_ANNE_CAPTAINS_ROOM", "SS_ANNE_KITCHEN",
    "ROCKET_HIDEOUT_B1F", "ROCKET_HIDEOUT_B2F", "ROCKET_HIDEOUT_B3F",
    "ROCKET_HIDEOUT_B4F", "ROCKET_HIDEOUT_ELEVATOR",
    "POWER_PLANT",
  })
end

-- =========================================================================
-- Where a FRIENDLY ghost (no battle -- see GEN_TYPE below) is allowed to be
-- sent from: everywhere a PokeTrainer ghost can (SEND_ALLOWED_MAPS above)
-- PLUS every town/city exterior, since a friendly greeter never ambushes
-- anyone and towns are arguably where the concept fits best. Still not
-- regular building interiors (houses, marts, Pokemon Centers, gyms) --
-- maintainer's explicit call: "allow towns and cities, but not indoors."
--
-- All 10 town/city ids below verified against red/data/generated/maps.lua
-- directly (not guessed from name) -- every one carries tileset
-- "OVERWORLD", the same outdoor tileset the allowed routes already use.
-- INDIGO_PLATEAU is deliberately not repeated here -- it's already in
-- SEND_ALLOWED_MAPS's own outdoor-routes block.
-- =========================================================================
local FRIENDLY_TOWN_MAPS = {
  "PALLET_TOWN", "VIRIDIAN_CITY", "PEWTER_CITY", "CERULEAN_CITY",
  "LAVENDER_TOWN", "VERMILION_CITY", "CELADON_CITY", "FUCHSIA_CITY",
  "SAFFRON_CITY", "CINNABAR_ISLAND",
}
local FRIENDLY_ALLOWED_MAPS = {}
for id in pairs(SEND_ALLOWED_MAPS) do FRIENDLY_ALLOWED_MAPS[id] = true end
for _, id in ipairs(FRIENDLY_TOWN_MAPS) do FRIENDLY_ALLOWED_MAPS[id] = true end

return function(mod)
  -- IMPORTANT (found live, v0.8.0 test): mod.options:define() REPLACES the
  -- whole option set on each call, it does not add to what a previous call
  -- already registered -- calling it twice (once for the toggles, once for
  -- ONLINE GHOST COUNT, to isolate risk from the then-unconfirmed numeric
  -- type) silently wiped GHOST COLLISION/REPEATABLE GHOST BATTLES/
  -- ONLINE MODE down to just the second call's one entry. Fixed: everything
  -- in ONE call. Upside of that failed experiment: it proved `type =
  -- "number"` (with min/max/step) DOES work in this engine -- ONLINE GHOST
  -- COUNT rendered and worked fine, it just took the others down with it as
  -- a side effect of the two-call split, not because the type was rejected.
  -- GHOST SPRITE and GHOST LEVELING used to live here as mod.options
  -- type="choice" dropdowns -- moved (2026-08-14, maintainer's call) into
  -- the new SILPH SCOPE NET hub menu instead (see openHub/openSpritePicker/
  -- openConnectionModePicker below), so their state moves with them: out of
  -- mod.options and into this mod's own storage.spriteKey/.connectionMode
  -- (loadStorage/markDirty, same file ghosts.lua already uses). Old
  -- mod.options values for those two keys are simply orphaned now, same
  -- precedent as the online_mode -> offline_mode rename. What's LEFT here
  -- are the four settings that stay on the standard options menu, in the
  -- maintainer's requested order (collision, repeatable, online count,
  -- offline mode last).
  local ONLINE_COUNT_SUPPORTED = pcall(function()
    local rows = {
      -- ON (default) = ghost is a normal solid NPC (blocks movement, like
      -- any trainer). OFF = non-solid -- can't wall you into a softlock if
      -- it lands somewhere awkward. Wired via the live NPC handle's
      -- underlying entity table: src/world/Collision.lua's
      -- Collision.occupied() only treats an entity as blocking when `not
      -- e.passable` -- so OFF sets `.passable = true` on the spawned ghost
      -- right after spawning it (confirmed field name from source;
      -- spawnNpc itself only returns a runtime id STRING, not the entity
      -- table, so the live handle from mod.world:npc() is needed to reach
      -- it).
      { key = "ghost_collision", label = "GHOST COLLISION", type = "toggle", default = true },
      -- OFF (default) = once a ghost is defeated, interacting with it (face
      -- + press the interact button) just replays its after-battle line --
      -- no more fight. ON = interacting with a defeated ghost starts a full
      -- rematch again (before-line, battle, after-line), same as the
      -- original encounter. Undefeated ghosts are unaffected either way --
      -- they're always fought via GHOST SIGHT, and this option only changes
      -- what happens AFTER a win.
      { key = "ghost_repeatable", label = "REPEATABLE GHOST BATTLES", type = "toggle", default = false },
      -- How many online ghosts to request per map, 1-5. type="number" IS
      -- confirmed working in this engine (min/max/step).
      { key = "online_ghost_count", label = "ONLINE GHOST COUNT", type = "number",
        min = 1, max = 5, step = 1, default = ONLINE_DEFAULT_COUNT },
      -- OFF (default) = ONLINE MODE is active: your sent ghost also
      -- uploads to a small server, and other players' ghosts near your
      -- current map get downloaded too. ON = opt this save out entirely,
      -- back to local shared-file ghosts only (no uploads, no downloads).
      { key = "offline_mode", label = "OFFLINE MODE", type = "toggle", default = false },
    }
    mod.options:define(rows)
  end)
  if not ONLINE_COUNT_SUPPORTED then
    -- Extremely defensive fallback in case the WHOLE batch ever fails on some
    -- other build (e.g. a future engine version that's stricter about
    -- unknown fields) -- re-register just the three toggles, which have been
    -- reliably confirmed working across this entire project, rather than the
    -- mod ending up with NO options at all.
    pcall(function()
      mod.options:define({
        { key = "ghost_collision", label = "GHOST COLLISION", type = "toggle", default = true },
        { key = "ghost_repeatable", label = "REPEATABLE GHOST BATTLES", type = "toggle", default = false },
        { key = "offline_mode", label = "OFFLINE MODE", type = "toggle", default = false },
      })
    end)
  end

  local SaveData       = require("src.core.SaveData")
  local SaveSerializer = require("src.core.SaveSerializer")
  local TextBox        = require("src.render.TextBox")
  local ChoiceBox      = require("src.ui.ChoiceBox")
  local NamingScreen   = require("src.ui.NamingScreen")
  local ListMenu       = require("src.ui.ListMenu")
  local QuantityBox    = require("src.ui.QuantityBox")
  local Flags          = require("src.script.Flags")
  -- src/inventory/Bag.lua -- confirmed generation-agnostic (Bag.add/remove/
  -- order/capacity all key off the item's own `.pocket` field when present,
  -- falling back to a single "ITEM" pocket when it's not, which is exactly
  -- Gen 1's shape). Used by the FRIENDLY ghost type's gift-item flow --
  -- Bag.add(save, id, qty, data) / Bag.remove(save, id, qty) / Bag.order(save).
  local Bag            = require("src.inventory.Bag")

  -- Online mode's two engine internals: Fetch (async GET, src/net/Fetch.lua)
  -- and Json (src/link/Json.lua, used by the game's own update-checker to
  -- parse a version-check server's response -- confirmed to have both
  -- .encode and .decode). Guarded: if either is missing/renamed in some
  -- build, online mode should just quietly do nothing rather than error.
  local Fetch, Json
  do
    local okF, f = pcall(require, "src.net.Fetch")
    if okF then Fetch = f end
    local okJ, j = pcall(require, "src.link.Json")
    if okJ then Json = j end
  end
  local ONLINE_AVAILABLE = Fetch ~= nil and Json ~= nil

  -- Real implementation is installed after the fs helpers exist (below). Until
  -- then this is a no-op so early log() calls can't error. log() captures it as
  -- an upvalue, so the later reassignment takes effect everywhere.
  local fileLog = function(_) end

  local function log(fmt, ...)
    local ok, s = pcall(string.format, "[silphscope_network] " .. fmt, ...)
    local line = ok and s or ("[silphscope_network] " .. tostring(fmt))
    mod.log:info("%s", line)
    fileLog(line)
  end

  -- Shallow one-line dump of a table's fields -- for learning the real shape of
  -- engine objects (the spawned NPC, game.save, etc.) from the log file.
  local function shallowDump(t, max)
    if type(t) ~= "table" then return tostring(t) end
    local parts, n = {}, 0
    for k, v in pairs(t) do
      n = n + 1
      if n > (max or 50) then parts[#parts + 1] = "..."; break end
      local tv = type(v)
      local vs = (tv == "string" or tv == "number" or tv == "boolean") and tostring(v) or tv
      parts[#parts + 1] = tostring(k) .. "=" .. vs
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end

  -- =====================================================================
  -- Persistence -- copied from vrm_pokemon_bank's main.lua (same file
  -- discipline: portable fs, backup -> tmp witness -> swap, flush on save).
  -- =====================================================================
  local function fs() return SaveData.portableFs() or love.filesystem end

  local function fileExists(name)
    local ok, info = pcall(function() return fs().getInfo(name) end)
    return ok and info ~= nil
  end
  local function tryRead(name)
    local ok, result = pcall(function() return fs().read(name) end)
    if ok and type(result) == "string" then return result end
    return nil
  end
  local function tryWrite(name, data)
    local ok, result = pcall(function() return fs().write(name, data) end)
    return ok and result ~= false
  end
  local function tryRemove(name)
    pcall(function() local f = fs(); if f.remove then f.remove(name) end end)
  end
  local function readStorageFile(name)
    if not fileExists(name) then return nil end
    local raw = tryRead(name); if not raw then return nil end
    local decoded = SaveSerializer.decode(raw)
    if type(decoded) ~= "table" then return nil end
    return decoded
  end

  local function freshStorage()
    return { version = STORAGE_VERSION, ghosts = {}, nextId = 1, passwords = {} }
  end

  local storage           -- in-memory cache, lazy-loaded
  local dirty = false

  local function normalize(s)
    s.ghosts = type(s.ghosts) == "table" and s.ghosts or {}
    s.nextId = math.max(1, math.floor(tonumber(s.nextId) or 1))
    -- passwords: added later than ghosts/nextId, so older storage files on
    -- disk simply won't have this key yet -- default it in rather than
    -- requiring every reader to guard against a missing table.
    s.passwords = type(s.passwords) == "table" and s.passwords or {}
    -- connectionMode/spriteKey: GHOST LEVELING and GHOST SPRITE moved here
    -- from mod.options (2026-08-14, the SILPH SCOPE NET hub menu rework) --
    -- global settings, same scope mod.options always gave them (one shared
    -- ghosts.lua across every save on the machine, not per-save).
    s.connectionMode = (s.connectionMode == "scale" or s.connectionMode == "off")
      and s.connectionMode or "filter"
    s.spriteKey = type(s.spriteKey) == "string" and s.spriteKey or ""
    s.ghostType = (s.ghostType == "friendly") and "friendly" or "trainer"
    return s
  end

  local function loadStorage()
    if storage then return storage end
    local out = readStorageFile(STORAGE_FILE)
      or readStorageFile(STORAGE_TMP)
      or readStorageFile(STORAGE_BACKUP)
      or freshStorage()
    storage = normalize(out)
    return storage
  end

  local function markDirty() dirty = true end

  -- GHOST LEVELING mode -- read fresh everywhere (not cached), same
  -- discipline mod.options reads always had, so a choice made in the hub
  -- menu is honored by the very next spawn/battle with no reload needed.
  -- Both generations' inject functions (injectTrainer, gen2InjectGhost) and
  -- filterCapForMap/levelCapForMap call this.
  local function ghostLevelMode()
    local v = loadStorage().connectionMode
    if v == "scale" or v == "off" then return v end
    return "filter"
  end
  local function setConnectionMode(mode)
    local s = loadStorage()
    s.connectionMode = mode
    markDirty()
  end

  -- Second return is a battle-art PATH on Gen 1, a trainer CLASS ID on Gen 2
  -- (see the GEN 2 DETECTION comment near the top of the file) -- always
  -- stored into rec.pic either way, since a save is only ever one
  -- generation and the two meanings never mix.
  local function selectedSprite()
    local key = loadStorage().spriteKey
    local list = IS_GEN2 and GEN2_GHOST_SPRITES or GHOST_SPRITES
    if type(key) == "string" and key ~= "" then
      for _, s in ipairs(list) do
        if s.key == key then
          return s.sprite, (IS_GEN2 and s.classId or s.pic)
        end
      end
    end
    if IS_GEN2 then return GEN2_PLAYER_SPRITE, GEN2_PLAYER_CLASS end
    return PLAYER_SPRITE, PLAYER_PIC
  end
  local function setSpriteKey(key)
    local s = loadStorage()
    s.spriteKey = key
    markDirty()
  end

  -- GHOST TYPE (2026-08-14 addition): which of the two send flows the next
  -- SEND GHOST uses. Same storage-backed, read-fresh pattern as
  -- connectionMode/spriteKey -- see their own comments.
  --   trainer (default) -- the original behavior, unchanged: a battle
  --     ghost with a captured party.
  --   friendly -- no battle at all. A plain NPC of the sender (dialogue
  --     only, no party captured) that can also hand a visiting save one
  --     optional item, once, subtracted from the sender's own bag at send
  --     time. See sendSelf/askLeaveItem/engageFriendlyGhost.
  local function ghostTypeMode()
    local v = loadStorage().ghostType
    return v == "friendly" and "friendly" or "trainer"
  end
  local function setGhostType(v)
    local s = loadStorage()
    s.ghostType = v
    markDirty()
  end
  local GHOST_TYPE_LABELS = { trainer = "TRAINER", friendly = "FRIEND" }
  local function ghostTypeLabel()
    return GHOST_TYPE_LABELS[ghostTypeMode()] or "TRAINER"
  end

  -- Which items a FRIENDLY ghost is allowed to leave: no key items, no HMs
  -- (progression-critical -- excluded per the maintainer's explicit call,
  -- inverted from an earlier draft that had TM/HM backwards). TMs ARE
  -- allowed -- they're tradable through other in-game means already, so
  -- there's nothing special being bypassed by gifting one.
  --
  -- HM ids use the SAME "HM_" prefix on BOTH generations (confirmed against
  -- both red/data/generated/items.lua and gold/data/generated/items.lua --
  -- e.g. HM_CUT, HM_SURF exist verbatim on both), so a plain prefix check
  -- is generation-agnostic and doesn't need a machine/pocket lookup at all.
  -- Key items differ by generation and DO need their own field: Gen 1 items
  -- carry a plain `keyItem = true` boolean; Gen 2 has no such field but
  -- instead sorts every item into a `.pocket` ("ITEM"/"BALL"/"KEY_ITEM"/
  -- "TM_HM"), so `pocket == "KEY_ITEM"` is the Gen 2 equivalent check.
  -- Checking both conditions unconditionally is safe on either generation:
  -- each field is simply absent/nil on the generation that doesn't use it.
  local function isGiftableItem(id, item)
    if type(id) ~= "string" or id:match("^HM_") then return false end
    if not item then return false end
    if item.keyItem == true then return false end
    if item.pocket == "KEY_ITEM" then return false end
    return true
  end

  -- Display labels for the hub menu's own rows (see hubItems below).
  --
  -- ListMenu draws a row's `label` at a fixed left position and its `right`
  -- right-aligned with no wrap (confirmed from src/ui/ListMenu.lua:draw) --
  -- combined, an 8px-glyph 160px-wide GB screen gives roughly 17 characters
  -- before they start overlapping. "CONNECTION MODE" (15) + "LEVEL/ZONE"
  -- (10) alone was 25 -- badly squished, which is what prompted this.
  -- fitRight truncates the live VALUE, not the row's own fixed label (the
  -- label is what tells you what the row even is), and is generic so any
  -- future summary row can reuse it rather than hand-picking a length.
  local HUB_ROW_BUDGET = 17
  local function fitRight(label, right)
    local room = HUB_ROW_BUDGET - #label - 1  -- -1 for a minimum one-space gap
    if room < 1 then return "" end
    if #right <= room then return right end
    return right:sub(1, room)
  end

  local CONNECTION_MODE_LABELS = { filter = "ZONE", scale = "SCALE", off = "OFF" }
  local function connectionModeLabel()
    return CONNECTION_MODE_LABELS[ghostLevelMode()] or "ZONE"
  end
  local function spriteLabel()
    local key = loadStorage().spriteKey
    local label
    if type(key) == "string" and key ~= "" then
      for _, s in ipairs(IS_GEN2 and GEN2_GHOST_SPRITES or GHOST_SPRITES) do
        if s.key == key then label = s.label; break end
      end
    end
    label = label or (IS_GEN2 and "CHRIS" or "RED")
    -- Strip the " (M)"/" (F)" gender suffix for the hub's own summary --
    -- the full label (gender included) still shows inside the sprite
    -- picker itself, which has a whole screen of width free; fitRight
    -- below is the final safety net for the handful of names still too
    -- long after this (e.g. "RIVAL - CHAMP").
    return (label:gsub("%s*%([MF]%)$", ""))
  end

  local function flushStorage()
    if not (dirty and storage) then return end
    pcall(function() fs().createDirectory(STORAGE_DIR) end)
    local ok, encoded = pcall(SaveSerializer.encode, storage)
    if not ok then
      mod.log:warn("[silphscope_network] could not encode storage: %s", tostring(encoded))
      return
    end
    if fileExists(STORAGE_FILE) then
      local prev = tryRead(STORAGE_FILE)
      if prev then tryWrite(STORAGE_BACKUP, prev) end
    end
    if not tryWrite(STORAGE_TMP, encoded) then
      mod.log:warn("[silphscope_network] could not stage %s", STORAGE_TMP); return
    end
    tryRemove(STORAGE_FILE)
    if not tryWrite(STORAGE_FILE, encoded) then
      mod.log:warn("[silphscope_network] could not write %s", STORAGE_FILE); return
    end
    tryRemove(STORAGE_TMP)
    dirty = false
    log("flushed %d ghost(s) to %s", #storage.ghosts, STORAGE_FILE)
  end

  -- ---------------------------------------------------------------------
  -- File logger -> silphscope_network/debug.log (next to ghosts.lua). mod.log
  -- output isn't visible in a normal run, so this is our window into the
  -- runtime checks. Written immediately (not on the save schedule) and
  -- size-capped so it can't grow without bound.
  -- ---------------------------------------------------------------------
  local LOG_FILE = STORAGE_DIR .. "/debug.log"
  fileLog = function(line)
    local f = fs()
    pcall(function() f.createDirectory(STORAGE_DIR) end)
    local stamp = (os.date and os.date("%Y-%m-%d %H:%M:%S")) or tostring((os.time and os.time()) or "")
    local entry = ("[%s] %s\n"):format(stamp, tostring(line))
    if type(f.append) == "function" then
      local ok = pcall(function() return f.append(LOG_FILE, entry) end)
      if ok then return end
    end
    local prev = tryRead(LOG_FILE) or ""
    if #prev > 200000 then prev = prev:sub(-100000) end
    tryWrite(LOG_FILE, prev .. entry)
  end
  fileLog(("==== silphscope_network session start (portableFs=%s, world=%s, online=%s, countOption=%s) ===="):format(
    tostring(SaveData.portableFs() ~= nil), tostring(mod.world ~= nil),
    tostring(ONLINE_AVAILABLE), tostring(ONLINE_COUNT_SUPPORTED)))

  -- Tie our write to the game's own save, same as the Bank (a reset-without-
  -- saving then reverts the deposit too -- no free duplication).
  mod.hooks:wrap("save.write", function(next_, game)
    local proceed = next_(game)
    if proceed ~= false then flushStorage() end
    return proceed
  end)

  -- =====================================================================
  -- Live game handle + small helpers
  -- =====================================================================
  local liveGame
  mod.events:on("game.ready", function(ev)
    liveGame = (ev and ev.game) or liveGame
  end)

  local function world() return mod.world end

  local function deepcopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do out[deepcopy(k, seen)] = deepcopy(val, seen) end
    return out
  end

  -- Stable per-save identity so a ghost never spawns back in the save it came
  -- from. Two things learned the hard way (v0.1.0/v0.2.0 logs):
  --   1. game.save.modData did NOT reliably persist across a real reload.
  --   2. Trainer name+id is NOT unique per SAVE SLOT -- slot1.lua and slot2.lua
  --      in this very install both have player.id=45799/name=WILL (this recomp
  --      doesn't re-roll a random id independently per slot the way the user's
  --      two test slots were created). Keying on trainer identity alone means
  --      two different save files silently share one identity.
  -- Fix: combine the SAVE SLOT (SaveData.activeSlot, the same "which file is
  -- this" the engine itself uses to load/save) with trainer identity. Same
  -- character reloaded in the same slot -> same origin (correctly excluded).
  -- Different slot, even with a colliding trainer id -> different origin
  -- (correctly shown) -- this is what actually matches "any save FILE".
  --
  -- FALLBACK when activeSlot fails (rewritten 0.10.7 -- the old one was a
  -- real bug, seen live on another player's client): it used to mint
  -- "rg-fallback-<os.time()>" and stash it in game.save.modData, which point
  -- 1 above already establishes does NOT reliably persist. A non-persisting
  -- store plus a TIMESTAMP seed means a brand-new identity every session,
  -- which is strictly worse than no fallback at all: every send creates an
  -- ADDITIONAL server row instead of replacing that player's previous ghost
  -- (breaking the one-ghost-per-save rule), and their GHOST REPORT queries
  -- an origin no row has ever had, so it always answers "you have no ghost
  -- out there" even seconds after a successful upload.
  --
  -- Fix: mint the token ONCE and persist it as a FLAG NAME in save.flags --
  -- the one store this mod has proven reliably persists (it's how defeat
  -- tracking already survives reloads). Flags only store booleans, so the
  -- token is encoded into the NAME (ORIGIN_FLAG_PREFIX .. token) and
  -- recovered by scanning save.flags for that prefix. Because save.flags
  -- lives INSIDE the save file, this is naturally per-save-file with no
  -- extra work -- two saves can't collide even if they share name+id, which
  -- is exactly the property activeSlot was giving us.
  --
  -- Randomness comes from love.math.random (seeded from system entropy at
  -- LOVE startup) rather than math.random: seeding the global Lua RNG in a
  -- Pokemon game could perturb battle/encounter rolls, which is not a
  -- tradeoff worth making for an id.
  local ORIGIN_FLAG_PREFIX = "SSN_ORIGIN_"

  local function mintOriginToken()
    local n1, n2
    local ok = pcall(function()
      n1 = love.math.random(0, 0xFFFFFF)
      n2 = love.math.random(0, 0xFFFFFF)
    end)
    if not (ok and n1 and n2) then
      -- love.math missing (headless/test harness): fall back to the plain
      -- RNG WITHOUT reseeding it, plus the clock for cross-run spread.
      n1, n2 = math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF)
    end
    return string.format("%06x%06x%x", n1, n2, os.time and os.time() or 0)
  end

  -- saveOriginId is called often (every nearby fetch, every send, assorted
  -- log lines), so memoise per save table -- weak keys so a save that goes
  -- away doesn't pin this entry. Also matters for correctness in the
  -- degraded no-flags-table case below: without the memo that path would
  -- mint a DIFFERENT token (and log) on every single call, whereas this way
  -- it at least stays stable for the session.
  local fallbackTokenMemo = setmetatable({}, { __mode = "k" })

  -- Returns the save's persistent fallback token, minting+storing one the
  -- first time. Never returns nil: a save with no readable flags table still
  -- gets a token, it just can't be persisted (and so reverts to old
  -- per-session behaviour) -- logged so that case is diagnosable, not silent.
  local function fallbackSlotToken(sv)
    local memo = fallbackTokenMemo[sv]
    if memo then return memo end
    local flags = type(sv.flags) == "table" and sv.flags or nil
    if flags then
      for name, on in pairs(flags) do
        if on == true and type(name) == "string" then
          local token = name:match("^" .. ORIGIN_FLAG_PREFIX .. "(.+)$")
          if token then
            fallbackTokenMemo[sv] = token
            return token
          end
        end
      end
    end
    local token = mintOriginToken()
    local stored = false
    if flags then
      stored = pcall(function() Flags.set(sv, ORIGIN_FLAG_PREFIX .. token) end)
    end
    fallbackTokenMemo[sv] = token
    log("activeSlot unavailable -- minted fallback save identity '%s' (persisted=%s)",
      token, tostring(stored))
    if stored then
      log("NOTE: that identity only sticks once the game itself is SAVED -- " ..
        "sending a ghost without saving afterwards will mint a new one next session")
    else
      log("WARNING: could not write the identity flag -- this save will get a NEW " ..
        "identity next session (duplicate ghosts, GHOST REPORT won't find its own)")
    end
    return token
  end

  local function saveOriginId(game)
    local sv = game and game.save
    if not sv then return "unknown" end
    local p = type(sv.player) == "table" and sv.player or nil
    local name = p and (p.name or p.playerName or p.trainerName or p.ot)
    local id   = p and (p.id or p.trainerId or p.otId or p.secretId or p.playerId)
    local slot
    do
      local ok, result = pcall(function() return SaveData.activeSlot(sv.version) end)
      if ok then slot = result end
    end
    -- Only ever consulted when activeSlot genuinely fails -- a save where it
    -- works keeps the exact origin string it already had, so existing ghosts
    -- and defeat flags are untouched by this change.
    if slot == nil then slot = fallbackSlotToken(sv) end
    return string.format("slot%s:%s#%s", tostring(slot), tostring(name or "?"), tostring(id or "?"))
  end

  local function playerName(game)
    local sv = game and game.save
    local p = sv and type(sv.player) == "table" and sv.player or nil
    local cand = p and (p.name or p.playerName or p.trainerName or p.ot)
    if type(cand) == "string" and #cand > 0 then return cand end
    return "RIVAL"
  end

  -- =====================================================================
  -- Battle plumbing: turn a stored record into a runtime trainer class.
  -- =====================================================================
  local function ghostTrainerClass(rec)
    return TRAINER_PREFIX .. tostring(rec.origin) .. "_" .. tostring(rec.id)
  end

  -- Per-receiving-save "have I beaten this ghost" state, via the engine's own
  -- Flags module (src/script/Flags.lua: save.flags[name] = true, arbitrary
  -- string names, directly callable outside the script-row system too) --
  -- confirmed a genuine part of the save's own data (unlike
  -- game.save.modData, which did NOT reliably persist -- see saveOriginId's
  -- notes above), and naturally scoped per receiving save: each save
  -- independently tracks whether IT has beaten a given shared ghost.
  local function defeatFlagName(rec)
    return "SSN_DEFEATED_" .. tostring(rec.origin) .. "_" .. tostring(rec.id)
  end
  local function isDefeated(game, rec)
    local sv = game and game.save
    if not sv then return false end
    local ok, result = pcall(function() return Flags.get(sv, defeatFlagName(rec)) end)
    return ok and result == true
  end

  -- Same pattern, for a FRIENDLY ghost: per-receiving-save "have I met this
  -- ghost before" state -- gates which of the two dialogue lines shows AND
  -- (when a gift item is set) whether the item has already been handed to
  -- THIS save. One flag does both jobs: the maintainer's decision was a
  -- ONE-TIME gift tracked per receiving save, and "have we met" is exactly
  -- that same one-time transition, so a second flag would just be
  -- redundant bookkeeping for the same fact.
  local function friendlyMetFlagName(rec)
    return "SSN_MET_" .. tostring(rec.origin) .. "_" .. tostring(rec.id)
  end
  local function hasMetFriendly(game, rec)
    local sv = game and game.save
    if not sv then return false end
    local ok, result = pcall(function() return Flags.get(sv, friendlyMetFlagName(rec)) end)
    return ok and result == true
  end

  -- The viewer's own party's average level, rounded and clamped to a valid
  -- level range -- the target SCALE TO ME sets every downloaded ghost mon
  -- to. nil if there's no readable party (never happens in practice, since
  -- both generations require a non-empty party before SEND GHOST even
  -- opens, but a downloaded ghost can be fought at any time).
  local function viewerAverageLevel(game)
    local party = game and game.save and game.save.party
    if type(party) ~= "table" or #party == 0 then return nil end
    local sum, n = 0, 0
    for _, mon in ipairs(party) do
      if type(mon.level) == "number" then sum = sum + mon.level; n = n + 1 end
    end
    if n == 0 then return nil end
    return math.max(1, math.min(100, math.floor(sum / n + 0.5)))
  end

  -- Money reward, entirely in-game: no snapshot, no server round-trip. Every
  -- GHOST_SPRITES pic already corresponds 1:1 to a REAL vanilla trainer
  -- class (that's how the sprite/pic pairs were mined in the first place --
  -- see [[gen1recomp-modding]]), and every one of those classes already has
  -- a real `baseMoney` the vanilla game itself balances. So instead of
  -- inventing a reward number, just look up which class the ghost's chosen
  -- battle art actually belongs to and reuse ITS baseMoney -- the engine's
  -- own existing trainer-victory formula (`baseMoney * enemy's last mon's
  -- level`, BattleState.lua) then pays out and prints the correct amount
  -- entirely on its own, no custom give_money/show_text needed. Built once
  -- and cached: `source ~= MOD_ID` excludes our OWN injected ghost classes
  -- from the scan, so an earlier ghost injection can never poison this
  -- lookup by having its OWN entry (initially baseMoney 0/looked-up) match
  -- some other ghost's pic first.
  local ghostBaseMoneyByPic  -- built lazily; nil until first use
  local GHOST_DEFAULT_BASE_MONEY = 35  -- OPP_RIVAL1's own baseMoney -- used
    -- whenever a ghost's pic has no real trainer-class match (the default
    -- Red look uses trainer_card art, which isn't a battle-trainer pic at
    -- all) -- a rival fits the "unclassed player-lookalike" case thematically
    -- and 35 sits solidly mid-pack among real classes (range 5-99).
  local function baseMoneyForPic(game, pic)
    if not ghostBaseMoneyByPic then
      ghostBaseMoneyByPic = {}
      local ok = pcall(function()
        for _, t in pairs(game.data.trainers) do
          if t.source ~= MOD_ID and type(t.pic) == "string" and type(t.baseMoney) == "number" then
            ghostBaseMoneyByPic[t.pic] = t.baseMoney
          end
        end
      end)
      if not ok then ghostBaseMoneyByPic = {} end
    end
    return (pic and ghostBaseMoneyByPic[pic]) or GHOST_DEFAULT_BASE_MONEY
  end

  -- BattleState.newTrainer (src/battle/BattleState.lua) reads
  -- game.data.trainers[class] and builds each party mon via
  -- Pokemon.new(data, slot.species, slot.level), THEN: "if slot.moves then
  -- mon.moves = <rebuilt from slot.moves ids> end" -- so a slot's moves ARE
  -- honored when present (confirmed from source). DVs are NOT: the same
  -- function unconditionally does `mon.dvs = trainerDvs` afterward, so exact
  -- IVs can't be preserved this way -- only species/level/moves are exact.
  -- class -> rec, refreshed every injectTrainer call. Lets the battle.started
  -- listener below (which only gets the trainer CLASS id from the engine's
  -- event payload, not our own record) find the sender's original party
  -- again -- specifically for nicknames, which Pokemon.new/BattleState.
  -- newTrainer have no field for at all (confirmed from source: neither
  -- reads a nickname off a party slot), so they can't be set at construction
  -- time and have to be patched onto the already-built enemyParty instead.
  local injectedRecs = {}

  local function injectTrainer(game, rec)
    if not (game and game.data and game.data.trainers) then return nil end
    local class = ghostTrainerClass(rec)
    injectedRecs[class] = rec
    -- SCALE TO ME: every mon's level becomes the VIEWER's own party average
    -- instead of whatever the sender actually had. Species/moves are
    -- untouched -- a scaled-up mon can still only know what it was sent
    -- with, a known and accepted tradeoff for an opt-in mode (see
    -- ghostLevelMode's own comment). nil (no scaling) if the mode isn't on
    -- or the viewer's own party is unreadable, in which case this behaves
    -- exactly as it always has.
    local scaleTo = (ghostLevelMode() == "scale") and viewerAverageLevel(game) or nil
    local slots = {}
    for _, mon in ipairs(rec.party or {}) do
      if mon and mon.species and mon.level then
        local moveIds
        if type(mon.moves) == "table" and #mon.moves > 0 then
          moveIds = {}
          for _, mv in ipairs(mon.moves) do
            local id = type(mv) == "table" and mv.id or mv
            if id then moveIds[#moveIds + 1] = id end
          end
          if #moveIds == 0 then moveIds = nil end
        end
        slots[#slots + 1] = { species = mon.species, level = scaleTo or mon.level, moves = moveIds }
      end
    end
    if #slots == 0 then return nil end
    local pic = rec.pic or PLAYER_PIC
    -- Money pays out on the GENUINE first win only. injectTrainer runs
    -- fresh before every battle -- including a REPEATABLE rematch
    -- (engageGhost re-injects before re-running battleSequenceRows) -- and
    -- isDefeated's flag only ever flips true the instant the FIRST win's
    -- own set_flag row runs, mid-battle-sequence. So checking it here,
    -- before THIS particular fight starts, cleanly distinguishes "first
    -- encounter" (not yet defeated -> real payout) from "rematch" (already
    -- defeated -> baseMoney 0, no repeat payout) with no separate
    -- bookkeeping needed.
    local alreadyDefeated = isDefeated(game, rec)
    game.data.trainers[class] = {
      id       = class,
      index    = -1,
      name     = rec.name or "RIVAL",
      pic      = pic,
      parties  = { slots },
      aiMods   = { 1 },
      baseMoney = alreadyDefeated and 0 or baseMoneyForPic(game, pic),
      source   = MOD_ID,
    }
    return class
  end

  -- Ghosts that belong in the CURRENTLY loaded save (everyone else's, same
  -- generation). Gen 1 and Gen 2 map ids collide (Gold's post-game Kanto
  -- reuses names like ROUTE_1), and battle-building is completely different
  -- between them (script verbs vs. a native trainer object), so a record
  -- from the wrong generation must never reach spawning at all -- not just
  -- "would look confusing" but "would crash or misbehave". Older records
  -- with no `game` field predate this and are treated as "red" (this mod's
  -- only generation until now), matching what they always were.
  local function recordGame(rec) return rec.game or "red" end
  local function activeGhosts(game)
    local origin = saveOriginId(game)
    local out = {}
    for _, rec in ipairs(loadStorage().ghosts) do
      if rec.origin ~= origin and recordGame(rec) == RECORD_GAME then out[#out + 1] = rec end
    end
    return out
  end

  -- =====================================================================
  -- Facing / movement-style helpers
  -- =====================================================================
  -- world:current().facing came back lowercase in testing ("left"/"right");
  -- the map-object schema's own values are uppercase cardinals ("UP"/"DOWN"/
  -- "LEFT"/"RIGHT", see maps.lua). v0.2.1 passed a nonexistent "facing" key on
  -- the objDef -- there IS no such field (confirmed: zero "facing" hits across
  -- maps.lua). A STAY object's orientation is its "range" field instead.
  local DIR_ALIASES = {
    up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
    UP = "UP", DOWN = "DOWN", LEFT = "LEFT", RIGHT = "RIGHT",
  }
  local function normalizeDir(facing)
    return DIR_ALIASES[facing] or "DOWN"
  end
  local FACE_DELTA = {
    UP = { 0, -1 }, DOWN = { 0, 1 }, LEFT = { -1, 0 }, RIGHT = { 1, 0 },
  }

  -- =====================================================================
  -- Spawning ghosts onto maps
  -- =====================================================================
  local spawned = {}     -- mapId -> { npcId, ... } we created (so we can clean up)
  local mapGhosts = {}   -- mapId -> { {rec=rec, npcName=name}, ... } for the current map
  local mapOrigins = {}  -- mapId -> { [rawOrigin] = true } for whichever source (local or online) got there first --
                          -- see spawnOnlineGhost: prevents the SAME sender's ghost from spawning twice (once
                          -- from the local shared file, once downloaded from the server) when online mode is on,
                          -- since the same send both writes locally and uploads.
  local mapTiles = {}    -- mapId -> { ["x,y"] = true } for every tile a spawned ghost already occupies (local
                          -- OR online) -- see spawnOnlineGhost: the server's own same-tile pick (worker.js's
                          -- ROW_NUMBER() partition) only dedupes among rows IT stores, so a local ghost from
                          -- ghosts.lua is invisible to it -- this catches a local ghost and a downloaded ghost
                          -- landing on one square. DIFFERENT from mapOrigins: that catches the SAME sender seen
                          -- twice, this catches DIFFERENT senders sharing coordinates. Local ghosts spawn
                          -- synchronously at map entry and register first, so they reliably win the race
                          -- against any async online fetch -- same ordering guarantee mapOrigins depends on.
  local gen2Ghosts = {}  -- GEN 2 ONLY: rec.id -> {npcId, mapId, rec, trainerStruct, sight, afterScript} --
                          -- everything refreshGen2Ghost needs to re-derive that ghost's object state.

  local function npcIdOf(npc, rec)
    -- spawnNpc returns the runtime object id as a STRING (e.g. "PALLET_TOWN_obj_4").
    if type(npc) == "string" then return npc end
    if type(npc) == "table" then return npc.id or npc.name or (NPC_NAME_PREFIX .. rec.id) end
    return NPC_NAME_PREFIX .. rec.id
  end

  local function despawnMap(mapId)
    local w = world(); if not w then return end
    for _, id in ipairs(spawned[mapId] or {}) do
      pcall(function() w:removeNpc(id) end)
    end
    spawned[mapId] = {}
    mapGhosts[mapId] = {}
    mapOrigins[mapId] = {}
    mapTiles[mapId] = {}
    if IS_GEN2 then
      for id, ghost in pairs(gen2Ghosts) do
        if ghost.mapId == mapId then gen2Ghosts[id] = nil end
      end
    end
  end

  -- GHOST COLLISION option, actually wired this time. Confirmed field from
  -- src/world/Collision.lua: `Collision.occupied(entities,cx,cy,ignore)` only
  -- treats an entity as blocking when `not e.passable`. spawnNpc's own return
  -- value is just a runtime id STRING (no entity table to set a field on
  -- directly), so this looks the live NPC back up via mod.world:npc() to
  -- reach its underlying `.npc` entity table (the same field Handle:face()
  -- writes `.facing` onto).
  local function applyCollision(w, mapId, name)
    local handle
    local ok = pcall(function() handle = w:npc(mapId, name) end)
    if not (ok and handle and handle.npc) then return end
    pcall(function() handle.npc.passable = (mod.options:get("ghost_collision") == false) end)
  end

  -- Spawns ONE ghost NPC (player sprite, stationary, facing its saved
  -- direction) on a map that's already the active spawn target for --
  -- shared by spawnGhostsForMap (local shared-file ghosts, all at once on
  -- map entry) and the online-mode download handler (added as results
  -- arrive asynchronously, potentially after the map's already spawned).
  -- Returns true on success.
  local function spawnOneGhost(game, w, mapId, rec)
    -- A FRIENDLY ghost has no battle at all, so no trainer class is needed
    -- -- otherwise identical spawn shape (stationary NPC, same sprite/
    -- position/facing/collision handling) either way.
    if rec.ghostType ~= "friendly" then
      injectTrainer(game, rec)  -- ensure the trainer class exists before any battle
    end
    local name = NPC_NAME_PREFIX .. rec.id
    local sprite = rec.sprite or PLAYER_SPRITE
    local objDef = { name = name, sprite = sprite, movement = "STAY", range = normalizeDir(rec.facing), x = rec.x, y = rec.y }
    local npc, err = w:spawnNpc(mapId, objDef)
    if not npc then
      mod.log:warn("[silphscope_network] spawnNpc failed on %s: %s", tostring(mapId), tostring(err))
      return false
    end
    if not spawned._loggedShape then
      spawned._loggedShape = true
      log("spawnNpc returned type=%s value=%s", type(npc), shallowDump(npc))
    end
    spawned[mapId] = spawned[mapId] or {}
    mapGhosts[mapId] = mapGhosts[mapId] or {}
    spawned[mapId][#spawned[mapId] + 1] = npcIdOf(npc, rec)
    -- The runtime id embeds the object's numeric index (e.g.
    -- "PALLET_TOWN_obj_4" -> 4; matches the same "_obj_<index>" shape seen in
    -- save.defeatedTrainers keys elsewhere in the engine). That number is
    -- what the 'emote' script command's target parameter wants
    -- (Commands.emote: a number -> ow:npcByIndex(target)) -- used for the
    -- GHOST SIGHT "!" flourish. nil if unparseable; the flourish just skips
    -- itself gracefully when that happens.
    local objIndex = type(npc) == "string" and tonumber(npc:match("_obj_(%d+)$")) or nil
    mapGhosts[mapId][#mapGhosts[mapId] + 1] = { rec = rec, npcName = name, objIndex = objIndex }
    applyCollision(w, mapId, name)
    mapOrigins[mapId] = mapOrigins[mapId] or {}
    mapOrigins[mapId][rec.sourceOrigin or rec.origin] = true
    mapTiles[mapId] = mapTiles[mapId] or {}
    mapTiles[mapId][rec.x .. "," .. rec.y] = true
    return true
  end

  -- Spawn every LOCAL (shared-file) ghost NPC for a map, replacing whatever
  -- was there before. The BATTLE is triggered separately by the input.step
  -- watcher below -- we don't rely on the map-script talk registry (its
  -- merged views are cached at load, so runtime registration was a no-op --
  -- see v0.1.0 log: "registered ... on 0 map(s)"). Online-mode ghosts are
  -- layered on top of this separately (see pollOnlineJobs) since they arrive
  -- asynchronously, potentially after this has already run for the map.
  local function spawnGhostsForMap(game, mapId)
    game = game or liveGame
    local w = world()
    if not (w and game and mapId) then return end
    despawnMap(mapId)
    spawned[mapId] = {}
    mapGhosts[mapId] = {}
    local n = 0
    for _, rec in ipairs(activeGhosts(game)) do
      if rec.mapId == mapId and spawnOneGhost(game, w, mapId, rec) then
        n = n + 1
      end
    end
    if n > 0 then log("spawned %d local ghost(s) on map %s", n, tostring(mapId)) end
  end

  -- =====================================================================
  -- GEN 2 (Gold) spawning + battle. Ported from the validated ssn_gen2_spike
  -- (see silphscope-gen2-scope memory) -- everything here only ever runs
  -- when IS_GEN2 is true; the Gen 1 code above/below it is untouched.
  --
  -- No hand-rolled walk-up: a Gold map object can carry a native `trainer`
  -- struct ({class, member, seenText, winText}) + a `sight` range, and
  -- World:checkTrainerBattle (run by the engine every step) does the "!",
  -- the approach, the dialogue and the battle itself for any such object in
  -- eyesight -- confirmed live, this is the entire GHOST SIGHT sequence for
  -- free. Defeat is NOT: with no `event` field (a numeric slot into Gold's
  -- own save-file event flags we must not squat on), the engine never marks
  -- our ghost beaten, so that -- and what the ghost becomes afterward -- is
  -- ours to track via save.flags (already generic, see defeatFlagName/
  -- isDefeated above) and DERIVE, never bake, into the live object each time
  -- something could have changed it (spawn, battle end, a toggle flip) --
  -- baking it one-way was tried and found broken in the spike: REPEATABLE
  -- turned on afterward did nothing for an already-beaten ghost, because
  -- Gold's object defs live in the map table for the whole session and
  -- re-entering the map rebuilds NPC instances FROM that def.
  -- =====================================================================
  local Trainers2, Mon2
  if IS_GEN2 then
    local okT, t = pcall(require, "src.world.gen2.Trainers")
    if okT then Trainers2 = t end
    local okM, m = pcall(require, "src.battle.gen2.Mon")
    if okM then Mon2 = m end
  end

  -- Full-fidelity ghost mons. Trainers.party (the function that turns a
  -- roster into real Mon instances for battle) hardcodes every trainer mon
  -- to DVs 9/8/8/8/8 and never passes happiness -- that's the CART's own
  -- MakeTrainerPartyMon behavior, used for real Gold trainers too, and it's
  -- wrong for a ghost twice over: on Gen 2, gender and shininess are
  -- DERIVED FROM DVS (Mon.vanillaGender compares the attack DV against
  -- genderRatio/16; Mon.vanillaShiny wants speed/defense/special all 10 and
  -- attack %4 in {2,3}), so fixed DVs mean every ghost is male and never
  -- shiny regardless of the sender; happiness drives RETURN/FRUSTRATION and
  -- defaults to 70. Fix: wrap Trainers.party once -- let the original build
  -- the party (moves/stats/everything), then rebuild ONLY rows carrying our
  -- own marker key through the SAME Mon.new constructor, with the real
  -- dvs/happiness passed through. A row with no marker (every real Gold
  -- trainer) comes back untouched, so the cart's own fixed-DV behavior for
  -- its own trainers is preserved exactly.
  local GEN2_ROSTER_EXTRA = "ssnExtra"
  local gen2PartyWrapped = false
  local function wrapGen2Party()
    if gen2PartyWrapped or not (Trainers2 and Mon2) then return end
    local original = Trainers2.party
    if type(original) ~= "function" then return end
    Trainers2.party = function(data, entry)
      local out = original(data, entry)
      local roster = entry and entry.roster
      if type(roster) ~= "table" or type(out) ~= "table" then return out end
      for i, row in ipairs(roster) do
        local extra = type(row) == "table" and row[GEN2_ROSTER_EXTRA]
        local built = out[i]
        if extra and built then
          -- Mon.new WRITES dvs.hp into the table it's handed -- copy first,
          -- the source here can be the sender's own save data via a local
          -- ghost record.
          local dvs
          if type(extra.dvs) == "table" then
            dvs = {}
            for k, v in pairs(extra.dvs) do dvs[k] = v end
          end
          local rebuilt = Mon2.new(data, row.species, row.level, {
            moves = built.moves, item = built.item, dvs = dvs, happiness = extra.happiness,
            nickname = extra.nickname,
          })
          if rebuilt then out[i] = rebuilt end
        end
      end
      return out
    end
    gen2PartyWrapped = true
    log("Gen 2: Trainers.party wrapped for full-fidelity ghost mons")
  end
  if IS_GEN2 then wrapGen2Party() end

  -- A save party -> a Gen 2 trainer roster row, captured at SEND time (same
  -- moment Gen 1 captures rec.party) so what's stored/uploaded is already
  -- battle-ready. Deliberately a snapshot of species/level/moves(+dvs/
  -- happiness for fidelity) -- OT is dropped, nothing in a battle reads it,
  -- same fidelity ceiling the Gen 1 payload already has. DVs carry gender
  -- AND shininess with them (see above), so those are never sent as
  -- separate booleans -- a standalone flag would contradict the DVs the
  -- instant anything re-derived them.
  local function gen2PartyRoster(game)
    local party = game and game.save and game.save.party
    if type(party) ~= "table" or #party == 0 then return nil end
    local roster = {}
    for _, mon in ipairs(party) do
      if mon and mon.species and mon.level then
        local moves
        if type(mon.moves) == "table" and #mon.moves > 0 then
          moves = {}
          for _, mv in ipairs(mon.moves) do
            local id = type(mv) == "table" and mv.id or mv
            if type(id) == "string" then moves[#moves + 1] = id end
          end
          if #moves == 0 then moves = nil end
        end
        local dvs
        if type(mon.dvs) == "table" then
          dvs = { attack = mon.dvs.attack, defense = mon.dvs.defense,
            speed = mon.dvs.speed, special = mon.dvs.special }
        end
        -- A Gen 2 save party mon's nickname field is `.name` (confirmed
        -- from a live Gold save dump, see silphscope-gen2-scope memory) --
        -- NOT `.nickname`, which is what Mon.new's own opts field is
        -- called. Renamed here so our own storage/transmission is
        -- consistent with Gen 1's naming, not because the source data uses
        -- that key.
        local nick = type(mon.name) == "string" and mon.name ~= "" and mon.name or nil
        roster[#roster + 1] = { species = mon.species, level = mon.level,
          moves = moves, item = mon.item,
          [GEN2_ROSTER_EXTRA] = { dvs = dvs, happiness = mon.happiness, nickname = nick } }
      end
    end
    if #roster == 0 then return nil end
    return roster
  end

  local GEN2_STANDING = { down = 6, up = 7, left = 8, right = 9 }  -- constants/map_object_constants.asm, via src/world/gen2/Npc.lua's MOVE table
  local GEN2_SIGHT_CELLS = 5  -- same scale as Gen 1's own GHOST SIGHT range

  local refreshGen2Ghost  -- forward-declared: spawnOneGen2Ghost calls it before its definition below

  -- Class+member injection: appends a member to a REAL trainer class (so
  -- money/items/AI personality come from the game's own balanced values,
  -- same trick as Gen 1's baseMoneyForPic) and injects the seen/win text
  -- into the live VM text table. Reuses the SAME member slot across
  -- refreshes of one ghost (rec._gen2Member) rather than growing the
  -- class's trainers array every spawn.
  local function gen2InjectGhost(game, rec)
    local data = game and game.data
    local classes = data and data.trainers and data.trainers.classes
    local classId = rec.pic or GEN2_PLAYER_CLASS
    local entry = classes and classes[classId]
    if not entry then
      entry = classes and classes[GEN2_PLAYER_CLASS]
      classId = GEN2_PLAYER_CLASS
    end
    if not (entry and type(entry.trainers) == "table") then return nil end
    local roster = type(rec.party) == "table" and #rec.party > 0 and rec.party or nil
    if not roster then return nil end
    -- SCALE TO ME (same rule as Gen 1's injectTrainer): every mon's level
    -- becomes the viewer's own party average. Species/moves/dvs untouched.
    -- rec.party is the SAME table object cached in loadStorage().ghosts (or
    -- the online download record), so this must build a fresh copy rather
    -- than mutate it in place -- otherwise a scaled level would get written
    -- back into the shared local storage / corrupt what a later refresh
    -- reads for a DIFFERENT viewer with scaling off.
    local scaleTo = (ghostLevelMode() == "scale") and viewerAverageLevel(game) or nil
    if scaleTo then
      local scaled = {}
      for i, mon in ipairs(roster) do
        local copy = {}
        for k, v in pairs(mon) do copy[k] = v end
        copy.level = scaleTo
        scaled[i] = copy
      end
      roster = scaled
    end
    local tag = "SSN_" .. tostring(rec.origin) .. "_" .. tostring(rec.id)
    local member = rec._gen2Member
    if member and entry.trainers[member] and entry.trainers[member].id == tag then
      entry.trainers[member].party = roster
    else
      member = #entry.trainers + 1
      entry.trainers[member] = { id = tag, index = member, name = rec.name or "RIVAL",
        party = roster, trainerType = "TRAINERTYPE_NORMAL" }
      rec._gen2Member = member
    end
    local seenKey, winKey = tag .. "_SEEN", tag .. "_WIN"
    local ok, ow = pcall(function() return mod.world:overworld() end)
    local texts = ok and ow and ow.text
    if type(texts) == "table" then
      texts[seenKey] = rec.beforeText and ((rec.name or "RIVAL") .. ": " .. rec.beforeText)
        or ((rec.name or "RIVAL") .. "\nwants to battle!")
      texts[winKey] = rec.afterText and ((rec.name or "RIVAL") .. ": " .. rec.afterText)
        or ((rec.name or "RIVAL") .. " has nothing\nmore to say.")
    end
    return { classIndex = entry.index, member = member, seenKey = seenKey, winKey = winKey }
  end

  -- Spawns ONE Gen 2 ghost NPC. Mirrors spawnOneGhost's role/callers exactly
  -- (shared by spawnGhostsForGen2Map and the online download handler) but
  -- the objDef shape is entirely different -- Gen 2 wants a numeric
  -- STANDING_* movement, `type = 2` (trainer), a `sight` range and the
  -- `trainer` struct itself, none of which Gen 1's spawnNpc call uses.
  local function spawnOneGen2Ghost(game, w, mapId, rec)
    local sprite = rec.sprite
    if not (type(sprite) == "string" and type(rec.pic) == "string"
      and GEN2_SPRITE_PAIR_OK[sprite .. "|" .. rec.pic]) then
      sprite = GEN2_PLAYER_SPRITE
    end
    local dir = string.lower(normalizeDir(rec.facing))

    -- FRIENDLY: a plain, non-trainer NPC (type=0, no `trainer` struct,
    -- sight=0) -- the SAME shape this mod already uses live for a
    -- defeated, non-repeatable TRAINER ghost (npc.def.trainer=nil,
    -- sight=0), just built directly here instead of derived. Deliberately
    -- no scriptKey either: dialogue and the gift-item grant are driven by
    -- a manual per-tick facing+interact poll (engageFriendlyGhost, called
    -- from gen2Step), not native script dispatch -- avoids needing to
    -- verify world.interacted's exact Gen 2 payload shape blind, and
    -- reuses the SAME manual-poll pattern Gen 1 already relies on for its
    -- own ghost interactions.
    if rec.ghostType == "friendly" then
      local objDef = {
        sprite = sprite, x = rec.x, y = rec.y,
        movement = GEN2_STANDING[dir] or GEN2_STANDING.down,
        type = 0, sight = 0, palette = 0,
        radius = { x = 0, y = 0 }, hours = { -1, -1 },
      }
      local id, err = w:spawnNpc(mapId, objDef)
      if not id then
        mod.log:warn("[silphscope_network] gen2 friendly spawnNpc failed on %s: %s", tostring(mapId), tostring(err))
        return false
      end
      spawned[mapId] = spawned[mapId] or {}
      spawned[mapId][#spawned[mapId] + 1] = id
      mapGhosts[mapId] = mapGhosts[mapId] or {}
      mapGhosts[mapId][#mapGhosts[mapId] + 1] = { rec = rec, gen2 = true, npcId = id }
      mapOrigins[mapId] = mapOrigins[mapId] or {}
      mapOrigins[mapId][rec.sourceOrigin or rec.origin] = true
      mapTiles[mapId] = mapTiles[mapId] or {}
      mapTiles[mapId][rec.x .. "," .. rec.y] = true
      return true
    end

    local inj = gen2InjectGhost(game, rec)
    if not inj then
      log("gen2 inject failed for ghost '%s'", tostring(rec.name))
      return false
    end
    local trainerStruct = { class = inj.classIndex, member = inj.member,
      seenText = inj.seenKey, winText = inj.winKey }
    local sight = GEN2_SIGHT_CELLS + 1
    local objDef = {
      sprite = sprite, x = rec.x, y = rec.y,
      movement = GEN2_STANDING[dir] or GEN2_STANDING.down,
      type = 2, sight = sight, palette = 0,
      radius = { x = 0, y = 0 }, hours = { -1, -1 },
      trainer = trainerStruct,
    }
    local id, err = w:spawnNpc(mapId, objDef)
    if not id then
      mod.log:warn("[silphscope_network] gen2 spawnNpc failed on %s: %s", tostring(mapId), tostring(err))
      return false
    end
    spawned[mapId] = spawned[mapId] or {}
    spawned[mapId][#spawned[mapId] + 1] = id
    local ghost = { npcId = id, mapId = mapId, rec = rec, trainerStruct = trainerStruct,
      sight = sight, afterScript = { { op = "jumptextfaceplayer", text = inj.winKey } } }
    gen2Ghosts[rec.id] = ghost
    mapGhosts[mapId] = mapGhosts[mapId] or {}
    mapGhosts[mapId][#mapGhosts[mapId] + 1] = { rec = rec, gen2 = true, npcId = id }
    mapOrigins[mapId] = mapOrigins[mapId] or {}
    mapOrigins[mapId][rec.sourceOrigin or rec.origin] = true
    mapTiles[mapId] = mapTiles[mapId] or {}
    mapTiles[mapId][rec.x .. "," .. rec.y] = true
    refreshGen2Ghost(game, ghost)  -- derive its real state immediately -- a defeat flag from an earlier session may already be set
    return true
  end

  local function liveGen2Npc(w, npcId)
    if not (w and type(w.npcs) == "table") then return nil end
    for _, npc in ipairs(w.npcs) do
      if npc.id == npcId then return npc end
    end
    return nil
  end

  -- DERIVED, never baked -- see the block comment above this section for why.
  -- Mirrors the spike's refreshGhost exactly: hunting (trainer struct live,
  -- full sight) / beaten-but-repeatable (trainer struct live, sight zeroed
  -- so it won't ambush, but interactBody tries def.trainer BEFORE
  -- def.scriptKey so an A-press still resolves to a real rematch) / beaten
  -- default (trainer struct cleared, scriptKey plays the after-battle line).
  refreshGen2Ghost = function(game, ghost)
    local ok, w = pcall(function() return mod.world:overworld() end)
    if not (ok and w) then return false end
    local npc = liveGen2Npc(w, ghost.npcId)
    if not (npc and npc.def) then return false end
    local defeated = isDefeated(game, ghost.rec)
    -- GHOST COLLISION -- same rule as Gen 1's Collision.occupied: an entity
    -- blocks unless passable. Lives on the live NPC instance (NPC.new never
    -- reads objDef.passable), so it belongs in the refresh, not the spawn.
    npc.passable = (mod.options:get("ghost_collision") == false)
    if not defeated then
      npc.def.trainer = ghost.trainerStruct
      npc.def.sight = ghost.sight
      npc.def.scriptKey = nil
    elseif mod.options:get("ghost_repeatable") == true then
      npc.def.trainer = ghost.trainerStruct
      npc.def.sight = 0
      npc.def.scriptKey = nil
    else
      npc.def.trainer = nil
      npc.def.sight = 0
      npc.def.scriptKey = ghost.afterScript
    end
    return true
  end

  local function spawnGhostsForGen2Map(game, mapId)
    game = game or liveGame
    local w = world()
    if not (w and game and mapId) then return end
    despawnMap(mapId)
    local n = 0
    for _, rec in ipairs(activeGhosts(game)) do
      if rec.mapId == mapId and spawnOneGen2Ghost(game, w, mapId, rec) then n = n + 1 end
    end
    if n > 0 then log("spawned %d gen2 ghost(s) on map %s", n, tostring(mapId)) end
  end

  -- =====================================================================
  -- ONLINE MODE: upload the sent ghost to the server, and download other
  -- players' ghosts near the player's current map. On by default; OFFLINE
  -- MODE is the opt-out toggle for a local-only save. Both directions ride
  -- on Fetch's async job/poll model -- nothing here blocks the game even if
  -- the server is slow or unreachable.
  -- =====================================================================
  local function onlineModeOn()
    return ONLINE_AVAILABLE and mod.options:get("offline_mode") ~= true
  end

  local function onlineGhostCount()
    if ONLINE_COUNT_SUPPORTED then
      local n = tonumber(mod.options:get("online_ghost_count"))
      if n then return math.max(1, math.min(5, math.floor(n))) end
    end
    return ONLINE_DEFAULT_COUNT
  end

  -- Used to build both the NPC's engine object name and the trainer-class/
  -- defeat-flag keys for a downloaded ghost -- a player's origin string can
  -- contain characters (":", "#") that are fine as plain Lua table keys but
  -- unconfirmed-safe as an engine object NAME, so this keeps everything
  -- derived from an online ghost restricted to word characters.
  local function sanitizeId(s)
    return (tostring(s):gsub("[^%w]", "_"))
  end

  -- Percent-encodes anything outside the URL-unreserved set. Needed because
  -- base64 output contains "+", "/", "=" -- "+" in particular is read as a
  -- literal space by some query-string parsers if left unescaped.
  local function urlEncodeComponent(s)
    return (tostring(s):gsub("[^%w%-%.%_%~]", function(c)
      return string.format("%%%02X", string.byte(c))
    end))
  end

  -- Current map + every map it's directly connected to (game.data.maps'
  -- own connections table -- already-loaded ROM data, so the server never
  -- needs to know anything about the game's map graph).
  --
  -- The STRING neighbor id lives under a different field per generation --
  -- found while building Gen 2 level protection, but this fixes a real gap
  -- in the already-built Gen 2 online nearby-fetch too, not just the new
  -- feature: Gen 1's connections entries carry the neighbor's string id
  -- directly as `.map` (e.g. `{map = "ROUTE_2", ...}`); Gold's own
  -- connections entries instead have `.map` as a NUMERIC map-group index
  -- and the actual string id under `.mapId` (confirmed against
  -- gold/data/generated/maps.lua). Without this, `type(conn.map) ==
  -- "string"` was silently false for every Gold connection, so Gen 2
  -- clients never actually queried neighboring maps at all -- current map
  -- only, invisibly. Checking both field names costs nothing on Gen 1
  -- (its connections never HAVE a `.mapId`) and fixes Gen 2 for both this
  -- and the existing online-fetch use.
  --
  -- CONFIRMED LIVE (2026-08-14): plain `game.data.maps` is nil on Gen 2 for
  -- a mod's own game.data reference at all -- see dataTable's own comment
  -- near the top of the file for why. Was silently broken here too before
  -- this, on top of the connections-field-name issue above.
  local function nearbyMapIds(game, mapId)
    local ids = { mapId }
    local ok, def = pcall(function() return dataTable(game, "maps")[mapId] end)
    if ok and type(def) == "table" and type(def.connections) == "table" then
      for _, conn in pairs(def.connections) do
        if type(conn) == "table" then
          local neighbor = conn.map
          if type(neighbor) ~= "string" then neighbor = conn.mapId end
          if type(neighbor) == "string" then ids[#ids + 1] = neighbor end
        end
      end
    end
    return ids
  end

  -- =====================================================================
  -- LEVEL/ZONE PROTECTION: cap which DOWNLOADED ghosts you see at roughly
  -- this area's own level, so a low-level area can't get steamrolled by
  -- someone else's endgame team. Reads the game's OWN wild-encounter and
  -- trainer-party data rather than a hand-maintained table, so it's exact
  -- for whatever ROM this build actually has and self-corrects if a mod
  -- patches encounters. Works on BOTH generations (2026-08-14) -- Gen 2's
  -- data lives under different field shapes (see mapOwnLevel/
  -- gen2ClassByIndexTable) but the same zoneLevel/margin/EXEMPT/BRANCH
  -- machinery drives both; the EXEMPT/BRANCH map tables themselves stay
  -- Gen 1-only since they were tuned against Gen 1's own data.
  --
  -- Deliberately does NOT gate what you can SEND -- an overleveled sender's
  -- ghost simply won't be offered to a REGION LOCK viewer (enforced
  -- server-side, see startOnlineNearbyFetch/worker.js's maxLevel filter);
  -- the sender gets a heads-up about that at send time instead, in
  -- sendSelf below.
  -- =====================================================================
  local LEVEL_PROTECTION_MARGIN = 2

  -- Per-map overrides, both easy to flip in code (2026-08-14 follow-up):
  --
  -- EXEMPT: no cap at all, regardless of margin. ROUTE_23 (the final
  -- approach to Victory Road/the Elite Four) is exempt by default -- it's
  -- where most late-game players legitimately cluster, and at that stage
  -- team POWER swings far more with movesets/items/skill than with the
  -- handful of levels a cap would be gatekeeping, so a hard cap there
  -- punishes normal endgame progress more than it deters smurfing. Comment
  -- the entry out to restore the cap there.
  local LEVEL_PROTECTION_EXEMPT_MAPS = {
    ROUTE_23 = true,
  }

  -- BRANCH: a wider flat margin REPLACING LEVEL_PROTECTION_MARGIN (not
  -- stacked on top of it) for routes that sit on a genuine order-of-
  -- operations branch. Gen 1 deliberately lets you tackle Celadon/Fuchsia/
  -- Saffron/Cinnabar (Erika/Koga/Sabrina/Blaine) in almost any order once
  -- you have the right HMs, so a player who does one first, levels up, then
  -- loops back through a connecting route they technically visited "out of
  -- order" shouldn't get quietly locked out of sending/seeing ghosts there.
  -- Judgment call, not derived from data (maps.lua has no "branch" field) --
  -- flagged for correction: these are the routes connecting those four
  -- towns to each other and to Lavender/Saffron. Measured against the real
  -- data (2026-08-14): own zone levels here range 22 (ROUTE_7) to 40
  -- (ROUTE_19/20, pulled up by their wild tables, not trainers) -- +8
  -- parked as a reasonable starting point, not yet tuned live.
  local LEVEL_PROTECTION_BRANCH_MARGIN = 8
  -- Both Gen 1 route ids, tuned specifically against Gen 1's own data (see
  -- the measurements above) -- deliberately NOT consulted on Gen 2 even
  -- though Gold's post-game Kanto reuses some of these exact names, since
  -- those namesake maps were never measured for Gold and could easily have
  -- totally different zone levels there. mapOwnLevel/filterCapForMap gate
  -- both tables on `not IS_GEN2` for this reason -- a Gen 2-specific
  -- EXEMPT/BRANCH pass (Gold's own Victory Road approach, its own branch
  -- routes) would need its own tables, not a reuse of these.
  local LEVEL_PROTECTION_BRANCH_MAPS = {
    ROUTE_7 = true, ROUTE_8 = true, ROUTE_16 = true, ROUTE_17 = true,
    ROUTE_18 = true, ROUTE_19 = true, ROUTE_20 = true,
  }

  -- Gen 2 ONLY: a map object's trainer struct carries a NUMERIC class index
  -- (`obj.trainer.class`), not the string class key Gen 1's
  -- `obj.trainerClass` gives directly -- confirmed against
  -- gold/data/generated/maps.lua (a real Bug Catcher object there:
  -- `trainer = {class = 36, member = 5, ...}`). data.trainers.classes is
  -- keyed by string but each entry carries its own `.index`, so this scans
  -- it once and caches index -> entry for that reverse lookup.
  local gen2ClassByIndex
  local function gen2ClassByIndexTable(game)
    if gen2ClassByIndex then return gen2ClassByIndex end
    local t = {}
    pcall(function()
      local classes = game.data.trainers and game.data.trainers.classes
      if type(classes) == "table" then
        for _, entry in pairs(classes) do
          if type(entry) == "table" and type(entry.index) == "number" then
            t[entry.index] = entry
          end
        end
      end
    end)
    gen2ClassByIndex = t
    return t
  end

  local function mapOwnLevel(game, mapId)
    local data = game and game.data
    if not data then return nil end
    local maxLv
    local function bump(lv)
      if type(lv) == "number" and (not maxLv or lv > maxLv) then maxLv = lv end
    end
    if IS_GEN2 then
      -- Gold's own encounter tables are keyed differently from Gen 1's:
      -- grass is data.encounters.grass[mapId].slots[DAY|MORN|NITE] (an
      -- array PER time of day, not one flat array), water is
      -- data.encounters.water[mapId].slots (flat, same shape as Gen 1).
      -- Confirmed against gold/data/generated/encounters.lua.
      pcall(function()
        local enc = dataTable(game, "encounters")
        local grassDef = enc and enc.grass and enc.grass[mapId]
        if type(grassDef) == "table" and type(grassDef.slots) == "table" then
          for _, daySlots in pairs(grassDef.slots) do
            if type(daySlots) == "table" then
              for _, slot in ipairs(daySlots) do bump(slot and slot.level) end
            end
          end
        end
        local waterDef = enc and enc.water and enc.water[mapId]
        if type(waterDef) == "table" and type(waterDef.slots) == "table" then
          for _, slot in ipairs(waterDef.slots) do bump(slot and slot.level) end
        end
        local maps = dataTable(game, "maps")
        local mapDef = maps and maps[mapId]
        if type(mapDef) == "table" and type(mapDef.objects) == "table" then
          local byIndex = gen2ClassByIndexTable(game)
          for _, obj in ipairs(mapDef.objects) do
            local t = obj.trainer
            if type(t) == "table" and t.class and t.member then
              local entry = byIndex[t.class]
              local member = entry and entry.trainers and entry.trainers[t.member]
              local party = member and member.party
              if type(party) == "table" then
                for _, mon in ipairs(party) do bump(mon and mon.level) end
              end
            end
          end
        end
      end)
      return maxLv
    end
    pcall(function()
      local enc = data.encounters and data.encounters[mapId]
      if type(enc) == "table" then
        for _, kind in ipairs({ "grass", "water" }) do
          local slots = enc[kind] and enc[kind].slots
          if type(slots) == "table" then
            for _, slot in ipairs(slots) do bump(slot and slot.level) end
          end
        end
      end
      local mapDef = data.maps and data.maps[mapId]
      if type(mapDef) == "table" and type(mapDef.objects) == "table" then
        for _, obj in ipairs(mapDef.objects) do
          local class, partyIdx = obj.trainerClass, obj.trainerParty
          if class and partyIdx then
            local classDef = data.trainers and data.trainers[class]
            local party = classDef and classDef.parties and classDef.parties[partyIdx]
            if type(party) == "table" then
              for _, mon in ipairs(party) do bump(mon and mon.level) end
            end
          end
        end
      end
    end)
    return maxLv
  end

  -- Maps with neither wild nor trainer data (a pure walkway segment) inherit
  -- the max level of whatever they directly connect to, reusing the same
  -- neighbor list nearbyMapIds already computes (fixed to read Gen 2's own
  -- connection field shape too, see nearbyMapIds' own comment).
  local function zoneLevel(game, mapId, seen)
    seen = seen or {}
    if seen[mapId] then return nil end
    seen[mapId] = true
    local lv = mapOwnLevel(game, mapId)
    if lv then return lv end
    for _, neighbor in ipairs(nearbyMapIds(game, mapId)) do
      if neighbor ~= mapId then
        local nlv = zoneLevel(game, neighbor, seen)
        if nlv and (not lv or nlv > lv) then lv = nlv end
      end
    end
    return lv
  end

  -- The REGION LOCK cap for a given map, independent of the CALLER's own
  -- GHOST LEVELING mode -- used both to decide what a REGION LOCK viewer
  -- requests from the server, and to warn a SENDER how a REGION LOCK viewer
  -- elsewhere would see their ghost regardless of the sender's own mode.
  -- nil for "no cap" -- either an EXEMPT map, or no zone data at all (fail
  -- open rather than silently hiding every ghost near an undata'd map).
  local function filterCapForMap(game, mapId)
    if not IS_GEN2 and LEVEL_PROTECTION_EXEMPT_MAPS[mapId] then return nil end
    local lv = zoneLevel(game, mapId)
    if not lv then return nil end
    local margin = (not IS_GEN2) and LEVEL_PROTECTION_BRANCH_MAPS[mapId]
      and LEVEL_PROTECTION_BRANCH_MARGIN or LEVEL_PROTECTION_MARGIN
    return lv + margin
  end

  -- The cap THIS client should actually request from the server, given its
  -- own GHOST LEVELING mode -- nil (no filtering) unless this client is
  -- itself in REGION LOCK mode. SCALE and OFF both want every ghost back
  -- unfiltered (SCALE then re-levels them client-side, see injectTrainer/
  -- gen2InjectGhost; OFF shows them as sent).
  local function levelCapForMap(game, mapId)
    if ghostLevelMode() ~= "filter" then return nil end
    return filterCapForMap(game, mapId)
  end

  local pendingUpload  -- { jobId = ... } or nil
  local pendingNearby   -- { jobId = ..., forMapId = ... } or nil
  local pendingStats    -- jobId, for the Start Menu's GHOST REPORT entry

  -- Tell the PLAYER when an upload didn't work, not just the log file.
  -- Until v0.9.5 only SUCCESS surfaced in game ("Ghost uploaded online!") --
  -- every failure path (couldn't build the payload, the request errored,
  -- the server rejected it) was log-only, so a tester whose upload failed
  -- saw exactly what a local-only send looks like and had no idea anything
  -- was wrong. That made remote diagnosis impossible: neither the tester nor
  -- the mod author could tell "never tried" from "tried and failed". The
  -- reason is included, trimmed, so a tester can just read it out.
  local function notifyUploadProblem(game, headline, reason)
    local detail = tostring(reason or "")
    detail = detail:gsub("%s+", " "):sub(1, 60)
    local msg = headline
    if detail ~= "" then msg = msg .. "\f" .. detail end
    pcall(function() game.stack:push(TextBox.new(game, msg)) end)
  end

  local function startOnlineUpload(game, rec)
    -- Say WHY we're not uploading. This used to return in total silence,
    -- which made the single most common failure -- ONLINE MODE simply being
    -- off -- completely undiagnosable: the send still reports "sent to the
    -- void!" exactly like a successful one, so a new player has no way to
    -- tell their ghost never left the machine.
    if not ONLINE_AVAILABLE then
      log("online upload skipped: engine networking/JSON unavailable in this build")
      return
    end
    if not onlineModeOn() then
      log("online upload skipped: OFFLINE MODE option is ON")
      return
    end
    if pendingUpload then
      log("online upload skipped: a previous upload is still in flight")
      return
    end
    local okBuild, jobId = pcall(function()
      -- Gen 2's rec.party is already roster-shaped (species/level/moves as
      -- plain id strings/item/ssnExtra{dvs,happiness}), captured that way at
      -- SEND time -- forward it verbatim so full fidelity survives the
      -- round trip. Gen 1's rec.party is the raw save-party deepcopy, so it
      -- still needs the same per-field extraction this always did.
      -- A FRIENDLY ghost has no party at all (rec.party is nil) -- send an
      -- empty array rather than nil/null so the server's own JSON parsing
      -- and validation have one consistent shape to check against
      -- regardless of ghost type.
      local party
      if not rec.party then
        party = {}
      elseif IS_GEN2 then
        party = rec.party
      else
        party = {}
        for _, mon in ipairs(rec.party) do
          local moveIds
          if type(mon.moves) == "table" and #mon.moves > 0 then
            moveIds = {}
            for _, mv in ipairs(mon.moves) do
              local id = type(mv) == "table" and mv.id or mv
              if id then moveIds[#moveIds + 1] = id end
            end
          end
          local nick = type(mon.nickname) == "string" and mon.nickname ~= "" and mon.nickname or nil
          party[#party + 1] = { species = mon.species, level = mon.level, moves = moveIds, nickname = nick }
        end
      end
      local payload = {
        id = rec.origin, name = rec.name, mapId = rec.mapId,
        x = rec.x, y = rec.y, facing = rec.facing, party = party,
        beforeText = rec.beforeText, afterText = rec.afterText,
        sprite = rec.sprite, pic = rec.pic, password = rec.password or "",
        game = RECORD_GAME, ghostType = rec.ghostType,
        giftItem = rec.giftItem, giftQty = rec.giftQty,
      }
      local jsonStr = Json.encode(payload)
      if #jsonStr > ONLINE_UPLOAD_MAX_BYTES then
        error(("payload too large (%d bytes)"):format(#jsonStr), 0)
      end
      local b64 = love.data.encode("string", "base64", jsonStr)
      local url = ONLINE_SERVER_URL .. "/upload?data=" .. urlEncodeComponent(b64)
      return Fetch.get(url, { maxSeconds = 15 })
    end)
    if okBuild and jobId then
      pendingUpload = { jobId = jobId }
      log("online upload started (job %s)", tostring(jobId))
    else
      log("online upload failed to start: %s", tostring(jobId))
      notifyUploadProblem(game, "Upload failed to\nstart.", jobId)
    end
  end

  -- =====================================================================
  -- Battle reporting: tell the server when someone fights a DOWNLOADED
  -- ghost, so its sender can see how it's doing (see the Start Menu's
  -- GHOST REPORT entry). "win"/"loss" here are from the GHOST's own
  -- perspective, like a real trainer's record -- the challenger defeating
  -- the ghost is a LOSS for the ghost, and the challenger losing or
  -- fleeing is a WIN for the ghost. Only two events are ever sent --
  -- "encounter" and "loss" -- because WINS are derived server-side as
  -- encounters minus losses. So an abandoned or crashed battle, which a
  -- quit client could never have reported anyway, lands in the derived-WIN
  -- bucket: walking out on a fight concedes it to the ghost.
  --
  -- Local shared-file ghosts are skipped entirely: they have no server row
  -- (rec.sourceOrigin is the tell -- only a downloaded ghost carries it).
  --
  -- These are queued rather than fired directly because Fetch is polled
  -- one job at a time here and an encounter can easily land while an
  -- upload or a nearby fetch is still in flight; dropping the report on
  -- the floor in that case would silently undercount.
  local reportQueue = {}
  local pendingReport

  local function queueOnlineReport(rec, event)
    if not (ONLINE_AVAILABLE and onlineModeOn()) then return end
    local ghostId = rec and rec.sourceOrigin
    if type(ghostId) ~= "string" or ghostId == "" then return end  -- local ghost, nothing to report to
    local ok, url = pcall(function()
      return string.format("%s/report?id=%s&event=%s",
        ONLINE_SERVER_URL, urlEncodeComponent(ghostId), urlEncodeComponent(event))
    end)
    if ok and url then
      reportQueue[#reportQueue + 1] = url
      log("queued '%s' report for online ghost '%s'", event, ghostId)
    end
  end

  -- Start Menu -> GHOST REPORT. Asks the server how the ghost THIS save
  -- currently has out there is doing. Async like everything else here, so
  -- the caller shows a "checking" beat and pollOnlineJobs pushes the real
  -- answer when it lands.
  local function startGhostReportFetch(game)
    if pendingStats then return false end
    local ok, jobId = pcall(function()
      local url = string.format("%s/stats?id=%s",
        ONLINE_SERVER_URL, urlEncodeComponent(saveOriginId(game)))
      return Fetch.get(url, { maxSeconds = 15 })
    end)
    if ok and jobId then
      pendingStats = jobId
      return true
    end
    log("ghost report fetch failed to start: %s", tostring(jobId))
    return false
  end

  local function startOnlineNearbyFetch(game, mapId)
    if not (ONLINE_AVAILABLE and onlineModeOn()) then return end
    if pendingNearby then return end  -- one at a time; next map change will retry
    local okBuild, jobId = pcall(function()
      local maps = table.concat(nearbyMapIds(game, mapId), ",")
      local origin = saveOriginId(game)
      -- This save's own remembered password (see finalizeSend/askPassword),
      -- not anything tied to a specific ghost -- governs what THIS player
      -- can see: public (no-password) ghosts always match, plus anything
      -- uploaded under the same password. Defaults to "" (public) if this
      -- save has never set one.
      local password = loadStorage().passwords[origin] or ""
      local cap = levelCapForMap(game, mapId)
      local url = string.format("%s/nearby?maps=%s&count=%d&exclude=%s&password=%s&game=%s",
        ONLINE_SERVER_URL, urlEncodeComponent(maps), onlineGhostCount(), urlEncodeComponent(origin),
        urlEncodeComponent(password), urlEncodeComponent(RECORD_GAME))
      if cap then url = url .. "&maxLevel=" .. tostring(cap) end
      return Fetch.get(url, { maxSeconds = 15 })
    end)
    if okBuild and jobId then
      pendingNearby = { jobId = jobId, forMapId = mapId }
      -- Log whether a password is in play (never the password itself). A
      -- passworded save only ever sees public ghosts plus its own pool, so
      -- "0 ghosts" with a password set is expected behavior, not a fault --
      -- without this line the two are impossible to tell apart in the log.
      local pw = loadStorage().passwords[saveOriginId(game)] or ""
      log("online: requesting ghosts for map %s (password %s)",
        tostring(mapId), pw ~= "" and "SET" or "none/public")
    else
      log("online nearby fetch failed to start: %s", tostring(jobId))
    end
  end

  -- Turns one server-returned ghost into a spawnable local record and spawns
  -- it. Namespaced ids (see sanitizeId) so an online ghost's trainer class/
  -- defeat flag can never collide with a local shared-file ghost's.
  --
  -- Dedup: the SAME send both writes to the local shared file AND uploads
  -- online (see finalizeSend), so on a machine where both are visible at
  -- once -- e.g. this dev machine, where every save shares one local
  -- ghosts.lua AND one online account -- the identical ghost can come back
  -- from BOTH sources for the same map, spawning twice and causing a double
  -- battle (confirmed live). serverGhost.id IS the sender's raw origin (see
  -- startOnlineUpload: `id = rec.origin`), so checking it against
  -- mapOrigins[mapId] (populated by every LOCAL ghost already spawned for
  -- this map, see spawnOneGhost) catches exactly this case and skips the
  -- online duplicate -- the local copy, spawned first and with no network
  -- dependency, wins.
  local function spawnOnlineGhost(game, w, mapId, serverGhost)
    if type(serverGhost) ~= "table" or type(serverGhost.id) ~= "string" then return false end
    if type(serverGhost.x) ~= "number" or type(serverGhost.y) ~= "number" then return false end
    -- A FRIENDLY ghost has no party at all -- only require a non-empty
    -- party for a battle (POKETRAINER) ghost.
    local ghostType = (serverGhost.ghostType == "friendly") and "friendly" or "trainer"
    if ghostType ~= "friendly" and (type(serverGhost.party) ~= "table" or #serverGhost.party == 0) then
      return false
    end
    -- nearbyMapIds queries the current map PLUS every directly-connected
    -- neighbor (so the server can answer in one round trip), but a ghost
    -- from a neighboring map must only ever be spawned on ITS OWN map --
    -- spawning it here (on forMapId) would place it using x/y coordinates
    -- that were never meant for this map, and the same ghost would then
    -- appear a second time (wrongly) the moment the player actually walks
    -- onto the neighboring map and it's fetched again, correctly, there.
    -- Confirmed live: AAA/WILL (stored on ROUTE_1) also rendering in
    -- PALLET_TOWN/VIRIDIAN_CITY, both connected to ROUTE_1.
    if serverGhost.mapId ~= mapId then
      log("online ghost from '%s' skipped -- belongs on map %s, not %s",
        tostring(serverGhost.id), tostring(serverGhost.mapId), tostring(mapId))
      return false
    end
    if mapOrigins[mapId] and mapOrigins[mapId][serverGhost.id] then
      log("online ghost from '%s' skipped -- already present on map %s (local or earlier online spawn)",
        tostring(serverGhost.id), tostring(mapId))
      return false
    end
    -- Same-tile guard (client half -- see mapTiles' own comment): the
    -- server already picks at most one ghost per exact tile among what IT
    -- stores (worker.js's ROW_NUMBER() partition), but a LOCAL shared-file
    -- ghost is invisible to that query -- this catches a local ghost and a
    -- downloaded ghost landing on one square. Different case from the
    -- mapOrigins check just above (same sender via two channels); this is
    -- two DIFFERENT senders sharing coordinates.
    do
      local tileKey = tostring(serverGhost.x) .. "," .. tostring(serverGhost.y)
      if mapTiles[mapId] and mapTiles[mapId][tileKey] then
        log("online ghost from '%s' skipped -- tile %s already occupied on map %s",
          tostring(serverGhost.id), tileKey, tostring(mapId))
        return false
      end
    end
    -- Identity MUST change when the sender re-sends, or their brand-new
    -- ghost inherits the previous one's defeat flag and spawns already
    -- beaten -- it won't hunt you, it just stands there replaying an
    -- after-battle line (confirmed by inspection, v0.9.0-0.9.2). Local mode
    -- never had this: a local send takes a fresh incrementing s.nextId, so
    -- each send is genuinely a new encounter (the v0.7.2 rule). The online
    -- id was derived from the sender's origin ALONE, which never changes,
    -- so it silently broke that rule. Folding in the server's uploadedAt
    -- restores it: same upload -> same id (defeat state persists correctly
    -- across sessions), new upload -> new id (correctly undefeated).
    -- %.0f, not tostring(): Lua 5.1 renders a 13-digit ms timestamp in
    -- scientific notation, which would collapse distinct sends together.
    local safeId = sanitizeId(serverGhost.id)
    local stamp = tonumber(serverGhost.uploadedAt)
    local uid = "online_" .. safeId
    if stamp then uid = uid .. "_" .. string.format("%.0f", stamp) end
    -- Never trust the wire's sprite/pic (see SPRITE_PAIR_OK/GEN2_SPRITE_PAIR_OK):
    -- the pair is honoured only if it exactly matches a combination we ship
    -- ourselves, so neither half can be an arbitrary sprite id, asset path,
    -- or (Gen 2) trainer class id. Ghosts uploaded before v0.11.0 with one
    -- of the two corrected pairings (BIRD_KEEPER/LASS) no longer match and
    -- simply fall back to the default look.
    local sprite, pic
    if IS_GEN2 then
      sprite, pic = GEN2_PLAYER_SPRITE, GEN2_PLAYER_CLASS
      if type(serverGhost.sprite) == "string" and type(serverGhost.pic) == "string"
        and GEN2_SPRITE_PAIR_OK[serverGhost.sprite .. "|" .. serverGhost.pic] then
        sprite, pic = serverGhost.sprite, serverGhost.pic
      end
    else
      sprite, pic = PLAYER_SPRITE, PLAYER_PIC
      if type(serverGhost.sprite) == "string" and type(serverGhost.pic) == "string"
        and SPRITE_PAIR_OK[serverGhost.sprite .. "|" .. serverGhost.pic] then
        sprite, pic = serverGhost.sprite, serverGhost.pic
      end
    end
    local rec = {
      id = uid,
      origin = uid,
      sourceOrigin = serverGhost.id,  -- raw origin, for mapOrigins dedup (see above) -- NOT for trainer/flag namespacing
      name = serverGhost.name or "RIVAL",
      mapId = mapId,
      x = serverGhost.x, y = serverGhost.y, facing = serverGhost.facing,
      ghostType = ghostType,
      party = serverGhost.party,
      beforeText = serverGhost.beforeText,
      afterText = serverGhost.afterText,
      sprite = sprite,
      pic = pic,
      game = RECORD_GAME,
      -- Item id/qty are NOT re-validated here the way sprite/pic are --
      -- Bag.add itself does NOT check that an id is a real known item (it
      -- falls back to a generic pocket for anything unrecognised and
      -- writes it into save.inventory regardless), so engageFriendlyGhost
      -- is where the real isGiftableItem() re-check happens, right before
      -- the actual grant -- see its own comment.
      giftItem = ghostType == "friendly" and serverGhost.giftItem or nil,
      giftQty = ghostType == "friendly" and serverGhost.giftQty or nil,
    }
    if IS_GEN2 then return spawnOneGen2Ghost(game, w, mapId, rec) end
    return spawnOneGhost(game, w, mapId, rec)
  end

  -- Called every ghostStep tick. Both jobs are one-at-a-time and short-lived
  -- (a single request each), so simple sequential polling is enough -- no
  -- need for a job queue.
  local function pollOnlineJobs(game)
    -- Reports are fire-and-forget: nothing in game depends on the result,
    -- so a failure is logged and dropped rather than retried. One at a
    -- time, drained in order, so a burst of encounters can't spawn a
    -- thread per report.
    if pendingReport then
      local ok, result = pcall(Fetch.poll, pendingReport)
      if ok and result and result.status ~= "pending" then
        if result.status ~= "ok" then
          log("online report failed (dropped): %s", tostring(result.err))
        end
        pcall(Fetch.release, pendingReport)
        pendingReport = nil
      end
    end
    if not pendingReport and #reportQueue > 0 then
      local url = table.remove(reportQueue, 1)
      local ok, jobId = pcall(function() return Fetch.get(url, { maxSeconds = 15 }) end)
      if ok and jobId then pendingReport = jobId end
    end

    if pendingStats then
      local ok, result = pcall(Fetch.poll, pendingStats)
      if ok and result and result.status ~= "pending" then
        pcall(Fetch.release, pendingStats)
        pendingStats = nil
        local msg
        if result.status == "ok" then
          local decoded = select(2, pcall(Json.decode, result.body))
          if type(decoded) ~= "table" or not decoded.ok then
            msg = "Couldn't read the\nreport."
          elseif not decoded.found then
            msg = "You have no ghost\nout there right now.\fSend one from a\nroute or dungeon!"
          else
            local enc = tonumber(decoded.encounters) or 0
            local friendlyType = decoded.ghostType == "friendly"
            if enc == 0 then
              msg = ("Your ghost waits on\n%s.\fNobody has found it\nyet."):format(tostring(decoded.mapId or "?"))
            elseif friendlyType then
              -- No win/loss concept for a friendly ghost -- just how many
              -- distinct people have stopped to talk to it (see
              -- engageFriendlyGhost's own "encounter" report, once per new
              -- visitor).
              msg = ("Your ghost on %s\nhas been visited by\n%d trainer(s)!"):format(
                tostring(decoded.mapId or "?"), enc)
            else
              local won = tonumber(decoded.wins) or 0
              local lost = tonumber(decoded.losses) or 0
              msg = ("Your ghost on %s\nhas been found by\n%d trainer(s)!"):format(
                tostring(decoded.mapId or "?"), enc)
              msg = msg .. ("\fIt won %d\nand lost %d."):format(won, lost)
            end
          end
        else
          log("ghost report fetch failed: %s", tostring(result.err))
          msg = "Couldn't reach the\nnetwork."
        end
        pcall(function() game.stack:push(TextBox.new(game, msg)) end)
      end
    end

    if pendingUpload then
      local ok, result = pcall(Fetch.poll, pendingUpload.jobId)
      if ok and result and result.status ~= "pending" then
        if result.status == "ok" then
          log("online upload finished: %s", tostring(result.body))
          -- HTTP succeeding just means we got a response -- the server can
          -- still reject the payload (e.g. validation failure), so check the
          -- body's own {ok:true/false} rather than trusting a 200 alone.
          local decoded = select(2, pcall(Json.decode, result.body))
          if type(decoded) == "table" and decoded.ok == true then
            game.stack:push(TextBox.new(game, "Ghost uploaded\nonline!"))
          else
            -- Reached the server but it said no (or sent something we
            -- couldn't parse) -- surface it instead of failing silently.
            local why = type(decoded) == "table" and decoded.error or result.body
            log("online upload rejected by server: %s", tostring(why))
            notifyUploadProblem(game, "Server rejected\nthe ghost.", why)
          end
        else
          log("online upload failed: %s", tostring(result.err))
          notifyUploadProblem(game, "Ghost upload\nfailed.", result.err)
        end
        pcall(Fetch.release, pendingUpload.jobId)
        pendingUpload = nil
      end
    end

    if pendingNearby then
      local ok, result = pcall(Fetch.poll, pendingNearby.jobId)
      if ok and result and result.status ~= "pending" then
        local forMapId = pendingNearby.forMapId
        pcall(Fetch.release, pendingNearby.jobId)
        pendingNearby = nil
        if result.status == "ok" then
          local w = world()
          local cur = w and w:current()
          if not (cur and cur.mapId == forMapId) then
            log("online nearby result for %s arrived after leaving -- discarded", tostring(forMapId))
          else
            local okDecode, decoded = pcall(Json.decode, result.body)
            if okDecode and type(decoded) == "table" and decoded.ok and type(decoded.ghosts) == "table" then
              local n = 0
              for _, g in ipairs(decoded.ghosts) do
                if spawnOnlineGhost(game, w, forMapId, g) then n = n + 1 end
              end
              -- Always log, including the returned-0 / spawned-0 cases: a
              -- silent no-op here is indistinguishable from "the feature is
              -- broken". "returned" vs "spawned" separates a server-side
              -- miss (no match for these maps + this password) from a
              -- client-side skip (dedup against a local copy, or a
              -- malformed record), which are very different problems.
              log("online: server returned %d ghost(s), spawned %d on map %s",
                #decoded.ghosts, n, tostring(forMapId))
            else
              log("online nearby response invalid, ignoring: %s", tostring(result.body))
            end
          end
        else
          log("online nearby fetch failed: %s", tostring(result.err))
        end
      end
    end
  end

  -- =====================================================================
  -- GEN 1 NICKNAME PATCH: battle.started fires once the whole battle object
  -- -- including a fully-built self.enemyParty -- already exists (it's
  -- emitted right at the end of BattleState:enter, well after newTrainer's
  -- construction), and BEFORE any message that could reference a mon's name
  -- is queued. So this is the one seam where a ghost's mons can get their
  -- nickname set for real, since neither Pokemon.new nor
  -- BattleState.newTrainer accept or read one at construction time (see
  -- injectTrainer's own comment). ev.trainerId is the class id the engine's
  -- own event payload gives us; injectedRecs maps that back to the rec whose
  -- party carries the sender's actual nicknames (rec.party[i] and
  -- enemyParty[i] line up 1:1 -- both are built in the same order from the
  -- same source list, skipping nothing since every stored party mon always
  -- has species+level). No-op on Gen 2 (different trainerId shape entirely,
  -- so the lookup just misses) -- that side gets nicknames through Mon.new's
  -- own opts.nickname instead, see gen2PartyRoster/wrapGen2Party.
  pcall(function()
    mod.events:on("battle.started", function(ev)
      local trainerId = ev and ev.trainerId
      local rec = trainerId and injectedRecs[trainerId]
      local enemyParty = rec and ev.battle and ev.battle.enemyParty
      if type(enemyParty) ~= "table" then return end
      local n = 0
      for i, mon in ipairs(enemyParty) do
        local src = rec.party and rec.party[i]
        local nick = src and src.nickname
        if type(nick) == "string" and nick ~= "" then
          mon.nickname = nick
          n = n + 1
        end
      end
      if n > 0 then log("nicknamed %d mon(s) for ghost '%s'", n, tostring(rec.name)) end
    end)
  end)

  -- =====================================================================
  -- GEN 2 EVENT WIRING: battle result + engagement detection. Unlike Gen 1
  -- (which has to infer a result from ctx.lastCheck / poll scriptRunning()),
  -- Gen 2's battle.ended event carries the outcome directly, and
  -- world.trainer_engaged fires for BOTH the eyesight cone and a manual
  -- A-press against a trainer object -- so this is simpler than Gen 1's
  -- awaitingResult/resolvePendingResults machinery, not a port of it.
  -- =====================================================================
  if IS_GEN2 then
    local gen2PendingGhost  -- the gen2Ghosts[] entry whose battle is currently in flight
    -- Money-once fix (see Gen 1's injectTrainer for the equivalent): Gen 2
    -- can't just zero out baseMoney for a rematch the way Gen 1 does,
    -- because baseMoney lives on the SHARED class record (BEAUTY, GRUNTM,
    -- ...) that real cart trainers of that class use too -- zeroing it
    -- would silence THEIR payouts as well. So instead: snapshot the
    -- player's money the instant a REPEAT engagement starts (only when
    -- isDefeated is already true, i.e. this is a rematch, not the first
    -- fight), and if the ghost loses again, roll the money back to that
    -- snapshot right after the engine's own native payout has already
    -- landed. Nothing else touches money mid-battle in this engine, so a
    -- plain before/after snapshot is exact -- no need to reverse-engineer
    -- Prize.ComputeTrainerReward's own formula.
    local gen2RematchMoneyBefore

    pcall(function()
      mod.events:on("world.trainer_engaged", function(ev)
        local member = ev and ev.partyIndex
        if not member then return end
        for _, ghost in pairs(gen2Ghosts) do
          if ghost.trainerStruct.member == member then
            gen2PendingGhost = ghost
            gen2RematchMoneyBefore = nil
            if isDefeated(liveGame, ghost.rec) then
              local sv = liveGame and liveGame.save
              local p = sv and type(sv.player) == "table" and sv.player
              if p and type(p.money) == "number" then gen2RematchMoneyBefore = p.money end
            end
            log("gen2 ghost '%s' engaged (%s)%s", tostring(ghost.rec.name),
              (ev and ev.sight) and "sight" or "interact",
              gen2RematchMoneyBefore and " [rematch, money snapshotted]" or "")
            -- Battle is committed the moment the engine reports this, same
            -- "honest encounter" moment Gen 1 uses. No-op for a local ghost.
            queueOnlineReport(ghost.rec, "encounter")
            break
          end
        end
      end)
    end)

    pcall(function()
      mod.events:on("battle.ended", function(ev)
        local ghost = gen2PendingGhost
        local moneyBefore = gen2RematchMoneyBefore
        gen2PendingGhost = nil
        gen2RematchMoneyBefore = nil
        if not ghost then return end
        local result = ev and ev.result
        if result ~= "win" then
          log("gen2 ghost '%s' survived (result=%s)", tostring(ghost.rec.name), tostring(result))
          return  -- ghost wins/keeps hunting; nothing reported (see Gen 1's same 0.12.0 rule)
        end
        -- Beaten. The engine can't record that for us (no `event` on the
        -- trainer struct, deliberately -- see the GEN 2 spawning section
        -- comment) -- both halves are ours: the flag, then re-deriving what
        -- the ghost becomes from it.
        local sv = liveGame and liveGame.save
        if sv then
          local ok, err = pcall(function() Flags.set(sv, defeatFlagName(ghost.rec)) end)
          log("gen2 ghost '%s' defeated -- Flags.set ok=%s err=%s",
            tostring(ghost.rec.name), tostring(ok), tostring(err))
        end
        if moneyBefore then
          local p = sv and type(sv.player) == "table" and sv.player
          if p and type(p.money) == "number" then
            log("gen2 ghost '%s' was a REMATCH -- rolling money back %d -> %d (no repeat payout)",
              tostring(ghost.rec.name), p.money, moneyBefore)
            p.money = moneyBefore
            -- Explain the rollback through the ghost's OWN after-battle
            -- text rather than a separately-timed TextBox -- this rides the
            -- exact same native display the real after-battle line already
            -- uses (trainertext(WIN) reading texts[winKey], via the same
            -- SEEN_BY_TRAINER_SCRIPT tail that plays after every native
            -- battle), so there's no guessing about when the battle screen
            -- has actually closed. If the sender wrote a real after-battle
            -- line, the note appears as a second PAGE after it (\012, the
            -- Gold text table's own page break -- confirmed against
            -- gold/data/generated/text.lua); if they didn't (this ghost's
            -- winText is still just the generic "has nothing more to say"
            -- fallback from gen2InjectGhost), the note REPLACES that filler
            -- outright rather than stacking a second, redundant page.
            local okText, ow = pcall(function() return mod.world:overworld() end)
            local texts = okText and ow and ow.text
            local winKey = ghost.trainerStruct and ghost.trainerStruct.winText
            if type(texts) == "table" and type(winKey) == "string" then
              local note = "This ghost was\nalready defeated\nbefore -- no repeat\nmoney reward."
              local hasRealAfterText = type(ghost.rec.afterText) == "string" and ghost.rec.afterText ~= ""
              if hasRealAfterText and type(texts[winKey]) == "string" and texts[winKey] ~= "" then
                texts[winKey] = texts[winKey] .. "\012" .. note
              else
                texts[winKey] = note
              end
            end
          end
        end
        refreshGen2Ghost(liveGame, ghost)
        queueOnlineReport(ghost.rec, "loss")
      end)
    end)
  end

  -- =====================================================================
  -- Battle trigger: watch the overworld each input step. An UNDEFEATED
  -- ghost can be engaged two ways -- GHOST SIGHT (spots the player and
  -- forces the approach) or facing+interacting with it directly (see
  -- interactEngageUndefeated) -- both run the same battleSequenceRows. A
  -- DEFEATED ghost only responds to facing+interact (see engageGhost). No
  -- map-script registry, no talk lookup, no trainer-object detection -- all
  -- under our control.
  --
  -- Position is read LIVE via mod.world:npc(mapId, name):position() rather
  -- than the ghost's captured x/y, since a GHOST SIGHT ghost that's mid-walk
  -- (or has walked up and stopped) may no longer be at its spawn tile.
  --
  -- Re-triggering is locked to the exact tile last engaged from until the
  -- player faces away, so one approach/interaction = one script fired.
  -- =====================================================================
  local engagedKey  -- "mapId:x:y" we last engaged from; cleared when facing away
  local warnedNoInput = false

  -- Best-effort read of "was the interact button just pressed". Tries the two
  -- plausible read paths (game.input / mod.input); returns nil (unsupported,
  -- not "not pressed") if neither works, so callers can fall back safely.
  local function interactPressed(game)
    local sources = {}
    if game and game.input then sources[#sources + 1] = game.input end
    if mod.input then sources[#sources + 1] = mod.input end
    for _, inp in ipairs(sources) do
      local ok, pressed = pcall(function() return inp:wasPressed("a") end)
      if ok then return pressed == true end
    end
    return nil
  end

  -- Shared row-builder: fight this ghost, sandwiching the sending player's
  -- own before/after text (see sendSelf) around it via 'show_text' (confirmed
  -- to accept a literal string, not just a symbolic TEXT_ constant --
  -- Commands.show_text: "literal string fallback for hand-ported scripts"),
  -- and remember a win. start_battle itself sets `ctx.lastCheck = (result ==
  -- "win")` the instant it returns (confirmed from source, no separate
  -- check_battle_result row needed), so jump_if_false skips the set_flag row
  -- on a loss/flee -- matching real trainer semantics: you don't "defeat" a
  -- trainer you lost to or ran from, so it should keep hunting you. Both
  -- GHOST SIGHT (sightStep) and the defeated-ghost interact path
  -- (engageGhost) build their scripts around this same shared tail.
  --
  -- Money is handled entirely by the engine's own trainer-victory code now
  -- (see baseMoneyForPic/injectTrainer) -- no custom give_money/show_text
  -- row needed here at all, just the win-flag bookkeeping this always had.
  --
  -- Sender-authored dialogue (rec.beforeText/afterText) is a bare literal
  -- string with no speaker tag of its own, unlike a vanilla trainer's own
  -- battle-end line (BattleState prefixes THAT with "<Name>: " itself, but
  -- only for its own endBattleText field -- our before/after lines go
  -- through a plain overworld show_text, which has no such mechanism, so
  -- the tag has to be added here or not at all).
  local function sayAs(rec, text)
    return (rec.name or "RIVAL") .. ": " .. text
  end

  local function battleSequenceRows(rec, class)
    local rows = {}
    if rec.beforeText then rows[#rows + 1] = { "show_text", sayAs(rec, rec.beforeText) } end
    rows[#rows + 1] = { "start_battle", "trainer", class, 1 }
    rows[#rows + 1] = { "jump_if_false", "ssn_no_win" }
    rows[#rows + 1] = { "set_flag", defeatFlagName(rec) }
    rows[#rows + 1] = { "label", "ssn_no_win" }
    if rec.afterText then rows[#rows + 1] = { "show_text", sayAs(rec, rec.afterText) } end
    return rows
  end

  -- Manual interact -- only ever reached (see ghostStep) for a ghost that's
  -- already DEFEATED (an undefeated ghost's interact goes to
  -- interactEngageUndefeated instead). Default: just replay its
  -- after-battle line (or a fallback line if it was sent with none).
  -- REPEATABLE GHOST BATTLES: run the full battle sequence again instead,
  -- exactly like the original encounter.
  local function engageGhost(game, rec, mapId, gx, gy, key)
    local class = injectTrainer(game, rec)  -- (re)inject in case the record changed
    if not class then engagedKey = key; return end
    local repeatable = mod.options:get("ghost_repeatable") == true
    local rows
    if repeatable then
      rows = battleSequenceRows(rec, class)
    else
      local line = (rec.afterText and sayAs(rec, rec.afterText))
        or (("%s has nothing\nmore to say."):format(rec.name or "RIVAL"))
      rows = { { "show_text", line } }
    end
    local ok, err = mod.world:queueScript(rows)
    if ok then
      engagedKey = key
      log("interacted with defeated ghost '%s' (%s) at %s:%s:%s (repeatable=%s)",
        rec.name or "?", class, mapId, gx, gy, tostring(repeatable))
    else
      log("queueScript refused (%s) -- will retry", tostring(err))
    end
  end

  -- FRIENDLY ghost interact -- no battle, no script, just a direct TextBox
  -- (and, on the first visit only, a gift item). Shared between both
  -- generations (called from ghostStep's facing+interact loop on Gen 1 and
  -- from a mirrored poll in gen2Step on Gen 2) since the logic itself has
  -- nothing generation-specific in it beyond Bag/Flags, which already are.
  --
  -- ONE flag (friendlyMetFlagName) does double duty: which dialogue line to
  -- show, AND whether the item's already been claimed by this save -- the
  -- maintainer's decision was a ONE-TIME gift tracked per receiving save,
  -- and "have we met" is exactly that same one-time transition. If the
  -- item exists but the receiving save's bag is full, the flag is
  -- deliberately NOT set -- the visit doesn't "complete" (same as a
  -- vanilla NPC's own "make room" gift gate), so the next interact retries
  -- instead of silently losing the gift forever.
  local function engageFriendlyGhost(game, rec, mapId, gx, gy, key)
    engagedKey = key
    local sv = game and game.save
    if hasMetFriendly(game, rec) then
      local line = rec.afterText and sayAs(rec, rec.afterText)
        or (("%s has nothing\nmore to say."):format(rec.name or "RIVAL"))
      game.stack:push(TextBox.new(game, line))
      log("talked to friendly ghost '%s' (return visit) at %s:%s:%s", rec.name or "?", mapId, gx, gy)
      return
    end
    -- GHOST REPORT visibility: report once per new (per-receiving-save)
    -- visitor, same "commit at the moment of first real engagement" rule
    -- the trainer path uses for its own "encounter" event -- no-op for a
    -- local (non-downloaded) ghost. A friendly ghost has no win/loss
    -- concept, so this is the only event it ever reports.
    queueOnlineReport(rec, "encounter")
    local line = rec.beforeText and sayAs(rec, rec.beforeText)
      or (("Hi, I'm %s!"):format(rec.name or "RIVAL"))
    local shouldMarkMet = true
    -- Re-validate the gift item against isGiftableItem here, not just
    -- trust rec.giftItem -- Bag.add itself does NOT check that an id is a
    -- real known item (see its own source), so a downloaded ghost's
    -- giftItem is exactly as untrusted as sprite/pic ever were and could
    -- otherwise smuggle a key item, an HM, or a bogus id straight into a
    -- receiving save's bag.
    local giftItemDef = rec.giftItem and game.data.items and game.data.items[rec.giftItem]
    if rec.giftItem and not isGiftableItem(rec.giftItem, giftItemDef) then
      log("friendly ghost '%s' gift item '%s' failed re-validation -- dropped",
        rec.name or "?", tostring(rec.giftItem))
      rec.giftItem = nil
    end
    if rec.giftItem then
      local qty = math.max(1, math.min(99, math.floor(tonumber(rec.giftQty) or 1)))
      local gave = false
      if sv then pcall(function() gave = Bag.add(sv, rec.giftItem, qty, game.data) end) end
      if gave then
        local itemName = (giftItemDef and giftItemDef.name) or rec.giftItem
        line = line .. ("\fYou received\n%s x%d!"):format(itemName, qty)
        log("friendly ghost '%s' gave %s x%d to this save", rec.name or "?", rec.giftItem, qty)
      else
        line = line .. "\fBut your bag is\nfull!\fCome back once\nyou have room."
        shouldMarkMet = false
        log("friendly ghost '%s' item grant FAILED (bag full?) -- not marking met, will retry",
          rec.name or "?")
      end
    end
    if shouldMarkMet and sv then
      pcall(function() Flags.set(sv, friendlyMetFlagName(rec)) end)
    end
    game.stack:push(TextBox.new(game, line))
    log("talked to friendly ghost '%s' (first meeting) at %s:%s:%s", rec.name or "?", mapId, gx, gy)
  end

  -- GHOST SIGHT: the vanilla trainer mechanic, v2 -- rebuilt around the
  -- engine's OWN scripted-approach primitives instead of a hand-rolled
  -- per-tick walk. Live test of the per-tick version (v0.4.1) surfaced two
  -- real problems: (1) the player was never actually frozen during the "!"
  -- beat, so simply stepping away avoided the whole encounter, and (2) once
  -- the ghost gave up mid-chase it ended up off in some arbitrary spot,
  -- misaligning its own sight line so it silently never re-triggered.
  --
  -- Fix: the "!", the sting, the walk-up, AND the battle are now ONE single
  -- queued script (`move_npc_to` BFS-paths + `start_battle`), not four
  -- separate things we stitch together ourselves. This matters because:
  --   - `move_npc_to` and `start_battle` both YIELD the script runner
  --     (confirmed from source), and `queueScript` refuses a second script
  --     while one is running -- which is exactly the mechanism vanilla
  --     trainer/cutscene sequences use to make the player unable to just walk
  --     away mid-approach. We don't need to implement freezing ourselves; the
  --     engine already does it for any running script, we just need to make
  --     the whole sequence ONE script instead of our own per-tick loop that
  --     left gaps for the player to move in between.
  --   - `move_npc_to` does real BFS pathing (obstruction-aware), not a blind
  --     straight walk, so it's far more likely to actually reach the player.
  --   - The ghost has a FIXED facing (captured at send time) and only watches
  --     the single line of tiles directly ahead of it -- not chase's
  --     "same row or column, either direction" sweep, and it does NOT re-aim
  --     mid-approach (that's what makes chase feel like stalking).
  --
  -- Re-arming: `world:current()` resolving is NOT proof the sequence is
  -- over -- it turns out the overworld state stays on top of the stack
  -- through the whole `move_npc_to` walk-up too (only `start_battle`
  -- actually pushes something else), so `ghostStep`/`sightStep` DO get
  -- reached mid-walk-up, repeatedly. Confirmed via `scriptRunning()`
  -- (the engine's own `ScriptRunner:isRunning()`, reached through the
  -- public `WorldAPI:overworld()`) instead of trusting that heuristic.
  local SIGHT_RANGE = 5
  local SIGHT_POLL_INTERVAL = 0.35
  local SIGHT_POST_SEQUENCE_GRACE = 2.0  -- avoids instantly re-spotting you at point-blank range right as you return
  local SIGHT_DIR_DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local sightCooldown = {}   -- npcName -> seconds remaining before the next check
  local sightAlerted = {}    -- npcName -> true while its approach+battle script is (believed) in flight
  local sightFacing = {}     -- npcName -> fixed lowercase direction, captured once

  -- Ground-truth "is a script genuinely still running" check, via the
  -- engine's own ScriptRunner (confirmed source: WorldAPI:queueScript does
  -- `if ow.runner:isRunning() then return nil, "a script is already
  -- running" end`). WorldAPI:overworld() is a real public method (scans
  -- game.stack.states for the topmost isOverworld entry), so this is
  -- reachable without private-field poking -- still an engine-internals
  -- reach-in (isRunning() itself isn't exposed via any documented mod.*
  -- surface), same category as Flags/SaveData.activeSlot elsewhere in this
  -- mod. pcall-guarded since none of this is a supported API.
  local function scriptRunning()
    local ok, ow = pcall(function() return mod.world:overworld() end)
    if not (ok and ow and ow.runner) then return false end
    local ok2, running = pcall(function() return ow.runner:isRunning() end)
    return ok2 and running == true
  end
  -- rec.id -> the rec itself, between "we committed to a battle THIS
  -- session" and the result landing. Gated on this session rather than just
  -- reading the defeat flag, because a ghost beaten in an EARLIER session
  -- already has that flag set on load -- without this we'd re-report a win
  -- every time the player walked past an old, already-beaten ghost.
  --
  -- Holds the REC (not just `true`) specifically so resolution never needs
  -- to find the ghost on the current map again -- see resolvePendingResults
  -- for why that matters.
  local awaitingResult = {}

  -- Battle-result resolution -- trigger-agnostic (GHOST SIGHT and manual
  -- interact both commit a battle the same way, via awaitingResult, so both
  -- get resolved here the same way too). Once a battle we started is no
  -- longer actually running, the ghost's own current defeat state tells us
  -- the outcome.
  --
  -- Only a LOSS is ever reported (0.12.0). The server derives wins as
  -- encounters - losses, so anything we DON'T report -- including a battle
  -- the player quit out of -- counts as a win for the ghost. That's
  -- deliberate: walking out on a fight is conceding it, and the old scheme
  -- (report wins, derive losses) charged the ghost a loss every time a
  -- player rage-quit or crashed.
  --
  -- It also removes the fragile case entirely. A ghost only LOSES when the
  -- challenger wins, and that is precisely the outcome where the player is
  -- NOT warped away (losing sends them to their last heal point via
  -- OverworldState:afterBattle -> warpToHealPoint, confirmed from engine
  -- source). So the one report we must actually deliver now happens with
  -- the player standing still on the ghost's own map, instead of racing a
  -- map transition.
  --
  -- Still iterates awaitingResult ITSELF rather than being driven from
  -- ghostStep's current-map loop, and still runs before that loop's `list`
  -- early-out -- isDefeated() reads the engine's save Flags, which are
  -- save-global and map-independent, so this stays correct no matter where
  -- the player ends up.
  local function resolvePendingResults(game)
    if next(awaitingResult) == nil then return end
    if scriptRunning() then return end  -- still in flight, check again later
    -- Clearing entries during pairs() is allowed in Lua (only ADDING keys
    -- mid-traversal is undefined), and queueOnlineReport only appends to a
    -- separate queue, so nothing can grow this table from in here.
    for id, rec in pairs(awaitingResult) do
      awaitingResult[id] = nil
      if isDefeated(game, rec) then
        queueOnlineReport(rec, "loss")
      else
        log("ghost '%s' survived -- counts as its WIN (derived server-side, nothing sent)",
          tostring(rec.name or "?"))
      end
    end
  end

  local function sightStep(game, w, mapId, entry, cur, dt)
    local rec = entry.rec
    local name = entry.npcName
    sightCooldown[name] = (sightCooldown[name] or 0) - dt
    if sightCooldown[name] > 0 then return end
    sightCooldown[name] = SIGHT_POLL_INTERVAL

    if sightAlerted[name] then
      -- world:current() resolving again is NOT proof the sequence is over
      -- -- it stays true through the whole move_npc_to walk-up too, since
      -- that runs inside the SAME overworld state (only start_battle
      -- actually pushes something non-overworld onto the stack). Confirmed
      -- live: this used to fire on nearly every tick of the walk-up,
      -- producing dozens of harmless-looking "script already running" log
      -- lines. Ground-truth check via the engine's own ScriptRunner
      -- instead (result reporting itself is handled by
      -- resolvePendingResults, called once per tick from ghostStep --
      -- this block is purely about re-arming GHOST SIGHT's own detection).
      if scriptRunning() then return end
      sightAlerted[name] = false
      sightCooldown[name] = SIGHT_POST_SEQUENCE_GRACE
      return
    end

    local handle
    local ok = pcall(function() handle = w:npc(mapId, name) end)
    if not (ok and handle and handle.position) then return end
    local gx, gy
    ok = pcall(function() gx, gy = handle:position() end)
    if not (ok and gx and gy) then return end

    local dir = sightFacing[name]
    if not dir then
      dir = string.lower(normalizeDir(rec.facing))
      sightFacing[name] = dir
    end
    local dx, dy = cur.x - gx, cur.y - gy
    local inLine, dist
    if dir == "up" then inLine, dist = (dx == 0 and dy < 0), -dy
    elseif dir == "down" then inLine, dist = (dx == 0 and dy > 0), dy
    elseif dir == "left" then inLine, dist = (dy == 0 and dx < 0), -dx
    else inLine, dist = (dy == 0 and dx > 0), dx end
    if not (inLine and dist >= 1 and dist <= SIGHT_RANGE) then return end

    local class = injectTrainer(game, rec)  -- (re)inject in case the record changed
    if not (class and entry.objIndex) then return end

    -- Target: one tile short of the player, on the side we're approaching
    -- from, so move_npc_to lands us adjacent rather than trying to stand on
    -- the player's own tile.
    local u = SIGHT_DIR_DELTA[dir]
    local tx, ty = cur.x - u[1], cur.y - u[2]

    -- Same shared battle sequence (dialogue + win-detection) as the
    -- defeated-ghost interact path -- see battleSequenceRows. Placed after
    -- the walk-up (move_npc_to) rather than before, so the ghost "says its
    -- line" once it's actually standing next to you, matching a normal
    -- trainer's intro text beat.
    local rows = {
      { "play_sound", "Trainer_Appeared" },
      { "emote", entry.objIndex, "shock", 60 },
      { "move_npc_to", entry.objIndex, tx, ty },
    }
    for _, row in ipairs(battleSequenceRows(rec, class)) do rows[#rows + 1] = row end

    local pok, qok, qerr = pcall(function() return w:queueScript(rows) end)
    if pok and qok then
      sightAlerted[name] = true
      log("ghost '%s' spotted the player (sight) -- scripted walk-up + battle queued", rec.name or "?")
      -- The battle is now committed (the script owns the stack and the
      -- player can't walk away), so this is the honest moment to call it an
      -- encounter -- reporting on the sight CHECK instead would count every
      -- time the ray happened to line up. No-op for a local ghost.
      queueOnlineReport(rec, "encounter")
      awaitingResult[rec.id] = rec
    else
      log("sight-triggered script refused (%s) -- will retry next time in sight", tostring(qerr))
    end
  end

  -- Manual interact trigger for an UNDEFEATED ghost -- same commit-then-
  -- report bookkeeping as sightStep (battleSequenceRows, "encounter"
  -- report, awaitingResult), just without the play_sound/emote/move_npc_to
  -- walk-up, since the player is already standing adjacent and facing it.
  -- Lets a player start the fight by talking to a ghost head-on instead of
  -- only ever being ambushed via its fixed sight line.
  local function interactEngageUndefeated(game, w, rec, name, mapId, gx, gy, key)
    local class = injectTrainer(game, rec)  -- (re)inject in case the record changed
    if not class then engagedKey = key; return end
    local rows = battleSequenceRows(rec, class)
    local pok, qok, qerr = pcall(function() return w:queueScript(rows) end)
    if pok and qok then
      engagedKey = key
      -- Also mark this ghost as sight-alerted, even though sight had
      -- nothing to do with this trigger -- it makes sightStep skip its own
      -- (redundant, would-be-refused) detection attempts for the same
      -- ghost while THIS battle is playing out, using the same
      -- scriptRunning()-gated re-arm it already has for its own triggers.
      sightAlerted[name] = true
      log("interacted with undefeated ghost '%s' (%s) at %s:%s:%s -- battle queued",
        rec.name or "?", class, mapId, gx, gy)
      -- Same "the battle is now committed" honesty rule as sightStep's own
      -- encounter report.
      queueOnlineReport(rec, "encounter")
      awaitingResult[rec.id] = rec
    else
      log("interact-triggered script refused (%s) -- will retry next time", tostring(qerr))
    end
  end

  local lastMapId  -- detects map transitions so we (re)spawn ghosts for the new map

  -- GEN 2's per-tick job: map-transition (re)spawn, poll online jobs, and
  -- re-derive ghost state when REPEATABLE/GHOST COLLISION actually change
  -- (so a flip applies live to ghosts already spawned, same "derived, never
  -- baked" rule as spawnOneGen2Ghost/refreshGen2Ghost). No sight/battle
  -- polling here at all -- World:checkTrainerBattle (engine-driven) and the
  -- GEN 2 EVENT WIRING above handle that entirely.
  local gen2LastMapId
  local gen2LastRepeatable, gen2LastCollision
  local function gen2Step(game, dt)
    local w = world()
    if not w then return end
    local cur = w:current()
    if not (cur and cur.mapId) then return end
    if cur.mapId ~= gen2LastMapId then
      gen2LastMapId = cur.mapId
      spawnGhostsForGen2Map(game, cur.mapId)
      startOnlineNearbyFetch(game, cur.mapId)
    end
    pollOnlineJobs(game)
    local rep = mod.options:get("ghost_repeatable") == true
    local col = mod.options:get("ghost_collision") == true
    if gen2LastRepeatable == nil then
      gen2LastRepeatable, gen2LastCollision = rep, col
    elseif rep ~= gen2LastRepeatable or col ~= gen2LastCollision then
      gen2LastRepeatable, gen2LastCollision = rep, col
      for _, ghost in pairs(gen2Ghosts) do refreshGen2Ghost(game, ghost) end
    end

    -- FRIENDLY ghosts: manual facing+interact poll. They're spawned as
    -- plain non-trainer objects with no scriptKey at all (see
    -- spawnOneGen2Ghost's friendly branch), so nothing native ever
    -- dispatches an interaction for them -- mirrors Gen 1's own
    -- facing+interact loop in ghostStep exactly, just using liveGen2Npc's
    -- id-based lookup (cellX/cellY, confirmed field names from the
    -- ssn_gen2_spike's own live status dump) instead of Gen 1's name-based
    -- mod.world:npc().
    local list = mapGhosts[cur.mapId]
    if list and #list > 0 and cur.x and cur.y then
      local d = cur.facing and FACE_DELTA[normalizeDir(cur.facing)]
      local fx, fy = d and (cur.x + d[1]) or nil, d and (cur.y + d[2]) or nil
      local facedRec, facedKey
      if fx then
        for _, entry in ipairs(list) do
          if entry.rec.ghostType == "friendly" and entry.npcId then
            local npc = liveGen2Npc(w, entry.npcId)
            if npc and npc.cellX == fx and npc.cellY == fy then
              facedRec = entry.rec
              facedKey = cur.mapId .. ":" .. fx .. ":" .. fy
              break
            end
          end
        end
      end
      if not facedRec then
        engagedKey = nil
      elseif facedKey ~= engagedKey then
        -- nil (no readable input source, see interactPressed's own
        -- comment) falls through to engage rather than getting stuck --
        -- matches Gen1's ghostStep, which only ever skips on an explicit
        -- false ("facing it, but hasn't pressed yet").
        if interactPressed(game) ~= false then
          engageFriendlyGhost(game, facedRec, cur.mapId, fx, fy, facedKey)
        end
      end
    end
  end

  local function ghostStep(game, dt)
    if IS_GEN2 then gen2Step(game, dt); return end
    local w = world()
    if not w then return end
    local cur = w:current()
    if not (cur and cur.mapId and cur.x and cur.y) then return end
    if cur.mapId ~= lastMapId then
      lastMapId = cur.mapId
      spawnGhostsForMap(game, cur.mapId)
      startOnlineNearbyFetch(game, cur.mapId)
    end

    -- Unconditional (a no-op instantly when online mode's never been on --
    -- both pending-job locals stay nil) so a fetch kicked off above can
    -- still resolve and populate mapGhosts even on a map with zero LOCAL
    -- ghosts, which would otherwise return early below before ever reaching
    -- a poll.
    pollOnlineJobs(game)

    -- Deliberately BEFORE the `list` early-out below, and independent of
    -- the current map: a battle the player LOST warps them off the ghost's
    -- map entirely, so anything gated on "the ghost is in this map's list"
    -- would never resolve it (see resolvePendingResults).
    resolvePendingResults(game)

    local list = mapGhosts[cur.mapId]
    if not list or #list == 0 then return end

    -- GHOST SIGHT is unconditional for every ghost that hasn't been defeated
    -- yet -- it's no longer an opt-in mode, it's just how a live ghost
    -- behaves. A defeated ghost is skipped here entirely; it stops hunting.
    -- A FRIENDLY ghost never hunts at all -- interact-only, see the facing
    -- loop below.
    for _, entry in ipairs(list) do
      if entry.rec.ghostType ~= "friendly" and not isDefeated(game, entry.rec) then
        sightStep(game, w, cur.mapId, entry, cur, dt or 0)
      end
    end

    -- Manual interact: while a ghost is UNDEFEATED, talking to it face-on is
    -- a second way to start the same battle GHOST SIGHT would (with its
    -- dialogue), not just a fallback for standing outside its fixed sight
    -- line. Once DEFEATED, interact is the ONLY way to engage it (see
    -- engageGhost): dialogue replay, or a full rematch if REPEATABLE GHOST
    -- BATTLES is on.
    local d = cur.facing and FACE_DELTA[normalizeDir(cur.facing)]
    local fx, fy = d and (cur.x + d[1]) or nil, d and (cur.y + d[2]) or nil

    local facedRec, facedName, facedKey, facedDefeated
    for _, entry in ipairs(list) do
      if fx then
        local handle, gx, gy
        local ok = pcall(function() handle = w:npc(cur.mapId, entry.npcName) end)
        if ok and handle and handle.position then
          local ok2 = pcall(function() gx, gy = handle:position() end)
          if ok2 and gx == fx and gy == fy then
            facedRec = entry.rec
            facedName = entry.npcName
            facedKey = cur.mapId .. ":" .. gx .. ":" .. gy
            facedDefeated = isDefeated(game, entry.rec)
          end
        end
      end
    end

    if not facedRec then engagedKey = nil; return end
    if facedKey == engagedKey then return end  -- already engaged from here; wait to face away

    local pressed = interactPressed(game)
    if pressed == nil then
      if not warnedNoInput then
        warnedNoInput = true
        log("no readable input source found -- ghost interact falls back to sight/walk-up trigger")
      end
    elseif not pressed then
      return  -- facing a ghost, but hasn't pressed the button yet
    end

    if facedRec.ghostType == "friendly" then
      engageFriendlyGhost(game, facedRec, cur.mapId, fx, fy, facedKey)
    elseif facedDefeated then
      engageGhost(game, facedRec, cur.mapId, fx, fy, facedKey)
    elseif sightAlerted[facedName] then
      -- A GHOST SIGHT sequence for this exact ghost is in flight, or just
      -- finished and hasn't been re-armed yet (see sightStep -- sightAlerted
      -- only clears once scriptRunning() confirms it's genuinely over).
      -- engagedKey alone doesn't cover this: sightStep's OWN trigger never
      -- sets engagedKey, only sightAlerted. Without this check, the exact
      -- button press that dismisses the ghost's final after-battle text
      -- (on a LOSS -- the engine warps the player to their last heal point
      -- from inside start_battle's own onFinish, but that happens AFTER our
      -- script's remaining rows already ran, so the player is often still
      -- standing right there facing the ghost when control returns) gets
      -- read as a fresh interact against the still-undefeated ghost,
      -- immediately queueing a genuine SECOND battle. Confirmed as the
      -- cause of the "lose, then get battled again right after respawn"
      -- report -- interact couldn't do this before it engaged undefeated
      -- ghosts at all (pre-0.10.2).
      log("interact ignored for '%s' -- a GHOST SIGHT sequence is still settling", tostring(facedName))
    else
      interactEngageUndefeated(game, w, facedRec, facedName, cur.mapId, fx, fy, facedKey)
    end
  end

  local okHook = pcall(function()
    mod.hooks:wrap("input.step", function(next_, game, dt)
      local result = next_(game, dt)
      pcall(ghostStep, game or liveGame, dt)
      return result
    end)
  end)
  log("input.step hook registered: %s", tostring(okHook))

  -- =====================================================================
  -- SEND: capture current position + party into the shared file, with an
  -- optional before/after-battle line the sending player writes themselves.
  -- One ghost per save: a new send REPLACES whatever this save already has
  -- out there (matched by origin), rather than accumulating alongside it.
  -- The old record's own id is gone, so any receiving save that had already
  -- beaten it starts fresh against the replacement -- a genuinely new ghost,
  -- correctly undefeated, not a revival of the old one.
  --
  -- Flow: "include dialogue?" (default NO) -> if yes, type the before-battle
  -- line -> "also add an after-battle line?" (default NO, only asked once
  -- the before-battle line is done) -> if yes, type it too. Declining the
  -- first question skips both entirely, exactly as asked. Confirming an
  -- EMPTY line at the naming screen (just pressing START without typing
  -- anything) is treated the same as not having one -- NamingScreen has no
  -- cancel path (B only backspaces), so this is the way out if the player
  -- changes their mind mid-typing.
  -- =====================================================================
  local function finalizeSend(game, cur, ghostType, beforeText, afterText, password, giftItem, giftQty)
    local s = loadStorage()
    local origin = saveOriginId(game)
    local replaced = 0
    for i = #s.ghosts, 1, -1 do
      if s.ghosts[i].origin == origin then
        table.remove(s.ghosts, i)
        replaced = replaced + 1
      end
    end
    local sprite, pic = selectedSprite()
    -- A FRIENDLY ghost has no battle at all, so no party is captured --
    -- Gen 2's party is captured already roster-shaped (see gen2PartyRoster)
    -- so it's battle-ready as stored; Gen 1 keeps the raw deepcopy it
    -- always used, converted at battle time by injectTrainer.
    local party
    if ghostType ~= "friendly" then
      party = IS_GEN2 and (gen2PartyRoster(game) or {}) or deepcopy(game.save.party)
    end
    local rec = {
      id        = s.nextId,
      origin    = origin,
      name      = playerName(game),
      mapId     = cur.mapId,
      x         = cur.x,
      y         = cur.y,
      facing    = cur.facing,
      ghostType = ghostType,
      party     = party,
      createdAt = os.time and os.time() or 0,
      beforeText = (beforeText ~= "" and beforeText) or nil,
      afterText  = (afterText ~= "" and afterText) or nil,
      sprite     = sprite,
      pic        = pic,
      password   = password or "",
      game       = RECORD_GAME,
      -- The item was already deducted from the SENDER's own bag the moment
      -- they picked it (see askLeaveItem) -- these two fields are just what
      -- a receiving save's first visit hands out, tracked per-receiving-save
      -- via a Flags marker so it's a one-time gift, not an unlimited one
      -- (maintainer's explicit call).
      giftItem  = giftItem,
      giftQty   = giftItem and giftQty or nil,
    }
    s.nextId = s.nextId + 1
    s.ghosts[#s.ghosts + 1] = rec
    -- Remembered per-save, not just attached to this one ghost, so a
    -- SEND-less later /nearby fetch (see startOnlineNearbyFetch) still
    -- knows this save's current password without re-sending.
    s.passwords[origin] = rec.password
    markDirty()
    log("captured ghost #%d '%s' type=%s at map=%s (%s,%s) party=%s dialogue=%s/%s sprite=%s gift=%s password=%s (replaced %d previous)",
      rec.id, rec.name, tostring(ghostType), tostring(rec.mapId), tostring(rec.x), tostring(rec.y),
      tostring(party and #party or 0), tostring(rec.beforeText ~= nil), tostring(rec.afterText ~= nil),
      tostring(sprite), tostring(giftItem or "none"), tostring(rec.password ~= ""), replaced)
    startOnlineUpload(game, rec)  -- no-op if OFFLINE MODE is on; async either way
    local msg = replaced > 0
      and "Your old ghost was\nrecalled.\f%s now waits\nhere for other\nworlds to find."
      or "Your ghost was\nsent to the void!\f%s now waits\nhere for other\nworlds to find."
    msg = msg:format(rec.name)
    -- Be explicit that a send with OFFLINE MODE on never leaves this
    -- machine. Without this the confirmation is identical either way, so
    -- testers reasonably assumed their ghost had gone out to other players
    -- when it had only ever been written to the local shared file (the
    -- single most likely reason a tester's upload "didn't work").
    if not onlineModeOn() then
      msg = msg .. "\fOFFLINE MODE is on,\nso this ghost stays\non this machine."
    end
    -- The overleveled-team heads-up now lives at the FRONT of sendSelf's
    -- flow instead (yes/no gate before any dialogue prompts), not appended
    -- here after the fact -- see sendSelf.
    game.stack:push(TextBox.new(game, msg))
  end

  -- Online password: a "room code" for ONLINE MODE, not a real credential
  -- (see README -- it travels in a plain-HTTP query string same as
  -- everything else this mod sends). A ghost uploaded with NO password is
  -- visible to every downloader; a ghost uploaded WITH a password is only
  -- visible to downloaders whose own remembered password matches exactly.
  -- Prefilled with whatever this save last set, so repeat sends can just
  -- say no and keep reusing it without retyping.
  local function askPassword(game, cur, ghostType, beforeText, afterText, giftItem, giftQty)
    local s = loadStorage()
    local current = s.passwords[saveOriginId(game)] or ""
    game.stack:push(TextBox.new(game, "Set an online\npassword?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then
          finalizeSend(game, cur, ghostType, beforeText, afterText, current, giftItem, giftQty)
          return
        end
        game.stack:push(NamingScreen.new(game, {
          title   = "ONLINE PASSWORD",
          maxLen  = DIALOGUE_MAX_LEN,
          default = current,
          onDone  = function(text) finalizeSend(game, cur, ghostType, beforeText, afterText, text, giftItem, giftQty) end,
        }))
      end, { defaultNo = true, noSound = true }))
    end))
  end

  -- Standalone Start Menu entry (see ui.start_menu.items below) -- lets a
  -- player who's only DOWNLOADING ghosts (not sending one) join or leave a
  -- private password pool without needing to go through SEND GHOST at all.
  -- Writes straight to the same per-save s.passwords entry askPassword
  -- reads/writes, so whichever was set last (here or at a send) wins.
  local function setOnlinePassword(game)
    local s = loadStorage()
    local origin = saveOriginId(game)
    local current = s.passwords[origin] or ""
    game.stack:push(NamingScreen.new(game, {
      title   = "ONLINE PASSWORD",
      maxLen  = DIALOGUE_MAX_LEN,
      default = current,
      onDone  = function(text)
        local st = loadStorage()
        st.passwords[origin] = text or ""
        markDirty()
        log("online password set directly (len=%d)", #(text or ""))
        local msg = (text and text ~= "")
          and "Online password set.\fOnline ghosts now only\nmatch that password."
          or "Online password\ncleared.\fYou'll see public\nghosts again."
        game.stack:push(TextBox.new(game, msg))
      end,
    }))
  end

  -- Start Menu -> GHOST REPORT. Deliberately a menu entry rather than an
  -- item (no inventory space to spare), an NPC (nothing to walk to, and
  -- runtime talk registration doesn't work in this engine) or a mod option
  -- (mod.options has no way to DISPLAY text at all -- toggles and numbers
  -- only). It sits next to SEND GHOST, which is the action that creates the
  -- thing being reported on, so it needs no explaining.
  local function showGhostReport(game)
    if not ONLINE_AVAILABLE then
      game.stack:push(TextBox.new(game, "Online features\naren't available\nin this build."))
      return
    end
    if not onlineModeOn() then
      game.stack:push(TextBox.new(game, "OFFLINE MODE is on.\fTurn it off in the\nmod options to track\nyour ghost."))
      return
    end
    if not startGhostReportFetch(game) then
      game.stack:push(TextBox.new(game, "Already checking...\nwait a moment."))
      return
    end
    -- The answer arrives asynchronously (see pollOnlineJobs); this is the
    -- "something is happening" beat so the menu doesn't look inert.
    game.stack:push(TextBox.new(game, "Checking the\nnetwork..."))
  end

  -- FRIENDLY ghosts only. Optional: leave one item, once, subtracted from
  -- the SENDER's own bag right here (the receiving save gets its copy
  -- later, on first interact -- see engageFriendlyGhost). Bag.order(save)
  -- is acquisition-ordered and already excludes badges; isGiftableItem
  -- further excludes key items and HMs (TMs ARE allowed, maintainer's
  -- explicit call). QuantityBox is a real, directly-pushable widget
  -- (confirmed from src/ui/QuantityBox.lua, same "construct and
  -- game.stack:push it" pattern as ListMenu/TextBox/ChoiceBox elsewhere in
  -- this file) -- new to this mod, like ListMenu was, so worth extra
  -- attention in testing.
  local function askLeaveItem(game, cur, ghostType, beforeText, afterText)
    game.stack:push(TextBox.new(game, "Leave an item for\nthem to find?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then
          askPassword(game, cur, ghostType, beforeText, afterText, nil, nil)
          return
        end
        local rows = {}
        pcall(function()
          for _, id in ipairs(Bag.order(game.save)) do
            local item = game.data.items and game.data.items[id]
            if isGiftableItem(id, item) then
              rows[#rows + 1] = { label = (item and item.name) or id,
                right = "x" .. tostring(game.save.inventory[id]), value = id }
            end
          end
        end)
        if #rows == 0 then
          game.stack:push(TextBox.new(game, "You have nothing\neligible to leave.", function()
            askPassword(game, cur, ghostType, beforeText, afterText, nil, nil)
          end))
          return
        end
        local picker
        picker = ListMenu.new(game, "LEAVE WHICH ITEM?", rows, {
          onChoose = function(item, m)
            m:close()
            local have = tonumber(game.save.inventory[item.value]) or 1
            game.stack:push(QuantityBox.new(game, {
              max = have, start = 1,
              onDone = function(qty)
                if not qty then
                  askPassword(game, cur, ghostType, beforeText, afterText, nil, nil)
                  return
                end
                Bag.remove(game.save, item.value, qty)
                log("gift item chosen for friendly ghost: %s x%d (deducted from sender's bag)",
                  item.value, qty)
                askPassword(game, cur, ghostType, beforeText, afterText, item.value, qty)
              end,
            }))
          end,
          onCancel = function()
            askPassword(game, cur, ghostType, beforeText, afterText, nil, nil)
          end,
        })
        game.stack:push(picker)
      end, { defaultNo = true, noSound = true }))
    end))
  end

  -- ChoiceBox renders only a YES/NO selector, no text of its own (confirmed
  -- from source) -- it's always paired with a preceding TextBox for the
  -- question, same as vrm_pokemon_bank's own RELEASE confirmation does.
  -- Wording and the NEXT step both branch on ghostType: a FRIENDLY ghost's
  -- "after" line is what plays on a RETURN visit (see engageFriendlyGhost),
  -- not an after-battle line, and it leads into askLeaveItem instead of
  -- straight to the password step.
  local function askAfterText(game, cur, ghostType, beforeText)
    local friendly = ghostType == "friendly"
    local prompt = friendly and "Add a different\nline for return\nvisits too?" or "Add an after-\nbattle line too?"
    local title = friendly and "RETURN VISIT LINE" or "AFTER-BATTLE LINE"
    local function proceed(afterText)
      if friendly then askLeaveItem(game, cur, ghostType, beforeText, afterText)
      else askPassword(game, cur, ghostType, beforeText, afterText, nil, nil) end
    end
    game.stack:push(TextBox.new(game, prompt, function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then proceed(""); return end
        game.stack:push(NamingScreen.new(game, {
          title   = title,
          maxLen  = DIALOGUE_MAX_LEN,
          default = "",
          onDone  = function(text) proceed(text) end,
        }))
      end, { defaultNo = true, noSound = true }))
    end))
  end

  local function askBeforeText(game, cur, ghostType)
    local title = (ghostType == "friendly") and "GREETING LINE" or "BEFORE-BATTLE LINE"
    game.stack:push(NamingScreen.new(game, {
      title   = title,
      maxLen  = DIALOGUE_MAX_LEN,
      default = "",
      onDone  = function(text) askAfterText(game, cur, ghostType, text) end,
    }))
  end

  local function sendSelf(game)
    local w = world()
    local cur = w and w:current()
    if not cur or not cur.mapId then
      game.stack:push(TextBox.new(game, "Can't send a ghost\nfrom here.\fTry again out in\nthe overworld."))
      return
    end
    local ghostType = ghostTypeMode()
    local friendly = ghostType == "friendly"
    -- A FRIENDLY ghost has no battle, so no party is needed to send one.
    if not friendly and (type(game.save.party) ~= "table" or #game.save.party == 0) then
      game.stack:push(TextBox.new(game, "You have no\nPOKéMON to send!"))
      return
    end
    local allowed
    if IS_GEN2 then
      -- Gold's own maps.lua carries the cart's own `environment` field --
      -- runtime check against real data instead of a maintained id list.
      -- POKETRAINER: route/cave/dungeon, no towns, no building interiors
      -- (confirmed: ROUTE 53 / CAVE 39 / DUNGEON 31 = 123 allowed of 368;
      -- blocked = TOWN 23 / GATE 24 / INDOOR 198). FRIENDLY additionally
      -- allows TOWN/GATE (maintainer's call: "allow towns and cities, but
      -- not indoors") since it never ambushes anyone.
      -- Root-caused live (2026-08-14, real player report): a diagnostic
      -- here once caught `game.data.maps` throwing "attempt to index field
      -- 'maps' (a nil value)" on Gold -- see dataTable's comment near the
      -- top of the file for why (a mod's own game.data doesn't get
      -- Gen2Compat's data.maps -> data.gen2Maps rename for free). Fixed by
      -- routing through dataTable; kept a lighter diagnostic here in case
      -- something else is still off.
      local ok, def = pcall(function() return dataTable(game, "maps")[cur.mapId] end)
      local env = ok and type(def) == "table" and def.environment
      if friendly then
        allowed = env == "ROUTE" or env == "CAVE" or env == "DUNGEON" or env == "TOWN" or env == "GATE"
      else
        allowed = env == "ROUTE" or env == "CAVE" or env == "DUNGEON"
      end
      if not allowed then
        log("gen2 send check failed: mapId=%s ghostType=%s ok=%s defType=%s env=%s def=%s",
          tostring(cur.mapId), ghostType, tostring(ok), type(def), tostring(env),
          type(def) == "table" and shallowDump(def) or tostring(def))
      end
    else
      allowed = (friendly and FRIENDLY_ALLOWED_MAPS or SEND_ALLOWED_MAPS)[cur.mapId] == true
    end
    if not allowed then
      log("send blocked: map %s is not an allowed send location (ghostType=%s)", tostring(cur.mapId), ghostType)
      game.stack:push(TextBox.new(game, "Unable to send ghost.\nInvalid location."))
      return
    end

    local function askDialogue()
      game.stack:push(TextBox.new(game, "Include dialogue\nwith this ghost?", function()
        game.stack:push(ChoiceBox.new(game, function(yes)
          if yes then
            askBeforeText(game, cur, ghostType)
          elseif friendly then
            askLeaveItem(game, cur, ghostType, "", "")
          else
            askPassword(game, cur, ghostType, "", "", nil, nil)
          end
        end, { defaultNo = true, noSound = true }))
      end))
    end

    -- LEVEL PROTECTION heads-up -- POKETRAINER only, a FRIENDLY ghost has no
    -- party/levels for this to mean anything about. FIRST in the sequence
    -- for the trainer case (2026-08-14 follow-up) so an overleveled sender
    -- sees it and gets a real yes/no choice to back out before investing
    -- any time in the dialogue prompts, rather than finding out as a
    -- footnote after everything's already typed. Reads game.save.party
    -- directly (not yet a captured rec at this point) -- works on both
    -- generations, since a save-party mon's `.level` exists either way.
    -- Uses filterCapForMap (REGION LOCK's own cap, honoring EXEMPT/BRANCH
    -- overrides) regardless of the SENDER's own GHOST LEVELING mode -- this
    -- warns about how a REGION LOCK viewer elsewhere would see the ghost,
    -- not about the sender's own setting.
    if not friendly then
      local cap = filterCapForMap(game, cur.mapId)
      if cap then
        local partyMax = 0
        for _, mon in ipairs(game.save.party) do
          if type(mon.level) == "number" and mon.level > partyMax then partyMax = mon.level end
        end
        if partyMax > cap then
          local warnMsg = ("Your team is above\nthis area's cap of\nLv%d.\fPlayers with LEVEL\nPROTECTION on won't\nsee this ghost.\fSend it anyway?"):format(cap)
          game.stack:push(TextBox.new(game, warnMsg, function()
            game.stack:push(ChoiceBox.new(game, function(yes)
              if yes then askDialogue()
              else game.stack:push(TextBox.new(game, "Ghost not sent.")) end
            end, { defaultNo = true, noSound = true }))
          end))
          return
        end
      end
    end

    askDialogue()
  end

  -- =====================================================================
  -- SILPH SCOPE NET hub menu (2026-08-14, replaces the three separate
  -- Start Menu rows this mod used to add). One row on the Start Menu now;
  -- selecting it opens a mod.ui.ListMenu with everything else inside.
  --
  -- ListMenu.new(game, title, items, opts) is a real, directly-pushable
  -- widget (confirmed from src/ui/ListMenu.lua: opaque full-screen state,
  -- B auto-pops itself and calls opts.onCancel, A calls opts.onChoose(item,
  -- self)) -- no mod.content.screens:register needed, same "construct and
  -- game.stack:push it" pattern this file already uses for TextBox/
  -- ChoiceBox/NamingScreen. Confirmed live for a scrollable sprite-style
  -- list only via the bundled example_dexnav mod and this project's own
  -- 2026-08-10 GHOST SPRITE spike (later reverted for an options dropdown,
  -- see gen1recomp-modding memory) -- this is the first time THIS mod ships
  -- it, so treat it as new/unverified until live-tested.
  --
  -- CONNECTION MODE and GHOST SPRITE are pickers: choosing either one pushes
  -- a NESTED ListMenu on top rather than acting immediately. Pressing B on
  -- that nested list pops it for free (ListMenu's own behavior) and reveals
  -- the hub underneath -- no manual back-navigation needed. After a pick,
  -- the hub's OWN items table is rebuilt in place (hubMenu.items = ...) so
  -- its "right" labels reflect the new value the moment you're back,
  -- without needing to reopen the whole menu.
  -- =====================================================================
  -- "CONNECTION MODE", then "GHOST MODE", were the original labels here --
  -- settled on plain "MODE" (2026-08-14) since the fuller versions plus the
  -- live value badly overlapped in the list (see fitRight/HUB_ROW_BUDGET
  -- above); "MODE" alone leaves the most room for that value.
  local function hubItems()
    return {
      { label = "MODE", right = fitRight("MODE", connectionModeLabel()), value = "mode" },
      { label = "SEND GHOST", value = "send" },
      { label = "GHOST SPRITE", right = fitRight("GHOST SPRITE", spriteLabel()), value = "sprite" },
      { label = "GHOST REPORT", value = "report" },
      { label = "GHOST TYPE", right = fitRight("GHOST TYPE", ghostTypeLabel()), value = "type" },
      { label = "ONLINE PASSWORD", value = "password" },
    }
  end

  local function openConnectionModePicker(game, hubMenu)
    local items = {
      { label = "LEVEL/ZONE", value = "filter" },
      { label = "SCALE TO PLAYER", value = "scale" },
      { label = "OFF", value = "off" },
    }
    local picker
    picker = ListMenu.new(game, "CONNECTION MODE", items, {
      onChoose = function(item, m)
        setConnectionMode(item.value)
        log("connection mode set to '%s'", tostring(item.value))
        m:close()
        hubMenu.items = hubItems()
      end,
    })
    game.stack:push(picker)
  end

  local function openSpritePicker(game, hubMenu)
    local list = IS_GEN2 and GEN2_GHOST_SPRITES or GHOST_SPRITES
    local items = { { label = IS_GEN2 and "CHRIS (DEFAULT)" or "RED (DEFAULT)", value = "" } }
    for _, s in ipairs(list) do items[#items + 1] = { label = s.label, value = s.key } end
    local picker
    picker = ListMenu.new(game, "GHOST SPRITE", items, {
      onChoose = function(item, m)
        setSpriteKey(item.value)
        log("ghost sprite set to '%s'", item.value ~= "" and item.value or "(default)")
        m:close()
        hubMenu.items = hubItems()
      end,
    })
    game.stack:push(picker)
  end

  local function openGhostTypePicker(game, hubMenu)
    local items = {
      { label = "POKETRAINER", value = "trainer" },
      { label = "FRIENDLY", value = "friendly" },
    }
    local picker
    picker = ListMenu.new(game, "GHOST TYPE", items, {
      onChoose = function(item, m)
        setGhostType(item.value)
        log("ghost type set to '%s'", tostring(item.value))
        m:close()
        hubMenu.items = hubItems()
      end,
    })
    game.stack:push(picker)
  end

  local function openHub(game)
    local menu
    menu = ListMenu.new(game, "SILPH SCOPE NET", hubItems(), {
      onChoose = function(item, m)
        if item.value == "send" then
          m:close(); sendSelf(game)
        elseif item.value == "report" then
          m:close(); showGhostReport(game)
        elseif item.value == "password" then
          m:close(); setOnlinePassword(game)
        elseif item.value == "mode" then
          openConnectionModePicker(game, m)
        elseif item.value == "sprite" then
          openSpritePicker(game, m)
        elseif item.value == "type" then
          openGhostTypePicker(game, m)
        end
      end,
    })
    game.stack:push(menu)
  end

  -- Add "SILPH NET" to the Start menu (decorate-after-next, like the
  -- Bank's PC-menu row) -- grouped next to the engine's own native "MODS"
  -- row (2026-08-14, maintainer's request) instead of tucked in wherever
  -- "EXIT" was assumed to be. Confirmed from src/ui/StartMenu.lua: the real
  -- native rows are POKéDEX/BAG/(party)/OPTION/LINK/**MODS** (gated on at
  -- least one discovered mod, opens the mod manager)/**QUIT** -- "EXIT" was
  -- never a real label here at all, so the old insertBefore(out, "EXIT",
  -- row) call was silently falling through to mod.ui's own append-if-not-
  -- found behavior this whole time (harmless, since it landed at the end
  -- either way, but not what it looked like it was doing). This mirrors the
  -- exact hand-rolled insert/fallback pattern gen1_cheat_menu already uses
  -- on this same install ("MOD MENUS -> Cheat Menu -> MODS") rather than
  -- trusting mod.ui.insertBefore's behavior for a label it's never been
  -- asked to match before.
  --
  -- Label shortened from "SILPH SCOPE NET" (2026-08-14 follow-up) -- 15
  -- characters stood out visibly longer than every native row it sits
  -- beside (POKéDEX/BAG/OPTION/LINK/MODS/QUIT are all 4-7). The hub SCREEN
  -- itself (openHub, below) keeps the full "SILPH SCOPE NET" as its own
  -- title -- that has a whole screen width to work with, not a menu row
  -- squeezed against five others.
  mod.hooks:wrap("ui.start_menu.items", function(next_, game, items)
    local out = next_(game, items)
    if type(out) ~= "table" then return out end
    local row = { label = "SILPH NET", onSelect = function() openHub(game) end }
    local function insertBeforeLabel(list, label)
      local decorated, inserted = {}, false
      for _, existing in ipairs(list) do
        local existingLabel = type(existing) == "table" and existing.label or nil
        if not inserted and existingLabel == label then
          decorated[#decorated + 1] = row
          inserted = true
        end
        decorated[#decorated + 1] = existing
      end
      return inserted and decorated or nil
    end
    local decorated = insertBeforeLabel(out, "MODS") or insertBeforeLabel(out, "QUIT")
    if decorated then return decorated end
    out[#out + 1] = row  -- neither anchor found -- last resort, bare append
    return out
  end)

  -- =====================================================================
  -- On load: confirm identity, inject trainers, index + spawn ghosts.
  -- =====================================================================
  mod.events:on("save.loaded", function()
    local game = liveGame
    if not game then
      log("save.loaded but no liveGame yet"); return
    end
    log("save.loaded: player=%s", shallowDump(game.save.player))
    log("save.loaded: meta=%s", shallowDump(game.save.meta))
    local okSlot, activeSlot = pcall(function() return SaveData.activeSlot(game.save.version) end)
    log("save.loaded: SaveData.activeSlot ok=%s value=%s", tostring(okSlot), tostring(activeSlot))
    log("save.loaded: identity=%s playerName=%s", tostring(saveOriginId(game)), playerName(game))
    local total = #loadStorage().ghosts
    local ghosts = activeGhosts(game)
    local defeatedCount = 0
    for _, rec in ipairs(ghosts) do
      if not IS_GEN2 then injectTrainer(game, rec) end  -- gen2's equivalent injection happens per-spawn, see gen2InjectGhost
      if isDefeated(game, rec) then defeatedCount = defeatedCount + 1 end
    end
    log("save.loaded: %d ghost(s) in file, %d active (not this save's own, generation=%d), %d already defeated",
      total, #ghosts, GENERATION, defeatedCount)
    local w = world()
    local cur = w and w:current()
    log("save.loaded: world:current -> %s", shallowDump(cur))
    if cur and cur.mapId then
      if IS_GEN2 then
        spawnGhostsForGen2Map(game, cur.mapId)
        gen2LastMapId = cur.mapId
      else
        spawnGhostsForMap(game, cur.mapId)
        lastMapId = cur.mapId
      end
      startOnlineNearbyFetch(game, cur.mapId)
    end
  end)

  -- Small read-only export so other mods (or a future UI) can list ghosts.
  mod.exports.listGhosts = function() return deepcopy(loadStorage().ghosts) end
  mod.exports.ghostCount = function() return #loadStorage().ghosts end

  log("loaded (v0.14.1, generation=%d)", GENERATION)
end
