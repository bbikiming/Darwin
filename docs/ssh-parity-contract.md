# SSH Onboard ↔ LAN Parity — Shared Interface Contract

Status: BINDING for 6 parallel workstreams (W1–W6). If you need to change a pinned
value, stop and renegotiate — do not diverge.

Goal: the SSH "onboard" path (robot `demo-pilot` owns `/dev/ttyUSB0`, runs
`Robotis::WalkLabBrokerage().Run()`) must give the Mac everything the wired-LAN
(5530 socat bridge → Mac `Bus`) path gives: working e-stop, robot→Mac telemetry
(IMU/voltage/temp → HUD + Mac safety gates), head control, mode persistence, and
UI honesty about which path/engine is live.

Ground truth verified in-tree:
- Robot framework namespace is `Robot` (Walking/Head/MotionStatus/MotionManager).
  Our brokerage class is `Robotis::WalkLabBrokerage` (firmware-patches/walklab-brokerage).
- `Robot::MotionStatus` (static, public, updated every 8ms by `MotionManager::Process()`
  with ZERO extra bus traffic): `FB_GYRO`, `RL_GYRO`, `FB_ACCEL`, `RL_ACCEL`, `BUTTON`,
  `FALLEN` — all `int`. FB_GYRO/RL_GYRO are already center-subtracted; FB_ACCEL/RL_ACCEL
  are raw ~512-centered ADC words. Only 2 gyro + 2 accel axes are exposed here.
- `Robot::CM730`: `m_BulkReadData[CM730::ID_CM]` is PUBLIC and already contains the full
  register block including `P_GYRO_X/Y/Z`, `P_ACCEL_X/Y/Z`, and `P_VOLTAGE` (reg 50).
  But `MotionManager::m_CM730` is PRIVATE → brokerage cannot fetch the pointer through
  MotionManager. Resolution: see §A.1 (main.cpp injection passes `&cm730` into `Run()`).
- `Robot::Head::GetInstance()->MoveByAngle(double pan, double tilt)` (absolute degrees),
  `GetPanAngle()/GetTiltAngle()`. Pan + : robot's right. Tilt + : up.
- g++ on robot is C++03 (no constexpr/C++11). Static const non-int members defined in .cpp.
- Mac types (ForgeCore/Bus.swift): `ImuRaw` stores 10-bit ADC as `UInt16` (gyroX/Y/Z,
  accelX/Y/Z) with center 512, plus `rollDeg`/`pitchDeg`. `BoardSnapshot.voltageRaw` is
  `UInt8` deci-volts (voltageVolts = raw/10). `TelemetrySnapshot(timestamp,board,joints,imu)`.
- `ConnectionStore.lastTelemetry: TelemetrySnapshot?` (@Published) and
  `lastImuRaw: ImuRaw?` (delegates to `health.lastImuRaw`). `health.recordImuSuccess(raw:at:)`
  is the existing setter for `lastImuRaw`.
- Safety gates that consume telemetry: L0 voltage (`board.voltageVolts`), L3 tilt
  (`imu` roll/pitch + gyro), L4 thermal (`joints` temperature → `avgTemperature`).

---

## A. Telemetry file `/tmp/df-walklab-telemetry`

### A.1 Producer (robot, W1)
`WalkLabBrokerage::Run()` writes one line every poll while it owns the bus. Use the
existing 200ms poll loop; gate telemetry writes to ~5Hz (every poll is fine — 200ms = 5Hz).
Write atomically: write `/tmp/df-walklab-telemetry.tmp` then `rename()` to final path
(same pattern as ACK file). Path constant: `TELEMETRY_PATH = "/tmp/df-walklab-telemetry"`.

`Run()` signature changes to accept the board pointer so voltage + 3-axis IMU are free
(read from the bulk-read buffer the motion loop already refreshes):

```cpp
// WalkLabBrokerage.h
void Run(Robot::CM730* cm730);   // cm730 may be NULL → degrade gracefully (see below)
```

main.cpp injection (RobotSetupCommand.demoInjectBlock, owned by W3 but the ONE call-site
edit is pinned here) changes its single line to:
```cpp
Robotis::WalkLabBrokerage().Run(&cm730);   // was: .Run();
```
`cm730` is in scope at the injection point (the SOCCER branch already uses
`cm730.WriteByte(...)`). W3 makes exactly this one-token edit; W1 owns the signature.

