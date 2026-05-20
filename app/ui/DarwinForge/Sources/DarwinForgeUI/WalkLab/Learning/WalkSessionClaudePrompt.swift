import Foundation

/// **v1.11.9 (2026-05-19)** — Claude CLI 분석용 prompt 직렬화.
///
/// 보행 세션 데이터 (header + summary + sample 통계) + 사용자 자연어 보고를 markdown
/// prompt 로 변환. `WalkSessionClaudeAnalyst` 가 이걸 stdin 으로 claude CLI 에 전달.
///
/// **설계 원칙**:
/// - 토큰 절약: 모든 sample 보내지 않고 phase 별 통계 + outlier 만
/// - 명확한 구조: header → summary → phase 분석 → 사용자 보고 → 분석 요청
/// - 한국어 prompt — 한국어 응답 자연스럽게 받기
/// - axis 정의 prompt 안에 포함 (모델이 도메인 모름)
public enum WalkSessionClaudePrompt {

    /// 최대 분석 대상 세션 수 (token 한도 고려).
    public static let maxSessions: Int = 5

    /// 분석 prompt 생성.
    /// - Parameters:
    ///   - sessions: 분석할 세션 list (최신순). 최대 `maxSessions` 개만 사용.
    ///   - userReport: 사용자 자연어 보고. 빈 문자열 가능.
    ///   - sampleStatsBuilder: 각 세션의 phase 통계 builder (caller 가 sample 배열에서 계산).
    /// - Returns: markdown prompt string.
    public static func build(
        sessions: [WalkSessionSummary],
        userReport: String,
        sampleStatsBuilder: (String) -> [PhaseStats]
    ) -> String {
        var out = ""
        out += systemSection()
        out += "\n---\n\n"
        out += sessionsSection(sessions, sampleStatsBuilder: sampleStatsBuilder)
        out += "\n---\n\n"
        out += userReportSection(userReport)
        out += "\n---\n\n"
        out += analysisRequestSection()
        return out
    }

    // MARK: - Sections

