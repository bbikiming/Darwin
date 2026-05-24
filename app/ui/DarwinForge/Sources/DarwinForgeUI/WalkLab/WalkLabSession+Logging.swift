import Foundation
import ForgeCore

/// **v1.22.5 (2026-05-22) — 사이클 94: god object Phase 6 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` 의 logging / analyzer / auto-loop pipeline 코드 (~395 line) 를
/// 본 extension 으로 이동. architect plan 의 마지막 큰 분할 — 본체에서 logging 관심사를
/// 완전히 분리.
///
/// # 비유
///
/// 도서관의 "기록 보관실" 을 별관으로 이전. 본관 (WalkLabSession) 은 책 (sample) 만
/// 발급하고, 보관실 (Logging extension) 이 색인 (analyzer) / 보존 (writeSummary) / 폐기
/// (cleanupOldSessions) / 검색 (loadSummaryFromDisk) 까지 전담. 책장 (sessionLogger /
/// sessionStartedAt / sparse trackers) 만 본관 잔존 — Swift extension 제약.
///
/// # 분할 정책
///
/// - **stored property 본체 잔존** (Swift 제약): `sessionLogger`, `sessionStartedAt`,
///   `lastLoggedTelemetryAt`, `lastLoggedImuSequence`, `lastLoggedJointFailures`,
///   `lastImuSampleAt` (computed).
/// - **method 이동**: `appendSessionSampleIfLogging`, `finalizeSessionLog`,
///   `triggerAutoLoopIfActive`, `loadSummaryFromDisk`, `extractSessionIdFromSummary`,
///   `loadAllExperimentSummaries`, `readFirstLine`.
/// - 본 cycle 에서 stored property 다수 `private` → `internal` 격상 — extension 에서
///   read/write 필요.
///
/// # 격상 list (cycle 94)
///
/// - `sessionStartedAt`: private → internal (read+write — append/finalize)
/// - `lastLoggedTelemetryAt`: private → internal (read+write — sparse cadence)
/// - `lastLoggedImuSequence`: private → internal (read+write — sparse cadence)
/// - `lastLoggedJointFailures`: private → internal (read+write — sparse cadence)
/// - `lastImuSampleAt`: private → internal (read — sample age 계산)
///
/// # 본체 잔존 (Swift extension 제약)
///
/// stored property 는 Swift 의 본질적 제약으로 extension 으로 이동 불가. struct/class
/// body 내부에만 선언 가능. 본 cycle 은 method 이동 + access 격상으로 logging concern 을
/// 본체에서 시각적으로 완전히 분리.
///
/// # 호출 site 무변경
///
/// - `tick()` → `appendSessionSampleIfLogging()` : 본체 method 호출 — extension 으로
///   resolve 됨 (Swift type method lookup).
/// - `stop()` → `finalizeSessionLog()` : 동일.
/// - 외부 (tests) → `WalkLabSession.loadSummaryFromDisk` etc : static call site 무변경.
@MainActor
extension WalkLabSession {

    // MARK: - Session sample append (per-tick)

