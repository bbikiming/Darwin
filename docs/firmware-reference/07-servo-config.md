# 07 — Servo + CM-730 Configuration (ROBOTIS-OP2 Factory Firmware)

## TL;DR

ROBOTIS-OP2 factory firmware (snapshot 2015-03-26) drives **20 MX-28T Dynamixel servos** (IDs 1–20) plus an optional pair of **FSR boards** (IDs 111/112) over a single half-duplex TTL bus, all bridged to the onboard PC by the **CM-740 sub-controller** at **ID 200** on `/dev/ttyUSB0`. The bus runs at **1 000 000 bps (1 Mbps), 8-N-1** — the host opens the port at `B38400` and uses Linux `TIOCSSERIAL` custom-divisor to reach 1 Mbps. The `MotionManager` 8 ms loop sends one **`SYNC_WRITE` at MX-28 address 26 (D-gain)** with 7-byte payload per joint (D-I-P-reserved-goalL-goalH) and reads a single **`BULK_READ`** covering CM-730 RAM (24..53), left FSR (26..35) and right FSR (26..35). The factory firmware-installer ships **CM-740 firmware version 0x14 (20)** and **MX-28T firmware version 0x1E (30) bundled with FSR 0x11 (17)**.

## Joint ID map (from JointData.h)

Quoted verbatim from `Framework/include/JointData.h`:

```cpp
enum
{
    ID_R_SHOULDER_PITCH     = 1,
    ID_L_SHOULDER_PITCH     = 2,
    ID_R_SHOULDER_ROLL      = 3,
    ID_L_SHOULDER_ROLL      = 4,
    ID_R_ELBOW              = 5,
    ID_L_ELBOW              = 6,
    ID_R_HIP_YAW            = 7,
    ID_L_HIP_YAW            = 8,
    ID_R_HIP_ROLL           = 9,
    ID_L_HIP_ROLL           = 10,
    ID_R_HIP_PITCH          = 11,
    ID_L_HIP_PITCH          = 12,
    ID_R_KNEE               = 13,
    ID_L_KNEE               = 14,
    ID_R_ANKLE_PITCH        = 15,
    ID_L_ANKLE_PITCH        = 16,
    ID_R_ANKLE_ROLL         = 17,
    ID_L_ANKLE_ROLL         = 18,
    ID_HEAD_PAN             = 19,
    ID_HEAD_TILT            = 20,
    NUMBER_OF_JOINTS
};
```

`NUMBER_OF_JOINTS = 21` (sentinel, not a real joint). The framework iterates `for (int id = ID_R_SHOULDER_PITCH; id < NUMBER_OF_JOINTS; id++)` — i.e. ID 1..20 inclusive — across `MotionManager::Initialize`, `Walking`, `Action`, `dxl_monitor`, `offset_tuner`, and `firmware_installer`.

Tabular view (3 shoulders + elbow per side, 6 leg joints per side, 2 head):

| ID | Symbol | Side | Body part | Axis |
|----|--------|------|-----------|------|
| 1  | `ID_R_SHOULDER_PITCH` | R | Shoulder | pitch |
| 2  | `ID_L_SHOULDER_PITCH` | L | Shoulder | pitch |
| 3  | `ID_R_SHOULDER_ROLL`  | R | Shoulder | roll |
| 4  | `ID_L_SHOULDER_ROLL`  | L | Shoulder | roll |
| 5  | `ID_R_ELBOW`          | R | Elbow    | pitch |
| 6  | `ID_L_ELBOW`          | L | Elbow    | pitch |
| 7  | `ID_R_HIP_YAW`        | R | Hip      | yaw |
| 8  | `ID_L_HIP_YAW`        | L | Hip      | yaw |
| 9  | `ID_R_HIP_ROLL`       | R | Hip      | roll |
| 10 | `ID_L_HIP_ROLL`       | L | Hip      | roll |
| 11 | `ID_R_HIP_PITCH`      | R | Hip      | pitch |
| 12 | `ID_L_HIP_PITCH`      | L | Hip      | pitch |
| 13 | `ID_R_KNEE`           | R | Knee     | pitch |
| 14 | `ID_L_KNEE`           | L | Knee     | pitch |
| 15 | `ID_R_ANKLE_PITCH`    | R | Ankle    | pitch |
| 16 | `ID_L_ANKLE_PITCH`    | L | Ankle    | pitch |
| 17 | `ID_R_ANKLE_ROLL`     | R | Ankle    | roll |
| 18 | `ID_L_ANKLE_ROLL`     | L | Ankle    | roll |
| 19 | `ID_HEAD_PAN`         | C | Head     | yaw |
| 20 | `ID_HEAD_TILT`        | C | Head     | pitch |

