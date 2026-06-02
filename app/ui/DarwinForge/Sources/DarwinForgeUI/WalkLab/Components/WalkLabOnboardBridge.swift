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
    /// SSH↔LAN parity (2026-06-01): onboard telemetry 업링크 + e-stop 의 lifecycle 을
    /// 소유한다. 종전: `startOnboardTelemetry` 호출부가 없어 poller 가 안 켜지고
    /// `telemetryMode` 가 `.onboard` 로 안 바뀌어 텔레메트리/온보드 e-stop 이 dead 였음.
    @EnvironmentObject private var store: ConnectionStore

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

    /// 스트리밍 송신 마지막 시각 — 연속 입력(머리/스틱) 추종 + walking keepalive 용.
    @State private var lastStreamSentAt: Date? = nil

    /// IMMEDIATE 관찰 그룹 (critical user action). body 체인 분할용 (타입체커 부담↓).
    private var immediateObservers: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // v1.11.24 audit iter2-I — activeRobotPreset 도 같이 관찰 (P1-1 split 이후
            // 실 motor task 가 cycle 종료 / 자동 정지로 nil 이 되는 시점도 trigger).
            .onChange(of: session.current)                  { _, _ in scheduleImmediateSend() }
            .onChange(of: session.activeRobotPreset)        { _, _ in scheduleImmediateSend() }
            .onChange(of: session.walkingEngine) { _, newValue in
                lastAckedLine = nil   // engine 전환 → dedup reset
                if newValue == .robotisOnboard {
                    scheduleHealthCheck()
                }
                syncOnboardLifecycle()   // telemetry poller + mode verify start/stop
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
                syncOnboardLifecycle()
                scheduleImmediateSend()
            }
    }

    var body: some View {
        // **타입체커 분할 (2026-06-02)**: onChange 체인이 길어 단일 `some View` 표현식이
        // 컴파일 시간 한계를 넘겼다. IMMEDIATE 그룹을 `immediateObservers` 로 떼어내
        // 체인을 두 개의 짧은 `some View` 경계로 나눈다 (동작 동일).
        immediateObservers
            // DEBOUNCED: slider drag.
            .onChange(of: session.strideMm)                 { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.sideMm)                   { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.turnDeg)                  { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.customPeriodMs)           { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.footHeightMm)             { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.hipPitchOffsetTrimDeg)    { _, _ in scheduleDebouncedSend() }
            // SSH parity (W4): head pan/tilt 도 onboard 명령에 포함 (12 필드 serializedLine).
            // 머리 각도는 `currentWalkingEngineCommand` 가 session 의 head 속성을 읽어
            // serializedLine 마지막 2 필드로 직렬화 → 본 bridge 의 send 경로가 자동 forward.
            // 머리 joystick 변경 시 즉시 robot 반영 위해 head 속성도 debounce 관찰.
            // 종전: head 변경이 onboard 모드에서 re-send 를 trigger 안 함 → 머리 갱신 지연.
            .onChange(of: session.onboardHeadPanDeg)        { _, _ in scheduleDebouncedSend() }
            .onChange(of: session.onboardHeadTiltDeg)       { _, _ in scheduleDebouncedSend() }
            // 볼 트래킹 (2026-06-02): on/off 토글은 즉시 전송 (slider 아님 → debounce 불필요).
            // serializedLine 13번째 필드로 자동 직렬화 → 로봇 브로커리지가 추적 모드 전환.
            .onChange(of: session.ballTrackingEnabled) { _, _ in handleBallTrackingToggle() }
            .onAppear { syncOnboardLifecycle() }
            .onDisappear { store.stopOnboardTelemetry() }
            .task { await streamLoop() }
    }

    /// 연속 입력 스트리밍 — debounce(입력 정지 시 발사)는 머리 추종이 "한참 뒤"였다.
    /// **헤드 부드러움 fix (2026-06-02)**: 종전 120ms(~8Hz)는 로봇의 cmd 폴링 주기(100ms=10Hz)
    /// 보다 느려, 매 폴마다 신선한 각도가 준비돼 있지 않아 큰 각도 점프(빠릿빠릿)+지연이 났다.
    /// 45ms(~22Hz 시도, 1-in-flight 큐가 RTT/로봇폴 10Hz 로 자연 스로틀)로 낮춰 로봇이 매 폴마다
    /// *항상 최신* 각도를 받게 한다 → 더 잘게 추종(부드러움) + 입력→이동 지연 단축(즉각 반응).
    /// 변경 없을 땐 dedup(lastAckedLine)로 skip, walking 중 1.5s keepalive 만 송출(과송신 X).
    private func streamLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard shouldSend() else { continue }
            let effectivePreset = session.activeRobotPreset ?? session.current
            let walkActive = effectivePreset != .idle || session.pilotIsWalking || session.mobileFreeformActive
            let line = session.currentWalkingEngineCommand(enabled: walkActive).serializedLine
            let now = Date()
            let keepalive = walkActive && (lastStreamSentAt.map { now.timeIntervalSince($0) > 1.5 } ?? true)
            if line == lastAckedLine && !keepalive { continue }
            lastStreamSentAt = now
            await performSend(line: line, isImmediate: false)
        }
    }

    /// onboard 엔진이 활성(`.robotisOnboard`)이고 SSH host 가 설정돼 있으면 텔레메트리
    /// 업링크를 시작하고(robot→Mac IMU/voltage 5Hz → HUD + L0/L3 게이트 복구) walklab
    /// 모드를 검증/자동복구한다. 아니면 정지. **이 함수가 onboard lifecycle 의 단일 소유자.**
    private func syncOnboardLifecycle() {
        let hostSet = !remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if session.walkingEngine == .robotisOnboard && hostSet {
            store.startOnboardTelemetry(remoteShell: remoteShell)
            // walklab 모드 보장 (재부팅/SOCCER 이탈 시 자동복구) — fire-and-forget.
            let verify = RobotSetupCommand.walkLabVerifyMode
            Task { @MainActor in _ = await remoteShell.send(verify) }
        } else {
            store.stopOnboardTelemetry()
        }
    }

    /// **v1.11.16.1**: critical 변경 — 즉시 send (debounce 우회).
    /// **v1.11.16.2**: actor queue 경유 — 1 in-flight 보장.
    private func scheduleImmediateSend() {
        guard shouldSend() else { return }
        debounceTask?.cancel()
        // v1.11.24 audit iter2-I — enabled 는 activeRobotPreset 우선 (실 task 진행 중 여부).
        // sim / no-task 시 fallback 으로 current.
        let effectivePreset = session.activeRobotPreset ?? session.current
        // 콕핏 freeform 조종 시 preset 은 .idle 일 수 있으므로 pilotIsWalking 도 함께 본다.
        let walkActive = effectivePreset != .idle || session.pilotIsWalking || session.mobileFreeformActive
        let cmd = session.currentWalkingEngineCommand(enabled: walkActive)
        let line = cmd.serializedLine
        if line == lastAckedLine { return }
        Task { @MainActor in
            await performSend(line: line, isImmediate: true)
        }
    }

    /// 볼 트래킹 토글 → 즉시 robot 전송. dedup 캐시를 비워 같은 walk 파라미터라도
    /// ball_track 비트 변경이 반드시 송출되게 한다 (보행 중 아니어도 추적 가능).
    private func handleBallTrackingToggle() {
        lastAckedLine = nil
        scheduleImmediateSend()
    }

    /// 150ms debounce — 마지막 변경 후 가만히 있으면 send. drag 중에는 매번 cancel.
    /// **헤드/파라미터 settle fix (2026-06-02)**: 300→150ms — 입력 정지 후 최종값 송출이
    /// 빠르게 안착(felt latency↓). 연속 추종은 streamLoop(45ms)가 담당하므로 이 경로는
    /// 슬라이더/디테일 변경의 coalescing 용. (streamLoop 와 중복돼도 dedup 로 무해.)
    /// **v1.11.16.2**: actor queue 경유 — race 차단.
    private func scheduleDebouncedSend() {
        guard shouldSend() else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            // v1.11.24 audit iter2-I — enabled 는 activeRobotPreset 우선 (실 task 진행 중 여부).
        // sim / no-task 시 fallback 으로 current.
        let effectivePreset = session.activeRobotPreset ?? session.current
        // 콕핏 freeform 조종 시 preset 은 .idle 일 수 있으므로 pilotIsWalking 도 함께 본다.
        let walkActive = effectivePreset != .idle || session.pilotIsWalking || session.mobileFreeformActive
        let cmd = session.currentWalkingEngineCommand(enabled: walkActive)
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
            // **codex HIGH fix (2026-06-02)**: tokens[2] 를 *cmd_id 형태일 때만* cmd_id 로 간주.
            // cmd_id 는 "c{ts}_{uuid}" 라 항상 '_' 포함, 구형 firmware 의 "OK {ts} {line}" 는
            // tokens[2] 가 숫자(enabled 필드)라 '_' 없음 → cmd_id 없음으로 처리(진짜 backward-compat).
            // 종전엔 숫자 필드를 cmd_id 로 오인해 구형 firmware 의 정상 ACK 를 항상 stale 로 폐기했다.
            let rawTok2 = tokens.count >= 3 ? String(tokens[2]) : nil
            let ackCmdId: String? = (rawTok2?.contains("_") == true) ? rawTok2 : nil
            let isStale = (ackCmdId != nil) && (ackCmdId != expectedCmdId) && (ackCmdId != "no_id")
            if isStale {
                // stale ACK — 이전 명령의 응답이 우리 명령에 매치. 실패로 처리.
                consecutiveFailures += 1
                session.onboardConsecutiveFailures = consecutiveFailures
                session.onboardLastError = "stale ACK (expected=\(expectedCmdId), got=\(ackCmdId ?? "nil"))"
                session.setOnboardAckStatus("stale")  // v1.11.24 audit iter4-A
                session.logSafetyEvent(
                    kind: .correctorOff,
                    message: "Onboard stale ACK(\(consecutiveFailures)회) — daemon 처리 지연 또는 race. expected=\(expectedCmdId)"
                )
                // codex MEDIUM fix: stale ACK 도 다른 실패 분기(error/NO_ACK/unexpected)와 동일하게
                // 3회 연속 시 자동 폴백/경고 — 반복 stale 로 조종 불능 상태가 방치되지 않게.
                if consecutiveFailures >= 3 {
                    session.setLastRobotEvent("🛑 ROBOTIS Onboard stale ACK 3회 — daemon/SSH race 점검 필요")
                    Task { @MainActor in await handleAutoFallbackIfEnabled() }
                }
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
            // **codex HIGH fix (2026-06-02)**: 예상치 못한 응답(타임아웃 후 잔여 출력 등)도 실패로
            // 집계 — 종전엔 카운트 안 해 연속실패/자동폴백이 발동 안 됐다(무선 stall 시 무대응).
            consecutiveFailures += 1
            session.onboardConsecutiveFailures = consecutiveFailures
            session.onboardLastError = "예상치 못한 응답: \(trimmed.prefix(40))"
            session.setOnboardAckStatus("unexpected")
            session.logSafetyEvent(
                kind: .correctorOff,
                message: "Onboard 응답 형식 인식 불가(\(consecutiveFailures)회): \(trimmed.prefix(60))"
            )
            if consecutiveFailures >= 3 {
                session.setLastRobotEvent("🛑 ROBOTIS Onboard 응답 이상 3회 — SSH/데몬 점검 필요")
                Task { @MainActor in await handleAutoFallbackIfEnabled() }
            }
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
        // 리뷰 L3 fix: 하드코딩 7-필드 대신 정식 12-필드 serializedLine (스키마 변경 시 자동 일치).
        let stopLine = WalkingEngineCommand.stop.serializedLine
        let stopCmdId = RobotSetupCommand.generateCmdId()
        let stopShellCmd = RobotSetupCommand.walkLabRobotisSendCommand(
            line: stopLine, cmdId: stopCmdId
        )
        let stopExchange = await sendQueue.enqueueSend(shellCmd: stopShellCmd, shell: remoteShell)
        // **codex HIGH fix (2026-06-02)**: stop 확인은 cmd_id 까지 검증 — 종전엔 아무 "OK "나
        // 수락해, 직전 명령의 stale OK 가 정지를 거짓 확인하고 Mac sparse 로 전환(실제 로봇은
        // 정지 안 된 채)할 수 있었다. ACK 형식 "OK {ts} {cmd_id} {line}" 의 cmd_id 가 이번 stop
        // 의 것과 일치(또는 backward-compat: cmd_id 없는 구형 firmware)할 때만 정지 확정.
        let stopOK: Bool = {
            guard stopExchange?.error == nil else { return false }
            let trimmed = (stopExchange?.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("OK ") else { return false }
            let tokens = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            // codex HIGH fix: cmd_id 형태('_' 포함)일 때만 cmd_id 로 간주 — 구형 firmware 의
            // 숫자 필드를 cmd_id 로 오인하지 않게(legacy 정상 stop ACK 를 거짓 거부 방지).
            let rawId = tokens.count >= 3 ? String(tokens[2]) : nil
            let ackId: String? = (rawId?.contains("_") == true) ? rawId : nil
            // 구형 firmware(cmd_id 미발급) 는 nil/"no_id" → 강제 매치 안 함(backward-compat).
            return ackId == stopCmdId || ackId == nil || ackId == "no_id"
        }()
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
    ///
    /// - Parameter timeoutSeconds: 기본 6s. 브리지 명령(머리/스틱/정지/헬스체크)은 모두 작은
    ///   파일-write 라 빠르게 끝나야 한다. WiFi stall 시 6s + ServerAlive(~4s) 로 빠르게 실패 →
    ///   직렬 큐가 30s 막혀 정지/다음 명령이 지연되는 것을 방지(무선 제어 복구성↑).
    func enqueueSend(shellCmd: String,
                     shell: RemoteShell,
                     timeoutSeconds: TimeInterval = 6) async -> RemoteShell.Exchange? {
        // actor isolation 으로 1 in-flight 보장.
        return await shell.send(shellCmd, timeoutSeconds: timeoutSeconds)
    }
}
