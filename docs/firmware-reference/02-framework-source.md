# 02 — ROBOTIS-OP2 Framework Source (on-robot install)

## TL;DR

The factory rootfs ships the **full ROBOTIS-OP2 framework as an SVN working copy** at `/robotis/` (rev 90 of `svn://svn.code.sf.net/p/darwinop/code/trunk/robotisop2`, dated 2015-03-25), with all C++ sources, pre-built `.o` files, a pre-archived `Linux/lib/darwin.a` static library, and a compiled `demo` binary. This is the canonical "DARwIn Framework" — the older SVN-hosted single-tree C++ codebase that **predates** the ROS-based packages in the vendored upstream (`research/robotis-official/ROBOTIS-Framework`, `ROBOTIS-OP2`).

## ReleaseNote.txt

Full quote of `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/ReleaseNote.txt`:

```
You can get the latest version at below link.
https://sourceforge.net/projects/darwinop/

for more information on Webots visit
http://www.cyberbotics.com

=====================================
          ROBOTIS-OP2 v1.7.0
=====================================
>>> Date: 25 Mar 2015

>>> New functionality/features
    * First released.

>>> Changes
    * First released.

>>> Bug fixes
    * First released.
```

Single release note: **v1.7.0, 2015-03-25, "First released"**. There is no incremental changelog — this is the only entry.

## Top-level layout

```
robotis/                            # /robotis on the SD card
├── .svn/                           # SVN working copy metadata (rev 90)
├── Data/                           # data assets
│   ├── motion_1024.bin             # motion pages, MX-28 firmware 1024-step
│   ├── motion_4096.bin             # motion pages, MX-28 firmware 4096-step (in use)
│   └── mp3/                        # voice prompts ("Stand up.mp3", "Shoot.mp3", …)
├── Framework/                      # platform-independent C++ framework
│   ├── doc/ReadMe.txt              # 1-line pointer to darwin-op.springnote.com
│   ├── include/                    # public headers
│   └── src/                        # implementation (motion/, vision/, math/, minIni/)
├── Linux/                          # Linux-specific build + applications
│   ├── build/                      # Linux platform glue + Makefile (objs in place)
│   ├── include/                    # Linux-specific headers (LinuxCM730.h, …)
│   ├── lib/                        # darwin.a static library (compiled)
│   └── project/                    # binaries: demo, walk_tuner, action_editor, etc.
└── ReleaseNote.txt                 # quoted above
```

Note `.svn/` is present at every directory — this is a **Subversion 1.6-format working copy**, not just an export. `Data/`, `Framework/`, `Linux/`, and each subdir all carry `.svn/text-base/*.svn-base` shadow copies.

## Framework modules (`Framework/src/<dir>` = module)

Source: `find /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src -type d` (excluding `.svn/`).

| Subdir | Files | Description |
|---|---|---|
| `Framework/src/` (root) | `CM730.cpp`, `MX28.cpp` | Hardware register tables and packet protocol for the CM-730 sub-controller and the MX-28 Dynamixel servo. Placed at root (not under `motion/`) because both motion and vision modules link them. |
| `motion/` | `MotionManager.cpp`, `MotionStatus.cpp`, `Kinematics.cpp`, `JointData.cpp` | Motion subsystem core. `MotionManager` is the singleton 8 ms tick that owns the CM-730 and drives registered `MotionModule`s; `MotionStatus` is the global gyro/accel/button/fall state; `Kinematics` provides leg geometry constants; `JointData` is the per-joint state vector. |
| `motion/modules/` | `Walking.cpp`, `Head.cpp`, `Action.cpp` | The three concrete `MotionModule` subclasses. Walking is the inverse-kinematics gait generator; Head is pan/tilt with image-error tracking; Action plays binary motion pages from `motion_4096.bin`. |
| `vision/` | `Camera.cpp`, `Image.cpp`, `ImgProcess.cpp`, `ColorFinder.cpp`, `BallTracker.cpp`, `BallFollower.cpp` | Vision pipeline. `Camera` carries the camera FOV constants; `Image`/`FrameBuffer` hold YUV/RGB/HSV frames; `ImgProcess` provides YUV→RGB, RGB→HSV, erosion, dilation; `ColorFinder` does HSV thresholding; `BallTracker`/`BallFollower` build the ball-following demo behavior on top of the head module. |
| `math/` | `Vector.cpp`, `Point.cpp`, `Matrix.cpp`, `Plane.cpp` | Custom (non-Eigen) linear algebra: `Point2D`, `Point3D`, `Vector3D`, `Matrix3D` (4×4 homogeneous), `Plane3D` (stub class). |
| `minIni/` | `minIni.h`, `wxMinIni.h`, `minGlue.h` | Compagner's minIni single-file INI parser, header-only here (no `.cpp`; the framework's `Framework/include/minIni.h` is a one-liner that includes `../src/minIni/minIni.h`). |