Field sources (NO extra bus reads — all already in memory):
| token        | source                                                              | units                     |
|--------------|---------------------------------------------------------------------|---------------------------|
| gyroX        | `cm730->m_BulkReadData[CM730::ID_CM].ReadWord(CM730::P_GYRO_X_L)`    | raw 10-bit ADC word (~512)|
| gyroY        | `...ReadWord(CM730::P_GYRO_Y_L)`                                     | raw 10-bit ADC word       |
| gyroZ        | `...ReadWord(CM730::P_GYRO_Z_L)`                                     | raw 10-bit ADC word       |
| accelX       | `...ReadWord(CM730::P_ACCEL_X_L)`                                    | raw 10-bit ADC word       |
| accelY       | `...ReadWord(CM730::P_ACCEL_Y_L)`                                    | raw 10-bit ADC word       |
| accelZ       | `...ReadWord(CM730::P_ACCEL_Z_L)`                                    | raw 10-bit ADC word       |
| voltage_dV   | `cm730->m_BulkReadData[CM730::ID_CM].ReadByte(CM730::P_VOLTAGE)`     | deci-volts (e.g. 122=12.2V)|
| walking01    | `walking_active ? 1 : 0` (the Run() loop's existing flag)           | 0/1                       |
| fallen       | `Robot::MotionStatus::FALLEN`                                        | -1 back / 0 up / 1 fwd    |
| ts_ms        | `clock_gettime(CLOCK_REALTIME)` → ms                                | unix ms                   |

If `cm730 == NULL` (defensive): substitute `Robot::MotionStatus::RL_GYRO` for gyroX,
`FB_GYRO` for gyroY, `gyroZ=0`, `RL_ACCEL` for accelX, `FB_ACCEL` for accelY,
`accelZ=512`, and `voltage_dV=0` (0 = "unknown", Mac must treat 0 as "no voltage datum",
NOT as 0.0V → must not trip L0). Prefer passing a real pointer; this is only a fallback.

NOTE on raw centering: `m_BulkReadData...ReadWord(P_GYRO_*)` returns the RAW ADC word
(NOT center-subtracted — that subtraction only happens when copied into `MotionStatus::FB_GYRO`).
Raw word is exactly what Mac `ImuRaw.gyroX:UInt16` expects (it subtracts 512 itself).
Clamp each raw word into `0..1023` before printing.

Temperature: the brokerage does NOT read joint temperatures (would add bus traffic and
fight the motion loop). `hottestTempC` is therefore NOT in the file. Mac L4 thermal gate
in onboard mode degrades to "unknown/offline" (see §D TelemetryMode + §F). Do not invent
a temperature field.

### A.2 Exact line format (PINNED)
Single line, space-separated, prefixed with literal `TEL`, newline-terminated:

```
TEL {ts_ms} {gyroX} {gyroY} {gyroZ} {accelX} {accelY} {accelZ} {voltage_dV} {walking01} {fallen}
    [{last_cmd_id} {loop_ms}]        ← O0 (2026-06-12): optional appended tokens
```
- **≥11 tokens** (`TEL` + 10 required values), **was "exactly 11"** before O0.
- `ts_ms`: integer (`long long`), unix epoch ms.
- `gyroX..accelZ`: integers 0..1023 (raw ADC).
- `voltage_dV`: integer deci-volts (0 = unknown).
- `walking01`: 0 or 1.
- `fallen`: -1, 0, or 1.
- **O0 appended (optional)**: `last_cmd_id` (string, last applied cmd_id; `no_id`/`-`→nil),
  `loop_ms` (int ≥0, supervisor loop duration). Closes the command-applied loop + loop_p95.
- printf (O0): `fprintf(fp, "TEL %lld %d %d %d %d %d %d %d %d %d %s %lld\n", ts_ms, gx,gy,gz, ax,ay,az, vdV, w, fallen, last_cmd_id, loop_ms);`

Example: `TEL 1748736000123 511 530 498 512 489 760 122 1 0` (legacy 11)
Example: `TEL 1748736000123 511 530 498 512 489 760 122 1 0 c123_ab12cd34 18` (O0)

### A.3 Consumer (Mac, W2 parse; W3 wire into store)
`OnboardTelemetry.parse` (see §D) splits on whitespace, requires `tokens[0]=="TEL"` and
**≥11 tokens** (O0: relaxed from "exactly 11"), parses the first 11 + optional `last_cmd_id`
/`loop_ms`, ignores any further tokens (forward-compat). Out-of-range or NaN → return nil
(drop the sample; do not crash, do not feed garbage to gates). **Ship the relaxation FIRST**
so the robot's token append cannot break an older Mac parser (would force telemetryMode
offline). Extra unknown tokens are ignored, never rejected.

---

## B. E-stop `/tmp/df-walklab-estop`

Semantics: **presence of the file = STOP**. The file is a flag, not a command queue.

- CREATOR (stop): Mac, via SSH, in `ConnectionStore.emergencyStop()` onboard branch (§D).
  Command (pinned): `touch /tmp/df-walklab-estop` AND, belt-and-suspenders, `killall -TERM demo demo-pilot`.
  Single SSH line W3 sends:
  ```
  touch /tmp/df-walklab-estop 2>/dev/null; sudo killall -TERM demo demo-pilot 2>/dev/null; echo ESTOP_OK
  ```
