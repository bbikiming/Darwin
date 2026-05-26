import SwiftUI

/// Mounts the MobileRelayController next to the existing app state.
///
/// Wire-up choice: this view owns its **own** `TeleopChannel` + `PilotSafetyGate`
/// pair, attached to the live `ConnectionStore` injected by the host. That
/// keeps the relay from racing with `RemotePilotView`'s own channel for the
/// torque-write path; the shared `ConnectionStore` is still the single source
/// of truth for bus / telemetry / dxlPower.
///
/// # 비유: 리모컨이 진짜 TV 채널 바꾸도록 회로 연결
///
/// 종전 `sendWalk` 는 리모컨 버튼을 눌러도 TV 내부 칩이 없는 껍데기 회로였다.
/// V291-4: `WalkLabSession.start(preset:)` 를 직접 호출 — 이제 리모컨이 실제 채널을 바꾼다.
///
/// # 안전 설계
///
/// - **dxlPower + preflight**: `WalkLabSession.start` 내부의 `quickPreflight` 가
///   emergency / cradle / IMU / thermal 체크를 수행. 실패 시 `lastPreflightFailure` 설정.
/// - **MVP 안전 whitelist**: `slowForward`, `turnLeft`, `turnRight`, `stop` 만 허용.
///   `freeform` 및 미래 고위험 preset 은 reject `highRiskNotAllowed`.
/// - **heartbeat watchdog**: 기존 `sendStop` hook 이 session.stop() 을 호출 — 끊김 시 자동 정지.
///
/// **V291-1**: `controller` 를 외부에서 주입받아 RootView 가 toolbar chip 과 공유한다.
/// 호출자는 `MobileRelayController.makePlaceholder()` 로 초기 포트를 생성한 뒤
/// `@StateObject` 로 소유하고 이 init 에 전달한다.
@MainActor
public struct MobileRelayBootstrap: View {

    @ObservedObject var store: ConnectionStore
    @StateObject private var relayChannel = TeleopChannel()
    @StateObject private var relayGate = PilotSafetyGate()
    /// 외부에서 주입된 controller — RootView @StateObject 소유, chip 과 공유.
    @ObservedObject var controller: MobileRelayController
    /// WalkLabSession — weak ref. nil 이면 walk 명령 reject (세션 미연결).
    weak var walkSession: WalkLabSession?

    @State private var hooksWired = false

    public init(store: ConnectionStore,
                controller: MobileRelayController,
                walkSession: WalkLabSession? = nil) {
        self.store = store
        self.controller = controller
        self.walkSession = walkSession
    }

    public var body: some View {
        MobileRelayPanel(controller: controller)
            .task {
                guard !hooksWired else { return }
                relayChannel.attach(store: store, gate: relayGate)
                rebindHooks()
                hooksWired = true
                // iOS 조종기 연결은 Mac Relay가 먼저 대기 중이어야 한다.
                // 앱 실행 후 사용자가 별도 토글을 찾지 않아도 iPhone의 Bonjour/QR 연결이
                // 바로 성공하도록, live hooks wiring이 끝난 뒤 자동으로 listen을 시작한다.
                if !controller.isRunning {
                    await controller.start()
                }
            }
    }

