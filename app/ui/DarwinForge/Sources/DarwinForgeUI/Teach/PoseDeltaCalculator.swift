import Foundation
import ForgeCore

/// 사이클 207 (Teach P2): 두 RobotPose 간 joint-by-joint 차이 계산 — pure logic.
///
/// # 비유
///
/// 두 사진의 색상 차이 비교 — 픽셀(관절)별 RGB delta(각도 delta)의 평균 / 최대.
/// 픽셀 하나가 크게 다르면 peak, 전체 분산이 크면 RMS 가 높다.
public enum PoseDeltaCalculator {

    /// 관절 하나의 비교 결과.
    public struct JointDelta: Equatable, Sendable {
        /// `JointID.rawValue` (1..20).
        public let jointId: Int
        /// `JointID.name` — UI 표시용 영문 식별자.
        public let jointName: String
        /// 기준(baseline) 자세의 해당 관절 각도(도).
        public let baselineDeg: Double
        /// 비교(candidate) 자세의 해당 관절 각도(도).
        public let candidateDeg: Double
        /// `candidateDeg - baselineDeg`.
        public let deltaDeg: Double
        /// `|deltaDeg|`.
        public var absDeltaDeg: Double { abs(deltaDeg) }
    }

    /// 두 자세 전체 비교 결과.
    public struct Comparison: Equatable, Sendable {
        /// 기준 자세 레이블.
        public let baselineLabel: String
        /// 비교 자세 레이블.
        public let candidateLabel: String
        /// `JointID.allCases` 순서의 관절별 delta.
        public let perJointDeltas: [JointDelta]
        /// RMS(root mean square) of |delta| — 전체 차이 magnitude 스칼라.
        public let rmsDeg: Double
        /// `|delta|` 가 가장 큰 관절. 관절이 없으면 nil.
        public let peakJoint: JointDelta?
    }

    // MARK: - Public API

    /// 두 자세를 관절별로 비교한다.
    ///
    /// - Parameters:
    ///   - baseline: 기준 자세.
    ///   - candidate: 비교 자세.
    ///   - baselineLabel: UI 표시용 기준 레이블.
    ///   - candidateLabel: UI 표시용 비교 레이블.
    /// - Returns: `Comparison` — perJointDeltas 는 `JointID.allCases` 순, RMS 및 peak 포함.
    public static func compare(
        baseline: RobotPose,
        candidate: RobotPose,
        baselineLabel: String,
        candidateLabel: String
    ) -> Comparison {
        let joints = JointID.allCases

        let deltas: [JointDelta] = joints.map { joint in
            let base = baseline.degrees(joint)
            let cand = candidate.degrees(joint)
            return JointDelta(
                jointId: Int(joint.rawValue),
                jointName: joint.name,
                baselineDeg: base,
                candidateDeg: cand,
                deltaDeg: cand - base
            )
        }

        let count = Double(deltas.count)
        let rms: Double = {
            guard count > 0 else { return 0 }
            let sumOfSquares = deltas.reduce(0.0) { $0 + $1.deltaDeg * $1.deltaDeg }
            return (sumOfSquares / count).squareRoot()
        }()

        let peak = deltas.max(by: { $0.absDeltaDeg < $1.absDeltaDeg })

        return Comparison(
            baselineLabel: baselineLabel,
            candidateLabel: candidateLabel,
            perJointDeltas: deltas,
            rmsDeg: rms,
            peakJoint: peak
        )
    }
}
