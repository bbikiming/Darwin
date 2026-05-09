# DarwinForge

> A macOS-only management & design application for two ROBOTIS DARwIn-OP
> humanoids — one 1st-generation **OP** (CM-730 sub-controller) and one
> 2nd-generation **OP2** (CM-740). Talks Dynamixel Protocol 1.0 over USB,
> tracks the cable harness on each robot, edits motions, and syncs the
> on-robot Linux config.

> **Status:** project bootstrap. Research dossier and architecture docs
> are landed; Swift package skeleton is the next milestone.

## Why this exists

The user owns both DARwIn-OP generations. ROBOTIS' own tooling
(RoboPlus, the bundled Linux demos, ROS-1-era packages) is
Windows-or-Linux, mostly archived, and predates Apple Silicon. Day-to-day
robot care — torque-on/off, joint zeroing, motion authoring, harness
inspection, maintenance log — needs a **first-class native Mac app**.

DarwinForge is that app.

## Scope

**In scope:**

- Both DARwIn-OP **1st gen** and **2nd gen** units
- Direct **USB Dynamixel Protocol 1.0** control via the CM-730 / CM-740
- **On-board Linux** sync over SSH (`/darwin/Data/config.ini`, `walking.ini`, `motion_4096.bin`, color LUTs)
- **Cable-harness data model + WireViz-rendered diagrams** (the user's harness-engineering view)
- **Motion authoring** (action pages, walk-tuner gait params, offset tuner)
- **Maintenance log** with reliability trending across the two robots

**Out of scope** (today):

- ROBOTIS OP3 — different model, Protocol 2.0, separate code path. See [ADR-0003](docs/architecture/adr-0003-protocol-1-only.md).
- Linux/Windows port. See [ADR-0001](docs/architecture/adr-0001-mac-only-swift.md).
- Cloud sync of robot data.

## Documentation

- [`docs/research/upstream-survey.md`](docs/research/upstream-survey.md) — inventory of upstream ROBOTIS repos, framework architecture, ROS support, reference materials
- [`docs/research/harness-engineering.md`](docs/research/harness-engineering.md) — IPC/WHMA-A-620F foundations, conductor and connector selection, EMI mitigation, DARwIn-specific bus topology
- [`docs/hardware/op1-vs-op2.md`](docs/hardware/op1-vs-op2.md) — generation-by-generation comparison, servo IDs, control-table addresses
- [`docs/protocol/dynamixel-1.0.md`](docs/protocol/dynamixel-1.0.md) — Protocol 1.0 wire format, instruction codes, error byte, CM-730 / CM-740 register map
- [`docs/harness/data-model.md`](docs/harness/data-model.md) — entity definitions for `HarnessKit`, query patterns, labelling convention
- [`docs/architecture/`](docs/architecture/) — the ADRs: macOS-only, package layout, Protocol 1.0 only, persistence & interchange, two-layer integration

## Repository layout

```
.
├── DarwinForge/             Swift Package — domain modules, app target, CLI target
│   ├── Package.swift
│   ├── Sources/
│   │   ├── SerialPortKit/
│   │   ├── DynamixelKit/
│   │   ├── RemoteShellKit/
│   │   ├── RobotKit/
│   │   ├── HarnessKit/
│   │   ├── OnboardSyncKit/
│   │   ├── PersistenceKit/
│   │   ├── WireVizBridge/
│   │   ├── DarwinForgeUI/
│   │   ├── DarwinForgeApp/
│   │   └── DarwinForgeCLI/
│   ├── Tests/
│   └── Resources/
├── docs/
│   ├── architecture/        ADRs and system diagrams
│   ├── hardware/            OP1 vs OP2, mechanical references
│   ├── harness/             Harness data model + per-robot YAMLs
│   ├── protocol/            Dynamixel Protocol 1.0 reference
│   └── research/            Source-cited research dossiers
├── reference/               Vendored upstream PDFs and headers (CM-730.h, etc.)
├── scripts/                 Utility scripts (WireViz import/export, firmware backup)
├── fixtures/                Test fixtures (synthetic Dynamixel byte arrays, sample YAML harnesses)
├── CONTRIBUTING.md
├── LICENSE                  Apache 2.0 (matching upstream ROBOTIS framework)
└── README.md                this file
```

## Two robots, one app

DarwinForge keeps both robots in a single SwiftData store, distinguished
by `Robot.generation`:

```swift
enum RobotGeneration { case op, op2 }
```

The wire protocol is identical between them, so `DynamixelKit` is
generation-agnostic. UI affordances and diagnostics that depend on the
sub-controller PCB or the embedded PC's storage type branch on
`generation`. See [`docs/hardware/op1-vs-op2.md`](docs/hardware/op1-vs-op2.md)
for the full delta list.

## Hardware safety

The `CONTRIBUTING.md` checklist applies whenever you connect to a real
robot:

1. Cradle the robot in the maintenance stand before issuing torque-on commands.
2. Disable both legs (`disableTorque(.leftLeg, .rightLeg)`) before any motion authoring.
3. Keep the LiPo emergency disconnect within reach.
4. **Never cross-flash** CM-730 firmware to a CM-740 or vice versa.

## Building (planned)

> The Swift package skeleton has not yet landed. When it does:
>
> ```sh
> swift build --package-path DarwinForge
> swift test  --package-path DarwinForge
> open DarwinForge/DarwinForge.xcodeproj
> ```
>
> Required: macOS 14 (Sonoma) or later, Xcode 15.4 or later.

## License

Apache 2.0 — see [`LICENSE`](LICENSE). The upstream ROBOTIS framework is
also Apache 2.0; the Interbotix HR-OS5 fork is GPL v3 and is read-only
reference for DarwinForge.
