"""Offline test of Scripts/main.lua with lupa (Lua 5.4) and small mocks of UE4SS and the game.

The mocks stand in for the UE4SS functions that the script uses (RegisterHook with a callback before and one after
the function, RegisterLoadMapPostHook, StaticFindObject, FindAllOf, the game-thread loops LoopInGameThreadWithDelay,
the old LoopAsync, ExecuteInGameThread, IsInGameThread) and for the game: the character builds through
GetAttributeMap (a map attribute -> value, params with get and set, values stored as 32-bit floats), the config objects
(int, double and 32-bit float properties), and the backpack's reward functions. os.clock is a mock clock (CLOCK).

TICK(n) runs the 1 s loop n times, CONFIG() the 5 s config read. BUILD(asset) runs the two callbacks of the attribute
hook the way the game's GetAttributeMap would and gives the map afterwards (attribute -> value); LEVEL is the level
parameter after the build. DUST(n), MEDICINE(id, n) and ITEMS(function, items) call the reward hooks.

The checks: nothing runs with the shipped config.lua; the attribute rows by class and kind of character, live; the
config objects (which classes are searched when, the game's value kept and written back, no compounding, class
defaults only for shields); the rewards; what happens when the game differs (a missing function, a failed RegisterHook,
a call from another thread, an unreadable map); the settings files a player may have instead of the shipped one; and
that config.lua ships exactly the defaults of main.lua.

Usage:
    python tests/test_main.py        (needs lupa: python -m pip install lupa)

Exit code: 0 = all checks passed, 1 = a check failed.
"""

import json
import re
import sys
import tempfile
from pathlib import Path

from lupa import lua54

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "src" / "phantombladezero_phantomtuner" / "Scripts" / "main.lua"
CONFIG = MAIN.parent / "config.lua"

