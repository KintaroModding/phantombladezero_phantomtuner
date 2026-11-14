-- Settings of Phantom Tuner. Change a value and save the file: the mod reads it again every 5 seconds.
-- Every value here is the game's own: a multiplier of 1 (or an absolute value of -1) leaves that value as the game
-- made it, so this file as shipped changes nothing.
-- A file it cannot read (for example while it is saved) keeps the last settings.
-- A setting that this file does not have keeps its default, so an older copy of the file still works after an update.
--
-- When a change shows:
-- - Enemy and player rows (health, attack, Sha-Chi, speed, level, attribute tables): for characters that the game
--   builds after the change. Quit to the main menu and load the save; a rest at a bell is not enough, and enemies
--   that already stand keep their values.
-- - Loading and ultimate values: at once. Break values and shields: for characters that spawn after
--   the change.
return {
    Enable = true,                 -- false: the mod changes nothing, the game's values come back

    -- ENEMIES ---------------------------------------------------------------------------------------------------
    -- A multiplier for every enemy (2 = double, 0.5 = half), or a table by the game's enemy class:
    --   { all = 1, mob = 1, standard = 1, elite = 1, miniboss = 1, boss = 2 }
    --   all: every enemy; boss: NormalBoss, GreatBoss and UltimateBoss together; normalboss, greatboss and
    --   ultimateboss: one boss class; untagged: the few enemies without a class tag. A class that the table does
    --   not name uses `all`.
    -- The game itself scales by difficulty on top of this: on Normal, Mob and Standard enemies get x0.8 health and
    -- x0.4 Sha-Chi, Elites x0.6 Sha-Chi, bosses x0.8 Sha-Chi. Multipliers from 0.01 to 100.
    EnemyHealth = 1,               -- their health
    EnemyAttack = 1,               -- the damage of their attacks to your health
    EnemyShaChiAttack = 1,         -- the damage of their attacks to your Sha-Chi
    EnemyShaChi = 1,               -- their Sha-Chi bar (lower: they break sooner)
    EnemyInfliction = 1,           -- the status build-up they take before a status lands (lower: statuses land sooner)
    EnemyShaChiRegen = 1,          -- how fast their Sha-Chi refills (experimental)
    EnemySpeed = 1,                -- their walk, jog, sprint and crouch speed (experimental; can look odd)
    EnemyLevelOffset = 0,          -- added to their level before their values come from the level curves (-100 to 100)
    EnemyShield = 1,               -- shields (the blue bar): a shield is 20% of the carrier's maximum health, so it
                                   -- grows with EnemyHealth; 0.5 with EnemyHealth = 2 keeps shields as they are
    EnemyAttributes = {},          -- any attribute by its name, a number or a table by class, for example
                                   -- { Resistance_Poise = { all = 0.5, boss = 1 } }
    ScaleUntagged = true,          -- false: enemies without a class tag (the horse cart, PowerMan) stay as they are
    ScaleAllies = false,           -- true: also friendly or story versions of characters (_NPC) and civilians
    ScaleProps = false,            -- true: also breakable things with health (firewood, braziers, campfires)

    -- YOU -------------------------------------------------------------------------------------------------------
    -- Multipliers on the base values your character is built from; upgrades add on top as usual. The game's base at
    -- level 1: attack 100, Sha-Chi regen 0.0833 with a 1 s cooldown, ultimate bar 100, 1 ultimate charge, jog 450,
    -- sprint 600. Your maximum health and Sha-Chi are not here: the mod Max Health and Sha-Chi does that.
    PlayerAttack = 1,              -- the damage you deal to health
    PlayerShaChiAttack = 1,        -- the damage you deal to enemies' Sha-Chi
    PlayerInfliction = 1,          -- the status build-up you take before a status lands
    PlayerShaChiRegen = 1,         -- how fast your Sha-Chi refills
    PlayerShaChiRegenCooldown = 1, -- the wait before your Sha-Chi refills (lower: sooner)
    PlayerUltimateBar = 1,         -- the size of your ultimate bar (0.5: ultimates ready twice as fast)
    PlayerSpeed = 1,               -- your jog and sprint speed (1.1 = 10% faster)
    PlayerUltimateCharges = -1,    -- stored ultimate charges, a count (0 to 10; -1 = the game's, which is 1)
    PlayerAttributes = {},         -- any attribute by its name, for example { Resistance_Fire = 2 }

    -- BREAKS AND ULTIMATE CHARGE (every difficulty) ---------------------------------------------------------------
    EnemyBreakDuration = 1,        -- how long enemies stay broken (game: 4 s on Normal, 3 on Easy); bosses included
    EnemyBreakDamage = 1,          -- the extra damage enemies take while broken (game: x1.5)
    PlayerBreakDuration = 1,       -- how long you stay broken (game: 3 s)
    PlayerBreakDamage = 1,         -- the extra damage you take while broken (game: x1.0)
    LieDuration = 1,               -- the time on the ground after a knockdown (game: 1 s)
    BreakAttribute = false,        -- experimental: true also writes the break multipliers into each character's
                                   -- BreakDurationAdditionalMultiplier; where the game reads both, they stack
    UltimateChargeDeflect = 1,     -- ultimate charge per deflect (game: x0.9)
    UltimateChargeAttack = 1,      -- ultimate charge per attack (game: x2.9)

    -- REWARDS (multipliers on the amount the game gives you) -----------------------------------------------------
    RewardDust = 1,                -- Dust
    RewardMaterials = 1,           -- upgrade materials (weapon, Sha-Chi weapon, accessory, medicine) and
                                   -- traversal talismans
    RewardConsumables = 1,         -- consumables and medicine
    RewardAllItems = false,        -- true: RewardMaterials multiplies every item, story items and
                                   -- permanent-stat shards too
    RewardRounding = "nearest",    -- "nearest", "up" or "down" for amounts that are not whole

    -- LOADING SCREENS (seconds; -1 = the game's) -------------------------------------------------------------------
    LoadingMinSeconds = -1,        -- the forced minimum, 0 to 30; 0 removes the wait
                                   -- (game: same area 3 s, new area 5 s, new game 4 s, save load 5 s)
    LoadingFadeSeconds = -1,       -- the fade-in of the loading screen
    LoadingRevealSeconds = -1,     -- the fade-out when the world is ready
    LoadingWidgetMaxTime = -1,     -- the loading widget's own limit; leave it at -1 unless a screen hangs

    -- THE MOD ---------------------------------------------------------------------------------------------------
    ReapplySeconds = 5,            -- how often new loading widgets get the values (0 to 60; 0 = only after a map
                                   -- load and a change of this file)
    LogSpawns = false,             -- true: ue4ss\UE4SS.log names every character the mod changed, with its class
    LogRewards = false,            -- true: a line for every reward the mod changed
    LogDetail = false,             -- true: every value written, and the whole attribute map once (for tests)
}
