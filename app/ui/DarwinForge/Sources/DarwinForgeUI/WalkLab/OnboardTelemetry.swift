import Foundation
import ForgeCore

/// SSH 온보드 경로의 robot→Mac 텔레메트리 한 줄을 표현하는 불변(immutable) 값.
///
/// 비유: 로봇이 매 0.2초마다 `/tmp/df-walklab-telemetry`에 "현재 상태 엽서"를
/// 한 장 남긴다. Mac은 그 엽서를 주워서 읽기만 한다. 이 struct는 그 엽서 한 장을
/// 그대로 옮겨 적은 것 — 해석/가공은 하지 않고 원시(raw) 값만 담는다.
///
/// 줄 포맷 (contract §A.2, PINNED) — 11 토큰, 공백 구분, `TEL` prefix:
/// ```
/// TEL {ts_ms} {gyroX} {gyroY} {gyroZ} {accelX} {accelY} {accelZ} {voltage_dV} {walking01} {fallen}
/// ```
/// 예: `TEL 1748736000123 511 530 498 512 489 760 122 1 0`
public struct OnboardTelemetry: Equatable, Sendable {
    public let tsMs: Int64
    public let gyroX: UInt16   // raw 0..1023
    public let gyroY: UInt16
    public let gyroZ: UInt16
    public let accelX: UInt16
    public let accelY: UInt16
    public let accelZ: UInt16
    public let voltageDeciVolts: Int   // 0 = unknown
    public let walking: Bool
    public let fallen: Int             // -1 / 0 / 1

    public init(tsMs: Int64,
                gyroX: UInt16, gyroY: UInt16, gyroZ: UInt16,
                accelX: UInt16, accelY: UInt16, accelZ: UInt16,
                voltageDeciVolts: Int, walking: Bool, fallen: Int) {
        self.tsMs = tsMs
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.voltageDeciVolts = voltageDeciVolts
        self.walking = walking
        self.fallen = fallen
    }

    // MARK: - Parse

    /// 한 줄(`/tmp/df-walklab-telemetry`)을 파싱. 잘못된 입력은 전부 nil 반환
    /// (샘플 drop). 절대 crash 하지 않고, gate에 garbage를 흘려보내지 않는다.
    ///
    /// 규칙 (contract §A.3): trim → 공백 split(빈 토큰 제거) → `[0] == "TEL"` &&
    /// 정확히 11 토큰 → 나머지 파싱. 범위 초과/NaN → nil.
    public static func parse(_ input: String) -> OnboardTelemetry? {
        // **버그 fix (2026-06-01)**: poller 는 SSHShell 의 *combined* 출력을 넘긴다 —
        // "TEL ...\n--- exit 0 ---" 처럼 exit suffix/stderr 가 붙는다. 전체를 한 번에
        // 토큰화하면 count≠11 로 매번 실패했다(telemetryMode 영원히 offline). 여러 줄 중
        // "TEL "로 시작하는 11-토큰 라인을 찾아 파싱한다 (단일 깨끗한 라인도 그대로 동작).
        for rawLine in input.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let sample = parseLine(String(rawLine)) { return sample }
        }
        return nil
    }

    /// 한 줄 파싱 — "TEL {ts} {gx gy gz ax ay az} {voltage} {walking01} {fallen}" (11 토큰).
    private static func parseLine(_ line: String) -> OnboardTelemetry? {
        let tokens = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        guard tokens.count == 11, tokens[0] == "TEL" else { return nil }

        guard let tsMs = Int64(tokens[1]),
              let gyroX = adcWord(tokens[2]),
              let gyroY = adcWord(tokens[3]),
              let gyroZ = adcWord(tokens[4]),
              let accelX = adcWord(tokens[5]),
              let accelY = adcWord(tokens[6]),
              let accelZ = adcWord(tokens[7]),
              let voltage = Int(tokens[8]),
              let walking01 = Int(tokens[9]),
              let fallen = Int(tokens[10])
        else { return nil }

        // 범위 검증 — gate에 들어가는 값이므로 경계에서 막는다.
        guard voltage >= 0,
              walking01 == 0 || walking01 == 1,
              fallen == -1 || fallen == 0 || fallen == 1
        else { return nil }

        return OnboardTelemetry(
            tsMs: tsMs,
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            accelX: accelX, accelY: accelY, accelZ: accelZ,
            voltageDeciVolts: voltage,
            walking: walking01 == 1,
            fallen: fallen
        )
    }

    /// 10-bit ADC 토큰 파싱: 정수이고 0..1023 범위여야 함. 아니면 nil.
    private static func adcWord(_ token: String) -> UInt16? {
        guard let value = Int(token), value >= 0, value <= 1023 else { return nil }
        return UInt16(value)
    }

    // MARK: - Derived

    /// 전압(V). unknown(deci-volts == 0)이면 nil.
    public var voltageVolts: Double? {
        voltageDeciVolts > 0 ? Double(voltageDeciVolts) / 10.0 : nil
    }

    // MARK: - Mapping into ForgeCore pipelines

    /// raw ADC → `ForgeCore.ImuRaw`. rollDeg/pitchDeg는 0 (온보드 HUD는 여기서
    /// gyro/accel만 사용; 자세각은 보드가 안 보냄). gate/HUD가 기대하는 raw 형식.
    public func toImuRaw() -> ImuRaw {
        ImuRaw(
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            accelX: accelX, accelY: accelY, accelZ: accelZ,
            rollDeg: 0, pitchDeg: 0
        )
    }

    /// 전압 gate(L0)용 `BoardSnapshot`. 전압 unknown이면 nil (마지막 board 유지하라는
    /// 신호 — contract §D.3). modelNumber 740, version 0, button 0 고정.
    public func toBoardSnapshot() -> BoardSnapshot? {
        guard voltageDeciVolts > 0 else { return nil }
        return BoardSnapshot(
            modelNumber: 740,
            version: 0,
            voltageRaw: UInt8(clamping: voltageDeciVolts),
            button: 0
        )
    }
}
