# Phantom Tuner

One mod for the numbers of the game: enemy health, damage and Sha-Chi by enemy class, the player's attack and speed, breaks, ultimate charge, rewards and loading waits. Every value is set in config.lua and read again while the game runs; the shipped file changes nothing.

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for Phantom Blade Zero (Unreal Engine 5.7), made with
game version `CL-302256_JKS-17280` and UE4SS `v3.0.1-1195-g1ceefac8`, tested in game with UE4SS `v4.0.0` (1.1, 2026-11-13). This README is for developers; what the mod does and
how to install it are in [openmods.md](openmods.md), the mod page on [openmods](https://openmods.nexus).

## How it works

Every setting is a multiplier on the game's own value (1 = the game's) or an absolute value (-1 = the game's). The
shipped `config.lua` holds only the game's values: then the mod sets no hook and searches no object. A part starts to
work when one of its settings differs from the game's value. `Scripts/main.lua` has three parts:

| Part | How | When a change shows |
|---|---|---|
| Character attributes: the enemy rows by class (`EnemyHealth`, `EnemyAttack`, ...), the player rows (`PlayerAttack`, `PlayerSpeed`, ...), `EnemyLevelOffset`, `EnemyAttributes`, `PlayerAttributes`, `BreakAttribute` | A hook on `PBZCharacterAttributeDataHelper:GetAttributeMap`. The callback before the function finds the character's config asset (`PDA_ActorConfig_C`, the outer object of the attribute data's level values) and adds the level offset to the `Level` parameter; the callback after it multiplies the entries of the filled map (attribute -> value) | For characters that the game builds after the change: quit to the main menu and load the save |
| Config objects: breaks, ultimate charge, shields, loading waits | `FindAllOf` by class (`PDA_GlobalCombatConfig_C`, `PBZDestinationLoadingConfig`, `WB_TempLoadingScreen_C`, `WB_AdditionalLoading_C`, `GA_GoldenBodyShield_PassiveBase`), then a write of the stored property; the game's value is kept per object | At once; breaks and shields for characters that spawn after the change |
| Rewards: Dust, upgrade materials, consumables | Hooks before `PBZBackPackSubsystem:AddDustNum`, `AddPropsByMap`, `AddPropsSilently` and `AddMedicineAmount` change the amount parameter | At once |

Characters: the config asset's full name tells the kind. Below `/Players/`: the player. A level actor
(`PersistentLevel`, not below `/ActorData/`): a prop (firewood, braziers), left alone unless `ScaleProps`. A name with
`_NPC`, starting with `ActorC_NPC_` or with `Nanmin`: an ally or civilian, left alone unless `ScaleAllies`. Everything
else is an enemy, and its class is the asset's `Difficulty Tag` (`CharacterType.Difficulty.Mob` ... `UltimateBoss`). A
class row takes a table (`{ all = 1, boss = 2 }`): the class, then `boss` for the three boss classes, then `all`. The
map holds the start value beside the maximum (`Health` beside `Health_Max`); both are scaled, or a character spawns
with a part of its bar missing.

Config objects: the game's value is kept per object address (`state`), and a property is written only when it
differs from the wanted value. A value that is neither the kept one nor the written one is the game's new value (an
object at a reused address, or the game wrote it). A full pass runs 5 s after the start, 1 s after a map load
(`RegisterLoadMapPostHook`), 3 s after the hook on `PlayerController:ClientRestart`, and right after a changed
`config.lua`; it searches the classes whose settings are in use and those whose objects still hold a value of the
mod, so a setting back at 1 (or `Enable = false`) writes the game's values back. Every `ReapplySeconds` (5) the classes
whose objects load during play (the loading widgets) are searched again, only while
their settings are in use. `GA_GoldenBodyShield_PassiveBase` is changed on its class defaults (`Default__`) only:
ability instances are copied from them when a carrier spawns. Values are compared with a tolerance for 32-bit floats.

Rewards: `AddPropsByMap` and `AddPropsSilently` get the same items for one pickup, so a map equal to the one changed
less than 0.05 s before is left alone. Materials are multiplied only for the 85 ids in `MATERIAL_IDS` (upgrade
materials and traversal talismans) unless `RewardAllItems`. An amount of 1 or more never drops to 0.

