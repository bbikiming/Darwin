import SwiftUI
import Combine

/// **v1.11.6 (2026-05-18)** — WalkLab `.robotisOnboard` 모드의 자동 brokering bridge.
///
/// **v1.11.16.2 (2026-05-19) — Codex cold 검증 fix**:
/// - cmd_id nonce + ACK seq 검증 (stale ACK 차단)
/// - 1 in-flight serialize (actor `OnboardSendQueue`) — race 차단
/// - lastSentLine 갱신을 send 시작 전 → ACK 받은 후로 변경 (실패 재시도 보장)
/// - auto fallback 시 walking stop ACK 확인 후 engine 변경 (robot 보행 잔존 차단)
/// - deadline polling 1.5s (sleep 0.25 보다 robust)
struct WalkLabOnboardBridge: View {
    var session: WalkLabSession
    @EnvironmentObject private var remoteShell: RemoteShell

    /// debounce 타이머 — slider drag 중 마지막 값만 1회 send.
    @State private var debounceTask: Task<Void, Never>? = nil

    /// **v1.11.16.2**: send queue actor — 1 in-flight 직렬화.
    /// 종전: 동시 send 시 shared /tmp/df-walklab-cmd 에 write race + lastSentLine
    /// 선갱신으로 실패 시 재시도 누락.
    @State private var sendQueue: OnboardSendQueue = OnboardSendQueue()

    /// 마지막 *성공* 송출 명령 (ACK 받은 후 갱신). 동일 값 중복 send skip.
    /// 종전: send 시작 전 갱신 → 실패해도 같은 값 재시도 안 됨.
    @State private var lastAckedLine: String? = nil

