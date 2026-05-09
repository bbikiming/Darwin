# Architecture

DarwinForge is a macOS-only management and design application for the
two ROBOTIS DARwIn-OP units the user owns (1st generation OP and 2nd
generation OP2). Architectural decisions are recorded as ADRs in this
directory.

## Reading order

1. [ADR-0001: macOS-only, native Swift / SwiftUI](adr-0001-mac-only-swift.md)
2. [ADR-0002: Swift Package layout — five domain modules](adr-0002-package-layout.md)
3. [ADR-0003: Protocol 1.0 only (OP3 explicitly out of scope)](adr-0003-protocol-1-only.md)
4. [ADR-0004: SwiftData for persistence; WireViz YAML for harness interchange](adr-0004-persistence-and-interchange.md)
5. [ADR-0005: Two-layer hardware integration (USB direct + on-robot SSH sync)](adr-0005-two-layer-integration.md)

## High-level diagram

```
+--------------------------------------- DarwinForge.app ---------------------------------------+
|                                                                                               |
|  +--------------------+  +--------------------+  +--------------------+                       |
|  |  DarwinForgeUI     |  |  MotionStudio      |  |  HarnessAtlas      |   (SwiftUI scenes)    |
|  |  - Robot dashboard |  |  - Action editor   |  |  - Wire diagrams   |                       |
|  |  - Live telemetry  |  |  - Walk tuner      |  |  - Maintenance log |                       |
|  |  - 3D pose         |  |  - Offset tuner    |  |  - WireViz import  |                       |
|  +---------+----------+  +----------+---------+  +----------+---------+                       |
|            |                        |                       |                                 |
|  +---------v------------------------v-----------------------v---------+                       |
|  |                            RobotKit (domain)                       |                       |
|  |   Robot · Joint · Telemetry · MotionPage · Walk · Calibration      |                       |
|  +---------+------------------------+-------------------------+-------+                       |
|            |                        |                         |                               |
|  +---------v---------+  +-----------v---------+  +------------v--------+  +----------------+  |
|  |  DynamixelKit     |  |  HarnessKit         |  |  OnboardSyncKit     |  |  PersistenceKit|  |
|  |  Protocol 1.0     |  |  Cable / harness    |  |  SSH / SFTP to      |  |  SwiftData     |  |
|  |  Packet I/O       |  |  data model + diag  |  |  /darwin/Data/*.ini |  |  + migrations  |  |
|  +---------+---------+  +---------+-----------+  +----------+----------+  +----------------+  |
|            |                      |                         |                                 |
|  +---------v---------+            |              +----------v----------+                      |
|  |  SerialPortKit    |            |              |  RemoteShellKit     |                      |
|  |  IOKit / ORSSerial|            |              |  NIO SSH client     |                      |
|  +-------------------+            |              +---------------------+                      |
|                                   |                                                           |
|                          +--------v--------+                                                  |
|                          |   WireVizBridge  |                                                 |
|                          |   YAML I/O       |                                                 |
|                          +-----------------+                                                  |
|                                                                                               |
+-----------------------------------------------------------------------------------------------+
                                              |
              +-------------------------------+-------------------------------+
              |                                                               |
       USB serial (1 Mbps)                                            SSH (port 22)
              |                                                               |
   +----------v----------+                                       +------------v-------------+
   |  CM-730 / CM-740    |                                       |  Embedded PC (Atom Linux)|
   |  Sub-controller     |                                       |  /darwin/Data/*.ini      |
   |  (ID 200)           |                                       |  /darwin/Data/*.bin      |
   +----------+----------+                                       +--------------------------+
              |
              | Dynamixel TTL daisy chain (1 Mbps)
              |
   +----------v----------+
   |  20 × MX-28T servos |
   |  IDs 1..20          |
   |  + FSR 111/112      |
   +---------------------+
```