    /// 보행 중 매 tick 호출 — sample 한 줄 logger 에 append.
    /// **v1.11 (2026-05-17 handoff §4 wiring + Codex 2026-05-18 HIGH-1 fix)**:
    /// candidate = ramp 적용 **전** raw corrector 결과 (`lastRawCandidate`),
    /// applied = pose 에 실제 들어간 값 (lastCorrectionApplied 면 `lastCorrections`, 아니면 0).
    /// 정확한 분리로 quality analyzer 가 "corrector 자체" vs "corrector+ramp" 효과 구분 가능.
    func appendSessionSampleIfLogging() {
        guard let logger = sessionLogger, let started = sessionStartedAt else { return }
        let elapsedMs = Date().timeIntervalSince(started) * 1000.0
        // candidate = corrector.corrections() 결과 (ramp 적용 전, raw).
        // observeOnly / applyToRobot=false 라도 채워짐.
        let candidate: [Double] = [
            lastRawCandidate?.rHipRoll    ?? 0,
            lastRawCandidate?.lHipRoll    ?? 0,
            lastRawCandidate?.rKnee       ?? 0,
            lastRawCandidate?.lKnee       ?? 0,
            lastRawCandidate?.rAnklePitch ?? 0,
            lastRawCandidate?.lAnklePitch ?? 0,
            lastRawCandidate?.rAnkleRoll  ?? 0,
            lastRawCandidate?.lAnkleRoll  ?? 0,
        ]
        // applied = pose 에 실제 들어간 값. observeOnly / applyToRobot=false → 0.
        // ramp 적용된 lastCorrections 가 실제로 pose 에 들어간 값과 동일.
        let appliedFromRamped: [Double] = [
            lastCorrections?.rHipRoll    ?? 0,
            lastCorrections?.lHipRoll    ?? 0,
            lastCorrections?.rKnee       ?? 0,
            lastCorrections?.lKnee       ?? 0,
            lastCorrections?.rAnklePitch ?? 0,
            lastCorrections?.lAnklePitch ?? 0,
            lastCorrections?.rAnkleRoll  ?? 0,
            lastCorrections?.lAnkleRoll  ?? 0,
        ]
        let applied: [Double] = lastCorrectionApplied ? appliedFromRamped : Array(repeating: 0, count: 8)
        // legacy `correctorDeltas` 는 applied 와 동일 (backward compat).
        let battery: Double? = (store?.lastTelemetry?.board?.voltageVolts)
        let motorTemp: Double? = (store?.lastTelemetry?.avgTemperature)
        // v1.11 logging fields
        let cfg = balanceExperimentConfig
        let imuAgeMs: Double? = lastImuSampleAt.map {
            Date().timeIntervalSince($0) * 1000.0
        }
        let expectedPitch: Double? = lastHybridResult.map { _ -> Double in
            // Hybrid 가 사용한 sway 모델 — periodMs/elapsedMs 로 재계산.
            guard let p = lastWalkPeriodMs, let e = lastWalkCycleElapsedMs, p > 0 else { return 0 }
            let phase = (2 * .pi) * e / p
            return balanceCorrector.sagittalSwayAmpDeg * sin(phase)
        }
        let expectedRoll: Double? = lastHybridResult.map { _ -> Double in
            guard let p = lastWalkPeriodMs, let e = lastWalkCycleElapsedMs, p > 0 else { return 0 }
            let phase = (2 * .pi) * e / p
            return balanceCorrector.lateralSwayAmpDeg * sin(phase)
        }
        let emaPitch: Double? = lastHybridResult != nil ? hybridBalanceState.pitchEma : nil
        let emaRoll:  Double? = lastHybridResult != nil ? hybridBalanceState.rollEma  : nil
        let effPitchErr: Double? = lastHybridResult?.effectivePitchErr
        let effRollErr:  Double? = lastHybridResult?.effectiveRollErr
        // §4 walkPhase01 — 0..1 정규화 위상. Hybrid path 에서 채운 lastWalkCycleElapsedMs 사용.
        let phase01: Double? = {
            guard let p = lastWalkPeriodMs, let e = lastWalkCycleElapsedMs, p > 0 else { return nil }
            return max(0, min(1, e / p))
        }()
        // §4 IMU sequence + bus failure counters — ConnectionStore 노출.
        let imuSeq: UInt32? = store?.imuSequenceCount
        let busWFail: Int? = store?.busWriteFailureCount
        let busRFail: Int? = store?.busReadFailureCount

        // v1.11.25 audit robot-A/B/C/E/F — 실 로봇 측 데이터를 sparse-cadence 로 dump.
        // ConnectionStore 가 메모리에 보유하고 있지만 disk 휘발이던 데이터 (per-joint state /
        // IMU raw 6축 / per-joint failure counter / RTT / board button) 를 sample 에 포함.

        // (1) per-joint state — telemetry tick 새 도착 시에만 (≈5Hz USB / 2Hz network).
        // 같은 telemetry 면 nil 로 두어 size 절약.
        var jointStatesSnapshot: [String: JointStateSnapshot]? = nil
        if let tel = store?.lastTelemetry, tel.timestamp != lastLoggedTelemetryAt {
            var dict: [String: JointStateSnapshot] = [:]
            for (jid, js) in tel.joints {
                dict[jid.name] = JointStateSnapshot(
                    g: js.goalPosition, a: js.presentPosition, sp: js.presentSpeed,
                    l: js.presentLoad, t: js.presentTemperature, v: js.presentVoltageRaw,
                    te: js.torqueEnabled
                )
            }
            if !dict.isEmpty {
                jointStatesSnapshot = dict
                lastLoggedTelemetryAt = tel.timestamp
            }
        }

        // (2) IMU raw 6축 — 새 IMU read (imuSequence 증가) 시에만. 같은 sequence 면 nil.
        var rawGX: Double? = nil
        var rawGY: Double? = nil
        var rawGZ: Double? = nil
        var rawAX: Double? = nil
        var rawAY: Double? = nil
        var rawAZ: Double? = nil
        if let raw = store?.lastImuRaw,
           let seq = store?.imuSequenceCount,
           seq != lastLoggedImuSequence {
            rawGX = raw.gyroXDps; rawGY = raw.gyroYDps; rawGZ = raw.gyroZDps
            rawAX = raw.accelXG; rawAY = raw.accelYG; rawAZ = raw.accelZG
            lastLoggedImuSequence = seq
        }

        // (3) per-joint failure delta — 변화한 joint 만 sparse.
        var failuresDelta: [String: Int]? = nil
        if let store = self.store {
            var dict: [String: Int] = [:]
            for (jid, count) in store.jointConsecutiveFailures {
                let prev = lastLoggedJointFailures[jid] ?? 0
                if count != prev {
                    dict[jid.name] = count
                    lastLoggedJointFailures[jid] = count
                }
            }
            if !dict.isEmpty { failuresDelta = dict }
        }

        // (4) board RTT + button state — 매 tick 채움 (값이 같으면 reader 가 dedup).
        let rttMs: Double? = store?.lastRoundTripMs
        let btn: UInt8? = store?.lastTelemetry?.board?.button

        // (5) FSR (foot pressure) — board cadence (1Hz). 같은 read 면 매 tick 같은 값 dedup.
        let fsrL: FsrSampleSnapshot? = store?.lastFsrLeft.map { r in
            FsrSampleSnapshot(fl: r.cellFrontLeft, fr: r.cellFrontRight,
                              rr: r.cellRearRight, rl: r.cellRearLeft,
                              x: r.centerX, y: r.centerY)
        }
        let fsrR: FsrSampleSnapshot? = store?.lastFsrRight.map { r in
            FsrSampleSnapshot(fl: r.cellFrontLeft, fr: r.cellFrontRight,
                              rr: r.cellRearRight, rl: r.cellRearLeft,
                              x: r.centerX, y: r.centerY)
        }

        // v1.11.24 audit P1-1 — logger sample.preset 은 activeRobotPreset 우선.
        // current 는 사용자 선택일 뿐 — 보행 중 다른 preset 클릭 시 sample 이 섞이는 버그
        // (audit §2: "slowWalk 세션 안에 normalWalk/fastWalk sample 섞임") 차단.
        let loggedPresetRaw = (activeRobotPreset ?? current).rawValue
        let sample = WalkSessionSample(
            t: elapsedMs,
            preset: loggedPresetRaw,
            intensityLevel: correctorIntensityLevel,
            imuRollDeg: imuRollDeg,
            imuPitchDeg: imuPitchDeg,
            correctorRollErrDeg: correctorFilteredRoll,
            correctorPitchErrDeg: correctorFilteredPitch,
            balanceState: String(describing: balanceState),
            correctorDeltas: applied,   // backward compat — applied (legacy correctorDeltas)
            imuSource: String(describing: imuSource),
            batteryVolts: battery,
            motorAvgTemp: motorTemp,
            balanceAlgorithmMode: cfg.algorithmMode.rawValue,
            balanceSignConvention: cfg.signConvention.rawValue,
            balanceGainProfile: cfg.gainProfile.rawValue,
            correctionAppliedToRobot: lastCorrectionApplied,
            walkCycleElapsedMs: lastWalkCycleElapsedMs,
            walkPeriodMs: lastWalkPeriodMs,
            imuSampleAgeMs: imuAgeMs,
            expectedPitchDeg: expectedPitch,
            emaPitchDeg: emaPitch,
            effectivePitchErrDeg: effPitchErr,
            // §4 wiring (2026-05-17 handoff)
            walkPhase01: phase01,
            candidateDeltas: candidate,
            appliedDeltas: applied,
            imuSequence: imuSeq,
            busWriteFailureCount: busWFail,
            busReadFailureCount: busRFail,
            effectiveRollErrDeg: effRollErr,
            expectedRollDeg: expectedRoll,
            emaRollDeg: emaRoll,
            // v1.11.25 audit robot-A/B/C/E/F — 실 로봇 측 sparse dump.
            jointStates: jointStatesSnapshot,
            rawGyroXDps: rawGX,
            rawGyroYDps: rawGY,
            rawGyroZDps: rawGZ,
            rawAccelXG: rawAX,
            rawAccelYG: rawAY,
            rawAccelZG: rawAZ,
            jointFailuresDelta: failuresDelta,
            busRttMs: rttMs,
            boardButton: btn,
            // v1.11.25 audit P0 robot-D — FSR sparse dump.
            fsrLeft: fsrL,
            fsrRight: fsrR,
            // v1.11.25 audit P1 log-H — fall predictor 시계열.
            fallScore: fallPrediction.score,
            fallRecommendEmergency: fallPrediction.recommendEmergency
        )
        logger.append(sample)
    }

