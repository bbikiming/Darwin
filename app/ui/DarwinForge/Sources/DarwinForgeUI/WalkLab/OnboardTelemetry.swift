import Foundation
import ForgeCore

/// **O4 (2026-06-12)** — TEL2 가 노출하는 "로봇이 실제로 적용 중인" 보행 상태 스냅샷.
/// 콕핏 HUD "명령 vs 래치값" 인디케이터(래칭 지연 가시화)와 시뮬 walkAnimator 위상 동기가
/// 소비한다. 셰이핑(거버너→슬루→게이트) 후 모터에 간 값 — "화면=게이지=실모터" 불변식.
public struct OnboardLatchSnapshot: Equatable, Sendable {
    public let phase: Int?           // Walking 위상 0..3 (미상 nil)
    public let seqApplied: Int64?    // 로봇이 적용한 명령 seq (스트림 폐루프)
    public let strideMm: Double      // x_lat
    public let sideMm: Double        // y_lat
    public let turnDeg: Double       // a_lat
    public let periodMs: Double      // period_lat
    public let activeSource: String? // "udp"/"file"
    public let at: Date

    public init(phase: Int?, seqApplied: Int64?, strideMm: Double, sideMm: Double,
                turnDeg: Double, periodMs: Double, activeSource: String?, at: Date) {
        self.phase = phase
        self.seqApplied = seqApplied
        self.strideMm = strideMm
        self.sideMm = sideMm
        self.turnDeg = turnDeg
        self.periodMs = periodMs
        self.activeSource = activeSource
        self.at = at
    }

    /// 이산 로봇 위상(PHASE0..3)을 보행 1주기 분율(0..1)로 — 시뮬 애니메이터 위상 정렬용.
    /// PHASE0(DSP)=0.0, PHASE1(좌스윙)=0.25, PHASE2(DSP)=0.5, PHASE3(우스윙)=0.75.
    public var phaseFraction01: Double? {
        guard let p = phase, p >= 0 else { return nil }
        return Double(((p % 4) + 4) % 4) / 4.0
    }
}

