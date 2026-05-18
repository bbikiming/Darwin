import SwiftUI
import Combine

/// **v1.11.6 (2026-05-18)** — WalkLab `.robotisOnboard` 모드의 자동 brokering bridge.
///
/// 사용자가 preset / tuning / hipPitchOffset / walkingEngine 변경 시 자동으로
/// `RobotSetupCommand.walkLabRobotisSendCommand` 를 RemoteShell 통해 SSH send.
/// debounce 300ms 로 slider drag 중 SSH spam 방지.
///
/// **invisible view** — UI 출력 없음, `.onReceive` 만 사용. WalkLabView 안에
/// `WalkLabOnboardBridge(session: session)` 한 줄 추가.
///
/// **선결조건**:
/// - `walkingEngine == .robotisOnboard` 일 때만 send.
/// - `remoteShell.host` 가 설정되어 있을 때만 send (`isHostConfigured`).
/// - 사용자가 명시 OFF 가능 (`autoBrokeringEnabled` 토글).
struct WalkLabOnboardBridge: View {
    @ObservedObject var session: WalkLabSession
    @EnvironmentObject private var remoteShell: RemoteShell

    /// debounce 타이머 — slider drag 중 마지막 값만 1회 send.
    @State private var debounceTask: Task<Void, Never>? = nil

    /// 마지막 송출한 명령 — 변경 없으면 skip (중복 SSH 방지).
    @State private var lastSentLine: String? = nil

    var body: some View {
        // invisible view — UI 출력 없음.
        // **v1.11.7 (2026-05-18, GPT HIGH-1 fix)**: brokering trigger 를 특정 튜닝
        // 값으로 축소. 종전 session.objectWillChange 전체 → IMU/safetyTimeline/
        // fallPrediction 같은 published 가 50ms tick 마다 변경 → debounce 계속 reset
        // 되어 실 송신 못 함. 8 개 specific @Published 만 watch.
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: session.current)                  { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.walkingEngine)            { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.autoOnboardBrokering)     { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.strideMm)                 { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.sideMm)                   { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.turnDeg)                  { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.customPeriodMs)           { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.footHeightMm)             { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.hipPitchOffsetTrimDeg)    { _, _ in scheduleDebouncedSend() }
    }

    /// 300ms debounce — 마지막 변경 후 가만히 있으면 send. drag 중에는 매번 cancel.
    private func scheduleDebouncedSend() {
        guard session.autoOnboardBrokering else { return }
        guard session.walkingEngine == .robotisOnboard else { return }
        guard !remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            if Task.isCancelled { return }

            let cmd = session.currentWalkingEngineCommand(enabled: session.current != .idle)
            let line = cmd.serializedLine

            // 동일 명령 중복 send 회피.
            if line == lastSentLine { return }
            lastSentLine = line

            let shellCmd = RobotSetupCommand.walkLabRobotisSendCommand(line: line)
            await remoteShell.send(shellCmd)
        }
    }
}
