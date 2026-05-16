import Foundation
import ForgeCore

/// 모션 스튜디오 카탈로그의 15 카테고리.
///
/// v1.1 — 320+ 모션을 의미별 그룹으로 분류해 UI sidebar 에서 필터링 가능.
///
/// # 설계 결정 (UInt8 ID 한계)
///
/// `MotionPage.id` 가 `UInt8` (max 255) 라 단일 doc 안에서 320 unique 보장 불가.
/// **카테고리별 별도 `MotionDoc` 보관** 모델 채택:
/// - 카테고리 doc 안에서는 ID 1..=N (카테고리 내부 식별만).
/// - UI sidebar 가 카테고리 선택 → 해당 doc 으로 page list 전환.
/// - 기존 unified starter doc (`MotionStudioView.starterPages`) 는 "기본 자세" 카테고리
///   로 표시.
public enum MotionCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case basicPose
    case greeting
    case emotion
    case dance
    case stretch
    case yoga
    case martial
    case walkVariant
    case balance
    case gaze
    case demo
    case exercise
    case recovery
    case meditation
    case generated

    /// 사용자 표시명 (한국어).
    public var label: String {
        switch self {
        case .basicPose:    return "기본 자세"
        case .greeting:     return "인사·예의"
        case .emotion:      return "표현·감정"
        case .dance:        return "댄스·리듬"
        case .stretch:      return "운동·스트레칭"
        case .yoga:         return "요가·필라테스"
        case .martial:      return "태권도·무술"
        case .walkVariant:  return "보행 변형"
        case .balance:      return "균형·곡예"
        case .gaze:         return "시선·머리"
        case .demo:         return "데모·엔터테인"
        case .exercise:     return "체조·근력"
        case .recovery:     return "응급 복구"
        case .meditation:   return "정적·명상"
        case .generated:    return "합성·합본"
        }
    }

    /// SF Symbol 이름.
    public var icon: String {
        switch self {
        case .basicPose:    return "figure.stand"
        case .greeting:     return "hand.wave"
        case .emotion:      return "face.smiling"
        case .dance:        return "music.note"
        case .stretch:      return "figure.flexibility"
        case .yoga:         return "figure.yoga"
        case .martial:      return "figure.taichi"
        case .walkVariant:  return "figure.walk"
        case .balance:      return "scale.3d"
        case .gaze:         return "eye"
        case .demo:         return "sparkles"
        case .exercise:     return "dumbbell"
        case .recovery:     return "arrow.uturn.up"
        case .meditation:   return "leaf"
        case .generated:    return "wand.and.stars"
        }
    }

    /// 짧은 부연 설명 (sidebar tooltip).
    public var summary: String {
        switch self {
        case .basicPose:    return "walkReady·T-pose·중립 자세"
        case .greeting:     return "한국식 절·서양 wave·악수·합장"
        case .emotion:      return "OK·NO·놀람·생각·기쁨"
        case .dance:        return "K-pop 안무·트위스트·시미·스텝"
        case .stretch:      return "거북목·어깨·허리·다리 스트레칭"
        case .yoga:         return "warrior·tree·child pose 단순화"
        case .martial:      return "태권도 기본 정권·차기·막기"
        case .walkVariant:  return "보행 점진 테스트·측면·회전"
        case .balance:      return "한발서기·까치발·회전·lean"
        case .gaze:         return "head pan/tilt 시퀀스·둘러보기"
        case .demo:         return "마법사·노래·박수·환호"
        case .exercise:     return "jumping jacks·squat·lunge"
        case .recovery:     return "넘어진 후 일어나기 변형"
        case .meditation:   return "호흡·절·정적 자세"
        case .generated:    return "mirror/morph/sequence 산출물"
        }
    }

    /// 카탈로그 sidebar 표시 순서.
    public static let displayOrder: [MotionCategory] = [
        .basicPose, .greeting, .emotion, .dance, .stretch, .yoga, .martial,
        .walkVariant, .balance, .gaze, .demo, .exercise, .recovery, .meditation,
        .generated,
    ]
}

// MARK: - Legacy / 공식 페이지 매핑 (unified starter doc → 카테고리)
//
// `MotionStudioView.starterPages` 가 반환하는 unified doc 의 페이지를 카테고리별로
// 그룹화하는 데 사용. 신규 모션 doc 은 카테고리 메타 자체에서 분류되므로 본 매핑은
// **기존 starter doc 에 한정**.

public enum MotionCatalogIndex {
    /// Starter doc 의 페이지 ID → 카테고리 매핑.
    /// 매핑되지 않은 ID 는 `.basicPose` 로 fallback.
    public static func category(forStarterId pageId: UInt8) -> MotionCategory {
        switch pageId {
        // ROBOTIS gui_motion.yaml — 기본 자세 / Stand Up / Walk Ready
        case 1, 9, 15:
            return .basicPose
        // ROBOTIS 인사·작별 + greetings 130~134
        case 2, 3, 4, 38:
            return .greeting
        case 130, 131, 132, 133, 134:
            return .greeting
        // ROBOTIS 환호·Wow·Oops·Clap
        case 23, 24, 27, 54:
            return .emotion
        // ROBOTIS Get Up Front/Back
        case 10, 11:
            return .recovery
        // ROBOTIS Right/Left Kick + Hand Standing
        case 12, 13, 17:
            return .martial
        // Sprint 5 walk progression
        case 110...115:
            return .walkVariant
        // Ergonomic 케어
        case 120...125:
            return .stretch
        // HROS5 소셜
        case 140...143:
            return .demo
        // prebundled idle/tPose/bow/wave/sit + extras
        case 200...255:
            return .basicPose
        default:
            return .basicPose
        }
    }

    /// 페이지 list 를 카테고리별로 그룹화 (starter doc 전용).
    public static func groupStarter(pages: [MotionPage]) -> [MotionCategory: [MotionPage]] {
        var groups: [MotionCategory: [MotionPage]] = [:]
        for page in pages {
            let cat = category(forStarterId: page.id)
            groups[cat, default: []].append(page)
        }
        return groups
    }
}
