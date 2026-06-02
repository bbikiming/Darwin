import Foundation

/// **방법론 (Flight Data Recorder / robotics rosbag + closed-loop telemetry)**:
///
/// 실 robot + 조종기로 cockpit 을 테스트할 때, "무엇을 명령했고 robot 이 어떻게
/// 반응했는가" 의 쌍(pair) 데이터를 구조적으로 남겨 **추후 개선 시 근거**로
/// 사용한다. 드론/로봇의 black-box recorder 와 동일 철학 — 모든 입력·출력·자세를
/// 시간축에 기록해 사후 분석.
///
/// # 저장 구조 (분석 친화적 — flat JSONL)
///
/// ```
/// ~/Library/Application Support/DarwinForge/CockpitPilot/<sessionId>/
///   manifest.json      — 세션 시작 환경 (1 객체)
///   dispatches.jsonl   — 매 명령 1줄 (commanded↔effective↔IMU pair)
///   events.jsonl       — lifecycle 이벤트 1줄 (ARM/DISARM/E-Stop/…)
///   summary.json       — finalize 시 집계 (1 객체)
/// ```
///
/// enum + associated value 의 중첩 JSON 대신 **2개 flat JSONL** 로 분리 — pandas /
/// jq 로 바로 dataframe 로드 가능.
///
/// # 정직성 (거짓 없는 데이터)
///
/// - `realMotor`: 실 motor 송출 세션만 true. sim-only 는 false 로 태그 → 분석 필터.
/// - `commandedDistanceMm`: 속도 공식 적분값 (명령 기준). **측정 odometry 아님** —
///   robot 에 encoder 가 없으므로 "명령한 거리" 임을 명시. 필드명에 commanded 포함.
/// - `imuRollDeg/imuPitchDeg`: robot 연결 시 실 IMU, 미연결 시 0 (manifest 의
///   robotConnected 로 판별).

// MARK: - Manifest (세션 시작 환경)

public struct CockpitPilotManifest: Codable, Equatable, Sendable {
    /// 스키마 진화 대비 — 분석 코드가 버전별 분기 가능.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionId: String
    public var startedAtISO: String
    public var appVersion: String
    /// 실 motor 송출 활성 여부 (세션 시작 시점). 토글은 events 로도 기록.
    public var realMotor: Bool
    public var robotConnected: Bool
    public var dxlPowerOn: Bool
    /// 연결된 외부 컨트롤러 이름 (DJI / GameController). nil = 키보드/마우스.
    public var controllerName: String?
    public var balanceCorrectionAtStart: Bool

    public init(schemaVersion: Int = CockpitPilotManifest.currentSchemaVersion,
                sessionId: String,
                startedAtISO: String,
                appVersion: String,
                realMotor: Bool,
                robotConnected: Bool,
                dxlPowerOn: Bool,
                controllerName: String?,
                balanceCorrectionAtStart: Bool) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.startedAtISO = startedAtISO
        self.appVersion = appVersion
        self.realMotor = realMotor
        self.robotConnected = robotConnected
        self.dxlPowerOn = dxlPowerOn
        self.controllerName = controllerName
        self.balanceCorrectionAtStart = balanceCorrectionAtStart
    }
}

// MARK: - Dispatch record (명령 1건 — closed-loop pair)

public struct CockpitPilotDispatch: Codable, Equatable, Sendable {
    /// 세션 시작 기준 경과 ms.
    public var tMs: Double
    /// 입력 source — keyboard / djiRC / virtualJoystick / gameController.
    public var source: String

    // 사용자가 명령한 raw amplitude (mapper 출력, clamp 전).
    public var cmdStrideMm: Double
    public var cmdSideMm: Double
    public var cmdTurnDeg: Double
    public var periodMs: Double