No separate `MotionModule.cpp` exists — it's a pure-virtual base class with declarations only in `Framework/include/MotionModule.h`.

## Public API (`Framework/include/*.h`)

All public headers at `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/`:

### Motion subsystem
- `MotionModule.h` — abstract base. Pure virtuals `Initialize()`, `Process()`, member `JointData m_Joint`, constant `TIME_UNIT = 8` ms.
- `MotionManager.h` — singleton manager. Holds `std::list<MotionModule*> m_Modules`, a `CM730*`, gyro calibration state, optional log file stream, joint-offset array `m_Offset[NUMBER_OF_JOINTS]`. Methods: `Initialize/Reinitialize`, `Process` (called every tick), `SetEnable`, `AddModule`/`RemoveModule`, `LoadINISettings`/`SaveINISettings`, `StartLogging`/`StopLogging`.
- `MotionStatus.h` — global statics: `JointData m_CurrentJoints`, `FB_GYRO`, `RL_GYRO`, `FB_ACCEL`, `RL_ACCEL`, `BUTTON`, `FALLEN`. Fall thresholds (`FALLEN_F_LIMIT = 390`, `FALLEN_B_LIMIT = 580`, `FALLEN_MAX_COUNT = 30`) and an enum `{BACKWARD = -1, STANDUP = 0, FORWARD = 1}`.
- `JointData.h` — per-joint state. Enum `ID_R_SHOULDER_PITCH=1 … ID_HEAD_TILT=20, NUMBER_OF_JOINTS`. Compliance slopes (`SLOPE_HARD=16, DEFAULT=32, SOFT=64, EXTRASOFT=128`), PID defaults (`P=32, I=0, D=0`), per-joint enable/value/angle/PID setters and the `SetEnableLeftLegOnly`/`SetEnableUpperBodyWithoutHead`/etc. group toggles.
- `Kinematics.h` — geometry constants only: `CAMERA_DISTANCE`, `EYE_TILT_OFFSET_ANGLE`, `LEG_SIDE_OFFSET`, `THIGH_LENGTH`, `CALF_LENGTH`, `ANKLE_LENGTH`, `LEG_LENGTH`. Singleton — no `Process()`.
- `Walking.h` — `class Walking : public MotionModule`. Singleton. Public tunables (X/Y/Z/A/P/R offsets, `PERIOD_TIME`, `DSP_RATIO`, `X_MOVE_AMPLITUDE`, balance gains, arm-swing gain, PID gains), control methods `Start/Stop/Process/IsRunning`, INI persistence. Phase enum `PHASE0..PHASE3`. INI section `"Walking Config"`.
- `Head.h` — `class Head : public MotionModule`. Singleton. Pan/tilt limits, PD gains, `MoveToHome`, `MoveByAngle`, `MoveByAngleOffset`, `MoveTracking(Point2D err)` for image-error feedback. INI section `"Head Pan/Tilt"`.
- `Action.h` — `class Action : public MotionModule`. Singleton. Plays binary motion pages from `motion_*.bin`: `PAGE` is 512 bytes = `PAGEHEADER` (name, repeat, schedule, stepnum, speed, accel, next, exit, checksum, slope[31]) + 7 × `STEP` (31 joint positions, pause, time). Max 256 pages.

### Hardware
- `CM730.h` — sub-controller protocol. `class PlatformCM730` (pure-virtual port/semaphore/timeout interface to be implemented per-OS) and `class CM730` (Dynamixel 1.0 protocol: SUCCESS/TX_CORRUPT/TX_FAIL/RX_FAIL/RX_TIMEOUT/RX_CORRUPT errors; register map starting at `P_MODEL_NUMBER_L=0` through DXL power/LED/gyro/accel/voltage/button). Also `class BulkReadData` for SyncRead-style bulk reads (table is `MX28::MAXNUM_ADDRESS` bytes).
- `MX28.h` — Dynamixel MX-28 servo. Two register maps gated by `#define MX28_1024`: legacy 1024-step (default disabled in factory build) vs 4096-step (current). Constants `MIN_VALUE`/`CENTER_VALUE`/`MAX_VALUE`/`MIN_ANGLE`/`MAX_ANGLE`/`RATIO_VALUE2ANGLE`/`RATIO_ANGLE2VALUE` and helpers `Angle2Value`, `Value2Angle`, `GetMirrorValue`, `GetMirrorAngle`.
- `FSR.h` — Force-Sensing Resistor foot module. Fixed IDs `ID_R_FSR=111`, `ID_L_FSR=112`. Register map covers FSR1-4 raw + computed `P_FSR_X`/`P_FSR_Y` center-of-pressure.