- REACTION (robot, W1): inside `Run()` poll loop, BEFORE parsing the command file, check
  `access("/tmp/df-walklab-estop", F_OK) == 0`. If present:
  `walking->Stop();` then disable torque on the walking body
  (`Robot::Walking::GetInstance()->m_Joint.SetEnableBody(false)` — match the enable call
  the framework used) and `walking_active = false`, then keep looping (do NOT exit — a
  re-arm must be possible). Also handle SIGTERM: install a `SIGTERM` handler that calls
  `walking->Stop()` then `_exit(0)` so the `killall -TERM` fallback also halts gait fast.
- REMOVER (re-arm): Mac, on explicit user "recover"/re-arm or on next onboard Start.
  Pinned: `rm -f /tmp/df-walklab-estop`. W3 adds this to the onboard start path
  (`walkLabRobotisStart` already runs at engine-enable; prepend an `rm -f` of the estop
  flag there — see §D persist note). The robot treats flag-absent as "may run".
- Path constant on robot: `ESTOP_PATH = "/tmp/df-walklab-estop"`.

Latency target: file check runs every poll (200ms). Worst-case stop = SSH round-trip
(~50–120ms over LAN) + one poll (≤200ms) ≈ ≤320ms. The `killall -TERM` is parallel
insurance. This is the single source of truth for "did the robot actually stop"; the
Mac's `bus.emergencyStop()` does nothing in onboard mode (no bus) — see §D.

---

## C. `WalkingEngineCommand.serializedLine` — head fields appended

PINNED: keep the existing 10 fields in exact order, APPEND 2 head fields → **12 fields**.
Backward compatible: old robot daemon's `sscanf(... 7 or 10 fields)` ignores trailing.

New struct fields (W4, in WalkingEngine.swift):
```swift
public let headPanDeg: Double    // -90...90, + = robot right.  default 0
public let headTiltDeg: Double   // -45...45, + = up.           default 0  (see note)
```
Add to `init` with defaults `headPanDeg: Double = 0, headTiltDeg: Double = 0`. Update
`WalkingEngineCommand.stop` to pass head 0,0. Clamp pan to [-90,90], tilt to [-45,45].

`serializedLine` (PINNED format string):
```swift
String(format: "%d %.2f %.2f %.2f %.0f %.0f %.2f %.2f %d %d %.2f %.2f",
       enabled ? 1 : 0, xMm, yMm, aDeg, periodMs, footHeightMm, hipPitchOffsetDeg,
       balanceGain, balanceEnable ? 1 : 0, correctorIntensityLevel,
       headPanDeg, headTiltDeg)
```
Token order (after the cmd_id prefix that `walkLabRobotisSendCommand` prepends):
```
{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable} {blevel} {headPan} {headTilt}
```

Robot sscanf (W1, in `ParseAndApply`) — extend the cmd_id-present attempt to 14 tokens
(cmd_id + 13), and the legacy no-id attempt to 12:
```cpp
float head_pan = 0.f, head_tilt = 0.f;          // NEW, default keep-last is too risky → default 0
float bgain = 1.f; int benable = 0, blevel = 2; // EXISTING balance fields (also currently parsed? see note)
int n = sscanf(line, "%31s %d %f %f %f %f %f %f %f %d %d %f %f",
               cmd_id, &enabled, &x,&y,&a,&period,&foot,&hip,
               &bgain,&benable,&blevel, &head_pan,&head_tilt);
// fallback: drop %31s cmd_id → 13 tokens
```
NOTE for W1: the current `.cpp` only parses through `hip` (8/7 tokens) and ignores
balance + head. Extending to parse balance(3)+head(2) is in W1 scope since W1 owns the
file; if balance application is out of scope this cycle, still CONSUME the tokens so head
lands in the right position. After parse, apply head every cycle:
`Robot::Head::GetInstance()->MoveByAngle(head_pan, head_tilt);` (Head module must be
enabled — the walklab injection already calls `Head::GetInstance()->m_Joint.SetEnableHeadOnly(true,true)`).
If both head values are 0 AND robot has never received a non-zero head command, you may
skip MoveByAngle to preserve the framework's default head pose; otherwise always apply.

**O2 (2026-06-12)**: this v1 line is now ONE of two dialects — see **§G.8** for the v2
twist line, the robot-owned governor/slew/gate-schedule pipeline that both dialects pass
through, and the balance-token wiring decision (`BALANCE_ENABLE` from `blevel`, not
`benable`). The v1 path here is unchanged and permanent.

---

## D. Swift interfaces (EXPOSES / CONSUMES)

### D.1 `OnboardTelemetry` — NEW (W2)
File: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/OnboardTelemetry.swift`
```swift
import Foundation
import ForgeCore   // for ImuRaw / BoardSnapshot mapping helpers if needed

public struct OnboardTelemetry: Equatable, Sendable {
    public let tsMs: Int64
    public let gyroX: UInt16   // raw 0..1023
    public let gyroY: UInt16
    public let gyroZ: UInt16
    public let accelX: UInt16
    public let accelY: UInt16
    public let accelZ: UInt16
    public let voltageDeciVolts: Int   // 0 = unknown
    public let walking: Bool
    public let fallen: Int             // -1 / 0 / 1

