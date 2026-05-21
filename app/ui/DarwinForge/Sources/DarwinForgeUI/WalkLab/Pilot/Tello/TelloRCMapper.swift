import Foundation

/// **v1.17.0 (2026-05-21) — Phase 4: Tello stick → DARwIn 매핑**.
///
/// Tello 의 `rc lr fb ud yaw` (각 -100..100) 를 DARwIn-OP2 의 보행 명령으로 변환.
///
/// # 매핑 설계 (research-analyst 권고)
///
/// - `fb` (전후) → `X_MOVE_AMPLITUDE` (보폭 mm). scale = 0.4
/// - `lr` (좌우) → `Y_MOVE_AMPLITUDE` (측면 mm). scale = 0.3
/// - `yaw` (회전) → `A_MOVE_AMPLITUDE` (회전 deg). scale = 0.2
/// - `ud` (상하) → DARwIn 미지원 — ignored (Tello 만 drone 특성)
///
/// # 안전
///
/// - 각 출력은 ROBOTIS Walking module 의 안전 한도 내로 clamp
/// - deadzone (|stick| < 5) → 0 (drift 제거)
/// - 사용자 input 이 robot 의 fall risk 보다 우선되지 않도록 호출자가 safetyGate 검사
public enum TelloRCMapper {

    /// 매핑 + clamp + deadzone. 입력 stick = -100..100, 출력 = walking amplitude.
    public static func map(
        lr: Int, fb: Int, ud: Int, yaw: Int,
        scale: Scale = .default
    ) -> WalkingCommand {
        let lrClean = applyDeadzone(lr, threshold: 5)
        let fbClean = applyDeadzone(fb, threshold: 5)
        let yawClean = applyDeadzone(yaw, threshold: 5)
        // ud 는 DARwIn 무관 (drone 전용) — 별도 trigger (예: 머리 끄덕임) 매핑 가능하나 본 phase 미구현.
        _ = ud

        let xMm = Double(fbClean) * scale.fb
        let yMm = Double(lrClean) * scale.lr
        let aDeg = Double(yawClean) * scale.yaw

        return WalkingCommand(
            strideMm: clamp(xMm, range: -40...40),
            sideMm: clamp(yMm, range: -25...25),
            turnDeg: clamp(aDeg, range: -20...20)
        )
    }

    /// stick 의 -5..5 영역은 사용자 의도 X — 0 으로 clamp (drift 차단).
    private static func applyDeadzone(_ value: Int, threshold: Int) -> Int {
        abs(value) < threshold ? 0 : value
    }

    private static func clamp(_ value: Double, range: ClosedRange<Double>) -> Double {
        max(range.lowerBound, min(range.upperBound, value))
    }

    /// stick → mm/deg 변환 계수. 사용자 조정 가능 (예: 보행 속도 sensitivity).
    public struct Scale: Equatable, Sendable {
        public let fb: Double  // mm per stick unit
        public let lr: Double
        public let yaw: Double

        public init(fb: Double, lr: Double, yaw: Double) {
            self.fb = fb
            self.lr = lr
            self.yaw = yaw
        }

        /// research-analyst 권고 default: fb=0.4, lr=0.3, yaw=0.2.
        public static let `default` = Scale(fb: 0.4, lr: 0.3, yaw: 0.2)
    }
}

/// 매핑 결과 — Walking module 의 X_MOVE/Y_MOVE/A_MOVE amplitude 대응.
public struct WalkingCommand: Equatable, Sendable, Hashable {
    public let strideMm: Double   // X_MOVE — 보폭 (앞=양수)
    public let sideMm: Double     // Y_MOVE — 측면 (오른쪽=양수)
    public let turnDeg: Double    // A_MOVE — 회전 (반시계=양수)

    public init(strideMm: Double, sideMm: Double, turnDeg: Double) {
        self.strideMm = strideMm
        self.sideMm = sideMm
        self.turnDeg = turnDeg
    }

    /// 모든 채널 0 — robot 정지.
    public static let stop = WalkingCommand(strideMm: 0, sideMm: 0, turnDeg: 0)

    public var isStop: Bool {
        strideMm == 0 && sideMm == 0 && turnDeg == 0
    }
}
