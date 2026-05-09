# ADR-0003: Protocol 1.0 only (OP3 out of scope)

- **Status:** Accepted
- **Date:** 2026-05-09

## Context

ROBOTIS' active humanoid line is OP3 (and the newer Physical AI series).
OP3 uses XM-430 servos and **Dynamixel Protocol 2.0**, which is a
different packet shape (header `0xFF 0xFF 0xFD 0x00`, CRC instead of
checksum, 2-byte length, instruction set superset). The user's two
robots are OP and OP2 — both Protocol 1.0.

Risk: leaving Protocol 2.0 plumbing in `DynamixelKit` "just in case"
adds branches throughout the codec, and tempts a future maintainer to
half-implement OP3 support and break Protocol 1.0 invariants.

## Decision

`DynamixelKit` is **Protocol 1.0 only**. All packets carry a 1-byte
checksum, 1-byte length, and the instruction set documented in
`docs/protocol/dynamixel-1.0.md`. There is no `Protocol` enum and no
abstraction "for both versions."

If the user later acquires an OP3, support lands as a **separate**
package target, `DynamixelKitV2`, with its own codec. The two SDKs may
share `SerialPortKit` and a thin `BusEnvelope` protocol but no codec
code.

## Consequences

- **Positive:** smaller surface, smaller test matrix, fewer footguns
  (e.g., a stale Protocol 2.0 packet will not silently pass a
  Protocol 1.0 checksum check).
- **Negative:** if OP3 support is ever needed, a new module is built
  from scratch instead of "flipping a switch."

## Mitigations

- The packet types are not exposed publicly — `DynamixelKit.Packet` and
  `Instruction` are `internal`. Callers use higher-level functions
  (`bus.ping(id:)`, `bus.read(id:address:length:)`). This means a
  hypothetical future v2 bus exposes the same higher-level API and the
  callers don't change.
