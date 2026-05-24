import Foundation
import SwiftUI

/// 사이클 V276-2 (Wave 4.1.3, ADR-002 Phase 4.1.3) — `WalkLabSession` 의 A/B
/// experiment lifecycle controller class.
///
/// # 비유
///
/// 자동차 시험장의 측정 컴퓨터 — 실험 시작 시점 (`activeExperimentId`) /
/// baseline session 기록 (`activeBaselineSessionId`) / rollback snapshot 보관
/// (`rollbackSnapshot`) / loop controller (`experimentLoop`) 을 관리. 실제
/// motor command / IMU sample 자체는 본체 (`WalkLabSession`) 가 처리하고,
/// 본 controller 는 실험 metadata 와 안전망 (snapshot) 만 보관.
///
/// # 분리 동기 (ADR-002 Phase 4.1.3)
///
/// 종전: `WalkLabSession` (2417 LOC) 안에 experiment 관련 stored property 4개
/// (`activeExperimentId` / `activeBaselineSessionId` / `experimentLoop` /
/// `rollbackSnapshot`) 와 method 본체 (~270 LOC) 가 hardware-coupled state
/// (status / IMU / pose-apply / safety sampling / fallPrevention) 와 혼재.
/// V275-2 분석에서 god object 분해 후보 A 로 선정.
///
/// 신규: `ExperimentController` 가 stored property 4개 만 보관 + 본체는 `var
/// experimentCtl: ExperimentController` 로 보유 + 기존 4개 stored property 는
/// backward-compat computed delegate 로 transparent forwarding. 외부 view/test
/// 코드 (`session.activeExperimentId` / `session.applyExperimentChange(...)` 등)
/// 전부 무수정.
///
/// # 책임 (lifecycle metadata + safety net)
///
/// - 실험 식별: `activeExperimentId`, `activeBaselineSessionId`
/// - rollback 안전망: `rollbackSnapshot` 저장 / 복원
/// - 실험 loop 관리: `experimentLoop` 시작 / 중단 (`ExperimentLoopController` weak ref)
///
/// # 비-책임 (`WalkLabSession` 에 잔존)
///
/// 다음은 본 controller 에 옮기지 않는다 — hardware-coupled side effect 필요:
/// - 실 walk cycle 송출 (`startWalkCycle` / `runWalkCycle`)
/// - balance correction 적용 (`makeCorrector` / `balanceCorrector`)
/// - sample logging (`logSafetyEvent` / `harness.record`)
/// - axis mutation 자체 (controller 는 metadata 만 — axis snapshot 생성 / 복원은
///   `WalkLabSession+Experiment` extension method 가 본체 property 직접 mutate)
///
/// # 안전 자세 보존 (CRITICAL)
///
/// `ExperimentController()` default 는 모든 nil — 종전 4개 stored property default 와
/// 완전 동일 (실험 미시작 상태). 변경 금지.
///
/// # weak session reference (reference cycle 차단)
///
/// `session` 은 weak — `WalkLabSession.experimentCtl` 이 strong ref 보유, controller
/// 의 `session` 이 strong 이면 retain cycle. 본체 deinit 시 controller 도 폐기 →
/// session weak 가 nil 자동 set. backward-compat method 들은 session weak unwrap
/// 후 동작.
@MainActor
public final class ExperimentController {

    // MARK: - Stored properties (4개 이전 — V275-2 분석 식별)

    /// **v1.11.14 (2026-05-19)** — A/B 실험 컨텍스트 (사용자 명시 승인 후 set).
    /// `nil` = 일반 보행 (실험 X). Logger header 의 experimentId 로 기록.
    public var activeExperimentId: String?

    /// baseline session id — applyExperimentChange 호출 시 set, 실험 종료 시 clear.
    /// Logger header 의 baselineSessionId 로 기록.
    public var activeBaselineSessionId: String?

    /// **v1.11.14**: ExperimentLoopController weak ref — 세션 종료 시 자동 폐루프.
    /// RootView 가 setExperimentLoop(_:) 로 inject. weak 라 actor lifecycle 의존성 없음.
    public weak var experimentLoop: ExperimentLoopController?