    // 실 motor 가 받는 effective amplitude (mobileFreeformClamp 후).
    // cmd 와 다르면 clamp 로 손실된 입력 — 분석 시 "사용자 의도 vs 실제 송출" 비교.
    public var effStrideMm: Double
    public var effSideMm: Double
    public var effTurnDeg: Double

    /// ROBOTIS Walking 공식: eff stride × 2000 / periodMs (mm/sec).
    public var robotSpeedMmPerSec: Double

    /// **closed-loop pair**: 명령 시점 robot 자세 (실 IMU, robot 연결 시).
    public var imuRollDeg: Double
    public var imuPitchDeg: Double

    public var balanceOn: Bool
    /// facade 가 수락 (true) 또는 거부 (false — emergency / 다른 보행 활성 등).
    public var accepted: Bool
    /// 차단 사유. nil = gate 통과 정상 송출.
    public var gateReason: String?

    public init(tMs: Double, source: String,
                cmdStrideMm: Double, cmdSideMm: Double, cmdTurnDeg: Double,
                periodMs: Double,
                effStrideMm: Double, effSideMm: Double, effTurnDeg: Double,
                robotSpeedMmPerSec: Double,
                imuRollDeg: Double, imuPitchDeg: Double,
                balanceOn: Bool, accepted: Bool, gateReason: String?) {
        self.tMs = tMs
        self.source = source
        self.cmdStrideMm = cmdStrideMm
        self.cmdSideMm = cmdSideMm
        self.cmdTurnDeg = cmdTurnDeg
        self.periodMs = periodMs
        self.effStrideMm = effStrideMm
        self.effSideMm = effSideMm
        self.effTurnDeg = effTurnDeg
        self.robotSpeedMmPerSec = robotSpeedMmPerSec
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
        self.balanceOn = balanceOn
        self.accepted = accepted
        self.gateReason = gateReason
    }
}

// MARK: - Event record (lifecycle)

public enum CockpitPilotEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case autoArm
    case autoDisarm
    case eStop
    case recover
    case maxDuration
    case preflightFail
    case balanceOn
    case balanceOff
    case realMotorOn
    case realMotorOff
    case headMove
    case sessionEnd
}

public struct CockpitPilotEvent: Codable, Equatable, Sendable {
    public var tMs: Double
    public var kind: CockpitPilotEventKind
    public var detail: String?