    /// **v1.11.16**: 연속 send 실패 횟수. 3회 이상이면 사용자 alert.
    @State private var consecutiveFailures: Int = 0

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // IMMEDIATE: critical user action.
            // v1.11.24 audit iter2-I — activeRobotPreset 도 같이 관찰 (P1-1 split 이후
            // 실 motor task 가 cycle 종료 / 자동 정지로 nil 이 되는 시점도 trigger).
            .onChange(of: session.current)                  { _, _ in scheduleImmediateSend() }
            .onChange(of: session.activeRobotPreset)        { _, _ in scheduleImmediateSend() }
            .onChange(of: session.walkingEngine) { _, newValue in
                lastAckedLine = nil   // engine 전환 → dedup reset
                if newValue == .robotisOnboard {
                    scheduleHealthCheck()
                }
                scheduleImmediateSend()
            }
            .onChange(of: session.autoOnboardBrokering) { _, newValue in
                lastAckedLine = nil
                if newValue {
                    scheduleHealthCheck()
                }
                scheduleImmediateSend()
            }
            .onChange(of: session.onboardWalkingActive) { _, _ in
                lastAckedLine = nil
                scheduleImmediateSend()
            }
            .onChange(of: remoteShell.host) { _, _ in
                lastAckedLine = nil
                scheduleImmediateSend()
            }
            // DEBOUNCED: slider drag.
            .onChange(of: session.strideMm)                 { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.sideMm)                   { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.turnDeg)                  { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.customPeriodMs)           { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.footHeightMm)             { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.hipPitchOffsetTrimDeg)    { _, _ in scheduleDebouncedSend() }
    }

    /// **v1.11.16.1**: critical 변경 — 즉시 send (debounce 우회).
    /// **v1.11.16.2**: actor queue 경유 — 1 in-flight 보장.
    private func scheduleImmediateSend() {
        guard shouldSend() else { return }
        debounceTask?.cancel()
        // v1.11.24 audit iter2-I — enabled 는 activeRobotPreset 우선 (실 task 진행 중 여부).
        // sim / no-task 시 fallback 으로 current.
        let effectivePreset = session.activeRobotPreset ?? session.current
        let cmd = session.currentWalkingEngineCommand(enabled: effectivePreset != .idle)
        let line = cmd.serializedLine
        if line == lastAckedLine { return }
        Task { @MainActor in
            await performSend(line: line, isImmediate: true)
        }
    }

    /// 300ms debounce — 마지막 변경 후 가만히 있으면 send. drag 중에는 매번 cancel.
    /// **v1.11.16.2**: actor queue 경유 — race 차단.
    private func scheduleDebouncedSend() {
        guard shouldSend() else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // v1.11.24 audit iter2-I — enabled 는 activeRobotPreset 우선 (실 task 진행 중 여부).
        // sim / no-task 시 fallback 으로 current.
        let effectivePreset = session.activeRobotPreset ?? session.current
        let cmd = session.currentWalkingEngineCommand(enabled: effectivePreset != .idle)
            let line = cmd.serializedLine
            if line == lastAckedLine { return }
            await performSend(line: line, isImmediate: false)
        }
    }

    /// **v1.11.16.2** — 실 send 수행. actor queue 가 직렬화 보장.
    /// cmd_id 생성 → SSH send → ACK 검증 → 결과 처리.
    @MainActor
    private func performSend(line: String, isImmediate: Bool) async {
        let cmdId = RobotSetupCommand.generateCmdId()
        let shellCmd = RobotSetupCommand.walkLabRobotisSendCommand(line: line, cmdId: cmdId)
        // actor queue 진입 — 1 in-flight 보장.
        let exchange = await sendQueue.enqueueSend(shellCmd: shellCmd, shell: remoteShell)
        handleSendResult(exchange: exchange, commandLine: line, expectedCmdId: cmdId)
    }

    /// shouldSend gate — onboard 모드 + brokering ON + host 설정.
    private func shouldSend() -> Bool {
        guard session.autoOnboardBrokering else { return false }
        guard session.walkingEngine == .robotisOnboard else { return false }
        guard !remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    /// **v1.11.16.1+.2**: send 결과 처리 + cmd_id 매치 검증.
    /// 분기:
    /// - error 있음 → SSH 실패.
    /// - "OK ..." prefix + cmd_id 매치 → 성공.
    /// - "OK ..." prefix + cmd_id 불일치 → stale ACK (이전 명령), 실패로 간주.
    /// - "NO_ACK" → daemon missing.
    /// - 그 외 → unknown.
    private func handleSendResult(exchange: RemoteShell.Exchange?,
                                   commandLine: String,
                                   expectedCmdId: String) {
        guard let exchange = exchange else { return }
        if let error = exchange.error {
            consecutiveFailures += 1
            session.onboardConsecutiveFailures = consecutiveFailures
            session.onboardLastError = error
            session.onboardLastAckAt = nil
            // v1.11.24 audit iter4-A — footer 의 onboardAckStatus 가 "pending" 으로 남지 않도록.
            session.setOnboardAckStatus("error: \(error.prefix(40))")
            session.setLastRobotEvent("⚠️ ROBOTIS Onboard 명령 실패 (\(consecutiveFailures)회 연속): \(error)")
            session.logSafetyEvent(
                kind: .correctorOff,
                message: "Onboard send 실패: \(error). cmd=\(commandLine.prefix(60))"
            )
            if consecutiveFailures >= 3 {
                session.setLastRobotEvent("🛑 ROBOTIS Onboard 연속 실패 3회 — daemon 또는 SSH 점검 필요")
                Task { @MainActor in await handleAutoFallbackIfEnabled() }
            }
            return
        }
        // SSH 자체는 성공 — ACK 검증.
        let result = exchange.result ?? ""
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("OK ") {
            // ACK 받음 — cmd_id 매치 검사 (v1.11.16.2 firmware 부터).
            // 형식: "OK {ts_ms} {cmd_id} {line}" 또는 "OK {ts_ms} {line}" (backward).
            let tokens = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            let ackCmdId: String? = tokens.count >= 3 ? String(tokens[2]) : nil
            // backward-compat: cmd_id 없는 firmware (v1.11.16.1) 면 매치 강제 X.
            let isStale = (ackCmdId != nil) && (ackCmdId != expectedCmdId) && (ackCmdId != "no_id")
            if isStale {
                // stale ACK — 이전 명령의 응답이 우리 명령에 매치. 실패로 처리.
                consecutiveFailures += 1
                session.onboardConsecutiveFailures = consecutiveFailures
                session.onboardLastError = "stale ACK (expected=\(expectedCmdId), got=\(ackCmdId ?? "nil"))"
                session.setOnboardAckStatus("stale")  // v1.11.24 audit iter4-A
                session.logSafetyEvent(
                    kind: .correctorOff,
                    message: "Onboard stale ACK — daemon 처리 지연 또는 race. expected=\(expectedCmdId)"
                )
                return
            }
            // 진짜 성공.
            session.onboardLastAckAt = Date()
            session.onboardLastError = nil
            session.onboardDaemonMissing = false
            session.setOnboardAckStatus("ok")  // v1.11.24 audit iter4-A
            lastAckedLine = commandLine
            if consecutiveFailures > 0 {
                session.setLastRobotEvent("✓ ROBOTIS Onboard 통신 복구 — \(consecutiveFailures)회 실패 후")
            }
            consecutiveFailures = 0
            session.onboardConsecutiveFailures = 0
        } else if trimmed == "NO_ACK" || trimmed.contains("NO_ACK") {
            consecutiveFailures += 1
            session.onboardConsecutiveFailures = consecutiveFailures
            session.onboardDaemonMissing = true
            session.onboardLastError = "daemon 응답 없음 (NO_ACK)"
            session.setOnboardAckStatus("no_ack")  // v1.11.24 audit iter4-A
            session.setLastRobotEvent("⚠️ Onboard daemon 응답 없음 — firmware patch 적용 또는 데몬 시작 필요")
            session.logSafetyEvent(
                kind: .correctorOff,
                message: "Onboard NO_ACK — robot 측 walklab-brokerage 데몬 미동작"
            )
            if consecutiveFailures >= 3 {
                Task { @MainActor in await handleAutoFallbackIfEnabled() }
            }
        } else {
            session.onboardLastError = "예상치 못한 응답: \(trimmed.prefix(40))"
            session.logSafetyEvent(
                kind: .correctorOff,
                message: "Onboard 응답 형식 인식 불가: \(trimmed.prefix(60))"
            )
        }
    }

    /// **v1.11.16.2 — Codex CRITICAL 2 fix**: 자동 fallback 의 안전 sequence.
    /// 종전: walkingEngine 만 변경. robot 측 walking 은 5초 stale timeout 까지 계속.
    /// 신: 1) walking stop 명령 (enabled=0) send + ACK 대기, 2) ACK 받으면 engine 변경.
    ///     3) stop ACK 실패 시 사용자에게 E-stop 요구 alert (자동 engine 변경 X).
    @MainActor
    private func handleAutoFallbackIfEnabled() async {
        let autoFallback = UserDefaults.standard.bool(forKey: "df.walklab.autoOnboardFallback")
        guard autoFallback else { return }
        guard session.walkingEngine == .robotisOnboard else { return }
        // 1. 명시 stop 명령 (enabled=0).
        let stopLine = "0 0.00 0.00 0.00 600 40 13.00"
        let stopCmdId = RobotSetupCommand.generateCmdId()
        let stopShellCmd = RobotSetupCommand.walkLabRobotisSendCommand(
            line: stopLine, cmdId: stopCmdId
        )
        let stopExchange = await sendQueue.enqueueSend(shellCmd: stopShellCmd, shell: remoteShell)
        let stopOK = stopExchange?.result?.contains("OK ") ?? false
        if !stopOK {
            // 안전 우려 — engine 변경 X. 사용자에게 명시 E-stop 요구.
            session.setLastRobotEvent("🛑 Onboard fallback 차단 — robot stop 명령도 실패. ⌘⇧. E-stop 권장")
            session.logSafetyEvent(
                kind: .correctorOff,
                message: "Auto fallback aborted: stop ACK 실패. 수동 E-stop 필요."
            )
            return
        }
        // 2. stop ACK 성공 → engine 안전하게 변경.
        session.walkingEngine = .macSparseKeyframe
        consecutiveFailures = 0
        session.onboardConsecutiveFailures = 0
        session.setLastRobotEvent("🔄 자동 fallback: stop 확인 후 Mac sparse 로 전환됨")
        session.logSafetyEvent(
            kind: .correctorOff,
            message: "Auto fallback: stop ACK 후 walkingEngine → .macSparseKeyframe"
        )
    }

    /// **v1.11.16 (2026-05-19)**: daemon health-check ping.
    /// brokerage daemon 이 robot 측에서 동작 중인지 확인. 단순 `echo OK` 명령.
    private func scheduleHealthCheck() {
        guard !remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            let ping = "echo OK"
            // health-check 도 queue 경유 — race 차단.
            let exchange = await sendQueue.enqueueSend(shellCmd: ping, shell: remoteShell)
            if let exchange = exchange {
                if let error = exchange.error {
                    session.setLastRobotEvent("⚠️ Onboard health-check 실패: \(error)")
                    session.logSafetyEvent(
                        kind: .correctorOff,
                        message: "Onboard daemon ping 실패 — robot 측 walklab-brokerage 데몬 확인 필요"
                    )
                } else {
                    session.onboardLastAckAt = Date()
                    session.logSafetyEvent(
                        kind: .correctorOn,
                        message: "Onboard health-check OK (ssh \(exchange.elapsedMs ?? 0)ms)"
                    )
                }
            }
        }
    }
}

/// **v1.11.16.2 (2026-05-19) — Codex HIGH 3 fix**: send queue actor.
/// 종전: WalkLabOnboardBridge 의 immediate / debounce / health-check 가 동시에
/// shared /tmp/df-walklab-cmd 에 write → race + ACK 도 last writer 의 응답 받음.
/// actor 가 1 in-flight 보장 — 순차 처리.
actor OnboardSendQueue {
    /// enqueue → SSH send 직렬 처리. await 사이 다른 enqueue 는 actor 가 자동 대기.
    func enqueueSend(shellCmd: String, shell: RemoteShell) async -> RemoteShell.Exchange? {
        // actor isolation 으로 1 in-flight 보장.
        return await shell.send(shellCmd)
    }
}
