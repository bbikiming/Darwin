import Foundation

/// **v1.20.0 (2026-05-21) 사이클 5 — Tello state message parsing**.
///
/// Tello SDK 의 state port (UDP 8890) 가 100ms 주기로 송출하는 텍스트 메시지 파싱.
/// Format (Tello SDK 2.0 docs):
/// ```
/// pitch:0;roll:0;yaw:0;vgx:0;vgy:0;vgz:0;templ:60;temph:62;tof:10;h:0;
/// bat:87;baro:-21.34;time:0;agx:-12.00;agy:8.00;agz:-996.00;
/// ```
///
/// macOS 가 Tello AP 에 접속한 상태에서 NWListener 가 port 8890 으로 패킷 수신.
/// 본 모듈은 ASCII 문자열을 struct 로 파싱 — 100% 순수 함수 (test 가능).
public struct TelloStateMessage: Equatable, Sendable {
    public let pitchDeg: Double
    public let rollDeg: Double
    public let yawDeg: Double
    /// velocity x/y/z (cm/s).
    public let vgx: Double
    public let vgy: Double
    public let vgz: Double
    /// 하한 / 상한 motor temp (°C).
    public let templ: Double
    public let temph: Double
    /// Time-of-Flight 거리 센서 (cm). nil 이면 미지원.
    public let tofCm: Double?
    /// 고도 (cm) — relative.
    public let heightCm: Double
    /// 배터리 잔량 0..100 (%).
    public let batteryPct: Int
    /// 기압 (Pa).
    public let baroPa: Double?
    /// 가속도 x/y/z (cm/s^2).
    public let agx: Double
    public let agy: Double
    public let agz: Double
    /// 수신 시각 (host 기준).
    public let receivedAt: Date

    /// 배터리 색상 코딩 — view 가 활용.
    public var batteryLevel: BatteryLevel {
        if batteryPct >= 50 { return .good }
        if batteryPct >= 20 { return .medium }
        return .low
    }

    public enum BatteryLevel: String, Sendable {
        case good       // ≥50%
        case medium     // ≥20%
        case low        // <20%
    }
}

// MARK: - Parser

public enum TelloStateMessageParser {

    /// raw ASCII string → struct. 파싱 실패 시 nil (필드 누락 등).
    public static func parse(_ raw: String, receivedAt: Date = Date()) -> TelloStateMessage? {
        // "pitch:0;roll:0;yaw:0;..." 형식. 세미콜론으로 split, 콜론으로 키:값.
        let pairs = raw.split(separator: ";")
        var dict: [String: String] = [:]
        for pair in pairs {
            let kv = pair.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            dict[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces)
        }
        // 필수 필드 검증.
        guard let pitch = doubleValue("pitch", in: dict),
              let roll = doubleValue("roll", in: dict),
              let yaw = doubleValue("yaw", in: dict),
              let bat = intValue("bat", in: dict)
        else { return nil }

        return TelloStateMessage(
            pitchDeg: pitch,
            rollDeg: roll,
            yawDeg: yaw,
            vgx: doubleValue("vgx", in: dict) ?? 0,
            vgy: doubleValue("vgy", in: dict) ?? 0,
            vgz: doubleValue("vgz", in: dict) ?? 0,
            templ: doubleValue("templ", in: dict) ?? 0,
            temph: doubleValue("temph", in: dict) ?? 0,
            tofCm: doubleValue("tof", in: dict),
            heightCm: doubleValue("h", in: dict) ?? 0,
            batteryPct: max(0, min(100, bat)),
            baroPa: doubleValue("baro", in: dict),
            agx: doubleValue("agx", in: dict) ?? 0,
            agy: doubleValue("agy", in: dict) ?? 0,
            agz: doubleValue("agz", in: dict) ?? 0,
            receivedAt: receivedAt
        )
    }

    private static func doubleValue(_ key: String, in dict: [String: String]) -> Double? {
        dict[key].flatMap { Double($0) }
    }

    private static func intValue(_ key: String, in dict: [String: String]) -> Int? {
        dict[key].flatMap { Int($0) }
    }
}
