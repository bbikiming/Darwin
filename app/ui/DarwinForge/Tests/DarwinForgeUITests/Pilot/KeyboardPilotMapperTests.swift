import Foundation
import SwiftUI
import XCTest
@testable import DarwinForgeUI

/// **v1.20.2 (2026-05-22) 사이클 8 — KeyboardPilotMapper 단위 테스트**.
///
/// 가상 stick 매핑이 TelloRCMapper.map 과 일관되게 동작하는지 + 키 조합 + emergency
/// 식별 + KeyEquivalent resolution 모두 검증.
final class KeyboardPilotMapperTests: XCTestCase {

    // MARK: - 단일 키 매핑

    func testForwardKeyMapsToPositiveStride() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.forward])
        XCTAssertEqual(cmd.strideMm, 40, accuracy: 1e-9, "fb=100 * 0.4 = 40")
        XCTAssertEqual(cmd.sideMm, 0)
        XCTAssertEqual(cmd.turnDeg, 0)
    }

    func testBackwardKeyMapsToNegativeStride() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.backward])
        XCTAssertEqual(cmd.strideMm, -40, accuracy: 1e-9)
    }

    func testRightKeyMapsToPositiveSide() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.right])
        // lr=100 * 0.3 = 30 → clamp 25.
        XCTAssertEqual(cmd.sideMm, 25, accuracy: 1e-9)
    }

    func testLeftKeyMapsToNegativeSide() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.left])
        XCTAssertEqual(cmd.sideMm, -25, accuracy: 1e-9)
    }

    func testTurnRightMapsToPositiveYaw() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.turnRight])
        // yaw=100 * 0.2 = 20 → 한도 OK.
        XCTAssertEqual(cmd.turnDeg, 20, accuracy: 1e-9)
    }

    func testTurnLeftMapsToNegativeYaw() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.turnLeft])
        XCTAssertEqual(cmd.turnDeg, -20, accuracy: 1e-9)
    }

    // MARK: - 키 조합 (게임 캐릭터 대각선)

    func testDiagonalForwardRight() {
        // W + D → 전진 + 우측 strafe.
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.forward, .right])
        XCTAssertEqual(cmd.strideMm, 40, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, 25, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, 0)
    }

    func testDiagonalBackwardLeft() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.backward, .left])
        XCTAssertEqual(cmd.strideMm, -40, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, -25, accuracy: 1e-9)
    }

    func testForwardWithTurn() {
        // 전진 + 우회전 — 자연스러운 곡선 이동.
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.forward, .turnRight])
        XCTAssertEqual(cmd.strideMm, 40, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, 20, accuracy: 1e-9)
    }

    // MARK: - 충돌 (서로 상쇄)

    func testConflictingForwardBackward() {
        // W+S → fb = 100 - 100 = 0 → strideMm 0.
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.forward, .backward])
        XCTAssertEqual(cmd.strideMm, 0, accuracy: 1e-9, "양방향 동시 입력 → 상쇄")
    }

    func testConflictingLeftRight() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.left, .right])
        XCTAssertEqual(cmd.sideMm, 0, accuracy: 1e-9)
    }

    func testEmptyKeysProducesStop() {
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [])
        XCTAssertEqual(cmd, .stop, "키 안 누름 → stop")
        XCTAssertTrue(cmd.isStop)
    }

    // MARK: - Scale 적용

    func testCustomScaleScalesOutput() {
        let halfScale = TelloRCMapper.Scale(fb: 0.2, lr: 0.15, yaw: 0.1)
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: [.forward], scale: halfScale)
        XCTAssertEqual(cmd.strideMm, 20, accuracy: 1e-9, "0.2 scale → 20mm")
    }

    // MARK: - Emergency

    func testEmergencyPressed() {
        XCTAssertTrue(KeyboardPilotMapper.isEmergencyPressed([.emergency]))
        XCTAssertTrue(KeyboardPilotMapper.isEmergencyPressed([.emergency, .forward]))
    }

    func testEmergencyNotPressed() {
        XCTAssertFalse(KeyboardPilotMapper.isEmergencyPressed([]))
        XCTAssertFalse(KeyboardPilotMapper.isEmergencyPressed([.forward, .right]))
    }

    // MARK: - KeyEquivalent → PilotKey resolution

    func testResolveWASD() {
        XCTAssertEqual(KeyboardPilotMapper.resolve("w"), .forward)
        XCTAssertEqual(KeyboardPilotMapper.resolve("a"), .left)
        XCTAssertEqual(KeyboardPilotMapper.resolve("s"), .backward)
        XCTAssertEqual(KeyboardPilotMapper.resolve("d"), .right)
    }

    func testResolveCaseInsensitive() {
        XCTAssertEqual(KeyboardPilotMapper.resolve("W"), .forward)
        XCTAssertEqual(KeyboardPilotMapper.resolve("D"), .right)
    }

    func testResolveQE() {
        XCTAssertEqual(KeyboardPilotMapper.resolve("q"), .turnLeft)
        XCTAssertEqual(KeyboardPilotMapper.resolve("e"), .turnRight)
    }

    func testResolveArrows() {
        XCTAssertEqual(KeyboardPilotMapper.resolve(.upArrow), .forward)
        XCTAssertEqual(KeyboardPilotMapper.resolve(.downArrow), .backward)
        XCTAssertEqual(KeyboardPilotMapper.resolve(.leftArrow), .left)
        XCTAssertEqual(KeyboardPilotMapper.resolve(.rightArrow), .right)
    }

    func testResolveSpace() {
        XCTAssertEqual(KeyboardPilotMapper.resolve(" "), .emergency)
        XCTAssertEqual(KeyboardPilotMapper.resolve(.space), .emergency)
    }

    func testResolveUnknownKeyReturnsNil() {
        XCTAssertNil(KeyboardPilotMapper.resolve("x"))
        XCTAssertNil(KeyboardPilotMapper.resolve("1"))
        XCTAssertNil(KeyboardPilotMapper.resolve(.return))
    }

    // MARK: - allHandledKeys completeness

    func testAllHandledKeysIncludesEssentials() {
        let keys = Set(KeyboardPilotMapper.allHandledKeys.map(\.character))
        XCTAssertTrue(keys.contains("w"), "W 포함")
        XCTAssertTrue(keys.contains("a"))
        XCTAssertTrue(keys.contains("s"))
        XCTAssertTrue(keys.contains("d"))
        XCTAssertTrue(keys.contains("q"))
        XCTAssertTrue(keys.contains("e"))
        XCTAssertTrue(keys.contains(" "), "Space 포함")
    }

    func testAllHandledKeysIncludesArrows() {
        let arrows: Set<KeyEquivalent> = [.upArrow, .downArrow, .leftArrow, .rightArrow]
        let handled = Set(KeyboardPilotMapper.allHandledKeys)
        for arrow in arrows {
            XCTAssertTrue(handled.contains(arrow), "\(arrow.character) 포함")
        }
    }

    // MARK: - Cycle 10: preset shortcuts (number keys)

    func testResolvePresetDigits() {
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("0"), .idle)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("1"), .march)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("2"), .slowWalk)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("3"), .normalWalk)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("4"), .fastWalk)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("5"), .jog)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("6"), .turnLeft)
        XCTAssertEqual(KeyboardPilotMapper.resolvePreset("7"), .turnRight)
    }

    func testResolvePresetUnmappedDigits() {
        XCTAssertNil(KeyboardPilotMapper.resolvePreset("8"))
        XCTAssertNil(KeyboardPilotMapper.resolvePreset("9"))
    }

    func testResolvePresetNonDigit() {
        XCTAssertNil(KeyboardPilotMapper.resolvePreset("a"))
        XCTAssertNil(KeyboardPilotMapper.resolvePreset("w"))
        XCTAssertNil(KeyboardPilotMapper.resolvePreset(.space))
    }

    func testAllHandledKeysIncludesDigits() {
        let handled = Set(KeyboardPilotMapper.allHandledKeys.map(\.character))
        for digit in 0..<8 {
            XCTAssertTrue(handled.contains(Character(String(digit))),
                          "digit \(digit) 포함")
        }
    }

    // MARK: - Cycle 19: Recovery key

    func testIsRecoveryKeyMatchesR() {
        XCTAssertTrue(KeyboardPilotMapper.isRecoveryKey("r"))
        XCTAssertTrue(KeyboardPilotMapper.isRecoveryKey("R"))
    }

    func testIsRecoveryKeyDoesNotMatchOthers() {
        XCTAssertFalse(KeyboardPilotMapper.isRecoveryKey("w"))
        XCTAssertFalse(KeyboardPilotMapper.isRecoveryKey("1"))
        XCTAssertFalse(KeyboardPilotMapper.isRecoveryKey(.space))
    }

    func testAllHandledKeysIncludesR() {
        let handled = Set(KeyboardPilotMapper.allHandledKeys.map(\.character))
        XCTAssertTrue(handled.contains("r"), "R 키 포함")
    }

    // MARK: - Cycle 31: Motion key (M)

    func testIsMotionKeyMatchesM() {
        XCTAssertTrue(KeyboardPilotMapper.isMotionKey("m"))
        XCTAssertTrue(KeyboardPilotMapper.isMotionKey("M"))
    }

    func testIsMotionKeyDoesNotMatchOthers() {
        XCTAssertFalse(KeyboardPilotMapper.isMotionKey("w"))
        XCTAssertFalse(KeyboardPilotMapper.isMotionKey("r"))
        XCTAssertFalse(KeyboardPilotMapper.isMotionKey("1"))
    }

    func testAllHandledKeysIncludesM() {
        let handled = Set(KeyboardPilotMapper.allHandledKeys.map(\.character))
        XCTAssertTrue(handled.contains("m"), "M 키 포함")
    }
}