    private static func systemSection() -> String {
        return #"""
        # ROBOTIS-OP2 humanoid robot 보행 데이터 분석 요청

        당신은 ROBOTIS-OP2 (DARwIn-OP) humanoid robot 의 보행 데이터 분석 전문가입니다.
        DarwinForge WalkLab 의 보행 세션 jsonl 로그를 받아 다음 분석을 제공합니다.

        ## 8 axis (분석 시 참고)

        1. `WalkingEngine`: `.macSparseKeyframe` (Mac 6 phase 합성, ~10Hz 등가) 또는 `.robotisOnboard` (robot 측 ROBOTIS Walking::GetInstance(), 125Hz)
        2. `algorithmMode`: `.off` / `.robotisPControl` / `.hybridBA` (slow EMA + phase residual) / `.observeOnly`
        3. `signConvention`: `.robotisWalkingCpp` (정상) / `.alternateDiagnostic` (sagittal 4관절 부호 반전, 진단)
        4. `gainProfile`: `.robotisOriginal` (anklePitch 0.9, hipRoll 0.5) / `.v110Experimental` (anklePitch 1.5, 실 fall 입증) / `.custom`
        5. `pitchInputConvention`: `.imuRaw` (default) / `.negateForwardIsNegative` (실 robot 부호 정규화)
        6. `applyToRobot`: bool — corrections 실 pose 적용 여부
        7. `enableBalanceCorrection`: bool — corrector master switch
        8. `hipPitchOffsetTrimDeg`: 0~20° (default 13° ROBOTIS 원본)

        ## 측정 metric

        - `imuPitchDeg`: 실 robot 에서 **앞기울 시 음수** (cm.rs::pitch_degrees + 마운트 방향), 코드 컨벤션은 양수=앞기울이라 부호 불일치 존재
        - `imuRollDeg`: 오른쪽 기울 시 양수 (~정상)
        - `correctorDeltas` (8 joint): rHipRoll, lHipRoll, rKnee, lKnee, rAnklePitch, lAnklePitch, rAnkleRoll, lAnkleRoll
        - `walkPhase01`: 0~1 (보행 cycle 내 위상, phase 0.03/0.18/0.42/0.52/0.68/0.92 sparse)
        - `meanAbsPitch / Roll`, `peakAbs`, `stdev`, `oscillationScore` (corrector zero-crossing Hz), `correctorEffectivenessScore` (corrector vs IMU tilt correlation, +1 회복 / 0 무관 / -1 fall 가속)
        """#
    }

    private static func sessionsSection(
        _ sessions: [WalkSessionSummary],
        sampleStatsBuilder: (String) -> [PhaseStats]
    ) -> String {
        var out = "## 분석 대상 세션 (최신순)\n\n"
        let limited = Array(sessions.prefix(maxSessions))
        if limited.isEmpty {
            return out + "(세션 없음)\n"
        }
        for (i, s) in limited.enumerated() {
            out += "### 세션 #\(i + 1): `\(s.id)` (\(s.preset))\n\n"
            out += "**Summary**:\n"
            out += "- 시작: \(s.startTimeIso), 길이: \(String(format: "%.1f", s.durationSec))s, samples: \(s.sampleCount)\n"
            out += "- intensity level: \(s.intensityLevelUsed)\n"
            out += "- meanAbsPitch: \(String(format: "%.2f", s.meanAbsPitch))° / peakAbsPitch: \(String(format: "%.2f", s.peakAbsPitch))° / pitchStdev: \(String(format: "%.2f", s.pitchStdev))°\n"
            out += "- meanAbsRoll: \(String(format: "%.2f", s.meanAbsRoll))° / peakAbsRoll: \(String(format: "%.2f", s.peakAbsRoll))° / rollStdev: \(String(format: "%.2f", s.rollStdev))°\n"
            out += "- oscillationScore: \(String(format: "%.2f", s.oscillationScore)) Hz (corrector delta zero-crossing rate)\n"
            out += "- correctorEffectivenessScore: \(String(format: "%.3f", s.correctorEffectivenessScore)) (-1 fall 가속 / 0 무관 / +1 회복)\n"
            out += "- 내장 권고: level \(s.intensityLevelUsed) → \(s.recommendedIntensityLevel), confidence \(String(format: "%.0f", s.confidence * 100))%\n"
            out += "- 권고 이유: \(s.recommendationReason)\n\n"

            // Phase 별 통계 (sample 배열에서 caller 가 계산).
            let phaseStats = sampleStatsBuilder(s.id)
            if !phaseStats.isEmpty {
                out += "**Phase 별 통계** (signed values):\n\n"
                out += "| phase | n | imuPitch μ±σ | imuRoll μ±σ | appliedDelta r_ank_pitch μ |\n"
                out += "|---|---|---|---|---|\n"
                for ps in phaseStats {
                    out += "| \(String(format: "%.2f", ps.phase)) | \(ps.count) | \(String(format: "%+.2f ± %.2f", ps.meanPitch, ps.stdPitch))° | \(String(format: "%+.2f ± %.2f", ps.meanRoll, ps.stdRoll))° | \(String(format: "%+.2f", ps.meanRAnklePitchDelta))° |\n"
                }
                out += "\n"
            }
        }
        return out
    }

    private static func userReportSection(_ report: String) -> String {
        var out = "## 사용자 자연어 보고\n\n"
        if report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "(사용자 보고 없음 — 데이터만으로 분석)\n"
        } else {
            out += "> \(report)\n"
        }
        return out
    }

    private static func analysisRequestSection() -> String {
        return #"""
        ## 분석 요청

        다음 4 항목에 대해 markdown 으로 답변하세요. 길지 않게 (700자 내). 데이터 인용 필수 (어느 세션 어느 metric).

        ### 1. 무엇이 잘못 됐나? (axis 별 진단)
        가장 의심되는 axis 1~3개 + 데이터 근거.

        ### 2. 왜 그런가? (root cause)
        Mac sparse 한계 / corrector 부호 / gain overshoot / phase mismatch / IMU 부호 등에서 가장 likely.

        ### 3. 어떻게 고칠 것인가? (axis 별 권고)
        - 즉시 변경 권고 (1~2개 axis): 어떤 값으로?
        - 보류 (검증 필요): 어떤 axis?
        - 안 변경: 어떤 axis (유지 이유)?

        ### 4. 다음 실험 1개 (가설 + 측정 방법)
        - 가설: ?
        - 변경: axis A → 값 X
        - 측정: 어떤 metric 으로 검증?
        - 예상 결과: ?
        """#
    }

    // MARK: - Helper struct

    /// Phase 별 통계 — caller (WalkLabSession) 가 sample 배열에서 계산.
    public struct PhaseStats: Equatable, Sendable {
        public let phase: Double          // 대표 phase (0.03/0.18/0.42/...)
        public let count: Int
        public let meanPitch: Double      // signed
        public let stdPitch: Double
        public let meanRoll: Double       // signed
        public let stdRoll: Double
        public let meanRAnklePitchDelta: Double  // signed, applied (또는 candidate)

        public init(phase: Double, count: Int,
                    meanPitch: Double, stdPitch: Double,
                    meanRoll: Double, stdRoll: Double,
                    meanRAnklePitchDelta: Double) {
            self.phase = phase
            self.count = count
            self.meanPitch = meanPitch
            self.stdPitch = stdPitch
            self.meanRoll = meanRoll
            self.stdRoll = stdRoll
            self.meanRAnklePitchDelta = meanRAnklePitchDelta
        }
    }

    /// Sample 배열에서 phase 별 통계 계산.
    /// phase 가 nil (legacy log) 인 sample 은 skip.
    public static func phaseStats(from samples: [WalkSessionSample]) -> [PhaseStats] {
        // 6 phase bucket (sparse keyframe 합성 phase): 0.03, 0.18, 0.42, 0.52, 0.68, 0.92.
        // bucket 폭 ±0.08.
        let centers: [Double] = [0.03, 0.18, 0.42, 0.52, 0.68, 0.92]
        let halfWidth: Double = 0.08
        return centers.compactMap { center in
            let bucket = samples.filter { s in
                guard let p = s.walkPhase01 else { return false }
                return abs(p - center) <= halfWidth
            }
            guard !bucket.isEmpty else { return nil }
            let n = bucket.count
            let pitches = bucket.map { $0.imuPitchDeg }
            let rolls = bucket.map { $0.imuRollDeg }
            let ankleDeltas = bucket.compactMap { s -> Double? in
                // applied 우선, 없으면 candidate, 없으면 correctorDeltas[4] (R anklePitch).
                if let a = s.appliedDeltas, a.count > 4 { return a[4] }
                if let c = s.candidateDeltas, c.count > 4 { return c[4] }
                if s.correctorDeltas.count > 4 { return s.correctorDeltas[4] }
                return nil
            }
            let mp = mean(pitches), mr = mean(rolls)
            return PhaseStats(
                phase: center,
                count: n,
                meanPitch: mp, stdPitch: std(pitches, mean: mp),
                meanRoll: mr, stdRoll: std(rolls, mean: mr),
                meanRAnklePitchDelta: ankleDeltas.isEmpty ? 0 : mean(ankleDeltas)
            )
        }
    }

    private static func mean(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        return a.reduce(0, +) / Double(a.count)
    }

    private static func std(_ a: [Double], mean m: Double) -> Double {
        guard a.count > 1 else { return 0 }
        let sumSq = a.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSq / Double(a.count)).squareRoot()
    }
}