MOCKS = r"""
LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({...}, "") end
CLOCK = 0
os.clock = function() return CLOCK end

LOOPS, DELAYS, ASYNC_LOOPS = {}, {}, 0
function LoopInGameThreadWithDelay(ms, callback) LOOPS[#LOOPS + 1] = callback DELAYS[#DELAYS + 1] = ms return #LOOPS end
function LoopAsync(ms, callback) ASYNC_LOOPS = ASYNC_LOOPS + 1 LOOPS[#LOOPS + 1] = callback DELAYS[#DELAYS + 1] = ms end
function ExecuteInGameThread(callback) callback() end
IN_GAME_THREAD = true
function IsInGameThread() return IN_GAME_THREAD end
function RUN(ms) for i = 1, #LOOPS do if DELAYS[i] == ms then LOOPS[i]() end end end
function TICK(n) for _ = 1, n or 1 do RUN(1000) end end
function CONFIG() RUN(5000) end
MAP_LOADS = {}
function RegisterLoadMapPostHook(callback) MAP_LOADS[#MAP_LOADS + 1] = callback end
function MAP_LOAD() for _, callback in ipairs(MAP_LOADS) do callback(Obj({}), Obj({})) end end

function Float(value) return (string.unpack("f", string.pack("f", value))) end
function Name(text) return { ToString = function() return text end } end
-- Game objects: methods, and properties in _values. INTS must get whole numbers, FLOATS are stored as 32-bit floats.
INTS = {}
FLOATS = { PrePerfectWindow = true, PerfectWindow = true, PostPerfectWindow = true, FailWindow = true,
    PreHitPointDuration = true, SameLevelMinSeconds = true, CrossLevelMinSeconds = true, NewGameMinSeconds = true,
    SaveLoadMinSeconds = true, FadeInSeconds = true, ImageFadeInSeconds = true, RevealFadeOutSeconds = true,
    GoldenShieldMaxHealthMultiplier = true, GoldenShieldMaxOverride = true }
WRITES, READ_ONLY = 0, false
local nextAddress = 0x1000
local Methods = {
    IsValid = function(self) return rawget(self, "_valid") ~= false end,
    GetAddress = function(self) return rawget(self, "_address") end,
    GetFullName = function(self) return rawget(self, "_full") end,
    GetFName = function(self) return Name(rawget(self, "_name")) end,
    GetOuter = function(self) return rawget(self, "_outer") end,
}
local ObjectMeta = {
    __index = function(self, key)
        if Methods[key] then return Methods[key] end
        return rawget(self, "_values")[key]
    end,
    __newindex = function(self, key, value)
        if READ_ONLY then error("property is read-only", 0) end
        assert(type(value) == "number", key .. " got " .. tostring(value))
        if INTS[key] then assert(math.type(value) == "integer", key .. " got the float " .. tostring(value)) end
        WRITES = WRITES + 1
        rawget(self, "_values")[key] = FLOATS[key] and Float(value) or value
    end,
}
function Obj(fields)
    nextAddress = nextAddress + 0x100
    fields._address = fields._address or nextAddress
    fields._values = fields._values or {}
    for key, value in pairs(fields._values) do
        if FLOATS[key] then fields._values[key] = Float(value) end
    end
    return setmetatable(fields, ObjectMeta)
end
function Param(value) return { get = function() return value end, set = function(_, v) value = v end } end

-- The hooks and the functions the game has.
ATTR = "/Script/PBZCombatAsset.PBZCharacterAttributeDataHelper:GetAttributeMap"
RESTART = "/Script/Engine.PlayerController:ClientRestart"
BACKPACK = "/Script/ProjectPBZ.PBZBackPackSubsystem:"
MISSING = {}
function StaticFindObject(path)
    if MISSING[path] or not (path == ATTR or path == RESTART or path:find(BACKPACK, 1, true)) then
        return Obj({ _valid = false })
    end
    return Obj({ _name = path })
end
HOOKS, HOOK_CALLS, HOOK_MODE, HOOKED = {}, 0, "works", {}
function RegisterHook(path, before, after)
    HOOK_CALLS = HOOK_CALLS + 1
    HOOKED[path] = (HOOKED[path] or 0) + 1
    if HOOK_MODE == "throws" then error("Was unable to register a hook\nstack traceback:\n    [C]: in ?", 0) end
    HOOKS[path] = { before = before, after = after }
    return 1, 2
end

-- Characters: a config asset, and attribute data whose level values belong to it.
function Asset(full, name, tag)
    return Obj({ _full = full, _name = name, _values = { ["Difficulty Tag"] = tag and { TagName = Name(tag) } or nil } })
end
-- tag "None": an empty gameplay tag (its name is None).
local function Enemy(name, tag)
    return Asset("PDA_ActorConfig_C /PBZCombatAsset/ActorData/Enemies/" .. name .. "." .. name, name,
        tag and (tag == "None" and tag or "CharacterType.Difficulty." .. tag))
end
PLAYER = Asset("PDA_ActorConfig_C /PBZCombatAsset/ActorData/Players/Hun/ActorConfig_Hun.ActorConfig_Hun",
    "ActorConfig_Hun")
MOB, ELITE, MINIBOSS, GREATBOSS = Enemy("ActorC_Mob", "Mob"), Enemy("ActorC_Elite", "Elite"),
    Enemy("ActorC_Mini", "MiniBoss"), Enemy("ActorC_Great", "GreatBoss")
UNTAGGED, NONE_TAG, ODD_TAG = Enemy("ActorC_Cart"), Enemy("ActorC_PowerMan", "None"), Enemy("ActorC_Odd", "Strange")
ALLY, CIVILIAN = Enemy("ActorC_LeiDang_NPC", "Elite"), Enemy("ActorC_Nanmin_01", "Mob")
PROP = Asset("PDA_ActorConfig_C /Game/Maps/Valley.Valley:PersistentLevel.BP_Firewood_C_1.ActorConfig", "ActorConfig")
function DATA(asset)
    return { MaxHealth = Obj({ _outer = asset }), Attack = Obj({ _outer = asset }), MaxShachi = Obj({ _outer = asset }) }
end
BAD_DATA = { MaxHealth = Obj({ _valid = false }), Attack = Obj({ _valid = false }), MaxShachi = Obj({ _valid = false }) }

BASE = { { "Health", 850 }, { "Health_Max", 850 }, { "Health_Max_Lv1", 100 }, { "Attack", 100 }, { "Attack_Lv1", 10 },
    { "ShachiAttack", 50 }, { "ShachiAttack_Lv1", 5 }, { "Shachi", 400 }, { "Shachi_Max", 400 },
    { "Shachi_Max_Lv1", 40 }, { "Infliction_Max", 200 }, { "Infliction_Max_Lv1", 20 }, { "ShachiRegen", 0.5 },
    { "ShachiRegenCooldown", 1 }, { "UltimateCharge_Max", 100 }, { "UltimateChargeCount_Max", 1 },
    { "WalkSpeed", 200 }, { "JogSpeed", 450 }, { "SprintSpeed", 600 }, { "CrouchSpeed", 150 },
    { "BreakDurationAdditionalMultiplier", 0 }, { "Resistance_Poise", 100 }, { "Resistance_Fire", 50 } }
-- NO_NAMES: keys without a readable name. MAP_READ_ONLY: values that cannot be written.
NO_NAMES, MAP_READ_ONLY = false, false
function MAP(entries)
    return { ForEach = function(self, callback)
        for _, entry in ipairs(entries) do
            local key = { get = function() return { AttributeName = NO_NAMES and 5 or Name(entry[1]) } end }
            callback(key, {
                get = function() return entry[2] end,
                set = function(_, value)
                    if MAP_READ_ONLY then error("read-only", 0) end
                    entry[2] = Float(value)
                end,
            })
        end
    end }
end
LEVEL = 30
function BUILD(asset)
    local entries = {}
    for i, entry in ipairs(BASE) do entries[i] = { entry[1], entry[2] } end
    LEVEL = 30
    local hook = HOOKS[ATTR]
    if hook then
        local data = asset and DATA(asset) or BAD_DATA
        local level = { get = function() return LEVEL end, set = function(_, value) LEVEL = value end }
        local map = MAP(entries)
        hook.before(Param(Obj({})), Param(data), level, Param(map))
        hook.after(Param(Obj({})), Param(data), level, Param(map))
    end
    local values = {}
    for _, entry in ipairs(entries) do values[entry[1]] = entry[2] end
    return values
end

-- Rewards: the hook before the game's function; the amount the game gets.
function DUST(amount)
    local param = Param(amount)
    if HOOKS[BACKPACK .. "AddDustNum"] then HOOKS[BACKPACK .. "AddDustNum"].before(Param(Obj({})), param) end
    return param:get()
end
function MEDICINE(id, amount)
    local param = Param(amount)
    local hook = HOOKS[BACKPACK .. "AddMedicineAmount"]
    if hook then hook.before(Param(Obj({})), Param(Name(id)), param) end
    return param:get()
end
function ITEMS(name, items)
    local entries = {}
    for i, item in ipairs(items) do entries[i] = { item[1], item[2] } end
    local map = { ForEach = function(self, callback)
        for _, entry in ipairs(entries) do
            callback({ get = function() return Name(entry[1]) end },
                { get = function() return entry[2] end, set = function(_, value) entry[2] = value end })
        end
    end }
    local hook = HOOKS[BACKPACK .. name]
    if hook then hook.before(Param(Obj({})), Param(map), Param(true)) end
    local values = {}
    for _, entry in ipairs(entries) do values[entry[1]] = entry[2] end
    return values
end

-- The config objects, found by class.
local function Config(name, values) return Obj({ _name = name, _full = name, _values = values }) end
local function Combat(name, mobBreak)
    return Config(name, { ["Mob Break Duration"] = mobBreak, ["Mob SimpleExe Break Duration"] = 4,
        ["DynamicBreakAdditionalDuration"] = 2, ["Mob Break Damage Multiplier"] = 1.5, ["Player Break Duration"] = 3,
        ["Player Break Damage Multiplier"] = 1, ["Lie Duration"] = 1, ["Deflect Ultimate Charge Multiplier Normal"] = 0.9,
        ["Deflect Ultimate Charge Multiplier Perfect"] = 0.9, ["Deflect Ultimate Charge Multiplier Perfect Dodge"] = 0.9,
        ["Attack Ultimate Charge Multiplier"] = 2.9 })
end
NORMAL, EASY, COMBAT_CDO = Combat("GlobalConfig_Combat_Normal", 4), Combat("GlobalConfig_Combat_Easy", 3),
    Combat("Default__PDA_GlobalCombatConfig_C", 0)
LOADING = Config("DestinationLoadingConfig", { SameLevelMinSeconds = 3, CrossLevelMinSeconds = 5, NewGameMinSeconds = 4,
    SaveLoadMinSeconds = 5, FadeInSeconds = 0.5, ImageFadeInSeconds = 0.5, RevealFadeOutSeconds = 1 })
function Widget(name) return Config(name, { MaxLoadTime = 60 }) end
WIDGET = Widget("WB_TempLoadingScreen_C_1")
-- An override of -1 is a marker; 123456.7 x0.3 is not exact as a 32-bit float.
SHIELD_CDO = Config("Default__GA_GoldenBodyShield_Passive_C",
    { GoldenShieldMaxHealthMultiplier = 0.2, GoldenShieldMaxOverride = -1 })
SHIELD_BIG_CDO = Config("Default__GA_GoldenBodyShield_Big_C",
    { GoldenShieldMaxHealthMultiplier = 0.2, GoldenShieldMaxOverride = 123456.7 })
SHIELD_INSTANCE = Config("GA_GoldenBodyShield_Passive_C_1",
    { GoldenShieldMaxHealthMultiplier = 0.2, GoldenShieldMaxOverride = 0 })
INSTANCES = {
    PDA_GlobalCombatConfig_C = { NORMAL, EASY, COMBAT_CDO },
    PBZDestinationLoadingConfig = { LOADING },
    WB_TempLoadingScreen_C = { WIDGET },
    GA_GoldenBodyShield_PassiveBase = { SHIELD_CDO, SHIELD_BIG_CDO, SHIELD_INSTANCE },
}
FIND_ALL, FINDS = {}, 0
function FindAllOf(class)
    FIND_ALL[class] = (FIND_ALL[class] or 0) + 1
    FINDS = FINDS + 1
    local list = INSTANCES[class]
    if not list or #list == 0 then return nil end
    return list
end
function FOUND(class) return FIND_ALL[class] or 0 end
"""

