# Dynamixel Protocol 1.0 — Reference for DarwinForge

> The wire protocol used by every device on a DARwIn-OP / OP2: the
> CM-730 / CM-740 sub-controller (ID 200), all 20 MX-28T servos (IDs 1–20),
> and the optional FSR boards (IDs 111/112). Half-duplex TTL UART, default
> **1 000 000 baud, 8-N-1**.
>
> This page is the spec the `DynamixelKit` Swift module is implemented
> against. When in doubt, prefer the official ROBOTIS reference at
> <https://emanual.robotis.com/docs/en/dxl/protocol1/> over what's written
> here.

## Packet format

Every transaction is a single packet. Two shapes — *Instruction* (host →
device) and *Status* (device → host).

```
Instruction Packet:
  0xFF 0xFF  ID  LENGTH  INSTRUCTION  PARAM_1 ... PARAM_N  CHECKSUM

Status Packet (response):
  0xFF 0xFF  ID  LENGTH  ERROR        PARAM_1 ... PARAM_N  CHECKSUM
```

- `LENGTH` = N + 2 (parameter count + instruction/error byte + checksum)
- `CHECKSUM` = `~(ID + LENGTH + INSTRUCTION + sum(PARAMS)) & 0xFF`
- `ID` 0–253; **254 = broadcast** (no Status returned)

## Instruction codes

| Code | Name           | Notes |
|------|----------------|-------|
| 0x01 | PING           | discovery |
| 0x02 | READ_DATA      | read register(s) |
| 0x03 | WRITE_DATA     | write register(s) |
| 0x04 | REG_WRITE      | queued write (commit on ACTION) |
| 0x05 | ACTION         | trigger queued writes |
| 0x06 | FACTORY_RESET  | |
| 0x08 | REBOOT         | |
| 0x83 | SYNC_WRITE     | write same registers across many IDs in one packet |
| 0x92 | BULK_READ      | read different registers from many IDs in one transaction |

Hot path:

- The Walking / Motion loop uses **`BULK_READ` every cycle** to read all 20 joint positions + IMU + FSR in a single transaction.
- It uses **`SYNC_WRITE`** to push the next 20 joint targets (and PID) in another single packet.

## Error byte (Status packet)

| Bit | Flag             | Cause |
|-----|------------------|-------|
| 0 (0x01) | INPUT_VOLTAGE | supply outside servo's voltage limits |
| 1 (0x02) | ANGLE_LIMIT   | goal position outside CW/CCW limits |
| 2 (0x04) | OVERHEATING   | internal temperature limit hit |
| 3 (0x08) | RANGE         | parameter out of range |
| 4 (0x10) | CHECKSUM      | RX checksum mismatch on the device side |
| 5 (0x20) | OVERLOAD      | motor torque could not satisfy load |
| 6 (0x40) | INSTRUCTION   | unknown or invalid instruction |

## Bus electrical

- Half-duplex TTL: VDD, GND, DATA on a 3-pin Molex/ROBOTIS SP connector ("Robot Cable-3P")
- 5 V logic levels
- Pull-up enabled inside each device
- Daisy-chain by passing through; no terminator needed at typical bus lengths inside the robot
- 1 Mbps default; the framework sometimes falls back to 576 kbps when CM detects errors. Servo register `4` selects baud.

## CM-730 / CM-740 host-side bridging

The CM-730 / CM-740 acts as a USB↔TTL bridge. From the Mac it is a serial
device — typically `/dev/cu.usbserial-*` (FTDI) at 1 Mbps. **There is no
separate higher-level USB protocol**: open the port at the right baud and
issue Protocol 1.0 packets directly. The CM appears as an addressable
device on the same packet stream via its own `ID 200`.

Implication for `DynamixelKit`: a single `SerialPort` writer/reader is
sufficient for the entire robot. No need to model "USB" and "TTL bus"
separately.

## Common control-table addresses

### CM-730 / CM-740 (`ID 200`)

| Address | Name          | Notes |
|---------|---------------|-------|
| 24      | DXL_POWER     | gate the Dynamixel power rail |
| 25      | LED_PANEL     | 3 chest LEDs |
| 26–29   | LED_HEAD / LED_EYE | RGB |
| 30      | BUTTON        | mode / start / select etc. |
| 38–43   | GYRO Z / Y / X | 10-bit ADC, ±500 dps |
| 44–49   | ACCEL X / Y / Z | 10-bit ADC, ±4 g |
| 50      | VOLTAGE       | battery voltage |
| 51–52, 67–68 | MIC L / R | analog mic samples |
| 53–80   | ADC channels 2–15 | |

### MX-28T servo (`ID 1..20`)

Subset (full table at <https://emanual.robotis.com/docs/en/dxl/mx/mx-28/>):

| Address | Name              | Type    |
|---------|-------------------|---------|
| 0–1     | Model Number      | EEPROM  |
| 3       | ID                | EEPROM  |
| 4       | Baud Rate         | EEPROM  |
| 6–7     | CW Angle Limit    | EEPROM  |
| 8–9     | CCW Angle Limit   | EEPROM  |
| 24      | Torque Enable     | RAM     |
| 25      | LED               | RAM     |
| 26      | D Gain            | RAM     |
| 27      | I Gain            | RAM     |
| 28      | P Gain            | RAM     |
| 30–31   | Goal Position     | RAM     |
| 32–33   | Moving Speed      | RAM     |
| 34–35   | Torque Limit      | RAM     |
| 36–37   | Present Position  | RAM, 12-bit (0–4095) |
| 38–39   | Present Speed     | RAM     |
| 40–41   | Present Load      | RAM     |
| 42      | Present Voltage   | RAM     |
| 43      | Present Temperature | RAM   |

## Reference Swift implementation contract

`DynamixelKit` exposes a typed API on top of the byte protocol:

```swift
public struct DynamixelPacket {
    public let id: UInt8
    public let instruction: Instruction
    public let parameters: [UInt8]
}

public enum Instruction: UInt8 {
    case ping = 0x01
    case readData = 0x02
    case writeData = 0x03
    case regWrite = 0x04
    case action = 0x05
    case factoryReset = 0x06
    case reboot = 0x08
    case syncWrite = 0x83
    case bulkRead = 0x92
}

public protocol DynamixelBus {
    func send(_ packet: DynamixelPacket) async throws
    func receive(timeout: Duration) async throws -> StatusPacket
}
```

`SerialBus` is the production conformer (FTDI / CDC over `IOKit`/`ORSSerialPort`); `LoopbackBus` is the test conformer used by `DynamixelKitTests`.