    public init(tsMs: Int64, gyroX: UInt16, gyroY: UInt16, gyroZ: UInt16,
                accelX: UInt16, accelY: UInt16, accelZ: UInt16,
                voltageDeciVolts: Int, walking: Bool, fallen: Int)

    /// Parse one `/tmp/df-walklab-telemetry` line. Returns nil on any malformed input.
    public static func parse(_ line: String) -> OnboardTelemetry?

    /// Convenience: voltage in volts, or nil if unknown (deci-volts == 0).
    public var voltageVolts: Double? { voltageDeciVolts > 0 ? Double(voltageDeciVolts)/10.0 : nil }

    /// Map raw ADC → ForgeCore.ImuRaw (rollDeg/pitchDeg = 0; HUD uses gyro/accel only here).
    public func toImuRaw() -> ImuRaw   // ImuRaw(gyroX:...accelZ:..., rollDeg: 0, pitchDeg: 0)

    /// Map to BoardSnapshot for the voltage gate. nil if voltage unknown.
    /// Use modelNumber 740, version 0, voltageRaw UInt8(clamping: voltageDeciVolts), button 0.
    public func toBoardSnapshot() -> BoardSnapshot?
}
```
Parsing rule: trim, split on whitespace (drop empties), require `[0]=="TEL"` && count==11.

### D.2 `OnboardTelemetryPoller` — NEW (W2)
File: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/OnboardTelemetryPoller.swift`
```swift
@MainActor
public final class OnboardTelemetryPoller: ObservableObject {
    @Published public private(set) var latest: OnboardTelemetry?
    @Published public private(set) var lastReceivedAt: Date?
    @Published public private(set) var consecutiveFailures: Int = 0

    public init(remoteShell: RemoteShell, intervalMs: Int = 500)

    /// Begins polling: every interval, SSH `cat /tmp/df-walklab-telemetry`, parse,
    /// publish `latest`/`lastReceivedAt`, invoke onSample. Idempotent (start twice = no-op).
    public func start(onSample: @escaping @MainActor (OnboardTelemetry) -> Void)
    public func stop()

    /// True when no fresh sample within staleThreshold (default 1.5s). Drives desaturation.
    public var isStale: Bool { /* lastReceivedAt older than 1.5s */ }
}
```
- The poller uses `RobotSetupCommand.walkLabReadTelemetry` (§D.4) as the SSH command.
- It runs ONLY while onboard engine + brokering active; W3 owns lifecycle (start on
  onboard-enable, stop on disable/disconnect/e-stop-disarm).
- Poll interval 500ms (2Hz Mac-side over a 5Hz producer is enough for HUD + gates and is
  cheap over SSH). Robot writes 5Hz; Mac samples whatever the latest line is.

### D.3 ConnectionStore consumption (W3)
W3 adds to `ConnectionStore`:
```swift
private var onboardPoller: OnboardTelemetryPoller?

/// Start/stop the onboard telemetry uplink. Called by the WalkLab onboard lifecycle
/// (engine == .robotisOnboard && brokering on → start; else stop).
public func startOnboardTelemetry(remoteShell: RemoteShell)
public func stopOnboardTelemetry()

/// Feed one onboard sample into the existing pipelines so HUD + L0/L3 gates work.
/// MUST: set telemetryMode = .onboard; update lastTelemetry (board from voltage if known,
/// imu from sample.toImuRaw()); call health.recordImuSuccess(raw: sample.toImuRaw()).
func ingestOnboardTelemetry(_ sample: OnboardTelemetry)
```
`ingestOnboardTelemetry` rules (PINNED so gates behave):
- `let imu = sample.toImuRaw()`; `health.recordImuSuccess(raw: imu)` (this also clears IMU
  stale/unavailable and sets `lastImuRaw`).
- `let board = sample.toBoardSnapshot()` (nil-safe); preserve existing `joints` (onboard
  has none → `[:]`):
  `lastTelemetry = TelemetrySnapshot(board: board ?? lastTelemetry?.board, joints: [:], imu: imu)`.
  Rationale: keep last-known board if this sample's voltage is unknown, so L0 doesn't flap.
- Set `telemetryMode` (§D.5) to `.onboard`.
- Do NOT touch `joints` temperature → L4 thermal must read `telemetryMode` and show
  "thermal offline" in onboard mode (W5 surfaces this).
- The poller's `isStale` (no sample 1.5s) → store maps to `telemetryMode = .onboardStale`.

