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
            // **v1.20.30.1 사이클 36-fix HIGH 2 (코덱스)** — requireConfirm 도 차단.
            // 종전: caller 책임으로 통과 — bridge.handleMotion(id:) path 가 confirm UI 없이 발화 →
            // highRisk page (slot 12/13 등) 가 사용자 동의 없이 실행 위험.
            // 신규: requireConfirm 도 reject — caller 가 명시 confirm 후 별도 path 로 재호출 필요.
            if case .requireConfirm(let reason) = verdict {
                let result: BlendResult = .rejectedSafety(reason: "위험 동의 필요: \(reason)")
                lastResult = result
                lastUpdatedAt = Date()
                return result
            }
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
    ///
    /// **Deprecated (v1.20.31)**: `blendedPose(walkingPose:alpha:)` 사용 권장 —
    /// 새 method 가 실 joint-wise overlay 구현 + alpha 지원. 본 method 는 caller
    /// 호환을 위해 유지, 내부는 동일 구현 위임.
    public func blendedPose(walkBasePose: RobotPose) -> RobotPose {
        return blendedPose(walkingPose: walkBasePose, alpha: 1.0)
    }

    /// **v1.20.31 (2026-05-22) — joint-wise blending 실 구현**.
    ///
    /// 보행 base pose 위에 upper motion descriptor 의 target joint 를 덮어쓰거나
    /// (alpha=1.0) 선형 보간 (0<alpha<1) 한다.
    ///
    /// # 비유
    ///
    /// DJ 의 mixer crossfader — `alpha=1.0` 이면 upper deck 만 출력, `alpha=0` 이면
    /// lower deck (walking) 만. 그 사이는 두 신호의 선형 합성. **단**, override 는
    /// upper motion 이 점유한 joint 에만 적용 — 점유 안 한 joint 는 walkingPose 그대로.
    ///
    /// # 동작
    ///
    /// 1. **teach 자세** (전신 점유) — walkingPose 무시, teach pose 자체 반환.
    /// 2. **upper 채널 nil** — walkingPose 그대로.
    /// 3. **upper 가 page** — `v1TargetPoseID` 가 `PoseLibrary` 의 자세를 가리키면
    ///    그 자세의 joint 중 page `bodyRegions` 가 점유한 joint 만 override.
    ///    v1TargetPoseID nil 이면 (e.g., chain page) override skip.
    /// 4. **upper 가 walk** — 발생 불가 (walk 는 lower channel) — walkingPose 그대로.
    /// 5. **lower 채널 (walk preset)** — walkingPose 가 이미 그 결과이므로 그대로
    ///    base 로 사용. 추가 처리 없음.
    ///
    /// - Parameters:
    ///   - walkingPose: 보행 module 의 현 step pose (lower body 결정).
    ///   - alpha: upper override 강도 (0..1). 1.0 = full override, 0 = walking 만,
    ///            0.5 = 중간. 범위 밖은 자동 clamp.
    /// - Returns: blended `RobotPose` — 새 인스턴스 (immutable).
    public func blendedPose(walkingPose: RobotPose, alpha: Double = 1.0) -> RobotPose {
        let blend = alpha.clamped(to: 0.0...1.0)

        // 1) teach 자세 — 전신 점유 (lower 에 저장됨). walkingPose 무시.
        if let lowerDescriptor = lower, case .teach(let snap) = lowerDescriptor {
            return snap.pose
        }
        // 2) page 가 lower 에 저장된 경우 (acceptedFullBody 분기) — page 전신 점유.
        //    v1TargetPoseID 매핑이 있으면 그 pose 사용, 없으면 walking 유지.
        if let lowerDescriptor = lower, case .page(let meta) = lowerDescriptor,
           !meta.bodyRegions.isEmpty,
           Set(meta.bodyRegions).contains(.rightLeg) || Set(meta.bodyRegions).contains(.leftLeg),
           !isUpperOnlyPage(meta) {
            // 전신 또는 lower 점유 page — v1TargetPoseID 없으면 walking 유지.
            guard let poseID = meta.v1TargetPoseID,
                  let named = PoseLibrary.get(poseID) else {
                return walkingPose
            }
            // page 가 점유한 joint 만 override.
            return overlay(base: walkingPose, target: named.pose, regions: Set(meta.bodyRegions), alpha: blend)
        }

        // 3) upper 채널 nil → walking 그대로.
        guard let upperDescriptor = upper else {
            return walkingPose
        }

        // 4) upper descriptor → target pose 추출.
        guard let targetPose = upperTargetPose(for: upperDescriptor) else {
            // 매핑 안 됨 (chain page 등) — walking 유지.
            return walkingPose
        }

        // 5) upper 가 점유한 joint 만 overlay.
        let regions = upperDescriptor.bodyRegions
        return overlay(base: walkingPose, target: targetPose, regions: regions, alpha: blend)
    }

    /// upper descriptor 의 target RobotPose 추출.
    /// - walk: nil (walk 는 lower channel, upper 가 walk 인 경우는 비정상).
    /// - page: `v1TargetPoseID` → `PoseLibrary` 매핑. nil 이면 nil 반환.
    /// - teach: snapshot pose 그대로.
    private func upperTargetPose(for descriptor: MotionDescriptor) -> RobotPose? {
        switch descriptor {
        case .walk:
            return nil
        case .page(let meta):
            guard let poseID = meta.v1TargetPoseID else { return nil }
            return PoseLibrary.get(poseID)?.pose
        case .teach(let snap):
            return snap.pose
        }
    }

    /// page 가 upper-only (lower joint 점유 X) 인지 — 즉 lower 에 저장될 일 없는 경우.
    /// 본 helper 는 `blendedPose` 의 분기에서 lower channel 의 page 가 진짜 lower
    /// 점유 page 인지 (e.g., get-up chain) 구분 용.
    private func isUpperOnlyPage(_ meta: MotionPageMetadata) -> Bool {
        let regions = Set(meta.bodyRegions)
        return !regions.contains(.rightLeg) && !regions.contains(.leftLeg)
    }

    /// joint-wise overlay — `regions` 에 속한 joint 만 base 와 target 의 alpha 보간.
    /// regions 밖 joint 는 base 그대로.
    private func overlay(
        base: RobotPose,
        target: RobotPose,
        regions: Set<JointID.BodyPart>,
        alpha: Double
    ) -> RobotPose {
        // alpha == 0 → base 그대로 (early exit, 새 인스턴스 회피).
        if alpha <= 0 { return base }
        var updates: [JointID: Int] = [:]
        for joint in JointID.allCases where regions.contains(joint.bodyPart) {
            let baseRaw = base.raw(joint)
            let targetRaw = target.raw(joint)
            if alpha >= 1.0 {
                updates[joint] = targetRaw
            } else {
                let blended = Double(baseRaw) + (Double(targetRaw) - Double(baseRaw)) * alpha
                updates[joint] = Int(blended.rounded())
            }
        }
        return base.with(updates)
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
