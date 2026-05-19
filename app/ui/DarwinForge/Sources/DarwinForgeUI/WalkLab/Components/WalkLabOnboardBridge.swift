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
///
/// **v1.11.16 (2026-05-19) — Mac sparse 한계 본질 fix 일환**:
/// - send 결과 확인 (Exchange?.error) → 실패 시 session.lastRobotEvent 알림 +
///   safetyEvent 로그. 종전 silent SSH 실패 → 사용자 인지 불가.
/// - 첫 send 또는 모드 전환 시 daemon health-check ping (`echo OK` 단순 명령).
///   응답 없으면 brokerage daemon 미동작 추정 → 명시 alert.
/// - 마지막 ACK 시각 추적 (`lastAckAt`) → UI 가 staleness 표시 가능.
struct WalkLabOnboardBridge: View {
    @ObservedObject var session: WalkLabSession
    @EnvironmentObject private var remoteShell: RemoteShell

    /// debounce 타이머 — slider drag 중 마지막 값만 1회 send.
    @State private var debounceTask: Task<Void, Never>? = nil

    /// 마지막 송출한 명령 — 변경 없으면 skip (중복 SSH 방지).
    @State private var lastSentLine: String? = nil

    /// **v1.11.16**: 마지막 health-check ping 시각. nil = 미수행 또는 실패.
    @State private var lastHealthCheckAt: Date? = nil

    /// **v1.11.16**: 연속 send 실패 횟수. 3회 이상이면 사용자 alert.
    @State private var consecutiveFailures: Int = 0

    var body: some View {
        // invisible view — UI 출력 없음.
        // **v1.11.7 (2026-05-18, GPT HIGH-1 fix)**: brokering trigger 를 특정 튜닝
        // 값으로 축소. 종전 session.objectWillChange 전체 → IMU/safetyTimeline/
        // fallPrediction 같은 published 가 50ms tick 마다 변경 → debounce 계속 reset
        // 되어 실 송신 못 함. 8 개 specific @Published 만 watch.
        //
        // **v1.11.8 (2026-05-18, HIGH-3/5 fix)**:
        // - walkingEngine / onboardWalkingActive / autoOnboardBrokering 전환 시
        //   lastSentLine reset (stale dedup 방지)
        // - remoteShell.host onChange 도 trigger (host 설정 후 자동 송출)
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: session.current)                  { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.walkingEngine) { _, newValue in
                lastSentLine = nil   // engine 전환 → dedup reset
                // **v1.11.16**: onboard 진입 시 health-check ping.
                if newValue == .robotisOnboard {
                    scheduleHealthCheck()
                }
                scheduleDebouncedSend()
            }
            .onChange(of: session.autoOnboardBrokering) { _, newValue in
                lastSentLine = nil   // brokering toggle → resend 보장
                // **v1.11.16**: brokering ON 전환 시 health-check.
                if newValue {
                    scheduleHealthCheck()
                }
                scheduleDebouncedSend()
            }
            .onChange(of: session.onboardWalkingActive) { _, _ in
                lastSentLine = nil   // start/stop edge → resend 보장
                scheduleDebouncedSend()
            }
            .onChange(of: remoteShell.host) { _, _ in
                lastSentLine = nil   // host 변경 → send (config 변경 후 첫 송출)
                scheduleDebouncedSend()
            }
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
            // **v1.11.16**: send 결과 확인.
            let exchange = await remoteShell.send(shellCmd)
            handleSendResult(exchange: exchange, commandLine: line)
        }
    }

    /// **v1.11.16 (2026-05-19)**: send 결과 처리.
    /// - 성공: consecutiveFailures reset, lastRobotEvent 갱신 (debug 모드만).
    /// - 실패: consecutiveFailures++ + lastRobotEvent + safetyEvent.
    /// - 3회 연속 실패: 사용자 명시 alert (lastRobotEvent + critical safetyEvent).
    private func handleSendResult(exchange: RemoteShell.Exchange?, commandLine: String) {
        guard let exchange = exchange else { return }
        if let error = exchange.error {
            consecutiveFailures += 1
            session.setLastRobotEvent("⚠️ ROBOTIS Onboard 명령 실패 (\(consecutiveFailures)회 연속): \(error)")
            session.logSafetyEvent(
                kind: .correctorOff,
                message: "Onboard send 실패: \(error). cmd=\(commandLine.prefix(60))"
            )
            if consecutiveFailures >= 3 {
                session.setLastRobotEvent("🛑 ROBOTIS Onboard 연속 실패 3회 — daemon 또는 SSH 점검 필요")
                session.logSafetyEvent(
                    kind: .correctorOff,
                    message: "Onboard 통신 비정상 — Mac sparse 로 전환 권장"
                )
            }
        } else {
            // 성공.
            if consecutiveFailures > 0 {
                session.setLastRobotEvent("✓ ROBOTIS Onboard 통신 복구 — \(consecutiveFailures)회 실패 후")
            }
            consecutiveFailures = 0
        }
    }

    /// **v1.11.16 (2026-05-19)**: daemon health-check ping.
    /// brokerage daemon 이 robot 측에서 동작 중인지 확인. 단순 `echo OK` 명령.
    /// 응답이 timeout 또는 error 면 daemon 미동작 추정 → 사용자 alert.
    private func scheduleHealthCheck() {
        guard !remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            // 짧은 sleep — onChange 가 연달아 일어날 때 마지막만 ping.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            let ping = "echo OK"
            let exchange = await remoteShell.send(ping)
            if let exchange = exchange {
                if let error = exchange.error {
                    session.setLastRobotEvent("⚠️ Onboard health-check 실패: \(error)")
                    session.logSafetyEvent(
                        kind: .correctorOff,
                        message: "Onboard daemon ping 실패 — robot 측 walklab-brokerage 데몬 확인 필요"
                    )
                    lastHealthCheckAt = nil
                } else {
                    lastHealthCheckAt = Date()
                    session.logSafetyEvent(
                        kind: .correctorOn,
                        message: "Onboard health-check OK (ssh \(exchange.elapsedMs ?? 0)ms)"
                    )
                }
            }
        }
    }
}
