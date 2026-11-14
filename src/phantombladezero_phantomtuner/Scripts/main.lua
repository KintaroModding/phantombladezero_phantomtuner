-- Phantom Tuner for Phantom Blade Zero.
--
-- One mod for the numbers of the game, each one a setting in config.lua. A multiplier of 1 (and an absolute value of
-- -1) leaves its value as the game made it. The shipped config.lua changes nothing: the mod then sets no hook and
-- searches no object. Three parts:
--
-- 1. Character attributes: the enemy rows by class, the player rows, the enemies' level offset, the free attribute
--    tables. When the game builds a character, it asks PBZCharacterAttributeDataHelper:GetAttributeMap for the start
--    values of the character's attributes at its level (a map: attribute -> value). The mod hooks that function. The
--    callback before it tells the character apart by the config asset (PDA_ActorConfig_C) that owns its attribute
--    data: the player (below /Players/), a level prop (a level actor, not below /ActorData/), an ally (_NPC, Nanmin)
--    or an enemy, whose class is the asset's Difficulty Tag; it also adds the level offset to the Level parameter.
--    The callback right after the function multiplies the entries of the map. So a value reaches characters that the
--    game builds after the change: quit to the main menu and load the save.
-- 2. Config objects: breaks, ultimate charge, shields and loading waits are stored values of the game's loaded
--    config objects. The mod finds them by class (FindAllOf), keeps the game's value per
--    object and writes the wanted one; a setting back at 1 (or Enable = false) writes the game's value back. A full
--    pass runs 5 s after the start, 1 s after a map load, 3 s after the player's pawn restarts (ClientRestart) and
--    right after a changed config.lua. The classes whose objects load during play (the loading widgets) are
--    searched again every ReapplySeconds. Only the classes of the settings in use are searched.
-- 3. Rewards: hooks before PBZBackPackSubsystem's AddDustNum, AddPropsByMap, AddPropsSilently and AddMedicineAmount
--    multiply the amount that the game is about to add. Materials: only the upgrade materials and traversal
--    talismans of MATERIAL_IDS, unless RewardAllItems is true.
--
-- Not in this mod, because a mod of ours does it (one mod per function): the player's maximum health and Sha-Chi
-- (Max Health and Sha-Chi, the same hook), the passive health regen (Passive Regen), and the deflect and parry
-- windows (Easier Parry and Dodge).
--
-- From the user's PBZTuner 1.0.4: the game calls, the values, the order of its logic and its checks. New here: the
-- settings form, no keys (F5 is the live read of config.lua, F7 is Enable = false, F6 is LogDetail), hooks and
-- searches only for the parts in use, game-thread timers instead of LoopAsync.
--
-- Threads: the 1 s tick and the 5 s config read run on the game thread (UE4SS's LoopInGameThreadWithDelay), never
-- on UE4SS's async thread (Witch Time's crash lesson). Every hook callback checks that it runs on the game thread.
--
-- Settings: the player edits Scripts\config.lua. The mod reads it at start and again every CONFIG_INTERVAL_MS; a
-- changed file is used at once, a broken or half-saved file keeps the last settings. DEFAULTS holds every setting
-- with its default. A player (or a mod manager) keeps their config.lua across updates, so a new main.lua can meet an
-- older file: a setting that the file lacks, or has with another type, keeps its default, and the log says so. Read a
-- setting only from Settings or Eff, never as `config.X or default`: for a true/false setting, `false or true` is true.

local MOD_NAME = "Phantom Tuner"
local VERSION = "1.1"
local TICK_MS = 1000
local CONFIG_INTERVAL_MS = 5000
-- Full passes over the config objects, in ticks (seconds) after their event: the source's delays.
local START_PASS_TICKS = 5
local MAP_PASS_TICKS = 1
local RESTART_PASS_TICKS = 3
-- A hook whose function is not there yet is tried again at each tick, at most this many times.
local MAX_HOOK_TRIES = 30
-- Log at most this many error lines in total, and this many LogSpawns, LogRewards and LogDetail lines per change of
-- config.lua.
local MAX_ERROR_LOGS = 10
local MAX_OPTIONAL_LOGS = 1000
-- Multipliers are clamped to this range; 0 or less means the game's value.
local MULTIPLIER_MIN, MULTIPLIER_MAX = 0.01, 100

local ATTRIBUTE_HOOK = "/Script/PBZCombatAsset.PBZCharacterAttributeDataHelper:GetAttributeMap"
local RESTART_HOOK = "/Script/Engine.PlayerController:ClientRestart"
local BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem:"

---------------------------------------------------------------------------------------------------------------------
-- What the settings change
---------------------------------------------------------------------------------------------------------------------

-- The enemy classes: the asset's Difficulty Tag -> the key in a row. "boss" covers the three boss classes.
local TIER_OF_TAG = {
    ["CharacterType.Difficulty.Mob"] = "mob",
    ["CharacterType.Difficulty.Standard"] = "standard",
    ["CharacterType.Difficulty.Elite"] = "elite",
    ["CharacterType.Difficulty.MiniBoss"] = "miniboss",
    ["CharacterType.Difficulty.NormalBoss"] = "normalboss",
    ["CharacterType.Difficulty.GreatBoss"] = "greatboss",
    ["CharacterType.Difficulty.UltimateBoss"] = "ultimateboss",
}
local COARSE = { normalboss = "boss", greatboss = "boss", ultimateboss = "boss" }
local CLASS_KEYS = { "all", "mob", "standard", "elite", "miniboss", "boss", "normalboss", "greatboss", "ultimateboss",
    "untagged" }

