# Controllers

## Requirement (Chad, Oct 2026)
Work with **every 8BitDo controller** and with **USB controllers plugged in by cable**, including
retro-style pads such as Genesis 6-button and N64 controllers, with no setup in the common case.
TV-style remotes are out of scope.

## Input paths
| Path | Covers | Platforms | Status |
|---|---|---|---|
| Apple GameController (`GCController`) | MFi, Xbox Wireless, DualShock 4, DualSense, Switch Pro, Joy-Con, and any 8BitDo/USB pad that identifies as one of these | macOS, iOS, iPadOS | M0; M3 adds both thumbsticks as analog, triggers, L3/R3, Home (`App/Input/ControllerHub.swift`) |
| Keyboard | Mac keyboard (window-scoped `NSEvent` monitor), iPad hardware keyboard (`GCKeyboard`) | macOS, iPadOS | M0; M3 adds E/R (L2/R2) and I/J/K/L (right stick, N64 C buttons) |
| Touch overlay | No controller connected | iOS, iPadOS | M3: per console (SNES, Genesis 6-button, N64, PS1, GB/GBC/GBA) (`App/Input/TouchControls.swift`) |
| Generic HID fallback (`IOHIDManager`) | Generic USB/2.4 GHz pads (D-input, cheap USB pads) that `GCController` ignores | macOS only | M3 (`App/Input/HIDGamepadManager.swift`); skips any device `GCController.supportsHIDDevice` claims |

[Inference] iOS/iPadOS has no public API for generic HID gamepads, so on iPhone/iPad a controller
must identify as one of the Apple-supported types. Confirm on Chad's iPad before promising it.

## Retro-style USB pads (Genesis, N64)
- Most of these are generic HID pads. On **macOS** the `IOHIDManager` fallback reads them, and a
  vendor/product-ID table picks a preset layout.
- Presets:
  - **Genesis 6-button:** A/B/C, X/Y/Z, Start, Mode.
  - **N64:** A, B, Z trigger, L/R, Start, four C buttons, analog stick.

  Each preset maps every button to its matching console button.
- Unknown pads get the generic preset (DirectInput order: buttons 1-4 bottom/right/left/top, 5-8 shoulders and
  triggers, 9 Select, 10 Start; hat or X/Y as d-pad; Z/Rz as right stick) and can be remapped in Controls.
  When two presets share IDs, the product string decides, then the console being played; the user can
  also pick a preset per pad type in Controls.

### Retrolink USB IDs and report layouts (M3 research)
Nothing here was checked on Chad's pads; the VM has no USB controllers. "Community" means the data comes
from RetroArch's joypad autoconfig (libretro/retroarch-joypad-autoconfig, commit f3b62b8) or SDL's
controller database, which other users submitted from real hardware.

| Pad | VID:PID | Source | Report layout (HID button usage = RetroArch index + 1) |
|---|---|---|---|
| Retrolink N64 | 0079:0006 | Community: RetroArch `Retrolink_N64.cfg` (udev name "Retrolink Nintento 64 Classic USB", DirectInput name "Generic USB Joystick") | Buttons 1-4 C-Up, C-Right, C-Down, C-Left; 5 L; 6 R; 7 A; 8 Z; 9 B; 10 Start. D-pad on hat 0. Stick on X/Y. |
| Retrolink SNES | 0079:0011 | Community: RetroArch and SDL ("Retrolink SNES Controller"); SDL also lists 12BD:D015 | Buttons 1 X, 2 A, 3 B, 4 Y, 5 L, 6 R, 9 Select, 10 Start. D-pad on X/Y axes, no hat. |
| Retrolink Genesis 6-button | **Unverified** (assumed 0079:0011) | Not in RetroArch, SDL or linux-usb.org | **Unverified** guess: buttons 1 A, 2 B, 3 C, 4 X, 5 Y, 6 Z, 9 Mode, 10 Start; d-pad on X/Y axes. Based on other Genesis-style pads on the same board. |