### D.4 `RobotSetupCommand` new static helpers (W3)
File: `Connection/RobotSetupCommand.swift` (W3 owns; W1 owns only the robot .cpp/.h).
```swift
/// SSH e-stop: touch flag + SIGTERM demo. Returns shell line ending in `echo ESTOP_OK`.
public static let walkLabRobotisEstop: String =
    "touch /tmp/df-walklab-estop 2>/dev/null; sudo killall -TERM demo demo-pilot 2>/dev/null; echo ESTOP_OK"

/// SSH read telemetry: cat one line (or empty). Poller parses result.
public static let walkLabReadTelemetry: String =
    "cat /tmp/df-walklab-telemetry 2>/dev/null"

/// Clear e-stop flag for re-arm. Run before/with onboard start.
public static let walkLabClearEstop: String = "rm -f /tmp/df-walklab-estop 2>/dev/null; echo CLEARED"

/// Persist walklab mode so it survives reboot. Writes a marker the boot/connect path reads.
/// PINNED marker file: /tmp/df-pilot-mode-persist with content "walklab".
public static let walkLabPersistMode: String =
    "mkdir -p ~/.config/darwinforge 2>/dev/null; echo walklab > ~/.config/darwinforge/pilot-mode; echo PERSIST_OK"

/// Connect-time verification: report whether onboard brokerage is live + which mode.
/// Output contract (first line marker, Mac parses):
///   DF_WALKLAB=active   — demo/demo-pilot running AND /tmp/df-pilot-mode/walklab path live
///   DF_WALKLAB=idle     — not in walklab mode
///   DF_WALKLAB=missing  — demo binary not running
public static let walkLabVerifyMode: String = #"""
set +e
if pgrep -x demo-pilot >/dev/null 2>&1 || pgrep -x demo >/dev/null 2>&1; then
  if [ -e /tmp/df-walklab-cmd ] || grep -q walklab ~/.config/darwinforge/pilot-mode 2>/dev/null; then
    echo "DF_WALKLAB=active"
  else
    echo "DF_WALKLAB=idle"
  fi
else
  echo "DF_WALKLAB=missing"
fi
"""#
```
Note: `walkLabRobotisStart` already exists and creates `/tmp/df-walklab-cmd`. W3 prepends
`rm -f /tmp/df-walklab-estop` to that script (single edit, W3 owns the file) so a fresh
start always re-arms. W3 also appends `walkLabPersistMode` content to the start path.

### D.5 `TelemetryMode` — NEW (W5)
File: `Connection/TelemetryMode.swift`
```swift
public enum TelemetryMode: String, Sendable, Equatable {
    case lan          // 5530 bridge → Mac Bus polling (full: voltage+imu+joints+temp)
    case onboard      // SSH uplink live (voltage+imu; NO joints/temp)
    case onboardStale // onboard selected but no fresh sample within 1.5s
    case offline      // nothing live

    public var isLive: Bool { self == .lan || self == .onboard }
    public var hasThermal: Bool { self == .lan }
    public var label: String { ... }   // "LAN" / "온보드" / "온보드(지연)" / "오프라인"
}
```
Store exposes: `@Published public private(set) var telemetryMode: TelemetryMode = .offline`
(W3 declares it; W5 reads it in views). LAN telemetry loop sets `.lan` on success; onboard
ingest sets `.onboard`; onboard staleness sets `.onboardStale`; disconnect sets `.offline`.
Views (W5) read `store.telemetryMode` to drive: path/engine badge, staleness desaturation
(when `!isLive` or `.onboardStale` → desaturate HUD numbers), thermal pill (hide/“offline”
when `!hasThermal`), and the "SAFETY GATES online/offline" banner (online iff `isLive`).

### D.6 `ConnectionStore.emergencyStop()` onboard branch (W3)
Insert near the top of `emergencyStop()`, BEFORE the `guard let bus else { return }`:
```swift
// Onboard path: no Mac bus owns the motors — the robot does. Stop via SSH flag + SIGTERM.
if telemetryMode == .onboard || telemetryMode == .onboardStale {
    emergencyStopActive = true
    Task { @MainActor in _ = await remoteShellRef?.send(RobotSetupCommand.walkLabRobotisEstop) }
    stopOnboardTelemetry()
    harness.record(.busEStop, level: .error, actor: .user,
                   data: ["source": AnyCodable("emergencyStop.onboard")])
    // do not return early if a bus also exists — fall through to bus.emergencyStop() as well.
}
```
W3 must give the store a way to reach `RemoteShell` (`remoteShellRef`, set at wiring time)
since onboard e-stop is SSH-side. The existing WalkLabSession delegation guard stays first.

### D.7 WalkingEngine head feed (W4 struct; consumer wiring)
`WalkLabSession.currentWalkingEngineCommand(enabled:)` (W4 edits this one method) must add
the two head args. Source of head angles: the cockpit head joystick already integrates into
`CockpitState.headPanDeg` / `.headTiltDeg` (degrees, pan ±90 + = right, tilt ±45 + = up).
PINNED data flow: cockpit publishes head degrees onto the session via existing/!new setter
`session.onboardHeadPanDeg` / `session.onboardHeadTiltDeg` (W4 adds these two stored props,
default 0); `currentWalkingEngineCommand` reads them:
```swift
headPanDeg: onboardHeadPanDeg,
headTiltDeg: onboardHeadTiltDeg
```
W5 (cockpit) sets `session.onboardHeadPanDeg = cockpitState.headPanDeg` (and tilt) inside
the cockpit's existing head-update tick (the same place that today does `.with(.headPan, raw:)`).
This keeps W4's struct/serialize change disjoint from W5's view wiring; the two stored
props on the session are the contract seam (W4 declares them).

