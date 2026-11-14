# Phantom Tuner

Tune the game's numbers in config.lua: enemy stats by class, your attack and speed, breaks, ultimate charge, rewards, loading waits.

## What it does

One mod for many numbers of the game, each one a setting in `config.lua`. Every setting starts at the game's own
value, so the mod changes nothing until you change a value.

- **Enemies by class:** health, attack, Sha-Chi attack, Sha-Chi bar, status build-up, Sha-Chi refill, speed, a level
  offset and the size of their shields. Each row is one multiplier for every enemy, or a table by the game's own enemy
  classes (Mob, Standard, Elite, MiniBoss, the three boss classes), for example `{ all = 1, boss = 2 }`. Allies,
  civilians and breakable props stay as they are unless you switch them on.
- **You:** attack, Sha-Chi attack, status build-up, Sha-Chi refill and its wait, the size of the ultimate bar, the
  number of stored ultimate charges, jog and sprint speed.
- **Breaks and ultimate charge:** how long enemies and you stay broken and the extra damage taken while broken, the
  time on the ground after a knockdown, the ultimate charge per deflect and per attack.
- **Rewards:** Dust, upgrade materials (and traversal talismans), consumables. Story items, treasures and
  permanent-stat shards keep their count unless you switch them on.
- **Loading screens:** the forced minimum wait, the fades.
- **Any attribute by its name**, for enemies (by class) and for you.

Enemy and player values reach the characters that the game builds after the change: quit to the main menu and load
your save (a rest at a bell is not enough). Loading and ultimate values change at once, while you
play; break values and shields reach the characters that spawn after the change.

It is a UE4SS Lua script: it changes values while the game runs. It replaces no game file and writes nothing into
your save; set a value back to the game's (or `Enable = false`) and the game's value comes back.