    // MARK: - Session finalize (cycle end)

    /// 보행 cycle 종료 시 호출 — logger close + analyzer 실행 + autoTuner.record.
    /// stop / cancelWalkCycle / runContinuousWalk Task 종료 시 모두 호출.
    /// **v1.11 (Codex 3rd review fix)**: cycleStartedAt 은 logger 존재 여부와 무관하게
    /// 항상 cleanup. 종전엔 logger=nil 일 때 early return 으로 cycleStartedAt 안 nil
    /// 처리됨 → 다음 walk start 시 이전 cycle 잔존 phase 사용 위험.
    public func finalizeSessionLog() {
        // 항상 cleanup (logging OFF / logger throw 케이스 cover).
        defer {
            cycleStartedAt = nil
        }
        guard let logger = sessionLogger, let started = sessionStartedAt else { return }
        let duration = Date().timeIntervalSince(started)
        let summary = WalkSessionAnalyzer.analyze(
            logger.samples,
            preset: logger.header.preset,
            startTime: started,
            durationSec: duration,
            intensityLevelUsed: correctorIntensityLevel,
            header: logger.header   // v1.11.10: V2 metric (quality + sagittal + candidateApplied)
        )
        try? logger.writeSummary(summary)
        // v1.11.24 audit iter2-H + iter3-F — footer 로 motor write 진단 export.
        // iter3-F: emergencyStop > lastCycleResult.reason > stop flag 순으로 정확도 우선.
        let endReason: String = {
            if emergencyStopActive { return "emergencyStop" }
            if let reason = lastCycleResult?.reason {
                switch reason {
                case .completedMaxDuration: return "presetMaxDuration"
                case .userCancelled:        return "userStop"
                case .lowerBodyWriteFailure: return "lowerBodyWriteFailure"
                case .bulkWriteFailure:     return "bulkWriteFailure"
                case .busDisconnected:      return "busDisconnected"
                }
            }
            if !isRobotWalking && !onboardWalkingActive { return "userStop" }
            return "cycleEnded"
        }()
        logger.close(
            motorWriteStarted: motorWriteStarted,
            motorWriteStepCount: motorWriteStepCount,
            onboardAckStatus: onboardAckStatus,
            endReason: endReason
        )
        // **사이클 V281-3 (Wave 4.1.4)**: 5줄 cleanup → recorder helper 한 줄.
        // logger nil 화 + sessionStartedAt nil 화 + sparse trackers reset 묶음.
        // cycleStartedAt 은 위 defer 에서 별도 처리 (logger 존재 여부 무관 — v1.11 Codex 3rd review fix).
        recorder.clearSessionState()
        // v1.11.25 audit log-Q — retention 항상 호출 (autoTuner 우회 path).
        // 종전: cleanupOldSessions 는 autoTuner.record 안에 cleanupEvery 카운트 기반만
        //       호출 → autoTuner 비활성/우회 시 cleanup 영원히 미실행. 본 호출이 모든
        //       session 종료 path 에서 보장.
        WalkSessionStore.cleanupOldSessions()
        autoTuner.record(summary, currentLevel: correctorIntensityLevel)
        lastRobotEvent = "📊 session 분석 완료 — \(summary.recommendationReason)"

        // **v1.11.14 (2026-05-19)** — 활성 실험이 있으면 자동 폐루프.
        // **v1.11.14.4 cold 3차 MED 6**: orchestration 을 testable async helper 로 추출.
        // 종전엔 Task closure 내부에 inlined — test 에서 trigger 불가.
        triggerAutoLoopIfActive(summaryId: summary.id)
    }

