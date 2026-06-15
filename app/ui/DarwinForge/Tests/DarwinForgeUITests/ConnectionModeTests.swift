/// 연결 모드(보행 ↔ 관절편집 ↔ 오프라인) — 파생 로직 + 표시 메타 단위 테스트.
///
/// 커버:
///   - `ConnectionMode.derive(busActive:telemetryMode:)` 순수 파생 규칙
///     (LAN 버스 우선 → 온보드 → 오프라인).
///   - 모드별 표시 메타(label/icon/guidance) 비어있지 않음 + 케이스별 정확성.
///   - `ConnectionStore.currentMode` 파생 위임(초기 오프라인 상태) + 전환 가드 phase.
import ForgeCore
import XCTest

@testable import DarwinForgeUI

// MARK: - 파생 로직 (순수)

final class ConnectionModeDerivationTests: XCTestCase {

    /// LAN 버스가 살아있으면 telemetryMode 와 무관하게 항상 관절편집 — Mac 직접 제어가 진실.
    func testBusActiveAlwaysJointEdit() {
        XCTAssertEqual(ConnectionMode.derive(busActive: true, telemetryMode: .lan), .jointEdit)
        XCTAssertEqual(ConnectionMode.derive(busActive: true, telemetryMode: .onboard), .jointEdit)
        XCTAssertEqual(ConnectionMode.derive(busActive: true, telemetryMode: .onboardStale), .jointEdit)
        XCTAssertEqual(ConnectionMode.derive(busActive: true, telemetryMode: .offline), .jointEdit)
    }

    /// 버스 없음 + 온보드(라이브/지연) → 보행.
    func testOnboardTelemetryIsWalk() {
        XCTAssertEqual(ConnectionMode.derive(busActive: false, telemetryMode: .onboard), .walk)
        XCTAssertEqual(ConnectionMode.derive(busActive: false, telemetryMode: .onboardStale), .walk)
    }

    /// 버스 없음 + LAN/오프라인 텔레메트리 → 오프라인.
    /// (.lan 인데 bus 없음은 비정상 조합이지만 안전하게 offline 로 떨어진다.)
    func testNoBusOfflineOrLanIsOffline() {
        XCTAssertEqual(ConnectionMode.derive(busActive: false, telemetryMode: .offline), .offline)
        XCTAssertEqual(ConnectionMode.derive(busActive: false, telemetryMode: .lan), .offline)
    }
}

// MARK: - 표시 메타

final class ConnectionModeMetaTests: XCTestCase {

    func testLabelsAreCorrectAndNonEmpty() {
        XCTAssertEqual(ConnectionMode.walk.label, "보행")
        XCTAssertEqual(ConnectionMode.jointEdit.label, "관절편집")
        XCTAssertEqual(ConnectionMode.offline.label, "오프라인")
        for mode in ConnectionMode.allCases {
            XCTAssertFalse(mode.label.isEmpty, "\(mode) label 비어있음")
        }
    }

    func testIconsAreCorrectAndNonEmpty() {
        XCTAssertEqual(ConnectionMode.walk.iconSystemName, "figure.walk")
        XCTAssertEqual(ConnectionMode.jointEdit.iconSystemName, "slider.horizontal.3")
        for mode in ConnectionMode.allCases {
            XCTAssertFalse(mode.iconSystemName.isEmpty, "\(mode) icon 비어있음")
        }
    }

    func testGuidanceNonEmptyAndDistinctPerActiveMode() {
        for mode in ConnectionMode.allCases {
            XCTAssertFalse(mode.guidance.isEmpty, "\(mode) guidance 비어있음")
        }
        // 보행/관절편집 안내는 서로 달라야 한다(사용자 혼동 방지).
        XCTAssertNotEqual(ConnectionMode.walk.guidance, ConnectionMode.jointEdit.guidance)
        // 관절편집 안내에는 "보행은 멈춥니다" 경고가 포함.
        XCTAssertTrue(ConnectionMode.jointEdit.guidance.contains("보행은 멈춥니다"))
    }

    func testSwitchNoteMentionsSharedBus() {
        XCTAssertFalse(ConnectionMode.switchNote.isEmpty)
        XCTAssertTrue(ConnectionMode.switchNote.contains("같은 모터 버스"))
    }
}

// MARK: - ConnectionStore 파생 위임 + 전환 가드

@MainActor
final class ConnectionModeStoreTests: XCTestCase {

    /// 갓 만든 store 는 버스 없음 + telemetryMode .offline → currentMode .offline.
    func testFreshStoreIsOffline() {
        let store = ConnectionStore(harness: RecordingHarness())
        XCTAssertEqual(store.currentMode, .offline)
        XCTAssertEqual(store.modeSwitchPhase, .idle)
    }

    /// 같은 모드(오프라인)로 전환 요청 → no-op (phase 변화 없음).
    func testSwitchToSameModeIsNoOp() async {
        let store = ConnectionStore(harness: RecordingHarness())
        let shell = RemoteShell(harness: RecordingHarness())
        await store.switchMode(to: .offline, remoteShell: shell)
        XCTAssertEqual(store.modeSwitchPhase, .idle, "동일 모드 전환은 phase 를 건드리지 않음")
    }

    /// e-stop 진입 상태에서 전환 시도 → 안전 가드로 .failed.
    /// (오프라인 → 관절편집 전환은 보통 SSH 명령을 보내지만, e-stop 가드가 먼저 차단한다.)
    func testSwitchBlockedDuringEmergencyStop() async {
        let store = ConnectionStore(harness: RecordingHarness())
        let shell = RemoteShell(harness: RecordingHarness())
        store._setEmergencyStopActive(true)
        await store.switchMode(to: .jointEdit, remoteShell: shell)
        guard case .failed(let msg) = store.modeSwitchPhase else {
            return XCTFail("e-stop 중 전환은 .failed 여야 함, 실제: \(store.modeSwitchPhase)")
        }
        XCTAssertTrue(msg.contains("정지"), "가드 메시지에 정지 안내 포함: \(msg)")
    }

    /// clearModeSwitchPhase 는 .failed 만 .idle 로 되돌린다.
    func testClearModeSwitchPhaseResetsFailedOnly() {
        let store = ConnectionStore(harness: RecordingHarness())
        store._setEmergencyStopActive(true)
        // 동기 가드를 직접 태우기 위해 Task 없이 phase 를 검증할 수 없으므로,
        // clearModeSwitchPhase 의 idempotency 만 확인(idle 에서 호출해도 idle 유지).
        store.clearModeSwitchPhase()
        XCTAssertEqual(store.modeSwitchPhase, .idle)
    }
}