Your maximum health and Sha-Chi are not in this mod: use
[Max Health and Sha-Chi](https://github.com/KintaroModding/phantombladezero_maxhealthandshachi). A passive health
regen is not either: use [Passive Regen](https://github.com/KintaroModding/phantombladezero_passiveregen).

## Screenshots

![Phantom Tuner](docs/cover.png)

## How to install

1. Install UE4SS for Phantom Blade Zero, for example [UE4SS](https://github.com/KintaroModding/ue4ss) (its zip
   `phantombladezero_ue4ss_<version>.zip`: the official UE4SS build with a config that makes it run in this game).
2. Download the zip of the latest release on GitHub (`phantombladezero_phantomtuner_<version>.zip`).
3. Unpack it into the game folder `platform\steam\`, next to the game's exe. It adds the folder
   `ue4ss\Mods\phantombladezero_phantomtuner\` (with the file `enabled.txt`, UE4SS starts it by itself).
4. Start the game.

To check that it runs: `platform\steam\ue4ss\UE4SS.log` has the line `[Phantom Tuner] <version> loaded.`

To update the mod, replace the folder with the one of the new release; to keep your settings, put your old
`Scripts\config.lua` back (a setting that it does not have keeps its default). To remove it, delete the folder
`ue4ss\Mods\phantombladezero_phantomtuner\`; after the next load of a save you have the game's values again.

## How to use

Open `config.lua` (below), change the values you want and save. The mod reads the file every 5 seconds. For enemy and
player values, quit to the main menu and load your save. `UE4SS.log` names the settings in use in the line
`[Phantom Tuner] Settings: ...`. To see what the mod changed, set `LogSpawns = true` (a line for every character it
changed, with its class) or `LogRewards = true` (a line for every reward it changed).

Less damage taken: set `EnemyAttack = 0.75`, and enemy hits on your health do 25% less damage (Sha-Chi damage is
`EnemyShaChiAttack`). It makes the enemies' attacks weaker, so their hits on allies get weaker too.

## Settings

The settings are in `platform\steam\ue4ss\Mods\phantombladezero_phantomtuner\Scripts\config.lua`. Open it with a text
editor, change a value and save: the mod reads the file every 5 seconds, so the game does not need a restart. A file
it cannot read (for example a typo) keeps the last settings, and `UE4SS.log` names each value it could not use.

A multiplier: 1 = the game's value, 2 = double, 0.5 = half (0.01 to 100). An absolute value: -1 = the game's value.
An enemy row takes one number for every enemy, or a table by class: `all`, `mob`, `standard`, `elite`, `miniboss`,
`boss` (the three boss classes together), `normalboss`, `greatboss`, `ultimateboss`, `untagged` (the few enemies
without a class). A class that the table does not name uses `all`.

| Setting | Default | What it does |
|---|---|---|
| `Enable` | `true` | `false`: the mod changes nothing, the game's values come back |
| `EnemyHealth` | `1` | Enemies' health (also the start value, so they spawn with a full bar) |
| `EnemyAttack` | `1` | The damage of enemies' attacks to your health |
| `EnemyShaChiAttack` | `1` | The damage of enemies' attacks to your Sha-Chi |
| `EnemyShaChi` | `1` | Enemies' Sha-Chi bar (lower: they break sooner) |
| `EnemyInfliction` | `1` | The status build-up enemies take before a status lands (lower: statuses land sooner) |
| `EnemyShaChiRegen` | `1` | How fast enemies' Sha-Chi refills (experimental) |
| `EnemySpeed` | `1` | Enemies' walk, jog, sprint and crouch speed (experimental) |
| `EnemyLevelOffset` | `0` | Added to enemies' level before their values come from the level curves (-100 to 100) |
| `EnemyShield` | `1` | Shields: a shield is 20% of the carrier's maximum health, so it grows with `EnemyHealth`; this scales that share |
| `EnemyAttributes` | `{}` | Any attribute by its name, a number or a table by class, for example `{ Resistance_Poise = { all = 0.5, boss = 1 } }` |
| `ScaleUntagged` | `true` | `false`: enemies without a class stay as they are |
| `ScaleAllies` | `false` | `true`: also friendly or story versions of characters and civilians |
| `ScaleProps` | `false` | `true`: also breakable things with health (firewood, braziers, campfires) |
| `PlayerAttack` | `1` | The damage you deal to health |
| `PlayerShaChiAttack` | `1` | The damage you deal to enemies' Sha-Chi |
| `PlayerInfliction` | `1` | The status build-up you take before a status lands |
| `PlayerShaChiRegen` | `1` | How fast your Sha-Chi refills |
| `PlayerShaChiRegenCooldown` | `1` | The wait before your Sha-Chi refills (lower: sooner) |
| `PlayerUltimateBar` | `1` | The size of your ultimate bar (0.5: ultimates ready twice as fast) |
| `PlayerSpeed` | `1` | Your jog and sprint speed |
| `PlayerUltimateCharges` | `-1` | Stored ultimate charges, a count from 0 to 10 (the game: 1) |
| `PlayerAttributes` | `{}` | Any attribute of yours by its name, for example `{ Resistance_Fire = 2 }` |
| `EnemyBreakDuration` | `1` | How long enemies stay broken (Normal: 4 s), bosses included |
| `EnemyBreakDamage` | `1` | The extra damage enemies take while broken (the game: x1.5) |
| `PlayerBreakDuration` | `1` | How long you stay broken (the game: 3 s) |
| `PlayerBreakDamage` | `1` | The extra damage you take while broken (the game: x1.0) |
| `LieDuration` | `1` | The time on the ground after a knockdown (the game: 1 s) |
| `BreakAttribute` | `false` | Experimental: `true` also writes the break multipliers into each character's own break attribute; where the game reads both, they stack |
| `UltimateChargeDeflect` | `1` | Ultimate charge per deflect |
| `UltimateChargeAttack` | `1` | Ultimate charge per attack |
| `RewardDust` | `1` | Dust |
| `RewardMaterials` | `1` | Upgrade materials and traversal talismans |
| `RewardConsumables` | `1` | Consumables and medicine |
| `RewardAllItems` | `false` | `true`: `RewardMaterials` multiplies every item, story items and permanent-stat shards too |
| `RewardRounding` | `"nearest"` | `"nearest"`, `"up"` or `"down"` for amounts that are not whole; a reward of 1 or more never drops to 0 |
| `LoadingMinSeconds` | `-1` | The forced minimum wait of loading screens, 0 to 30 s (the game: 3 to 5 s); 0 removes it |
| `LoadingFadeSeconds` | `-1` | The fade-in of the loading screen (0 to 30 s) |
| `LoadingRevealSeconds` | `-1` | The fade-out when the world is ready (0 to 30 s) |
| `LoadingWidgetMaxTime` | `-1` | The loading widget's own limit (0 to 600 s); leave it unless a screen hangs |
| `ReapplySeconds` | `5` | How often new loading widgets get the values (0 to 60; 0 = only after a map load and a change of the file) |
| `LogSpawns` | `false` | `true`: `UE4SS.log` names every character the mod changed, with its class |
| `LogRewards` | `false` | `true`: a line for every reward the mod changed |
| `LogDetail` | `false` | `true`: every value written, and the whole attribute map once (for tests) |

## Compatibility

- Game version: Steam build 26367565 (`CL-302256_JKS-17280`).
- Tested with UE4SS `v4.0.0`.
- [Max Health and Sha-Chi](https://github.com/KintaroModding/phantombladezero_maxhealthandshachi) works beside it:
  Phantom Tuner has no maximum health or Sha-Chi row for you. If you name `Health_Max` or `Shachi_Max` in
  `PlayerAttributes`, the two mods multiply.
- [Passive Regen](https://github.com/KintaroModding/phantombladezero_passiveregen) works beside it; it heals a share
  of your maximum health.
- [Heaven or Hell](https://github.com/KintaroModding/phantombladezero_heavenorhell) writes your attack and the damage
  you take while it runs, so `PlayerAttack` and `EnemyAttack` do not show next to it.
- [More Dust and Materials](https://github.com/KintaroModding/phantombladezero_moredustandmaterials) has its own
  Dust and material multipliers. Next to `RewardDust` and `RewardMaterials` here they multiply (x2 there and x2 here
  give x4). Nothing loops or grows by itself. Use the one you prefer, or set the other to 1.
- [Faster Movement](https://github.com/KintaroModding/phantombladezero_fastermovement) has its own jog and sprint
  speed. Next to `PlayerSpeed` here the speeds multiply. Use the one you prefer, or set the other to 1.
- Other mods that change the same values stack with this one or fight it: set that value here back to the game's, or
  use only one of them.
- The deflect and parry windows are not in this mod:
  [Easier Parry and Dodge](https://github.com/KintaroModding/phantombladezero_easierparryanddodge) has them.

## Known issues

- Enemy and player values need a load of the save from the main menu; a rest at a bell is not enough, and enemies
  that already stand keep their values.
- `EnemySpeed`, `EnemyShaChiRegen` and `BreakAttribute` are experimental.

## How to build

There is nothing to build: `src\phantombladezero_phantomtuner\Scripts\main.lua` is the mod. `tests\test_main.py` runs the script
outside the game with Lua 5.4 ([lupa](https://pypi.org/project/lupa/)) and mocks of UE4SS:
`python tests\test_main.py`. `README.md` has the details.

## Credits

Made by Kintaro. MIT license: you may use, change and share this mod. UE4SS is made by the
[UE4SS-RE team](https://github.com/UE4SS-RE/RE-UE4SS). Phantom Blade Zero belongs to its makers.