Reserved IDs from `CM730.h` / `FSR.h`:

| ID | Symbol | Device |
|----|--------|--------|
| 111 | `FSR::ID_R_FSR` | Right foot FSR board |
| 112 | `FSR::ID_L_FSR` | Left foot FSR board |
| 200 | `CM730::ID_CM` | Sub-controller (CM-730/740) |
| 254 | `CM730::ID_BROADCAST` | Broadcast (no status reply) |

## CM-730 / CM-740 control table (from CM730.h)

Full enum at `Framework/include/CM730.h:89–149`:

EEPROM (0..16):

| Address | Name | Width | Default |
|---------|------|-------|---------|
| 0–1 | `P_MODEL_NUMBER_L/H` | 2 | model id |
| 2 | `P_VERSION` | 1 | firmware version |
| 3 | `P_ID` | 1 | **200** (`ID_CM`) |
| 4 | `P_BAUD_RATE` | 1 | 1 = 1 Mbps |
| 5 | `P_RETURN_DELAY_TIME` | 1 | μs/2; reset to **0** by firmware-installer |
| 16 | `P_RETURN_LEVEL` | 1 | reset to **2** (reply to all) |

RAM (24..80):

| Address | Name | Width | Description |
|---------|------|-------|-------------|
| 24 | `P_DXL_POWER` | 1 | Dynamixel rail gate (1 = on) |
| 25 | `P_LED_PANNEL` | 1 | 3 chest LEDs as bitmask |
| 26–27 | `P_LED_HEAD_L/H` | 2 | RGB565, head pair |
| 28–29 | `P_LED_EYE_L/H` | 2 | RGB565, eye pair |
| 30 | `P_BUTTON` | 1 | mode/start (bit 0/1) |
| 38–43 | `P_GYRO_Z/Y/X` | 6 | 3 × 16-bit gyro samples |
| 44–49 | `P_ACCEL_X/Y/Z` | 6 | 3 × 16-bit accel samples |
| 50 | `P_VOLTAGE` | 1 | Battery, 0.1 V/LSB |
| 51–52 | `P_LEFT_MIC_L/H` | 2 | OP1 microphone L |
| 53–66 | `P_ADC2..ADC8` | 14 | 7 × 16-bit aux ADC |
| 67–68 | `P_RIGHT_MIC_L/H` | 2 | OP1 microphone R |
| 69–80 | `P_ADC10..ADC15` | 12 | 6 × 16-bit aux ADC |

`MAXNUM_ADDRESS = 81`. Notable symbolic constants from the same file:

- `MAXNUM_TXPARAM = 256`, `MAXNUM_RXPARAM = 1024` — packet buffer sizes (`CM730.h:13–14`).
- `RefreshTime = 6` ms — internal refresh constant (`CM730.h:159`, but motion loop uses 8 ms via `MotionManager`).

Instruction-byte constants (from `CM730.cpp:22–29`):

```cpp
#define INST_PING        (1)
#define INST_READ        (2)
#define INST_WRITE       (3)
#define INST_REG_WRITE   (4)
#define INST_ACTION      (5)
#define INST_RESET       (6)
#define INST_SYNC_WRITE  (131)   // 0x83
#define INST_BULK_READ   (146)   // 0x92
```

Error bits (`CM730.h:78–87`): `INPUT_VOLTAGE=1, ANGLE_LIMIT=2, OVERHEATING=4, RANGE=8, CHECKSUM=16, OVERLOAD=32, INSTRUCTION=64`.

### BULK_READ packet composition (factory MotionManager loop)

`CM730::MakeBulkReadPacket` (`Framework/src/CM730.cpp:390–434`) builds a single broadcast `0x92` packet with three sub-requests:

1. If ping CM-730 OK → `length = 30, id = 200, start = P_DXL_POWER (24)` → grabs `DXL_POWER` + LED panel + LED head/eye + button + **gyro 3 axes + accel 3 axes + voltage** + mic-L in one shot (24..53, 30 bytes).
2. If ping `FSR::ID_L_FSR (112)` OK → `length = 10, id = 112, start = P_FSR1_L (26)` → 4 FSR cells × 2 bytes + FSR_X + FSR_Y.
3. If ping `FSR::ID_R_FSR (111)` OK → `length = 10, id = 111, start = P_FSR1_L (26)` → same.