    /// Replace the controller's placeholder port with one bound to the live
    /// store + channel. Closures capture the @MainActor types weakly so the
    /// bootstrap view can be torn down cleanly.
    private func rebindHooks() {
        let liveHooks = ConnectionStoreSafetyPort.Hooks(
            armAsync: { [weak relayChannel] in
                guard let ch = relayChannel else { return false }
                await ch.arm()
                return ch.armStage == .ready
            },
            disarmSync: { [weak relayChannel] in
                relayChannel?.disarm()
            },
            emergencyStopSync: { [weak store] in
                store?.emergencyStop()
            },
            sendMotion: { [weak relayChannel] slot, confirmRisk in
                guard let ch = relayChannel else { return false }
                return await ch.sendMotion(slot: slot, confirmRisk: confirmRisk)
            },
            sendWalk: { [weak store, weak walkSession] payload in
                // 안전 whitelist — MVP 허용 preset 만 통과.
                // jog / freeform 등 고위험 preset 은 즉시 reject (command.rejected 전달).
                let safelist: Set<WalkPreset> = [.slowForward, .turnLeft, .turnRight, .stop]
                guard safelist.contains(payload.preset) else {
                    throw RelayServerError.rejected("highRiskNotAllowed")
                }
                // dxlPower 사전 점검 — 토크 OFF 상태에서 걷기 명령 차단.
                guard store?.isDxlPowerOn == true else {
                    throw RelayServerError.rejected("dxlPowerOff")
                }
                guard let session = walkSession else {
                    throw RelayServerError.rejected("walkSessionUnavailable")
                }
                // stop preset → 진행 중 세션 정지.
                if payload.preset == .stop {
                    if session.isWalkActive { session.stop() }
                    return true
                }
                // WalkPreset (iOS) → WalkLabPreset (Mac) 매핑.
                let macPreset: WalkLabPreset = WalkPresetMapper.map(payload.preset)
                // WalkLabSession.start 가 quickPreflight (cradle / emergency / IMU)
                // 를 내부에서 수행. 실패 시 lastPreflightFailure 가 set 되고 return.
                let preBefore = session.lastPreflightFailure
                session.start(macPreset)
                // preflight 실패 여부: start() 는 동기 void — 실패 시 lastPreflightFailure 갱신.
                let preAfter = session.lastPreflightFailure
                if let failure = preAfter, preBefore?.diagnosticCode != failure.diagnosticCode {
                    throw RelayServerError.rejected("preflightFailed:\(failure.diagnosticCode)")
                }
                return session.isWalkActive
            },
            sendStop: { [weak walkSession] _ in
                if let session = walkSession, session.isWalkActive {
                    session.stop()
                }
                return true
            },
            snapshot: { [weak store, weak relayChannel] in
                let armed = relayChannel?.armStage == .ready
                let busConnected = store?.bus != nil
                let dxlPower = store?.isDxlPowerOn ?? false
                let battery = store?.lastTelemetry?.board?.voltageVolts
                let temp = store?.lastTelemetry?.avgTemperature
                return MobileRelayTelemetryFactory.make(
                    macConnected: true,
                    robotConnected: busConnected,
                    armed: armed,
                    dxlPower: dxlPower,
                    busBusy: false,
                    endpoint: nil,
                    batteryV: battery,
                    maxTempC: temp,
                    latencyMs: 30,
                    lastAckAgeMs: nil,
                    estopActive: !dxlPower && armed == false && busConnected)
            })
        let livePort = ConnectionStoreSafetyPort(hooks: liveHooks)
        controller.swapPort(livePort)
        // V291-10: Mac-side battery voltage 재검증 클로저 주입.
        // ConnectionStore.lastTelemetry 는 @MainActor 격리이므로 MainActor.run 으로 hop.
        //
        // CI fix (PR #42, 2026-05-25): `ConnectionStore` 는 `@MainActor`
        // isolated class — `@Sendable` 클로저 capture 시 Sendable race 로
        // reject. `nonisolated(unsafe)` 로 capture 한정자를 풀어 회피한다.
        // 안전 근거: 실제 접근은 항상 `await MainActor.run` 내부에서만 발생.
        nonisolated(unsafe) let storeRef = store
        controller.swapBatteryVoltage {
            await MainActor.run { storeRef.lastTelemetry?.board?.voltageVolts }
        }
    }
}

// MARK: - WalkPreset (iOS) → WalkLabPreset (Mac) 매핑

/// iOS 의 `WalkPreset` (5 case) 를 Mac 의 `WalkLabPreset` (8 case) 로 변환.
///
/// # 매핑 근거
/// - `slowForward` → `slowWalk`: 가장 안전한 전진 preset. MVP 기본 이동.
/// - `turnLeft`  → `turnLeft`:  동일 이름 1:1 대응.
/// - `turnRight` → `turnRight`: 동일 이름 1:1 대응.
/// - `stop`      → `idle`:      stop 명령은 caller 가 `session.stop()` 으로 처리
///                              (매핑 table 에 포함되나 실제 사용 경로는 sendWalk 의 stop 분기).
/// - `freeform`  → whitelist 에서 차단 (highRiskNotAllowed) — 매핑 table 미포함.
public enum WalkPresetMapper {
    /// iOS `WalkPreset` → Mac `WalkLabPreset` 변환 dictionary.
    static let table: [WalkPreset: WalkLabPreset] = [
        .slowForward: .slowWalk,
        .turnLeft:    .turnLeft,
        .turnRight:   .turnRight,
        .stop:        .idle,
    ]

    /// 매핑 반환. `freeform` 등 table 미포함 preset 은 `.idle` fallback (안전).
    public static func map(_ preset: WalkPreset) -> WalkLabPreset {
        table[preset] ?? .idle
    }
}
