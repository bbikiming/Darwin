import ForgeCore
import Foundation

/// **v1.18.0 (2026-05-21) Phase 3 — 통합 motion identifier**.
///
/// WalkLabPreset / MotionPage / Teach capture 를 단일 enum 으로 통합.
/// critic + architect 권고 반영:
/// - `BodyRegion` enum 신설 X — 기존 `JointID.BodyPart` 재사용
/// - composite 는 enum case 아닌 별도 `struct CompositeMotion` (재귀 enum 회피)
/// - `case teach(TeachCapture.PoseSnapshot)` — value type, Sendable 호환
public enum MotionDescriptor: Identifiable, Sendable {
    /// 보행 preset — WalkLabSession 의 walking module amplitude 송출.
    case walk(WalkLabPreset)
    /// motion_4096.bin 페이지 — 단발 자세 또는 chain.
    case page(MotionPageMetadata)
    /// 사용자 teach 자세 — value type snapshot.
    case teach(TeachCapture.PoseSnapshot)

    public var id: String {
        switch self {
        case .walk(let preset):          return "walk:\(preset.rawValue)"
        case .page(let meta):            return "page:\(meta.slot)"
        case .teach(let snap):           return "teach:\(snap.id.uuidString)"
        }
    }

    /// 한국어 표시 라벨 — UI 카드 / HUD 용.
    public var displayLabel: String {
        switch self {
        case .walk(let preset):          return preset.label
        case .page(let meta):            return meta.displayNameKo
        case .teach(let snap):           return "🎓 \(snap.name)"
        }
    }

    /// 영향 받는 body region — composite 의 IK 충돌 검출에 사용.
    public var bodyRegions: Set<JointID.BodyPart> {
        switch self {
        case .walk:
            // walking 은 다리 + arm swing (rShoulderPitch / lShoulderPitch 만).
            // architect 권고: arm swing 의 충돌 검출은 별도 (composite 시).
            return [.rightLeg, .leftLeg]
        case .page(let meta):
            return Set(meta.bodyRegions)
        case .teach:
            // teach snapshot 은 전신 자세 — 모든 region 점유 가정 (보수적).
            return Set(JointID.BodyPart.allCases)
        }
    }

    /// 안전 등급 — composite 시 max (most restrictive) 선택.
    public var safetyClass: SafetyClass {
        switch self {
        case .walk(let preset):
            // walk preset 의 safety 는 highRisk (jog) 부터 safe (slowWalk) 까지.
            // 단순 mapping — preset.safety 가 별도 enum 이라면 변환.
            return preset.safety.toMotionSafetyClass
        case .page(let meta):
            return meta.safetyClass
        case .teach:
            // teach 는 사용자 자세 — caution default (검증 안 됨).
            return .caution
        }
    }

    /// blendable — composite 의 다른 motion 과 동시 실행 가능 여부.
    /// walk 는 lower channel 점유라 upper-only motion 과 blend 가능.
    /// page 는 bodyRegions 가 단일 channel 일 때만.
    public var isBlendable: Bool {
        // composite 자체는 enum 에 없음 — 모든 case 가 blendable candidate.
        let regions = bodyRegions
        let lowerCount = regions.filter { $0.isLower }.count
        let upperCount = regions.filter { $0.isUpper }.count
        // 한 channel 에만 속하면 blend 가능. 둘 다 점유면 X.
        return !(lowerCount > 0 && upperCount > 0)
    }

    /// 활용 motion channel (lower 만 / upper 만 / both).
    public var occupiedChannels: Set<MotionChannel> {
        var channels: Set<MotionChannel> = []
        let regions = bodyRegions
        if regions.contains(where: { $0.isLower }) { channels.insert(.lower) }
        if regions.contains(where: { $0.isUpper }) { channels.insert(.upper) }
        return channels
    }
}

// MARK: - WalkLabSafety → SafetyClass 매핑

extension WalkLabSafety {
    fileprivate var toMotionSafetyClass: SafetyClass {
        switch self {
        case .safe:        return .safe
        case .caution:     return .caution
        case .highRisk:    return .highRisk
        }
    }
}

// MARK: - MotionDescriptor Equatable + Hashable (associated value 비교)

/// **v1.18.0.1 fix (코덱스 HIGH 1)**: 종전 id 기반 비교는 같은 slot 의 page 가 다른
/// displayName/safetyClass 를 가져도 == 처리 → composite safety max 산출 시 stale 값
/// 위험. associated value 자체 비교로 변경.
extension MotionDescriptor: Equatable, Hashable {
    public static func == (lhs: MotionDescriptor, rhs: MotionDescriptor) -> Bool {
        switch (lhs, rhs) {
        case (.walk(let a), .walk(let b)):
            return a == b
        case (.page(let a), .page(let b)):
            // MotionPageMetadata 는 Equatable — 모든 stored field 비교.
            return a == b
        case (.teach(let a), .teach(let b)):
            return a == b
        default:
            return false
        }
    }
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .walk(let p):
            hasher.combine(0)
            hasher.combine(p.rawValue)
        case .page(let m):
            hasher.combine(1)
            hasher.combine(m.slot)
            hasher.combine(m.safetyClass.rawValue)
        case .teach(let s):
            hasher.combine(2)
            hasher.combine(s.id)
        }
    }
}

// MARK: - CompositeMotion

/// **architect FIX-2**: composite 는 enum 재귀가 아닌 별도 struct.
/// 두 MotionDescriptor 의 동시 실행 — `init` 시 channel 충돌 자동 검출.
public struct CompositeMotion: Sendable, Equatable, Hashable {
    public let lower: MotionDescriptor
    public let upper: MotionDescriptor

    /// init 실패 가능 — channel 충돌 시 nil.
    public init?(lower: MotionDescriptor, upper: MotionDescriptor) {
        // 1) channel 분리 검증.
        let lowerChannels = lower.occupiedChannels
        let upperChannels = upper.occupiedChannels
        // lower 가 upper channel 도 점유 OR upper 가 lower channel 도 점유 → 충돌.
        if lowerChannels.contains(.upper) || upperChannels.contains(.lower) {
            return nil
        }
        // 2) 둘 다 비어있으면 의미 X.
        if lowerChannels.isEmpty || upperChannels.isEmpty {
            return nil
        }
        // 3) 같은 channel (e.g., 둘 다 upper) 는 같은 motion 으로 통합 의미 — 거부.
        if lowerChannels == upperChannels {
            return nil
        }
        self.lower = lower
        self.upper = upper
    }

    /// 종합 safety — 두 component 의 max (most restrictive).
    public var safetyClass: SafetyClass {
        let a = lower.safetyClass
        let b = upper.safetyClass
        return max(a, b)
    }

    /// 종합 body regions — 두 component 의 union.
    public var bodyRegions: Set<JointID.BodyPart> {
        lower.bodyRegions.union(upper.bodyRegions)
    }
}

// MARK: - SafetyClass ordering

extension SafetyClass: Comparable {
    /// safe < caution < highRisk — composite 의 max 산출 가능.
    public static func < (lhs: SafetyClass, rhs: SafetyClass) -> Bool {
        lhs.rank < rhs.rank
    }

    var rank: Int {
        switch self {
        case .safe:     return 0
        case .caution:  return 1
        case .highRisk: return 2
        }
    }
}