> Per-joint position reads are commented out in the production `MakeBulkReadPacket` (lines 406–415); the framework polls **only** sub-controller + FSRs every cycle. Per-joint position queries are issued one-off at `MotionManager::Initialize` and on demand. The Webots-build alternative `MakeBulkReadPacketWb` (lines 703–728) adds 6-byte `MX28::P_PRESENT_POSITION_L` reads per joint — used by the simulator only.

### SYNC_WRITE packet composition

`MotionManager::Process` (`Framework/src/motion/MotionManager.cpp:286–317`) issues one `SYNC_WRITE` per cycle, addressed `MX28::P_D_GAIN (26)` with `each_length = MX28::PARAM_BYTES = 7`:

| Byte | Field |
|------|-------|
| 0 | joint ID |
| 1 | D gain (address 26) |
| 2 | I gain (address 27) |
| 3 | P gain (address 28) |
| 4 | reserved (0, address 29) |
| 5 | goal position low (address 30) |
| 6 | goal position high (address 31) |

Goal position is `MotionStatus::m_CurrentJoints.GetValue(id) + m_Offset[id]` (line 303–304) — i.e. the per-robot calibration offset is summed into the goal at write time, never persisted into servo EEPROM.

The MX28_1024 build path uses `each_length = 5` and writes starting at `MX28::P_CW_COMPLIANCE_SLOPE` instead (line 296, 314) — that path is **disabled** in the factory firmware (`#define MX28_1024` is commented out in `MX28.h:11`).

## MX-28 control table key fields (from MX28.h)

The factory tree compiles the **4096-resolution (MX-28T firmware ≥ 0x1B)** branch — `#define MX28_1024` is commented out at `Framework/include/MX28.h:11`.

EEPROM (0..23):

| Address | Name | Width |
|---------|------|-------|
| 0–1 | `P_MODEL_NUMBER_L/H` | 2 |
| 2 | `P_VERSION` | 1 |
| 3 | `P_ID` | 1 |
| 4 | `P_BAUD_RATE` | 1 |
| 5 | `P_RETURN_DELAY_TIME` | 1 |
| 6–7 | `P_CW_ANGLE_LIMIT_L/H` | 2 |
| 8–9 | `P_CCW_ANGLE_LIMIT_L/H` | 2 |
| 11 | `P_HIGH_LIMIT_TEMPERATURE` | 1 |
| 12 | `P_LOW_LIMIT_VOLTAGE` | 1 |
| 13 | `P_HIGH_LIMIT_VOLTAGE` | 1 |
| 14–15 | `P_MAX_TORQUE_L/H` | 2 |
| 16 | `P_RETURN_LEVEL` | 1 |
| 17 | `P_ALARM_LED` | 1 |
| 18 | `P_ALARM_SHUTDOWN` | 1 |
| 19 | `P_OPERATING_MODE` | 1 |
| 20–23 | `P_LOW_/HIGH_CALIBRATION_*` | 4 |

RAM (24..67):

| Address | Name | Width |
|---------|------|-------|
| 24 | `P_TORQUE_ENABLE` | 1 |
| 25 | `P_LED` | 1 |
| **26** | **`P_D_GAIN`** | 1 |
| **27** | **`P_I_GAIN`** | 1 |
| **28** | **`P_P_GAIN`** | 1 |
| 29 | `P_RESERVED` | 1 |
| **30–31** | **`P_GOAL_POSITION_L/H`** | 2 |
| 32–33 | `P_MOVING_SPEED_L/H` | 2 |
| 34–35 | `P_TORQUE_LIMIT_L/H` | 2 |
| **36–37** | **`P_PRESENT_POSITION_L/H`** | 2 |
| 38–39 | `P_PRESENT_SPEED_L/H` | 2 |
| 40–41 | `P_PRESENT_LOAD_L/H` | 2 |
| 42 | `P_PRESENT_VOLTAGE` | 1 |
| 43 | `P_PRESENT_TEMPERATURE` | 1 |
| 44 | `P_REGISTERED_INSTRUCTION` | 1 |
| 45 | `P_PAUSE_TIME` | 1 |
| 46 | `P_MOVING` | 1 |
| 47 | `P_LOCK` | 1 |
| 48–49 | `P_PUNCH_L/H` | 2 |
| 52–67 | `P_POT_L/H`, `P_PWM_OUT_L/H`, P/I/D error + output mirrors | 16 |

`MAXNUM_ADDRESS = 68` for the 4096-resolution branch.

### Position range and angle conversion

From `Framework/src/MX28.cpp:22–31` (4096-resolution branch active):

