# Harness Engineering Research Report

> Cable harness design foundations applied to the ROBOTIS DARwIn-OP class
> humanoid (1st and 2nd generation). This is the dossier the Mac management
> application's harness module is built against.

---

## 1. Cable Harness Engineering Fundamentals

A **wire** is a single insulated conductor; a **cable** is two or more conductors sharing a jacket; a **harness** (also "loom" or "wiring tree") is a structured assembly of wires, cables, connectors, terminals, and protective coverings, manufactured as a single replaceable unit and routed along a predetermined path. The harness is the load-bearing object in robot maintenance: failures usually occur in harnesses, not in individual wires.

**Lifecycle stages** (industry-standard sequence):

1. **Requirements** — current, voltage, signal integrity, environment (flex cycles, temperature)
2. **Schematic / circuit list** — logical connectivity
3. **Wire list (from-to table)** — source pin → destination pin per conductor
4. **3D routing study** — physical pathway, bend radii, clamping, service loops
5. **BOM** — every cut wire, terminal, connector, sleeve, label
6. **Manufacture** — cut, strip, crimp, insert, dress, sleeve, label
7. **Test** — continuity, hipot, IR (insulation resistance), pull force
8. **Maintain** — inspect, log failures, replace per service interval

**Standards stack:**

- **IPC/WHMA-A-620F (2025)** — global consensus standard for "Requirements and Acceptance for Cable and Wire Harness Assemblies." Defines workmanship classes (Class 1 consumer, Class 2 dedicated/industrial, Class 3 high-reliability medical/aerospace), crimp acceptance, soldering criteria, marking, protective coverings, and electrical testing. **A robot harness is typically Class 2; mission-critical robots target Class 3.** The F revision supersedes E (Oct 2022).
- **SAE AS50881** — aerospace EWIS (electrical wiring interconnection systems), formerly **MIL-W-5088L** (made inactive for new design 1998). Covers installation design (separation, clamping, routing), not manufacture.
- **ANSI/TIA-606-D** — administration/labeling of telecom and structured cable plant, useful as a labeling-scheme template.
- **UL 758 / AWM** — recognized hookup wire ratings.
- **IEC 60228** — conductor classes (Class 5/6 = fine-stranded "flex" cable for robotics).

---

## 2. Harness Components

**Conductors.** Solid copper is forbidden in any flexing harness — only **stranded** (Class 5 or finer Class 6) survives joint articulation.

| AWG | Typical use in a DARWIN-class robot | Approx. chassis ampacity |
|-----|--------------------------------------|--------------------------|
| 28  | Low-current sensor signal             | ~1.4 A |
| 26  | TTL signal, encoder                   | ~2.2 A |
| 24  | Dynamixel TTL bus signal              | ~3.5 A |
| 22  | MX-28 power leg (per servo)           | ~7 A |
| 20  | Bus-segment power, common rail        | ~11 A |
| 18  | Battery-to-CM-730 main feed           | ~16 A |

**Insulation.** PVC (cheap, 80 °C, stiff at cold), **FEP/PTFE** (180–200 °C, flexible, expensive — preferred near motors), **silicone** (ultra-flexible, ideal for joints, but abrasion-prone — sleeve it), **TPE** (the modern robot-cable workhorse).

**Shielding.** Required when (a) cables run parallel to PWM motor leads, (b) signals are <1 V or differential at >100 kHz, or (c) regulatory EMC compliance is needed. Options: **braid** (best HF coverage), **foil** (full coverage, low flex life), **foil + drain wire** (low-cost compromise), **braid+foil** (premium). Ground the shield at one end only (typically the controller side) to prevent ground loops.

**Connectors used in a DARWIN-class build:**

