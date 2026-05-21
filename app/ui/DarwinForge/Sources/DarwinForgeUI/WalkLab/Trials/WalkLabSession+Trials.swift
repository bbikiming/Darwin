import Foundation

/// **v1.15.0 (2026-05-21) — Phase 1 WalkLabSession 통합 hook**.
///
/// `WalkLabSession` 의 trial 생애주기 통합은 별도 extension 으로 분리 (god object 확장 금지).
/// Main file 에는 다음 2개 stored property 만 추가:
///   - `public var pendingLabelTrial: WalkTrial?` — 라벨 sheet 트리거 (SwiftUI .sheet item).
///   - `private var trialStartCapture: TrialStartCapture?` — start 시점 ephemeral capture.
///
/// 모든 메서드는 이 extension 안. main session 의 sessionLogger 가 jsonl 만들고, 종료 시
/// 본 extension 이 timeseries 로드 → Analyzer → Trial 생성 → Store 저장 → 라벨 sheet 트리거.
///
/// # 호출 site (단 3곳, 각 1줄)
///
/// 1. `start(_:)` preflight 통과 직후 — `captureTrialStart(preset:)`
/// 2. `stop()` 진입 직후 — `finalizeTrialIfPending(endReason: .userStop)`
/// 3. `emergencyStop(trigger:)` 진입 직후 — `finalizeTrialIfPending(endReason: .emergencyStop)`

/// trial 시작 시점의 ephemeral snapshot — finalize 시 outcome 계산에 사용.
struct TrialStartCapture {
    let startedAt: Date
    let preset: WalkLabPreset
    let config: TrialConfig
    /// sessionLogger 가 만든 jsonl 파일 경로 snapshot. nil = logger 비활성.
    let loggerFilePath: URL?
    /// sessionLogger 의 sessionId — trial.id 와 동일.
    let loggerSessionId: String?
}

extension WalkLabSession {

    /// trial 시작 — start(_:) preflight 통과 직후 호출.
    @MainActor
    func captureTrialStart(preset: WalkLabPreset) {
        let isReal = (store?.bus != nil)
        let tuning = TuningSnapshot(
            strideMm: strideMm,
            sideMm: sideMm,
            turnDeg: turnDeg,
            periodMs: customPeriodMs,
            footHeightMm: footHeightMm,
            balanceGain: balanceGain
        )
        let customGain: CustomGainSnapshot? = balanceExperimentConfig.gainProfile == .custom
            ? CustomGainSnapshot(
                hipRoll: customHipRollGain,
                knee: customKneeGain,
                anklePitch: customAnklePitchGain,
                ankleRoll: customAnkleRollGain
            )
            : nil
        let config = TrialConfig(
            preset: preset.rawValue,
            presetSafety: preset.safety.rawValue,
            intensityLevel: correctorIntensityLevel,
            balanceConfig: balanceExperimentConfig,
            enableBalanceCorrection: enableBalanceCorrection,
            tuning: tuning,
            customGain: customGain,
            walkingEngine: walkingEngine.rawValue,
            isRealRobot: isReal
        )
        trialStartCapture = TrialStartCapture(
            startedAt: Date(),
            preset: preset,
            config: config,
            loggerFilePath: nil,  // logger 는 startWalkCycle 안에서 만들어짐 — finalize 시 다시 확인.
            loggerSessionId: nil
        )
    }