```cpp
const int    MX28::MIN_VALUE          = 0;
const int    MX28::CENTER_VALUE       = 2048;
const int    MX28::MAX_VALUE          = 4095;
const double MX28::MIN_ANGLE          = -180.0;   // degree
const double MX28::MAX_ANGLE          =  180.0;
const double MX28::RATIO_VALUE2ANGLE  = 0.088;    // 360 / 4096
const double MX28::RATIO_ANGLE2VALUE  = 11.378;   // 4096 / 360
const int    MX28::PARAM_BYTES        = 7;        // SYNC_WRITE chunk size
```

Helpers:

```cpp
static int    Angle2Value(double angle) { return (int)(angle*RATIO_ANGLE2VALUE)+CENTER_VALUE; }
static double Value2Angle(int value)    { return (double)(value-CENTER_VALUE)*RATIO_VALUE2ANGLE; }
static int    GetMirrorValue(int value) { return MAX_VALUE + 1 - value; }
static double GetMirrorAngle(double a)  { return -a; }
```

(Confirms `docs/architecture/joint-conventions.md` — 0 maps to −180°, 2048 to 0°, 4095 to +180°.)

The legacy 1024-resolution branch (firmware version < 27) is preserved for compatibility but not built: `MIN_ANGLE = -150°`, `MAX_ANGLE = +150°`, `CENTER_VALUE = 512`, `MAX_VALUE = 1023`, `PARAM_BYTES = 5` (`MX28.cpp:14–21`).

## Factory init parameters

### Serial port

`Framework/Linux/build/LinuxCM730.cpp:52`:

```cpp
double baudrate = 1000000.0; //bps (1Mbps)
```

The Linux port speaks `B38400` to the kernel and reaches 1 Mbps via the FTDI `TIOCSSERIAL` custom-divisor trick (`baud_base / 1000000`). `SetBaud(int)` uses Dynamixel's `baudrate = 2_000_000 / (baud + 1)` formula (line 112). Byte transfer time is precomputed: `(1000.0 / baudrate) * 12.0` ms (line 98).

### Dynamixel-power-on / LED handshake

`CM730::DXLPowerOn` (`Framework/src/CM730.cpp:489–507`):

```cpp
if (WriteByte(CM730::ID_CM, CM730::P_DXL_POWER, 1, 0) == SUCCESS) {
    WriteWord(CM730::ID_CM, CM730::P_LED_HEAD_L,
              MakeColor(255, 128, 0), 0);       // head LED → orange
    m_Platform->Sleep(300);                     // 300 ms settle
}
```

`Disconnect` (line 509–517) emits a literal 9-byte packet `FF FF C8 05 03 1A E0 03 32` which is a `WRITE_DATA` to ID 200 (`0xC8 = 200`), address `0x1A` (= 26 = `P_LED_HEAD_L`), value `0x03E0` — i.e. shutdown leaves the **head LED green**.

### Default PID / compliance constants

`Framework/include/JointData.h:42–55`:

```cpp
enum { SLOPE_HARD = 16, SLOPE_DEFAULT = 32, SLOPE_SOFT = 64, SLOPE_EXTRASOFT = 128 };
enum { P_GAIN_DEFAULT = 32, I_GAIN_DEFAULT = 0, D_GAIN_DEFAULT = 0 };
```

The Walking module overrides arm gains at construction (`Framework/src/motion/modules/Walking.cpp:45–77`):

```cpp
P_GAIN = JointData::P_GAIN_DEFAULT;   // 32
I_GAIN = JointData::I_GAIN_DEFAULT;   // 0
D_GAIN = JointData::D_GAIN_DEFAULT;   // 0
// Per-joint arm overrides at startup:
m_Joint.SetPGain(ID_R_SHOULDER_PITCH, 8);
m_Joint.SetPGain(ID_L_SHOULDER_PITCH, 8);
m_Joint.SetPGain(ID_R_SHOULDER_ROLL,  8);
m_Joint.SetPGain(ID_L_SHOULDER_ROLL,  8);
m_Joint.SetPGain(ID_R_ELBOW,          8);
m_Joint.SetPGain(ID_L_ELBOW,          8);
```

So the factory profile is: **legs + head = P=32 / I=0 / D=0**; **both arms = P=8 / I=0 / D=0** (soft, to absorb shock during gait). The default SLOPE constants are used only on the legacy MX-28_1024 path.

### Torque enable

`MotionManager::Initialize` (`Framework/src/motion/MotionManager.cpp:35–77`) does **not** issue any torque-enable write. Torque is left in the state the servos powered up with — i.e. `P_TORQUE_ENABLE = 0` after `DXL_POWER` was toggled by `CM730::DXLPowerOn`. The `Action` module and `Walking::Start` are responsible for enabling per-joint torque before motion.

