# Switch Native-Quality Cockpit UI Methodology

Date: 2026-06-05

## Goal

Darwin Switch Cockpit should feel like a controller-first console interface, while staying safe for robot operation and lightweight enough for Switchroot Ubuntu.

This does not copy Nintendo proprietary UI. It adopts public, general console UX patterns visible in open-source Switch homebrew projects:

- controller-first navigation
- persistent button prompts
- strong focus state
- 1280x720 handheld/TV-safe layout
- touch-friendly targets
- low dependency footprint
- clear system status

## Open-Source References

### Borealis

Borealis is an Apache-2.0 UI library for PC and Nintendo Switch homebrew. Its public feature list is useful as a quality target:

- controller and TV oriented UI
- hardware acceleration
- automatic scaling for TV usage
- flexbox-like layout engine
- automated controller navigation
- touch support
- reusable/restylable components
- efficient list recycling

Source:

- https://www.gamebrew.org/wiki/Borealis_Switch
- https://github.com/natinusala/borealis

### nx-hbmenu

`nx-hbmenu` is the open-source Nintendo Switch Homebrew Menu. It provides useful interaction conventions:

- D-pad/joystick selects items
- A launches/enters
- B backs out
- X/Y and `-` expose secondary commands
- local time, network, battery/temperature can be displayed when services are available
- themes live under `/config/nx-hbmenu/themes/`

Sources:

- https://github.com/switchbrew/nx-hbmenu
- https://www.switchbrew.org/wiki/Homebrew_Menu

### libnx HID

`libnx` documents HID service types, including footer UI controller types such as handheld Joy-Con, Joy-Dual, and Pro Controller. For a future `.nro`, the UI should align with active controller mode and show matching footer prompts.

Source:

- https://switchbrew.github.io/libnx/hid_8h.html

## Design Rules Applied To Darwin Cockpit

1. Controller-first, not mouse-first.

   The bottom action dock now has explicit command focus. Left/right changes the selected command. The selected tile has a strong ring and highlighted glyph.

2. Keep safety commands visually dominant.

   `STOP` and `E-STOP` remain persistent. `E-STOP` stays the largest/most intense action. Arm is visible but not visually stronger than emergency actions.

3. Do not trust browser Gamepad API for face-button semantics.

   Browser Gamepad API button indices can differ by controller and browser. Darwin Cockpit uses Gamepad API only for D-pad focus and safe stop/estop edges. Arm/Recover still require explicit UI/keyboard handling.

4. Use a stable 16:9 composition.

   The interface remains a single 1280x720 screen with no scroll at native Switch resolution:

   - top HUD
   - left Joy-Con rail
   - central stage/camera
   - right Joy-Con rail
   - telemetry readouts
   - bottom command dock

5. Make video readable without hiding robot state.

   The camera stream sits behind the HUD with a vignette and reticle. If stream fails, `CAMERA LOST` is visible and the robot figure remains as fallback.

6. Keep the Linux runtime light.

   The cockpit remains plain HTML/CSS/JS:

   - no Electron
   - no Qt
   - no external web libraries
   - no remote fonts
   - no large raster assets

7. Avoid heavy effects.

   Removed filter-based press effect. Added reduced-motion CSS handling. DOM writes are skipped when values are unchanged.

## Implemented Upgrade

Files updated:

- `tools/switch-pilot/web/index.html`
- `tools/switch-pilot/web/styles.css`
- `tools/switch-pilot/web/app.js`

Changes:

- added command focus panel in bottom dock
- added selected command label and hint
- added stronger selected/focus state
- added D-pad/Gamepad API focus support
- limited Gamepad API action handling to safer stop/estop behavior
- added reduced-motion fallback
- removed filter-based active effect
- kept one-screen 1280x720 layout

## Future Native `.nro` Direction

If we later build a true Switch homebrew app instead of Switchroot Ubuntu web cockpit:

1. Use libnx + Borealis as the first candidate stack.
2. Build a native command dock using Borealis focus navigation.
3. Use libnx HID directly for Joy-Con/Pro Controller mode.
4. Use a native video path only if MJPEG decode/rendering is reliable. Otherwise keep Switchroot Linux web cockpit as the camera/control station.
5. Preserve the same safety model:
   - deadman required
   - E-stop always visible
   - heartbeat timeout stop
   - no implicit arm from ambiguous controller mapping

## Current Judgment

For the near-term robot controller, Switchroot Ubuntu + local web cockpit remains the best implementation path. It gives native-feeling controller UX while keeping deployment, debugging, SSH, MJPEG camera, and systemd autostart simple.

For a later polished `.nro`, Borealis is the strongest open-source UI reference because it directly targets Nintendo Switch homebrew and already solves controller navigation, scalable layout, and touch support.
