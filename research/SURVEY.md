# ROBOTIS DARWIN-OP — Upstream Open-Source Survey

> Inventory of the upstream code, documentation, and academic record that
> the DarwinForge Mac app builds on top of. Generated as part of the project
> bootstrap; refresh annually or when an upstream repo materially changes.

---

## 1. Open-Source Software Repositories

ROBOTIS publishes across two GitHub orgs relevant to OP / OP2:

### `ROBOTIS-GIT` (active, official)

| Repository | Purpose | License | Status |
|------------|---------|---------|--------|
| [ROBOTIS-OP2](https://github.com/ROBOTIS-GIT/ROBOTIS-OP2) | ROS packages for OP2 — `cm_740_module`, `op2_walking_module`, `op2_kinematics_dynamics`, `op2_manager`, `op2_gui_demo`, `robotis_op2` | Apache-2.0 | Sparse — only ~3 master commits |
| [ROBOTIS-OP2-Common](https://github.com/ROBOTIS-GIT/ROBOTIS-OP2-Common) | URDF, common utilities, Gazebo simulation. Packages: `robotis_op2_common`, `robotis_op2_description`, `robotis_op2_gazebo` | Apache-2.0 | Stable |
| [ROBOTIS-OP-Series-Data](https://github.com/ROBOTIS-GIT/ROBOTIS-OP-Series-Data) | Hardware PDFs — assembly, wiring, fabrication manuals; sub-controller control tables; covers OP, OP2, OP3 in separate folders | n/a (docs) | **Authoritative hardware reference** |
| [ROBOTIS-Framework](https://github.com/ROBOTIS-GIT/ROBOTIS-Framework) | Core framework (`robotis_controller`, `robotis_device`, `robotis_framework`, `robotis_framework_common`); used by both OP2 and OP3 | Apache-2.0 | Active for OP3-driven needs |
| [DynamixelSDK](https://github.com/ROBOTIS-GIT/DynamixelSDK) | Dynamixel Protocol 1.0 + 2.0 SDK — C, C++, C#, Java, MATLAB, LabVIEW, Python | Apache-2.0 | Active, **macOS supported** |
| [emanual](https://github.com/ROBOTIS-GIT/emanual) | Markdown source for emanual.robotis.com — `docs/en/platform/op/` and `docs/en/platform/op2/` | n/a (docs) | Active |
| [ROBOTIS-OP3](https://github.com/ROBOTIS-GIT/ROBOTIS-OP3) | **Different model** — XM-430 servos, Protocol 2.0, Intel NUC i3. Reference only. | Apache-2.0 | Active |

### `ROBOTIS-OP` (older, ROS1 community packages)

`robotis_op_framework`, `robotis_op_common`, `robotis_op_simulation`, `robotis_op_launch`, `robotis_op_camera`, `robotis_op_ball_tracker`, `robotis_op_teleop`, `robotis_op_moveit`, `robotis_op_ros_control`, `robotis_op_iros_tutorial`, `robotis_op_documentation`. Largely community-maintained ROS1 wrappers; expect bit-rot, but useful for design references.

### Legacy / Historical

- **SourceForge:** [darwinop project](https://sourceforge.net/projects/darwinop/) — original framework source for the Main Controller, under `/Software/Main Controller/Source Code`.
- **Unofficial GitHub mirror with cleanups:** [darwinop-ens/darwin-op](https://github.com/darwinop-ens/darwin-op) — cleanest place to read the canonical CM730/MX28/Walking sources.
- **Interbotix HR-OS5 fork:** [Interbotix/HROS5-Framework](https://github.com/Interbotix/HROS5-Framework) — **archived July 2021**, **GPL v3** (incompatible with Apache 2.0 redistribution; verify per-file headers if borrowing).

### License summary

| Source | License |
|--------|---------|
| ROBOTIS-GIT/* (OP2, OP2-Common, Framework, DynamixelSDK, OP3) | Apache 2.0 |
| Interbotix/HROS5-Framework (derivative) | GPL v3 |
| HumaRobotics/darwin_description (URDF) | BSD-2-Clause |
| ROBOTIS-OP-Series-Data PDFs | © ROBOTIS, redistributed in the data repo |

DarwinForge picks **Apache 2.0** so it remains compatible with the upstream framework.

---

## 2. Framework Architecture

Canonical layout from the SourceForge sources (mirrored on `darwinop-ens`, `HROS5-Framework`, `robotis_op_framework`). On the robot at `/darwin/`:

```
/darwin/
  Data/        # config and motion files
    config.ini       # per-joint zero offsets
    walking.ini      # gait params (PERIOD_TIME, *_AMPLITUDE, balance gains)
    motion_4096.bin  # action pages (motion sequences) edited by Action Editor
    *.lut            # color LUTs for Vision module
  Framework/   # OS-independent C++ library
    include/   # CM730.h, MX28.h, JointData.h, FSR.h, Walking.h, MotionManager.h
    src/
      math/      # vector / matrix / kinematics
      minIni/    # INI parser
      motion/    # MotionManager, MotionModule, Head, Action, Walking, Kinematics, JointData
      vision/    # ImgProcess, BallTracker, ColorFinder, ImgSerializer
      hardware/  # CM730.cpp, MX28.cpp
  Linux/       # OS-specific glue (POSIX, V4L2, USB)
    include/   # LinuxCM730.h, LinuxCamera.h, LinuxMotionTimer.h
    lib/       # libdarwin.a build target
    project/   # demo applications
      action_editor/    # CLI to author/edit action pages
      arm_copy/
      demo/             # default demo: soccer + vision
      dxl_monitor/      # raw Dynamixel diagnostic
      firmware_installer/
      instrumentation/
      offset_tuner/     # zero-offset calibration GUI
      roboplus/         # bridge for RoboPlus Windows tools
      tutorial/
      vertical/         # standing/upright tuning
      walk_tuner/       # walks-module gait tuner
  Simulink/    # MATLAB/Simulink integration (git submodule)
```

Pattern: a singleton `MotionManager` owns the bus, registers `MotionModule` subclasses (Action, Head, Walking) via `AddModule()`, and runs them on a periodic timer (`LinuxMotionTimer`). Every cycle it `BULK_READ`s IMU/FSR/joint state from CM-730 and `SYNC_WRITE`s target positions and PID gains via Dynamixel Protocol 1.0.

---

## 3. ROS / ROS 2 / Simulation Support

- **ROS 1** (Indigo / Kinetic era): `ROBOTIS-OP/robotis_op_*` and `ROBOTIS-GIT/ROBOTIS-OP2`.
- **ROS 2**: first-class only for OP3. OP2 ROS support remains legacy ROS 1.
- **Webots** (CyberBotics): built-in DARwIn-OP node in the Robotis category, with cross-compilation hooks so a Webots controller can be transferred to the real robot. Reference: <https://www.cyberbotics.com/doc/guide/darwin-op>.
- **Gazebo (ROS 1)**: via `robotis_op_simulation` and `robotis_op2_gazebo` (URDF in `robotis_op2_description`).
- **Third-party URDF**: [HumaRobotics/darwin_description](https://github.com/HumaRobotics/darwin_description) — BSD-licensed mesh + URDF, suitable for embedding in DarwinForge for live 3D pose preview.

---

## 4. Servo ID Convention (per `JointData.h`)

The framework's `JointData::ID_*` constants are the authoritative ID mapping. Published numbers vary slightly between sources (UPenn, Robotis e-Manual, third-party wikis), so any code that hardcodes IDs must reference `JointData.h` from the exact framework version it talks to.

Reference (verified on `darwinop-ens/darwin-op`'s `Framework/include/JointData.h`):

```
1   R_SHOULDER_PITCH    11  R_HIP_YAW
2   L_SHOULDER_PITCH    12  L_HIP_YAW
3   R_SHOULDER_ROLL     13  R_HIP_ROLL
4   L_SHOULDER_ROLL     14  L_HIP_ROLL
5   R_ELBOW             15  R_HIP_PITCH
6   L_ELBOW             16  L_HIP_PITCH
7   R_HIP_YAW (alt)     17  R_KNEE
8   L_HIP_YAW (alt)     18  L_KNEE
9   …                   19  HEAD_PAN
10  …                   20  HEAD_TILT
```

Special IDs:

- `200` — CM-730 / CM-740 controller itself
- `254` — broadcast
- `111` — right foot FSR
- `112` — left foot FSR

> **Caveat:** the duplicated "HIP_YAW (alt)" entries above reflect inconsistent labelling in upstream materials. DarwinForge resolves this at runtime by reading the framework's exact symbol table from a vendored copy of `JointData.h`; do not hardcode.

---

## 5. Documentation Sources

### Official e-Manual

- DARwIn-OP / ROBOTIS OP: <https://emanual.robotis.com/docs/en/platform/op/getting_started/>
- ROBOTIS OP2: <https://emanual.robotis.com/docs/en/platform/op2/getting_started/>
- ROBOTIS OP3 (different model — for reference): <https://emanual.robotis.com/docs/en/platform/op3/introduction/>
- Dynamixel Protocol 1.0: <https://emanual.robotis.com/docs/en/dxl/protocol1/>
- Dynamixel MX-28T: <https://emanual.robotis.com/docs/en/dxl/mx/mx-28/>
- Legacy support pages: <http://support.robotis.com/en/product/darwin-op/...>
- CM-730 reference: <http://support.robotis.com/en/product/darwin-op/references/reference/hardware_specifications/electronics/sub_controller_(cm-730).htm>
- CM-740 reference: <http://support.robotis.com/en/product/robotis-op2/sub_controller(cm-740).htm>
- FSR reference: <http://support.robotis.com/en/product/darwin-op/references/reference/hardware_specifications/electronics/optional_components/fsr.htm>

> **Caveat:** `emanual.robotis.com`, `en.robotis.com`, and `support.robotis.com` block unauthenticated WebFetch from automated tools (HTTP 403). Download authoritative copies of the PDFs from `ROBOTIS-OP-Series-Data` and check them into `reference/` for offline use.

### Academic papers

- Ha, Tamura, Asama, Han, Hong. "Development of Open Humanoid Platform DARwIn-OP." SICE 2011. <https://www.romela.org/wp-content/uploads/2015/05/Development-of-open-humanoid-platform-DARwIn-OP.pdf>
- McGill, Brindza, Yi, Lee. "Development of an Open Humanoid Robot Platform for Research and Autonomous Soccer Playing." <https://www.romela.org/wp-content/uploads/2015/05/Development-of-an-Open-Humanoid-Robot-Platform-for-Research-and-Autonomous-Soccer-Playing.pdf>
- "DARwIn's Evolution": <https://www.romela.org/wp-content/uploads/2015/05/DARwIn%E2%80%99s-Evolution.pdf>
- RoMeLa overview: <https://www.romela.org/darwin-op-open-platform-humanoid-robot-for-research-and-education/>

### RoboCup teams open-sourcing DARwIn-OP code

- **UPennalizers (UPenn)** — RoboCup Istanbul 2011 winners. <https://github.com/UPenn-RoboCup/UPennalizers>
- **Hamburg Bit-Bots / Hambot** — open-hardware variant. Paper: <https://link.springer.com/chapter/10.1007/978-3-319-29339-4_28> Mechanical CAD: <https://github.com/bit-bots/hambot>
- **NUbots OP2 Restoration Guide** — practical hardware resurrection notes: <https://nubook.nubots.net/guides/hardware/darwin-op2-guide/>
- **Seed Robotics knowledge base** — harness/firmware tips: <https://kb.seedrobotics.com/doku.php?id=dh4d:darwinopframework>
- **DASL (UNLV) wiki** — practical guides: <https://www.daslhub.org/unlv/wiki/doku.php?id=making_the_darwin-op_walk>
- **RoboCup Humanoid League open-source materials index**: <https://humanoid.robocup.org/materials/open-source/humanoid-soccer-competition/>

---

## 6. Maintenance Status / Caveats

- `darwinop-ens/darwin-op` is **unofficial** but the cleanest GitHub mirror of the SourceForge framework — best primary source for reading framework internals.
- `Interbotix/HROS5-Framework` is **archived** (2021) and **GPL v3** — read for inspiration, never silently copy.
- `ROBOTIS-OP/*` packages are largely community-maintained and ROS 1-era; expect bit-rot.
- `ROBOTIS-GIT/ROBOTIS-OP2` has minimal commits; do not expect ongoing upstream feature work for OP/OP2. ROBOTIS' active humanoid focus is OP3 and the Physical AI line (AI Worker, AI Sapiens). The user's two units are therefore in **long-term maintenance mode**, which is precisely what DarwinForge is intended to support.

---

## 7. What DarwinForge Should Vendor / Cache

Local references the Mac app should ship or fetch on first run:

1. **`reference/robotis-op-series-data/`** — checked-in PDF set from `ROBOTIS-OP-Series-Data` (wiring manual, fabrication manual, assembly manual, sub-controller control tables) for in-app diagrams and the Maintenance view.
2. **DynamixelSDK Swift bindings** — DarwinForge's `DynamixelKit` either statically links the C SDK or reimplements Protocol 1.0 in pure Swift; the latter is preferred for SwiftPM cleanliness given the protocol is well-bounded and short.
3. **URDF from `ROBOTIS-OP2-Common/robotis_op2_description`** — for 3D pose rendering of the live robot in `DarwinForgeUI`.
4. **`Framework/include/CM730.h`, `MX28.h`, `JointData.h`, `FSR.h`** — vendored as authoritative register-address constants. Check in copies under `reference/upstream-headers/` to remove any runtime fetch dependency.

## 8. Layered Strategy for the Mac App

- **Layer A — Direct hardware I/O (extremely stable, identical between OP and OP2):** open the FTDI USB serial device (`/dev/cu.usbserial-*` or `/dev/cu.usbmodem*`) at **1 000 000 baud, 8-N-1**. Speak Dynamixel Protocol 1.0 to CM (ID 200), servos (1–20), FSR (111/112). Use `BULK_READ` (0x92) for fast multi-device polling and `SYNC_WRITE` (0x83) for setting all 20 joint targets in one packet.

- **Layer B — On-robot framework integration (optional, more fragile):** read/write `/darwin/Data/config.ini`, `walking.ini`, `motion_4096.bin`, and color LUTs over SSH/SFTP. The CM-730/CM-740 USB is **not** multiplexed: only one process at a time can hold the serial port. If the on-robot demo is running, DarwinForge must either stop it first, or talk through a higher-level proxy daemon wrapping `MotionManager`.

The two layers are kept as separate Swift targets (`DynamixelKit` + `RobotKit` for Layer A, `OnboardSyncKit` for Layer B) so a user with no network setup can still do bench work over USB.

---

## 9. Distinction: OP3 ≠ OP/OP2

OP3 uses **XM-430** servos, **Protocol 2.0**, an **Intel NUC i3**, and a different mechanical/wiring layout. Code targeting OP/OP2 must remain on Protocol 1.0; a future bridge to OP3 would be a separate Swift target (`DynamixelKitV2`) and a separate driver path. DarwinForge's scope is OP and OP2 only.
