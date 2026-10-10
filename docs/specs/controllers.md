# Controllers

## Requirement (Chad, Oct 2026)
Work with **every 8BitDo controller** and with **USB controllers plugged in by cable**, including
retro-style pads such as Genesis 6-button and N64 controllers, with no setup in the common case.
TV-style remotes are out of scope.

## Input paths
| Path | Covers | Platforms | Status |
|---|---|---|---|
| Apple GameController (`GCController`) | MFi, Xbox Wireless, DualShock 4, DualSense, Switch Pro, Joy-Con, and any 8BitDo/USB pad that identifies as one of these | macOS, iOS, iPadOS | Implemented in M0 (`App/GameInput.swift`) |
| Keyboard (`GCKeyboard`) | Mac keyboard, iPad hardware keyboard | macOS, iPadOS | Implemented in M0 |
| Touch overlay | No controller connected | iOS, iPadOS | Implemented in M0 (SNES layout) |
| Generic HID fallback (`IOHIDManager`) | Generic USB/2.4 GHz pads (D-input, cheap USB pads) that `GCController` ignores | macOS only | Planned M4 |

[Inference] iOS/iPadOS has no public API for generic HID gamepads, so on iPhone/iPad a controller
must identify as one of the Apple-supported types. Confirm on Chad's iPad before promising it.

## Retro-style USB pads (Genesis, N64)
- Most of these are generic HID pads. On **macOS** the `IOHIDManager` fallback reads them, and a
  vendor/product-ID table picks a preset layout.
- Presets:
  - **Genesis 6-button:** A/B/C, X/Y/Z, Start, Mode.
  - **N64:** A, B, Z trigger, L/R, Start, four C buttons, analog stick.

  Each preset maps every button to its matching console button.
- **iPhone/iPad:** works when the pad (or its adapter, e.g. 8BitDo retro receivers) identifies as an
  Apple-supported type. Generic pads need either an adapter or an iPadOS DriverKit HID driver.
  [Inference] DriverKit runs only on M-series iPads and needs extra Apple entitlements, so it's a
  later option and depends on which controllers Chad actually owns.

## 8BitDo
8BitDo controllers have several modes, picked with a button combination at power-on or a switch.
Which modes Apple devices recognise differs by model and firmware, so the app ships a per-model table
(model -> recommended mode -> button layout). It's built by testing Chad's controllers and reading 8BitDo's
docs, then shown in the app as a one-screen "Connect your controller" guide.

## Mapping rules
1. Map by **position**, not label: the bottom face button is always the console's "confirm" position
   (SNES B, Genesis B, PS1 Cross) whatever the controller prints on it.
2. Precedence: console default -> controller-type override -> per-game override.
3. Hotkeys: a long press of the Home/Guide button (or Select+Start held for 1 s) opens the in-game menu.
   This is how users save, load, and exit from the couch.
4. Several controllers: the first one connected is player 1. Reordering happens in the in-game menu.
5. Disconnect mid-game pauses and shows the touch overlay or a "Reconnect controller" prompt.

## Chad's hardware (Oct 2026)
- Controllers: 8BitDo (models TBD) and **Retrolink** USB Genesis and N64 pads.
- Phones: iPhone 16 or newer (A18-class, so no DriverKit). Macs: M1.
- [Inference] Retrolink pads are generic USB HID. They should work on the M1 Macs through `IOHIDManager`
  presets, but are likely invisible to `GCController` on iPhone. To verify: plug one into the iPhone 16
  and check whether `GCController.controllers()` lists it. If it doesn't, the iPhone options are an
  adapter that identifies as an Apple-supported type, or 8BitDo controllers.

## Test matrix (needs Chad's hardware)
For each controller and platform, record: detected type, mode used, every button mapped, both analog
sticks (N64/PS1), hotkey, reconnect, and two-player use.
