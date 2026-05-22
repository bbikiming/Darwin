import Foundation
import ForgeCore

/// **v1.19.0 (2026-05-21) 사이클 3 — Trial 자동 생성 도구**.
///
/// 사이클 1+2 평가: Recommender (Phase 2) 가 실 사용자 trial 5+ 누적 없으면 nil 반환
/// — 빈 깡통. sim 모드 trial 자동 생성으로 Phase 1+2 활성화.
///
/// # 동작
///
/// 4-D config space (preset × intensity × tuning × balance) 를 grid 또는 random
/// sampling 으로 탐색. 각 sample 마다:
/// 1. WalkLabSession.start(preset) — 사용자 입력 없이 자동
/// 2. simTimer 가 N 초간 sample 생성
/// 3. WalkLabSession.stop() — trial finalize hook (Phase 1 의 +Trials extension)
/// 4. WalkTrialStore 에 자동 저장
///
/// **주의**: 본 도구는 sim 모드 전용 — 실 robot 송출 X (start 가 bus.bus==nil 일 때만 진행).
@MainActor
public final class WalkTrialAutoGenerator {

    /// 진행 중 상태 — view binding.
    public private(set) var progress: Progress?

    public init() {}

    /// N개의 trial 자동 생성 + 저장.
    /// - Parameters:
    ///   - session: WalkLabSession (sim 모드 강제 검증)
    ///   - presetSet: 탐색 할 preset 목록 (default: 4개 — slowWalk/normalWalk/march/fastWalk)
    ///   - intensityRange: 0..4
    ///   - trialsPerCombo: 같은 config 반복 trial 수 (variance 캡처)
    ///   - durationSec: 각 trial 의 sim 보행 시간 (default 5초)
    ///   - onProgress: 진행 callback (current / total / sampleConfig)
    public func generateBatch(
        session: WalkLabSession,
        presetSet: [WalkLabPreset] = [.slowWalk, .normalWalk, .march, .fastWalk],
        intensityRange: ClosedRange<Int> = 0...4,
        trialsPerCombo: Int = 2,
        durationSec: Double = 5.0,
        onProgress: ((Progress) -> Void)? = nil
    ) async {
        // sim 모드 검증 — bus 가 nil 이어야.
        guard session.store?.bus == nil else {
            return  // 실 robot 연결 시 거부 (사용자 보호).
        }

        // **v1.21.1 사이클 66 — 코덱스 HIGH-1 fix + 사이클 71 — 코덱스 CRITICAL-2 강화**:
        // emergency 활성 시 silent breakage 차단 + facade 일관성.
        //
        // 사이클 71 변경:
        // 1. lastRobotEvent 직접 write → `pilotPostEvent` facade 사용 (length cap / dedup /
        //    source prefix 일관성). 종전 직접 write 는 cycle 60 facade 규칙 위반.
        // 2. lastPreflightFailure / startBlockedReason 명시 set — root guard 의 invariant 와
        //    일치 (test 가 generator 자체의 guard 만으로 cause 검증 가능).
        if session.emergencyStopActive {
            let f = WalkLabSession.WalkPreflightFailure(cause: .emergencyActive)
            session.pilotMarkPreflightFailure(f)
            session.pilotPostEvent(
                "Auto Trial 생성 차단 — \(f.userMessage)",
                source: .ui
            )
            progress = Progress(
                current: 0, total: 0,
                lastTrial: "emergency 활성 — 차단됨"
            )
            onProgress?(progress!)
            return
        }

        let total = presetSet.count * intensityRange.count * trialsPerCombo
        var current = 0
        progress = Progress(current: 0, total: total, lastTrial: nil)

        for preset in presetSet {
            for intensity in intensityRange {
                for _ in 0..<trialsPerCombo {
                    current += 1
                    progress = Progress(
                        current: current, total: total,
                        lastTrial: "\(preset.rawValue) lvl=\(intensity)"
                    )
                    onProgress?(progress!)

                    // 1) config 설정.
                    session.correctorIntensityLevel = intensity
                    // 2) 보행 시작.
                    session.start(preset)
                    // 3) sim duration 대기 — sim tick 이 trial sample 생성.
                    try? await Task.sleep(nanoseconds: UInt64(durationSec * 1_000_000_000))
                    // 4) 정상 종료 — WalkLabSession+Trials.finalize 가 자동 store 저장.
                    session.stop()
                    // 5) 짧은 settle wait — Task.detached 의 file write 완료 위해.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }

        progress = Progress(current: total, total: total, lastTrial: "완료")
        onProgress?(progress!)
    }

    /// 단발 generation — 한 config 의 한 trial.
    public func generateSingle(
        session: WalkLabSession,
        preset: WalkLabPreset,
        intensity: Int,
        durationSec: Double = 5.0
    ) async {
        guard session.store?.bus == nil else { return }
        // 사이클 66 + 사이클 71 — emergency silent breakage 차단 + facade 일관성.
        if session.emergencyStopActive {
            let f = WalkLabSession.WalkPreflightFailure(cause: .emergencyActive)
            session.pilotMarkPreflightFailure(f)
            session.pilotPostEvent(
                "Auto Trial single 차단 — \(f.userMessage)",
                source: .ui
            )
            return
        }
        session.correctorIntensityLevel = intensity
        session.start(preset)
        try? await Task.sleep(nanoseconds: UInt64(durationSec * 1_000_000_000))
        session.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    public struct Progress: Equatable, Sendable {
        public let current: Int
        public let total: Int
        public let lastTrial: String?

        public var percentComplete: Double {
            guard total > 0 else { return 0 }
            return Double(current) / Double(total)
        }
    }
}
