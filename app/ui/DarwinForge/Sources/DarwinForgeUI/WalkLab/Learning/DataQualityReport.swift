import Foundation

/// **v1.11.10 (2026-05-19)** — 보행 세션 데이터 품질 평가.
///
/// 진단 문서 (`docs/diagnosis/WALKLAB_CLAUDE_AGENT_ANALYSIS_REVIEW_2026-05-19.md`)
/// §HIGH 1 + Agent 2 실 데이터 검증 (~/Library/Application Support/DarwinForge/sessions/
/// 의 38 세션 실측) 기반.
///
/// **Claude critic 또는 auto-tuner 가 권고 전 통과해야 하는 gate**:
/// - verdict=fail → 분석 불가, 데이터 재수집 권고만
/// - verdict=weak → 보수적 분석 (confidence ≤ 0.5)
/// - verdict=pass → 정상 분석
///
/// **Threshold 근거 (Agent 2 실 데이터)**:
/// - duplicate ratio 진단 문서 30% 비현실적 (실측 median 55%) → ≤ 60% (실 robot 의
///   IMU 30Hz vs sample loop 16Hz down-sampling 부산물 흡수)
/// - stale ≥ 500ms 사실상 0 (실측 0%) → stale ≥ 250ms 사용 (median 0.4%)
/// - phase coverage 6/6 정상 → ≥ 4 require
/// - appliedDeltas zero=1.0 12 세션 중 절반 (corrector 비활성) → ≤ 30% (활성 보장)
public struct DataQualityReport: Codable, Equatable, Sendable {

    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case pass    // 모든 gate 통과 → 정상 분석
        case weak    // 1~2 metric marginal → 보수적 분석
        case fail    // critical gate fail → 데이터 재수집 권고
    }

    /// 종합 verdict.
    public let verdict: Verdict
    /// 인간 친화 fail/weak 사유 list.
    public let reasons: [String]

    // MARK: - 개별 metric (각각 ok flag + 실측값)

    public let durationSec: Double
    public let durationOK: Bool             // ≥ 5초 (Agent 2: 14 세션이 < 1초 abort)
    public let sampleCount: Int
    public let sampleCountOK: Bool          // ≥ 100 (확실한 분석 base)
    public let sampleRateHz: Double
    public let sampleRateOK: Bool           // ≥ 12Hz (목표 20Hz 의 60%, 실측 median 16Hz)
    public let staleSampleRatio: Double     // imuSampleAgeMs ≥ 250ms 비율
    public let staleRatioOK: Bool           // ≤ 0.05 (실측 median 0.004)
    public let duplicateImuRatio: Double    // imuSequence 연속 동일 비율
    public let duplicateOK: Bool            // ≤ 0.60 (실측 median 0.55)
    public let busWriteFailureDelta: Int
    public let busWriteOK: Bool             // = 0
    public let realRobotRatio: Double       // imuSource=real 비율
    public let realRobotOK: Bool            // sim/실 분석 모두 일관 (≥ 0.95 또는 = 0)
    public let phaseCoverageCount: Int      // unique covered phase bucket (6 phase 중)
    public let phaseCoverageOK: Bool        // ≥ 4
    public let appliedZeroRatio: Double     // appliedDeltas 가 모두 0 인 sample 비율
    public let appliedZeroOK: Bool          // ≤ 0.30 (corrector 활성 확인. observeOnly 면 별도)
    public let isObserveOnly: Bool          // appliedZero 해석용 context

    // MARK: - v1.11.25 (2026-05-21) audit log-A — v1.11.24 신규 필드 검증
    //
    // 종전 한계: requestedPreset / startBlockedReason / motorWriteStarted 가 jsonl 에 들어가지만
    // 어떤 analyzer 도 read 안 함 → 사실상 "dark data". 본 fix 가 fail rule 추가로 활용.

    /// header.startBlockedReason 이 nil 이 아니면 — preflight 진입 실패 흔적. 보행 데이터 분석 무의미.
    public let startBlockedReason: String?
    /// header.startBlockedReason 가 nil 이면 OK (preflight 통과).
    public let startBlockedOK: Bool
    /// header.motorWriteStarted (footer 가 immutable header 자리 점령 — 항상 nil. 실 footer 필요).
    /// 본 필드는 향후 logger 가 motorWriteStarted 를 header 에 write 하면 유효.
    public let motorWriteStarted: Bool?
    /// motorWriteStarted=true 또는 unknown(nil) 이면 OK. false 면 명시 fail.
    public let motorWriteStartedOK: Bool

    /// v1.11.25 audit-E — sim 데이터 명시. UI/Critic 가 sim 결과를 실 robot 권고로 misuse 차단.
    /// `header.isRealRobot=false` 이거나 realRobotRatio < 0.5 면 true (sim-only 결과).
    public let isSimulationOnly: Bool

    /// 통계 계산 → verdict 자동 산출.
    ///
    /// v1.11.25 audit-L: durationSec ≤ 0 edge case → empty(verdict=fail) 강제.
    /// 종전: 1 sample + duration=0 시 rate=Inf → JSONEncoder fail.
    /// v1.11.25 audit-K: V1 legacy session (walkingEngine 등 v2 핵심 필드 누락) →
    /// 자동 verdict=fail. critic V2 가 nil quality 에 fake pass 못 받게.
    public static func compute(
        samples: [WalkSessionSample],
        header: WalkSessionHeader,
        durationSec: Double
    ) -> DataQualityReport {
        let n = samples.count
        guard n > 0 else {
            return empty(durationSec: durationSec)
        }
        guard durationSec > 0 else {
            // audit-L: 1 sample + duration=0 → rate=Inf 차단.
            return empty(durationSec: 0)
        }
        // audit-K: V1 legacy 감지 — header AND sample 양쪽에서 v2 필드 모두 nil 일 때만 fail.
        // header 만 minimal (예: 테스트 fixture) 이지만 sample 에는 v2 필드 있으면 V1 아님.
        // 분석가가 V1 mixed batch 에 섞어 결론 오도하는 케이스만 차단.
        let v2HeaderMissing = (header.walkingEngine == nil && header.balanceAlgorithmMode == nil)
        let v2SampleMissing = samples.allSatisfy { $0.balanceAlgorithmMode == nil && $0.walkPhase01 == nil }
        if v2HeaderMissing && v2SampleMissing {
            return DataQualityReport(
                verdict: .fail,
                reasons: ["V1 legacy 세션 (header + sample 모두 v2 필드 부재) — V2 분석 incompatible"],
                durationSec: durationSec, durationOK: false,
                sampleCount: n, sampleCountOK: false,
                sampleRateHz: 0, sampleRateOK: false,
                staleSampleRatio: 0, staleRatioOK: true,
                duplicateImuRatio: 0, duplicateOK: true,
                busWriteFailureDelta: 0, busWriteOK: true,
                realRobotRatio: 0, realRobotOK: false,
                phaseCoverageCount: 0, phaseCoverageOK: false,
                appliedZeroRatio: 0, appliedZeroOK: true,
                isObserveOnly: false,
                startBlockedReason: nil, startBlockedOK: true,
                motorWriteStarted: nil, motorWriteStartedOK: true,
                isSimulationOnly: !header.isRealRobot
            )
        }

        // 1. duration / sample count / rate
        let durationOK = durationSec >= 5.0
        let sampleCountOK = n >= 100
        let rate = durationSec > 0 ? Double(n) / durationSec : 0
        let rateOK = rate >= 12.0

        // 2. stale ratio (imuSampleAgeMs ≥ 250ms)
        let staleSamples = samples.filter { ($0.imuSampleAgeMs ?? 0) >= 250 }.count
        let staleRatio = Double(staleSamples) / Double(n)
        let staleOK = staleRatio <= 0.05

        // 3. duplicate IMU sequence
        var dupCount = 0
        for i in 1..<samples.count {
            if let cur = samples[i].imuSequence, let prev = samples[i - 1].imuSequence,
               cur == prev {
                dupCount += 1
            }
        }
        let dupRatio = Double(dupCount) / Double(max(1, n - 1))
        let dupOK = dupRatio <= 0.60

        // 4. bus write failure delta (begin → end)
        let firstFail = samples.first?.busWriteFailureCount ?? 0
        let lastFail = samples.last?.busWriteFailureCount ?? 0
        let busDelta = max(0, lastFail - firstFail)
        let busOK = busDelta == 0

        // 5. realRobot ratio
        let realCount = samples.filter { $0.imuSource == "real" }.count
        let realRatio = Double(realCount) / Double(n)
        let realOK: Bool = {
            if header.isRealRobot { return realRatio >= 0.95 }
            return realRatio <= 0.05  // sim 분석이면 real 사용 X 일관
        }()

        // 6. phase coverage
        let phaseCenters: [Double] = [0.03, 0.18, 0.42, 0.52, 0.68, 0.92]
        let halfWidth: Double = 0.08
        let coveredPhases = phaseCenters.filter { center in
            samples.contains { s in
                guard let p = s.walkPhase01 else { return false }
                return abs(p - center) <= halfWidth
            }
        }.count
        let phaseOK = coveredPhases >= 4

        // 7. applied zero ratio
        let isObserveOnly: Bool = {
            if let mode = header.correctionApplyMode { return mode == "observeOnly" }
            return false
        }()
        let appliedZero = samples.filter { s in
            guard let a = s.appliedDeltas else { return true }   // nil = legacy = 0 취급
            return a.allSatisfy { abs($0) < 1e-6 }
        }.count
        let appliedZeroRatio = Double(appliedZero) / Double(n)
        // observeOnly 면 appliedZero=1.0 정상.
        let appliedZeroOK = isObserveOnly ? true : appliedZeroRatio <= 0.30

        // Verdict 결정.
        var reasons: [String] = []
        var failCount = 0
        var weakCount = 0
        func tally(_ ok: Bool, fail: Bool, reason: String) {
            if !ok {
                if fail { failCount += 1 } else { weakCount += 1 }
                reasons.append(reason)
            }
        }
        tally(durationOK,    fail: durationSec < 1.0,   reason: "duration \(String(format: "%.1f", durationSec))s < 5s (Agent 2: 1초 미만 abort)")
        tally(sampleCountOK, fail: n < 30,              reason: "sampleCount \(n) < 100")
        tally(rateOK,        fail: rate < 8,            reason: "sampleRate \(String(format: "%.1f", rate))Hz < 12Hz")
        tally(staleOK,       fail: staleRatio > 0.20,   reason: "staleRatio \(String(format: "%.2f", staleRatio)) > 0.05")
        tally(dupOK,         fail: dupRatio > 0.75,     reason: "duplicateRatio \(String(format: "%.2f", dupRatio)) > 0.60")
        tally(busOK,         fail: busDelta > 5,        reason: "busWriteFailureDelta \(busDelta) > 0")
        tally(realOK,        fail: false,               reason: "realRobotRatio \(String(format: "%.2f", realRatio)) inconsistent with header.isRealRobot=\(header.isRealRobot)")
        tally(phaseOK,       fail: coveredPhases < 3,   reason: "phaseCoverage \(coveredPhases)/6 < 4")
        tally(appliedZeroOK, fail: appliedZeroRatio > 0.80 && !isObserveOnly, reason: "appliedZeroRatio \(String(format: "%.2f", appliedZeroRatio)) > 0.30 (corrector 비활성)")

        // v1.11.25 audit log-A — v1.11.24 신규 필드 검증.
        let startBlockedReason = header.startBlockedReason
        let startBlockedOK = (startBlockedReason == nil)
        let motorWriteStarted = header.motorWriteStarted
        // false 가 명시되면 fail. nil 또는 true 면 OK (구버전 jsonl 호환).
        let motorWriteStartedOK = motorWriteStarted != false
        tally(startBlockedOK, fail: true, reason: "preflight 차단됨: \(startBlockedReason ?? "unknown") (audit P0-1)")
        tally(motorWriteStartedOK, fail: true, reason: "motor write 시작 안 됨 (audit P1-2): preflight 통과했지만 motor 송출 0회 → bus race / disconnect 의심")

        let verdict: Verdict = {
            if failCount > 0 { return .fail }
            if weakCount > 0 { return .weak }
            return .pass
        }()

        return DataQualityReport(
            verdict: verdict, reasons: reasons,
            durationSec: durationSec, durationOK: durationOK,
            sampleCount: n, sampleCountOK: sampleCountOK,
            sampleRateHz: rate, sampleRateOK: rateOK,
            staleSampleRatio: staleRatio, staleRatioOK: staleOK,
            duplicateImuRatio: dupRatio, duplicateOK: dupOK,
            busWriteFailureDelta: busDelta, busWriteOK: busOK,
            realRobotRatio: realRatio, realRobotOK: realOK,
            phaseCoverageCount: coveredPhases, phaseCoverageOK: phaseOK,
            appliedZeroRatio: appliedZeroRatio, appliedZeroOK: appliedZeroOK,
            isObserveOnly: isObserveOnly,
            // v1.11.25 audit log-A
            startBlockedReason: startBlockedReason,
            startBlockedOK: startBlockedOK,
            motorWriteStarted: motorWriteStarted,
            motorWriteStartedOK: motorWriteStartedOK,
            // v1.11.25 audit-E
            isSimulationOnly: !header.isRealRobot || realRatio < 0.5
        )
    }

    /// 빈 sample → 즉시 fail.
    public static func empty(durationSec: Double) -> DataQualityReport {
        return DataQualityReport(
            verdict: .fail,
            reasons: ["샘플 없음 — 분석 불가"],
            durationSec: durationSec, durationOK: false,
            sampleCount: 0, sampleCountOK: false,
            sampleRateHz: 0, sampleRateOK: false,
            staleSampleRatio: 0, staleRatioOK: true,
            duplicateImuRatio: 0, duplicateOK: true,
            busWriteFailureDelta: 0, busWriteOK: true,
            realRobotRatio: 0, realRobotOK: false,
            phaseCoverageCount: 0, phaseCoverageOK: false,
            appliedZeroRatio: 0, appliedZeroOK: true,
            isObserveOnly: false,
            startBlockedReason: nil, startBlockedOK: true,
            motorWriteStarted: nil, motorWriteStartedOK: true,
            isSimulationOnly: false
        )
    }
}

