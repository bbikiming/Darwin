import SwiftUI

/// **V280-C (2026-05-24)**: WalkDataView 분리 — ExperimentApproval / Claude
/// data loading helper extension.
///
/// 종전 WalkDataView.swift line 117-304 (188 LOC) 를 별도 file 로 이동:
/// - `loadHeaders` / `loadHeader` — jsonl header 디스크 load
/// - `phaseStatsForSession` — V2 phase 통계
/// - `phaseStatsClassic` — V1 phase 통계 (static)
/// - `buildProposedConfig` — NextExperiment → BalanceExperimentConfig + Deltas
/// - `applyExperimentApproval` — 사용자 승인 후 ExperimentLoop start + 실 변경
///
/// WalkDataView 본체는 800 LOC 한계 준수 + segmented control + body view 에 집중.
/// Logic 보존 — 모든 함수 signature / behavior 동일.
extension WalkDataView {

    /// 모든 세션의 jsonl 에서 header load.
    func loadHeaders() -> [String: WalkSessionHeader] {
        var map: [String: WalkSessionHeader] = [:]
        guard let dir = WalkSessionStore.sessionsDir else { return map }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return map
        }
        let decoder = JSONDecoder()
        for url in files where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url),
                  let firstLine = data.split(separator: 0x0a).first,
                  let header = try? decoder.decode(WalkSessionHeader.self, from: Data(firstLine))
            else { continue }
            map[header.sessionId] = header
        }
        return map
    }

    func phaseStatsForSession(_ sessionId: String) -> [WalkSessionClaudePromptV2.PhaseStatsV2] {
        guard let dir = WalkSessionStore.sessionsDir else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let match = files.first { $0.lastPathComponent.contains(sessionId) && $0.pathExtension == "jsonl" }
        guard let url = match, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var samples: [WalkSessionSample] = []
        for line in data.split(separator: 0x0a).dropFirst() {
            // v1.11.24 audit iter4 critic — footer 줄 은 sample 아니므로 skip.
            if line.contains("\"type\":\"footer\"".utf8) { continue }
            if let s = try? decoder.decode(WalkSessionSample.self, from: Data(line)) {
                samples.append(s)
            }
        }
        return WalkSessionClaudePromptV2.phaseStatsV2(from: samples)
    }

    /// V280-C: invokeClaudeAnalysis 의 inline builder 를 static helper 로 추출.
    static func phaseStatsClassic(forSessionId sessionId: String) -> [WalkSessionClaudePrompt.PhaseStats] {
        guard let dir = WalkSessionStore.sessionsDir else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let match = files.first { $0.lastPathComponent.contains(sessionId) && $0.pathExtension == "jsonl" }
        guard let url = match, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var samples: [WalkSessionSample] = []
        for line in data.split(separator: 0x0a).dropFirst() {
            if let s = try? decoder.decode(WalkSessionSample.self, from: Data(line)) {
                samples.append(s)
            }
        }
        return WalkSessionClaudePrompt.phaseStats(from: samples)
    }

    /// 한 sessionId 의 jsonl 첫 줄 (header) load.
    func loadHeader(forSessionId id: String) -> WalkSessionHeader? {
        guard let dir = WalkSessionStore.sessionsDir else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let match = files.first { $0.lastPathComponent.contains(id) && $0.pathExtension == "jsonl" }
        guard let url = match, let data = try? Data(contentsOf: url),
              let firstLine = data.split(separator: 0x0a).first
        else { return nil }
        return try? JSONDecoder().decode(WalkSessionHeader.self, from: Data(firstLine))
    }

    /// **v1.11.14 (2026-05-19) — fix 진단 문서 #2**: 현재 WalkLab config 기준 + 한 axis 만 override.
    /// `currentConfig` 는 RootView/WalkLabView 가 전달. baseline session 의 Header V2
    /// 도 우선 사용 (있으면 더 정확). nil 이면 default — backward compat.
    /// **v1.11.14.1**: tuning slider (stride/side/turn/period/footHeight/balanceGain) +
    /// customGain* 4종 도 ExperimentDeltas 로 반환.
    func buildProposedConfig(from exp: NextExperiment,
                             currentConfig: BalanceExperimentConfig?,
                             currentHipPitchOffsetTrimDeg: Double = 13.0,
                             baselineHeader: WalkSessionHeader? = nil)
        -> (config: BalanceExperimentConfig, deltas: WalkLabSession.ExperimentDeltas) {
        var algorithm: BalanceAlgorithmMode = currentConfig?.algorithmMode ?? .robotisPControl
        var sign: BalanceSignConvention = currentConfig?.signConvention ?? .robotisWalkingCpp
        var gain: BalanceGainProfile = currentConfig?.gainProfile ?? .robotisOriginal
        var apply: Bool = currentConfig?.applyToRobot ?? true
        var pitchInput: BalancePitchInputConvention = currentConfig?.pitchInputConvention ?? .imuRaw
        if let h = baselineHeader {
            if let v = h.balanceAlgorithmMode.flatMap(BalanceAlgorithmMode.init) { algorithm = v }
            if let v = h.balanceSignConvention.flatMap(BalanceSignConvention.init) { sign = v }
            if let v = h.balanceGainProfile.flatMap(BalanceGainProfile.init) { gain = v }
            if let v = h.pitchInputConvention.flatMap(BalancePitchInputConvention.init) { pitchInput = v }
        }
        _ = currentHipPitchOffsetTrimDeg  // baseline header 우선이지만 logging 용 reserved.
        _ = baselineHeader?.hipPitchOffsetTrimDegAtStart  // header 의 baseline trim 도 검사 reserved.
        var deltas = WalkLabSession.ExperimentDeltas()

        // 한 axis 만 override.
        switch exp.axis {
        case .algorithmMode:
            if let v = BalanceAlgorithmMode(rawValue: exp.to) { algorithm = v }
        case .signConvention:
            if let v = BalanceSignConvention(rawValue: exp.to) { sign = v }
        case .gainProfile:
            if let v = BalanceGainProfile(rawValue: exp.to) { gain = v }
        case .pitchInputConvention:
            if let v = BalancePitchInputConvention(rawValue: exp.to) { pitchInput = v }
        case .applyToRobot:
            apply = (exp.to.lowercased() == "true")
        case .hipPitchOffsetTrimDeg:
            if let d = Double(exp.to) { deltas.hipPitchOffsetTrimDeg = d }
        // **v1.11.14.5 — 사용자 평가 HIGH 2 fix**: walkingEngine + enableBalanceCorrection.
        case .walkingEngine:
            if let v = WalkingEngine(rawValue: exp.to) { deltas.walkingEngine = v }
        case .enableBalanceCorrection:
            deltas.enableBalanceCorrection = (exp.to.lowercased() == "true")
        // v1.11.14.1: tuning slider 6종 + customGain 4종 적용.
        case .strideMm:
            if let d = Double(exp.to) { deltas.strideMm = d }
        case .sideMm:
            if let d = Double(exp.to) { deltas.sideMm = d }
        case .turnDeg:
            if let d = Double(exp.to) { deltas.turnDeg = d }
        case .periodMs:
            if let d = Double(exp.to) { deltas.customPeriodMs = d }
        case .footHeightMm:
            if let d = Double(exp.to) { deltas.footHeightMm = d }
        case .balanceGain:
            if let d = Double(exp.to) { deltas.balanceGain = d }
        case .customGainHipRoll:
            if let d = Double(exp.to) { deltas.customHipRollGain = d }
        case .customGainKnee:
            if let d = Double(exp.to) { deltas.customKneeGain = d }
        case .customGainAnklePitch:
            if let d = Double(exp.to) { deltas.customAnklePitchGain = d }
        case .customGainAnkleRoll:
            if let d = Double(exp.to) { deltas.customAnkleRollGain = d }
        // **데이터 기반 자동 튜닝 (2026-05-30)**: 균형 안정성 파라미터 (승인 게이트 경유).
        case .baselineTauSec:
            if let d = Double(exp.to) { deltas.baselineTauSec = d }
        case .derivativeTimeSec:
            if let d = Double(exp.to) { deltas.derivativeTimeSec = d }
        // **v1.11.14.6 — exhaustive switch**: ResponseAxis 신규 추가 시 silent skip 차단.
        case .none, .unknown:
            break
        }
        let config = BalanceExperimentConfig(
            algorithmMode: algorithm, signConvention: sign,
            gainProfile: gain, applyToRobot: apply,
            pitchInputConvention: pitchInput
        )
        return (config, deltas)
    }

    /// **v1.11.14**: 사용자 명시 승인 후 ExperimentLoop start + WalkLabSession 실 변경.
    /// 진단 문서 #1 fix — 승인 시 실제 config 변경.
    @MainActor
    func applyExperimentApproval(response: ClaudeCriticResponse,
                                 experiment: NextExperiment,
                                 currentConfig: BalanceExperimentConfig?,
                                 currentTrim: Double,
                                 session: WalkLabSession?) async {
        let baselineId = selectedId ?? (summaries.first?.id ?? "unknown")
        let baseHeader = loadHeader(forSessionId: baselineId)
        let (proposedConfig, deltas) = buildProposedConfig(
            from: experiment,
            currentConfig: currentConfig,
            currentHipPitchOffsetTrimDeg: currentTrim,
            baselineHeader: baseHeader
        )
        // v1.11.14 진단 문서 #5 fix — 현재 config 기준 forbidden 조합 검증.
        let validation = response.validate(currentConfig: currentConfig ?? proposedConfig,
                                           currentTrim: currentTrim)
        if !validation.passed {
            experimentLoop.setLastError("승인 검증 실패: \(validation.issues.joined(separator: " | "))")
            showApprovalSheet = false
            return
        }
        let started = await experimentLoop.startExperiment(
            from: response,
            baselineSessionId: baselineId,
            proposedConfig: proposedConfig
        )
        if started, let session = session, let current = experimentLoop.current {
            // 실 WalkLabSession 에 한 axis 변경 적용 (사용자 명시 승인 + safety gate 통과 후).
            let result = session.applyExperimentChange(
                experimentId: current.id,
                baselineSessionId: baselineId,
                proposedConfig: proposedConfig,
                deltas: deltas
            )
            switch result {
            case .applied: break  // WalkLab 의 lastRobotEvent 가 사용자에게 표시.
            case .failed(let reason):
                // **v1.11.14.4 — cold 3차 CRIT 2 fix**: silent 차단 — safetyVerdict 강등 등 알림.
                experimentLoop.setLastError("실험 적용 실패: \(reason)")
                await experimentLoop.cancel()
            }
        }
        showApprovalSheet = false
    }
}