---

## E. FILE OWNERSHIP MAP (disjoint)

| WS | Theme | Files (OWNS = may edit) |
|----|-------|--------------------------|
| W1 | robot brokerage | `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp`, `WalkLabBrokerage.h` |
| W2 | telemetry ingest | NEW `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/OnboardTelemetry.swift`, NEW `.../WalkLab/OnboardTelemetryPoller.swift`, NEW `app/ui/DarwinForge/Tests/DarwinForgeUITests/OnboardTelemetryTests.swift` |
| W3 | estop + remotecmd + store | `app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift`, `Connection/RobotSetupCommand.swift` |
| W4 | command format | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkingEngine.swift`, `WalkLab/Components/WalkLabOnboardBridge.swift`, and the two head props in `WalkLab/WalkLabSession.swift` ONLY via the seam in §D.7 (see conflict note) |
| W5 | ui surfacing | NEW `Connection/TelemetryMode.swift`, `Connection/ConnectionDashboard.swift`, `Pilot/Cockpit/PilotCockpitView.swift`, `Pilot/Cockpit/CockpitWalkLogicPanel.swift` |
| W6 | wizard | `Connection/ConnectionWizard.swift` |

### Disjointness check + shared-edit assignments
- `WalkLabSession.swift` is touched by BOTH W4 (head props + `currentWalkingEngineCommand`)
  and is read by W5. **Assign the WalkLabSession edits entirely to W4.** W5 only READS
  `session.onboardHeadPanDeg/Tilt` are set by W5's cockpit view, but the property
  DECLARATION + the `currentWalkingEngineCommand` change belong to W4. W5 sets the values
  from the cockpit view (assignment statements only, no new symbols). To stay strictly
  disjoint at the source-file level, **W4 declares the two stored props and the cockpit
  update path is added by W5 inside PilotCockpitView/CockpitState which W5 owns** — W5 does
  not edit WalkLabSession.swift; it assigns to the W4-declared props from its own files.
- `ConnectionStore.swift`: telemetryMode declaration, onboard poller lifecycle, ingest,
  estop onboard branch, remoteShellRef — ALL W3. W5 only reads `store.telemetryMode`.
- `RobotSetupCommand.swift`: ALL new helpers + the one-token `Run(&cm730)` injection edit
  + the `rm -f estop` prepend to `walkLabRobotisStart` → W3. W1 does NOT edit this file;
  W1 only changes the C++ `Run` signature; W3 makes main.cpp injection pass `&cm730`.
- `WalkLabOnboardBridge.swift`: only W4 (it builds the serialized line; head fields flow
  through `currentWalkingEngineCommand` automatically, so W4 may not even need to edit it —
  but it's reserved to W4 to avoid contention).
- Tests: W2 owns the new `OnboardTelemetryTests.swift`. If W4 wants serialize tests, W4
  edits the EXISTING `WalkLab` engine tests file under its own theme (coordinate: W4 adds
  to whatever existing WalkingEngine test file already covers `serializedLine`; if none,
  W4 creates `WalkingEngineCommandHeadTests.swift` — distinct from W2's file).
- ConnectionWizard.swift (W6): adds a setting/toggle "연결 방식: SSH 온보드(기본) / LAN(5530)".
  Default SSH onboard; the LAN option calls the existing `store.connectNetwork()` path.
  W6 does not touch ConnectionStore beyond calling existing public methods.

No two workstreams write the same file. The only cross-WS seams are typed contracts:
`OnboardTelemetry` (W2→W3), `telemetryMode`/`startOnboardTelemetry`/`ingestOnboardTelemetry`
(W3→W5 read), head props (W4 decl → W5 assign), serialized 12-field line + robot sscanf
(W4↔W1), telemetry file format + estop flag (W1↔W2/W3).

---

## F. Integration invariants (every WS must hold)
1. Telemetry file is 11 tokens, `TEL`-prefixed, atomic write. (A.2)
2. serializedLine is 12 fields, head appended last, backward-compatible. (C)
3. Robot sscanf consumes through head; head applied via `Head::MoveByAngle`. (C)
4. E-stop = create `/tmp/df-walklab-estop` + SIGTERM; robot checks flag every poll; re-arm
   = `rm -f` on start. Latency ≤ ~320ms. (B)
5. Onboard voltage unknown (deci-volts 0) must NOT trip L0; keep last-known board. (A.1, D.3)
6. L4 thermal is offline in onboard mode (no joint temps) — UI says so, gate does not
   false-pass. (A.1, D.5)
7. UI never shows stale-green LAN data while onboard: `telemetryMode` drives badge +
   desaturation + SAFETY GATES banner. (D.5)
8. Default connection path is SSH onboard; LAN (5530) is an explicit wizard setting. (W6)
9. C++ stays C++03: new static const non-int members defined in `.cpp`; no constexpr/auto.

---

## G. O0/O1 event-driven transport (2026-06-12, P3)

Adds an **event-driven UDP transport** alongside the file-poll path. The file paths
(§A/§B/command file) are **permanent fallbacks** — UDP is additive, gated by a handshake.

### G.1 Channel handshake `/tmp/df-walklab-channel`
- Single line `"{token} {estop_port} {cmd_port}\n"`, atomic tmp+mv.
- CREATOR: Mac, **any time** (`RobotSetupCommand.walkLabWriteChannelHandshake`) — need not
  precede `Run()`. The robot re-checks every 1s (`RefreshHandshake`) and accepts within ≤1s.
- CONSUMER: robot `WalkLabBrokerage::RefreshHandshake` (1s throttle). Present + threads down →
  `LoadHandshake` + start UDP threads. **mtime change → restart** (token/port rotation; handles
  a stale token from a crashed prior session). File absent → stop threads (file poll only).
- `token`: 16 alphanumerics (shell-safe). Ports default to 17372/17374 if omitted.
- **Session end: Mac MUST call `walkLabClearChannelHandshake`** (`rm -f /tmp/df-walklab-channel`)
  so the robot tears down UDP transport and returns to file-poll (no stale listener with an old
  token). Absent handshake = legacy file-poll behavior fully preserved.

### G.2 E-STOP datagram (UDP `estop_port`, default 17372)
- Payload `DF-ESTOP v1 {token} {unixMillis}`. Mac fires **×3 burst (0/50/100ms)** in
  parallel with the SSH/file path (first to land wins).
- Robot listener: on prefix+token match → `Walking::Stop()` + body torque off (~1–5ms) +
  **touch the §B flag file** (so the existing latch/re-arm machinery owns hold-stopped state;
  Mac re-arms via `rm`). Wrong token → ignored (spoof damage = unnecessary stop = fail-safe).
- **No throttle/batch/extra hop on this path** (latency §7 invariant).

### G.3 Command datagram (UDP `cmd_port`, default 17374)
- Payload `DFCMD {token} {seq} {line}` where `line` is the §C command line (cmd_id + 13).
- Robot listener: token match → `CommandSlot.Offer(line, seq)` (latest-wins, **seq strictly
  monotonic** — reordered/old datagrams dropped) + best-effort UDP `ACK {seq} {t_rx}` reply.
- Supervisor applies the slot each loop (single writer — transport threads only touch the slot).

### G.4 Supervisor loop + watchdog tiers
- Loop period: **20ms while walking** (`SUPERVISOR_WALK_MS`, ≥20Hz effective), 100ms idle;
  ball-tracking keeps camera pace (no sleep). File poll relaxed to 250ms when UDP active.
- **Watchdog tiers** (`WalkLabTransport::WatchdogDecision`, ms since last applied command):
  `≥600` → amplitude slew to 0 (march in place, **torque held**); `≥2500` → `Walking::Stop()`
  (torque held). 5s `STALE_TIMEOUT_MS` remains as a backstop. Torque cut is E-STOP/FALLEN only.
- **Tiers are STREAM-SOURCE ONLY** (`from_stream` gate). A command applied from the **file**
  path does NOT arm the tiers — the Mac bridge dedups and Switch sends only on change, so a
  steady stick-hold legitimately stops refreshing the file; arming 600ms/2.5s there would cause
  a march/stop regression. File-source commands rely on the 5s STALE backstop only. UDP-slot
  (continuous 20–30Hz) commands arm the tiers so packet loss is caught fast.

### G.5 Persistent SSH channel (Mac → robot command path)
- `PersistentSSHChannel` runs one resident `ssh host 'exec sh -s'`; commands written to stdin
  as `… > cmd.tmp && mv …; printf '__DF_DONE_<id>_<exit>__\n' "$?"`. stdout sentinel
  correlates completion. 0 fork/exec per command. Falls back to `SSHShell.run` on failure.
- Coalescing: `SendPolicy.latestWins(key:)` for freeform tuning; `.ordered` for estop/mode
  switch (never coalesced). Feature flag `df.onboard.persistentChannel`.

### G.6 Pure logic location (host-testable)
- `firmware-patches/walklab-brokerage/WalkLabTransport.{h,cpp}` — `CommandSlot`,
  `WatchdogDecision`, `ParseCommandLine`(+clamps), `ParseEstopDatagram`, `ParseCmdDatagram`.
  No `Robot::` deps → host unit tests (`tests/`, plain Makefile, C++03). Brokerage links it.

### G.7 New ports (single source: `DFConnectionConstants` ↔ handshake file)
`estopUDPPort=17372`, `commandUDPPort=17374` (telemetry stays 17371). Do not hard-code
elsewhere — the handshake conveys them to the robot.

### G.8 Command semantics v2 — twist SI + robot-owned shaping (2026-06-12, O2)

Adds a **second command dialect** alongside v1 (§C). The robot accepts both forever
(`ParseCommandLine` branches on the `"V2 "` prefix); v1 14-token path is permanent.

**v2 line (REP-103 SI, all integers — float parsing excluded):**
```
V2 {seq} {t_tx_ms} {flags} {vx_mms} {vy_mms} {wz_mrad_s} {period_ms} {foot_mm} {hip_cdeg} {blevel} {pan_cdeg} {tilt_cdeg}
```
- `flags` bits (SINGLE DEFINITION, shared `WalkLabTransport.h FLAG_*` ↔ Swift
  `WalkingEngineCommand.V2Flag`): `0x01` ENABLED, `0x02` BALANCE_ENABLE, `0x04` BALLTRACK,
  `0x08` GATE_SCHED_OFF (default 0 = gate schedule ON). Booleans fold into `flags`.
- **Robot owns twist→amplitude conversion** (`X_MOVE = k_x·vx·T/2`, `Y = k_y·vy·T/2`,
  `A_deg = k_a·(wz/1000)·T/2·(180/π)`, `T = period_ms/1000`). `k_x/k_y/k_a = 1.0`
  initial — **TODO(bench-O0): calibrate from step-response settle distance.**
- `hip_cdeg`/`pan_cdeg`/`tilt_cdeg` = degrees ×100. `blevel` 0..3 (Mac 0..4 clamps).
- ACK `cmd_id` for v2 = `"v2#{seq}"`.
- Mac serializer `WalkingEngineCommand.serializedLineV2(seq:tTxMs:)` emits the inverse
  (`vx = 2·X/T`). **Switchover is gated**: keep emitting v1 until every deployed robot is
  O2-patched AND `k_x` is bench-fixed — emitting `"V2 …"` to an unpatched robot misparses.

**Robot-owned shaping pipeline (the single apply point `ApplyCommandLine`, v1+v2, every
client incl. Switch/handheld — robot owns the FINAL clamp):**
1. **Combined-envelope governor** (G6): `|x|/x_max + |y|/y_max + |a|/a_max ≤ 1.15`, else
   proportional scaledown. Period-dependent `x_max`: 700→40, 600→38, 500→32, 440→28mm
   (interpolated; clamped outside). `y_max=22`, `a_max=12`. Mac clamps (38/22/12) stay as
   a UX layer (double defense).
2. **Latch-unit slew** (G5): per half-period, `|ΔX|≤8`, `|ΔY|≤6`mm, `|ΔA|≤4°`,
   `|ΔPERIOD|≤60ms`. Re-seeded to 0 on idle→walk (first-step capturability) and on the
   watchdog `SLEW_ZERO` tier (ramp from 0 on recovery). **Advanced from BOTH the command
   apply path AND the supervisor loop** (`SlewCadenceDue`/`SlewAtTarget` pure helpers): a
   single command (file-path Mac-bridge dedup / exact keyboard value, no re-send) must still
   ramp to target over successive latches — the loop steps the slew toward `m_tgt_*` while
   `walking_active && !at-target && cadence-due`, sharing `WriteShapedCommand` so the gate
   boost re-applies. (Earlier draft advanced only on command arrival → single commands stuck
   at the first 8mm step; fixed.) Watchdog `SLEW_ZERO` zeroes both target+slew, so the loop
   advance is a natural no-op there.
3. **Speed-proportional gate schedule** (dynamics): when `|x|/x_max > 0.70`, linearly add
   `Z_MOVE +5mm`, `Y_SWAP +2mm`, `HIP_PITCH +1.5°` (full at `x_max`). `flags 0x08` = OFF.
   `Y_SWAP` base is the robot's `config.ini`-tuned `Y_SWAP_AMPLITUDE` **captured once at Run
   entry** (`m_yswap_base`), not the constant 20.0 — preserves per-robot tuning.
4. **Balance wiring** (G7): `blevel(0..3) → BALANCE_*_GAIN ×{0, 0.5, 1.0, 1.5}` off the
   shipped base gains (0.3/0.9/0.5/1.0). **`BALANCE_ENABLE` is driven by `blevel`, NOT the
   `benable` token** (`enable = scale>0`) — deployed Mac sends `benable=0` by default and
   wiring it literally would disable gyro balance on every default command (fall regression
   vs. the prior always-on Walking default). `blevel=0` is the explicit-off path; `bgain`
   and `benable` are **deprecated** (single-sourced on `blevel`, design "blevel 로 단일화").

**Constants single source**: all governor/slew/gate/twist-k constants live in
`WalkLabTransport.h` and are **shared with `bus-direct-teleop-upgrade.md` D1** (mode parity).

**Shaping moved off Mac**: Mac command EMA relaxed `α 0.25→0.5`
(`CockpitState.commandSmoothingAlpha`) — the robot slew now owns acceleration limiting, so
the prior Mac+robot double-smoothing serial overlap is removed. Sim-display smoothing
(chase position, head EMA) unchanged.

**Host tests** (`tests/test_transport.cpp`, 125 checks): v2 parse+conversion, envelope
table+scaledown, slew first-apply/delta-clamp, balance gain scale, gate schedule. Mac
serializer round-trip in `WalkLabO2TwistSerializerTests`.
