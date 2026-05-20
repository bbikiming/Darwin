import Foundation

/// 실험 목적 분류 — 어떤 의도로 데이터가 수집됐는지.
///
/// `safetyIncident` 는 emergency / fall 등이 발생한 세션 — 자동 튜닝에서 분리한다.
/// `signDiagnostic*` 은 반대 부호 실험 — observe-only 가 기본.
public enum WalkTrialPurpose: String, Codable, Sendable, CaseIterable {
    case calibrationIdle
    case baselineLegacy
    case robotisPControl
    case hybridObserveOnly
    case hybridApplied
    case signDiagnosticObserveOnly
    case signDiagnosticApplied
    case safetyIncident
    case unknown
}

/// 자동 추천 액션. low-quality 데이터에서는 절대 `raiseIntensity` 가 나오면 안 된다.
public enum RecommendationAction: String, Codable, Sendable, CaseIterable {
    case keepCurrent
    case lowerIntensity
    case raiseIntensity
    case switchToObserveOnly
    case markSignSuspicious
    case markHybridPhaseSuspicious
    case collectMoreData
    case doNotUseForLearning
}

/// 세션 단위 추천. summary 에 같이 저장.
public struct WalkSessionRecommendation: Codable, Equatable, Sendable {
    public let action: RecommendationAction
    public let confidence: Double
    public let reason: String
    public let recommendedIntensityLevel: Int?
    public let trialPurpose: WalkTrialPurpose

    public init(action: RecommendationAction,
                confidence: Double,
                reason: String,
                recommendedIntensityLevel: Int? = nil,
                trialPurpose: WalkTrialPurpose = .unknown) {
        self.action = action
        self.confidence = max(0, min(1, confidence))
        self.reason = reason
        self.recommendedIntensityLevel = recommendedIntensityLevel
        self.trialPurpose = trialPurpose
    }

    public var isSafeForAutoApply: Bool {
        switch action {
        case .raiseIntensity, .markSignSuspicious, .markHybridPhaseSuspicious:
            // 위험도 있는 권고 — quality + confidence 게이트 통과한 호출자만 적용 결정.
            return false
        case .lowerIntensity, .switchToObserveOnly:
            // 안전 방향이라 자동 적용 허용 (사용자 토글이 켜진 경우에 한해).
            return true
        case .keepCurrent, .collectMoreData, .doNotUseForLearning:
            return true
        }
    }
}

/// 라벨 helper.
public enum WalkRecommendationLabels {
    public static func actionLabel(_ action: RecommendationAction) -> String {
        switch action {
        case .keepCurrent: return "현재 설정 유지"
        case .lowerIntensity: return "보정 강도 한 단계 낮춤"
        case .raiseIntensity: return "보정 강도 한 단계 올림"
        case .switchToObserveOnly: return "관찰 모드로 전환"
        case .markSignSuspicious: return "부호 의심 — 같은 조건에서 재확인 필요"
        case .markHybridPhaseSuspicious: return "Hybrid 위상 의심 — 검증 필요"
        case .collectMoreData: return "데이터 더 모으기 권장"
        case .doNotUseForLearning: return "학습/추천에 사용하지 않음"
        }
    }

    public static func purposeLabel(_ purpose: WalkTrialPurpose) -> String {
        switch purpose {
        case .calibrationIdle: return "보정 캘리브레이션"
        case .baselineLegacy: return "구버전 기록 (베이스라인)"
        case .robotisPControl: return "ROBOTIS P-control"
        case .hybridObserveOnly: return "Hybrid (관찰만)"
        case .hybridApplied: return "Hybrid (실 적용)"
        case .signDiagnosticObserveOnly: return "부호 진단 (관찰만)"
        case .signDiagnosticApplied: return "부호 진단 (실 적용)"
        case .safetyIncident: return "안전 사고 발생"
        case .unknown: return "분류 불가"
        }
    }
}
