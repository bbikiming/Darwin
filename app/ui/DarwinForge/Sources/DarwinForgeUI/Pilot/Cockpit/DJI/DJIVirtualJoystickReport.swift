import Foundation

/// DJI Virtual Joystick HID input report 의 **순수 디코더**.
///
/// # 실측 HID Report Descriptor (DJI FPV Remote Controller 3, VID=0x2CA3, PID=0x1021)
///
/// `ioreg -p IOUSB -r -l` 출력을 디코드한 결과:
///
/// ```
/// 05 01        Usage Page (Generic Desktop)
/// 09 05        Usage (Game Pad)
/// A1 01        Collection (Application)
///   A1 00      Collection (Physical)
///     05 09    Usage Page (Buttons)
///     19 01 29 18    Buttons 1..24
///     15 00 25 01    Logical 0..1
///     95 18 75 01    24 × 1bit  →  3 bytes
///     81 02          Input (Data, Var, Abs)
///     05 01    Usage Page (Generic Desktop)
///     09 30 31 32 33 34   X, Y, Z, Rx, Ry
///     16 6C FD 26 94 02   Logical -660..+660 (int16 LE)
///     75 10 95 05         5 × 16bit  →  10 bytes
///     81 02          Input (Data, Var, Abs)
///   C0
/// C0
/// ```
///
/// 총 13 bytes — `MaxInputReportSize = 13` (실 ioreg 검증과 정확히 일치).
///
/// 이 디코더는 framework 의존성이 없고, raw `Data` 만 받아 순수 함수처럼 동작하므로
/// 단위 테스트로 결정론 검증이 가능하다 (HID Manager / IOKit 의존 없이).
public struct DJIVirtualJoystickReport: Equatable, Sendable {

    // MARK: - DJI vendor / product

    /// DJI Technology Co., Ltd. — USB vendor ID.
    public static let vendorID: Int = 0x2CA3
    /// "DJI Virtual Joystick" — DJI FPV Remote Controller 3 USB game-controller 모드.
    public static let productID: Int = 0x1021

    /// HID 디스크립터가 명시한 axis 범위. signed int16 little-endian.
    public static let axisMin: Int16 = -660
    public static let axisMax: Int16 =  660

    /// 디코더가 인식하는 정확한 input report 길이 (bytes).
    public static let reportSize: Int = 13

    // MARK: - Stored fields (normalised to -1.0 ... 1.0)

    /// X axis (좌 스틱 X — yaw on standard DJI Mode 2).
    public let axisX: Double
    /// Y axis (좌 스틱 Y — throttle on standard DJI Mode 2).
    public let axisY: Double
    /// Z axis (camera wheel — 보통 우측 휠).
    public let axisZ: Double
    /// Rx axis (우 스틱 X — roll on standard DJI Mode 2).
    public let axisRx: Double
    /// Ry axis (우 스틱 Y — pitch on standard DJI Mode 2).
    public let axisRy: Double
    /// 24개 버튼의 down 상태. index 0 = button 1 (LSB of byte 0).
    public let buttons: [Bool]

    // MARK: - Decoding

    public init(axisX: Double = 0,
                axisY: Double = 0,
                axisZ: Double = 0,
                axisRx: Double = 0,
                axisRy: Double = 0,
                buttons: [Bool] = Array(repeating: false, count: 24)) {
        self.axisX = axisX
        self.axisY = axisY
        self.axisZ = axisZ
        self.axisRx = axisRx
        self.axisRy = axisRy
        self.buttons = buttons
    }

    /// 13-byte raw report → normalised report. 길이가 정확히 13이 아니면 nil.
    ///
    /// 길이 검사 외에 다른 sanity check 는 하지 않는다 — 잘못된 디스크립터의
    /// 디바이스가 우연히 같은 길이를 보내면 garbage 가 통과할 수 있지만, vendor 매칭
    /// (`vendorID = 0x2CA3`) 으로 이미 1차 필터링되어 있어 production 에서는 안전.
    public static func decode(_ data: Data) -> DJIVirtualJoystickReport? {
        guard data.count == reportSize else { return nil }
        let bytes = Array(data)

        // Bytes 0..2 : 24 buttons (LSB-first within each byte, button 1 = bit 0 of byte 0).
        var buttons: [Bool] = []
        buttons.reserveCapacity(24)
        for i in 0..<24 {
            let byteIndex = i / 8
            let bitIndex  = i % 8
            buttons.append((bytes[byteIndex] >> bitIndex) & 0x01 == 1)
        }

        // Bytes 3..12 : 5 axes × int16 little-endian, range -660 ... +660.
        let x  = readSignedInt16LE(bytes, offset: 3)
        let y  = readSignedInt16LE(bytes, offset: 5)
        let z  = readSignedInt16LE(bytes, offset: 7)
        let rx = readSignedInt16LE(bytes, offset: 9)
        let ry = readSignedInt16LE(bytes, offset: 11)

        return DJIVirtualJoystickReport(
            axisX:  normalise(x),
            axisY:  normalise(y),
            axisZ:  normalise(z),
            axisRx: normalise(rx),
            axisRy: normalise(ry),
            buttons: buttons
        )
    }

    /// raw int16 → [-1.0, +1.0]. clamp 로 안전하게 처리 (디바이스가 660 초과 보내도
    /// 정규화 결과는 ±1.0 으로 saturate).
    public static func normalise(_ raw: Int16) -> Double {
        let v = Double(raw) / Double(axisMax)
        return max(-1.0, min(1.0, v))
    }

    private static func readSignedInt16LE(_ bytes: [UInt8], offset: Int) -> Int16 {
        let lo = UInt16(bytes[offset])
        let hi = UInt16(bytes[offset + 1])
        return Int16(bitPattern: lo | (hi << 8))
    }
}
