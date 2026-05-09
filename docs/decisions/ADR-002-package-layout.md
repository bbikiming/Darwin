# ADR-0002: Swift Package layout — domain modules

- **Status:** Accepted
- **Date:** 2026-05-09

## Context

DarwinForge has several distinct concerns:

- Speaking the Dynamixel wire protocol over a serial port
- Modelling a robot, its joints, its telemetry
- Modelling and editing harnesses (the user's harness-engineering view)
- Editing motions (action pages, walk gait)
- Talking to the on-robot Linux PC over SSH
- Persisting all of the above

Mixing them in one giant target makes testing painful and cross-talk
between the protocol and the UI inevitable.

## Decision

The Swift Package is split into the following targets, each in
`DarwinForge/Sources/<Module>`:

| Target             | Layer | Responsibility |
|--------------------|-------|----------------|
| `SerialPortKit`    | infra | macOS serial-port wrapper around IOKit / ORSSerialPort. Pure I/O, no protocol. |
| `DynamixelKit`     | infra | Protocol 1.0 packet codec + transport-agnostic bus protocol. Depends on `SerialPortKit` only at the production wiring. |
| `RemoteShellKit`   | infra | NIO-based SSH/SFTP client wrapper. |
| `RobotKit`         | domain | `Robot`, `Joint`, `Telemetry`, `MotionPage`, `WalkGait`, `Calibration`. No I/O. Depends on nothing infra. |
| `HarnessKit`       | domain | `Harness`, `HarnessSegment`, `Conductor`, `Connector`, `Endpoint`, `PinAssignment`, `MaintenanceLog`, `TestRecord`, `PartCatalog`. WireViz YAML round-trip. |
| `OnboardSyncKit`   | application | Orchestrates `RemoteShellKit` for `/darwin/Data/*.ini` and `*.bin` round-trip. Talks to `RobotKit`. |
| `PersistenceKit`   | application | SwiftData store, schema versioning, export/import. |
| `WireVizBridge`    | application | Subprocess to a vendored `wireviz` Python (or pure-Swift port) for diagram render. |
| `DarwinForgeUI`    | UI | SwiftUI scenes, view models, design system. |
| `DarwinForgeApp`   | UI | App target — the executable. |
| `DarwinForgeCLI`   | UI | Optional headless executable. |

Tests live at `DarwinForge/Tests/<Module>Tests`.

### Dependency rules

- `DarwinForgeApp` ⇒ `DarwinForgeUI` ⇒ `*Kit*`
- `*Kit*` may depend on each other only as listed above.
- **Domain (`RobotKit`, `HarnessKit`) must not depend on infra** (no `import IOKit`, no `import NIO`). This keeps the domain testable without a robot in the room.

## Consequences

- Clean unit-test surface: codec tests against synthetic byte arrays, robot
  tests against in-memory fixtures, UI snapshot tests against a `LoopbackBus`.
- Minor bookkeeping cost: more `Package.swift` targets to declare.
- The CLI target gets the same domain modules for free.
