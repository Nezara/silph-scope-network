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
-- Experimental ONLINE MODE (option, default OFF): additionally uploads a
-- sent ghost to a small server and downloads other players' ghosts near the
-- current map, via the engine's async GET-only Fetch module (src/net/
-- Fetch.lua) and JSON codec (src/link/Json.lua) -- no POST exists anywhere
-- in this engine's networking, so "upload" is a GET with a base64-encoded
-- payload. See README.md for the server side and full writeup.
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

-- Selectable ghost sprites (main.lua's GHOST SPRITE toggles below pick one of
-- these by option key; PLAYER_PIC/PLAYER_SPRITE above are the fallback when
-- none is toggled on). Each has real matching front art under
-- assets/generated/battle/trainers/, confirmed against trainers.lua's own
-- `pic` field for the equivalent vanilla trainer class -- same sprite/pic
-- pairing style used for every other trainer in this engine's own data.
local GHOST_SPRITES = {
  { key = "sprite_biker",        label = "GHOST SPRITE: BIKER",
    sprite = "SPRITE_BIKER",        pic = "assets/generated/battle/trainers/biker.png" },
  { key = "sprite_cooltrainerm",  label = "GHOST SPRITE: COOLTRAINER (M)",
    sprite = "SPRITE_COOLTRAINER_M", pic = "assets/generated/battle/trainers/cooltrainerm.png" },
  { key = "sprite_hiker",         label = "GHOST SPRITE: HIKER",
    sprite = "SPRITE_HIKER",        pic = "assets/generated/battle/trainers/hiker.png" },
  { key = "sprite_beauty",        label = "GHOST SPRITE: BEAUTY",
    sprite = "SPRITE_BEAUTY",       pic = "assets/generated/battle/trainers/beauty.png" },
  { key = "sprite_cooltrainerf",  label = "GHOST SPRITE: COOLTRAINER (F)",
    sprite = "SPRITE_COOLTRAINER_F", pic = "assets/generated/battle/trainers/cooltrainerf.png" },
  { key = "sprite_channeler",     label = "GHOST SPRITE: CHANNELER",
    sprite = "SPRITE_CHANNELER",    pic = "assets/generated/battle/trainers/channeler.png" },
}

