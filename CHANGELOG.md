# Changelog

All notable changes to BearChad. Format follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [SemVer](https://semver.org/).

## [1.5.2] - 2026-04-28

### Fixed
- `targetDebuffByPlayer`, `playerBuff`, and `playerBuffInfo` now always return their declared types (zeros, false, nil) when the loop completes without a match. Previous fall-through could return implicit `nil` and cause downstream "compare nil with number" errors in fragile code paths.
- Buff status row spacing now derived from `_BUFF_SIZE + _BUFF_GAP` constants instead of a hardcoded `26`. Previously, changing the icon size or gap would leave the icons misaligned.

### Performance
- Aura tracking switched from per-tick 40-slot scans to an event-driven cache refreshed only on `UNIT_AURA` and `PLAYER_TARGET_CHANGED`. Previously the addon walked target debuffs and player buffs four to five times per second; now it only walks them when the actual aura state changes. Net cost drops from ~150 µs/sec of pointless aura iteration to roughly zero.
- Survival of the Fittest talent rank cached. Previously rescanned the entire Feral talent tree once per second whenever the stats panel was open. Now scanned once and invalidated only on talent change events.

## [1.5.1] - 2026-04-28

### Changed
- Toc Interface bumped from 20504 (2.5.4) to 20505 (2.5.5) to match the current TBC Classic Anniversary client. Packager builds and CurseForge uploads now correctly advertise 2.5.5 support.

## [1.5.0] - 2026-04-28

### Added
- **Stats panel** — top-anchored bear-tank dashboard, toggleable via `/bc stats`. Floats on the dialog strata with a close button. Persists shown/hidden state across reloads.
- **SURVIVAL section** — Crit Reduction (with progress bar vs the 5.60% UNCRITTABLE cap, computed from defense skill + resilience + auto-detected Survival of the Fittest talent rank), Defense, Resilience, Health / EHP (computed from armor mitigation), Armor (raw + % physical reduction vs a level 73 boss), Dodge.
- **THREAT section** — Hit (with progress bar vs the 9% yellow-attack cap), Expertise (with progress bar vs the 26-skill cap), Crit Chance.
- **Base stats line** — Stamina, Agility, and Attack Power on a single combined row.
- **Tier comparison selector** — T3 / T4 / T5 / T6 / SWP buttons that color HP / EHP / Armor / Dodge values **red** when below tier, **yellow** when in range, or **green** when above. Lets you flip phases to see "am I geared for this content yet?" instantly.
- **Hover tooltips** on every row explaining what each stat does and where its cap or target comes from.
- **Section headers and dividers** with thin colored underlines separating SURVIVAL / THREAT / RAW STATS.
- **Zebra striping** on alternate rows.
- **Chad verdict line** at the bottom — randomized roast/respect message from a pool of 75+ lines (heavy on druid and bear-form humor) picked based on whether your aggregate stats fall below, within, or above the selected tier's targets. Re-rolls each time you open the panel or change tiers.

## [1.4.5] - 2026-04-27

### Changed
- Suggester label dropped 4 pixels lower (offset −2 → −6) so the text breathes between the icon and the buff row instead of hugging the bottom of the icon.

## [1.4.4] - 2026-04-27

### Changed
- Frame backdrop upgraded from a flat 35% transparent black rectangle to a proper 85% opaque dark backdrop with a 1px black border outline. The frame no longer looks like it's floating against the world.
- "MAUL QUEUED" indicator demoted from a large floating overlay at the top of the frame to a small label inside the rage bar (off-GCD — doesn't deserve top-of-frame real estate).
- Form warning ("NOT IN BEAR FORM") reanchored to overlay the suggester icon directly. The previous anchor (frame center + 40) put it floating above the bars, which was easy to miss when the frame was in a busy spot on screen.

### Removed
- Standalone "CLEARCAST — free GCD" overlay text. The Clearcasting cue is now conveyed by the suggester border flipping cyan during the proc, making the separate label redundant.

### Changed
- Moving and resizing now require **Shift** to be held. Drag the frame body without Shift and nothing happens; drag the corner grip without Shift and nothing happens. Prevents accidental nudges during combat. Tooltips and `/bc unlock` message updated to reflect the new modifier.

## [1.4.3] - 2026-04-27

### Added
- Bash to the cooldown row (positioned after Growl). The interrupt/stun is part of a tank's job and now visible at a glance alongside the other defensive cooldowns.

### Changed
- Frame width increased from 330 to 350 so the 8 cooldown icons keep comfortable spacing. Rage / HP / Mangle / Lacerate bars widen proportionally to match.

## [1.4.2] - 2026-04-27

### Changed
- Cooldown row icons now distribute evenly across the row width so the rightmost icon (Barkskin) sits flush with the right edge of the frame, matching the right edge of the bars above. Previously the icons clustered to the left with ~20px of dead space on the right.

## [1.4.1] - 2026-04-27

### Fixed
- Cooldown row showed duplicate countdown numerals — one inside the icon (from `CooldownFrameTemplate` / OmniCC) and one below the icon (a custom font string anchored outside the icon's bounds). Removed the redundant custom text; the icon-internal countdown now stands alone.

## [1.4.0] - 2026-04-27

### Changed
- Bar texture swapped from `Interface\TargetingFrame\UI-StatusBar` to the flatter `Interface\RaidFrame\Raid-Bar-Hp-Fill` for a cleaner, modern look across all four bars (rage, HP, Mangle, Lacerate).
- Bar text now uses an outlined font (`STANDARD_TEXT_FONT` 11px OUTLINE) so numbers stay legible over bright bar fills (e.g., the rage-cap yellow). Previously the unstroked `GameFontHighlightSmall` washed out on light backgrounds.
- Suggester icon and buff icons now use a clean 1px backdrop frame outline instead of a solid filled rectangle that looked like painted-on color. The suggester border switches to cyan during a Clearcasting proc so the visual cue is on the icon itself, not a separate floating label.
- Lacerate bar turns red at 5/5 stacks so it's instantly clear that further Lacerate casts are filler-only and you don't need to keep stacking.

## [1.3.3] - 2026-04-27

### Changed
- Cooldown row reorganized to: Mangle, Growl, Enrage, Demoralizing Roar, Challenging Roar, Frenzied Regeneration, Barkskin. Mangle's 6s cooldown now visible at a glance (the debuff bar shows the 12s debuff, not the CD). Faerie Fire (Feral) removed from the row since the rotation already tracks it via debuff state.

## [1.3.2] - 2026-04-27

### Changed
- Suggester label below the icon is now left-aligned (anchored to the suggester's bottom-left corner) instead of centered. Long labels like "stack Lacerate (3/5)" used to overflow past the frame's left edge when centered.

## [1.3.1] - 2026-04-27

### Fixed
- Wait state showed a solid yellow box instead of a distinct visual. The auto-attack icon path wasn't loading reliably across clients, leaving the suggester's yellow border visible behind a missing texture. Now the icon is hidden and the border switches to a dim grey when the suggester is in the wait state, making "nothing to press" unmistakable.

## [1.3.0] - 2026-04-27

### Added
- **Buff status row** for Mark of the Wild, Thorns, and Omen of Clarity. Icons display in full color when the buff is up and dim grey with a red border when missing.
- **Buff expiration warnings.** Yellow icon tint and countdown numeral when ≤60 seconds remain; pulsing red border and red-tinted icon when ≤30 seconds remain.
- **Health bar** beneath the rage bar, full-width, with green / yellow / red thresholds at 50% and 30%.

### Changed
- **Layout overhaul.** Rage and HP bars span the full frame width with text overlaid inside the bars. Suggester icon stays on the left; Mangle and Lacerate bars sit to its right; cooldown row tucked under Lacerate to share the right column. Buff row right-aligned under the cooldowns.
- All bar and label text switched from yellow (`GameFontNormalSmall`) to white (`GameFontHighlightSmall`) for readability.
- Frame height reduced from 180 to 150.

### Fixed
- **Wait state visual ambiguity.** When the suggester recommended waiting for auto-attacks to build rage, it previously showed the Maul icon — visually indistinguishable from the "queue Maul (rage dump)" recommendation. Now shows a desaturated auto-attack icon to make the two states distinct.

## [1.2.0] - 2026-04-27

### Fixed
- **FFF respects the debuff duration.** The suggester previously recommended recasting Faerie Fire (Feral) every 6 seconds (its cooldown), wasting GCDs even when the 40s armor-reduction debuff still had 30+ seconds remaining. Now only triggers when the debuff is missing or has ≤3 seconds left.
- **Maul no longer drains rage from Mangles.** Previously suggested unconditionally as the priority fallback. Now gated by rage (≥50 single-target, ≥70 AoE) and skipped if already queued. When neither condition is met, the suggester shows "wait / auto-attack" instead.

### Changed
Rotation overhaul based on expert TBC bear review:
- **Mangle prioritized on cooldown** rather than refresh-only. It's the highest threat-per-GCD ability bears have, and the 30% bleed-bonus debuff justifies refreshing early.
- **Removed Lacerate filler at 5 stacks.** Casting Lacerate when the bleed is already maxed is always a wasted GCD.
- **AoE: Swipe now ranks above Mangle-on-focus** when rage allows. With 4 targets, Swipe's spread damage beats Mangle's snap threat per GCD.
- **Clearcasting (Omen of Clarity) overrides rage gates.** Mangle, Lacerate, Swipe, and Demo Roar all trigger during a CC proc regardless of rage — never waste a free GCD.

### Removed
- Dead helpers (`spellUsable`, `findAura`).

## [1.1.0] - 2026-04-27

### Added
- **AoE auto-detection and AoE rotation mode.**
  - Hybrid detection unions threat-filtered nameplate scan with a 5-second combat-log GUID pool. The `UnitThreatSituation` filter excludes sapped mobs, mobs other tanks are holding, and other false positives.
  - Asymmetric debouncing: 0.5s up (ST → AoE), 2.5s down (AoE → ST).
  - AoE rotation priority: Demo Roar refresh > Swipe > Mangle on focus > FFF.
  - `ST` / `AoE` mode label in the suggester corner (orange when AoE is active, asterisk for manual override).
  - `/bc aoe on | off | auto` slash command for manual override.
- BigWigs packager GitHub workflow for automated CurseForge releases on tag push.

## [1.0.0] - 2026-04-27

### Added
- Initial release.
- Single-target rotation suggester: Mangle debuff > Lacerate to 5 > Lacerate refresh > Mangle on CD > FFF > Maul.
- Trackers: rage bar with cap warning, Mangle debuff timer, Lacerate stacks + duration.
- Cooldown row: FFF, Demoralizing Roar, Enrage, Barkskin, Frenzied Regeneration, Growl.
- Maul-queued indicator, Clearcasting proc cue, bear-form combat warning.
- Drag-to-move, corner resize grip, scale persistence.
- Slash commands: `/bc lock | unlock | reset | scale N`.