/// SSH 온보드 경로의 robot→Mac 텔레메트리 한 줄을 표현하는 불변(immutable) 값.
///
/// 비유: 로봇이 매 0.2초마다 `/tmp/df-walklab-telemetry`에 "현재 상태 엽서"를
/// 한 장 남긴다. Mac은 그 엽서를 주워서 읽기만 한다. 이 struct는 그 엽서 한 장을
/// 그대로 옮겨 적은 것 — 해석/가공은 하지 않고 원시(raw) 값만 담는다.
///
/// 줄 포맷 (contract §A.2) — **최소 11 토큰**, 공백 구분, `TEL` prefix:
/// ```
/// TEL {ts_ms} {gyroX} {gyroY} {gyroZ} {accelX} {accelY} {accelZ} {voltage_dV} {walking01} {fallen}
///     [{last_cmd_id} {loop_ms}]                                                   ← O0 (≥11 토큰)
/// ```
/// 예: `TEL 1748736000123 511 530 498 512 489 760 122 1 0`
/// 예(O0): `TEL 1748736000123 511 530 498 512 489 760 122 1 0 c123_ab12cd34 18`
///
/// **O0 (2026-06-12, walklab-onboard-teleop-upgrade Wave O0)**: 종전 "정확히 11 토큰"
/// 검증을 "≥11" 로 완화한다 — 로봇 브로커리지가 `{last_cmd_id} {loop_ms}` 2 토큰을 APPEND
/// 해도 구버전 파서가 매번 실패(telemetryMode 영원히 offline)하던 비호환을 제거. 완화
/// 커밋을 *먼저* 배포해야 로봇 측 토큰 추가가 안전하다(contract §A.3). 추가 토큰이 없으면
/// `lastCmdId`/`loopMs` 는 nil — 명령 적용 시각 폐루프 확인 기능만 graceful degrade.
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

    /// **O0** — 로봇이 마지막으로 적용한 명령의 cmd_id. 토큰 미존재(구버전 펌웨어) 시 nil.
    /// Mac 이 "보낸 cmd_id == 텔레메트리 last_cmd_id" 로 명령 적용을 폐루프 확인.
    public let lastCmdId: String?
    /// **O0** — 로봇 supervisor 루프 1회 소요(ms). 토큰 미존재 시 nil. HUD loop_p95 진단용.
    public let loopMs: Int?

    // MARK: - O4 TEL2 (2026-06-12, walklab-onboard-teleop-upgrade Wave O4)
    // 아래 필드는 **TEL2(v2) 라인에서만** 채워진다(UDP 30Hz 경로). v1(파일·SSH 폴백) 라인은
    // 전부 nil — `isTel2 == false`. "명령 vs 실제 적용"(래치)·위상·FSR 을 Mac 이 표시/소비.

    /// TEL2 라인 여부(prefix `TEL2`). v1 은 false.
    public let isTel2: Bool
    /// Walking 게이트 위상(0..3). -1/미존재 = 미상.
    public let phase: Int?
    /// 마지막으로 로봇이 적용한 명령의 seq(스트림 폐루프). 미존재 nil.
    public let seqApplied: Int64?
    /// 셰이핑(거버너→슬루→게이트) 후 실제 대입된 진폭/주기 — 래칭 지연 가시화.
    public let latStrideMm: Double?
    public let latSideMm: Double?
    public let latTurnDeg: Double?
    public let latPeriodMs: Double?
    /// 좌/우 발 FSR 4셀(wire 순서 l1..l4 / r1..r4). 미장착(OP1/PING 실패) 시 nil.
    public let fsrLeftCells: [UInt16]?
    public let fsrRightCells: [UInt16]?
    /// 전신 CoP 근사(접지발 FSR_X/Y 바이트 평균). 미가용 시 nil.
    public let copX: Int?
    public let copY: Int?
    /// 낙상 위험 지표(O3) — 현재 로봇 미구현이라 항상 nil(자리만). forward-compat.
    public let riskDeg: Double?
    /// 마지막 적용 명령의 소스("udp"/"file") — H2 가시화. 미존재 nil.
    public let activeSource: String?

    public init(tsMs: Int64,
                gyroX: UInt16, gyroY: UInt16, gyroZ: UInt16,
                accelX: UInt16, accelY: UInt16, accelZ: UInt16,
                voltageDeciVolts: Int, walking: Bool, fallen: Int,
                lastCmdId: String? = nil, loopMs: Int? = nil,
                isTel2: Bool = false, phase: Int? = nil, seqApplied: Int64? = nil,
                latStrideMm: Double? = nil, latSideMm: Double? = nil,
                latTurnDeg: Double? = nil, latPeriodMs: Double? = nil,
                fsrLeftCells: [UInt16]? = nil, fsrRightCells: [UInt16]? = nil,
                copX: Int? = nil, copY: Int? = nil,
                riskDeg: Double? = nil, activeSource: String? = nil) {
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
        self.lastCmdId = lastCmdId
        self.loopMs = loopMs
        self.isTel2 = isTel2
        self.phase = phase
        self.seqApplied = seqApplied
        self.latStrideMm = latStrideMm
        self.latSideMm = latSideMm
        self.latTurnDeg = latTurnDeg
        self.latPeriodMs = latPeriodMs
        self.fsrLeftCells = fsrLeftCells
        self.fsrRightCells = fsrRightCells
        self.copX = copX
        self.copY = copY
        self.riskDeg = riskDeg
        self.activeSource = activeSource
    }

    // MARK: - Parse

    /// 한 줄(`/tmp/df-walklab-telemetry`)을 파싱. 잘못된 입력은 전부 nil 반환
    /// (샘플 drop). 절대 crash 하지 않고, gate에 garbage를 흘려보내지 않는다.
    ///
    /// 규칙 (contract §A.3): trim → 공백 split(빈 토큰 제거) → `[0] == "TEL"` &&
    /// **≥11 토큰** → 첫 11 토큰 파싱 + 선택적 `{last_cmd_id} {loop_ms}`. 범위 초과/NaN → nil.
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

    /// 한 줄 파싱 — "TEL {ts} {gx gy gz ax ay az} {voltage} {walking01} {fallen}" (≥11 토큰)
    /// + 선택적 O0 토큰 `{last_cmd_id} {loop_ms}` (12·13번째).
    private static func parseLine(_ line: String) -> OnboardTelemetry? {
        let tokens = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        // **O4**: prefix 로 방언 판별. "TEL2" → v2(UDP 30Hz), "TEL" → v1(파일·SSH 폴백).
        guard let first = tokens.first else { return nil }
        if first == "TEL2" { return parseTel2(tokens) }

        // **O0**: "정확히 11" → "≥11". 추가 토큰은 선택적으로 소비, 미지 토큰은 무시.
        guard tokens.count >= 11, tokens[0] == "TEL" else { return nil }

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

        // **O0** 선택 토큰 — 존재하면 파싱, 형식 불량이면 그 필드만 nil(라인은 유효).
        // last_cmd_id 는 임의 shell-safe 문자열(cmd_id 규약). "no_id"/"-" 는 nil 로 정규화.
        let lastCmdId: String? = {
            guard tokens.count >= 12 else { return nil }
            let raw = tokens[11]
            return (raw == "no_id" || raw == "-") ? nil : raw
        }()
        let loopMs: Int? = {
            guard tokens.count >= 13, let v = Int(tokens[12]), v >= 0 else { return nil }
            return v
        }()

        return OnboardTelemetry(
            tsMs: tsMs,
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            accelX: accelX, accelY: accelY, accelZ: accelZ,
            voltageDeciVolts: voltage,
            walking: walking01 == 1,
            fallen: fallen,
            lastCmdId: lastCmdId,
            loopMs: loopMs
        )
    }

    /// **O4** — TEL2(v2) 한 줄 파싱. 형식(contract §A.2 TEL2):
    /// `TEL2 {ts} {seq} {phase} {x} {y} {a} {period} {gx gy gz ax ay az}`
    /// `{fsr l1..l4 r1..r4 | -} {copx copy | -} {fallen} {risk|-} {vdV} {src} {loop}`
    /// 가변 토큰(FSR/CoP "-" 폴백)은 커서로 좌→우 소비. 형식 불량/범위초과 → nil(드롭).
    private static func parseTel2(_ tokens: [String]) -> OnboardTelemetry? {
        // 최소 길이: 고정 14(prefix~az) + FSR "-"(1) + CoP "-"(1) + 후행 5 = 21.
        guard tokens.count >= 21, tokens[0] == "TEL2" else { return nil }

        guard let tsMs = Int64(tokens[1]),
              let seq = Int64(tokens[2]),
              let phase = Int(tokens[3]),
              let x = Double(tokens[4]),
              let y = Double(tokens[5]),
              let a = Double(tokens[6]),
              let period = Double(tokens[7]),
              let gyroX = adcWord(tokens[8]),
              let gyroY = adcWord(tokens[9]),
              let gyroZ = adcWord(tokens[10]),
              let accelX = adcWord(tokens[11]),
              let accelY = adcWord(tokens[12]),
              let accelZ = adcWord(tokens[13])
        else { return nil }

        var cursor = 14

        // FSR 그룹: "-"(1토큰) 또는 8셀(l1..l4 r1..r4).
        var leftCells: [UInt16]? = nil
        var rightCells: [UInt16]? = nil
        if tokens[cursor] == "-" {
            cursor += 1
        } else {
            guard tokens.count >= cursor + 8 else { return nil }
            var cells: [UInt16] = []
            for i in 0..<8 {
                guard let c = UInt16(tokens[cursor + i]) else { return nil }
                cells.append(c)
            }
            leftCells = Array(cells[0..<4])
            rightCells = Array(cells[4..<8])
            cursor += 8
        }

        // CoP 그룹: "-"(1토큰) 또는 {copx copy}(2토큰, 정수).
        var copX: Int? = nil
        var copY: Int? = nil
        guard cursor < tokens.count else { return nil }
        if tokens[cursor] == "-" {
            cursor += 1
        } else {
            guard tokens.count >= cursor + 2,
                  let cx = Int(tokens[cursor]), let cy = Int(tokens[cursor + 1])
            else { return nil }
            copX = cx; copY = cy
            cursor += 2
        }

        // 후행 고정 5: fallen risk vdV src loop.
        guard tokens.count >= cursor + 5 else { return nil }
        guard let fallen = Int(tokens[cursor]),
              let voltage = Int(tokens[cursor + 2]),
              let loop = Int(tokens[cursor + 4])
        else { return nil }
        guard voltage >= 0, fallen == -1 || fallen == 0 || fallen == 1 else { return nil }
        let riskTok = tokens[cursor + 1]
        let risk: Double? = (riskTok == "-") ? nil : Double(riskTok)
        let src = tokens[cursor + 3]
        let loopMs: Int? = loop >= 0 ? loop : nil
        let phaseOpt: Int? = phase >= 0 ? phase : nil

        return OnboardTelemetry(
            tsMs: tsMs,
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            accelX: accelX, accelY: accelY, accelZ: accelZ,
            voltageDeciVolts: voltage,
            walking: phaseOpt != nil,   // TEL2 엔 walking01 토큰이 없음 — 위상 유무로 추정.
            fallen: fallen,
            lastCmdId: seq > 0 ? "seq#\(seq)" : nil,
            loopMs: loopMs,
            isTel2: true, phase: phaseOpt, seqApplied: seq,
            latStrideMm: x, latSideMm: y, latTurnDeg: a, latPeriodMs: period,
            fsrLeftCells: leftCells, fsrRightCells: rightCells,
            copX: copX, copY: copY,
            riskDeg: risk, activeSource: src
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