-- The rows: setting -> the attributes it multiplies in the map. The map holds a start value beside the maximum
-- ("Health" beside "Health_Max"): both are scaled, or a character spawns with a part of its bar missing (the source,
-- after a player's report on its 1.0.1).
local ENEMY_ROWS = {
    { "EnemyHealth", { "Health", "Health_Max", "Health_Max_Lv1" } },
    { "EnemyAttack", { "Attack", "Attack_Lv1" } },
    { "EnemyShaChiAttack", { "ShachiAttack", "ShachiAttack_Lv1" } },
    { "EnemyShaChi", { "Shachi", "Shachi_Max", "Shachi_Max_Lv1" } },
    { "EnemyInfliction", { "Infliction_Max", "Infliction_Max_Lv1" } },
    { "EnemyShaChiRegen", { "ShachiRegen" } },
    { "EnemySpeed", { "WalkSpeed", "JogSpeed", "SprintSpeed", "CrouchSpeed" } },
}
local PLAYER_ROWS = {
    { "PlayerAttack", { "Attack", "Attack_Lv1" } },
    { "PlayerShaChiAttack", { "ShachiAttack", "ShachiAttack_Lv1" } },
    { "PlayerInfliction", { "Infliction_Max", "Infliction_Max_Lv1" } },
    { "PlayerShaChiRegen", { "ShachiRegen" } },
    { "PlayerShaChiRegenCooldown", { "ShachiRegenCooldown" } },
    { "PlayerUltimateBar", { "UltimateCharge_Max" } },
    { "PlayerSpeed", { "JogSpeed", "SprintSpeed" } },
}
-- A count, not a multiplier.
local ULTIMATE_CHARGES = "UltimateChargeCount_Max"
local INT_ATTRIBUTES = { UltimateChargeCount_Max = true }
-- BreakAttribute (experimental): this attribute (the game's value 0) gets the break multiplier - 1.
local BREAK_ATTRIBUTE = "BreakDurationAdditionalMultiplier"

-- The config objects: class, and per property the setting that multiplies it (mult) or sets it (abs, -1 = the
-- game's). positive: a value of 0 or less is a marker and stays. timer: objects of
-- the class load during play, so the class is searched every ReapplySeconds. cdo: only the class defaults are
-- changed (ability instances are copied from them when a carrier spawns, and must not be scaled twice).
local TARGETS = {
    { class = "PDA_GlobalCombatConfig_C", props = {
        { "Mob Break Duration", mult = "EnemyBreakDuration" },
        { "Mob SimpleExe Break Duration", mult = "EnemyBreakDuration" },
        { "DynamicBreakAdditionalDuration", mult = "EnemyBreakDuration" },
        { "Mob Break Damage Multiplier", mult = "EnemyBreakDamage" },
        { "Player Break Duration", mult = "PlayerBreakDuration" },
        { "Player Break Damage Multiplier", mult = "PlayerBreakDamage" },
        { "Lie Duration", mult = "LieDuration" },
        { "Deflect Ultimate Charge Multiplier Normal", mult = "UltimateChargeDeflect" },
        { "Deflect Ultimate Charge Multiplier Perfect", mult = "UltimateChargeDeflect" },
        { "Deflect Ultimate Charge Multiplier Perfect Dodge", mult = "UltimateChargeDeflect" },
        { "Attack Ultimate Charge Multiplier", mult = "UltimateChargeAttack" },
    } },
    { class = "PBZDestinationLoadingConfig", props = {
        { "SameLevelMinSeconds", abs = "LoadingMinSeconds" },
        { "CrossLevelMinSeconds", abs = "LoadingMinSeconds" },
        { "NewGameMinSeconds", abs = "LoadingMinSeconds" },
        { "SaveLoadMinSeconds", abs = "LoadingMinSeconds" },
        { "FadeInSeconds", abs = "LoadingFadeSeconds" },
        { "ImageFadeInSeconds", abs = "LoadingFadeSeconds" },
        { "RevealFadeOutSeconds", abs = "LoadingRevealSeconds" },
    } },
    { class = "WB_TempLoadingScreen_C", timer = true, props = { { "MaxLoadTime", abs = "LoadingWidgetMaxTime" } } },
    { class = "WB_AdditionalLoading_C", timer = true, props = { { "MaxLoadTime", abs = "LoadingWidgetMaxTime" } } },
    { class = "GA_GoldenBodyShield_PassiveBase", cdo = true, props = {
        { "GoldenShieldMaxHealthMultiplier", mult = "EnemyShield" },
        { "GoldenShieldMaxOverride", mult = "EnemyShield", positive = true },
    } },
}

-- The upgrade materials and traversal talismans that RewardMaterials multiplies (weapon, Sha-Chi weapon, accessory and
-- medicine upgrade materials, snap-soul materials; the source read them from the running game, 2026-10-29). Story
-- items, treasures, book pages, memory petals, accessory fragments and the permanent-stat shards keep their count
-- unless RewardAllItems is true.
local MATERIAL_IDS = {}
for _, id in ipairs({
    "Ac_Material_1", "Ac_Material_4", "Medi_Material_1", "Medi_Material_2", "Medi_Material_3", "TU_01001",
    "TU_02001", "TU_03001", "TU_03002", "TU_03003", "TU_04001", "TU_04003",
    "TU_05001", "TU_05003", "TU_05004", "TU_05005", "TU_06001", "TU_06002",
    "TU_06004", "TU_06005", "TU_07001", "TU_08001", "TU_08002", "TU_09001",
    "TU_09002", "TU_09003", "TU_09004", "TU_0901", "TU_10001", "TU_10002",
    "TU_10003", "TU_11003", "TU_11005", "TU_11006", "TU_11008", "TU_11009",
    "TU_11010", "TU_11012", "TU_12001", "TU_12002", "TU_13004", "TU_14001",
    "TU_15001", "TU_150011", "TU_15002", "TU_150021", "TU_18001", "TU_18008",
    "TU_180091", "TU_180092", "TU_180093", "TU_180094", "TU_18011", "TU_19001",
    "TU_19002", "TU_19004", "TU_19006", "Weapon_Material_01", "Weapon_Material_02", "Weapon_Material_03",
    "Weapon_Material_04", "Weapon_Material_05", "Weapon_Material_06", "Weapon_Material_07", "Weapon_Material_08",
    "Weapon_Material_09", "Weapon_Material_10", "Weapon_Material_11", "Weapon_Material_12", "Weapon_Material_13",
    "Weapon_Material_14", "Weapon_Material_15", "Weapon_Material_16", "Weapon_Material_17", "Weapon_Material_18",
    "Weapon_Material_19", "Weapon_Material_20", "Weapon_Material_21", "Weapon_Material_22", "Weapon_Material_23",
    "Weapon_Material_24", "Weapon_Material_25", "Weapon_Material_26", "Weapon_Material_27", "Item_Traversing",
}) do
    MATERIAL_IDS[id] = true
end

---------------------------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------------------------

-- Every setting with its default; config.lua ships the same names and values (tests\test_main.py checks it). Every
-- default is the game's own value.
local DEFAULTS = {
    Enable = true,
    -- Enemies: a multiplier for every enemy, or a table by class ({ all = 1, boss = 2 }).
    EnemyHealth = 1,
    EnemyAttack = 1,
    EnemyShaChiAttack = 1,
    EnemyShaChi = 1,
    EnemyInfliction = 1,
    EnemyShaChiRegen = 1,
    EnemySpeed = 1,
    EnemyLevelOffset = 0,
    EnemyShield = 1,
    EnemyAttributes = {},
    ScaleUntagged = true,
    ScaleAllies = false,
    ScaleProps = false,
    -- The player.
    PlayerAttack = 1,
    PlayerShaChiAttack = 1,
    PlayerInfliction = 1,
    PlayerShaChiRegen = 1,
    PlayerShaChiRegenCooldown = 1,
    PlayerUltimateBar = 1,
    PlayerSpeed = 1,
    PlayerUltimateCharges = -1,
    PlayerAttributes = {},
    -- Breaks and ultimate charge.
    EnemyBreakDuration = 1,
    EnemyBreakDamage = 1,
    PlayerBreakDuration = 1,
    PlayerBreakDamage = 1,
    LieDuration = 1,
    BreakAttribute = false,
    UltimateChargeDeflect = 1,
    UltimateChargeAttack = 1,
    -- Rewards.
    RewardDust = 1,
    RewardMaterials = 1,
    RewardConsumables = 1,
    RewardAllItems = false,
    RewardRounding = "nearest",
    -- Loading screens.
    LoadingMinSeconds = -1,
    LoadingFadeSeconds = -1,
    LoadingRevealSeconds = -1,
    LoadingWidgetMaxTime = -1,
    -- The mod.
    ReapplySeconds = 5,
    LogSpawns = false,
    LogRewards = false,
    LogDetail = false,
}
-- Number settings that are not multipliers: their range. game: a value below 0 means the game's own (-1). Every other
-- number setting is a multiplier (MULTIPLIER_MIN to MULTIPLIER_MAX); the enemy rows also take a table by class.
local LIMITS = {
    EnemyLevelOffset = { -100, 100 },
    PlayerUltimateCharges = { 0, 10, game = true },
    LoadingMinSeconds = { 0, 30, game = true },
    LoadingFadeSeconds = { 0, 30, game = true },
    LoadingRevealSeconds = { 0, 30, game = true },
    LoadingWidgetMaxTime = { 0, 600, game = true },
    ReapplySeconds = { 0, 60 },
}
local ROUNDING = { nearest = true, up = true, down = true }
local CLASS_ROWS = {}
for _, row in ipairs(ENEMY_ROWS) do
    CLASS_ROWS[row[1]] = true
end
-- The settings that change a character's build, and those that change a break.
local BUILD_SETTINGS = { Enable = true, EnemyLevelOffset = true, EnemyAttributes = true, ScaleUntagged = true,
    ScaleAllies = true, ScaleProps = true, PlayerUltimateCharges = true, PlayerAttributes = true,
    BreakAttribute = true }
for _, row in ipairs(ENEMY_ROWS) do
    BUILD_SETTINGS[row[1]] = true
end
for _, row in ipairs(PLAYER_ROWS) do
    BUILD_SETTINGS[row[1]] = true
end
local BREAK_SETTINGS = { EnemyBreakDuration = true, EnemyBreakDamage = true, PlayerBreakDuration = true,
    PlayerBreakDamage = true }

local errors = 0
local optionalLogs = 0
local warned = {}

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function LogError(message)
    errors = errors + 1
    if errors <= MAX_ERROR_LOGS then
        Log(message)
    end
end

-- A problem that the log names once per game start.
local function WarnOnce(key, message)
    if not warned[key] then
        warned[key] = true
        Log(message)
    end
end

local Settings = {}   -- the checked settings of config.lua
local Eff = {}        -- the values in use: Settings, or the defaults (the game's values) while Enable is false

-- An opt-in line: with the setting `switch` (or LogDetail) on. message is a function, so nothing is built otherwise.
local function Optional(switch, message)
    if (Settings[switch] or Settings.LogDetail) and optionalLogs < MAX_OPTIONAL_LOGS then
        optionalLogs = optionalLogs + 1
        Log(message())
    end
end

local function Detail(message)
    Optional("LogDetail", message)
end

local function Note(message)
    Log("config.lua: " .. message)
end

-- A number for the log: at most 6 digits, no ".0".
local function Number(value)
    return string.format("%.6g", value)
end

-- A setting's value for the log; a class row with only `all` is its number.
local function Show(value)
    if type(value) == "number" then
        return Number(value)
    elseif type(value) ~= "table" then
        return tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    if #keys == 1 and keys[1] == "all" and type(value.all) == "number" then
        return Number(value.all)
    end
    local parts = {}
    for i, key in ipairs(keys) do
        parts[i] = key .. "=" .. Show(value[key])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function CopyDefaults()
    local settings = {}
    for name, value in pairs(DEFAULTS) do
        if CLASS_ROWS[name] then
            settings[name] = { all = value }
        elseif type(value) == "table" then
            settings[name] = {}
        else
            settings[name] = value
        end
    end
    return settings
end

local DEFAULT_SHOW = {}
for name, value in pairs(CopyDefaults()) do
    DEFAULT_SHOW[name] = Show(value)
end

-- The settings that differ from their defaults, sorted by name; "" when there are none.
local function Describe(settings)
    local names = {}
    for name in pairs(DEFAULTS) do
        if Show(settings[name]) ~= DEFAULT_SHOW[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do
        parts[i] = name .. "=" .. Show(settings[name])
    end
    return table.concat(parts, ", ")
end

-- A multiplier from config.lua: the value to use, or nil (with a line) when it is not a number.
local function CheckMultiplier(label, value)
    if type(value) ~= "number" or value ~= value then
        Note(label .. " must be a number; it is not used.")
        return nil
    end
    if value <= 0 then
        Note(label .. " = " .. Number(value) .. " is 0 or less; 1 (the game's value) is used.")
        return 1
    end
    if value < MULTIPLIER_MIN or value > MULTIPLIER_MAX then
        local clamped = math.min(MULTIPLIER_MAX, math.max(MULTIPLIER_MIN, value))
        Note(string.format("%s = %s is outside %s to %s; %s is used.", label, Number(value), Number(MULTIPLIER_MIN),
            Number(MULTIPLIER_MAX), Number(clamped)))
        return clamped
    end
    return value
end

-- An enemy row: a number (every enemy) or a table by class; nil when it is neither.
local function CheckClassRow(label, value)
    if type(value) == "number" then
        local checked = CheckMultiplier(label, value)
        return checked and { all = checked } or nil
    end
    if type(value) ~= "table" then
        return nil
    end
    local row = {}
    for key, entry in pairs(value) do
        local known = false
        for _, class in ipairs(CLASS_KEYS) do
            known = known or key == class
        end
        if known then
            row[key] = CheckMultiplier(label .. "." .. key, entry)
        else
            Note(label .. "." .. tostring(key) .. " is not a class (" .. table.concat(CLASS_KEYS, ", ")
                .. "); it is ignored.")
        end
    end
    return row
end

-- EnemyAttributes or PlayerAttributes: attribute name -> multiplier (enemies: or a table by class).
local function CheckAttributes(name, value)
    local checked = {}
    for attribute, entry in pairs(value) do
        local label = name .. "." .. tostring(attribute)
        if type(attribute) ~= "string" or #attribute > 64 or not attribute:match("^[%a_][%w_]*$") then
            Note(name .. ": " .. tostring(attribute) .. " is not an attribute name; it is ignored.")
        elseif name == "EnemyAttributes" then
            checked[attribute] = CheckClassRow(label, entry)
            if checked[attribute] == nil then
                Note(label .. " must be a number or a table by class; it is ignored.")
            end
        else
            checked[attribute] = CheckMultiplier(label, entry)
        end
    end
    return checked
end

-- Lua's line number and reason, without the chunk name.
local function Reason(message)
    message = tostring(message)
    local line, reason = message:match("config%.lua:(%d+): ([^\n]*)")
    return line and ("line " .. line .. ": " .. reason) or (message:gsub("%s*\n%s*", " "))
end

-- DEFAULTS with the checked values of config.lua's text over them; nil and the reason when the text is not usable.
local function ParseConfig(text)
    local chunk, problem = load(text, "=config.lua", "t", {})
    if not chunk then
        return nil, "config.lua not read (" .. Reason(problem) .. ")"
    end
    local ok, config = pcall(chunk)
    if not ok then
        return nil, "config.lua not read (" .. Reason(config) .. ")"
    end
    if type(config) ~= "table" then
        return nil, "config.lua does not return a table"
    end
    local settings = CopyDefaults()
    for name, value in pairs(config) do
        local default = DEFAULTS[name]
        local limit = LIMITS[name]
        if default == nil then
            Note("unknown setting " .. tostring(name) .. " ignored.")
        elseif CLASS_ROWS[name] then
            local row = CheckClassRow(name, value)
            if row then
                settings[name] = row
            else
                Note(name .. " must be a number or a table by class; the default " .. Show(default) .. " is used.")
            end
        elseif type(value) ~= type(default) then
            Note(string.format("%s must be a %s; the default %s is used.", name, type(default), Show(default)))
        elseif type(default) == "table" then
            settings[name] = CheckAttributes(name, value)
        elseif type(default) == "string" then
            if ROUNDING[value] then
                settings[name] = value
            else
                Note(name .. " must be \"nearest\", \"up\" or \"down\"; the default " .. default .. " is used.")
            end
        elseif type(default) ~= "number" then
            settings[name] = value
        elseif not limit then
            settings[name] = CheckMultiplier(name, value) or default
        elseif value ~= value then
            Note(name .. " is not a number; the default " .. Show(default) .. " is used.")
        elseif limit.game and value < 0 then
            settings[name] = -1
        elseif value < limit[1] or value > limit[2] then
            local clamped = math.min(limit[2], math.max(limit[1], value))
            Note(string.format("%s = %s is outside %s to %s; %s is used.", name, Number(value), Number(limit[1]),
                Number(limit[2]), Number(clamped)))
            settings[name] = clamped
        else
            settings[name] = value
        end
    end
    return settings
end

-- The value of a row for one class: the class, then its coarse class (boss), then all; 1 when none is set.
local function ClassValue(row, tier)
    local value = row[tier]
    if value == nil and COARSE[tier] then
        value = row[COARSE[tier]]
    end
    if value == nil then
        value = row.all
    end
    return value or 1
end

local function RowUsed(row)
    for _, value in pairs(row) do
        if value ~= 1 then
            return true
        end
    end
    return false
end

local function SpecUsed(spec)
    return (spec.abs ~= nil and Eff[spec.abs] >= 0) or (spec.mult ~= nil and Eff[spec.mult] ~= 1)
end

local function ClassUsed(target)
    for _, spec in ipairs(target.props) do
        if SpecUsed(spec) then
            return true
        end
    end
    return false
end

-- Which parts the settings in use change; a part that changes nothing gets no hook and no search.
local use = {}

local function UpdateUse()
    local attributes = Eff.EnemyLevelOffset ~= 0 or Eff.PlayerUltimateCharges >= 0
        or (Eff.BreakAttribute and (Eff.EnemyBreakDuration ~= 1 or Eff.PlayerBreakDuration ~= 1))
    for _, row in ipairs(ENEMY_ROWS) do
        attributes = attributes or RowUsed(Eff[row[1]])
    end
    for _, row in ipairs(PLAYER_ROWS) do
        attributes = attributes or Eff[row[1]] ~= 1
    end
    for _, row in pairs(Eff.EnemyAttributes) do
        attributes = attributes or RowUsed(row)
    end
    attributes = attributes or RowUsed(Eff.PlayerAttributes)
    local objects = false
    for _, target in ipairs(TARGETS) do
        objects = objects or ClassUsed(target)
    end
    use = {
        attributes = attributes,
        objects = objects,
        dust = Eff.RewardDust ~= 1,
        materials = Eff.RewardMaterials ~= 1,
        consumables = Eff.RewardConsumables ~= 1,
    }
end

local configPath = nil
-- The text of the last read; false: no file at the last read; nil: not read yet.
local configText = nil

-- Reads config.lua when its text changed since the last read; true when the settings changed (not at start). At
-- start, a missing or broken file means the defaults; later, a broken file keeps the last settings (a half-saved
-- file), and a missing one means the defaults.
local function ReadConfig()
    local atStart = configText == nil
    configPath = configPath or package.searchpath("config", package.path)
    local text = false
    if configPath then
        local file = io.open(configPath, "rb")
        if file then
            text = file:read("a") or false
            file:close()
        end
    end
    if text == configText then
        return false
    end
    configText = text
    local settings, problem
    if text == false then
        settings, problem = CopyDefaults(), nil
        Log("No config.lua; every setting uses its default.")
    else
        settings, problem = ParseConfig(text)
    end
    if not settings then
        if atStart then
            Log(problem .. "; every setting uses its default.")
            settings = CopyDefaults()
        else
            Log(problem .. "; the last settings stay.")
            return false
        end
    end
    local old = Settings
    local line = Describe(settings)
    local changed = atStart or line ~= Describe(old)
    Settings = settings
    Eff = settings.Enable and settings or CopyDefaults()
    UpdateUse()
    if not changed then
        return false
    end
    optionalLogs = 0
    Log("Settings: " .. (line ~= "" and line
        or "all at their defaults: every value is the game's own, so the mod changes nothing."))
    if atStart then
        return false
    end
    local build, breaks = false, false
    for name in pairs(DEFAULTS) do
        if Show(old[name]) ~= Show(settings[name]) then
            build = build or BUILD_SETTINGS[name] == true
            breaks = breaks or BREAK_SETTINGS[name] == true
        end
    end
    if build then
        Log("Attribute values reach the characters that the game builds from now on: quit to the main menu and load "
            .. "the save (a rest at a bell is not enough); enemies that already stand keep theirs.")
    end
    if breaks then
        Log("Break values reach the characters that spawn from now on.")
    end
    return true
end

---------------------------------------------------------------------------------------------------------------------
-- Helpers for the game's objects
---------------------------------------------------------------------------------------------------------------------

local function Valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

-- A hook parameter, and the keys and values of a map, are UE4SS params: get() gives the value.
local function Unwrap(value)
    if type(value) == "table" or type(value) == "userdata" then
        local ok, result = pcall(function()
            return value:get()
        end)
        if ok then
            return result
        end
    end
    return value
end

-- A name as Lua text (UE4SS gives an FString or FName); nil when it is none.
local function Text(value)
    if type(value) ~= "string" then
        if type(value) ~= "userdata" and type(value) ~= "table" then
            return nil
        end
        local ok, text = pcall(function()
            return value:ToString()
        end)
        if not ok then
            return nil
        end
        value = text
    end
    if type(value) ~= "string" or #value == 0 or #value > 128 then
        return nil
    end
    return value
end

-- A hook callback works only on the game thread; a call from another thread is left alone (and named once).
local function InGameThread(what)
    if type(IsInGameThread) ~= "function" then
        return true
    end
    local ok, inGameThread = pcall(IsInGameThread)
    if ok and inGameThread == true then
        return true
    end
    WarnOnce("thread " .. what, "A call of " .. what .. " came from another thread; the mod left it alone.")
    return false
end

---------------------------------------------------------------------------------------------------------------------
-- Part 1: character attributes
---------------------------------------------------------------------------------------------------------------------

-- Per config asset (address): { kind = "player" | "enemy" | "ally" | "prop", tier, name, full }.
local classCache = {}

-- The character behind the attribute data; nil when no config asset owns it.
local function Classify(data)
    local level = data.MaxHealth
    if not Valid(level) then
        level = data.Attack
    end
    if not Valid(level) then
        level = data.MaxShachi
    end
    if not Valid(level) then
        return nil
    end
    local asset = level:GetOuter()
    if not Valid(asset) then
        return nil
    end
    local address = asset:GetAddress()
    local full = asset:GetFullName()
    local cached = classCache[address]
    if cached and cached.full == full then
        return cached
    end
    local info = { kind = "enemy", tier = "untagged", full = full, name = asset:GetFName():ToString() }
    if full:find("/Players/", 1, true) then
        info.kind, info.tier = "player", "player"
    elseif full:find("PersistentLevel", 1, true) and not full:find("/ActorData/", 1, true) then
        -- A level actor with its own attribute data (firewood, braziers, campfires): not a character.
        info.kind, info.tier = "prop", "prop"
    else
        local ok, tag = pcall(function()
            return asset["Difficulty Tag"].TagName:ToString()
        end)
        if ok and type(tag) == "string" and tag ~= "None" and tag ~= "" then
            info.tier = TIER_OF_TAG[tag] or tag:lower()
        end
        -- Friendly or story versions of characters and civilians share the enemies' data folders.
        local name = info.name
        if name:find("_NPC", 1, true) or name:find("^ActorC_NPC_") or name:find("Nanmin", 1, true) then
            info.kind = "ally"
        end
    end
    classCache[address] = info
    return info
end

-- What to write for one character: { attribute = multiplier }, { attribute = value }, { attribute = added }.
local function Plan(info)
    local mults, absolute, adds = {}, {}, {}
    local function put(names, multiplier)
        if multiplier ~= 1 then
            for _, name in ipairs(names) do
                mults[name] = (mults[name] or 1) * multiplier
            end
        end
    end
    local function breakAttribute(multiplier)
        if Eff.BreakAttribute and multiplier ~= 1 then
            adds[BREAK_ATTRIBUTE] = (adds[BREAK_ATTRIBUTE] or 0) + (multiplier - 1)
        end
    end
    if info.kind == "player" then
        for _, row in ipairs(PLAYER_ROWS) do
            put(row[2], Eff[row[1]])
        end
        if Eff.PlayerUltimateCharges >= 0 then
            absolute[ULTIMATE_CHARGES] = Eff.PlayerUltimateCharges
        end
        breakAttribute(Eff.PlayerBreakDuration)
        for name, multiplier in pairs(Eff.PlayerAttributes) do
            put({ name }, multiplier)
        end
    elseif info.kind == "enemy" or (info.kind == "prop" and Eff.ScaleProps)
        or (info.kind == "ally" and Eff.ScaleAllies) then
        if info.tier == "untagged" and not Eff.ScaleUntagged then
            return mults, absolute, adds
        end
        for _, row in ipairs(ENEMY_ROWS) do
            put(row[2], ClassValue(Eff[row[1]], info.tier))
        end
        breakAttribute(Eff.EnemyBreakDuration)
        for name, row in pairs(Eff.EnemyAttributes) do
            put({ name }, ClassValue(row, info.tier))
        end
    end
    return mults, absolute, adds
end

-- The character of the current build, from the callback before GetAttributeMap to the one after it.
local pending = nil
local mapLogged = {}   -- LogDetail: the whole map of the first build of each kind

local function BeforeAttributeMap(_, attributeData, level, _)
    pending = nil
    if not use.attributes or not InGameThread("GetAttributeMap") then
        return
    end
    local ok, info = pcall(Classify, Unwrap(attributeData))
    if not ok then
        WarnOnce("classify", "A character's attribute data could not be read (" .. tostring(info)
            .. "); that character stays as the game made it.")
        return
    end
    if not info then
        WarnOnce("noasset", "A character's attribute data has no config asset behind it; it stays as the game made it.")
        return
    end
    pending = { info = info, levelNote = "" }
    if info.kind == "enemy" and Eff.EnemyLevelOffset ~= 0
        and not (info.tier == "untagged" and not Eff.ScaleUntagged) then
        local set, problem = pcall(function()
            local old = level:get()
            if type(old) == "number" then
                local new = math.max(1, old + Eff.EnemyLevelOffset)
                level:set(new)
                pending.levelNote = " level " .. Number(old) .. "->" .. Number(new)
            end
        end)
        if not set then
            WarnOnce("level", "The level of a character could not be changed (" .. tostring(problem) .. ").")
        end
    end
end

local function AttributeName(key)
    local struct = Unwrap(key)
    local ok, name = pcall(function()
        return struct.AttributeName
    end)
    return ok and Text(name) or nil
end

-- Multiplies the entries of the map that GetAttributeMap filled, with the plan of the character.
local function ScaleMap(current, outMap)
    local info = current.info
    local mults, absolute, adds = Plan(info)
    if next(mults) == nil and next(absolute) == nil and next(adds) == nil then
        if info.kind == "ally" and not Eff.ScaleAllies then
            Optional("LogSpawns", function()
                return string.format("ally %s (%s): left alone (ScaleAllies is false)", info.name, info.tier)
            end)
        else
            Optional(info.kind == "prop" and "LogDetail" or "LogSpawns", function()
                return string.format("%s %s (%s)%s: nothing to change", info.kind, info.name, info.tier,
                    current.levelNote)
            end)
        end
        return
    end
    local map = Unwrap(outMap)
    local changed, unwritable, seen, named = 0, 0, 0, 0
    local lines, whole, problem = {}, nil, nil
    if Settings.LogDetail and not mapLogged[info.kind] then
        whole = {}
    end
    map:ForEach(function(key, value)
        -- An error inside the callback may not reach the caller: keep it and raise it after the loop.
        if problem then
            return
        end
        local ok, err = pcall(function()
            seen = seen + 1
            local name = AttributeName(key)
            if not name then
                return
            end
            named = named + 1
            local old = Unwrap(value)
            if whole then
                whole[#whole + 1] = name .. "=" .. tostring(old)
            end
            local a, m, d = absolute[name], mults[name], adds[name]
            if (a == nil and m == nil and d == nil) or type(old) ~= "number" then
                return
            end
            local new = a ~= nil and a or old * (m or 1) + (d or 0)
            if INT_ATTRIBUTES[name] then
                new = math.floor(new + 0.5)
            end
            if math.abs(new - old) > 1e-9 then
                if not pcall(function()
                    value:set(new)
                end) then
                    unwritable = unwritable + 1
                    return
                end
                changed = changed + 1
                lines[#lines + 1] = string.format("%s %.4g->%.4g", name, old, new)
            end
        end)
        if not ok then
            problem = tostring(err)
        end
    end)
    if problem then
        error(problem, 0)
    end
    if whole and #whole > 0 then
        mapLogged[info.kind] = true
        Detail(function()
            return string.format("attribute map of the first %s (%s), %d entries: %s", info.kind, info.name, #whole,
                table.concat(whole, ", "))
        end)
    end
    if seen == 0 then
        WarnOnce("empty", "An attribute map arrived empty (" .. info.name .. ").")
    elseif named == 0 then
        WarnOnce("names", string.format("The attribute map's names cannot be read on this game version (%d entries): "
            .. "the attribute rows change nothing; please post this log.", seen))
    end
    if unwritable > 0 then
        WarnOnce("unwritable", string.format("Attribute values cannot be written on this game version (%d): the "
            .. "attribute rows change nothing; please post this log.", unwritable))
    end
    Optional("LogSpawns", function()
        return string.format("%s %s (%s)%s: %d value(s) scaled%s", info.kind, info.name, info.tier, current.levelNote,
            changed, #lines > 0 and (": " .. table.concat(lines, ", ")) or "")
    end)
end

local function AfterAttributeMap(_, _, _, outMap)
    local current = pending
    pending = nil
    if current == nil or not use.attributes or not InGameThread("GetAttributeMap") then
        return
    end
    local ok, err = pcall(ScaleMap, current, outMap)
    if not ok then
        WarnOnce("map", "An attribute map could not be changed (" .. tostring(err) .. "); that character stays as "
            .. "the game made it. Please post this log.")
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Part 2: config objects
---------------------------------------------------------------------------------------------------------------------

-- [class][object address][property] = { vanilla = the game's value, scaled = the value the mod wrote or found }
local state = {}
-- Classes whose objects held a value of the mod at their last pass: searched again at the next full pass, so a
-- setting back at 1 writes the game's values back.
local touched = {}

-- Two stored values that are the same; the game keeps 32-bit floats.
local function Near(a, b)
    return math.abs(a - b) <= 1e-5 + 1e-6 * math.max(math.abs(a), math.abs(b))
end

local function Wanted(spec, vanilla)
    local value = vanilla
    local absolute = spec.abs and Eff[spec.abs]
    if absolute and absolute >= 0 then
        value = absolute
    elseif spec.mult then
        value = vanilla * Eff[spec.mult]
    end
    if value < 0 then
        value = 0
    end
    return value
end

local function ObjectName(object)
    local ok, name = pcall(function()
        return object:GetFName():ToString()
    end)
    return ok and name or "?"
end

-- Writes one property of one object; the game's value is kept per object. True when it wrote.
local function ScaleProp(records, object, spec)
    local prop = spec[1]
    local ok, value = pcall(function()
        return object[prop]
    end)
    if not ok or type(value) ~= "number" then
        return false
    end
    local record = records[prop]
    if record then
        if Near(value, record.scaled) then
            local want = Wanted(spec, record.vanilla)
            if Near(want, value) then
                return false
            end
            object[prop] = want
            record.scaled = want
            Detail(function()
                return string.format("%s.%s %.4g -> %.4g (settings changed)", ObjectName(object), prop, value, want)
            end)
            return true
        elseif not Near(value, record.vanilla) then
            -- Another object at this address, or the game wrote the value: it is the game's value now.
            record = nil
        end
    end
    if not record then
        record = { vanilla = value, scaled = value }
        records[prop] = record
    end
    if spec.positive and record.vanilla <= 0 then
        return false
    end
    local want = Wanted(spec, record.vanilla)
    if Near(want, value) then
        record.scaled = value
        return false
    end
    object[prop] = want
    record.scaled = want
    Detail(function()
        return string.format("%s.%s %.4g -> %.4g", ObjectName(object), prop, value, want)
    end)
    return true
end

local function IsDefault(object)
    return ObjectName(object):sub(1, 9) == "Default__"
end

-- One class: its objects, the values written, and whether one of them holds a value of the mod now.
local function PassClass(target)
    local list = FindAllOf(target.class)
    if type(list) ~= "table" then
        return 0, 0, false
    end
    state[target.class] = state[target.class] or {}
    local records = state[target.class]
    local objects, changed, holds = 0, 0, false
    for _, object in ipairs(list) do
        if Valid(object) and IsDefault(object) == (target.cdo == true) then
            objects = objects + 1
            local ok, err = pcall(function()
                local address = object:GetAddress()
                records[address] = records[address] or {}
                for _, spec in ipairs(target.props) do
                    if ScaleProp(records[address], object, spec) then
                        changed = changed + 1
                    end
                    local record = records[address][spec[1]]
                    if record and not Near(record.scaled, record.vanilla) then
                        holds = true
                    end
                end
            end)
            if not ok then
                LogError("Error while writing " .. target.class .. ": " .. tostring(err))
            end
        end
    end
    return objects, changed, holds
end

-- full: every class in use or touched (start, map load, pawn restart, a changed config.lua). Otherwise only the
-- classes in use whose objects load during play.
local function Pass(full)
    local searched, objects, changed = 0, 0, 0
    for _, target in ipairs(TARGETS) do
        local used = ClassUsed(target)
        if (full and (used or touched[target.class])) or (not full and target.timer and used) then
            searched = searched + 1
            local o, c, holds = PassClass(target)
            objects, changed = objects + o, changed + c
            touched[target.class] = holds
        end
    end
    if searched == 0 then
        return
    end
    local line = function()
        return string.format("Config objects: %d classes searched, %d objects, %d values written.", searched,
            objects, changed)
    end
    if full and changed > 0 then
        Log(line())
    else
        Detail(line)
    end
end

-- Full passes waiting, in ticks.
local countdowns = {}

local function Schedule(ticks)
    countdowns[#countdowns + 1] = ticks
end

local function BeforeClientRestart()
    if use.objects and InGameThread("ClientRestart") then
        Schedule(RESTART_PASS_TICKS)
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Part 3: rewards
---------------------------------------------------------------------------------------------------------------------

local function Rounded(amount, multiplier)
    -- Rounded to 6 places first: 10 * 1.1 is 11.000000000000002, which must not round up to 12.
    local value = math.floor(amount * multiplier * 1e6 + 0.5) / 1e6
    local mode = Eff.RewardRounding
    if mode == "up" then
        value = math.ceil(value)
    elseif mode == "down" then
        value = math.floor(value)
    else
        value = math.floor(value + 0.5)
    end
    if value < 1 and amount >= 1 then
        value = 1
    end
    return value
end

-- Multiplies a count parameter before the game's function reads it.
local function ScaleAmount(param, multiplier, label)
    if multiplier == 1 then
        return
    end
    local ok, amount = pcall(function()
        return param:get()
    end)
    if not ok or type(amount) ~= "number" or amount <= 0 then
        return
    end
    local new = Rounded(amount, multiplier)
    if new ~= amount then
        param:set(new)
        Optional("LogRewards", function()
            return string.format("%s: %s -> %s (x%s)", label, Number(amount), Number(new), Number(multiplier))
        end)
    end
end

local function BeforeAddDust(_, num)
    if not use.dust or not InGameThread("AddDustNum") then
        return
    end
    local ok, err = pcall(ScaleAmount, num, Eff.RewardDust, "Dust")
    if not ok then
        LogError("Error in AddDustNum: " .. tostring(err))
    end
end

local function BeforeAddMedicine(_, medicineId, amount)
    if not use.consumables or not InGameThread("AddMedicineAmount") then
        return
    end
    local ok, err = pcall(function()
        ScaleAmount(amount, Eff.RewardConsumables, "Consumable " .. (Text(Unwrap(medicineId)) or "?"))
    end)
    if not ok then
        LogError("Error in AddMedicineAmount: " .. tostring(err))
    end
end

-- The last map the mod changed: AddPropsByMap and AddPropsSilently must not multiply the same pickup twice.
local lastProps = { signature = "", time = -1 }

local function ItemId(key)
    local id = Text(Unwrap(key))
    if id == nil then
        id = Text(key)
    end
    return id
end

local function MapSignature(map)
    local parts = {}
    pcall(function()
        map:ForEach(function(key, value)
            parts[#parts + 1] = (ItemId(key) or "?") .. "=" .. tostring(Unwrap(value))
        end)
    end)
    table.sort(parts)
    return table.concat(parts, ";")
end

local function ScaleItems(label, mapParam)
    local multiplier = Eff.RewardMaterials
    local map = Unwrap(mapParam)
    local signature = MapSignature(map)
    if signature ~= "" and signature == lastProps.signature and os.clock() - lastProps.time < 0.05 then
        Optional("LogRewards", function()
            return label .. ": the same item map as the call before; left alone"
        end)
        return
    end
    local problem = nil
    map:ForEach(function(key, value)
        if problem then
            return
        end
        local ok, err = pcall(function()
            local id = ItemId(key)
            local amount = Unwrap(value)
            if type(id) ~= "string" or type(amount) ~= "number" or amount <= 0 then
                return
            end
            if not Eff.RewardAllItems and not MATERIAL_IDS[id] then
                Optional("LogRewards", function()
                    return string.format("%s: %s x%s left alone (not an upgrade material)", label, id, Number(amount))
                end)
                return
            end
            local new = Rounded(amount, multiplier)
            if new ~= amount then
                if pcall(function()
                    value:set(new)
                end) then
                    Optional("LogRewards", function()
                        return string.format("%s: %s %s -> %s (x%s)", label, id, Number(amount), Number(new),
                            Number(multiplier))
                    end)
                else
                    WarnOnce("items", "Materials: the item map cannot be written on this game version; please post "
                        .. "this log.")
                end
            end
        end)
        if not ok then
            problem = tostring(err)
        end
    end)
    if problem then
        WarnOnce("itemmap", "Materials: an item map could not be read (" .. problem .. "); please post this log.")
    end
    lastProps.signature = MapSignature(map)
    lastProps.time = os.clock()
end

local function ItemHook(label)
    return function(_, propMap)
        if not use.materials or not InGameThread(label) then
            return
        end
        local ok, err = pcall(ScaleItems, label, propMap)
        if not ok then
            LogError("Error in " .. label .. ": " .. tostring(err))
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------------------------------

-- Each hook is set once, when its part is first in use; while its function is not there it is tried again at each
-- tick (MAX_HOOK_TRIES). After a failed RegisterHook there is no second try: two hooks on one reward function would
-- multiply twice.
local HOOKS = {
    { path = ATTRIBUTE_HOOK, part = "attributes", before = BeforeAttributeMap, after = AfterAttributeMap },
    { path = RESTART_HOOK, part = "objects", before = BeforeClientRestart },
    { path = BACKPACK .. "AddDustNum", part = "dust", before = BeforeAddDust },
    { path = BACKPACK .. "AddPropsByMap", part = "materials", before = ItemHook("AddPropsByMap") },
    { path = BACKPACK .. "AddPropsSilently", part = "materials", before = ItemHook("AddPropsSilently") },
    { path = BACKPACK .. "AddMedicineAmount", part = "consumables", before = BeforeAddMedicine },
}
for _, hook in ipairs(HOOKS) do
    hook.state, hook.tries = "none", 0
end

local function SetHook(hook)
    hook.tries = hook.tries + 1
    if not Valid(StaticFindObject(hook.path)) then
        if hook.tries >= MAX_HOOK_TRIES then
            hook.state = "failed"
            Log("No hook on " .. hook.path .. ": the function is not in the game. Its part changes nothing; a game "
                .. "update may need a new version of the mod.")
        elseif hook.tries == 1 then
            Log("Not ready yet: " .. hook.path .. " is not there; the mod tries again every second.")
        end
        return
    end
    local ok, problem
    if hook.after then
        ok, problem = pcall(RegisterHook, hook.path, hook.before, hook.after)
    else
        ok, problem = pcall(RegisterHook, hook.path, hook.before)
    end
    if not ok then
        hook.state = "failed"
        Log("No hook on " .. hook.path .. ": " .. tostring(problem):match("^[^\n]*") .. ". Its part changes nothing.")
        return
    end
    hook.state = "set"
    Log("Hook set: " .. hook.path .. ".")
end

local function SetHooks()
    for _, hook in ipairs(HOOKS) do
        if hook.state == "none" and use[hook.part] then
            SetHook(hook)
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------------------------------------------------

local reapplyTicks = 0

-- Every TICK_MS on the game thread: the hooks in use, the full passes that are due, the pass of the classes whose
-- objects load during play.
local function Tick()
    SetHooks()
    local due = false
    for i = #countdowns, 1, -1 do
        countdowns[i] = countdowns[i] - 1
        if countdowns[i] <= 0 then
            table.remove(countdowns, i)
            due = true
        end
    end
    if due then
        reapplyTicks = 0
        Pass(true)
        return
    end
    reapplyTicks = reapplyTicks + 1
    if Settings.ReapplySeconds > 0 and reapplyTicks >= Settings.ReapplySeconds then
        reapplyTicks = 0
        Pass(false)
    end
end

local function TickStep()
    local ok, err = pcall(Tick)
    if not ok then
        LogError("Error: " .. tostring(err))
    end
end

-- A changed config.lua is used at once: new hooks, and a full pass that writes the new values (or the game's back).
local function ConfigStep()
    local ok, err = pcall(function()
        if ReadConfig() then
            SetHooks()
            Pass(true)
        end
    end)
    if not ok then
        LogError("Error while reading config.lua: " .. tostring(err))
    end
end

Settings = CopyDefaults()
Eff = Settings
UpdateUse()
Log(VERSION .. " loaded.")
local read, problem = pcall(ReadConfig)
if not read then
    LogError("Error while reading config.lua: " .. tostring(problem))
end
if not Settings.Enable then
    Log("Enable = false in config.lua: the mod changes nothing until it is true.")
end

Schedule(START_PASS_TICKS)
if type(RegisterLoadMapPostHook) == "function" then
    local ok, err = pcall(RegisterLoadMapPostHook, function()
        Schedule(MAP_PASS_TICKS)
    end)
    if not ok then
        Log("No map load callback (" .. tostring(err):match("^[^\n]*") .. "): the config objects are written at the "
            .. "start, after a pawn restart and after a change of config.lua.")
    end
end

-- Both loops run on the game thread (UE4SS's Delayed Action API): no Lua on a second thread (Witch Time's crash
-- lesson). A UE4SS without it gets the old LoopAsync loops, and the log says so.
if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(TICK_MS, TickStep)
    LoopInGameThreadWithDelay(CONFIG_INTERVAL_MS, ConfigStep)
else
    Log("This UE4SS has no game-thread loops (LoopInGameThreadWithDelay): the older LoopAsync is used; a newer UE4SS "
        .. "is safer.")
    LoopAsync(TICK_MS, function()
        ExecuteInGameThread(TickStep)
        -- false keeps the loop running.
        return false
    end)
    LoopAsync(CONFIG_INTERVAL_MS, function()
        ExecuteInGameThread(ConfigStep)
        return false
    end)
end
