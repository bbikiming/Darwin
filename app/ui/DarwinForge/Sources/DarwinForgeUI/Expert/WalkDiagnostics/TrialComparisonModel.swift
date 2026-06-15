import Foundation

/// 사이클 183 (P1 #3.5 fix, cycle 177 audit): 두 trial outcome 의 정량 비교 — pure logic.
///
/// # 비유
///
/// 학생 의 시험 점수 비교 — 두 시험 의 같은 과목 점수 가 좋아졌나 나빠졌나 한눈에. 본 모듈
/// 은 두 WalkTrial 의 metric 을 받아 "+1.2°↓" 같은 한국어 directional label 생성. view
/// 격리 — 테스트 가능.
///
/// # 디자인
///
/// - 두 trial 이 모두 있어야 비교 — nil 처리 caller 책임.
/// - "개선" 방향 (lower is better for roll/pitch, higher for scores) 자동 해석.
/// - 한국어 + emoji-free — 사용자 도 분석가 도 동일 의미.
public enum TrialComparisonModel {

    /// 한 metric 의 비교 결과.
    public struct MetricDelta: Equatable, Sendable {
        /// 사용자 표시 라벨 (예: "안정성", "최대 roll").
        public let label: String
        /// baseline 값.
        public let baseline: Double
        /// candidate 값.
        public let candidate: Double
        /// 단위 ("°", "" 등).
        public let unit: String
        /// 소수점 자리 수.
        public let decimals: Int
        /// "lower is better" (peak roll 등) vs "higher is better" (score 등).
        public let lowerIsBetter: Bool

        public var delta: Double { candidate - baseline }

        /// 개선 여부 — direction + lowerIsBetter 고려.
        public var isImprovement: Bool {
            lowerIsBetter ? (delta < 0) : (delta > 0)
        }

        /// 한국어 directional 라벨 — "+1.2°↓ 개선" / "−0.05↑ 악화" 등.
        public var koreanLabel: String {
            let baseStr = String(format: "%.\(decimals)f", baseline)
            let candStr = String(format: "%.\(decimals)f", candidate)
            let deltaStr = String(format: "%+.\(decimals)f", delta)
            let arrow: String
            if abs(delta) < 0.0001 {
                arrow = "≈"
            } else if isImprovement {
                arrow = lowerIsBetter ? "↓" : "↑"
            } else {
                arrow = lowerIsBetter ? "↑" : "↓"
            }
            let verdict = abs(delta) < 0.0001 ? "동일" : (isImprovement ? "개선" : "악화")
            return "\(baseStr)\(unit) → \(candStr)\(unit) (\(deltaStr)\(unit) \(arrow) \(verdict))"
        }
    }

    /// 한 비교 view — baseline trial 의 4 핵심 metric 과 candidate 의 차이.
    public struct Comparison: Equatable, Sendable {
        public let baselineId: String
        public let candidateId: String
        public let metrics: [MetricDelta]

        /// 전체 개선 메트릭 비율 (0..1). 1 = 모두 개선.
        public var improvementRatio: Double {
            guard !metrics.isEmpty else { return 0 }
            let improved = metrics.filter { $0.isImprovement }.count
            return Double(improved) / Double(metrics.count)
        }

        /// 한국어 summary — "5 중 4 개선" 등.
        public var summaryLabel: String {
            let improved = metrics.filter { $0.isImprovement }.count
            let total = metrics.count
            return "\(total) 중 \(improved) 개선 (\(Int(improvementRatio * 100))%)"
        }
    }

    /// 두 TrialOutcome 의 4 핵심 metric 비교 생성.
    /// - Parameters:
    ///   - baselineId: baseline trial id (UI 식별용).
    ///   - candidateId: candidate trial id.
    ///   - baseline: 기준 outcome (예: 과거 trial).
    ///   - candidate: 비교 대상 outcome (예: 현재 / 최근 trial).
    /// - Returns: 4 metric (안정성 / 부드러움 / 최대 roll / 최대 pitch) 비교.
    public static func compare(
        baselineId: String,
        candidateId: String,
        baseline: TrialOutcome,
        candidate: TrialOutcome
    ) -> Comparison {
        let metrics: [MetricDelta] = [
            MetricDelta(
                label: "안정성",
                baseline: baseline.stabilityScore,
                candidate: candidate.stabilityScore,
                unit: "",
                decimals: 2,
                lowerIsBetter: false
            ),
            MetricDelta(
                label: "부드러움",
                baseline: baseline.smoothnessScore,
                candidate: candidate.smoothnessScore,
                unit: "",
                decimals: 2,
                lowerIsBetter: false
            ),
            MetricDelta(
                label: "최대 |roll|",
                baseline: baseline.peakAbsRollDeg,
                candidate: candidate.peakAbsRollDeg,
                unit: "°",
                decimals: 1,
                lowerIsBetter: true
            ),
            MetricDelta(
                label: "최대 |pitch|",
                baseline: baseline.peakAbsPitchDeg,
                candidate: candidate.peakAbsPitchDeg,
                unit: "°",
                decimals: 1,
                lowerIsBetter: true
            )
        ]
        return Comparison(
            baselineId: baselineId,
            candidateId: candidateId,
            metrics: metrics
        )
    }
}
