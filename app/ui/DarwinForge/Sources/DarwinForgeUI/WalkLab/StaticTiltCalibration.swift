import Foundation

/// **v1.11.3 (2026-05-18) — 정적 IMU 기울임 캘리브레이션 (P1.0)**.
///
/// 부호 컨벤션 진단 도구. 사용자가 robot 을 손으로 다섯 자세 (직립 / 앞·뒤·오·왼 30°)
/// 에 두고 각 5초 IMU 평균을 캡처 → `Diagnosis` 가 코드 컨벤션 (양수=앞기울/오른기울)
/// 과 실 robot 부호 일치 여부 판정.
///
/// **GPT 검증 (2026-05-18) 권고**: 부호 컨벤션을 코드로 바로 뒤집기 전, 정적 캘리브레이션
/// 을 한 차례 한 후 결과 기반 결정. 이 데이터가 P1.1 (정규화 변수 도입) 의 근거가 됨.
///
/// **Privacy**: 캡처 결과는 로컬에만 저장 (`~/Library/Application Support/DarwinForge/calibration/`).
public enum StaticTiltCalibration {

    /// 캘리브레이션 자세 (5축).
    public enum Axis: String, Codable, CaseIterable, Sendable, Identifiable {
        case upright       // 직립 — pitch≈0, roll≈0 expected
        case forward30     // 앞으로 ~30° 숙임 — pitch sign 진단
        case backward30    // 뒤로 ~30° 젖힘 — pitch sign 진단
        case right30       // 오른쪽 ~30° 기울임 — roll sign 진단
        case left30        // 왼쪽 ~30° 기울임 — roll sign 진단

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .upright:    return "직립 (0°)"
            case .forward30:  return "앞으로 30° 숙임"
            case .backward30: return "뒤로 30° 젖힘"
            case .right30:    return "오른쪽 30° 기울임"
            case .left30:     return "왼쪽 30° 기울임"
            }
        }

        /// 사용자 안내 — 어떻게 robot 을 잡으면 되는지.
        public var instruction: String {
            switch self {
            case .upright:    return "robot 을 거치대 위에 직립 자세로. 5초 동안 가만히."
            case .forward30:  return "robot 상체를 앞으로 약 30° 숙임. 5초 유지."
            case .backward30: return "robot 상체를 뒤로 약 30° 젖힘. 5초 유지."
            case .right30:    return "robot 을 robot 의 오른쪽 (사용자 시점 왼쪽) 으로 30° 기울임. 5초 유지."
            case .left30:     return "robot 을 robot 의 왼쪽 (사용자 시점 오른쪽) 으로 30° 기울임. 5초 유지."
            }
        }
    }

    /// 단일 IMU 샘플 (roll/pitch deg, signed).
    public struct Sample: Codable, Equatable, Sendable {
        public let rollDeg: Double
        public let pitchDeg: Double
        /// elapsed ms from capture start.
        public let tMs: Double

        public init(rollDeg: Double, pitchDeg: Double, tMs: Double) {
            self.rollDeg = rollDeg
            self.pitchDeg = pitchDeg
            self.tMs = tMs
        }
    }

    /// 한 자세의 캡처 결과.
    public struct Capture: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let axis: Axis
        public let startTimeIso: String
        public let durationSec: Double
        public let samples: [Sample]
        /// IMU 출처 — "sim" / "real" / "stale".
        public let imuSource: String

        public init(id: UUID = UUID(),
                    axis: Axis,
                    startTimeIso: String,
                    durationSec: Double,
                    samples: [Sample],
                    imuSource: String) {
            self.id = id
            self.axis = axis
            self.startTimeIso = startTimeIso
            self.durationSec = durationSec
            self.samples = samples
            self.imuSource = imuSource
        }

        /// 캡처 sample 통계 — mean / std / min / max.
        public var summary: Summary { Summary(samples: samples) }

        public struct Summary: Equatable, Sendable {
            public let meanRoll: Double
            public let meanPitch: Double
            public let stdRoll: Double
            public let stdPitch: Double
            public let minRoll: Double
            public let maxRoll: Double
            public let minPitch: Double
            public let maxPitch: Double
            public let sampleCount: Int

            public init(samples: [Sample]) {
                let n = samples.count
                self.sampleCount = n
                guard n > 0 else {
                    self.meanRoll = 0; self.meanPitch = 0
                    self.stdRoll = 0; self.stdPitch = 0
                    self.minRoll = 0; self.maxRoll = 0
                    self.minPitch = 0; self.maxPitch = 0
                    return
                }
                let rolls = samples.map(\.rollDeg)
                let pitches = samples.map(\.pitchDeg)
                let mr = rolls.reduce(0, +) / Double(n)
                let mp = pitches.reduce(0, +) / Double(n)
                self.meanRoll = mr
                self.meanPitch = mp
                self.minRoll = rolls.min() ?? 0
                self.maxRoll = rolls.max() ?? 0
                self.minPitch = pitches.min() ?? 0
                self.maxPitch = pitches.max() ?? 0
                // population std (Bessel 보정 없음 — sample 많을 때 차이 무시할 수 있음).
                let vr = rolls.map { ($0 - mr) * ($0 - mr) }.reduce(0, +) / Double(n)
                let vp = pitches.map { ($0 - mp) * ($0 - mp) }.reduce(0, +) / Double(n)
                self.stdRoll = sqrt(vr)
                self.stdPitch = sqrt(vp)
            }
        }
    }

    /// 5축 캡처 1세트 → 부호 컨벤션 진단.
    public struct Diagnosis: Equatable, Sendable {
        /// 코드 컨벤션 (BalanceCorrector 의 forwardPitchErrDeg 양수=앞기울) 와 실 robot
        /// 부호 일치 여부.
        /// - `true`: imuPitch 양수 = 앞기울 (코드 컨벤션 그대로 OK).
        /// - `false`: imuPitch 음수 = 앞기울 (정규화 필요, `forwardPitchErrDeg = -imuPitchDeg`).
        /// - `nil`: 데이터 부족 / 모호.
        public let pitchPositiveMeansForward: Bool?

        /// 코드 컨벤션 (rollErrDeg 양수=오른쪽기울) 와 실 robot 부호 일치 여부.
        public let rollPositiveMeansRight: Bool?

        /// 진단 신뢰도 0..1. forward-backward 차이가 명확하면 1, 모호하면 0.
        public let confidence: Double

        /// 사용자 친화 메시지 (한국어).
        public let notes: [String]

        public init(pitchPositiveMeansForward: Bool?,
                    rollPositiveMeansRight: Bool?,
                    confidence: Double,
                    notes: [String]) {
            self.pitchPositiveMeansForward = pitchPositiveMeansForward
            self.rollPositiveMeansRight = rollPositiveMeansRight
            self.confidence = confidence
            self.notes = notes
        }
    }

    /// 5축 캡처 set 으로부터 진단.
    ///
    /// - 판정 기준 (각 축 ≥ 10 sample, std < 5° 안정):
    ///   - forward30 의 meanPitch 와 backward30 의 meanPitch 부호 비교.
    ///     forward 가 양수면 코드 컨벤션 일치, 음수면 반전 필요.
    ///   - right30 / left30 의 meanRoll 부호 비교 동일.
    /// - 신뢰도: |forwardPitch - backwardPitch| / 60° (= 30° 사이 거리 기대).
    ///   클수록 confidence ↑. 0.5 이하면 모호로 판정.
    public static func diagnose(captures: [Capture]) -> Diagnosis {
        var notes: [String] = []
        let byAxis = Dictionary(grouping: captures, by: \.axis)

        // forward/backward → pitch sign
        var pitchVerdict: Bool? = nil
        var pitchConfidence: Double = 0
        if let fwd = byAxis[.forward30]?.last, let bwd = byAxis[.backward30]?.last {
            let fwdMean = fwd.summary.meanPitch
            let bwdMean = bwd.summary.meanPitch
            let separation = abs(fwdMean - bwdMean)
            notes.append("forward30 meanPitch=\(String(format: "%.2f", fwdMean))°, backward30 meanPitch=\(String(format: "%.2f", bwdMean))°, |Δ|=\(String(format: "%.2f", separation))°")
            // separation 이 30° 보다 작으면 sample 부족 / 자세 부정확.
            if separation < 15 {
                notes.append("⚠️ forward-backward pitch 차이가 15° 미만 — 자세 재확인 필요")
                pitchConfidence = 0
            } else {
                pitchConfidence = min(1.0, separation / 60.0)
                if fwdMean > bwdMean {
                    pitchVerdict = true   // forward 가 더 양수 → 코드 컨벤션 OK
                    notes.append("✅ imuPitch 양수 = 앞기울 (코드 컨벤션 일치)")
                } else {
                    pitchVerdict = false  // forward 가 더 음수 → 정규화 필요
                    notes.append("⚠️ imuPitch 음수 = 앞기울 — corrections() 입력 시 negate 필요")
                }
            }
        } else {
            notes.append("ℹ️ forward30 또는 backward30 캡처 없음 — pitch 부호 진단 불가")
        }

        // right/left → roll sign
        var rollVerdict: Bool? = nil
        var rollConfidence: Double = 0
        if let r = byAxis[.right30]?.last, let l = byAxis[.left30]?.last {
            let rMean = r.summary.meanRoll
            let lMean = l.summary.meanRoll
            let separation = abs(rMean - lMean)
            notes.append("right30 meanRoll=\(String(format: "%.2f", rMean))°, left30 meanRoll=\(String(format: "%.2f", lMean))°, |Δ|=\(String(format: "%.2f", separation))°")
            if separation < 15 {
                notes.append("⚠️ right-left roll 차이가 15° 미만 — 자세 재확인 필요")
                rollConfidence = 0
            } else {
                rollConfidence = min(1.0, separation / 60.0)
                if rMean > lMean {
                    rollVerdict = true
                    notes.append("✅ imuRoll 양수 = 오른쪽 기울 (코드 컨벤션 일치)")
                } else {
                    rollVerdict = false
                    notes.append("⚠️ imuRoll 음수 = 오른쪽 기울 — corrections() 입력 시 negate 필요")
                }
            }
        } else {
            notes.append("ℹ️ right30 또는 left30 캡처 없음 — roll 부호 진단 불가")
        }

        // upright drift 확인
        if let u = byAxis[.upright]?.last {
            let s = u.summary
            notes.append("upright meanPitch=\(String(format: "%.2f", s.meanPitch))°, meanRoll=\(String(format: "%.2f", s.meanRoll))° (drift)")
            if abs(s.meanPitch) > 5 {
                notes.append("⚠️ 직립 자세 pitch drift \(String(format: "%.1f", abs(s.meanPitch)))° > 5° — walkReady trim 필요")
            }
            if abs(s.meanRoll) > 5 {
                notes.append("⚠️ 직립 자세 roll drift \(String(format: "%.1f", abs(s.meanRoll)))° > 5°")
            }
        }

        // overall confidence
        let overallConfidence = (pitchConfidence + rollConfidence) / 2.0

        return Diagnosis(
            pitchPositiveMeansForward: pitchVerdict,
            rollPositiveMeansRight: rollVerdict,
            confidence: overallConfidence,
            notes: notes
        )
    }
}
