# SupersEmu brand and visual system

Approved direction (Oct 2026): bright, clean and editorial, with one muted brick-red accent. Light and dark mode follow the
system setting. The emulator picture and the player chrome around it stay dark. This replaces the dark/cinematic default in
`ui-direction.md` (layout and UX goals there still apply).

No third-party brand assets. Console logos stay as-is (`branding-assets.md`).

## Colour tokens

Asset-catalog colour sets in `App/Assets.xcassets/Brand/` (Any + Dark appearances), exposed as `Brand.*` in
`App/Client/Brand.swift`. `AccentColor` = BrandRed, and the app's global accent is set in project.yml
(`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`).

| Token | Use | Light | Dark |
|---|---|---|---|
| BrandPaper | Screen background | #F8F8F7 | #111110 |
| BrandSurface | Cards, sheets, menus | #FFFFFF | #1B1B1A |
| BrandCard | Inset panels, unselected rows | #F1F1EF | #232321 |
| BrandLine | 1 pt hairlines and borders | #E4E4E1 | #30302D |
| BrandInk | Primary text | #141414 | #F3F3F1 |
| BrandInk2 | Secondary text | #55554F | #B5B5AF |
| BrandInk3 | Tertiary text, disabled | #8C8C86 | #80807A |
| BrandRed | Primary buttons, selection, progress | #B4493F | #BE5448 |
| BrandRedPressed | Pressed primary | #943A33 | #A3463B |
| BrandRedText | Red text (eyebrows, links) | #B4493F | #DE8075 |
| BrandRedTint | Red-tinted backgrounds | #F6E7E4 | #3A2421 |

White on BrandRed is 5.3:1 (light) and 4.6:1 (dark). Red is only for the single primary action on a screen, focus/selection
and progress. Everything else is ink on paper.

## Type

System fonts for the interface (Dynamic Type keeps working):
- SF Pro (default) for UI.
- New York (`.system(..., design: .serif)`) for game titles on the detail page and the onboarding headline.
- SF Mono (`.system(..., design: .monospaced)`), uppercase with 1–1.5 pt tracking, for eyebrows, counts and metadata lines,
  e.g. `N64 · 2000 · 1–4 PLAYERS`.

The wordmark is the only custom-font exception: Silkscreen Bold, bundled under the SIL Open Font License (OFL), with “SUPERS”
in BrandInk and “EMU” in BrandRedText. It is used only for the wordmark.

## Shape and spacing

Corner radii: 14 cards, 12 buttons, 10 rows, capsule chips. 1 pt BrandLine borders instead of shadows and materials.
Spacing on a 4 pt grid; screen margin 20 (compact) / 32 (regular).

## Home hero

The featured game leads with its server screenshot, then the newest valid local save-slot screenshot, and finally the
existing blurred-cover `WideArt` fallback. When a screenshot exists, the cover art appears as a small white-bordered
sticker hanging from its lower leading edge; the title, last-played subtitle and actions remain below the art, with no
separate red eyebrow.

## Mark

Cartridge outline with a 3×2 dot label, on a 24×24 grid:
- Outline path `M4 2.5h16a1.5 1.5 0 0 1 1.5 1.5v17.5h-4v-2.2h-11v2.2h-4V4A1.5 1.5 0 0 1 4 2.5z`, stroke 1.7, round joins.
- Dots r=1.15 at x ∈ {8.6, 12.0, 15.4}, y ∈ {8.4, 11.8}.
- In-app: outline BrandInk, dots BrandRed, next to the Silkscreen Bold wordmark.
- App icon: white outline and dots on BrandRed (`docs/brand/app-icon.svg`).

## Launch splash

The cold-launch splash drops the cartridge mark into a slot, lights its dots, then reveals the wordmark before fading away. Tap
anywhere or press a key on Mac to skip; Reduce Motion shows the final frame immediately. `SUPERSEMU_SPLASH=off` disables it
and `SUPERSEMU_SPLASH=hold` keeps the final frame visible for screenshots. It never appears over the Player.
