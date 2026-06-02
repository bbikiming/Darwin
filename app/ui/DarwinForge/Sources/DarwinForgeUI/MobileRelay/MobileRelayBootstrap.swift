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
/// - **안전 whitelist**: `slowForward`, `turnLeft`, `turnRight`, `stop`, `freeform`
///   만 허용. `freeform` 은 joystick amplitude clamp 후 전용 연속 루프에 반영한다.
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
                walkSession?.attach(store: store)
                relayChannel.attach(store: store, gate: relayGate)
                rebindHooks()
                hooksWired = true
                // 기본 상태는 **off**: 앱 실행만으로는 listen 을 시작하지 않는다.
                // 종전엔 hooks wiring 직후 자동으로 `controller.start()` 를 호출해
                // 사용자 의사와 무관하게 연결 대기(advertising) 상태로 진입했다.
                // 이제는 live hooks 만 미리 wiring 해 두고, 실제 listen 시작은
                // 사용자 입력(첫 실행 팝오버 "지금 시작" 버튼 또는 toolbar chip 토글)
                // 이 있을 때만 수행한다. → relay 는 명시적 opt-in.
            }
    }

    /// Replace the controller's placeholder port with one bound to the live
    /// store + channel. Closures capture the @MainActor types weakly so the
    /// bootstrap view can be torn down cleanly.
    private func rebindHooks() {
        let liveHooks = ConnectionStoreSafetyPort.Hooks(
            armAsync: { [weak relayChannel, weak store] in
                // V297-6 (PM Story S3.3): emergencyStopActive=true 이면 iOS "복구" 버튼
                // 경로. pilot.arm 을 새 명령 추가 없이 재사용 — emergencyStopActive 플래그로
                // ARM vs recover 를 분기한다.
                // cradleConfirmed=true: iOS 앱이 보낸 pilot.arm 은 ConnectionStoreSafetyPort
                // 에서 이미 검증됐으므로 cradle 확인 완료로 간주.
                if let store, store.emergencyStopActive {
                    await store.recoverFromEStop(cradleConfirmed: true)
                    // 복구 성공 여부: recoverFromEStop 가 정상 완료되면
                    // emergencyStopActive 가 false 로 reset된다.
                    return store.emergencyStopActive == false
                }
                // 일반 ARM 경로.
                guard let ch = relayChannel else { return false }
                await ch.arm()
                // V297-4: readyDegraded 도 성공으로 인정 — 상체 일부 토크 실패는
                // 보행 안전에는 영향 없음. simReady 는 sim 모드라 ARM 성공으로 간주.
                return ch.armStage == .ready
                    || ch.armStage == .readyDegraded
                    || ch.armStage == .simReady
            },
            // V297-4: ARM 진행 중 polling — 프로토콜 §8.4 의 engagingTorque 단계 누락 해소.
            // TeleopChannel.armStage 의 실제 transition 을 프로토콜 stage 이름으로 변환.
            currentArmStageName: { [weak relayChannel] in
                guard let ch = relayChannel else { return nil }
                switch ch.armStage {
                case .enablingPower:     return "enablingPower"
                case .rampingTorque:     return "engagingTorque"
                case .reachingWalkready: return "walkReadyPose"
                case .ready, .readyDegraded, .simReady: return "armed"
                case .idle, .disarming:  return nil
                }
            },
            disarmSync: { [weak relayChannel] in
                relayChannel?.disarm()
            },
            emergencyStopSync: { [weak store] in
                // V297-5 CRITICAL-5: 검증된 결과 반환.
                // bus nil: ConnectionStore.emergencyStop 가 silent return — 검증 실패.
                // bus 있음: emergencyStopActive flag 가 set 됐는지 확인.
                guard let store else { return false }
                store.emergencyStop()
                return store.emergencyStopActive
            },
            sendMotion: { [weak relayChannel] slot, confirmRisk in
                guard let ch = relayChannel else { return false }
                return await ch.sendMotion(slot: slot, confirmRisk: confirmRisk)
            },
            sendWalk: { [weak store, weak walkSession] payload in
                // 안전 whitelist — MVP 허용 preset 만 통과.
                // jog 등 고위험 preset 은 즉시 reject (command.rejected 전달).
                let safelist: Set<WalkPreset> = [.slowForward, .turnLeft, .turnRight, .stop, .freeform]
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
                // V297-4: speedScale safe clamp + telemetry log.
                // V297-8 (P3-Mac): clampedScale 을 session.start 에 실제 전달 — 이제 적용됨.
                let _scale = (payload.speedScale ?? 1.0)
                let clampedScale = min(max(0.5, _scale), 1.5)
                // stop preset → 진행 중 세션 정지.
                if payload.preset == .stop {
                    if session.isWalkActive { session.stop() }
                    return true
                }
                if payload.preset == .freeform {
                    if !payload.enabled {
                        if session.isWalkActive { session.stop() }
                        return true
                    }
                    let preBefore = session.lastPreflightFailure
                    let tuning = MobileFreeformWalkMapper.tuning(from: payload,
                                                                 speedScale: clampedScale)
                    let started = session.startOrUpdateMobileFreeform(tuning: tuning)
                    let preAfter = session.lastPreflightFailure
                    if let failure = preAfter, preBefore?.diagnosticCode != failure.diagnosticCode {
                        _ = failure.diagnosticCode
                        throw RelayServerError.rejected("preflightFailed")
                    }
                    return started && session.isWalkActive
                }
                // WalkPreset (iOS) → WalkLabPreset (Mac) 매핑.
                let macPreset: WalkLabPreset = WalkPresetMapper.map(payload.preset)
                // WalkLabSession.start 가 quickPreflight (cradle / emergency / IMU)
                // 를 내부에서 수행. 실패 시 lastPreflightFailure 가 set 되고 return.
                let preBefore = session.lastPreflightFailure
                // V297-8 (P3-Mac): speedScale 실 적용 — WalkLabSession.start 에 전달.
                session.start(macPreset, speedScale: clampedScale)
                // preflight 실패 여부: start() 는 동기 void — 실패 시 lastPreflightFailure 갱신.
                //
                // V297-7 P3-i1 (검증 fix): reason 은 enum-friendly raw string ("preflightFailed")
                // 고정. diagnosticCode 는 message 필드에. 종전엔 reason 에 "preflightFailed:CODE"
                // 동적 suffix → iOS RejectionReason enum 매칭 실패 → .unknown fallback → 사용자
                // 가 정확한 원인 못 봄. RelayServerError 가 reason 만 capture 하므로 message
                // 전달은 sendCommandRejected message 통로 — 여기선 reason 단일화만.
                let preAfter = session.lastPreflightFailure
                if let failure = preAfter, preBefore?.diagnosticCode != failure.diagnosticCode {
                    _ = failure.diagnosticCode  // future: pass via message channel
                    throw RelayServerError.rejected("preflightFailed")
                }
                return session.isWalkActive
            },
            sendStop: { [weak walkSession] _ in
                if let session = walkSession, session.isWalkActive {
                    session.stop()
                }
                return true
            },
            setBallTracking: { [weak walkSession] enabled in
                // 볼 트래킹 (2026-06-02): session flag set → OnboardBridge onChange 가
                // serializedLine 13번째 필드로 robot 에 전달 → 브로커리지 자체 헤드 추적.
                guard let session = walkSession else { return false }
                session.ballTrackingEnabled = enabled
                return true
            },
            snapshot: { [weak store, weak relayChannel] in
                let armed = relayChannel?.armStage == .ready
                    || relayChannel?.armStage == .readyDegraded
                let busConnected = store?.bus != nil
                let dxlPower = store?.isDxlPowerOn ?? false
                let battery = store?.lastTelemetry?.board?.voltageVolts
                let temp = store?.lastTelemetry?.avgTemperature
                // V297-4: 실시간 데이터 plumbing — 종전 거짓 4개 필드 제거.
                //
                // endpoint: store.activeEndpoint 의 displayName (USB path 또는 host:port).
                // latencyMs: ConnectionStore.health.lastRoundTripMs (board snapshot RTT 측정).
                // lastAckAgeMs: 마지막 성공 read 시각으로부터 경과 (staleness 신호).
                // busBusy: ROBOTIS demo USB 점유 감지 회로 미구현 — 후속 PR. 현재 false.
                // estopActive: 새 emergencyStopActive 플래그 직접 사용 (휴리스틱 폐기).
                let endpointString: String? = store?.activeEndpoint?.displayName
                let liveLatencyMs: Int = {
                    if let rtt = store?.lastRoundTripMs { return Int(rtt.rounded()) }
                    return 0
                }()
                let lastAckAge: Int? = {
                    guard let at = store?.lastSuccessAt else { return nil }
                    return Int(Date().timeIntervalSince(at) * 1000)
                }()
                let estopFlag: Bool = store?.emergencyStopActive ?? false
                // V297-8 (P3-Mac): busBusy — ConnectionStore.isDemoBusyDetected 휴리스틱 사용.
                // 종전 false 하드코딩 대신 실제 감지 값 전달. 정확한 demo 감지는 후속 PR.
                let busBusyFlag: Bool = store?.isDemoBusyDetected ?? false
                return MobileRelayTelemetryFactory.make(
                    macConnected: true,
                    robotConnected: busConnected,
                    armed: armed,
                    dxlPower: dxlPower,
                    busBusy: busBusyFlag,
                    endpoint: endpointString,
                    batteryV: battery,
                    maxTempC: temp,
                    latencyMs: liveLatencyMs,
                    lastAckAgeMs: lastAckAge,
                    estopActive: estopFlag)
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

public enum MobileFreeformWalkMapper {
    public static func tuning(from payload: WalkPayload,
                              speedScale: Double) -> WalkMotionLibrary.AdvancedTuning {
        let scale = min(max(0.5, speedScale), 1.5)
        return WalkMotionLibrary.mobileFreeformClamp(.init(
            strideMm: payload.xMm * scale,
            sideMm: payload.yMm * scale,
            turnDeg: payload.aDeg * scale,
            periodMs: Double(payload.periodMs),
            footHeightMm: payload.footMm,
            balanceGain: 1.0,
            hipPitchOffsetDeg: payload.hipPitchDeg
        ))
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
/// - `freeform`  → `sendWalk` 의 mobile freeform 전용 분기에서 처리.
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