    // MARK: - Auto-loop orchestration (experiment A/B)

    /// **v1.11.14.4**: 자동 폐루프 orchestration — session end 후 호출.
    /// activeExperimentId/baselineSessionId 가 있으면 controller append + compare 자동.
    /// disk IO 는 detached Task (UI hang 방지). test 에서 직접 호출 가능하도록
    /// internal 노출 + `baseDir` inject.
    func triggerAutoLoopIfActive(summaryId: String, baseDir: URL? = nil) {
        guard let expId = activeExperimentId, let baselineId = activeBaselineSessionId,
              let controller = experimentLoop else { return }
        Task { @MainActor [weak self, weak controller] in
            // Disk IO 는 detached background Task 로 await — main actor 비차단.
            let baseline = await Task.detached(priority: .userInitiated) {
                WalkLabSession.loadSummaryFromDisk(sessionId: baselineId, baseDir: baseDir)
            }.value
            let experimentSummaries = await Task.detached(priority: .userInitiated) {
                WalkLabSession.loadAllExperimentSummaries(experimentId: expId, baseDir: baseDir)
            }.value
            guard let controller = controller else { return }
            await controller.appendExperimentSession(summaryId)
            guard let b = baseline else { return }
            await controller.compareWithBaseline(
                baselineSummary: b,
                experimentSummaries: experimentSummaries
            )
            if let comp = controller.lastComparison {
                self?.lastRobotEvent =
                    "🔬 A/B 비교: \(comp.verdict.rawValue) — \(comp.reason)"
                // **v1.11.14.5 — 사용자 평가 CRIT 1 fix**: failRollback verdict 시 자동
                // rollback. 종전엔 verdict 만 표시되고 위험한 config 가 그대로 남음 →
                // 다음 보행에서 fall 가속 위험. 안전한 자동 보호.
                if comp.verdict == .failRollback {
                    _ = self?.rollbackExperiment()
                    // 사용자에게 명시 알림 — rollback 사유 (verdict reason) 포함.
                    self?.lastRobotEvent = "🔄 자동 rollback — \(comp.reason)"
                }
            }
        }
    }
}

