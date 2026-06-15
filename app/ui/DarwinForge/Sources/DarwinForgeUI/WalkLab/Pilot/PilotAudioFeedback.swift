import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// **v1.22.0 (2026-05-22) — 사이클 86: pilot 안전 이벤트 오디오 피드백**.
///
/// emergency 발화 / recovery 등 안전 critical event 에 macOS NSBeep / NSSound 출력.
/// 사용자가 시각 UI 를 보지 않아도 청각으로 즉시 인지 가능. accessibility 보조.
///
/// # 비유
///
/// 자동차 안전벨트 미착용 경고음 — 시각적 경고등이 가려져도 사용자가 즉시 듣는다.
/// 본 service 는 emergency / recovery 같은 critical safety event 에 system sound 트리거.
///
/// # 정책
///
/// - emergency: system beep (macOS 기본) — 짧고 강한 신호.
/// - recovery: 무소리 (시각으로 충분, 청각 noise 절약).
/// - 다른 이벤트: 향후 확장 가능 (현재 OFF).
///
/// # 테스트 친화
///
/// `AudioFeedbackPlayer` protocol 추상화 — 실 `NSBeepFeedbackPlayer` + test `MockAudioFeedback`.
/// XCTest 환경에서 mock 으로 호출 횟수 검증.
public protocol AudioFeedbackPlayer: Sendable {
    func playEmergency()
    func playRecovery()
}

/// production 구현 — macOS NSBeep 사용. AppKit 의존이라 macOS 전용.
public final class NSBeepFeedbackPlayer: AudioFeedbackPlayer, @unchecked Sendable {
    public init() {}

    public func playEmergency() {
        #if canImport(AppKit)
        NSSound.beep()
        #endif
    }

    public func playRecovery() {
        // 정책: recovery 는 silent (시각 banner 로 충분, 청각 noise 절약).
        // 향후 사용자 선호 시 NSSound 등으로 변경 가능.
    }
}

/// **테스트 전용** — 호출 횟수 카운트.
public final class MockAudioFeedback: AudioFeedbackPlayer, @unchecked Sendable {
    public private(set) var emergencyPlayCount: Int = 0
    public private(set) var recoveryPlayCount: Int = 0
    private let lock = NSLock()

    public init() {}

    public func playEmergency() {
        lock.lock(); defer { lock.unlock() }
        emergencyPlayCount += 1
    }

    public func playRecovery() {
        lock.lock(); defer { lock.unlock() }
        recoveryPlayCount += 1
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        emergencyPlayCount = 0
        recoveryPlayCount = 0
    }
}
