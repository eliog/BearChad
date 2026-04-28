# BearChad

A druid bear tank co-pilot for TBC Classic. Tracks rotation, surfaces the next ability, and keeps your eyes on the boss instead of your bars — so warriors named Chad stop topping your threat meter.

<p align="center"><img src="logo.png" alt="BearChad" width="200"/></p>

## Features

- Next-ability suggester driven by the standard feral threat priority
- Rage bar with rage-cap warning
- Player-applied Mangle debuff timer on target
- Lacerate stack tracker with refresh warning
- Cooldown row: Faerie Fire (Feral), Demoralizing Roar, Enrage, Barkskin, Frenzied Regeneration, Growl
- `MAUL QUEUED` indicator and Clearcasting (Omen of Clarity) cue
- Bear-form alert in combat

## Priority

1. Apply / refresh Mangle debuff
2. Stack Lacerate to 5
3. Refresh Lacerate before falloff
4. Mangle on cooldown
5. Faerie Fire (Feral) on cooldown
6. Lacerate as filler
7. Maul whenever rage allows

## Install

1. Download the latest zip from [Releases](../../releases) (or from CurseForge).
2. Extract into `World of Warcraft/_classic_/Interface/AddOns/`.
3. `/reload` in-game.

## Slash commands

| Command | Effect |
|---|---|
| `/bc unlock` | Drag to move, corner grip to resize |
| `/bc lock` | Lock in place |
| `/bc scale 1.4` | Set scale (0.5–2.5) |
| `/bc reset` | Restore default position and scale |

## Compatibility

- TBC Classic (2.5.4) — primary target
- Druid only

## License

Public domain ([Unlicense](LICENSE)).
