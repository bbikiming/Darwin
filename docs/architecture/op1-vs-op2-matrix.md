# DARwIn-OP vs DARwIn-OP 2 — Side-by-Side

> The user owns one of each. From DarwinForge's perspective, almost
> everything is shared; the wire-level protocol is identical. This page
> exists so the UI can render correct labels and the diagnostics can warn
> about generation-specific anomalies.

## At a glance

|                           | DARwIn-OP (1st gen, 2010) | DARwIn-OP 2 / ROBOTIS OP2 (~2013) |
|---------------------------|---------------------------|-----------------------------------|
| Internal codename in app  | `OP`                      | `OP2`                             |
| Sub-controller            | **CM-730** (STM32F103RE @ 72 MHz) | **CM-740** (functionally compatible STM32) |
| Embedded PC               | Atom **Z530** 1.6 GHz, 1 GB DDR2 | Atom **N2600** 1.6 GHz dual-core, up to 4 GB DDR3 |
| Storage                   | 4 GB on-board flash        | 32 GB mSATA SSD                   |
| Default OS shipped        | Ubuntu 9.10 (later 10.04)  | Ubuntu 12.04+                     |
| Audio                     | 3.5 mm mic-in / line-out jacks on chassis | Jacks removed |
| Video out                 | none                       | mini-HDMI on back panel           |
| Connectivity              | USB 2.0                    | USB 2.0 (revised header location) |
| DOF                       | 20                         | 20                                |
| Actuators                 | Dynamixel **MX-28T** ×20 (Protocol 1.0) | **same** |
| Bus speed                 | 1 Mbps default (576 kbps fallback) | **same** |
| Battery                   | 11.1 V Li-Po (1800 mAh stock; LB-011 1000 mAh, LB-020 1300 mAh sold separately) | **same** |
| DC jack                   | 12 V on back panel, parallel to battery | **same** |
| IMU                       | 3-axis gyro ±500 dps, 3-axis accel ±4 g, 10-bit ADC | **same** |
| Camera                    | Logitech C905 USB webcam, up to 1600×1200 | **same physical, occasionally swapped to C920 in restorations** |
| FSR (optional)            | 8 sensors (4 per foot), Dynamixel IDs 111 (right) / 112 (left) | **same** |
| Mechanical kinematics     | identical to OP2           | identical to OP                   |
| Mass                      | ~2.9 kg                    | ~2.9 kg                           |
| Height                    | ~454 mm                    | ~454 mm                           |

**Bottom line:** the wire protocol, register addresses, joint count, kinematics, and battery harness are **identical**. The differences live in the embedded PC, back-panel I/O, and storage.

## Servo IDs (canonical)

Both robots use the same ID convention from the official ROBOTIS [`OP2.robot`](../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/OP2.robot). All **20 servos** carry contiguous IDs 1..20:

```
1   R_SHOULDER_PITCH     7  R_HIP_YAW       13  R_KNEE
2   L_SHOULDER_PITCH     8  L_HIP_YAW       14  L_KNEE
3   R_SHOULDER_ROLL      9  R_HIP_ROLL      15  R_ANK_PITCH
4   L_SHOULDER_ROLL     10  L_HIP_ROLL      16  L_ANK_PITCH
5   R_ELBOW             11  R_HIP_PITCH     17  R_ANK_ROLL
6   L_ELBOW             12  L_HIP_PITCH     18  L_ANK_ROLL
                                            19  HEAD_PAN
                                            20  HEAD_TILT
```

Special IDs: **200** = sub-controller (CM-730 / CM-740), **254** = broadcast, **111/112** = right/left foot FSR.

> Some legacy OP1 firmware mirrors (`darwinop-ens` etc.) re-mapped the leg servos to IDs 11..18, leaving 7..10 unused. DarwinForge supports both layouts via `forge_core::joint::JointMap` — on connection, PING sweep auto-selects `Official` (canonical 7..20) or `LegacyOp1` (11..18 with user-supplied ankle IDs).

## Mac-side device naming

Both generations enumerate as FTDI USB serial on macOS. Expect device nodes like:

- `/dev/cu.usbserial-XXXXXX` (FTDI FT232 path)
- `/dev/cu.usbmodemNNNN` (CDC ACM path, less common)

The DarwinForge connection picker should look for `cu.usbserial*` and `cu.usbmodem*` and let the user disambiguate by polling each candidate with a `PING` (instruction 0x01) to ID 200.

## CM-730 vs CM-740 control table

The control tables are functionally identical; CM-740 is the same firmware ABI on a smaller PCB. DarwinForge treats them as one register map and only branches on `Controller.model` for diagnostics that depend on physical board geometry (e.g., when overlaying the live error LED on a board photo).

Salient registers (Dynamixel address space, `[ID 200]`):

| Address | Name        | Notes |
|---------|-------------|-------|
| 0–1     | Model Number | |
| 2       | Version     | |
| 3       | ID          | always 200 |
| 4       | Baud Rate   | |
| 5       | Return Delay Time | |
| 24      | DXL_POWER   | software gate for the Dynamixel rail |
| 25      | LED_PANEL   | 3 chest LEDs |
| 26–29   | LED_HEAD / LED_EYE | RGB |
| 30      | BUTTON      | mode/start/etc. |
| 38–43   | GYRO Z/Y/X  | |
| 44–49   | ACCEL X/Y/Z | |
| 50      | VOLTAGE     | |
| 51–52, 67–68 | MIC L/R | analog samples |
| 53–80   | ADC channels 2–15 | |

Error flags (returned in the Status packet `ERROR` byte): `INPUT_VOLTAGE 1`, `ANGLE_LIMIT 2`, `OVERHEATING 4`, `RANGE 8`, `CHECKSUM 16`, `OVERLOAD 32`, `INSTRUCTION 64`.

## Files DarwinForge syncs from each robot

Whether you SSH into the on-board Linux or pull the SD card out of the OP2, DarwinForge expects to find these files at `/darwin/`:

- `Data/config.ini` — per-joint zero offsets (Offset Tuner output)
- `Data/walking.ini` — gait parameters
- `Data/motion_4096.bin` — action pages (motion sequences)
- Color LUT files for the Vision module
- `/etc/rc.local` — autostart hook for the demo, disabled while DarwinForge is connected

## Known generation-specific gotchas

- **CM-730 firmware is not interchangeable with CM-740.** Never cross-flash. DarwinForge guards firmware uploads by checking `[ID 200].MODEL_NUMBER` first.
- **OP1 fan-out via mic jacks** is sometimes used for tethered audio capture during demos; OP2 lost this and DarwinForge should disable the "external audio probe" UI affordance for `Controller.model == CM_740`.
- **OP2 mSATA SSDs** do fail on long-stored units. Add a `Health → Storage SMART` check that uses `smartctl` over SSH on OP2 only.
- **OP1 NAND flash** is wear-prone and read-only-after-failure. DarwinForge should warn before writing to `/darwin/Data/` on an OP1 with > N writes recorded.