PLAYER_CONFIGS = [
    ("no config.lua", None, "No config.lua"),
    ("an empty or older config.lua", "return {}\n", None),
    ("a broken config.lua", "return {\n    Enable =\n", "config.lua not read"),
    ("a config.lua without a table", "-- nothing here\n", "does not return a table"),
    ("a config.lua with wrong types", "wrong types", "must be a"),
    ("a config.lua with an unknown setting", "return { NoSuchSetting = 1 }\n", "unknown setting NoSuchSetting"),
]
DEFAULT_LINE = "all at their defaults: every value is the game's own, so the mod changes nothing."


def lua_path(path: Path) -> str:
    return "[[" + path.as_posix() + "]]"


class Run:
    """main.lua in a fresh Lua state, with config.lua read from config_folder; before: Lua run before main.lua."""

    def __init__(self, config_folder: Path, before: str = ""):
        self.folder = config_folder
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        self.lua.execute(f'package.path = {lua_path(config_folder)} .. "/?.lua"; package.cpath = ""')
        if before:
            self.lua.execute(before)
        self.g = self.lua.globals()
        self.do(MAIN.read_text(encoding="utf-8"))

    def do(self, code: str):
        """Runs Lua code; a Lua error that stops it becomes an "Error" line in the log, so the checks fail."""
        try:
            return self.lua.execute(code)
        except lua54.LuaError as error:
            self.g.LOG[len(self.g.LOG) + 1] = "Error: main.lua stopped: " + str(error).splitlines()[0]

    def eval(self, expression: str):
        try:
            return self.lua.eval(expression)
        except lua54.LuaError as error:
            self.g.LOG[len(self.g.LOG) + 1] = "Error: test expression failed: " + str(error).splitlines()[0]
            return None

    def log(self):
        return [self.g.LOG[i].rstrip() for i in range(1, len(self.g.LOG) + 1)]

    def count(self, text: str) -> int:
        return sum(text in line for line in self.log())

    def write_config(self, text: str):
        (self.folder / "config.lua").write_text(text, encoding="utf-8")


def settings_lines(log):
    return [line.split("] Settings: ", 1)[1] for line in log if "] Settings: " in line]