- **JST PH (2.0 mm pitch, 2 A, 100 V)** — sensor breakouts, small batteries
- **JST XH (2.5 mm, 3 A, 250 V)** — workhorse for inter-board power, friction-latch
- **JST ZH (1.5 mm, 1 A)** and **SH (1.0 mm, 1 A)** — micro/internal IMU breakouts
- **Molex Mini-Fit Jr. (4.2 mm, 9 A)** — main battery and bus power
- **Molex PicoBlade (1.25 mm, 1 A)** — typical Pixhawk-class signal connector
- **Hirose DF13 (1.25 mm)** — looks like PicoBlade but **not interchangeable**; document carefully
- **ROBOTIS proprietary 3-pin Molex (TTL)** — Dynamixel daisy chain (see §4)

**Protection & dress.** Backshells and **strain relief** at every connector exit; **cable glands** at frame penetrations; **heat-shrink tubing** (2:1 polyolefin general-purpose, 3:1 adhesive-lined for sealed joints); **expandable braided sleeve** (PET, 155 °C); **spiral wrap** (cheap, allows mid-run breakouts); **lacing tape (waxed polyester)** preferred over zip ties under vibration because nylon zip ties stress-relax and saw through insulation.

---

## 3. Considerations Specific to Humanoid Robots

**Bend radius.** Industry rule for dynamic flex: **≥10×OD static, ≥20×OD dynamic** (some robotics suppliers cite 8×OD/15×OD as floor). A 4 mm OD sleeved Dynamixel pair therefore needs a 60–80 mm dynamic bend window.

**Service loops.** Every joint that rotates needs a slack loop sized to the maximum joint angle × harness OD ÷ 2 plus 20 % margin. For a knee with ±100° travel, plan ~30–40 mm of slack.

**Twist accumulation.** DARWIN-OP has **bounded** rotation everywhere, so anti-twist is unnecessary — but **direction-of-twist** still matters. Orient harnesses so they unwind, not wind up, when the joint moves toward its mechanical stop.

**EMI from PWM.** MX-28 motors are pulse-width-driven. Mitigation:

- Twisted pair on every signal/RS-485/USB run (twist rate ~1 turn per 25 mm)
- Ferrite chokes at the controller end, 1–2 turns through the ring max (more turns add capacitive coupling)
- Maintain physical separation from motor power ≥25 mm where possible (full 200 mm aerospace separation is impractical inside DARWIN's torso — rely on shielding instead)

**Voltage drop.** With a 3S Li-Po (11.1 V) and a ~10 A worst-case stall, even short 22 AWG runs cost 100–200 mV; size the battery-to-CM-730 leg at 18 AWG.

**Common-mode chokes** are needed for any USB or Ethernet that runs near motor cables. RS-485 differential pairs (Dynamixel Protocol 2.0) tolerate noise better than the original Protocol 1.0 single-wire half-duplex used by MX-28T.

---

## 4. ROBOTIS DARWIN-OP Specific Harness

**Servo topology — 20 DOF** (Dynamixel MX-28T, all on a single TTL bus):

- Head/Neck: 2 (pan, tilt — convention varies between IDs 19/20 and 1/2)
- Arms: 2 × 3 = 6 (shoulder pitch, shoulder roll, elbow per side)
- Legs: 2 × 6 = 12 (hip yaw, hip roll, hip pitch, knee, ankle pitch, ankle roll per side)

**Bus electrical.** Dynamixel Protocol 1.0 over half-duplex TTL on a 3-pin Molex housing: pin 1 = GND, pin 2 = VDD (11.1 V), pin 3 = DATA. Each servo has two parallel connectors so units daisy-chain pin-to-pin without splices. Default baud is 1 Mbps, fallback 576 kbps. Because it is single-wire half-duplex, the bus is more EMI-sensitive than a true differential pair — keep the run as short as possible inside each limb.

**Sub-controller.**

- **CM-730** (DARWIN-OP / "1st gen"): STM32F103RE Cortex-M3 @ 72 MHz, 512 KB flash, 64 KB SRAM; **6 ROBOTIS 3-pin ports**; 6–15 V supply (11.1 V nominal); 10 A bus fuse; 50 mA standby; 300 mA aux I/O; 5 buttons; mic; voltage sensor; gyro + accelerometer (±500 dps, ±4 g, 10-bit ADC).
- **CM-740** (DARWIN-OP 2 / "2nd gen"): functionally compatible with CM-730 (same sensor specs, same Dynamixel protocol) but **physically smaller PCB**. Released as part of the OP2 refresh that also moved the PC from Atom Z530 single-core/1 GB DDR2/4 GB NAND to Atom N2600 dual-core/up to 4 GB DDR3/32 GB mSATA. Pinout/port layout is largely preserved; mounting holes and outline differ.

**Routing landmarks** (per the official DARwIn-OP Wiring Manual on GitHub):

- Battery → CM-730 main power (back of torso)
- CM-730 → arm bus (neck-shoulder pass)
- CM-730 → leg bus (hip pass-through)
- Sensor cluster (FSR foot sensors, optional) → CM-730 aux I/O
- USB and FFC cable from PC SBC → CM-730

**1st-vs-2nd-gen harness deltas to track:**

- CM-730 vs CM-740 mounting and connector positions → bracket-side cable lengths differ
- OP2 PC has different USB header location and different mSATA/storage cabling
- OP2 chassis has slightly revised hip/shoulder bracket geometry, changing service-loop length
- Battery cable polarity and connector are unchanged (XT60 / Tamiya variants depending on ROBOTIS revision)

Authoritative source: **`ROBOTIS-GIT/ROBOTIS-OP-Series-Data`** repo on GitHub (`Hardware/Mechanics/DARwIn OP Wiring Manual.pdf` and `DARwIn OP Assembly Manual.pdf`).

---

## 5. Documentation & Tooling Landscape

**Schematic.** KiCad, Altium Designer, EAGLE all do harness-flavored schematics; Altium has a dedicated Harness Design module producing connector tables and BOMs.

**3D routing.** EPLAN Harness proD and EPLAN Pro Panel (industry leader for industrial automation), Siemens NX Routing, Dassault CATIA Electrical, SolidWorks Electrical 3D + SolidWorks Routing, Zuken E3.series.

**Open-source / lightweight.** **WireViz** (Python, YAML-input → SVG/PNG diagram + auto-BOM via Graphviz) — widely used in maker robotics and **the recommended interchange format** for our Mac app's import/export. Splice CAD and RapidHarness are commercial web-based alternatives.

**Wire labeling schemes:**

- *From-to:* `CM730.J3.P2 → MX-28(ID7).P3` (verbose, unambiguous)
- *Hierarchical:* `LL.HIP.YAW.PWR` (Left Leg, Hip Yaw, Power) — readable, good for stickers
- *Numbered:* `W042` with a separate from-to table — compact, requires the table to be on hand
- **Recommended for DARWIN: hierarchical primary + numeric ID secondary**, e.g. `W042 LL.KNEE.SIG`.

**Test procedures (per IPC/WHMA-A-620 §19):**

- **Continuity:** end-to-end resistance, pass typically <0.5 Ω for short jumpers.
- **Hipot / dielectric withstand:** 500 V DC or 1000 V AC for ~1 s between adjacent conductors and to shield; pass = no breakdown, leakage <1 mA.
- **Insulation Resistance (IR):** lower DC voltage (100–500 V), measure leakage steady-state; pass typically >100 MΩ.
- **Pin-to-pin / mis-wire:** automated test against a "golden" netlist.
- **Pull/retention:** crimp pull-out force per IPC-A-620 Table 19-2.

For an in-service robot, a **continuity sweep** plus visual inspection per IPC-A-620 Class 2 is the practical maintenance check; full hipot is reserved for newly built or re-terminated assemblies.

---

## 6. Sources

- [IPC/WHMA-A-620F-2025 — ANSI Blog](https://blog.ansi.org/ansi/ipc-whma-a-620f-2025-cable-wire-harness-assembly/)
- [IPC/WHMA-A-620 Standard — MJM Industries](https://mjmindustries.com/what-is-the-ipc-whma-a-620-standard/)
- [Understanding IPC/WHMA-A-620 — TT Electronics](https://www.ttelectronics.com/blog/cable-harness-standards/)
- [An Introduction to A-620 Cable Testing — Cirris](https://cirris.com/a-summary-of-a-620-cable-testing-standard/)
- [Wire Harness Testing Protocols — TeleWire](https://www.telewiretech.com/blogs/technical-resources/essential-testing-protocols-for-custom-cable-assemblies)
- [What Is SAE-AS50881 — Interconnect Wiring](https://www.interconnect-wiring.com/blog/what-is-sae-as50881-and-how-does-it-relate-to-wiring-harness-design/)
- [MIL-W-5088L — EverySpec](https://everyspec.com/MIL-SPECS/MIL-SPECS-MIL-W/MIL-W-5088L_11283/)
- [Sub Controller (CM-730) — ROBOTIS](http://support.robotis.com/en/product/darwin-op/references/reference/hardware_specifications/electronics/sub_controller_(cm-730).htm)
- [Replacing Dynamixel(s) — ROBOTIS](http://support.robotis.com/en/product/darwin-op/self-maintenance/replacing_dynamixel(s).htm)
- [DARwIn-OP — Wikipedia](https://en.wikipedia.org/wiki/DARwIn-OP)
- [DARwIn OP Wiring Manual — ROBOTIS-GIT GitHub](https://github.com/ROBOTIS-GIT/ROBOTIS-OP-Series-Data/blob/master/ROBOTIS-OP,%20ROBOTIS-OP2/Hardware/Mechanics/DARwIn%20OP%20Wiring%20Manual.pdf)
- [Picking the right cables for your DYNAMIXEL — ROBOTIS](https://robotis.us/tech-tips-picking-the-right-cables-for-your-dynamixel)
- [DYNAMIXEL Selection Guide — ROBOTIS e-Manual](https://emanual.robotis.com/docs/en/reference/dxl-selection-guide/)
- [Robot Wire Harness Design for Motion Life — FPIC](https://sz-fpi.com/how-to-design-a-robot-wire-harness-for-torsion-bend-radius-and-drag-chain-life)
- [What's the Best Way to Reduce Cable Failures in Moving Robots — RoboticsAndAutomationNews](https://roboticsandautomationnews.com/2025/12/29/whats-the-best-way-to-reduce-cable-failures-in-moving-robots-arms-agvs-and-humanoid-joints/97904/)
- [JST Connector Comparison — TeleWire](https://www.telewiretech.com/blogs/technical-resources/jst-connector-comparison-ph-vs-xh-vs-sh-vs-zh-vs-gh-for-board-to-wire-applications)
- [DF13 Series — Hirose / DigiKey](https://www.digikey.com/en/product-highlight/h/hirose/df13-series)
- [AWG Wire Gauge Sizes — EngineeringToolbox](https://www.engineeringtoolbox.com/wire-gauges-d_419.html)
- [7 Steps to Reducing EMI with VFDs — KEB](https://www.kebamerica.com/blog/7-steps-to-reducing-emi-with-vfds/)
- [Mitigating Conducted EMI with Ferrite Rings — KEB](https://www.kebamerica.com/blog/mitigating-conducted-emi-with-ferrite-rings/)
- [SOLIDWORKS Electrical vs Routing — GoEngineer](https://www.goengineer.com/blog/solidworks-electrical-vs-routing)
- [EPLAN Harness proD](https://www.eplan.com/us-en/products/eplan-harness-prod/)
- [WireViz — GitHub](https://github.com/wireviz/WireViz)
- [Defining the Wiring Diagram — Altium Designer](https://www.altium.com/documentation/altium-designer/harness-design/wiring-diagram)
- [ANSI/TIA-606-B Cable Labeling — DuraLabel](https://resources.duralabel.com/articles/ansi-tia-606-b-cable-labeling-standards)
