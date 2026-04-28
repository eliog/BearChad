# Changelog

All notable changes to BearChad. Format follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [SemVer](https://semver.org/).

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