    public init(tMs: Double, kind: CockpitPilotEventKind, detail: String? = nil) {
        self.tMs = tMs
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - Summary (finalize 집계 — 순수 함수)

public struct CockpitPilotSummary: Codable, Equatable, Sendable {
    public var sessionId: String
    public var durationMs: Double
    public var dispatchCount: Int
    public var acceptedCount: Int
    public var rejectedCount: Int
    public var peakSpeedMmPerSec: Double
    public var meanSpeedMmPerSec: Double
    /// 명령 기준 적분 거리 (측정 odometry 아님 — 정직 명시).
    public var commandedDistanceMm: Double
    public var eStopCount: Int
    public var autoArmCount: Int
    public var autoDisarmCount: Int
    public var maxDurationCount: Int
    public var preflightFailCount: Int
    /// balanceOn dispatch 비율 (%) — 자이로 보정 사용 시간 비중.
    public var balanceDutyPercent: Double
    public var peakAbsRollDeg: Double
    public var peakAbsPitchDeg: Double
    /// gate 거부 사유별 횟수 — 신뢰성 분석.
    public var gateReasonHistogram: [String: Int]

    /// **순수 함수** — dispatches + events 로부터 집계. 단위 테스트로 정확성 검증.
    ///
    /// - `commandedDistanceMm`: 인접 dispatch 사이 사다리꼴 적분
    ///   `Σ ((v[i]+v[i-1])/2) × dt`. accepted dispatch 만 (실제 송출된 명령).
    public static func compute(sessionId: String,
                               dispatches: [CockpitPilotDispatch],
                               events: [CockpitPilotEvent],
                               endTMs: Double) -> CockpitPilotSummary {
        let accepted = dispatches.filter { $0.accepted }
        let speeds = accepted.map { abs($0.robotSpeedMmPerSec) }
        let peak = speeds.max() ?? 0
        let movingSpeeds = speeds.filter { $0 > 0.01 }
        let mean = movingSpeeds.isEmpty
            ? 0
            : movingSpeeds.reduce(0, +) / Double(movingSpeeds.count)

        // 사다리꼴 적분 — accepted dispatch 의 시간순 speed.
        var distance = 0.0
        let ordered = accepted.sorted { $0.tMs < $1.tMs }
        for i in 1..<max(1, ordered.count) {
            let dtSec = (ordered[i].tMs - ordered[i - 1].tMs) / 1000.0
            guard dtSec > 0, dtSec < 5.0 else { continue }   // gap / 비정상 무시
            let v0 = abs(ordered[i - 1].robotSpeedMmPerSec)
            let v1 = abs(ordered[i].robotSpeedMmPerSec)
            distance += (v0 + v1) / 2.0 * dtSec
        }

        let balanceOnCount = accepted.filter { $0.balanceOn }.count
        let balanceDuty = accepted.isEmpty
            ? 0
            : Double(balanceOnCount) / Double(accepted.count) * 100.0

        let peakRoll = dispatches.map { abs($0.imuRollDeg) }.max() ?? 0
        let peakPitch = dispatches.map { abs($0.imuPitchDeg) }.max() ?? 0

        var histogram: [String: Int] = [:]
        for d in dispatches where !d.accepted {
            let reason = d.gateReason ?? "unknown"
            histogram[reason, default: 0] += 1
        }

        func eventCount(_ kind: CockpitPilotEventKind) -> Int {
            events.filter { $0.kind == kind }.count
        }

        return CockpitPilotSummary(
            sessionId: sessionId,
            durationMs: endTMs,
            dispatchCount: dispatches.count,
            acceptedCount: accepted.count,
            rejectedCount: dispatches.count - accepted.count,
            peakSpeedMmPerSec: peak,
            meanSpeedMmPerSec: mean,
            commandedDistanceMm: distance,
            eStopCount: eventCount(.eStop),
            autoArmCount: eventCount(.autoArm),
            autoDisarmCount: eventCount(.autoDisarm),
            maxDurationCount: eventCount(.maxDuration),
            preflightFailCount: eventCount(.preflightFail),
            balanceDutyPercent: balanceDuty,
            peakAbsRollDeg: peakRoll,
            peakAbsPitchDeg: peakPitch,
            gateReasonHistogram: histogram)
    }

    public init(sessionId: String, durationMs: Double, dispatchCount: Int,
                acceptedCount: Int, rejectedCount: Int,
                peakSpeedMmPerSec: Double, meanSpeedMmPerSec: Double,
                commandedDistanceMm: Double, eStopCount: Int,
                autoArmCount: Int, autoDisarmCount: Int, maxDurationCount: Int,
                preflightFailCount: Int, balanceDutyPercent: Double,
                peakAbsRollDeg: Double, peakAbsPitchDeg: Double,
                gateReasonHistogram: [String: Int]) {
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.dispatchCount = dispatchCount
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.peakSpeedMmPerSec = peakSpeedMmPerSec
        self.meanSpeedMmPerSec = meanSpeedMmPerSec
        self.commandedDistanceMm = commandedDistanceMm
        self.eStopCount = eStopCount
        self.autoArmCount = autoArmCount
        self.autoDisarmCount = autoDisarmCount
        self.maxDurationCount = maxDurationCount
        self.preflightFailCount = preflightFailCount
        self.balanceDutyPercent = balanceDutyPercent
        self.peakAbsRollDeg = peakAbsRollDeg
        self.peakAbsPitchDeg = peakAbsPitchDeg
        self.gateReasonHistogram = gateReasonHistogram
    }
}
