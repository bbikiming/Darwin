import Foundation
import ForgeCore

/// **사이클 V281-3 (Wave 4.1.4, ADR-002) — WalkLabRecorder 추출**.
///
/// `WalkLabSession.swift` 의 session-logger / sample buffer / persist 책임을
/// 별도 type 으로 추출. 50Hz tick 의 logger / sparse-cadence tracker 등 logging-
/// only state 가 robot control 과 혼재되어 god object 가속되던 문제 분리.
///
/// # 비유
///
/// 운동 코치의 노트북. 선수 (WalkLabSession) 가 운동 중일 때 50Hz tick 마다
/// 코치가 데이터 기록 — 노트북 (sample buffer) + 펜 (logger) + 정리
/// (finalize) 가 한 묶음. 운동 자체 (motor control / balance correction) 는
/// 선수 몫.
///
/// # 책임 (이전 from WalkLabSession)
///
/// - **sessionLogger lifecycle** — start (extension 에서 set) / append /
///   finalize 시 nil 화
/// - **sessionStartedAt** — sample timestamp 계산 위한 시작 시각
/// - **cycleStartedAt** — walking cycle 시작 시각 (Hybrid phase 계산용,
///   BalanceCorrection 도 read)
/// - **sparse-cadence trackers** — `lastLoggedTelemetryAt` /
///   `lastLoggedImuSequence` / `lastLoggedJointFailures` (50Hz 마다 같은
///   telemetry 중복 dump 차단)
///
/// # 비-책임 (WalkLabSession 잔존)
///
/// - 실 motor 송출 / balance correction / safety gate / UI state
/// - logger 의 _생성_ (swcInitSessionLogger) — preset / experiment context 가
///   WalkLabSession state 라 본체 잔존
/// - `appendSessionSampleIfLogging` 본체 method — sample 의 70+ field 가
///   WalkLabSession state read 라 본체 잔존 (recorder 가 append() 만 제공)
///
/// # Actor 선택 이유
///
/// `@MainActor final class` (actor 가 아님).
///
/// - WalkLabSession 자체가 `@MainActor` → 동일 isolation 에서 await 비용 0
/// - 50Hz tick 안 `await recorder.append(...)` 도입 시 message-passing
///   overhead — `actor` 채택 시 timing-baseline 의 P99 < 5ms gate 위협
/// - 책임 분리는 stored property + method 이동만으로 달성 — concurrency
///   격리는 필요 없음
/// - 추후 실측에서 50Hz 부하 발견 시 `actor` 로 migrate 검토 (W4.1.4 후속)
///
/// # backward-compat
///
/// 외부 caller (tests 의 `session.sessionLogger = logger` 등) 보존 위해
/// `WalkLabSession` 에 5개 computed delegate (`sessionLogger` /
/// `sessionStartedAt` / `cycleStartedAt` / sparse 3개) get+set 노출.
@MainActor
public final class WalkLabRecorder {

    // MARK: - Session lifecycle state

    /// 활성 session 의 logger. nil = 보행 중 아님 또는 logging OFF.
    /// **이전 from WalkLabSession.sessionLogger** (V281-3, Wave 4.1.4).
    /// extension 의 `swcInitSessionLogger` 가 set, `finalizeSessionLog` 가
    /// nil 처리. `WalkLabSession+Trials.swift` 가 finalize 시 sessionId /
    /// filePath / sampleCount 추출 위해 read 함 — internal 유지.
    var sessionLogger: WalkSessionLogger?

    /// session 시작 시각 — sample timestamp 계산.
    /// **이전 from WalkLabSession.sessionStartedAt** (V281-3, Wave 4.1.4).
    /// `swcInitSessionLogger` 가 `logger.startedAt` 와 sync 로 set —
    /// summary.id 와 jsonl filename 일치 보장.
    var sessionStartedAt: Date?

    /// walking cycle 시작 시각. session 전체 시각 (`sessionStartedAt`) 과
    /// 별개 — Hybrid phase-locked correction 의 정확한 phase 계산용.
    /// `runContinuousWalk` 진입 시 갱신, cycle 가 연속이므로 cycle 종료 시
    /// 갱신 안 함 (truncatingRemainder 로 wrap).
    /// **이전 from WalkLabSession.cycleStartedAt** (V281-3, Wave 4.1.4).
    /// `WalkLabSession+BalanceCorrection.swift` 의 hybrid 경로가 read,
    /// `finalizeSessionLog` 가 nil 처리.
    var cycleStartedAt: Date?

    // MARK: - Sparse-cadence trackers

    // sample size 폭증 방지 (audit #54 robot-Z) — 매 tick 마다 18 joint ×
    // 7 field 를 저장하면 30분 = ~54MB. 대신 telemetry tick 새 데이터
    // 도착 시에만 jointStates 채움.

    /// 마지막 jointStates dump 시점의 lastTelemetry.timestamp — 같은
    /// telemetry 면 nil 로 두어 size 절약.
    /// **이전 from WalkLabSession.lastLoggedTelemetryAt** (V281-3).
    var lastLoggedTelemetryAt: Date?

    /// 마지막 dump 시점의 imuSequenceCount — 같은 IMU read 면 raw 6축 nil
    /// 로 처리.
    /// **이전 from WalkLabSession.lastLoggedImuSequence** (V281-3).
    var lastLoggedImuSequence: UInt32?

    /// 이전 tick 의 per-joint failure counter — 변화한 joint 만 sparse
    /// dump.
    /// **이전 from WalkLabSession.lastLoggedJointFailures** (V281-3).
    var lastLoggedJointFailures: [JointID: Int] = [:]

    // MARK: - init

    /// 기본 init — 모든 state nil/empty 로 시작. WalkLabSession init 에서
    /// 단 1회 호출.
    public init() {}

    // MARK: - Cycle lifecycle

    /// walking cycle 시작 시 호출. `cycleStartedAt` 만 갱신 — logger 생성은
    /// 별도 (`swcInitSessionLogger` 본체 잔존).
    /// **v1.11 (Codex 2nd review MEDIUM-B fix)** 동작 보존: logging 여부와
    /// 무관하게 walk start 시 항상 set.
    func markCycleStarted(at date: Date = Date()) {
        cycleStartedAt = date
    }

    /// finalize 후 sparse trackers reset. v1.11.25 audit robot-A/B/C 대응.
    /// `finalizeSessionLog` 의 cleanup phase 위임 helper.
    func resetSparseTrackers() {
        lastLoggedTelemetryAt = nil
        lastLoggedImuSequence = nil
        lastLoggedJointFailures = [:]
    }

    /// finalize 시 logger / sessionStartedAt nil 화 + sparse trackers reset
    /// 묶음 helper. `cycleStartedAt` 은 본체에서 defer 로 별도 처리 (logger
    /// 존재 여부와 무관하게 항상 cleanup — v1.11 Codex 3rd review fix).
    func clearSessionState() {
        sessionLogger = nil
        sessionStartedAt = nil
        resetSparseTrackers()
    }
}