### Joint EEPROM reset values (firmware_installer)

`Linux/project/firmware_installer/main.cpp:106–356`, the `Reset(CM730*, int id)` helper called once per joint after MX-28 firmware install. Per-joint EEPROM is rewritten with:

| Register | Value |
|----------|-------|
| `P_RETURN_DELAY_TIME` (5) | 0 |
| `P_RETURN_LEVEL` (16) | 2 (status reply on all instructions) |
| `P_HIGH_LIMIT_TEMPERATURE` (11) | 80 (°C) |
| `P_LOW_LIMIT_VOLTAGE` (12) | 60 (= 6.0 V) |
| `P_HIGH_LIMIT_VOLTAGE` (13) | 140 (= 14.0 V) |
| `P_MAX_TORQUE_L/H` (14–15) | `MX28::MAX_VALUE = 4095` |
| `P_ALARM_LED` (17) | 36 (`0x24` = OVERLOAD | OVERHEATING) |
| `P_ALARM_SHUTDOWN` (18) | 36 (same) |
| `P_CW_ANGLE_LIMIT` (6–7) | per-joint, see table below |
| `P_CCW_ANGLE_LIMIT` (8–9) | per-joint, see table below |

CW/CCW angle limits (degrees) baked into the firmware-installer reset code (lines 153–239):

| Joint | CW (°) | CCW (°) |
|-------|--------|---------|
| R_SHOULDER_PITCH / L_SHOULDER_PITCH / SHOULDER joints not listed | −180 | +180 (`MX28::MIN/MAX_ANGLE`) |
| R_SHOULDER_ROLL | −75 | +135 |
| L_SHOULDER_ROLL | −135 | +75 |
| R_ELBOW | −95 | +70 |
| L_ELBOW | −70 | +95 |
| R_HIP_YAW | −123 | +53 |
| L_HIP_YAW | −53 | +123 |
| R_HIP_ROLL | −45 | +59 |
| L_HIP_ROLL | −59 | +45 |
| R_HIP_PITCH | −100 | +29 |
| L_HIP_PITCH | −29 | +100 |
| R_KNEE | −6 | +130 |
| L_KNEE | −130 | +6 |
| R_ANKLE_PITCH | −72 | +80 |
| L_ANKLE_PITCH | −80 | +72 |
| R_ANKLE_ROLL | −44 | +63 |
| L_ANKLE_ROLL | −63 | +44 |
| HEAD_TILT | −25 | +55 |
| HEAD_PAN | (defaults to ±180; no override in switch) | |

> These are the **factory mechanical limits** — they encode the joint asymmetry from the chassis (e.g. the right knee can only flex CCW because of the leg-bone geometry). Joint values are then offset by per-robot `m_Offset[id]` (loaded from `config.ini [Offset]`) before reaching the servo.

> Note on `R/L_SHOULDER_PITCH`: there is **no `case` label** for them in `Reset()`, so they retain `cwLimit = MX28::MIN_ANGLE (-180)`, `ccwLimit = MX28::MAX_ANGLE (+180)`. The pitch axis is unrestricted by firmware-installer — collision avoidance is left to higher layers.

### Reset for ID 200 (CM-740)

When called with `id = CM730::ID_CM`, `Reset()` only writes `P_RETURN_DELAY_TIME = 0` and `P_RETURN_LEVEL = 2`. CM-740 has no angle-limit semantics.

## Joint offset calibration

### How `offset_tuner` calibrates

`Linux/project/offset_tuner/cmd_process.cpp`:

- **InitPose** (line 29) — a hand-coded 21-element `int InitPose[]` initial pose for the robot when calibrating. (For example, knees and shoulders are not centered at 2047 — `InitPose[12] = 2013`, `InitPose[20] = 2170`, etc.)
- The user moves each joint with arrow keys; `[`/`]` adjust the current cell by ±1; `{`/`}` adjust by ±10 (lines 113–118 of `Linux/project/offset_tuner/main.cpp`).
- `m_Offset[id]` is stored in `MotionManager::GetInstance()->m_Offset[]` at runtime, then summed into the goal at `MotionManager::Process` (line 303–304):

  ```cpp
  param[n++] = CM730::GetLowByte (GetValue(id) + m_Offset[id]);
  param[n++] = CM730::GetHighByte(GetValue(id) + m_Offset[id]);
  ```
