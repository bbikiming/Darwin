import Foundation
import Observation
import ForgeCore

/// **v1.18.0 (2026-05-21) Phase 3 — upper/lower body blending engine**.
///
/// `CompositeMotion` 의 lower (보행) + upper (named motion) 동시 실행을 관리.
///
/// # 핵심 책임
///
/// 1. **play**: 단일 또는 composite motion 시작 — `BlendResult` 반환 (안전 차단 명시)
/// 2. **emergencyKill**: 모든 motion 즉시 강제 종료 (emergency stop 우선순위)
/// 3. **upperFinished**: composite 의 upper motion 종료 콜백 — lower 만 유지
/// 4. **isPlaying**: 현재 motion 활성 여부 — view binding
///
/// # 비유
///
/// DJ 의 믹서 — lower deck (walking beat) + upper deck (vocals/motion) 두 channel.
/// emergency cut = 두 deck 모두 즉시 stop. lower 가 항상 base.
///
/// # Sim-only (Phase 3)
///
/// 실 robot 송출은 안 함. blendedPose() 가 RobotPose 만 반환. WalkLabRCBridge 가
/// 실 hardware send 책임 — 본 phase 에선 송출 자체 미구현 (별도 phase).
@MainActor
@Observable
public final class MotionBlender {

    /// 현재 lower channel 점유 motion (보행 기반). nil = idle.
    public private(set) var lower: MotionDescriptor?
    /// 현재 upper channel 점유 motion (팔/머리). nil = lower 만 또는 idle.
    public private(set) var upper: MotionDescriptor?
    /// loop=false 이고 upper 종료 시 자동 nil → 본 motion 의 finish callback 발화.
    public private(set) var upperLoops: Bool = false

    /// 마지막 play 결과 — view binding (HUD 에 결과 표시).
    public private(set) var lastResult: BlendResult?
    /// 마지막 update 시각 — debugging.
    public private(set) var lastUpdatedAt: Date?

    public init() {}

    // MARK: - Play / Stop

    /// 단일 또는 composite motion 시작. channel 충돌 / safety verdict 검증.
    ///
    /// **v1.18.0.1 fix (코덱스 HIGH 2)**: `safetyContext` 전달 시 TransitionPolicy 통합 호출.
    /// nil 이면 (테스트 / safety guard 별도 처리 시) 검증 skip.
    @discardableResult
    public func play(
        _ descriptor: MotionDescriptor,
        loop: Bool = false,
        safetyContext: SafetyContext? = nil
    ) -> BlendResult {
        // 1) safety policy 검증 (있는 경우).
        if let ctx = safetyContext {
            let verdict = MotionTransitionPolicy.validate(
                target: descriptor,
                balanceState: ctx.balanceState,
                robotConnected: ctx.robotConnected,
                riskAcknowledged: ctx.riskAcknowledged
            )
            if case .blocked(let reason) = verdict {
                let result: BlendResult = .rejectedSafety(reason: reason)
                lastResult = result
                lastUpdatedAt = Date()
                return result
            }
            // requireConfirm 은 caller 책임 (UI sheet 표시) — 여기선 일단 통과.
        }
        let result = validateAndApply(single: descriptor, loop: loop)
        lastResult = result
        lastUpdatedAt = Date()
        return result
    }

    /// composite 시작 — lower + upper 동시.
    @discardableResult
    public func play(
        composite: CompositeMotion,
        upperLoops: Bool = false,
        safetyContext: SafetyContext? = nil
    ) -> BlendResult {
        // **v1.18.0.1 fix**: composite 도 safety 검증 — lower + upper 각각 별도 검증.
        if let ctx = safetyContext {
            for descriptor in [composite.lower, composite.upper] {
                let verdict = MotionTransitionPolicy.validate(
                    target: descriptor,
                    balanceState: ctx.balanceState,
                    robotConnected: ctx.robotConnected,
                    riskAcknowledged: ctx.riskAcknowledged
                )
                if case .blocked(let reason) = verdict {
                    let result: BlendResult = .rejectedSafety(reason: reason)
                    lastResult = result
                    lastUpdatedAt = Date()
                    return result
                }
            }
        }
        lower = composite.lower
        upper = composite.upper
        self.upperLoops = upperLoops
        let result: BlendResult = .accepted(composite.bodyRegions)
        lastResult = result
        lastUpdatedAt = Date()
        return result
    }