def main() -> None:
    version = json.loads((ROOT / "mod.json").read_text(encoding="utf-8"))["version"]
    failures = []

    def check(condition, text):
        print(("ok    " if condition else "FAIL  ") + text)
        if not condition:
            failures.append(text)

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        shipped_text = CONFIG.read_text(encoding="utf-8")
        counter = [0]

        def folder(text=shipped_text):
            counter[0] += 1
            f = temp / f"run{counter[0]}"
            f.mkdir()
            if text is not None:
                (f / "config.lua").write_text(text, encoding="utf-8")
            return f

        def config(**values):
            """The shipped config.lua with other values, for example config(EnemyHealth="2")."""
            text = shipped_text
            for name, value in values.items():
                lines = [line for line in text.splitlines() if line.strip().startswith(name + " = ")]
                assert len(lines) == 1, name
                # A shipped value has no comma, so the first comma ends it.
                old = lines[0].split(",", 1)[0]
                text = text.replace(old + ",", f"    {name} = {value},", 1)
            return text

        def started(name, text, before=""):
            run = Run(folder(text), before)
            return run, run.eval

        def clean(run):
            return not any("Error" in line for line in run.log())

        # --- The mod as players get it: nothing runs.
        r, e = started("shipped", shipped_text)
        for line in r.log():
            print("      log: " + line)
        check(list(r.g.DELAYS.values()) == [1000, 5000] and r.g.ASYNC_LOOPS == 0,
              "game-thread loops: the tick every 1 s, the config read every 5 s")
        check(any(f"{version} loaded." in line for line in r.log()), f"load line with the version {version} of mod.json")
        check(settings_lines(r.log()) == [DEFAULT_LINE] and not any("config.lua" in line for line in r.log()),
              "one settings line: all at their defaults, no warning")
        r.do("TICK(12) MAP_LOAD() TICK(4) CONFIG() TICK(6)")
        check(e("HOOK_CALLS") == 0 and e("FINDS") == 0 and len(r.log()) == 2,
              "the shipped config.lua: no hook, no search, no line after the start (also after a map load)")
        check(e("BUILD(MOB).Health_Max") == 850 and e("DUST(10)") == 10, "the game's values stay")

        # --- Part 1: the attribute rows.
        r, e = started("rows", config(EnemyHealth="{ all = 2, boss = 3 }", PlayerAttack="1.5", LogSpawns="true"))
        r.do("TICK()")
        check(e("HOOK_CALLS") == 1 and e("HOOKS[ATTR] ~= nil and HOOKS[ATTR].after ~= nil")
              and r.count("Hook set: " + "/Script/PBZCombatAsset.PBZCharacterAttributeDataHelper:GetAttributeMap.") == 1,
              "attribute rows: one hook on GetAttributeMap, with a callback before and one after; no other hook")
        r.do("TICK(12) MAP_LOAD() TICK(3)")
        check(e("FINDS") == 0 and e("HOOK_CALLS") == 1, "attribute rows only: no config object is searched")
        check(e("BUILD(MOB).Health") == 1700 and e("BUILD(MOB).Health_Max") == 1700
              and e("BUILD(MOB).Health_Max_Lv1") == 200 and e("BUILD(MOB).Attack") == 100
              and e("BUILD(MOB).Shachi_Max") == 400, "a Mob: health x2 (start value, maximum, level 1), the rest stays")
        check(r.count("enemy ActorC_Mob (mob): 3 value(s) scaled: Health 850->1700, Health_Max 850->1700, "
                      "Health_Max_Lv1 100->200") >= 1, "LogSpawns: a line with the class and the old and new values")
        check(e("BUILD(GREATBOSS).Health_Max") == 2550 and e("BUILD(MINIBOSS).Health_Max") == 1700
              and e("BUILD(ELITE).Health_Max") == 1700, "boss x3 for a GreatBoss; a MiniBoss and an Elite use all")
        check(e("BUILD(UNTAGGED).Health_Max") == 1700 and e("BUILD(NONE_TAG).Health_Max") == 1700
              and e("BUILD(ODD_TAG).Health_Max") == 1700, "no tag, the tag None and an unknown tag: all")
        check(e("BUILD(PLAYER).Attack") == 150 and e("BUILD(PLAYER).Attack_Lv1") == 15
              and e("BUILD(PLAYER).Health_Max") == 850 and e("BUILD(PLAYER).Health") == 850,
              "the player: attack x1.5; no player health row (Max Health and Sha-Chi does that)")
        check(e("BUILD(ALLY).Health_Max") == 850 and e("BUILD(CIVILIAN).Health_Max") == 850
              and e("BUILD(PROP).Health_Max") == 850 and r.count("ally ActorC_LeiDang_NPC (elite): left alone") >= 1,
              "allies, civilians and level props stay")
        check(e("BUILD(MOB).Attack") == 100 and e("BUILD(GREATBOSS).Attack") == 100, "enemies' attack: the player's row does not reach them")
        check(e("BUILD(nil).Health_Max") == 850 and r.count("has no config asset behind it") == 1,
              "attribute data without a config asset: stays, one line")
        r.do("IN_GAME_THREAD = false")
        check(e("BUILD(MOB).Health_Max") == 850 and r.count("A call of GetAttributeMap came from another thread") == 1,
              "a call from another thread: the build stays, one line")
        r.do("IN_GAME_THREAD = true")
        check(clean(r), "no error line so far")

        r.write_config(config(EnemyHealth="{ all = 2, boss = 3 }", ScaleUntagged="false", ScaleAllies="true",
                              ScaleProps="true"))
        r.do("CONFIG()")
        check(r.count("Attribute values reach the characters that the game builds from now on") == 1,
              "a changed row: the hint about the next build")
        check(e("BUILD(UNTAGGED).Health_Max") == 850 and e("BUILD(NONE_TAG).Health_Max") == 850
              and e("BUILD(MOB).Health_Max") == 1700, "ScaleUntagged = false: untagged enemies stay")
        check(e("BUILD(ALLY).Health_Max") == 1700 and e("BUILD(PROP).Health_Max") == 1700,
              "ScaleAllies and ScaleProps: allies and props are scaled too")
        r.write_config(config(EnemyAttributes="{ Resistance_Poise = { all = 0.5, boss = 1 } }",
                              PlayerAttributes="{ Resistance_Fire = 2 }"))
        r.do("CONFIG()")
        check(e("BUILD(MOB).Resistance_Poise") == 50 and e("BUILD(GREATBOSS).Resistance_Poise") == 100
              and e("BUILD(PLAYER).Resistance_Fire") == 100 and e("BUILD(MOB).Resistance_Fire") == 50
              and e("BUILD(MOB).Health_Max") == 850, "the free attribute tables, by class for enemies")
        r.write_config(config(PlayerUltimateCharges="2.6", PlayerSpeed="1.1", PlayerUltimateBar="0.5"))
        r.do("CONFIG()")
        check(e("BUILD(PLAYER).UltimateChargeCount_Max") == 3 and abs(e("BUILD(PLAYER).JogSpeed") - 495) < 1e-3
              and e("BUILD(PLAYER).WalkSpeed") == 200 and e("BUILD(PLAYER).UltimateCharge_Max") == 50
              and e("BUILD(MOB).UltimateChargeCount_Max") == 1,
              "ultimate charges 2.6: a whole count (3); player speed: jog and sprint only; ultimate bar")
        r.write_config(config(EnemyLevelOffset="5", LogSpawns="true"))
        r.do("CONFIG()")
        check(e("(function() BUILD(MOB) return LEVEL end)()") == 35
              and e("(function() BUILD(PLAYER) return LEVEL end)()") == 30
              and e("(function() BUILD(ALLY) return LEVEL end)()") == 30,
              "EnemyLevelOffset 5: an enemy's level 30 -> 35; the player and allies keep theirs")
        check(r.count("enemy ActorC_Mob (mob) level 30->35: nothing to change") >= 1, "the level is named in the log")
        r.write_config(config(EnemyLevelOffset="-100"))
        r.do("CONFIG()")
        check(e("(function() BUILD(MOB) return LEVEL end)()") == 1, "a level offset never goes below level 1")
        r.write_config(config(EnemyBreakDuration="2", PlayerBreakDuration="1.5", BreakAttribute="true"))
        r.do("CONFIG()")
        check(e("BUILD(MOB).BreakDurationAdditionalMultiplier") == 1
              and e("BUILD(PLAYER).BreakDurationAdditionalMultiplier") == 0.5
              and r.count("Break values reach the characters that spawn from now on") >= 1,
              "BreakAttribute: the break multiplier - 1 in the attribute, for enemies and the player")
        r.write_config(config(EnemyBreakDuration="2", PlayerBreakDuration="1.5", EnemyHealth="2", PlayerAttack="2"))
        r.do("CONFIG()")
        check(e("BUILD(MOB).BreakDurationAdditionalMultiplier") == 0 and e("BUILD(MOB).Health_Max") == 1700
              and e("BUILD(PLAYER).BreakDurationAdditionalMultiplier") == 0,
              "BreakAttribute = false: the attribute stays while other rows change the build")
        r.write_config(config(EnemyHealth="2", Enable="false"))
        r.do("CONFIG()")
        check(e("BUILD(MOB).Health_Max") == 850, "Enable = false (live): builds stay")
        r.write_config(config(EnemyHealth="2"))
        r.do("CONFIG()")
        check(e("BUILD(MOB).Health_Max") == 1700 and e("HOOKED[ATTR]") == 1, "Enable again: scaled again, the same hook")
        r.write_config("return {\n    EnemyHealth =\n")
        r.do("CONFIG()")
        check(r.count("config.lua not read (line") == 1 and r.count("the last settings stay") == 1
              and e("BUILD(MOB).Health_Max") == 1700, "a broken (half-saved) file keeps the last settings")
        r.write_config(shipped_text)
        r.do("CONFIG()")
        check(e("BUILD(MOB).Health_Max") == 850 and e("BUILD(PLAYER).Attack") == 100 and clean(r),
              "the shipped file again: every build as the game made it")

        detail, e2 = started("detail", config(EnemyHealth="2", PlayerAttack="1.5", LogDetail="true"))
        detail.do("TICK() BUILD(MOB) BUILD(ELITE) BUILD(PLAYER) BUILD(PLAYER)")
        check(detail.count("attribute map of the first enemy (ActorC_Mob), 23 entries: Health=850,") == 1
              and detail.count("attribute map of the first") == 2,
              "LogDetail: the whole map once per kind of character")

        broken, e3 = started("names", config(EnemyHealth="2"), "NO_NAMES = true")
        broken.do("TICK() BUILD(MOB) BUILD(MOB)")
        check(broken.count("names cannot be read") == 1, "map keys without names: one line")
        broken.do("NO_NAMES = false MAP_READ_ONLY = true")
        check(e3("BUILD(MOB).Health_Max") == 850 and broken.count("cannot be written on this game version (3)") == 1,
              "map values that cannot be written: one line")

        # --- Part 2: config objects.
        r, e = started("breaks", config(EnemyBreakDuration="1.5"))
        r.do("TICK(4)")
        check(e("HOOK_CALLS") == 1 and e("HOOKS[RESTART] ~= nil") and e("FINDS") == 0,
              "config objects in use: the ClientRestart hook; no search before the first pass (5 s)")
        r.do("TICK()")
        check(e("FOUND('PDA_GlobalCombatConfig_C')") == 1 and e("FINDS") == 1,
              "the first pass after 5 s searches only the class in use")
        check(e("NORMAL['Mob Break Duration']") == 6 and e("EASY['Mob Break Duration']") == 4.5
              and e("NORMAL['DynamicBreakAdditionalDuration']") == 3 and e("COMBAT_CDO['Mob Break Duration']") == 0,
              "enemy break duration x1.5 on every difficulty (4 -> 6, 3 -> 4.5, the bosses' dynamic 2 -> 3); the class "
              "default stays")
        check(r.count("Config objects: 1 classes searched, 2 objects, 6 values written.") == 1, "one line for the pass")
        r.do("TICK(20)")
        check(e("FINDS") == 1, "a class that loads with the game is not searched on the timer")
        r.do("MAP_LOAD() TICK()")
        check(e("FINDS") == 2 and e("NORMAL['Mob Break Duration']") == 6 and e("WRITES") == 6,
              "a map load: a pass 1 s later, nothing written twice")
        r.do("HOOKS[RESTART].before(Param(Obj({}))) TICK(2)")
        check(e("FINDS") == 2, "a pawn restart: no pass after 2 s")
        r.do("TICK()")
        check(e("FINDS") == 3, "a pawn restart: a pass after 3 s")
        r.write_config(config(EnemyBreakDuration="2"))
        r.do("CONFIG()")
        check(e("NORMAL['Mob Break Duration']") == 8 and e("EASY['Mob Break Duration']") == 6,
              "a changed multiplier works at once, from the game's value (4 x2 = 8, not 6 x2)")
        r.do("NORMAL._values['Mob Break Duration'] = 5 MAP_LOAD() TICK()")
        check(e("NORMAL['Mob Break Duration']") == 10, "a value the game wrote is taken as the game's (5 x2)")
        finds = e("FINDS")
        r.write_config(shipped_text)
        r.do("CONFIG()")
        check(e("NORMAL['Mob Break Duration']") == 5 and e("EASY['Mob Break Duration']") == 3
              and e("NORMAL['DynamicBreakAdditionalDuration']") == 2 and e("FINDS") == finds + 1,
              "back to the shipped file: the game's values are written back at once")
        r.do("MAP_LOAD() TICK(3) CONFIG() TICK(10)")
        check(e("FINDS") == finds + 1, "after that the class is not searched any more")
        check(clean(r), "no error line in the break run")

        r, e = started("objects", config(EnemyBreakDuration="2", LoadingMinSeconds="0", EnemyShield="0.3",
                                         LoadingWidgetMaxTime="120"))
        r.do("TICK(5)")
        check(e("FOUND('PDA_GlobalCombatConfig_C')") == 1 and e("FOUND('PBZDestinationLoadingConfig')") == 1
              and e("FOUND('GA_GoldenBodyShield_PassiveBase')") == 1 and e("FOUND('WB_TempLoadingScreen_C')") == 1,
              "the first pass searches the classes in use only")
        check(e("NORMAL['Mob Break Duration']") == 8 and e("NORMAL['DynamicBreakAdditionalDuration']") == 4
              and e("NORMAL['Mob SimpleExe Break Duration']") == 8 and e("NORMAL['Player Break Duration']") == 3,
              "enemy break duration x2, also the bosses' dynamic break; the player's stays")
        check(e("LOADING.SameLevelMinSeconds") == 0 and e("LOADING.SaveLoadMinSeconds") == 0
              and e("LOADING.FadeInSeconds") == 0.5 and e("WIDGET.MaxLoadTime") == 120,
              "loading minimum 0, the widget's limit 120 s; the fade stays")
        check(abs(e("SHIELD_CDO.GoldenShieldMaxHealthMultiplier") - 0.06) < 1e-6
              and e("SHIELD_CDO.GoldenShieldMaxOverride") == -1
              and e("SHIELD_BIG_CDO.GoldenShieldMaxOverride") == e("Float(Float(123456.7) * 0.3)")
              and abs(e("SHIELD_INSTANCE.GoldenShieldMaxHealthMultiplier") - 0.2) < 1e-6,
              "shields x0.3 on the class defaults only; an override of -1 (a marker) stays")
        r.do("INSTANCES.WB_TempLoadingScreen_C[2] = Widget('WB_TempLoadingScreen_C_2') TICK(4)")
        check(e("INSTANCES.WB_TempLoadingScreen_C[2].MaxLoadTime") == 60, "a new loading widget: not yet at 4 s")
        r.do("TICK()")
        check(e("INSTANCES.WB_TempLoadingScreen_C[2].MaxLoadTime") == 120
              and e("FOUND('WB_TempLoadingScreen_C')") == 2 and e("FOUND('PDA_GlobalCombatConfig_C')") == 1,
              "after ReapplySeconds (5): the new widget gets the value; only the classes that load during play")
        r.do("TICK(30) MAP_LOAD() TICK() MAP_LOAD() TICK()")
        check(e("WIDGET.MaxLoadTime") == 120 and e("SHIELD_BIG_CDO.GoldenShieldMaxOverride")
              == e("Float(Float(123456.7) * 0.3)") and e("NORMAL['Mob Break Duration']") == 8,
              "many passes: no value is multiplied twice (32-bit floats too)")
        r.write_config(config(EnemyBreakDuration="2", LoadingMinSeconds="0", EnemyShield="0.3",
                              LoadingWidgetMaxTime="120", Enable="false"))
        r.do("CONFIG()")
        check(e("WIDGET.MaxLoadTime") == 60 and e("NORMAL['Mob Break Duration']") == 4
              and e("LOADING.SameLevelMinSeconds") == 3
              and abs(e("SHIELD_CDO.GoldenShieldMaxHealthMultiplier") - 0.2) < 1e-6
              and e("SHIELD_BIG_CDO.GoldenShieldMaxOverride") == e("Float(123456.7)"),
              "Enable = false (live): every config value back to the game's at once")
        finds = e("FINDS")
        r.do("TICK(20)")
        check(e("FINDS") == finds, "Enable = false: no more searches")
        check(clean(r), "no error line in the config objects run")

        r, e = started("reapply", config(LoadingWidgetMaxTime="120", ReapplySeconds="0"))
        r.do("TICK(30)")
        check(e("FOUND('WB_TempLoadingScreen_C')") == 1, "ReapplySeconds = 0: only the first pass")
        r.do("MAP_LOAD() TICK()")
        check(e("FOUND('WB_TempLoadingScreen_C')") == 2, "ReapplySeconds = 0: a map load still gives a pass")

        stuck, e4 = started("stuck", config(LoadingWidgetMaxTime="120"), "READ_ONLY = true")
        stuck.do("TICK(5) for _ = 1, 14 do MAP_LOAD() TICK() end")
        check(stuck.count("Error while writing WB_TempLoadingScreen_C: property is read-only") == 10
              and e4("WIDGET.MaxLoadTime") == 60, "a property that cannot be written: at most 10 error lines")

        # --- Part 3: rewards.
        r, e = started("rewards", config(RewardDust="2", LogRewards="true"))
        r.do("TICK()")
        check(e("HOOK_CALLS") == 1 and e("HOOKS[BACKPACK .. 'AddDustNum'] ~= nil")
              and e("HOOKS[BACKPACK .. 'AddDustNum'].after == nil"), "RewardDust: one hook (before AddDustNum)")
        check(e("DUST(10)") == 20 and e("DUST(0)") == 0 and r.count("Dust: 10 -> 20 (x2)") == 1,
              "Dust x2; 0 stays; LogRewards line")
        r.do("IN_GAME_THREAD = false")
        check(e("DUST(10)") == 10, "a call from another thread: the amount stays")
        r.do("IN_GAME_THREAD = true")
        # 50 x 1.1 is 55.00000000000001 in doubles: it must stay 55 with "up".
        for rounding, dust3, dust50 in (('"up"', 4, 55), ('"down"', 3, 55), ('"nearest"', 3, 55)):
            r.write_config(config(RewardDust="1.1", RewardRounding=rounding))
            r.do("CONFIG()")
            check(e("DUST(3)") == dust3 and e("DUST(50)") == dust50,
                  f"RewardRounding {rounding}: 3 x1.1 -> {dust3}, 50 x1.1 -> {dust50}")
        r.write_config(config(RewardDust="0.1", RewardRounding='"down"'))
        r.do("CONFIG()")
        check(e("DUST(3)") == 1, "a reward of 1 or more never drops to 0")
        r.write_config(config(RewardMaterials="2", RewardConsumables="3", LogRewards="true"))
        r.do("CONFIG()")
        check(e("DUST(10)") == 10 and e("HOOKED[BACKPACK .. 'AddDustNum']") == 1,
              "RewardDust back at 1: the hook stays, the amount stays")
        check(e("HOOK_CALLS") == 4, "RewardMaterials and RewardConsumables: three more hooks, set with the config read")
        r.do("A = ITEMS('AddPropsByMap', { { 'Weapon_Material_01', 3 }, { 'Story_Item_01', 1 } })")
        check(e("A.Weapon_Material_01") == 6 and e("A.Story_Item_01") == 1
              and r.count("Story_Item_01 x1 left alone (not an upgrade material)") == 1,
              "materials x2; a story item stays")
        r.do("B = ITEMS('AddPropsSilently', { { 'Weapon_Material_01', 6 }, { 'Story_Item_01', 1 } })")
        check(e("B.Weapon_Material_01") == 6 and r.count("the same item map as the call before; left alone") == 1,
              "the same map in AddPropsSilently right after: not multiplied twice")
        r.do("CLOCK = CLOCK + 1 C = ITEMS('AddPropsSilently', { { 'Weapon_Material_01', 6 } })")
        check(e("C.Weapon_Material_01") == 12, "the same items a second later: a new pickup, multiplied")
        check(e("MEDICINE('Medicine_01', 1)") == 3, "consumables x3")
        r.write_config(config(RewardMaterials="2", RewardAllItems="true"))
        r.do("CONFIG() CLOCK = CLOCK + 1")
        check(e("ITEMS('AddPropsByMap', { { 'Story_Item_01', 1 } }).Story_Item_01") == 2
              and e("MEDICINE('Medicine_01', 1)") == 1, "RewardAllItems: every item; consumables back at 1")
        check(clean(r), "no error line in the rewards run")

        # --- A game that differs from what the mod knows.
        late, e = started("late", config(EnemyHealth="2"), "MISSING[ATTR] = true")
        late.do("TICK(3)")
        check(e("HOOK_CALLS") == 0 and late.count("Not ready yet: " + "/Script/PBZCombatAsset") == 1,
              "a function that is not there yet: no hook, one line")
        late.do("MISSING[ATTR] = nil TICK()")
        check(e("HOOK_CALLS") == 1 and e("BUILD(MOB).Health_Max") == 1700, "it is there a moment later: the hook works")
        never, e = started("never", config(RewardDust="2"), "MISSING[BACKPACK .. 'AddDustNum'] = true")
        never.do("TICK(40)")
        check(e("HOOK_CALLS") == 0 and never.count("No hook on " + "/Script/ProjectPBZ.PBZBackPackSubsystem:AddDustNum: "
                                                  "the function is not in the game") == 1
              and never.count("Not ready yet") == 1, "a function missing for good: 30 tries, two lines in all")
        throws, e = started("throws", config(EnemyHealth="2"), "HOOK_MODE = 'throws'")
        throws.do("TICK() HOOK_MODE = 'works' TICK(5)")
        check(e("HOOK_CALLS") == 1 and throws.count("No hook on " + "/Script/PBZCombatAsset.PBZCharacterAttributeDataHelper"
                                                    ":GetAttributeMap: Was unable to register a hook. Its part") == 1
              and not any("traceback" in line for line in throws.log()),
              "RegisterHook fails: one line (its first), no second try")
        old, e = started("old", config(EnemyHealth="2"), "LoopInGameThreadWithDelay = nil")
        old.do("TICK()")
        check(old.eval("ASYNC_LOOPS") == 2 and old.count("no game-thread loops") == 1
              and e("BUILD(MOB).Health_Max") == 1700, "a UE4SS without game-thread loops: LoopAsync, and a log line")

        # --- Checks of the values in config.lua.
        r, e = started("limits", config(EnemyHealth="1000", EnemyAttack="0", EnemyShaChi="{ all = 2, bosses = 3 }",
                                        RewardRounding='"sideways"', LoadingWidgetMaxTime="1000",
                                        LoadingMinSeconds="-5", EnemyLevelOffset="500",
                                        PlayerAttributes='{ ["bad name"] = 2, Attack = "x" }'))
        log = r.log()
        expected = ["EnemyHealth = 1000 is outside 0.01 to 100; 100 is used.",
                    "EnemyAttack = 0 is 0 or less; 1 (the game's value) is used.",
                    "EnemyShaChi.bosses is not a class",
                    "RewardRounding must be \"nearest\", \"up\" or \"down\"",
                    "LoadingWidgetMaxTime = 1000 is outside 0 to 600; 600 is used.",
                    "EnemyLevelOffset = 500 is outside -100 to 100; 100 is used.",
                    "PlayerAttributes: bad name is not an attribute name",
                    "PlayerAttributes.Attack must be a number"]
        check(all(sum(text in line for line in log) == 1 for text in expected) and not any("LoadingMinSeconds" in line
                                                                                          and "config.lua:" in line
                                                                                          for line in log),
              "values out of range are clamped or ignored, each with one line; a negative absolute value is the game's")
        line = settings_lines(log)[0]
        check("EnemyHealth=100" in line and "EnemyShaChi=2" in line and "LoadingWidgetMaxTime=600" in line
              and "EnemyAttack" not in line and "LoadingMinSeconds" not in line and "RewardRounding" not in line,
              f"the settings line names the values in use ({line})")

        # --- The settings files a player may have.
        defaults_block = re.search(r"^local DEFAULTS = (\{.*?^\})", MAIN.read_text(encoding="utf-8"), re.S | re.M)
        r, e = started("ships", shipped_text)
        r.do(f"MAIN_DEFAULTS = (function() return {defaults_block.group(1)} end)() SHIPPED = dofile({lua_path(CONFIG)})")
        same = r.eval("""(function()
            local function same(a, b)
                if type(a) ~= type(b) then return false end
                if type(a) ~= "table" then return a == b end
                for k, v in pairs(a) do if not same(v, b[k]) then return false end end
                for k in pairs(b) do if a[k] == nil then return false end end
                return true
            end
            return same(MAIN_DEFAULTS, SHIPPED)
        end)()""")
        count = len(list(r.eval("SHIPPED").keys()))
        check(same is True and count == len(list(r.eval("MAIN_DEFAULTS").keys())),
              f"config.lua ships exactly the defaults of main.lua ({count} settings)")
        for case, content, expected_line in PLAYER_CONFIGS:
            if content == "wrong types":
                content = r.eval(r"""(function()
                    local lines = {}
                    for name, value in pairs(SHIPPED) do
                        lines[#lines + 1] = string.format("    [%q] = %s,", name, type(value) == "string" and "0" or '"wrong"')
                    end
                    return "return {\n" .. table.concat(lines, "\n") .. "\n}\n"
                end)()""")
            run = Run(folder(content))
            run.do("TICK(12) MAP_LOAD() TICK(3) CONFIG()")
            log = run.log()
            fine = (settings_lines(log) == [DEFAULT_LINE] and len(run.g.LOOPS) == 2 and run.eval("HOOK_CALLS") == 0
                    and run.eval("FINDS") == 0 and clean(run))
            if expected_line is None:
                fine = fine and not any("config.lua" in line for line in log)
            else:
                fine = fine and sum(expected_line in line for line in log) == (count if "wrong" in case else 1)
            check(fine, f"{case}: starts with the defaults, changes nothing"
                  + (f", logs '{expected_line}' once per setting" if "wrong" in case
                     else (f", logs '{expected_line}' once" if expected_line else ", no warning")))
            if not fine:
                for line in log:
                    print("      log: " + line)
        off, e = started("off", config(EnemyHealth="2", RewardDust="2", Enable="false"))
        off.do("TICK(12)")
        check(off.count("changes nothing until it is true") == 1 and e("HOOK_CALLS") == 0 and e("FINDS") == 0
              and len(off.g.LOOPS) == 2, "Enable = false at start: no hook, no search, the loops are there")
        off.write_config(config(EnemyHealth="2", RewardDust="2"))
        off.do("CONFIG()")
        check(e("HOOK_CALLS") == 2 and e("BUILD(MOB).Health_Max") == 1700 and e("DUST(5)") == 10,
              "Enable = true later (live): the hooks are set at once and work")

    print(f"\n{'All checks passed' if not failures else str(len(failures)) + ' check(s) FAILED'}.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