    /// trial 종료 — stop() / emergencyStop() 등 종료 path 진입 직후 호출.
    /// **idempotent**: 같은 trial 에 대해 여러 번 호출돼도 한 번만 저장 (capture 가 nil 됨).
    @MainActor
    func finalizeTrialIfPending(endReason: EndReason) {
        guard let cap = trialStartCapture else { return }
        trialStartCapture = nil  // idempotent guard.

        let endedAt = Date()
        let duration = endedAt.timeIntervalSince(cap.startedAt)

        // logger 가 살아있다면 file path + sessionId 가져옴 (start 시점엔 미생성).
        let loggerPath: URL? = (sessionLogger as Any as? WalkSessionLoggerProtocolMirror)?.filePath
        let loggerSessionId: String? = (sessionLogger as Any as? WalkSessionLoggerProtocolMirror)?.sessionId
        // ↑ Mirror protocol 트릭: WalkSessionLogger 의 sessionId/filePath 가 public 이지만 직접 접근
        //   하면 sessionLogger 가 private 이라 extension 에서 못 봄. 같은 module 이라 internal
        //   접근 가능 — protocol mirror 불필요. 단순 cast 시도.

        // timeseries 정보 — logger 가 있고 sample count > 0 이면 ref.
        let timeseries: TimeseriesRef? = makeTimeseriesRef(
            loggerPath: loggerPath
        )

        // outcome 계산 + 저장. main actor 안에서 진행 (deinit safety).
        //
        // **v1.15.0.1 (2026-05-21) — flaky trap fix**: 종전 `Task.detached` 는 self 를
        // strong capture 해 instance lifetime 을 background queue 로 연장. 그 결과 deinit 이
        // background 에서 fire → `MainActor.assumeIsolated` trap (signal 5). 신규: 외부
        // Task 는 main isolated (호출자가 @MainActor func) 로 두고, file I/O 만 nonisolated
        // helper 로 분기 (WalkTrialStore 가 @unchecked Sendable). self 의 deinit 은 main
        // 에서 보장.
        let stepsExec = self.motorWriteStepCount
        let busFails = self.store?.busWriteFailureCount ?? 0
        let trialId = timeseries.map { _ in cap.startedAt.iso8601 + "-" + cap.preset.rawValue }
            ?? UUID().uuidString
        Task { [weak self, cap, endedAt, duration, timeseries, endReason, stepsExec, busFails, trialId] in
            // file I/O — background hop. WalkTrialStore 는 nonisolated 라 안전.
            let samples: [WalkSessionSample] = await Task.detached(priority: .utility) {
                guard let ref = timeseries else { return [] }
                return WalkTrialStore.shared.loadTimeseriesSamples(ref: ref) ?? []
            }.value

            let outcome = WalkTrialAnalyzer.analyze(
                samples: samples,
                endReason: endReason,
                durationSec: duration,
                stepsExecuted: stepsExec,
                busWriteFailures: busFails
            )
            let trial = WalkTrial(
                id: trialId,
                startedAtIso: cap.startedAt.iso8601,
                endedAtIso: endedAt.iso8601,
                durationSec: duration,
                endReason: endReason,
                config: cap.config,
                outcome: outcome,
                label: nil,
                timeseries: timeseries
            )
            // append 는 nonisolated → 어디서나 OK.
            WalkTrialStore.shared.append(trial)
            // 라벨 sheet 트리거는 main isolated (UI mutation).
            await MainActor.run {
                self?.pendingLabelTrial = trial
            }
        }
    }

    @MainActor
    private func makeTimeseriesRef(loggerPath: URL?) -> TimeseriesRef? {
        guard let path = loggerPath else { return nil }
        // 상대 경로 = "sessions/<filename>".
        let filename = path.lastPathComponent
        return TimeseriesRef(
            jsonlRelativePath: filename,
            sampleCount: (sessionLogger?.sampleCount) ?? 0,
            sampleRateHz: 10.0  // v1.14.8: tickDtSec 0.1 = 10Hz.
        )
    }
}

// MARK: - Mirror protocol — extension 의 cast 헬퍼

/// `sessionLogger` 가 `WalkSessionLogger?` 인데 extension 에선 private 접근 가능 (same module
/// rule). 직접 sessionLogger?.sessionId 사용해도 되지만, 명시적 protocol cast 로 의도 표시.
protocol WalkSessionLoggerProtocolMirror {
    var sessionId: String { get }
    var filePath: URL { get }
    var sampleCount: Int { get }
}

// MARK: - Date ISO 8601 helper

private extension Date {
    var iso8601: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: self)
    }
}