// MARK: - Disk IO helpers (nonisolated static)
//
// `nonisolated static` — Task.detached 에서 background 호출 가능. MainActor 격리 해제
// 필요. 본 extension 은 `@MainActor` 가 아니라 nonisolated free function 같은 static
// helper 만 모음.

extension WalkLabSession {

    /// **v1.11.14**: baseline session 디스크 load (summary.json).
    /// **v1.11.14.1**: static + Sendable — Task.detached 에서 background 호출.
    /// **v1.11.14.2 (2026-05-19)**: substring match 제거 — WalkSessionLogger 의 명명
    /// 규칙 "{sessionId}-{preset}.summary.json" 따라 prefix match 로 강화. 종전
    /// `contains(sessionId)` 는 sessionId A 가 B 의 substring 일 때 false positive
    /// 가능 (현실에선 ISO timestamp 라 거의 충돌 X, 그러나 defensive coding).
    nonisolated static func loadSummaryFromDisk(sessionId: String,
                                                 baseDir: URL? = nil) -> WalkSessionSummary? {
        guard let dir = baseDir ?? WalkSessionStore.sessionsDir else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let match = files.first { url in
            extractSessionIdFromSummary(url) == sessionId
        }
        guard let url = match, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalkSessionSummary.self, from: data)
    }

    /// **v1.11.14.3 cold 2차**: prefix match 강화. WalkSessionLogger 의 명명 규칙
    /// "{sessionId}-{preset}.summary.json" 에서 마지막 hyphen 으로 sessionId 추출.
    /// 종전 `hasPrefix("\(sessionId)-")` 는 sessionId 가 hyphen 포함한 ISO timestamp
    /// (예: 2026-05-19T08-30) 라 짧은 prefix 가 false positive 매치.
    /// 본 함수는 ".summary.json" 제거 + 마지막 hyphen 분리 → 정확한 sessionId 추출.
    nonisolated private static func extractSessionIdFromSummary(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.hasSuffix(".summary.json") else { return nil }
        let stem = String(name.dropLast(".summary.json".count))
        // stem = "{sessionId}-{preset}". 마지막 hyphen 으로 분리.
        guard let lastHyphenIdx = stem.lastIndex(of: "-") else { return nil }
        return String(stem[stem.startIndex..<lastHyphenIdx])
    }

    /// **v1.11.14**: 같은 experimentId 의 모든 실험 세션 summary load.
    /// **v1.11.14.1**: static + Sendable — Task.detached 에서 background 호출.
    /// **v1.11.14.3**: baseDir inject — test 에서 임시 디렉토리 사용 가능.
    nonisolated static func loadAllExperimentSummaries(experimentId: String,
                                                       baseDir: URL? = nil) -> [WalkSessionSummary] {
        guard let dir = baseDir ?? WalkSessionStore.sessionsDir else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        // jsonl 의 header 에 experimentId 매치 → summary load.
        // **v1.11.14.3 (2026-05-19) — 진단 cold #D fix**: jsonl 전체 load 가 큰 sample
        // (수만 줄) 시 메모리 부담. 첫 줄 (header) 만 streaming read → O(header size).
        var summaries: [WalkSessionSummary] = []
        for jsonlURL in files where jsonlURL.pathExtension == "jsonl" {
            guard let firstLineData = readFirstLine(from: jsonlURL),
                  let header = try? decoder.decode(WalkSessionHeader.self, from: firstLineData),
                  header.experimentId == experimentId else { continue }
            let summaryURL = jsonlURL.deletingPathExtension()
                .appendingPathExtension("summary.json")
            guard let sData = try? Data(contentsOf: summaryURL),
                  let s = try? decoder.decode(WalkSessionSummary.self, from: sData) else { continue }
            summaries.append(s)
        }
        return summaries
    }

    /// **v1.11.14.3**: jsonl 의 첫 줄만 streaming read (전체 load X).
    /// FileHandle 로 chunk 단위 read → newline 만나면 즉시 종료.
    /// `nonisolated` — loadAllExperimentSummaries 가 nonisolated 라 동일하게 표시.
    /// **v1.11.14.4 (2026-05-19) — cold 3차 CRIT 1**: 동적 chunk 확장. header 의
    /// operatorNoteAtStart 등 사용자 입력 길이 무제한 → 8KB 초과 시 silent miss.
    /// newline 만날 때까지 반복 read. 최대 1MB 안전 한도 (그 이상은 header 오염).
    nonisolated private static func readFirstLine(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var accumulated = Data()
        let chunkSize = 8192
        let maxBytes = 1_048_576  // 1MB — header 안전 한도. 넘으면 비정상 jsonl.
        while accumulated.count < maxBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                // EOF — newline 못 찾았지만 끝까지 read. 누적 데이터 반환 (caller 가 parse 시도).
                return accumulated.isEmpty ? nil : accumulated
            }
            accumulated.append(chunk)
            if let newlineIdx = accumulated.firstIndex(of: 0x0a) {
                return accumulated.prefix(upTo: newlineIdx)
            }
        }
        return nil  // 1MB 넘는 header — 비정상.
    }
}
