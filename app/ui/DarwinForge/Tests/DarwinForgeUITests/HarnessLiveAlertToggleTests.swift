import XCTest
@testable import DarwinForgeUI

// MARK: - HarnessLiveAlertToggleTests (V289-5, 2026-05-25)
//
// 비유: 알람 on/off 스위치 — 누를 때마다 상태가 즉시 뒤집히고,
// 전원을 껐다 켜도 기억하는지 확인.
//
// 기술: HarnessLiveAlerts.toastEnabled 가 UserDefaults 에 즉시 반영되고,
// 다음 읽기 시 동기화되는지 검증. HarnessLiveAlerts.shared 대신
// UserDefaults 직접 읽어 SSoT 검증.

@MainActor
final class HarnessLiveAlertToggleTests: XCTestCase {

    private let key = HarnessLiveAlerts.toastEnabledKey

    override func setUp() {
        super.setUp()
        // 각 테스트 전 초기화 — 다른 테스트와 격리.
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    // MARK: - 기본값

    func test_toastEnabled_defaultIsFalse() {
        // given: UserDefaults 미설정 상태
        // when
        let v = HarnessLiveAlerts.shared.toastEnabled
        // then: bool(forKey:) 는 missing key → false
        XCTAssertFalse(v, "초기 toastEnabled 는 false 이어야 함")
    }

    // MARK: - 설정 → UserDefaults 즉시 반영

    func test_setToastEnabled_true_persists() {
        // given
        HarnessLiveAlerts.shared.toastEnabled = true
        // when: UserDefaults 직접 읽기 (SSoT 확인)
        let stored = UserDefaults.standard.bool(forKey: key)
        // then
        XCTAssertTrue(stored, "toastEnabled=true 설정 후 UserDefaults 가 true 이어야 함")
    }

    func test_setToastEnabled_false_persists() {
        // given: 먼저 true 로
        UserDefaults.standard.set(true, forKey: key)
        // when: false 로 변경
        HarnessLiveAlerts.shared.toastEnabled = false
        // then
        let stored = UserDefaults.standard.bool(forKey: key)
        XCTAssertFalse(stored, "toastEnabled=false 설정 후 UserDefaults 가 false 이어야 함")
    }

    // MARK: - 토글 왕복

    func test_toggleRoundTrip_returnsToPreviousState() {
        // given
        let original = HarnessLiveAlerts.shared.toastEnabled
        // when: toggle on
        HarnessLiveAlerts.shared.toastEnabled = !original
        // then: read back
        XCTAssertEqual(HarnessLiveAlerts.shared.toastEnabled, !original,
                       "토글 후 반대 값이어야 함")
        // when: toggle back
        HarnessLiveAlerts.shared.toastEnabled = original
        // then: restored
        XCTAssertEqual(HarnessLiveAlerts.shared.toastEnabled, original,
                       "재토글 후 원래 값으로 복원되어야 함")
    }

    // MARK: - key 상수 검증

    func test_toastEnabledKey_isExpectedValue() {
        XCTAssertEqual(HarnessLiveAlerts.toastEnabledKey, "harness.live_alerts_toast_enabled",
                       "UserDefaults key 가 스펙과 일치해야 함")
    }
}
