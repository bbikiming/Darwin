import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 109: god object Phase 8 분할 (Balance Mitigation)**.
///
/// `WalkLabSession.swift` (2893 line) 의 `applyBalanceMitigation()` (~42 line) 만
/// 본 extension 으로 이동.
///
/// # 비유
///
/// 비행기 fly-by-wire 의 "자동 회피 기동 컴퓨터" 모듈을 별도 부속실로 이전. 회피
/// 정책 (engine 명령 조정 + hysteresis counter + 자동 cancel) 만 이전.
///
/// # 분할 정책
///
/// - **method 1개 이동**: `applyBalanceMitigation()`.
/// - 격상 (사이클 109):
///   - `engine` (private → internal) — `engine.setCommand(...)` 호출
///   - `warningStateConsecutiveSamples` (private → internal) — hysteresis counter
///   - `dangerStateConsecutiveSamples` (private → internal) — hysteresis counter
///   - `cancelWalkCycle` (private → internal) — 3 tick 연속 임계 도달 시 auto cancel
/// - `balanceState / lastRobotEvent / isRobotWalking / store` 이미 internal 이상 — 격상 0.
/// - 호출 site `tick()` 의 `applyBalanceMitigation()` 호출은 본체 동일.
///
/// # 회귀
///
/// 1296 tests 회귀 0 — 외부 API 변경 0 (모든 격상은 module-internal).
extension WalkLabSession {

    /// **Stage 2 + Phase C/D (v1.1 fall prevention)**: 다단계 임계 별 자동 mitigation.
    /// v1.11.19 (2026-05-20) 정합: 25/35/45/50° BalanceState 임계.
    ///
    /// Warning (35° 이상) — sim engine 속도 70% 감속 + 3 tick hysteresis 후 실 robot
    /// `cancelWalkCycle` (안전한 walkReady 복귀, 사용자가 슬라이더 줄이고 재시작 권장).
    /// Danger (45° 이상) — sim engine 정지 + 3 tick hysteresis 후 cancelWalkCycle
    /// (`transformPose` 가 lastSafePose 반환, 자세 동결).
    /// Emergency (≥ 50°) — 별도 L3 hard gate (3 연속 sample → 토크 OFF + walkReady).
    ///
    /// `autoFallPrevention = false` 면 호출 안 됨 — emergency 만 작동.
    internal func applyBalanceMitigation() {
        let cmd = effectiveCommand
        switch balanceState {
        case .normal, .caution:
            // **Phase D 정정**: 회복 시 engine 100% 복원. 이전 warning 의 0.7× 잔존 방지.
            engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
            // v1.8: warning hysteresis 리셋.
            warningStateConsecutiveSamples = 0
            dangerStateConsecutiveSamples = 0
        case .warning:
            // 70% 자동 감속 — sim engine 의 x_amplitude 만 줄임.
            engine.setCommand(
                x: cmd.x * BalanceState.warning.speedScale,
                y: cmd.y,
                a: cmd.a,
                enabled: cmd.enabled
            )
            // v1.8 (2026-05-17): hysteresis 도입. 한 sample spike → 즉시 cancel false-positive
            // 차단. 3 tick 연속 (150ms @ 50ms tick) warning 일 때만 실 robot 보행 정지.
            warningStateConsecutiveSamples += 1
            dangerStateConsecutiveSamples = 0
            if warningStateConsecutiveSamples >= 3,
               isRobotWalking, store?.bus != nil {
                lastRobotEvent = "⚠️ 기울기 35°+ 지속 — 실 robot 보행 정지. 슬라이더 줄이고 재시작 권장"
                cancelWalkCycle(eventLabel: "Warning state 지속 자동 정지")
                warningStateConsecutiveSamples = 0
            }
        case .danger:
            // **Phase C**: sim engine 정지 + `transformPose` 가 lastSafePose 반환.
            engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
            // v1.8: danger 도 3 tick hysteresis.
            dangerStateConsecutiveSamples += 1
            if dangerStateConsecutiveSamples >= 3,
               isRobotWalking, store?.bus != nil {
                lastRobotEvent = "🛑 기울기 45°+ 지속 — 자세 동결 (낙상 직전)"
                cancelWalkCycle(eventLabel: "Danger state 지속 자세 동결")
                dangerStateConsecutiveSamples = 0
            }
        case .emergency:
            // 즉시 L3 게이트 (별도 처리).
            break
        }
    }
}
