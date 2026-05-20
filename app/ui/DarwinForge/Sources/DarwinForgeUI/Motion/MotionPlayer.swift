import Foundation
import ForgeCore

/// 한 페이지의 step 시퀀스를 시간에 따라 보간 재생.
///
/// 디자인:
/// - Step i = 시작 자세, Step i+1 = 도달 목표.
/// - play_time(ms) 동안 lerp(easing=cubic) → pause_time 동안 정지 → 다음 step.
/// - tick(now)이 현재 RobotPose를 반환. 재생 끝나면 isPlaying=false.
/// - 실 모터로 발행은 ConnectionStore에서 호출자가 결정.
@MainActor
public final class MotionPlayer: ObservableObject {

    public enum Mode: String, Sendable {
        case stop, playing, paused
    }

    @Published public private(set) var mode: Mode = .stop
    @Published public private(set) var elapsedMs: Double = 0
    @Published public private(set) var currentStepIndex: Int = 0
    @Published public private(set) var pose: RobotPose = .walkReady

    /// 재생 속도 — 0.25 ~ 2.0. UI 가 표준 0.5 / 1.0 / 2.0 cycle.
    @Published public var playbackRate: Double = 1.0
    /// 끝에 도달 시 처음부터 다시 재생 (loop).
    @Published public var isLooping: Bool = false

    public var page: MotionPage?
    /// 페이지 시작 자세 (default: walk_ready).
    public var startPose: RobotPose = .walkReady

    /// 총 재생 시간 (ms) — UI 가 자주 조회.
    public var totalDurationMs: Double { Double(page?.totalDurationMs ?? 0) }

    private var timer: Timer?
    private var lastTickTime: Date?

    public init() {}

    // MARK: - Control

    public func load(_ page: MotionPage, from start: RobotPose = .walkReady) {
        stop()
        self.page = page
        self.startPose = start
        self.pose = start
        self.elapsedMs = 0
        self.currentStepIndex = 0
        // **v1.14.2 (2026-05-21)** — motion 페이지 로드 telemetry.
        // 사용자가 어떤 motion 을 선택했는지 추적 — play 시작 전 의도 분리.
        Harness.shared.record(
            .motionLoad, level: .info, actor: .user,
            data: ["page_id": AnyCodable(page.id),
                   "page_name_hash": AnyCodable(Harness.shortHash(page.name)),
                   "step_count": AnyCodable(page.steps.count),
                   "duration_ms": AnyCodable(page.totalDurationMs)]
        )
    }

    public func play() {
        guard let p = page else { return }
        if mode == .playing { return }
        mode = .playing
        lastTickTime = .now
        timer?.invalidate()
        // v1.12.2 telemetry — 모션 재생 시작 (page name redacted).
        Harness.shared.record(
            .motionPlayStart, level: .info, actor: .user,
            data: ["page_name_hash": AnyCodable(Harness.shortHash(p.name)),
                   "page_id": AnyCodable(p.id),
                   "step_count": AnyCodable(p.steps.count),
                   "duration_ms": AnyCodable(p.totalDurationMs)]
        )
        // v1.11.2 (2026-05-18): CI Swift 5.9 호환 — inner Task closure 에 weak self 재캡쳐.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    public func pause() {
        if mode == .playing {
            mode = .paused
            timer?.invalidate()
            timer = nil
        }
    }

    public func stop() {
        let wasPlaying = (mode == .playing)
        let elapsedForHarness = elapsedMs
        let pageNameForHarness = page?.name
        timer?.invalidate()
        timer = nil
        mode = .stop
        elapsedMs = 0
        currentStepIndex = 0
        if let p = page {
            pose = startPose
            _ = p
        }
        if wasPlaying, let name = pageNameForHarness {
            Harness.shared.record(
                .motionPlayAbort, level: .info, actor: .user,
                data: ["page_name_hash": AnyCodable(Harness.shortHash(name)),
                       "elapsed_ms": AnyCodable(elapsedForHarness)]
            )
        }
    }