### Math / Util
- `Point.h` — `Point2D` (X, Y) and `Point3D` (X, Y, Z) with arithmetic operators and `static Distance(...)`.
- `Vector.h` — `Vector3D` only. `Length`, `Normalize`, `Dot`, `Cross`, `AngleBetween` (with optional axis).
- `Matrix.h` — `Matrix3D` indexing enum `m00..m33` for a row-major 4×4 homogeneous matrix (declared, full body in `Matrix.cpp`).
- `Plane.h` — `Plane3D` is a near-empty class (constructor + destructor only). Reserved for future use.
- `minIni.h` — one-line shim that re-exports `../src/minIni/minIni.h` so framework consumers can write `#include "minIni.h"`.

### Vision
- `Image.h` — `class Image` (raw pixel buffer + width/height/pixelsize/widthstep) and `class FrameBuffer` (holds simultaneous YUV/RGB/HSV/BGRA frames; the BGRA frame is Webots-only).
- `ImgProcess.h` — static color-space and morphology ops: `YUVtoRGB`, `RGBtoHSV`, `Erosion`/`Dilation` (in-place and two-arg), `HFlipYUV`, `VFlipYUV`, plus Webots-only `BGRAtoHSV`.
- `Camera.h` — only carries the camera FOV: `VIEW_V_ANGLE = 46.0°`, `VIEW_H_ANGLE = 58.0°`, plus the static `WIDTH`/`HEIGHT`. The actual V4L2 driver lives in `Linux/include/LinuxCamera.h`.
- `ColorFinder.h` — HSV threshold filter. Public `m_hue` (0-360), `m_hue_tolerance` (0-180), `m_min_saturation` (0-100), `m_min_value` (0-100), `m_min_percent`/`m_max_percent`. INI section `"Find Color"`. `GetPosition(Image* hsv_img)` returns the filtered blob centroid.
- `BallTracker.h` — wraps `Head` to do search-when-lost behavior. Constants `NoBallMaxCount=15`, `NotFoundMaxCount=100`, `TiltTopLimit=25°`, `TiltBottomLimit=-12°`, `PanLimit=65°`.
- `BallFollower.h` — wraps `Walking` to drive toward a `Point2D` ball position, with kick-trigger logic (`KickBall` = 0/1/-1).

### Umbrella header
- `DARwIn.h` — convenience `#include`-all header that pulls in `CM730.h`, `MX28.h`, `MotionModule.h`, `MotionManager.h`, `MotionStatus.h`, `JointData.h`, `Action.h`, `Walking.h`, `Head.h`, `Image.h`, `ImgProcess.h`, `BallTracker.h`, `BallFollower.h`, `ColorFinder.h`, `Camera.h`, `Point.h`, `Vector.h`, `Matrix.h`, `Plane.h`, `minIni.h`. Use this in any user app.

