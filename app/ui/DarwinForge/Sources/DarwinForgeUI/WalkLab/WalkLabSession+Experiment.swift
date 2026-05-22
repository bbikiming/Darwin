import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 97: god object Phase 2 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` (4331 line) 의 A/B 실험 system (~270 line) 을 본 extension 으로
/// 이동 — Phase 2 plan 의 가장 큰 단일 분할. stored property 4개 (`activeExperimentId` /
/// `activeBaselineSessionId` / `experimentLoop` / `rollbackSnapshot`) 는 Swift extension
/// 제약으로 본체 잔존 — type / method 만 이동.
///
/// # 비유
///
/// 큰 실험실의 "A/B 비교 시험" 부서만 별도 시험관으로 이전. 시험 등록부 (state) 는 본
/// 실험실 캐비넷에 잔존, 시험 절차 (method) 와 시험서식 (struct) 만 이전. 시험관은
/// 캐비넷에 internal access 로 등록 / 회수.
///
/// # 분할 정책
///
/// - **stored property 본체 잔존** (Swift 제약): `activeExperimentId` / `activeBaselineSessionId` /
///   `experimentLoop` / `rollbackSnapshot`.
/// - 본 cycle 에서 `rollbackSnapshot` 의 `public private(set)` → `public internal(set)` 으로
///   access 격상 — extension 의 write 허용 + 외부 API 는 read-only 유지.
/// - `activeExperimentId` / `activeBaselineSessionId` 는 이미 `public var` (외부 RW) — 변경 없음.
/// - `experimentLoop` 도 이미 `public weak var` — 변경 없음.
/// - method / nested type 이동: `ExperimentDeltas` / `ExperimentSnapshot` / `ApplyExperimentResult` /
///   `setExperimentLoop(_:)` / `applyExperimentChange(...)` / `clearExperimentContext()` /
///   `rollbackExperiment()` / `onboardHealthCheckWarnings()` / `onboardHealthCheckWarningsImpl(...)`.
///
/// # 핵심 invariant
///
/// - `rollbackExperiment` 가 본체 `stop()` 호출 — 본체 잔존 method 와 의존성 유지.
/// - experiment 가 `balanceExperimentConfig` 등 mutable axis mutate — 본체 setter (이미
///   internal/public) 접근.
/// - 외부 caller (`ExperimentLoopController` / `WalkDataView` / `ActiveExperimentBanner` /
///   `RootView`) signature 보존 — nested type 은 `WalkLabSession.ExperimentDeltas` 등 그대로.
///
/// # 회귀
///
/// 1267 tests 회귀 0 — 외부 API 변경 0 (read 시 동일, write 는 module 내부만).
extension WalkLabSession {

    /// **v1.11.14.1**: critic 이 제안 가능한 모든 non-config axis 의 delta.
    /// nil = 변경 없음 (현재값 유지). 한 번에 1개만 non-nil 이어야 changeOneAxisOnly 준수.
    /// **v1.11.14.5 (2026-05-19)**: walkingEngine + enableBalanceCorrection 추가.
    /// 종전엔 ResponseAxis 에는 있지만 applyExperimentChange 가 적용 안 함 — silent
    /// no-op (critic 이 "ROBOTIS onboard 로 바꿔라" 권고해도 변화 X).
    public struct ExperimentDeltas: Sendable, Equatable {
        public var hipPitchOffsetTrimDeg: Double? = nil
        public var strideMm: Double? = nil
        public var sideMm: Double? = nil
        public var turnDeg: Double? = nil
        public var customPeriodMs: Double? = nil
        public var footHeightMm: Double? = nil
        public var balanceGain: Double? = nil
        public var customHipRollGain: Double? = nil
        public var customKneeGain: Double? = nil
        public var customAnklePitchGain: Double? = nil
        public var customAnkleRollGain: Double? = nil
        public var walkingEngine: WalkingEngine? = nil
        public var enableBalanceCorrection: Bool? = nil

        public init() {}

        /// 모든 delta 가 nil 인 경우 — config axis 변경만 적용.
        public var isEmpty: Bool {
            hipPitchOffsetTrimDeg == nil && strideMm == nil && sideMm == nil
                && turnDeg == nil && customPeriodMs == nil && footHeightMm == nil
                && balanceGain == nil && customHipRollGain == nil && customKneeGain == nil
                && customAnklePitchGain == nil && customAnkleRollGain == nil
                && walkingEngine == nil && enableBalanceCorrection == nil
        }

        /// tuning slider (stride/side/turn/period/foot/balanceGain) 가 포함되면 true.
        /// applyExperimentChange 에서 session.advanced 자동 true 강제 — 종전엔 advanced=false
        /// 면 currentWalkTuning 이 preset default 사용해 silent no-op 였음.
        public var hasTuningSlider: Bool {
            strideMm != nil || sideMm != nil || turnDeg != nil
                || customPeriodMs != nil || footHeightMm != nil || balanceGain != nil
        }
    }

    /// **v1.11.14.5 (2026-05-19) — 사용자 평가 CRIT 1 fix**: rollback snapshot.
    /// applyExperimentChange 직전 모든 mutable axis 값 저장. failRollback verdict 시
    /// 또는 사용자 명시 rollback 호출 시 복원.
    public struct ExperimentSnapshot: Sendable {
        public let balanceExperimentConfig: BalanceExperimentConfig
        public let hipPitchOffsetTrimDeg: Double
        public let strideMm: Double
        public let sideMm: Double
        public let turnDeg: Double
        public let customPeriodMs: Double
        public let footHeightMm: Double
        public let balanceGain: Double
        public let customHipRollGain: Double
        public let customKneeGain: Double
        public let customAnklePitchGain: Double
        public let customAnkleRollGain: Double
        public let walkingEngine: WalkingEngine
        public let enableBalanceCorrection: Bool
        public let advanced: Bool
    }

    public enum ApplyExperimentResult: Sendable {
        case applied
        case failed(reason: String)
    }

    /// RootView 또는 외부 caller 가 controller 주입.
    /// **v1.11.14.1**: controller.onCleared callback 등록 — finalize/cancel 시 자동
    /// clearExperimentContext 호출. 종전엔 activeExperimentId 가 leak 되어 다음 일반
    /// 보행도 experiment 로 인식되는 버그.
    public func setExperimentLoop(_ controller: ExperimentLoopController?) {
        self.experimentLoop = controller
        controller?.onCleared = { [weak self] in
            self?.clearExperimentContext()
        }
    }

    /// **v1.11.14**: ExperimentApprovalUI 가 사용자 승인 후 호출. axis 한 개만 변경.
    /// **v1.11.14.1**: deltas struct 도입 — tuning slider + customGain* axis 통합.
    /// - safetyVerdict.blocked → reject (deterministic gate)
    /// - 활성 실험 진행 중이면 reject (reentry 가드)
    /// - changeOneAxisOnly invariant — 호출자가 axis 하나만 변경한 config 전달 책임
    public func applyExperimentChange(
        experimentId: String,
        baselineSessionId: String,
        proposedConfig: BalanceExperimentConfig,
        deltas: ExperimentDeltas = ExperimentDeltas()
    ) -> ApplyExperimentResult {
        if case .blocked(let reason) = proposedConfig.safetyVerdict {
            return .failed(reason: "safetyVerdict.blocked — \(reason)")
        }
        // **v1.11.14.1**: reentry 가드 — 활성 실험 진행 중에 새 실험 적용 차단.
        // 종전엔 activeExperimentId 덮어쓰기 + leak 으로 이전 실험 데이터 추적 단절.
        if let existing = activeExperimentId {
            return .failed(reason: "이미 활성 실험 (\(existing)) — 종료 후 재시도")
        }
        // **v1.11.14.6 (2026-05-19) — cold 3차 추가 HIGH fix**: walkingEngine 변경 시
        // 보행 중이면 reject. didSet 이 walkCycleTask cancel 안 하므로, 보행 도중
        // engine 변경하면 이전 engine 의 task 가 진행 + 새 명령은 새 engine 으로 →
        // 불일치 / 충돌 위험. 사용자가 명시 stop 후 재승인하도록 강제.
        if deltas.walkingEngine != nil, current != .idle {
            return .failed(reason: "walkingEngine 변경은 보행 중 적용 불가 — 정지 (idle) 후 재시도")
        }
        // **v1.11.14.5 — 사용자 평가 CRIT 1 fix**: rollback snapshot 저장 (mutation 전).
        rollbackSnapshot = ExperimentSnapshot(
            balanceExperimentConfig: balanceExperimentConfig,
            hipPitchOffsetTrimDeg: hipPitchOffsetTrimDeg,
            strideMm: strideMm, sideMm: sideMm, turnDeg: turnDeg,
            customPeriodMs: customPeriodMs, footHeightMm: footHeightMm,
            balanceGain: balanceGain,
            customHipRollGain: customHipRollGain, customKneeGain: customKneeGain,
            customAnklePitchGain: customAnklePitchGain, customAnkleRollGain: customAnkleRollGain,
            walkingEngine: walkingEngine,
            enableBalanceCorrection: enableBalanceCorrection,
            advanced: advanced
        )
        // 실제 config 변경.
        balanceExperimentConfig = proposedConfig
        // v1.11.14.1: 모든 non-config axis delta 적용 (nil 인 axis 는 현재값 유지).
        if let v = deltas.hipPitchOffsetTrimDeg { hipPitchOffsetTrimDeg = v }
        if let v = deltas.strideMm { strideMm = v }
        if let v = deltas.sideMm { sideMm = v }
        if let v = deltas.turnDeg { turnDeg = v }
        if let v = deltas.customPeriodMs { customPeriodMs = v }
        if let v = deltas.footHeightMm { footHeightMm = v }
        if let v = deltas.balanceGain { balanceGain = v }
        if let v = deltas.customHipRollGain { customHipRollGain = v }
        if let v = deltas.customKneeGain { customKneeGain = v }
        if let v = deltas.customAnklePitchGain { customAnklePitchGain = v }
        if let v = deltas.customAnkleRollGain { customAnkleRollGain = v }
        // **v1.11.14.5 — 사용자 평가 HIGH 2 fix**: walkingEngine + enableBalanceCorrection
        // 도 실 적용. 종전엔 ResponseAxis 에 있지만 silent no-op.
        if let v = deltas.walkingEngine { walkingEngine = v }
        if let v = deltas.enableBalanceCorrection { enableBalanceCorrection = v }
        // **v1.11.14.5 — 사용자 평가 HIGH 3 fix**: tuning slider delta 있으면 advanced=true.
        // 종전엔 advanced=false 시 currentWalkTuning 이 preset default 사용 → 데이터상
        // "실험 적용" 처럼 보이지만 실 보행은 거의 그대로. critic 의 강건한 비교 차단.
        if deltas.hasTuningSlider {
            advanced = true
        }
        activeExperimentId = experimentId
        activeBaselineSessionId = baselineSessionId
        logSafetyEvent(
            kind: .correctorOn,
            message: "실험 적용: \(experimentId) (baseline=\(baselineSessionId))"
        )
        return .applied
    }

    /// **v1.11.14**: 실험 종료 (사용자 명시 또는 finalize).
    /// **v1.11.14.5**: rollbackSnapshot 도 clear — 사용자가 변경 결과 수락한 것으로 간주.
    /// 종전엔 snapshot 남아있어 다음 applyExperimentChange 가 다른 baseline 으로 잘못
    /// 복원할 위험. 사용자가 rollback 원하면 rollbackExperiment() 명시 호출 필요.
    public func clearExperimentContext() {
        activeExperimentId = nil
        activeBaselineSessionId = nil
        rollbackSnapshot = nil
    }

    /// **v1.11.14.7 (2026-05-19)** — ROBOTIS Onboard 모드 health check.
    /// startWalkCycle 의 onboard 분기에서 호출 — 잠재 silent failure 감지.
    /// 반환: 경고 문자열 배열 (빈 배열 = 정상).
    ///
    /// 체크 항목:
    /// 1. ConnectionStore 의 SSH 채널 연결 (lastTelemetry.isRealRobot)
    /// 2. autoOnboardBrokering 활성 여부
    /// 3. 보행 명령 enabled 여부 (cradle confirmed)
    nonisolated internal func onboardHealthCheckWarningsImpl(
        isRobotConnected: Bool,
        autoOnboardOn: Bool,
        cradleOK: Bool
    ) -> [String] {
        var warnings: [String] = []
        if !isRobotConnected {
            warnings.append("실 robot SSH 미연결 — onboard 명령 silent fail 위험")
        }
        if !autoOnboardOn {
            warnings.append("autoOnboardBrokering=OFF — 명령 수동 송출 필요")
        }
        if !cradleOK {
            warnings.append("cradle 미확인 — 안전 절차 위반 가능")
        }
        return warnings
    }

    /// MainActor instance helper — startWalkCycle 에서 호출.
    func onboardHealthCheckWarnings() -> [String] {
        let isRobotConnected: Bool = {
            // ConnectionStore.lastTelemetry?.isRealRobot — store 가 nil 일 수 있음.
            guard let store = self.store else { return false }
            return store.bus != nil
        }()
        return onboardHealthCheckWarningsImpl(
            isRobotConnected: isRobotConnected,
            autoOnboardOn: autoOnboardBrokering,
            cradleOK: cradleConfirmed
        )
    }

    /// **v1.11.14.5 (2026-05-19) — 사용자 평가 CRIT 1 fix**: 변경 원상복구.
    /// applyExperimentChange 가 저장한 snapshot 으로 모든 axis 복원 + activeExperimentId
    /// clear. failRollback verdict 시 자동 호출 또는 사용자 명시 호출.
    /// snapshot 없으면 no-op.
    /// **v1.11.14.6 (2026-05-19)**: ExperimentLoopController.current 도 cancel.
    /// 종전엔 session 측만 clear → controller.current 살아있어 사용자가 새 실험 시도
    /// 시 controller.startExperiment 가 reject (current != nil). silent UX failure.
    @discardableResult
    public func rollbackExperiment() -> Bool {
        guard let snapshot = rollbackSnapshot else { return false }
        // **v1.11.14.7 (2026-05-19) — 사용자 평가 CRIT fix**: 보행 중 rollback 시
        // walkCycleTask 자동 stop + walkReady 복귀. 종전: rollback 이 config 만 복원,
        // walkCycleTask 는 이전 walkingEngine 으로 계속 진행 → 불일치 + 안전 위험.
        // **사이클 61**: 중복 복합 술어 → `isActuallyWalking` 단일 source 로 위임.
        let wasWalking = isActuallyWalking
        if wasWalking {
            stop()  // walkCycleTask cancel + walkReady 복귀 + onboard cleanup.
            logSafetyEvent(
                kind: .sessionStop,
                message: "🔄 rollback 직전 자동 stop — 안전한 config 복원"
            )
        }
        balanceExperimentConfig = snapshot.balanceExperimentConfig
        hipPitchOffsetTrimDeg = snapshot.hipPitchOffsetTrimDeg
        strideMm = snapshot.strideMm
        sideMm = snapshot.sideMm
        turnDeg = snapshot.turnDeg
        customPeriodMs = snapshot.customPeriodMs
        footHeightMm = snapshot.footHeightMm
        balanceGain = snapshot.balanceGain
        customHipRollGain = snapshot.customHipRollGain
        customKneeGain = snapshot.customKneeGain
        customAnklePitchGain = snapshot.customAnklePitchGain
        customAnkleRollGain = snapshot.customAnkleRollGain
        walkingEngine = snapshot.walkingEngine
        enableBalanceCorrection = snapshot.enableBalanceCorrection
        advanced = snapshot.advanced
        let expId = activeExperimentId ?? "?"
        activeExperimentId = nil
        activeBaselineSessionId = nil
        rollbackSnapshot = nil
        // v1.11.14.6: controller 도 cancel — onCleared callback 이 다시 호출되지만
        // activeExperimentId 이미 nil 이라 idempotent. controller.current=nil 보장으로
        // 사용자가 새 실험 시도 가능.
        if let controller = experimentLoop {
            Task { @MainActor in
                await controller.cancel()
            }
        }
        logSafetyEvent(
            kind: .correctorOff,
            message: "🔄 실험 rollback: \(expId) → 변경 전 상태 복원"
        )
        lastRobotEvent = "🔄 실험 rollback — 변경 전 config 복원됨"
        return true
    }
}
