import Foundation
import ForgeCore
import os.log

/// E-Stop 후 모터 토크 실제 OFF 여부를 검증하는 actor.
///
/// # 비유
///
/// 정지 버튼을 눌렀는데 차가 진짜 멈췄는지 직접 눈으로 확인해야 안전하다.
/// ACK(소프트웨어 응답)만 믿으면 USB 단선·펌웨어 sync 실패 시 모터가 energized 상태로
/// 남아 있어도 앱은 "정지됨"이라 표시한다.
/// `EStopVerifier` 는 1초 대기 후 모든 joint speed 를 측정해서
/// 실제 정지 여부를 물리적으로 검증한다.
///
/// # 동작 시퀀스
///
///   1. `delay` 초 대기 — 모터 감속 완료 시간
///   2. 모든 `JointID` 에 대해 `bus.readState()` 호출
///   3. |presentSpeed| < `speedThreshold` (raw unit) 인지 확인
///   4. 전부 통과 → `.verified`
///   5. 일부 초과 → `.failed(unstoppedJoints:)` — 어느 관절인지 식별
///   6. bus 예외 → `.unreachable(error)` — 연결 문제
///
/// # Non-blocking 설계
///
/// `fireEmergencyStop()` 에서 `Task.detached` 로 호출 — E-Stop ACK 는 즉시 반환.
/// 검증 결과는 1초 후 `ConnectionStore.lastSafetyAlert` 로 표면화.
public enum EStopVerifier {

    // MARK: - Result

    /// 검증 결과.
    public enum VerificationResult: Sendable, Equatable {
        /// 모든 관절 속도가 threshold 미만 — 실제로 정지됨.
        case verified
        /// 일부 관절이 여전히 움직임 — 물리 차단 필요.
        case failed(unstoppedJoints: [JointID])
        /// bus read 중 예외 — 연결 상태 점검 필요.
        case unreachable(errorDescription: String)

        public static func == (lhs: VerificationResult, rhs: VerificationResult) -> Bool {
            switch (lhs, rhs) {
            case (.verified, .verified):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            case (.unreachable(let a), .unreachable(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Configuration

    /// |presentSpeed| 이하이면 정지로 판단하는 raw unit threshold.
    /// Dynamixel AX-12A: 0.111 RPM/unit → 5 unit ≈ 0.55 RPM (사실상 정지).
    public static let defaultSpeedThreshold: UInt16 = 5

    // MARK: - Verification

    /// E-Stop 후 모터 torque 실제 OFF 여부를 검증한다.
    ///
    /// - Parameters:
    ///   - bus: 검증에 사용할 `BusInterface`. nil 이면 `.unreachable` 반환.
    ///   - delay: 모터 감속 완료 대기 시간 (기본값 1.0초).
    ///   - speedThreshold: 정지 판단 raw unit 임계값 (기본값 5).
    /// - Returns: `VerificationResult` — throw 없음. 모든 실패는 result 에 표현.
    public static func verifyTorqueOff(
        bus: (any BusInterface)?,
        delay: TimeInterval = 1.0,
        speedThreshold: UInt16 = defaultSpeedThreshold
    ) async -> VerificationResult {
        guard let bus else {
            return .unreachable(errorDescription: "bus nil — 연결 없음")
        }

        // 1초 대기: 모터 감속 완료 시간.
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // 모든 joint speed 읽기.
        var unstoppedJoints: [JointID] = []
        for joint in JointID.allCases {
            do {
                let state = try bus.readState(joint)
                // Dynamixel presentSpeed: 10bit 값, MSB(bit10)가 방향 비트.
                // 실제 속도 크기 = rawValue & 0x3FF.
                let speedMagnitude = state.presentSpeed & 0x3FF
                if speedMagnitude >= speedThreshold {
                    unstoppedJoints.append(joint)
                }
            } catch {
                // 개별 joint read 실패 = 연결 불안정 → unreachable 처리.
                return .unreachable(errorDescription: "joint \(joint.rawValue) read 실패: \(error)")
            }
        }

        if unstoppedJoints.isEmpty {
            return .verified
        } else {
            return .failed(unstoppedJoints: unstoppedJoints)
        }
    }
}
