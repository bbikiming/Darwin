import Foundation

/// 사이클 V262-1 (Wave 4.1.2, ADR-002 Phase 4.1.2) — `WalkLabSession` 의 safety state
/// snapshot struct.
///
/// # 비유
///
/// 자동차의 계기판 + 경고등 묶음 — 균형 상태 게이지 (`balanceState`), 최근 안전
/// 이벤트 로그 (`safetyEvents`), 보행 시작 차단 사유 (`startBlockedReason` /
/// `lastPreflightFailure`), 그리고 sparkline 차트 source (`safetyTimeline`).
/// 이것들은 모두 "현재 안전 스냅샷" 이지만, 실제 IMU polling / preflight 평가 /
/// 모터 송출 결정 자체는 별개 시스템 (`WalkLabSession` lifecycle). 본 struct 는
/// 안전 dashboard 의 "현재 표시 값 묶음" 만 보관 — 평가 / 트리거 로직은 잔존.
///
/// # 분리 동기 (ADR-002 Phase 4.1.2)
///
/// 종전: `WalkLabSession` 안에 safety 관련 5개 stored property (`balanceState` /
/// `safetyTimeline` / `safetyEvents` / `lastPreflightFailure` / `startBlockedReason`)
/// 가 hardware-coupled state (status / IMU / pose-apply / fallPrevention) 와 혼재.
/// 변경 영향 추적 곤란.
///
/// 신규: `WalkSafetyState` 가 5개 safety property 만 보관 (pure data, hardware 무관).
/// `WalkLabSession` 가 `safetyState: WalkSafetyState` 로 보유 + 기존 5개 property 는
/// backward-compat computed delegate 로 transparent forwarding. 외부 view/test 코드
/// (`session.balanceState = .normal` 등) 전부 무수정.
///
/// # 책임 (pure data, lifecycle 없음)
///
/// - 자세 안정성 상태: `balanceState` (5단계 normal/caution/warning/danger/emergency)
/// - 안전 시계열 sample: `safetyTimeline` (sparkline 차트 source, 최근 10초 / max 250)
/// - 안전 이벤트 로그: `safetyEvents` (최근 50건, ring buffer)
/// - 마지막 preflight 실패 사유: `lastPreflightFailure`
/// - 보행 시작 차단 사유 코드: `startBlockedReason`
///
/// # 비-책임 (`WalkLabSession` 에 잔존)
///
/// - `preflightStatus` (computed property — store/bus/cradle 등 6 layer 종합 평가)
/// - `normalizedSafetyTimeline` (safetyTimeline 캐시 — 별도 lifecycle, 다음 wave)
/// - `emergencyStopActive` (별도 emergency lifecycle, 다음 wave)
/// - `previousBalanceState` 등 transition 검출 internal cache
///
/// `WalkLabSession` 의 computed delegate setter 가 `safetyState.foo = newValue` 한
/// 뒤 부수 효과 (logSafetyEvent / harness telemetry) 를 자체 트리거. 본 struct 는
/// pure mutation 만 — 부수 효과 0.
///
/// # 안전 자세 보존 (CRITICAL)
///
/// `WalkSafetyState.initial` default 값은 `WalkLabSession` 의 종전 5개 default 와
/// 완전 동일:
/// - balanceState = .normal (안전 baseline)
/// - safetyTimeline / safetyEvents = [] (빈 상태)
/// - lastPreflightFailure / startBlockedReason = nil (preflight 미시도 또는 통과)
///
/// preset 미선택 시 robot 정지 / 안정 자세 invariant 보존. 변경 금지.
///
/// # Codable
///
/// preset save/load 또는 session snapshot 직렬화 용. SafetyTimeline 50Hz tick 마다
/// append 되지만 struct copy 비용은 무시 가능 수준 (10Hz × max 250 samples,
/// value semantic 우선). 향후 `WalkLabSession.applyExperimentChange` 가 본 struct
/// 단위 swap / serialize 가능.
public struct WalkSafetyState: Sendable, Equatable, Codable {

    // MARK: - 자세 안정성 상태 (5단계)

    /// 현재 IMU 기반 안전 상태. `WalkLabSession+Tick` 의 tick() 마다 갱신
    /// (`BalanceState.from(maxTilt:)` 분류). default `.normal` — 안전 baseline.
    public var balanceState: WalkLabSession.BalanceState

    // MARK: - 안전 시계열 sample (sparkline 차트)

    /// 시계열 안전 sample buffer — 최근 10초 (10Hz tick × 100, max 250).
    /// `WalkLabSession+SafetySampling.recordSafetySampleAndEvents` 가 tick 마다 append.
    /// FallPreventionMonitor 의 sparkline 차트 source. start() reset 시 비움.
    public var safetyTimeline: [WalkLabSession.SafetySample]

    // MARK: - 안전 이벤트 로그

    /// 안전 이벤트 로그 — 최근 50건 (가장 최신이 last). 별도 보존 — start() reset
    /// 시에도 유지 (사용자가 이전 세션 이벤트를 후행 진단 가능). FallPreventionMonitor
    /// 의 events 리스트 source.
    public var safetyEvents: [WalkLabSession.SafetyEvent]

    // MARK: - 보행 시작 차단 정보

    /// 마지막 preflight 실패 payload. nil = preflight 미시도 / 통과 / 명시 reset.
    /// UI 가 토스트 / sidebar 에 표시. 로거 header 에도 기록.
    public var lastPreflightFailure: WalkLabSession.WalkPreflightFailure?

    /// preflight 차단 사유 진단 코드 — `WalkPreflightFailure.diagnosticCode` 의 캐시.
    /// 로거 header 의 `startBlockedReason` 필드. nil = preflight 통과 (성공 또는 미시도).
    public var startBlockedReason: String?

    // MARK: - Init (default = 안전 baseline)

    /// 모든 safety state 를 안전 baseline 으로 초기화.
    ///
    /// - balanceState = .normal (안정 자세)
    /// - safetyTimeline / safetyEvents = [] (빈 상태)
    /// - lastPreflightFailure / startBlockedReason = nil (preflight 미시도)
    public init(
        balanceState: WalkLabSession.BalanceState = .normal,
        safetyTimeline: [WalkLabSession.SafetySample] = [],
        safetyEvents: [WalkLabSession.SafetyEvent] = [],
        lastPreflightFailure: WalkLabSession.WalkPreflightFailure? = nil,
        startBlockedReason: String? = nil
    ) {
        self.balanceState = balanceState
        self.safetyTimeline = safetyTimeline
        self.safetyEvents = safetyEvents
        self.lastPreflightFailure = lastPreflightFailure
        self.startBlockedReason = startBlockedReason
    }

    /// 안전 baseline static — 모든 default 가 안전 상태.
    /// `WalkLabSession.safetyState` 의 초기 값 + start() reset 시 fallback.
    public static let initial: WalkSafetyState = WalkSafetyState()
}