-- sprite name -> its OWN pic, used to validate a DOWNLOADED ghost's look.
-- A downloaded ghost's sprite/pic arrive as arbitrary strings from another
-- player's client, so they are never trusted directly: the sprite name is
-- looked up here and the pic is taken from OUR copy, never from the wire.
-- Without this, a malformed/hostile value reaches spawnNpc as an unknown
-- sprite (ghost silently fails to spawn) or the battle renderer as an
-- arbitrary asset path (crashes into lua-error.log, which a mod can't even
-- see). Anything not in this table falls back to the Red default.
local SPRITE_BY_NAME = {}
for _, s in ipairs(GHOST_SPRITES) do SPRITE_BY_NAME[s.sprite] = s.pic end

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
  -- GHOST SPRITE: mod.options has no confirmed picker/dropdown type (only
  -- "toggle" and "number" are confirmed working -- see the numeric-type note
  -- below), so a choice of 6 sprites is modeled as 6 mutually-exclusive
  -- toggles, each self-labeled with the sprite name, rather than an
  -- unlabeled numeric index the player would need a legend to decode. Built
  -- from GHOST_SPRITES so the option list and the lookup table can't drift
  -- apart. Resolution (see selectedSprite below): first toggle found ON
  -- wins, in GHOST_SPRITES order; none on falls back to PLAYER_SPRITE/
  -- PLAYER_PIC (today's default, Red).
  local function ghostSpriteOptionRows()
    local rows = {}
    for _, s in ipairs(GHOST_SPRITES) do
      rows[#rows + 1] = { key = s.key, label = s.label, type = "toggle", default = false }
    end
    return rows
  end

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
      -- OFF (default) = local shared-file ghosts only, unchanged from
      -- before. ON = additionally uploads your sent ghost to a small server
      -- and downloads other players' ghosts near your current map.
      { key = "online_mode", label = "ONLINE MODE", type = "toggle", default = false },
      -- How many online ghosts to request per map, 1-5. See the big comment
      -- above -- type="number" IS confirmed working in this engine.
      { key = "online_ghost_count", label = "ONLINE GHOST COUNT", type = "number",
        min = 1, max = 5, step = 1, default = ONLINE_DEFAULT_COUNT },
    }
    for _, row in ipairs(ghostSpriteOptionRows()) do rows[#rows + 1] = row end
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
        { key = "online_mode", label = "ONLINE MODE", type = "toggle", default = false },
      })
    end)
  end

  -- First GHOST_SPRITES entry with its toggle on wins; none on -> the
  -- PLAYER_SPRITE/PLAYER_PIC default (Red). Read fresh at SEND GHOST time
  -- (not cached), so flipping the option before a send takes effect
  -- immediately, same as every other option this mod has.
  local function selectedSprite()
    for _, s in ipairs(GHOST_SPRITES) do
      local ok, on = pcall(function() return mod.options:get(s.key) end)
      if ok and on == true then return s.sprite, s.pic end
    end
    return PLAYER_SPRITE, PLAYER_PIC
  end

  local SaveData       = require("src.core.SaveData")
  local SaveSerializer = require("src.core.SaveSerializer")
  local TextBox        = require("src.render.TextBox")
  local ChoiceBox      = require("src.ui.ChoiceBox")
  local NamingScreen   = require("src.ui.NamingScreen")
  local Flags          = require("src.script.Flags")

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
    if slot == nil then
      -- Fallback so we never nil out: modData persistence is unconfirmed, but
      -- better than nothing if activeSlot ever fails.
      sv.modData = type(sv.modData) == "table" and sv.modData or {}
      local md = sv.modData[MOD_ID]
      if type(md) ~= "table" then md = {}; sv.modData[MOD_ID] = md end
      if not md.originId then md.originId = string.format("rg-fallback-%s", tostring(os.time() or 0)) end
      slot = md.originId
    end
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

  -- BattleState.newTrainer (src/battle/BattleState.lua) reads
  -- game.data.trainers[class] and builds each party mon via
  -- Pokemon.new(data, slot.species, slot.level), THEN: "if slot.moves then
  -- mon.moves = <rebuilt from slot.moves ids> end" -- so a slot's moves ARE
  -- honored when present (confirmed from source). DVs are NOT: the same
  -- function unconditionally does `mon.dvs = trainerDvs` afterward, so exact
  -- IVs can't be preserved this way -- only species/level/moves are exact.
  local function injectTrainer(game, rec)
    if not (game and game.data and game.data.trainers) then return nil end
    local class = ghostTrainerClass(rec)
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
        slots[#slots + 1] = { species = mon.species, level = mon.level, moves = moveIds }
      end
    end
    if #slots == 0 then return nil end
    game.data.trainers[class] = {
      id       = class,
      index    = -1,
      name     = rec.name or "RIVAL",
      pic      = rec.pic or PLAYER_PIC,
      parties  = { slots },
      aiMods   = { 1 },
      baseMoney = 0,
      source   = MOD_ID,
    }
    return class
  end

  -- Ghosts that belong in the CURRENTLY loaded save (everyone else's).
  local function activeGhosts(game)
    local origin = saveOriginId(game)
    local out = {}
    for _, rec in ipairs(loadStorage().ghosts) do
      if rec.origin ~= origin then out[#out + 1] = rec end
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
    injectTrainer(game, rec)  -- ensure the trainer class exists before any battle
    local name = NPC_NAME_PREFIX .. rec.id
    local objDef = { name = name, sprite = rec.sprite or PLAYER_SPRITE, movement = "STAY", range = normalizeDir(rec.facing), x = rec.x, y = rec.y }
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
  -- ONLINE MODE: upload the sent ghost to the server, and download other
  -- players' ghosts near the player's current map. Off by default (OFF has
  -- zero behavior change from before). Both directions ride on Fetch's
  -- async job/poll model -- nothing here blocks the game even if the server
  -- is slow or unreachable.
  -- =====================================================================
  local function onlineModeOn()
    return ONLINE_AVAILABLE and mod.options:get("online_mode") == true
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
  local function nearbyMapIds(game, mapId)
    local ids = { mapId }
    local ok, def = pcall(function() return game.data.maps[mapId] end)
    if ok and type(def) == "table" and type(def.connections) == "table" then
      for _, conn in pairs(def.connections) do
        if type(conn) == "table" and type(conn.map) == "string" then
          ids[#ids + 1] = conn.map
        end
      end
    end
    return ids
  end

  local pendingUpload  -- { jobId = ... } or nil
  local pendingNearby   -- { jobId = ..., forMapId = ... } or nil

  local function startOnlineUpload(game, rec)
    -- Say WHY we're not uploading. This used to return in total silence,
    -- which made the single most common failure -- ONLINE MODE simply being
    -- off (it defaults to off) -- completely undiagnosable: the send still
    -- reports "sent to the void!" exactly like a successful one, so a new
    -- player has no way to tell their ghost never left the machine.
    if not ONLINE_AVAILABLE then
      log("online upload skipped: engine networking/JSON unavailable in this build")
      return
    end
    if not onlineModeOn() then
      log("online upload skipped: ONLINE MODE option is OFF (it defaults to off)")
      return
    end
    if pendingUpload then
      log("online upload skipped: a previous upload is still in flight")
      return
    end
    local okBuild, jobId = pcall(function()
      local party = {}
      for _, mon in ipairs(rec.party or {}) do
        local moveIds
        if type(mon.moves) == "table" and #mon.moves > 0 then
          moveIds = {}
          for _, mv in ipairs(mon.moves) do
            local id = type(mv) == "table" and mv.id or mv
            if id then moveIds[#moveIds + 1] = id end
          end
        end
        party[#party + 1] = { species = mon.species, level = mon.level, moves = moveIds }
      end
      local payload = {
        id = rec.origin, name = rec.name, mapId = rec.mapId,
        x = rec.x, y = rec.y, facing = rec.facing, party = party,
        beforeText = rec.beforeText, afterText = rec.afterText,
        sprite = rec.sprite, pic = rec.pic, password = rec.password or "",
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
    end
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
      local url = string.format("%s/nearby?maps=%s&count=%d&exclude=%s&password=%s",
        ONLINE_SERVER_URL, urlEncodeComponent(maps), onlineGhostCount(), urlEncodeComponent(origin),
        urlEncodeComponent(password))
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
    if type(serverGhost.party) ~= "table" or #serverGhost.party == 0 then return false end
    if mapOrigins[mapId] and mapOrigins[mapId][serverGhost.id] then
      log("online ghost from '%s' skipped -- already present on map %s (local or earlier online spawn)",
        tostring(serverGhost.id), tostring(mapId))
      return false
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
    -- Never trust the wire's sprite/pic (see SPRITE_BY_NAME): match the
    -- sprite name against our own table and take the pic from our copy.
    local sprite, pic = PLAYER_SPRITE, PLAYER_PIC
    if type(serverGhost.sprite) == "string" and SPRITE_BY_NAME[serverGhost.sprite] then
      sprite, pic = serverGhost.sprite, SPRITE_BY_NAME[serverGhost.sprite]
    end
    local rec = {
      id = uid,
      origin = uid,
      sourceOrigin = serverGhost.id,  -- raw origin, for mapOrigins dedup (see above) -- NOT for trainer/flag namespacing
      name = serverGhost.name or "RIVAL",
      mapId = mapId,
      x = serverGhost.x, y = serverGhost.y, facing = serverGhost.facing,
      party = serverGhost.party,
      beforeText = serverGhost.beforeText,
      afterText = serverGhost.afterText,
      sprite = sprite,
      pic = pic,
    }
    return spawnOneGhost(game, w, mapId, rec)
  end

  -- Called every ghostStep tick. Both jobs are one-at-a-time and short-lived
  -- (a single request each), so simple sequential polling is enough -- no
  -- need for a job queue.
  local function pollOnlineJobs(game)
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
          end
        else
          log("online upload failed: %s", tostring(result.err))
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
  -- Battle trigger: watch the overworld each input step. GHOST SIGHT (below)
  -- drives undefeated ghosts entirely on its own; the facing+interact check
  -- further down only ever matters for a ghost that's already DEFEATED (see
  -- ghostStep and engageGhost). No map-script registry, no talk lookup, no
  -- trainer-object detection -- all under our control.
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
  local function battleSequenceRows(rec, class)
    local rows = {}
    if rec.beforeText then rows[#rows + 1] = { "show_text", rec.beforeText } end
    rows[#rows + 1] = { "start_battle", "trainer", class, 1 }
    rows[#rows + 1] = { "jump_if_false", "ssn_no_win" }
    rows[#rows + 1] = { "set_flag", defeatFlagName(rec) }
    rows[#rows + 1] = { "label", "ssn_no_win" }
    if rec.afterText then rows[#rows + 1] = { "show_text", rec.afterText } end
    return rows
  end

  -- Manual interact -- only ever reached (see ghostStep) for a ghost that's
  -- already DEFEATED; an undefeated ghost is only ever engaged via GHOST
  -- SIGHT. Default: just replay its after-battle line (or a fallback line if
  -- it was sent with none). REPEATABLE GHOST BATTLES: run the full
  -- battle sequence again instead, exactly like the original encounter.
  local function engageGhost(game, rec, mapId, gx, gy, key)
    local class = injectTrainer(game, rec)  -- (re)inject in case the record changed
    if not class then engagedKey = key; return end
    local repeatable = mod.options:get("ghost_repeatable") == true
    local rows
    if repeatable then
      rows = battleSequenceRows(rec, class)
    else
      local line = rec.afterText or (("%s has nothing\nmore to say."):format(rec.name or "RIVAL"))
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
  -- Re-arming: `world:current()` only resolves while the overworld is the
  -- active state -- during the walk-up and the battle, it's not (a running
  -- script / the battle state owns the stack), so `ghostStep` never even
  -- reaches this function until we're genuinely back. The first tick that
  -- happens IS the "the sequence is over" signal -- no arbitrary timers.
  local SIGHT_RANGE = 5
  local SIGHT_POLL_INTERVAL = 0.35
  local SIGHT_POST_SEQUENCE_GRACE = 2.0  -- avoids instantly re-spotting you at point-blank range right as you return
  local SIGHT_DIR_DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local sightCooldown = {}   -- npcName -> seconds remaining before the next check
  local sightAlerted = {}    -- npcName -> true while its approach+battle script is (believed) in flight
  local sightFacing = {}     -- npcName -> fixed lowercase direction, captured once

  local function sightStep(game, w, mapId, entry, cur, dt)
    local rec = entry.rec
    local name = entry.npcName
    sightCooldown[name] = (sightCooldown[name] or 0) - dt
    if sightCooldown[name] > 0 then return end
    sightCooldown[name] = SIGHT_POLL_INTERVAL

    if sightAlerted[name] then
      -- We're back in the overworld and this ghost's sequence was in flight
      -- -- it must have finished (see re-arming note above). Re-arm with a
      -- short grace period.
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
    else
      log("sight-triggered script refused (%s) -- will retry next time in sight", tostring(qerr))
    end
  end

  local lastMapId  -- detects map transitions so we (re)spawn ghosts for the new map

  local function ghostStep(game, dt)
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

    local list = mapGhosts[cur.mapId]
    if not list or #list == 0 then return end

    -- GHOST SIGHT is unconditional for every ghost that hasn't been defeated
    -- yet -- it's no longer an opt-in mode, it's just how a live ghost
    -- behaves. A defeated ghost is skipped here entirely; it stops hunting.
    for _, entry in ipairs(list) do
      if not isDefeated(game, entry.rec) then
        sightStep(game, w, cur.mapId, entry, cur, dt or 0)
      end
    end

    -- Manual interact is only meaningful for a DEFEATED ghost (see
    -- engageGhost): dialogue replay, or a full rematch if REPEATABLE
    -- GHOST BATTLES is on. An undefeated ghost is only ever engaged via
    -- sight above, so it's excluded from this facing check entirely.
    local d = cur.facing and FACE_DELTA[normalizeDir(cur.facing)]
    local fx, fy = d and (cur.x + d[1]) or nil, d and (cur.y + d[2]) or nil

    local facedRec, facedKey
    for _, entry in ipairs(list) do
      if fx and isDefeated(game, entry.rec) then
        local handle, gx, gy
        local ok = pcall(function() handle = w:npc(cur.mapId, entry.npcName) end)
        if ok and handle and handle.position then
          local ok2 = pcall(function() gx, gy = handle:position() end)
          if ok2 and gx == fx and gy == fy then
            facedRec = entry.rec
            facedKey = cur.mapId .. ":" .. gx .. ":" .. gy
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
        log("no readable input source found -- defeated-ghost interact falls back to walk-up trigger")
      end
    elseif not pressed then
      return  -- facing a defeated ghost, but hasn't pressed the button yet
    end

    engageGhost(game, facedRec, cur.mapId, fx, fy, facedKey)
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
  local function finalizeSend(game, cur, beforeText, afterText, password)
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
    local rec = {
      id        = s.nextId,
      origin    = origin,
      name      = playerName(game),
      mapId     = cur.mapId,
      x         = cur.x,
      y         = cur.y,
      facing    = cur.facing,
      party     = deepcopy(game.save.party),
      createdAt = os.time and os.time() or 0,
      beforeText = (beforeText ~= "" and beforeText) or nil,
      afterText  = (afterText ~= "" and afterText) or nil,
      sprite     = sprite,
      pic        = pic,
      password   = password or "",
    }
    s.nextId = s.nextId + 1
    s.ghosts[#s.ghosts + 1] = rec
    -- Remembered per-save, not just attached to this one ghost, so a
    -- SEND-less later /nearby fetch (see startOnlineNearbyFetch) still
    -- knows this save's current password without re-sending.
    s.passwords[origin] = rec.password
    markDirty()
    log("captured ghost #%d '%s' at map=%s (%s,%s) party=%d dialogue=%s/%s sprite=%s password=%s (replaced %d previous)",
      rec.id, rec.name, tostring(rec.mapId), tostring(rec.x), tostring(rec.y), #rec.party,
      tostring(rec.beforeText ~= nil), tostring(rec.afterText ~= nil), tostring(sprite),
      tostring(rec.password ~= ""), replaced)
    startOnlineUpload(game, rec)  -- no-op if ONLINE MODE is off; async either way
    local msg = replaced > 0
      and "Your old ghost was\nrecalled.\f%s now waits\nhere for other\nworlds to find."
      or "Your ghost was\nsent to the void!\f%s now waits\nhere for other\nworlds to find."
    msg = msg:format(rec.name)
    -- Be explicit that a send with ONLINE MODE off never leaves this
    -- machine. Without this the confirmation is identical either way, so
    -- testers reasonably assumed their ghost had gone out to other players
    -- when it had only ever been written to the local shared file (the
    -- single most likely reason a tester's upload "didn't work").
    if not onlineModeOn() then
      msg = msg .. "\fONLINE MODE is off,\nso this ghost stays\non this machine."
    end
    game.stack:push(TextBox.new(game, msg))
  end

  -- Online password: a "room code" for ONLINE MODE, not a real credential
  -- (see README -- it travels in a plain-HTTP query string same as
  -- everything else this mod sends). A ghost uploaded with NO password is
  -- visible to every downloader; a ghost uploaded WITH a password is only
  -- visible to downloaders whose own remembered password matches exactly.
  -- Prefilled with whatever this save last set, so repeat sends can just
  -- say no and keep reusing it without retyping.
  local function askPassword(game, cur, beforeText, afterText)
    local s = loadStorage()
    local current = s.passwords[saveOriginId(game)] or ""
    game.stack:push(TextBox.new(game, "Set an online\npassword?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then
          finalizeSend(game, cur, beforeText, afterText, current)
          return
        end
        game.stack:push(NamingScreen.new(game, {
          title   = "ONLINE PASSWORD",
          maxLen  = DIALOGUE_MAX_LEN,
          default = current,
          onDone  = function(text) finalizeSend(game, cur, beforeText, afterText, text) end,
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

  -- ChoiceBox renders only a YES/NO selector, no text of its own (confirmed
  -- from source) -- it's always paired with a preceding TextBox for the
  -- question, same as vrm_pokemon_bank's own RELEASE confirmation does.
  local function askAfterText(game, cur, beforeText)
    game.stack:push(TextBox.new(game, "Add an after-\nbattle line too?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if not yes then askPassword(game, cur, beforeText, ""); return end
        game.stack:push(NamingScreen.new(game, {
          title   = "AFTER-BATTLE LINE",
          maxLen  = DIALOGUE_MAX_LEN,
          default = "",
          onDone  = function(text) askPassword(game, cur, beforeText, text) end,
        }))
      end, { defaultNo = true, noSound = true }))
    end))
  end

  local function askBeforeText(game, cur)
    game.stack:push(NamingScreen.new(game, {
      title   = "BEFORE-BATTLE LINE",
      maxLen  = DIALOGUE_MAX_LEN,
      default = "",
      onDone  = function(text) askAfterText(game, cur, text) end,
    }))
  end

  local function sendSelf(game)
    local w = world()
    local cur = w and w:current()
    if not cur or not cur.mapId then
      game.stack:push(TextBox.new(game, "Can't send a ghost\nfrom here.\fTry again out in\nthe overworld."))
      return
    end
    if type(game.save.party) ~= "table" or #game.save.party == 0 then
      game.stack:push(TextBox.new(game, "You have no\nPOKéMON to send!"))
      return
    end
    if not SEND_ALLOWED_MAPS[cur.mapId] then
      log("send blocked: map %s is not an allowed send location", tostring(cur.mapId))
      game.stack:push(TextBox.new(game, "Unable to send ghost.\nInvalid location."))
      return
    end
    game.stack:push(TextBox.new(game, "Include dialogue\nwith this ghost?", function()
      game.stack:push(ChoiceBox.new(game, function(yes)
        if yes then
          askBeforeText(game, cur)
        else
          askPassword(game, cur, "", "")
        end
      end, { defaultNo = true, noSound = true }))
    end))
  end

  -- Add "SEND GHOST" and "ONLINE PASSWORD" to the Start menu (decorate-
  -- after-next, like the Bank's PC-menu row). Insert both before EXIT if
  -- present; otherwise append. ONLINE PASSWORD is separate from SEND GHOST
  -- specifically so a player who only wants to DOWNLOAD ghosts (never sends
  -- one) can still join/leave a private password pool.
  mod.hooks:wrap("ui.start_menu.items", function(next_, game, items)
    local out = next_(game, items)
    if type(out) ~= "table" then return out end
    local sendRow = { label = "SEND GHOST", onSelect = function() sendSelf(game) end }
    local pwRow   = { label = "ONLINE PASSWORD", onSelect = function() setOnlinePassword(game) end }
    if mod.ui and mod.ui.insertBefore then
      local inserted = mod.ui.insertBefore(out, "EXIT", sendRow)
      if type(inserted) == "table" then out = inserted end
      inserted = mod.ui.insertBefore(out, "EXIT", pwRow)
      if type(inserted) == "table" then return inserted end
      return out
    end
    out[#out + 1] = sendRow
    out[#out + 1] = pwRow
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
      injectTrainer(game, rec)
      if isDefeated(game, rec) then defeatedCount = defeatedCount + 1 end
    end
    log("save.loaded: %d ghost(s) in file, %d active (not this save's own), %d already defeated",
      total, #ghosts, defeatedCount)
    local w = world()
    local cur = w and w:current()
    log("save.loaded: world:current -> %s", shallowDump(cur))
    if cur and cur.mapId then
      spawnGhostsForMap(game, cur.mapId)
      startOnlineNearbyFetch(game, cur.mapId)
      lastMapId = cur.mapId
    end
  end)

  -- Small read-only export so other mods (or a future UI) can list ghosts.
  mod.exports.listGhosts = function() return deepcopy(loadStorage().ghosts) end
  mod.exports.ghostCount = function() return #loadStorage().ghosts end

  log("loaded (v0.9.4)")
end