/// **v1.11.10 (2026-05-19)** — Sagittal plane (앞기울/뒤기울) 분석 metric.
///
/// 진단 문서 §HIGH 2: 기존 analyzer 가 roll + R hipRoll 중심. 사용자 문제는
/// "앞으로 잘 못 나아감", "앞으로 넘어짐" — pitch / hipPitch / knee / anklePitch /
/// stride / period 중심. signed pitch 보존 (방향 정보).
public struct SagittalMetric: Codable, Equatable, Sendable {
    public let meanSignedPitch: Double    // signed — 앞기울(real robot) = 음수
    public let pitchDriftPerSec: Double   // linear trend slope (°/s)
    public let pitchRecoveryCount: Int    // |pitch|>10° → |pitch|<5° 복귀 횟수

    public static func compute(samples: [WalkSessionSample], durationSec: Double) -> SagittalMetric {
        guard !samples.isEmpty else {
            return SagittalMetric(meanSignedPitch: 0, pitchDriftPerSec: 0, pitchRecoveryCount: 0)
        }
        let pitches = samples.map { $0.imuPitchDeg }
        let meanSigned = pitches.reduce(0, +) / Double(pitches.count)
        // Linear regression slope: drift over time.
        let n = Double(pitches.count)
        let xs = (0..<pitches.count).map { Double($0) * (durationSec / n) }
        let xMean = xs.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<pitches.count {
            let dx = xs[i] - xMean
            num += dx * (pitches[i] - meanSigned)
            den += dx * dx
        }
        let drift = den > 1e-9 ? (num / den) : 0
        // Recovery count: |pitch|>10° 진입 → |pitch|<5° 복귀 trans count.
        var count = 0
        var inHighTilt = false
        for p in pitches {
            if !inHighTilt && abs(p) > 10 { inHighTilt = true }
            else if inHighTilt && abs(p) < 5 { count += 1; inHighTilt = false }
        }
        return SagittalMetric(meanSignedPitch: meanSigned, pitchDriftPerSec: drift, pitchRecoveryCount: count)
    }
}