Hooks: each one is set on the game thread the first time its part is in use, after a check that its function is
there (`StaticFindObject`); a missing function is tried again every second, 30 times. A failed `RegisterHook` is not
tried again (two hooks on a reward function would multiply twice). Every callback checks `IsInGameThread` first. The
timers run on the game thread (`LoopInGameThreadWithDelay`: a 1 s tick and the 5 s read of `config.lua`); a UE4SS
without them gets `LoopAsync` with `ExecuteInGameThread`, and the log says so.

Not in this mod: the player's maximum health and Sha-Chi (`phantombladezero_maxhealthandshachi` does it with the same
hook; with both, the values would multiply) and a passive health regen (`phantombladezero_passiveregen`).

The log (`ue4ss\UE4SS.log`, lines that start with `[Phantom Tuner]`): the version, the settings that differ from the
defaults, each hook, a line for a full pass that wrote values, and the problems (each one once). `LogSpawns` adds a
line per character build, `LogRewards` a line per changed reward, `LogDetail` every written value and the whole
attribute map of the first build of each kind (at most 1000 such lines per change of `config.lua`).

## Not in this mod

The deflect and parry windows (the perfect-deflect frames, the spam penalty, the timed-parry windows, the deflect
lead) of the source are left out:
[Easier Parry and Dodge](https://github.com/KintaroModding/phantombladezero_easierparryanddodge) has them. So are the
player's maximum health and Sha-Chi (Max Health and Sha-Chi) and the passive regen (Passive Regen).

## Deploy and test

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1     # copy the mod folder into the game's ue4ss\Mods
python tests\test_main.py                                 # offline test of main.lua (needs lupa)
```

`deploy.ps1` copies `src\phantombladezero_phantomtuner\` to `<game folder>\platform\steam\ue4ss\Mods\phantombladezero_phantomtuner\`. The game
folder is `$env:UE5_GAMES_DIR\PBZ`; `-GameDir` or `-ModsDir` override it. The mod folder holds
`enabled.txt`, so UE4SS starts it without an entry in `mods.txt`. An existing `Scripts\config.lua` in the game stays
(the tester's settings); `-ResetConfig` copies the shipped one. UE4SS loads Lua mods at game start. The mod writes
its lines into `ue4ss\UE4SS.log`, for example `[Phantom Tuner] 1.1 loaded.`

`tests\test_main.py` runs `main.lua` in Lua 5.4 ([lupa](https://pypi.org/project/lupa/)) with mocks of the UE4SS
functions that the script uses and of the game's character builds, config objects (int, double and 32-bit float
properties) and reward functions. It finds syntax and logic errors before a game start.

Versioning: every change raises the second number (1.0 -> 1.1) in `mod.json` and in `main.lua`:
`python scripts\bump_version.py`.

## Settings

`Scripts/config.lua` holds the player's settings, `DEFAULTS` in `main.lua` every setting with its default (the game's
value) and `LIMITS` the range of the number settings that are not multipliers; every other number setting is a
multiplier from 0.01 to 100 (0 or less means 1). The enemy rows take a number or a table by class; `EnemyAttributes`
and `PlayerAttributes` take attribute names. The mod reads the file at start and again every 5 seconds (`ReadConfig`):
a changed file is used at once, a broken or half-saved one keeps the last settings, a missing one means the defaults.
Players and mod managers keep their own `config.lua` across updates, so a new `main.lua` can meet an older file: a
setting that the file lacks, or has with another type, keeps its default, and the log says so (`ParseConfig`). Add each
setting to both files with the same value, and read it only from `Settings` or `Eff` (the values in use: the
defaults while `Enable` is false), never as `config.X or default` (for a true/false setting, `false or true` is
true). `tests\test_main.py` checks that `config.lua` ships exactly the defaults, and runs `main.lua` with a missing,
empty, broken and wrong `config.lua`.

## Project layout

```
src/phantombladezero_phantomtuner/   The UE4SS mod folder: Scripts/main.lua, Scripts/config.lua, enabled.txt
tests/test_main.py    Offline test of main.lua with mocks of UE4SS and the game
docs/                 Cover and screenshots
scripts/              bump_version.py
deploy.ps1            Copies the mod folder into the game's ue4ss\Mods
mod.json              Name, version, game, engine and UE4SS version
```

## License

MIT, see [LICENSE](LICENSE).