- On `save` the offsets are persisted via `MotionManager::SaveINISettings(ini)` (cmd_process.cpp:826–833).

### Storage format (`config.ini` `[Offset]` section)

`Framework/src/motion/MotionManager.cpp:140–167`:

```cpp
#define OFFSET_SECTION "Offset"
#define INVALID_VALUE  -1024.0

for (int i = 1; i < JointData::NUMBER_OF_JOINTS; i++) {
    char key[10];
    sprintf(key, "ID_%.2d", i);
    if ((ivalue = ini->geti(section, key, INVALID_VALUE)) != INVALID_VALUE)
        m_Offset[i] = ivalue;
}
```

So a calibrated robot's `config.ini` has a section like:

```ini
[Offset]
ID_01 = 12
ID_02 = -8
...
ID_20 = 0
```

The default `INI_FILE_PATH` is `"../../../Data/config.ini"` (`offset_tuner/main.cpp:17`, also `demo/main.cpp` and `tutorial/action_script/main.cpp:27`).

### Offsets are RAM-only on the servo

The offset is **never written to MX-28 EEPROM**. It only modifies the goal position at SYNC_WRITE time. Pulling power on the robot does not erase the calibration because it lives in `Data/config.ini` on the onboard PC's microSD, not on the servos themselves.

### Factory `offset.ini` / `config.ini` present?

**No factory-pristine `Data/config.ini` ships in this firmware backup.** `find sda1-rootfs -name "config.ini"` returns only the **tutorial sample configs** (`Linux/project/tutorial/{action_script,camera,head_tracking,color_filtering}/config.ini`), all four of which contain camera/walking/PID tuning but **no `[Offset]` section**. The expected production path `robotis/Data/config.ini` does not exist in the snapshot — meaning the factory shipped the robot with **no offset calibration** (all `m_Offset[i] = 0`, the constructor default at `MotionManager.cpp:27–28`), and the user was expected to run `offset_tuner` after delivery.

`robotis/Data/` contains only motion binaries and the MP3 audio set:

```
Data/motion_1024.bin    131 072 bytes (legacy MX-28 1024-resolution motion library)
Data/motion_4096.bin    131 072 bytes (4096-resolution motion library — active)
Data/mp3/               speech samples
```

The `offset_tuner` save target is whichever `INI_FILE_PATH` the binary was built with — relative path `../../../Data/config.ini` from the `Linux/project/offset_tuner/` working directory.

## Firmware versions (from firmware_installer)

`Linux/project/firmware_installer/main.cpp:366–367` declares the **default firmware blob filenames**, which encode their version numbers in hex:

```cpp
char *controller_fw = (char*)"cm740_0x14.hex";
char *actuator_fw   = (char*)"mx28_0x1E+FSR_0x11.hex";
```

Embedded blobs on disk (all are Intel HEX, CRLF line endings):

| File | Size (bytes) | Version | Notes |
|------|--------------|---------|-------|
| `Linux/project/firmware_installer/cm740_0x14.hex` | 65 044 | **0x14 = 20** | CM-740 sub-controller firmware. Active default. |
| `Linux/project/firmware_installer/mx28_0x1E+FSR_0x11.hex` | 168 089 | **MX-28 0x1E = 30, FSR 0x11 = 17** | Combined MX-28 + FSR firmware. Active default. |
| `Linux/project/firmware_installer/mx28_0x1A_1024.hex` | 109 932 | **0x1A = 26** | Legacy MX-28 firmware for 1024-resolution. Kept for downgrade only. |

The installer's version check (`firmware_installer/main.cpp:705–719` and `dxl_monitor/main.cpp:157–172`) refuses to mix-and-match:

```cpp
if (0 < firm_ver && firm_ver < 27) {
    fprintf(stderr, "\n MX-28's firmware is not support 4096 resolution!! \n");
    fprintf(stderr, " Upgrade MX-28's firmware to version 27(0x1B) or higher.\n\n");
    goto EXIT;
}
```

> Translation: **factory-built OP2 robots from this snapshot ship with MX-28T firmware version 0x1E (30) and CM-740 firmware version 0x14 (20).** Any MX-28 below version 0x1B is treated as the old 1024-resolution variant and would have required the `mx28_0x1A_1024.hex` legacy build.

Installer mechanics (mode 2, `main.cpp:591–728`):

- Port: `/dev/ttyUSB0` at **B57600**, 8-N-1 (line 481).
- Trigger: spam `#` until robot responds (line 494–507).
- Erase: `l 8023000\r` (line 594) — start address 0x8023000 (MX-28 flash region).
- Download in 64-byte chunks + checksum byte (lines 612–639).
- Boot: `go 8023000\r` (line 653).
- After install, `Reset(&cm730, id)` is called for every joint plus the CM-740 (lines 720–723).