    public func seek(toMs ms: Double) {
        guard let page else { return }
        elapsedMs = max(0, min(ms, Double(page.totalDurationMs)))
        recompute()
    }

    /// 처음으로 (0ms).
    public func seekToStart() { seek(toMs: 0) }

    /// 끝으로 (totalDurationMs).
    public func seekToEnd() {
        guard let page else { return }
        seek(toMs: Double(page.totalDurationMs))
    }

    /// 한 step 앞으로 (dir=+1) / 뒤로 (dir=-1) — 키프레임 navigation.
    /// 현재 step 의 시작 지점으로 snap 후 dir 적용.
    public func step(by dir: Int) {
        guard let page else { return }
        let target = currentStepIndex + dir
        guard target >= 0, target < page.steps.count else { return }
        var t = 0
        for i in 0..<target { t += page.steps[i].playMs + page.steps[i].pauseMs }
        seek(toMs: Double(t))
    }

    /// 특정 step 의 시작 지점으로 jump.
    public func jumpToStep(_ index: Int) {
        guard let page else { return }
        let clamped = max(0, min(index, page.steps.count - 1))
        var t = 0
        for i in 0..<clamped { t += page.steps[i].playMs + page.steps[i].pauseMs }
        seek(toMs: Double(t))
    }

    /// 재생 속도 cycle — 0.5 → 1.0 → 2.0 → 0.5.
    public func cyclePlaybackRate() {
        switch playbackRate {
        case 0.5: playbackRate = 1.0
        case 1.0: playbackRate = 2.0
        default:  playbackRate = 0.5
        }
    }

    // MARK: - Tick

    private func tick() {
        guard mode == .playing else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTickTime ?? now) * 1000.0 * playbackRate
        lastTickTime = now
        elapsedMs += dt
        recompute()
    }

    private func recompute() {
        guard let page else { return }
        guard !page.steps.isEmpty else {
            mode = .stop
            return
        }

        // 누적 시간 표를 만들고 현재 시점 어디인지 찾는다.
        var t: Double = 0
        var prevPose = startPose
        for (idx, step) in page.steps.enumerated() {
            let playMs = Double(step.playMs)
            let pauseMs = Double(step.pauseMs)
            let nextPose = step.toPose()
            let stepStart = t
            let stepPlayEnd = t + playMs
            let stepPauseEnd = t + playMs + pauseMs

            if elapsedMs <= stepPlayEnd {
                let frac = playMs > 0 ? max(0, min(1, (elapsedMs - stepStart) / playMs)) : 1
                pose = prevPose.lerp(to: nextPose, t: cubicEase(frac))
                currentStepIndex = idx
                return
            }
            if elapsedMs <= stepPauseEnd {
                pose = nextPose
                currentStepIndex = idx
                return
            }
            t = stepPauseEnd
            prevPose = nextPose
        }

        // 페이지 끝.
        pose = prevPose
        currentStepIndex = page.steps.count - 1
        if isLooping {
            // Loop 모드 — 처음으로 wrap-around. mode 유지, timer 유지.
            elapsedMs = 0
            // 다음 tick 에서 다시 시작 step 부터 계산.
        } else {
            // **v1.12.2 (Codex re-review fix)** — 자연 종료 telemetry.
            // mode == .playing 일 때만 발행. 사용자가 seek(toEnd) 등으로 elapsedMs 를
            // 끝으로 옮긴 뒤 recompute 호출 시 misfire 안 됨 (mode == .stop / .paused).
            if mode == .playing {
                Harness.shared.record(
                    .motionPlayComplete, level: .info, actor: .system,
                    data: ["page_name_hash": AnyCodable(Harness.shortHash(page.name)),
                           "page_id": AnyCodable(page.id),
                           "elapsed_ms": AnyCodable(elapsedMs)]
                )
            }
            mode = .stop
            timer?.invalidate(); timer = nil
        }
    }

    private func cubicEase(_ t: Double) -> Double {
        // 부드러운 시작·끝 (in-out cubic).
        let u = t.clamped(to: 0...1)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }
}
