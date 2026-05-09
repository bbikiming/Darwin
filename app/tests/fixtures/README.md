# fixtures/

Test fixtures consumed by the Swift package:

- `dynamixel/` — pre-recorded byte arrays of valid Instruction and Status
  packets, captured from the real CM-730 / CM-740 with `dxl_monitor`.
  Used by `DynamixelKitTests` to verify codec round-trips against
  ground truth.
- `harness/` — golden-master WireViz YAML harnesses paired with their
  rendered SVGs, for snapshot-testing the import/export bridge.
- `onboard/` — sample `config.ini`, `walking.ini`, and a few small
  `*.bin` action pages stripped of any robot-specific calibration, for
  testing `OnboardSyncKit` parsers.
