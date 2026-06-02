import XCTest
@testable import MobilePilotKit

/// V297-7 검증 P2-i1 (CRITICAL fix) — iOS state machine 의 복구 흐름.
///
/// # 시나리오 S4 (BDD)
///
/// Given: pilotState = .estopped (사용자가 비상정지 누른 후)
/// When : armRequested apply (사용자가 "복구" 버튼 누름)
/// Then : state == .arming → armed apply → state == .armedReady
///
/// V297-7 이전엔 estopped 에서 armRequested 가 default 분기로 빠져 transition 없음.
/// 즉 사용자가 "복구" 1탭 해도 UI 가 estopped 유지 → 복구 실패처럼 보임.
final class RecoveryFSMScenarioTests: XCTestCase {

    func testS4_estoppedToArmedReady_viaRecover() {
        var sm = MobilePilotStateMachine(initial: .estopped)

        // 사용자 "복구" 탭.
        let r1 = sm.apply(.armRequested)
        XCTAssertEqual(r1.nextState, .arming,
                       "AC: estopped + armRequested → arming (V297-7 추가 transition)")
        XCTAssertTrue(r1.sideEffects.contains(where: { effect in
            if case .logSafety(let msg) = effect {
                return msg == "Recovery requested from estopped"
            }
            return false
        }), "AC: 복구 transition 시 safety log emit")

        // Mac 가 ack 응답 → iOS .armed apply.
        let r2 = sm.apply(.armed)
        XCTAssertEqual(r2.nextState, .armedReady,
                       "AC: arming + armed → armedReady (정상 ARM 흐름 재사용)")
    }

    func testS4_staleStopToArmedReady_viaRecover() {
        var sm = MobilePilotStateMachine(initial: .staleStop)
        let r1 = sm.apply(.armRequested)
        XCTAssertEqual(r1.nextState, .arming,
                       "AC: staleStop + armRequested → arming")
        let r2 = sm.apply(.armed)
        XCTAssertEqual(r2.nextState, .armedReady)
    }

    /// 복구 진행 중 (arming) telemetry 가 잠시 estopped 라도 사용자 의도 보존.
    /// Mac telemetry 가 ack 직전 race 윈도우에서 estopped 표시할 수 있음 (Mac
    /// recoverFromEStop 완료 직전). FSM 이 이때 estopped 로 끌려가면 사용자 입장에서
    /// "복구 무한 루프" 처럼 보임 — 그걸 방지.
    func testS4_armingStateNotPulledBackByStaleEstopTelemetry() {
        var sm = MobilePilotStateMachine(initial: .arming)
        let staleEstopTelemetry = TelemetryStatePayload(
            mac: .connected, robot: .connected, endpoint: nil,
            armed: false, dxlPower: false,
            batteryV: 11.7, maxTempC: 40,
            latencyMs: 30, lastAckAgeMs: nil,
            safety: .estopped, uiState: .estopped)
        let r = sm.apply(.telemetry(staleEstopTelemetry))
        XCTAssertEqual(r.nextState, .arming,
                       "AC: arming 중 stale estop telemetry 가 와도 사용자 의도(복구) 보존")
    }

    /// armedReady 상태도 race window 동안 estop telemetry 무시 — 명령 진행 안전성 보장.
    /// (사용자가 estopRequested 또는 watchdog 가 보내야만 estop 진입.)
    func testS4_armedReadyPreservedAgainstTransientEstopTelemetry() {
        var sm = MobilePilotStateMachine(initial: .armedReady)
        let transientEstop = TelemetryStatePayload(
            mac: .connected, robot: .connected, endpoint: nil,
            armed: true, dxlPower: true,
            batteryV: 11.7, maxTempC: 40,
            latencyMs: 30, lastAckAgeMs: nil,
            safety: .estopped, uiState: .estopped)
        let r = sm.apply(.telemetry(transientEstop))
        XCTAssertEqual(r.nextState, .armedReady,
                       "AC: armedReady 가 transient estop telemetry 만으로 estopped 로 안 끌림")
    }

    /// 사용자가 명시적으로 estopRequested 를 보내면 어떤 상태에서도 estopped 진입.
    func testS4_explicitEstopAlwaysWins() {
        var sm = MobilePilotStateMachine(initial: .armedReady)
        let r = sm.apply(.estopRequested)
        XCTAssertEqual(r.nextState, .estopped,
                       "AC: 명시 estopRequested 는 항상 estopped 진입")
    }

    // MARK: - V297-7 재검증 P2 — recoveryFailed input

    /// arming 중 복구 실패 → estopped 유지, side effect 는 정확한 trace 만.
    /// 가짜 "E-stop requested by user" 로그가 emit 되지 않아야 한다.
    func testS4_recoveryFailedKeepsEstoppedWithoutFakeUserEstopLog() {
        var sm = MobilePilotStateMachine(initial: .arming)
        let r = sm.apply(.recoveryFailed(reason: "rejected:notArmed"))
        XCTAssertEqual(r.nextState, .estopped,
                       "AC: recoveryFailed → estopped 유지")
        // side effects: 정확한 trace 로그만, 가짜 "E-stop requested by user" 없음.
        let logs = r.sideEffects.compactMap { effect -> String? in
            if case .logSafety(let msg) = effect { return msg }
            return nil
        }
        XCTAssertTrue(logs.contains("Recovery failed: rejected:notArmed"),
                      "AC: 정확한 recovery failure reason trace")
        XCTAssertFalse(logs.contains("E-stop requested by user"),
                       "AC: 가짜 사용자-E-stop 로그 없음")
        // haptic / openRecoveryBanner 도 없어야 한다 (이미 banner 떠 있음).
        let hasHaptic = r.sideEffects.contains { effect in
            if case .haptic = effect { return true }
            return false
        }
        XCTAssertFalse(hasHaptic, "AC: 복구 실패 시 추가 haptic 없음")
        let hasBannerOpen = r.sideEffects.contains { effect in
            if case .openRecoveryBanner = effect { return true }
            return false
        }
        XCTAssertFalse(hasBannerOpen, "AC: 복구 실패 시 banner 재open 없음 (이미 떠 있음)")
    }
}
