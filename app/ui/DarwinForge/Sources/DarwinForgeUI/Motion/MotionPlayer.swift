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

    public var page: MotionPage?
    /// 페이지 시작 자세 (default: walk_ready).
    public var startPose: RobotPose = .walkReady

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
    }

    public func play() {
        guard page != nil else { return }
        if mode == .playing { return }
        mode = .playing
        lastTickTime = .now
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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
        timer?.invalidate()
        timer = nil
        mode = .stop
        elapsedMs = 0
        currentStepIndex = 0
        if let p = page {
            pose = startPose
            _ = p
        }
    }

    public func seek(toMs ms: Double) {
        guard let page else { return }
        elapsedMs = max(0, min(ms, Double(page.totalDurationMs)))
        recompute()
    }

    // MARK: - Tick

    private func tick() {
        guard mode == .playing else { return }
        let now = Date()
        let dt = now.timeIntervalSince(lastTickTime ?? now) * 1000.0
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
        mode = .stop
        timer?.invalidate(); timer = nil
    }

    private func cubicEase(_ t: Double) -> Double {
        // 부드러운 시작·끝 (in-out cubic).
        let u = t.clamped(to: 0...1)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }
}
