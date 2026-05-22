import Foundation
import XCTest
@testable import DarwinForgeUI

/// **사이클 86 — PilotAudioFeedback 단위 테스트**.
///
/// production NSBeep 은 실제 sound 재생하므로 테스트 부적합. `MockAudioFeedback` 으로
/// 호출 횟수 검증.
final class PilotAudioFeedbackTests: XCTestCase {

    func testMockInitialState() {
        let mock = MockAudioFeedback()
        XCTAssertEqual(mock.emergencyPlayCount, 0)
        XCTAssertEqual(mock.recoveryPlayCount, 0)
    }

    func testPlayEmergencyIncrementsCounter() {
        let mock = MockAudioFeedback()
        mock.playEmergency()
        XCTAssertEqual(mock.emergencyPlayCount, 1)
        mock.playEmergency()
        mock.playEmergency()
        XCTAssertEqual(mock.emergencyPlayCount, 3)
    }

    func testPlayRecoveryIncrementsCounter() {
        let mock = MockAudioFeedback()
        mock.playRecovery()
        XCTAssertEqual(mock.recoveryPlayCount, 1)
    }

    func testResetClearsBothCounters() {
        let mock = MockAudioFeedback()
        mock.playEmergency()
        mock.playRecovery()
        mock.reset()
        XCTAssertEqual(mock.emergencyPlayCount, 0)
        XCTAssertEqual(mock.recoveryPlayCount, 0)
    }

    /// **사이클 86**: production NSBeepFeedbackPlayer 가 crash 없이 init + call.
    /// 실 NSBeep 호출은 silent (CI 환경에서 audio device 없음 — silently no-op).
    func testNSBeepFeedbackPlayerNoCrash() {
        let player = NSBeepFeedbackPlayer()
        // 실 sound 안 들려도 crash 안 함 검증.
        player.playEmergency()
        player.playRecovery()
    }
}
