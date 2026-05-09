# Contributing

This project is a personal workshop for managing two ROBOTIS DARwIn-OP units (1st and 2nd generation). Contribution overhead is intentionally low.

## Branching

- `main` — stable, releasable
- `claude/<topic>` — work generated through Claude Code on the web
- `feature/<topic>` — local feature branches
- `fix/<topic>` — bugfixes

## Commit messages

Conventional Commits style:

```
<type>(<scope>): <subject>

<body>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`, `ci`.

Scopes used in this repo: `dynamixel`, `harness`, `motion`, `vision`, `ui`, `persistence`, `cli`, `docs`.

## Development environment

- macOS 14 (Sonoma) or later
- Xcode 15.4 or later
- Swift 5.10+
- USB-to-serial drivers for FTDI / Prolific (needed to talk to CM-730/CM-740)

## Running tests

```sh
swift test --package-path DarwinForge
```

UI snapshot tests require a Mac with a display. The CI on Claude Code on the web runs only the headless unit tests.

## Hardware safety when testing on a real robot

1. Always cradle the robot in the maintenance stand before issuing torque-on commands.
2. Disable both legs (`disableTorque(.leftLeg, .rightLeg)`) before any motion authoring.
3. Keep an emergency battery disconnect within reach.
4. The 2nd-gen unit's CM-740 firmware is not pin-compatible with 1st-gen CM-730 — never cross-flash.