    /// rollback 용 snapshot. applyExperimentChange 가 set, rollbackExperiment 또는
    /// clearExperimentContext 가 clear.
    public var rollbackSnapshot: WalkLabSession.ExperimentSnapshot?

    // MARK: - Session reference (weak — retain cycle 차단)

    /// 본체 `WalkLabSession` weak ref. controller 의 lifecycle 은 본체에 종속 —
    /// 본체 deinit 시 controller 도 폐기 + session weak 자동 nil.
    public weak var session: WalkLabSession?

    // MARK: - Init

    /// 기본 init — 모든 stored property nil. session 은 본체가 init 직후 주입.
    public init(session: WalkLabSession? = nil) {
        self.activeExperimentId = nil
        self.activeBaselineSessionId = nil
        self.experimentLoop = nil
        self.rollbackSnapshot = nil
        self.session = session
    }

    // MARK: - Pure metadata helpers (session 비의존)

    /// 실험 metadata 전체 clear — `clearExperimentContext` / `rollbackExperiment` 가
    /// 공통 호출. session 의 axis 복원 책임은 호출자 (WalkLabSession+Experiment) 에 잔존.
    ///
    /// **v1.11.14.5 (2026-05-19)**: rollbackSnapshot 도 함께 clear — 사용자가 변경 결과
    /// 수락한 것으로 간주. 사용자가 rollback 원하면 rollbackExperiment() 명시 호출 필요.
    public func clearAllMetadata() {
        activeExperimentId = nil
        activeBaselineSessionId = nil
        rollbackSnapshot = nil
    }

    /// 활성 실험 ID 가 있으면 reentry 가드 사유 message 반환, 없으면 nil.
    /// `applyExperimentChange` 의 reentry 차단 검사 추출 — invariant 분리.
    public func reentryGuardMessage() -> String? {
        guard let existing = activeExperimentId else { return nil }
        return "이미 활성 실험 (\(existing)) — 종료 후 재시도"
    }

    /// 새 실험 metadata 적용 — `applyExperimentChange` 의 마지막 단계 추출.
    /// axis mutation / snapshot 생성은 session 측 책임. 본 method 는 metadata 만 set.
    public func activateExperiment(
        experimentId: String,
        baselineSessionId: String,
        snapshot: WalkLabSession.ExperimentSnapshot
    ) {
        self.rollbackSnapshot = snapshot
        self.activeExperimentId = experimentId
        self.activeBaselineSessionId = baselineSessionId
    }

    // MARK: - Loop wiring

    /// **v1.11.14**: experiment loop controller 주입 + onCleared callback 등록.
    /// session 의 `clearExperimentContext` 를 weak ref 로 호출 — finalize/cancel 시
    /// 자동 metadata clear. 종전엔 activeExperimentId 가 leak 되어 다음 일반 보행도
    /// experiment 로 인식되는 버그.
    ///
    /// weak session unwrap 으로 reference cycle 차단 — 세션이 이미 해제되면 no-op.
    public func setExperimentLoop(_ controller: ExperimentLoopController?) {
        self.experimentLoop = controller
        controller?.onCleared = { [weak session] in
            session?.clearExperimentContext()
        }
    }

    // MARK: - Onboard health check (pure)

    /// **v1.11.14.7 (2026-05-19)** — ROBOTIS Onboard 모드 health check (pure).
    /// startWalkCycle 의 onboard 분기에서 호출 — 잠재 silent failure 감지.
    /// 반환: 경고 문자열 배열 (빈 배열 = 정상).
    ///
    /// 체크 항목:
    /// 1. ConnectionStore 의 SSH 채널 연결 (isRobotConnected)
    /// 2. autoOnboardBrokering 활성 여부
    /// 3. 보행 명령 enabled 여부 (cradle confirmed)
    ///
    /// pure function — session 의존 0, nonisolated 가능 (호출자 측에서 input 평가).
    public nonisolated func onboardHealthCheckWarningsImpl(
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
}