### Linux-specific headers (`Linux/include/*.h`)
- `LinuxDARwIn.h` — umbrella header: `DARwIn.h` + the five Linux specializations below.
- `LinuxCM730.h` — `class LinuxCM730 : public PlatformCM730`. Wraps a `/dev/ttyUSB*` file descriptor and three POSIX `sem_t` priority semaphores for `Low`/`Mid`/`HighPriorityWait`/`Release`. Implements `OpenPort`, `SetBaud`, `Read/WritePort`, packet/update timeouts via `clock_gettime`-derived `GetCurrentTime`.
- `LinuxCamera.h` — V4L2 capture (`<linux/videodev2.h>`). `CameraSettings` struct (`brightness`, `contrast`, `saturation`, `gain`, `exposure`). Singleton `LinuxCamera::GetInstance()`. INI persistence; `CaptureFrame`/`CaptureFrameWb`. `SetAutoWhiteBalance` uses `V4L2_CID_AUTO_WHITE_BALANCE`.
- `LinuxMotionTimer.h` — drives the 8 ms motion tick via a POSIX `pthread`. Owns a `MotionManager*`; `Start`/`Stop`/`IsRunning`. The `TimerProc` is a static thread function.
- `LinuxNetwork.h` — POSIX BSD socket wrappers: `LinuxSocket` (create/bind/listen/accept/connect/send/recv), `LinuxSocketException`, `LinuxServer` (used by `roboplus` project as a TCP server on port 6501).
- `LinuxActionScript.h` — text-driven motion playback. Parses `script.asc` files like `(4,../../../Data/mp3/Thank you.mp3)` → "page 4 + play this MP3". Static `ScriptStart(filename)`, `PlayMP3(filename)`, `PlayMP3Wait(filename)`. Owns a `pthread_t` and the `mp3_pid` of the spawned `mpg123` process.
- `mjpg_streamer.h` — header for the mjpg-streamer subsystem (httpd.cpp/jpeg_utils.cpp/mjpg_streamer.cpp in `Linux/build/streamer/`), so apps can serve the camera over HTTP.

## Built artifacts

The factory image ships **everything pre-compiled**:

- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/lib/darwin.a` — single static archive, 262,092 bytes, `ar` format. Contents (verified by `ar t`): MX28.o, CM730.o, Matrix.o, Plane.o, Point.o, Vector.o, JointData.o, Kinematics.o, MotionManager.o, MotionStatus.o, Action.o, Head.o, Walking.o, BallFollower.o, BallTracker.o, ColorFinder.o, Image.o, ImgProcess.o, Camera.o, minIni.o, httpd.o, jpeg_utils.o, mjpg_streamer.o, LinuxCamera.o, LinuxCM730.o, LinuxNetwork.o (plus separator entries). **LinuxActionScript.o** and **LinuxMotionTimer.o** are present as loose `.o` in `Linux/build/` but apparently not in this snapshot of `darwin.a` (the Makefile lists them — likely a stale `.a` from a build before LinuxActionScript was added; not load-bearing).
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/*.o` — `LinuxActionScript.o` (5.3 KB), `LinuxCM730.o` (8.4 KB), `LinuxCamera.o` (16.3 KB), `LinuxMotionTimer.o` (3.6 KB), `LinuxNetwork.o` (15.0 KB), plus `streamer/httpd.o`, `streamer/jpeg_utils.o`, `streamer/mjpg_streamer.o`.
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/**/*.o` — every framework `.cpp` has a sibling `.o` next to it (CM730.o, MX28.o, math/*.o, motion/*.o, motion/modules/*.o, vision/*.o, minIni/minIni.o).
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/demo` — 32-bit Linux ELF executable for Intel 80386 (Atom Z530), 182,815 bytes, dynamically linked, `not stripped`. Build ID `4a2b6d349f2f4f86f4352f25d88994a82e47bb78`. This is the binary `auto_start` runs.

**Implication**: nothing needs to be rebuilt to use the factory firmware. To experiment, run `make -C Linux/build` (rebuilds `darwin.a`) then `make -C Linux/project/<name>` to relink an app. Pre-existing `.o` files mean even partial rebuilds are fast.