- 0079 is DragonRise Inc. (linux-usb.org: 0079:0006 "PC TWIN SHOCK Gamepad", 0079:0011 "Gamepad"). Many
  unbranded pads use the same IDs, so a 0079:0011 pad might be a SNES, Genesis or Saturn pad. Linux
  `hid-dr.c` documents the 0079:0011 report: 3 constant bytes, X and Y (8-bit), 4 padding bits, 10 buttons.
- To confirm on Chad's Mac: System Information > USB lists the VID/PID; Controls (Settings) shows
  "USB VVVV:PPPP" and the preset in use for a connected pad. If the Genesis pad's buttons come out wrong,
  pick the right layout there, remap, and update this table.
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
3. Hotkeys: a long press of the Home/Guide button (0.6 s; the app sets `preferredSystemGestureState = .disabled`
   so the system doesn't take it) or Select+Start held for 1 s opens the in-game menu (Resume, Save/Load State,
   Swap Disc, Controls, Exit to Library). On the keyboard that's Tab+Return. This is how users save, load,
   and exit from the couch.
4. Several controllers: the first one connected is player 1 (with touch and keyboard); pads 2-4 drive ports
   2-4. When a pad disconnects, the pads after it move up a slot. Reordering in the in-game menu is not built yet.
5. Remapping (Settings > Controls on Mac, gamepad button in the iOS library, or Controls in the in-game menu):
   pick a console control, press the physical input, or Reset to Default. Saved to
   `Application Support/SupersEmu/Controls.json` as `controllerOverrides[type][system][control]` and
   `gameOverrides[gameID][control]`, where a type is `keyboard`, `gc:<category>:<vendor name>` or
   `hid:vvvv:pppp`. Touch controls always use the console defaults.
6. Disconnect mid-game pauses and shows a "Reconnect controller" prompt; Continue (or A/Start on any pad)
   resumes with what's left: another pad, touch or the keyboard.

## Console layouts
Defaults by position (`App/Input/ConsoleLayout.swift`), in the RetroPad terms the cores read:
- SNES: B bottom, A right, Y left, X top, L/R shoulders. GB/GBC/GBA: B bottom, A right (GBA adds L/R).
- Genesis / Sega CD / 32X: A left, B bottom, C right, X left shoulder, Y top, Z right shoulder, Mode = Select
  (Genesis Plus GX and PicoDrive both read A/B/C from RetroPad Y/B/A and X/Y/Z from L/X/R).
- PS1: Cross bottom, Circle right, Square left, Triangle top, L1/R1/L2/R2/L3/R3. Digital pad only for now:
  Beetle PSX's port device isn't switched to DualShock, so PS1 analog sticks aren't sent yet.
- N64 (keyed by "n64"): stick = left analog, C buttons = right analog, A bottom (RetroPad B), B left (RetroPad Y),
  Z = left trigger (L2), L/R shoulders. [Inference] This is mupen64plus-next's default RetroPad layout; the N64
  core track should confirm it when the core lands.
- Analog sticks reach the core through `RETRO_DEVICE_ANALOG` (`-[SELibretroHost setAnalogStick:x:y:forPort:]`).
  Digital consoles also read the left stick as the d-pad unless something is remapped onto the stick.

## Chad's hardware (Oct 2026)
- Controllers: 8BitDo (models TBD) and **Retrolink** USB Genesis and N64 pads.
- Phones: iPhone 16 or newer (A18-class, so no DriverKit). Macs: M1.
- [Inference] Retrolink pads are generic USB HID. They should work on the M1 Macs through `IOHIDManager`
  presets, but are likely invisible to `GCController` on iPhone. To verify: plug one into the iPhone 16
  and check whether `GCController.controllers()` lists it. If it doesn't, the iPhone options are an
  adapter that identifies as an Apple-supported type, or 8BitDo controllers.

## Test matrix (needs Chad's hardware; nothing below has been run on real controllers yet)
For each controller and platform, record: detected type, mode used, every button mapped, both analog
sticks (N64/PS1), hotkey, reconnect, and two-player use.