CM-740 install (mode 1, `main.cpp:517–590`) uses bootloader command `l\r` from `/dev/ttyUSB0` at B57600. Note the **install port speed (57 600 bps) is different from operational port speed (1 Mbps)** — the CM-740 bootloader speaks 57 600 bps, the application firmware speaks 1 Mbps.

## What this means for Darwin

### Cross-check against `docs/architecture/joint-conventions.md`

> **Inconsistency found.** The Darwin doc (`docs/architecture/joint-conventions.md:16–25`) lists hip yaw at **ID 11/12**, hip roll at **13/14**, hip pitch at **15/16**, knee at **17/18**, omits ankles entirely, and labels HEAD_PAN/TILT as **19/20**. The factory `JointData.h` actually assigns:
>
> - 7/8 = HIP_YAW (Darwin says 11/12)
> - 9/10 = HIP_ROLL (Darwin says 13/14)
> - 11/12 = HIP_PITCH (Darwin says 15/16)
> - 13/14 = KNEE (Darwin says 17/18)
> - 15/16 = ANKLE_PITCH (**missing from Darwin doc**)
> - 17/18 = ANKLE_ROLL (**missing from Darwin doc**)
> - 19/20 = HEAD_PAN/TILT (Darwin agrees)
>
> The Darwin doc also says "7–10은 사용 안 함 (구버전 ID 흔적)" — this is **factually incorrect** for OP2 factory firmware where 7–10 are hip yaw/roll. **Action: update `docs/architecture/joint-conventions.md` to match the canonical JointData.h enum before any motion code consumes it.**

### Cross-check against `docs/protocols/dynamixel-1.0.md`

The protocol doc is accurate:

- Default 1 Mbps, 8-N-1 — confirmed.
- `BULK_READ (0x92)` and `SYNC_WRITE (0x83)` — confirmed.
- Error bit assignments — confirmed (matches `CM730.h:79–87`).
- MX-28 control-table subset — confirmed.

> **Discrepancy (minor):** The protocol doc says "The Walking / Motion loop uses BULK_READ every cycle to read all 20 joint positions + IMU + FSR." The factory firmware actually **only** reads CM-730 RAM (24..53) + FSR (26..35 × 2). Per-joint position reads are commented out (CM730.cpp:407–415) in the production build, present only in the Webots simulator path. Update `docs/protocols/dynamixel-1.0.md` to reflect this.

### Cross-check against `docs/protocols/cm-730-740.md`

Mostly accurate. Specific spot-checks:

- `Return Delay Time` "기본 0" — confirmed (reset to 0 by `Reset()` in firmware_installer).
- "Baud 1 = 1 Mbps, 7 = 576 kbps" — the formula in `LinuxCM730::SetBaud` is `baudrate = 2_000_000 / (baud + 1)`, so baud=1 → 1 Mbps, baud=7 → 250 kbps (not 576 kbps). The 576 kbps fallback claim in the doc appears to be folklore — **verify against ROBOTIS e-manual and correct if wrong**.
- "Model Number OP1: 730, OP2: 740 (확인 필요)" — this snapshot does not write the model number anywhere; reading it from a live robot is the way to confirm.

### Cross-check against `docs/architecture/sensor-stack.md`

Accurate. Sensor-stack doc's IMU register map (38–43 gyro, 44–49 accel, 50 voltage) matches `CM730.h:105–117` exactly. Mic addresses (51–52 / 67–68) also match. Note: the Darwin doc labels gyro as `Y, Z, X (38–43)` but the framework header orders them `Z (38–39), Y (40–41), X (42–43)` — same registers, just different label ordering. The protocol doc has the same order.

### Missing / unused control-table addresses in Darwin docs

Addresses currently undocumented or under-documented:

- `CM730.h:23–24` — `BulkReadData` class. Worth noting in Darwin protocol doc that `BULK_READ` responses are buffered per-ID and queryable via `ReadByte(addr)` / `ReadWord(addr)`.
- `MX28.h:147–164` — the **second half of the MX-28 RAM** (`P_POT_L..P_D_ERROR_OUT_H`, addresses 52–67) is firmware-specific diagnostic state. Useful for live debugging but absent from the protocol doc.
- `FSR.h:13–44` — the FSR-board control table. Not yet in any Darwin doc. Especially relevant fields: `P_FSR1_L..P_FSR4_H` (26–33) for 4 cells × 2 bytes per foot, plus `P_FSR_X / P_FSR_Y` (34–35) for the on-board center-of-pressure estimate.

