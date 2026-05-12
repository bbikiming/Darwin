# ADR-0001: macOS-only, native Swift / SwiftUI

- **Status:** Accepted
- **Date:** 2026-05-09

## Context

The user has explicitly scoped the application to **Mac only** ("맥 전용
프로그램"). They run a Mac as their primary workstation. Both robots
(DARwIn-OP 1st and 2nd gen) connect via USB serial, which the Mac
exposes as `/dev/cu.usbserial-*` device nodes.

Cross-platform options considered:

| Option              | Pros | Cons |
|---------------------|------|------|
| **Swift + SwiftUI** | Native USB / IOKit access, Apple-Silicon performance, modern declarative UI, SwiftData built in, no runtime overhead | Locked to Apple platforms — but that matches the requirement |
| Electron + Node     | Cross-platform, large ecosystem | Heavy runtime, awkward serial-port story (`serialport` npm package), no native menu bar / scenes |
| Tauri + Rust        | Lighter than Electron | More complex toolchain, no advantage over Swift for a Mac-only build |
| Python + PyQt6      | Quick to prototype | Distribution painful (py2app), GIL-bound serial I/O, look-and-feel non-native |
| Webots add-on (C++) | Reuses existing simulation | Tied to Webots; not a standalone management tool |

## Decision

DarwinForge is **native macOS, Swift 5.10+, SwiftUI** for the application
shell, with **SwiftData** for persistence. Minimum macOS deployment
target is **macOS 14 (Sonoma)** to take advantage of mature SwiftData
and `@Observable`.

Build system: **Swift Package Manager** as the single source of truth;
an Xcode project is generated/maintained as a thin wrapper.

## Consequences

- **Positive:** native USB serial via IOKit, native menu bar, native 3D
  with RealityKit/SceneKit, `async/await` for the realtime control loop,
  signed/notarized distribution, low binary footprint.
- **Negative:** locks the project to Apple platforms. Acceptable: the
  user's other robots and other tools are all Mac-first; second-machine
  Linux access is via SSH and does not need a native UI.
- **Risk:** SwiftData migrations are still maturing — mitigated by the
  small schema scope and by export-to-WireViz-YAML as a vendor-neutral
  backup.

## Open questions

- Whether to ship a separate `DarwinForgeCLI` target for headless
  scripting (firmware backup, batch tests). Probably yes; tracked as a
  follow-up.