    /// upper motion 자연 종료 — loop=false 면 nil 로 clean.
    public func upperFinished() {
        guard !upperLoops else { return }
        upper = nil
        lastUpdatedAt = Date()
    }

    /// emergency kill — 모든 motion 강제 종료. emergency stop 우선순위 (다른 모든 호출 무시 가능).
    public func emergencyKill() {
        lower = nil
        upper = nil
        upperLoops = false
        lastResult = .accepted([])
        lastUpdatedAt = Date()
    }

    /// 일반 정지 — lower / upper 둘 다 nil.
    public func stopAll() {
        lower = nil
        upper = nil
        upperLoops = false
        lastResult = nil
    }

    /// 활성 여부 — view binding.
    public var isPlaying: Bool {
        lower != nil || upper != nil
    }

    // MARK: - Pose query (sim only, Phase 3)

    /// blended pose 산출 — walkBasePose (walking module 결과) 위에 upper motion overlay.
    /// **주의**: arm swing (rShoulderPitch/lShoulderPitch) 는 upper motion 이 override.
    public func blendedPose(walkBasePose: RobotPose) -> RobotPose {
        // Phase 3 sim: lower = walkBasePose 그대로, upper motion 의 joint 가 있다면 override.
        // 본격 motion overlay (page joint angle 추출 등) 는 별도 phase — 현재 base 만 반환.
        return walkBasePose
    }

    // MARK: - Internal validation

    private func validateAndApply(single descriptor: MotionDescriptor, loop: Bool) -> BlendResult {
        let channels = descriptor.occupiedChannels
        if channels.contains(.lower) && channels.contains(.upper) {
            // 두 channel 모두 점유 — composite 불가능, 단독으로만.
            lower = descriptor
            upper = nil
            upperLoops = false
            return .acceptedFullBody(descriptor.bodyRegions)
        }
        if channels.contains(.lower) {
            lower = descriptor
            // upper 는 기존 유지 (composite 자연 형성).
            return .accepted(descriptor.bodyRegions)
        }
        if channels.contains(.upper) {
            upper = descriptor
            upperLoops = loop
            // lower 는 기존 유지.
            return .accepted(descriptor.bodyRegions)
        }
        // 빈 motion — 무시.
        return .rejectedEmptyChannels
    }
}

// MARK: - SafetyContext

/// `MotionBlender.play(_:safetyContext:)` 의 검증 input.
/// 호출 site (예: WalkLabRCBridge) 가 현재 session 의 balanceState 등을 캡처해서 전달.
public struct SafetyContext: Equatable, Sendable {
    public let balanceState: WalkLabSession.BalanceState
    public let robotConnected: Bool
    public let riskAcknowledged: Bool

    public init(
        balanceState: WalkLabSession.BalanceState,
        robotConnected: Bool,
        riskAcknowledged: Bool
    ) {
        self.balanceState = balanceState
        self.robotConnected = robotConnected
        self.riskAcknowledged = riskAcknowledged
    }
}

// MARK: - BlendResult

public enum BlendResult: Equatable, Sendable {
    /// 정상 적용 — 영향 받은 region.
    case accepted(Set<JointID.BodyPart>)
    /// 단일 motion 이 전신 점유 — composite 안 됨.
    case acceptedFullBody(Set<JointID.BodyPart>)
    /// motion 의 occupiedChannels 가 empty — 의미 없음.
    case rejectedEmptyChannels
    /// safety 검증 실패 — TransitionPolicy 가 결정.
    case rejectedSafety(reason: String)

    public var isAccepted: Bool {
        switch self {
        case .accepted, .acceptedFullBody: return true
        default: return false
        }
    }
}
