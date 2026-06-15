import Foundation

/// **v1.16.0 (2026-05-21) — Phase 2: Recommender → WalkLabSession hook**.
///
/// Recommender 의 추천을 사용자가 "이 config 적용" 버튼 클릭 시 session 에 inject.
/// god object 확장 금지 — extension 으로 분리 (Phase 1 의 `+Trials.swift` 와 같은 패턴).
extension WalkLabSession {

    /// 추천 config 를 현재 session 에 적용. 사용자가 직접 시작 누르면 새 trial 시작.
    ///
    /// 적용 항목:
    /// - tuning sliders (strideMm, sideMm, turnDeg, customPeriodMs, footHeightMm, balanceGain)
    /// - intensity level
    /// - balanceExperimentConfig (algorithm/sign/gain/applyToRobot/pitchInputConvention)
    ///
    /// **주의**: 보행 중에는 적용 안 함 (안전). 보행 중이면 lastScopeWarning 설정.
    /// **v1.16.0.1 fix (M4 test)**: 종전 `isWalkActive` (isRobotWalking || onboardWalkingActive)
    /// 는 sim 모드에서 false → sim 보행 중에 추천 적용되어 사용자 혼동. `current != .idle`
    /// 로 변경 — sim/실/onboard 어느 path 든 보행 중이면 차단.
    @MainActor
    public func applyRecommendation(_ rec: WalkTrialRecommendation) {
        guard current == .idle else {
            lastScopeWarning = "추천 적용은 보행 정지 후 가능합니다. (현재 \(current.label) 진행 중)"
            return
        }

        // tuning 적용 — sliders.
        strideMm = rec.tuning.strideMm
        sideMm = rec.tuning.sideMm
        turnDeg = rec.tuning.turnDeg
        customPeriodMs = rec.tuning.periodMs
        footHeightMm = rec.tuning.footHeightMm
        balanceGain = rec.tuning.balanceGain

        // intensity 적용 — corrector setter 의 didSet 으로 defer.
        correctorIntensityLevel = rec.intensityLevel

        // balance config — didSet 안에서 corrector 재생성 + Harness 로그.
        balanceExperimentConfig = rec.balanceConfig

        // 사용자 안내 — 다음 보행 시 이 config 사용됨을 명시.
        lastRobotEvent = "✨ \(rec.strategy.label) 추천 적용됨 — 시작 버튼 누르면 이 config 로 보행"
        lastScopeWarning = nil
    }
}
