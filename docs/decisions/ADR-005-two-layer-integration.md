# ADR-0005: Two-layer hardware integration

- **Status:** Accepted
- **Date:** 2026-05-09

## Context

The robot can be controlled at two distinct altitudes:

1. **USB-direct, low altitude:** the Mac opens the FTDI serial that
   the CM-730/CM-740 exposes, and speaks Dynamixel Protocol 1.0
   directly. This works whether or not the on-board Linux PC is
   running. It cannot run while the on-board demo holds the serial
   port.

2. **SSH to on-board Linux, high altitude:** read/write
   `/darwin/Data/config.ini`, `walking.ini`, `motion_4096.bin`, run
   the bundled tools (`offset_tuner`, `walk_tuner`, `action_editor`,
   `dxl_monitor`), or restart the demo.

Mixing them in one code path leads to the well-known footgun:
two processes contending for the same `/dev/ttyUSB0`.

## Decision

DarwinForge models the two paths as **distinct connection types**, each
with their own state machine:

```
ConnectionMode
  ├── usbDirect(SerialPath)        // requires demo stopped on the robot
  └── onboardLinux(Hostname,
                   sshKey,
                   demoControl)     // demo is started/stopped by us
```

A `Robot` exposes both connection modes; the UI surfaces them as two
tabs ("Direct" / "Onboard") and refuses to engage `usbDirect` when
`onboardLinux` reports the demo is running. Conversely, switching from
`onboardLinux` to `usbDirect` issues a polite `systemctl stop
darwin-op-demo` (or the equivalent `rc.local` toggle) and waits for
the serial port to come free before opening it.

The two paths share `RobotKit`'s domain types (joint state, motion
page, walking config). They differ in their adapters:

- `DynamixelKit + SerialPortKit` for `usbDirect`
- `OnboardSyncKit + RemoteShellKit` for `onboardLinux`

## Consequences

- **Positive:** the user can do bench work on a powered-but-network-less
  robot (USB only), or remote work from across the desk (SSH only),
  and the app's UX makes the difference legible.
- **Positive:** test fixtures can mock either side independently.
- **Negative:** `OnboardSyncKit` carries deployment-specific knowledge
  (where systemd / rc.local lives on each generation's stock image).
  Encoded as small profile records in `RobotKit`.

## Out of scope

A third path — talking to a running on-robot daemon via TCP — is *not*
implemented. The user does not currently run such a daemon, and adding
one is an undifferentiated lift.
