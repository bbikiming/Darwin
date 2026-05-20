import Foundation

/// 세션 데이터가 어떤 용도로 쓸 수 있는지 분류.
///
/// 원칙:
/// - `usableForComparison` 은 알고리즘 A/B 판정까지 허용한 최고 등급.
/// - `usableForBiasOnly` 는 만성 pitch/roll bias 추정만 허용 — 보정 효과 비교 금지.
/// - `usableForSafetyReview` 는 emergency / fall 분석 전용.
/// - `inconclusive` 는 평균은 봐도 되지만 추천 결정에는 못 쓴다.
/// - `rejected` 는 학습/추천에서 완전 제외.
public enum WalkSessionUseClass: String, Codable, Sendable, CaseIterable {
    case usableForComparison
    case usableForBiasOnly
    case usableForSafetyReview
    case inconclusive
    case rejected
}

/// 등급 A..F — 5 단계. A 가 가장 신뢰도 높음.
public enum WalkSessionGrade: String, Codable, Sendable, CaseIterable {
    case A
    case B
    case C
    case D
    case F

    /// 비교를 위한 정렬 우선순위 (낮을수록 좋음).
    public var rank: Int {
        switch self {
        case .A: return 0
        case .B: return 1
        case .C: return 2
        case .D: return 3
        case .F: return 4
        }
    }
}

/// 사용자가 왜 데이터가 탈락했는지 / 어느 용도까지 쓸 수 있는지 보는 사유 코드.
public enum WalkSessionQualityReason: String, Codable, Sendable, CaseIterable {
    case durationTooShort
    case independentImuTooLow
    case duplicateRatioTooHigh
    case staleRatioTooHigh
    case emergencyStopped
    case busFailuresPresent
    case legacySchemaMissingFields
    case algorithmFieldsMissing
    case supportModeUnknown
    case schemaIncomplete
    case healthy
}

/// 세션의 품질 지표 + 등급 + 분류. session summary 와 함께 저장된다.
public struct WalkSessionDataQuality: Codable, Equatable, Sendable {
    public let useClass: WalkSessionUseClass
    public let grade: WalkSessionGrade
    public let reasons: [WalkSessionQualityReason]

    public let durationSec: Double
    public let sampleCount: Int
    public let independentImuSampleCount: Int
    public let imuDuplicateRatio: Double
    public let nominalSampleRateHz: Double
    public let effectiveImuRateHz: Double

    public let medianImuAgeMs: Double?
    public let p95ImuAgeMs: Double?
    public let staleRatio: Double

    public let busFailureCount: Int
    public let emergencyCount: Int

    public init(useClass: WalkSessionUseClass,
                grade: WalkSessionGrade,
                reasons: [WalkSessionQualityReason],
                durationSec: Double,
                sampleCount: Int,
                independentImuSampleCount: Int,
                imuDuplicateRatio: Double,
                nominalSampleRateHz: Double,
                effectiveImuRateHz: Double,
                medianImuAgeMs: Double? = nil,
                p95ImuAgeMs: Double? = nil,
                staleRatio: Double = 0,
                busFailureCount: Int = 0,
                emergencyCount: Int = 0) {
        self.useClass = useClass
        self.grade = grade
        self.reasons = reasons
        self.durationSec = durationSec
        self.sampleCount = sampleCount
        self.independentImuSampleCount = independentImuSampleCount
        self.imuDuplicateRatio = imuDuplicateRatio
        self.nominalSampleRateHz = nominalSampleRateHz
        self.effectiveImuRateHz = effectiveImuRateHz
        self.medianImuAgeMs = medianImuAgeMs
        self.p95ImuAgeMs = p95ImuAgeMs
        self.staleRatio = staleRatio
        self.busFailureCount = busFailureCount
        self.emergencyCount = emergencyCount
    }
}

/// 사용자에게 보여지는 한국어 라벨. UI 가 직접 분기하지 말고 이 helper 를 쓴다.
public enum WalkSessionLabels {
    public static func useClassLabel(_ useClass: WalkSessionUseClass) -> String {
        switch useClass {
        case .usableForComparison: return "비교 가능"
        case .usableForBiasOnly: return "기울기 확인만 가능"
        case .usableForSafetyReview: return "안전 검토용"
        case .inconclusive: return "판단 불가"
        case .rejected: return "분석 제외"
        }
    }

    public static func gradeLabel(_ grade: WalkSessionGrade) -> String {
        "데이터 품질 \(grade.rawValue)"
    }

    public static func reasonLabel(_ reason: WalkSessionQualityReason) -> String {
        switch reason {
        case .durationTooShort: return "보행 시간 부족"
        case .independentImuTooLow: return "독립 IMU 샘플 부족"
        case .duplicateRatioTooHigh: return "IMU 중복률 높음"
        case .staleRatioTooHigh: return "IMU 신선도 부족"
        case .emergencyStopped: return "비상 정지 발생"
        case .busFailuresPresent: return "버스 통신 실패"
        case .legacySchemaMissingFields: return "구버전 스키마 (일부 필드 누락)"
        case .algorithmFieldsMissing: return "알고리즘 정보 누락 (비교 불가)"
        case .supportModeUnknown: return "지지 조건 불명"
        case .schemaIncomplete: return "스키마 불완전"
        case .healthy: return "정상"
        }
    }
}