### Implementation guidance for `DynamixelKit` Swift port

- **Baud-rate trick is Linux-specific.** macOS uses `IOSSIOSPEED` ioctl (FTDI VCP driver) to set non-standard 1 000 000 bps. `ORSSerialPort` exposes this; the FTDI VCP virtual COM driver must be installed.
- **`Reset()` defaults are essential** — when verifying a "new" robot, read the per-joint EEPROM against the table above; if values differ, the robot has been retuned and `m_Offset` calibration is suspect.
- **Status-return level 2** means every WRITE/SYNC_WRITE expects a response packet for each non-broadcast ID. The framework's `CM730::SyncWrite` issues a broadcast (ID 254) and gets no reply (matches Protocol 1.0). Single-target writes do return.
- **PID is RAM-only**. The factory only sets gains via SYNC_WRITE — no startup write-to-EEPROM. A power-cycle resets servo P/I/D to MX-28 firmware defaults (each MX-28T's own EEPROM, not the framework's `P_GAIN_DEFAULT = 32`).
- **Per-joint torque enable is not handled in MotionManager.** Higher layers (Action, Walking::Start) must explicitly `WriteByte(id, P_TORQUE_ENABLE, 1, ...)` before any joint moves, or the SYNC_WRITE's goal position is recorded but the motor stays limp.

## Evidence

Absolute paths cited in this document:

1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/JointData.h` — joint ID enum, default P/I/D, slope constants.
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/CM730.h` — sub-controller control table, ID_CM = 200, packet-buffer sizes, instruction codes.
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MX28.h` — MX-28 control table, conditional 1024 vs 4096 branches.
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/FSR.h` — FSR board IDs (111/112), FSR control-table addresses.
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MotionManager.h` — `OFFSET_SECTION = "Offset"`, `INVALID_VALUE = -1024.0`, per-joint `m_Offset[]`.
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/CM730.cpp` — instruction-code defines, `BULK_READ` packet builder, `DXLPowerOn` LED handshake, disconnect packet.
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/MX28.cpp` — MIN/CENTER/MAX position constants, RATIO_VALUE2ANGLE, PARAM_BYTES.
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/MotionManager.cpp` — INI offset load/save, SYNC_WRITE payload composition with `m_Offset[]` summation.
9. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/modules/Walking.cpp` — factory per-arm P-gain overrides (P=8 for shoulder/elbow), slope EXTRASOFT defaults.
10. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/LinuxCM730.cpp` — 1 Mbps baudrate, FTDI custom-divisor handling, `SetBaud()` formula.
11. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/firmware_installer/main.cpp` — per-joint EEPROM reset table (CW/CCW limits, temp 80°C, voltage 6.0–14.0 V, alarm 0x24), default firmware filenames.
12. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/firmware_installer/cm740_0x14.hex` — CM-740 firmware version 0x14 (20), 65 044 bytes.
13. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/firmware_installer/mx28_0x1E+FSR_0x11.hex` — MX-28 firmware version 0x1E (30) + FSR 0x11 (17), 168 089 bytes.
14. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/firmware_installer/mx28_0x1A_1024.hex` — legacy MX-28 1024-resolution firmware version 0x1A (26).
15. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/dxl_monitor/main.cpp` — `id`/`on all`/`off all`/`reset` commands; firmware-version sanity check.
16. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/offset_tuner/main.cpp` — `MOTION_FILE_PATH`, `INI_FILE_PATH = "../../../Data/config.ini"`, P/I/D-gain hotkeys.
17. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/offset_tuner/cmd_process.cpp` — `InitPose[21]` factory zero, offset adjustment hotkeys, `SaveCmd` persistence via `SaveINISettings`.
18. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/config.ini` — sample `config.ini` showing `[Camera] [Find Color] [Head Pan/Tilt] [Walking Config]` sections; **note: no `[Offset]` section in this sample, confirming offsets are robot-specific and absent from factory bundles**.
19. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/protocols/cm-730-740.md` — Darwin cross-reference (mostly aligned, minor inconsistency on baud-rate mapping noted).
20. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/protocols/dynamixel-1.0.md` — Darwin cross-reference (BULK_READ scope claim needs correction).
21. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/architecture/joint-conventions.md` — Darwin cross-reference (**joint IDs 7–18 are wrong; needs correction**).
22. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/architecture/sensor-stack.md` — Darwin cross-reference (aligned).