/// **v1.11.10 (2026-05-19)** — Candidate vs applied delta 분리 통계.
///
/// 진단 문서 §HIGH 3: observeOnly 에서 appliedDeltas 가 [0,...] 이지만 candidateDeltas
/// 는 의미 있는 값. 현재 phaseStats 가 한 필드만 출력 → 두 값 차이 가려짐.
public struct CandidateAppliedSplit: Codable, Equatable, Sendable {
    public let meanCandidateRAnklePitch: Double
    public let meanAppliedRAnklePitch: Double
    public let meanCandidateLAnklePitch: Double
    public let meanAppliedLAnklePitch: Double

    public static func compute(samples: [WalkSessionSample]) -> CandidateAppliedSplit {
        let cands = samples.compactMap { s -> (Double, Double)? in
            guard let c = s.candidateDeltas, c.count >= 8 else { return nil }
            return (c[4], c[5])  // rAnklePitch, lAnklePitch
        }
        let apps = samples.compactMap { s -> (Double, Double)? in
            guard let a = s.appliedDeltas, a.count >= 8 else { return nil }
            return (a[4], a[5])
        }
        let cR = cands.map(\.0)
        let cL = cands.map(\.1)
        let aR = apps.map(\.0)
        let aL = apps.map(\.1)
        return CandidateAppliedSplit(
            meanCandidateRAnklePitch: cR.isEmpty ? 0 : cR.reduce(0, +) / Double(cR.count),
            meanAppliedRAnklePitch:   aR.isEmpty ? 0 : aR.reduce(0, +) / Double(aR.count),
            meanCandidateLAnklePitch: cL.isEmpty ? 0 : cL.reduce(0, +) / Double(cL.count),
            meanAppliedLAnklePitch:   aL.isEmpty ? 0 : aL.reduce(0, +) / Double(aL.count)
        )
    }
}