### Top-level Linux build Makefile

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/Makefile`:

```
CC = g++ ; AR = ar ; ARFLAGS = cr
TARGET = darwin.a
INCLUDE_DIRS = -I../include -I../../Framework/include
CXXFLAGS += -O2 -DLINUX -Wall -shared $(INCLUDE_DIRS)
LFLAGS += -lpthread -ldl
```

`-shared` in CXXFLAGS for a static archive is a vestigial flag; the archive is built with `$(AR) cr ../lib/darwin.a $(OBJS)`. Each project Makefile (`Linux/project/*/Makefile`) builds local `.o`s and links against `../../lib/darwin.a`, with a phony `darwin.a:` target that recurses into `../../build`. The standard compile flag is `-O2 -DLINUX -g -Wall` per project; libraries are `-lpthread -lncurses -lrt -ljpeg` (subset depending on whether the project uses ncurses TUI or the JPEG streamer).

## Projects (`robotis/Linux/project/*`)

### demo

- **Path**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/`
- **Files**: `Makefile`, `main.cpp` (11 KB), `StatusCheck.cpp`/`.h`, `VisionMode.cpp`/`.h`, `script.asc`, `www/` (mjpg-streamer HTTP UI), compiled `demo` (182 KB ELF) and its `.o`s.
- **What it does**: the headline demo binary. `main.cpp` pulls in `LinuxDARwIn.h`, `StatusCheck.h`, `VisionMode.h`; it picks `motion_4096.bin` (vs `motion_1024.bin` based on `#ifdef MX28_1024`), reads `../../../Data/config.ini` and a local `script.asc`, opens `/dev/ttyUSB0` for the CM-730, and drives soccer/vision/interactive demos. The `script.asc` file is a list of `(motion_page, mp3_path)` tuples played by `LinuxActionScript`.

### walk_tuner

- **Path**: `.../robotis/Linux/project/walk_tuner/`
- **Files**: `Makefile`, `main.cpp`, `cmd_process.cpp`/`.h`, `www/`. Uses **ncurses TUI** (LIBS `-lpthread -lncurses -lrt -ljpeg`).
- **What it does**: interactive walking-parameter tuner. Lets you tweak the `[Walking Config]` INI section (period_time, X/Y/Z move amplitudes, balance gains, pelvis offset, hip pitch offset, arm swing gain, …) while the robot walks and immediately calls `Walking::Process()` with the new values. Also exposes the MJPEG streamer.

### action_editor

- **Path**: `.../robotis/Linux/project/action_editor/`
- **Files**: `Makefile`, `main.cpp`, `cmd_process.cpp`/`.h`. ncurses, no JPEG.
- **What it does**: motion-page editor for `motion_4096.bin`. Reads/writes one of 256 PAGEs (header + 7 STEPs of 31 joint positions). Same role as the Windows-side RoboPlus Motion editor, but on-robot via ncurses.

### offset_tuner

- **Path**: `.../robotis/Linux/project/offset_tuner/`
- **Files**: `Makefile`, `main.cpp`, `cmd_process.cpp`/`.h`. ncurses, JPEG.
- **What it does**: per-joint zero-offset calibration. Walks all 20 joints, lets you nudge each by ±1 tick to define mechanical zero; result writes the `[Offset]` INI section consumed by `MotionManager::LoadINISettings()` / `m_Offset[NUMBER_OF_JOINTS]`.

### roboplus

- **Path**: `.../robotis/Linux/project/roboplus/`
- **Files**: `Makefile`, `main.cpp`, `protocol.txt`.
- **What it does**: TCP bridge for RoboPlus Motion (the Windows GUI). Opens a `LinuxServer` on **port 6501** speaking a simple text protocol documented in `protocol.txt` — `v` returns version, similar verbs for page get/put/play. Lets the Windows RoboPlus app talk to a robot over Ethernet/Wi-Fi as if it were the local USB device.

### firmware_installer

- **Path**: `.../robotis/Linux/project/firmware_installer/`
- **Files**: `Makefile`, `main.cpp`, `hex2bin.cpp`/`.h`, **`cm740_0x14.hex`** (CM-740 firmware v0x14), **`mx28_0x1A_1024.hex`** (MX-28 firmware v0x1A, 1024-step), **`mx28_0x1E+FSR_0x11.hex`** (combined MX-28 v0x1E 4096-step + FSR v0x11).
- **What it does**: flashes Dynamixel/CM bootloaders. `hex2bin.cpp` converts Intel-HEX to raw firmware; main.cpp drives the bootloader handshake over the CM-730 serial bus.

### dxl_monitor

- **Path**: `.../robotis/Linux/project/dxl_monitor/`
- **Files**: `Makefile`, `main.cpp`, `cmd_process.cpp`/`.h`. ncurses-free (LIBS `-lpthread -lrt`).
- **What it does**: low-level Dynamixel diagnostic. Scan IDs on the bus, read/write any register on any servo, watch present-position/temperature/load. Equivalent to ROBOTIS's `dxl_monitor` Windows tool.

### tutorial/*

Path: `.../robotis/Linux/project/tutorial/<sub>/`. Each subdirectory is a self-contained tiny app.

| Sub | Files | Description |
|---|---|---|
| `action_script` | Makefile, main.cpp, **config.ini**, **script.asc** | Plays a sequence of `(motion_page, mp3)` tuples via `LinuxActionScript::ScriptStart`. config.ini has full `[Camera]`+`[Find Color]`+`[Head Pan/Tilt]`+`[Walking Config]` sections — minimal viable INI for any framework app. |
| `ball_following` | Makefile, main.cpp, www/ | End-to-end: capture frame → ColorFinder → BallTracker → BallFollower → Walking, plus MJPEG streamer for remote view. No config.ini (uses defaults). |
| `camera` | Makefile, main.cpp, **config.ini**, www/ | Bare V4L2 capture + MJPEG streamer; config.ini contains only `[Camera]` settings (brightness=-1, contrast=-1, saturation=-1, gain=255, exposure=1000). |
| `color_filtering` | Makefile, main.cpp, **config.ini**, www/ | Camera + ColorFinder; config.ini adds `[Find Color]` (default hue=355 magenta-red, tol=15). |
| `fsr` | Makefile, main.cpp, **foot.raw**, www/ | Reads FSR sensors via the CM-730 bulk-read; `foot.raw` is a captured trace for offline replay. |
| `head_tracking` | Makefile, main.cpp, **config.ini**, www/ | Color → head pan/tilt feedback loop (uses BallTracker minus the walking layer). |
| `read_write` | Makefile, main.cpp | Hello-world: open CM-730, read MX-28 register 0x24 (present position), echo to console. No web UI. |

## SVN provenance

- **Repository URL**: `svn://svn.code.sf.net/p/darwinop/code/trunk/robotisop2`
  Verified by `cat /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/.svn/entries`:
  ```
  10
  dir
  90
  svn://svn.code.sf.net/p/darwinop/code/trunk/robotisop2
  svn://svn.code.sf.net/p/darwinop/code
  ...
  2015-03-25T07:56:24.742059Z
  ```
- **SVN revision**: **90**
- **SVN working-copy format**: **10** (Subversion 1.6 layout — each directory carries its own `.svn/text-base/*.svn-base` and `.svn/entries`).
- **Repository root**: `svn://svn.code.sf.net/p/darwinop/code` (SourceForge `darwinop` project).
- **Working-copy commit time**: **2015-03-25T07:56:24.742059Z** — exactly matches the v1.7.0 release date in `ReleaseNote.txt`.
- **Version string in headers**: none. The framework has no version constant; the only version marker is `ReleaseNote.txt` (1.7.0) and the SVN rev 90.
- **Last-modified dates**: all source files are timestamped 2015-03-25 (`stat` confirms `Mar 25 2015` on every framework file).
- **License**: per `Linux/build/Makefile` header — `License: GPL`. Per the SourceForge project, GPLv2.

## Comparison with vendored upstream

Vendored clones (in `research/robotis-official/`):
- `ROBOTIS-Framework` — commit `288e048adeb5195dae49626d044a30190fbab46c`, Apache 2.0, ROS-based packages: `robotis_framework_common`, `robotis_device`, `robotis_controller`, `robotis_framework` (meta).
- `ROBOTIS-OP2` — commit `9e18ae6e1b3cc9a770a0823872300274e520caf9`, Apache 2.0, ROS packages: `cm_740_module`, `op2_walking_module`, `op2_kinematics_dynamics`, `op2_manager`, `op2_gui_demo`, `robotis_op2` (meta).
- `ROBOTIS-OP-Framework` — directory exists but **empty** in the local clone.

**Top-level differences vs the on-robot `/robotis/Framework`+`/robotis/Linux` SVN tree:**

| Aspect | On-robot (this doc) | Vendored upstream |
|---|---|---|
| Source layout | Single SVN tree: `Framework/include`+`Framework/src` + `Linux/{build,include,lib,project}` | Multiple ROS Catkin packages: `cm_740_module/src`, `op2_walking_module/src`, etc., each with own `CMakeLists.txt`, `package.xml`. |
| Build system | Hand-rolled GNU Make (`Linux/build/Makefile` → `darwin.a`) | CMake + catkin |
| OS coupling | Tight: `LinuxCM730.h`, `LinuxCamera.h`, `LinuxNetwork.h` directly in `Linux/include/` | Cleaner: ROS hardware-interface plugins, `robotis_device` abstraction |
| Class names | `MotionModule`, `MotionManager`, `Walking`, `Head`, `Action` | Equivalent classes mostly renamed/refactored; OP2 walking module is `op2_walking_module.cpp` not `Walking.cpp` |
| Dependencies | Minimal: pthread, ncurses, rt, jpeg, dl | Heavy: ROS1 (roscpp, sensor_msgs, dynamixel_sdk, eigen, …) |
| Maintenance | Frozen at 2015-03-25 SVN rev 90 | Active until `_NOTES.md` notes "maintenance nearly stopped" — vendored commits are also old |
| License | GPL (per Makefile header) | Apache 2.0 |

**They are essentially the same algorithm in two different package layouts** — the upstream `op2_walking_module/src/op2_walking_module.cpp` is a refactor of the SVN `Framework/src/motion/modules/Walking.cpp`, the upstream `cm_740_module/src/cm_740_module.cpp` is a refactor of `Framework/src/CM730.cpp` + `Linux/include/LinuxCM730.h`. **The math is identical**; what differs is the integration layer (ROS topics + plugin lifecycle vs hand-rolled 8 ms pthread tick).

For Phase 2 algorithm reverse-engineering, the SVN tree at `/robotis/` is **more useful** because it has fewer abstraction layers and the loop is right in front of you. For Phase 5+ Rust porting style, the ROS variants are sometimes cleaner because of clearer module boundaries.

## What this means for Darwin

### Framework module → Rust module mapping

Comparing `Framework/src/` modules with our `app/core/forge-core/src/`:

| Framework C++ module | Rust target in `forge-core/src/` |
|---|---|
| `Framework/src/MX28.cpp`, `Framework/src/CM730.cpp` | `dynamixel/` (servo register tables + packet protocol) and `serial/` (transport). The split `MX28`/`CM730` files are the right ancestor; preserve the separation in Rust (`dynamixel/mx28.rs` + `dynamixel/cm730.rs`). |
| `Framework/src/motion/MotionManager.cpp` | `motion/` + `controller/`. `MotionManager` ↔ a Rust scheduler trait; the 8 ms tick is the central abstraction. |
| `Framework/src/motion/JointData.cpp` | `joint/` |
| `Framework/src/motion/MotionStatus.cpp` | `motion/status.rs` (global fall/gyro state — translate as a `RwLock`-guarded struct, not C++ statics) |
| `Framework/src/motion/Kinematics.cpp` | `walk/kinematics.rs` or `motion/kinematics.rs` (geometry constants are static) |
| `Framework/src/motion/modules/Walking.cpp` | `walk/` (the bulk of Sprint 5 — straight line-by-line port) |
| `Framework/src/motion/modules/Head.cpp` | `motion/head.rs` |
| `Framework/src/motion/modules/Action.cpp` | `motion/action.rs` + `docs/motion-format/` parser (the 512-byte PAGE format is documented elsewhere) |
| `Framework/src/vision/*` | `vision/` (Camera consts + ColorFinder + ImgProcess; we may swap in `opencv`-backed implementations) |
| `Framework/src/math/*` | replaced by `nalgebra` — do not re-port the custom Point/Vector/Matrix. |
| `Framework/src/minIni/*` | replaced by `serde_ini` / `toml`. |
| `Linux/include/LinuxCM730.h` | `serial/uart.rs` (V4L2 → tokio-serial; semaphores → tokio mutexes or just `&mut self`) |
| `Linux/include/LinuxMotionTimer.h` | `controller/timer.rs` (tokio interval @ 8 ms) |
| `Linux/include/LinuxCamera.h` | `vision/camera.rs` (V4L2 → `v4l` crate on Linux, AVFoundation on macOS) |
| `Linux/include/LinuxActionScript.h` | not needed — modern UI replaces script.asc with structured motion bundles |
| `Linux/include/LinuxNetwork.h` | not needed — replaced by tokio TCP / WebSocket |

The `control/` and `strategy/` modules in our Rust tree have no direct C++ ancestor — those are new abstractions we're adding (e.g. fall-recovery state machines, soccer/cosplay strategy plugins). Confirm with the architecture doc.

### Project → SwiftUI app inspiration

| Factory C++ project | SwiftUI app that should mirror it |
|---|---|
| `walk_tuner` (ncurses, port 8080 stream) | **Studio → Walk Tuner** screen: sliders for `[Walking Config]` keys (period_time, x/y/z amplitudes, balance gains, pelvis offset) bound to live `Walking::Process()` state via Rust IPC. The factory app proves the parameter set is finite and tunable in real time. |
| `action_editor` (ncurses motion-page editor) | **Studio → Motion Page Editor**: timeline of 7 STEP rows × 31 joint columns, with PAGEHEADER fields (name, repeat, schedule, next, exit) at the top. The on-robot version is the authoritative spec. |
| `offset_tuner` (ncurses per-joint zero) | **Studio → Joint Calibration** (we have this in v0.1). |
| `demo` (soccer + vision + voice) | **Demo / Play** mode that just exposes "Start soccer", "Start motion demo", "Start vision demo" buttons — load the same `motion_4096.bin` + `script.asc` schema. |
| `dxl_monitor` (Dynamixel diagnostic) | **Diagnostics** screen — Sprint 7 already has bus-scan + register-watch, modeled on this. |
| `firmware_installer` (CM-740 / MX-28 hex flashing) | **Service → Firmware** (deferred; we keep the `.hex` files as artifacts but defer building a flasher GUI). |
| `roboplus` (TCP bridge on port 6501) | Not in scope — replaced by our gRPC/WebSocket protocol to the SwiftUI client. |
| `tutorial/*` | Inspiration for individual demos and tests; the `head_tracking` flow is the smallest end-to-end vision pipeline. |

### Source we should re-vendor or update

- **Re-vendor**: `/robotis/Linux/project/firmware_installer/*.hex` — these binary firmwares are not in the upstream ROS repos. Copy them to `assets/firmware/` so we can ship them with future tooling.
- **Re-vendor**: `/robotis/Data/motion_4096.bin` and `/robotis/Data/motion_1024.bin` — needed for any motion-page work; the format is documented in `docs/motion-format/`.
- **Re-vendor**: `/robotis/Data/mp3/*.mp3` — 20 voice prompts (Stand up, Sit down, Bye bye, Clap please, Shoot, Headstand, …). These are the canonical demo soundtrack.
- **Do NOT update**: the SVN tree is frozen and authoritative for Darwin-OP2. Pulling upstream rev > 90 risks breaking 32-bit Atom Z530 compatibility; treat 2015-03-25 SVN rev 90 as the source of truth.
- **Reference, don't port**: `Framework/src/math/Matrix.cpp` and friends — use `nalgebra`.

## Evidence

All cited absolute paths (verified to exist on disk):

1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/ReleaseNote.txt`
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/.svn/entries` (SVN rev 90, URL `svn://svn.code.sf.net/p/darwinop/code/trunk/robotisop2`, 2015-03-25T07:56:24Z)
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/doc/ReadMe.txt`
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MotionModule.h`
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MotionManager.h`
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MotionStatus.h`
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/JointData.h`
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/CM730.h`
9. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MX28.h`
10. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Walking.h`
11. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Head.h`
12. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Action.h`
13. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Kinematics.h`
14. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/FSR.h`
15. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/DARwIn.h`
16. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Camera.h`
17. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/ColorFinder.h`
18. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/BallTracker.h`
19. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/BallFollower.h`
20. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Image.h`
21. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/ImgProcess.h`
22. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Point.h`
23. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Vector.h`
24. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Matrix.h`
25. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Plane.h`
26. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/minIni.h`
27. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxDARwIn.h`
28. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxCM730.h`
29. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxMotionTimer.h`
30. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxCamera.h`
31. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxNetwork.h`
32. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxActionScript.h`
33. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/Makefile`
34. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/lib/darwin.a` (262 KB static library)
35. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/streamer/mjpg_streamer.cpp` (and `httpd.cpp`, `jpeg_utils.cpp`)
36. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp`
37. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/demo` (ELF 32-bit Linux executable, 182,815 bytes)
38. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/walk_tuner/Makefile`
39. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/action_editor/Makefile`
40. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/offset_tuner/Makefile`
41. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/roboplus/protocol.txt`
42. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/firmware_installer/cm740_0x14.hex` (and `mx28_0x1A_1024.hex`, `mx28_0x1E+FSR_0x11.hex`)
43. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/dxl_monitor/main.cpp`
44. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/config.ini`
45. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/camera/config.ini`
46. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/motion_4096.bin` (and `motion_1024.bin`)
47. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/mp3/Stand up.mp3` (representative of 20 MP3 prompts)
48. `/Users/bbikiming/Documents/vibe_coding/Darwin/research/robotis-official/ROBOTIS-Framework/_NOTES.md`
49. `/Users/bbikiming/Documents/vibe_coding/Darwin/research/robotis-official/ROBOTIS-OP2/_NOTES.md`
50. `/Users/bbikiming/Documents/vibe_coding/Darwin/research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp`
51. `/Users/bbikiming/Documents/vibe_coding/Darwin/research/robotis-official/ROBOTIS-OP2/cm_740_module/src/cm_740_module.cpp`
