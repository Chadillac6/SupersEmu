# Branding assets

The Home screen re-themes per console (`App/Client/SystemTheme.swift`, one `SystemTheme` entry per system) and shows that
console's official logo. The logos are bundled vectors in `App/Assets.xcassets/Logos/` (`logo-<system>.imageset`), downloaded
unmodified from Wikimedia Commons. "All" uses the SupersEmu wordmark, drawn as text.

> **Review before Phase 2.** These are trademarks of Nintendo, Sega and Sony. Wikimedia lists the files as public domain
> (simple text/geometric logos below the threshold of originality), but that covers copyright only, not trademark use.
> That's fine for Phase 1 (Chad's own devices). Before invited friends (Phase 2) get the app, review whether to keep
> them, ask for permission or swap in generic marks. Swapping a logo means replacing one imageset and its row here.

| System | Asset | Source | Licence (per Commons) |
|---|---|---|---|
| SNES | `logo-snes` | [File:Super Nintendo Entertainment System logo.svg](https://commons.wikimedia.org/wiki/File:Super_Nintendo_Entertainment_System_logo.svg) | Public domain (PD-textlogo); trademarked |
| Game Boy | `logo-gb` | [File:Nintendo Game Boy Logo.svg](https://commons.wikimedia.org/wiki/File:Nintendo_Game_Boy_Logo.svg) | Public domain (PD-textlogo); trademarked |
| Game Boy Color | `logo-gbc` | [File:Game Boy Color logo.svg](https://commons.wikimedia.org/wiki/File:Game_Boy_Color_logo.svg) | Public domain (PD-textlogo); trademarked |
| Game Boy Advance | `logo-gba` | [File:Game Boy Advance logo.svg](https://commons.wikimedia.org/wiki/File:Game_Boy_Advance_logo.svg) | Public domain (PD-textlogo); trademarked |
| Genesis | `logo-genesis` | [File:Sega genesis logo.svg](https://commons.wikimedia.org/wiki/File:Sega_genesis_logo.svg) (SEGA + Genesis) | Public domain (PD-textlogo); trademarked |
| Sega CD | `logo-segacd` | [File:Sega CD Logo (USA).svg](https://commons.wikimedia.org/wiki/File:Sega_CD_Logo_(USA).svg) | Public domain (PD-textlogo); trademarked |
| 32X | `logo-sega32x` | [File:Sega 32X logo.svg](https://commons.wikimedia.org/wiki/File:Sega_32X_logo.svg) | Public domain (PD-textlogo); trademarked |
| PlayStation | `logo-psx` | [File:PlayStation logo and wordmark.svg](https://commons.wikimedia.org/wiki/File:PlayStation_logo_and_wordmark.svg) | Public domain (PD-textlogo); trademarked |
| Nintendo 64 | `logo-n64` | [File:Nintendo 64 wordmark.svg](https://commons.wikimedia.org/wiki/File:Nintendo_64_wordmark.svg) | Public domain (PD-textlogo); trademarked |

Theme colours (accent, background gradient, brand stripe) are our own approximations of each console's branding, not
official palettes. Logos that are dark or low-contrast on their theme sit on a white plate (`LogoStyle.plate`); the
black PlayStation mark is drawn in white (`LogoStyle.light`).

Game artwork and text have their own terms; see `metadata-and-artwork.md`.
