import Combine
import ForgeCore
import Observation
import SwiftUI

/// Walk Lab 의 observable model — 현재 프리셋 / 고급 슬라이더 / 시뮬 결과 / 안전 상태.
/// **v1.14.9 (2026-05-21) Fix #7 — @Observable 마이그레이션**:
/// 종전: ObservableObject + 76 @Published. tick 마다 ~12-15 @Published mutate →
///       모든 @ObservedObject/@EnvironmentObject subscriber 의 body 재평가 (blanket
///       invalidation). 변화와 무관한 view 도 dirty mark.
/// 신규: @Observable 매크로 (Swift 5.9+, macOS 14+) — property-level tracking.
///       View 가 실제로 read 한 property 만 dependency 로 등록 → 무관 property 변화 시
///       body 재평가 skip. 73 @Published cascade 의 근본 원인 해소.
/// View 측 변경:
///   - @EnvironmentObject var session: WalkLabSession → @Environment(WalkLabSession.self) var session
///   - @ObservedObject var session: WalkLabSession → var session: WalkLabSession
///   - @StateObject var session = WalkLabSession() → @State var session = WalkLabSession()
///   - $session.foo (Binding) → @Bindable var session = session; $session.foo
///   - .environmentObject(session) → .environment(session)
///
/// 시뮬 vs 실 송출 (Sprint 16+):
///   - **프리셋 보행 cycle 실 송출 활성**: `WalkMotionLibrary.page(for:tuning:)` 로 합성한
///     step 시퀀스를 `runWalkCycle` Task 가 `Bus.setPosition` 으로 직접 송출.
///     bus 연결 + cradleConfirmed + (highRisk → riskAck) 조건 모두 만족 시.
///   - 고급 슬라이더 (보폭/측면/회전/주기/발 들기/균형) → 시뮬 엔진과 실 송출 page 모두에 반영.
///     ROBOTIS walking module 기반 keyframe을 재합성하고, 진행 중이면 짧게 debounce 후 재시작.
///   - 시뮬 50ms tick (foot trail / IMU / 온도) 는 기존대로 simTimer 가 갱신.
///   - `attach(store:)` 호출 전이면 송출 skip (테스트 / preview / 연결 전).
///   - emergencyStop / 균형 손실 / 온도 임계 시 walkCycleTask 즉시 cancel + walkReady 복귀.
@MainActor
@Observable
public final class WalkLabSession {
    // MARK: - 사용자 입력
    public var current: WalkLabPreset = .idle
    /// v1.11.25 audit log-F — silent toggle 차단. didSet 으로 SE/Harness 발화.
    public var cradleConfirmed: Bool = false {
        didSet {
            guard cradleConfirmed != oldValue else { return }
            logSafetyEvent(
                kind: .stateChange,
                message: "정비 스탠드 거치 토글: \(oldValue ? "ON→OFF" : "OFF→ON")"
            )
            Harness.shared.record(
                .walkLabConfigChange, level: .info, actor: .user,
                data: ["field": AnyCodable("cradleConfirmed"),
                       "new_value": AnyCodable(cradleConfirmed)]
            )
        }
    }
    /// v1.11.25 audit log-F + audit-I — advanced 토글 silent 차단 + ON 시 현재 preset
    /// 기본값 자동 load (사용자 혼란 "왜 안 움직이지" 차단).
    public var advanced: Bool = false {
        didSet {
            guard advanced != oldValue else { return }
            logSafetyEvent(
                kind: .stateChange,
                message: "고급 모드 토글: \(advanced ? "OFF→ON" : "ON→OFF")"
            )
            Harness.shared.record(
                .walkLabConfigChange, level: .info, actor: .user,
                data: ["field": AnyCodable("advanced"),
                       "new_value": AnyCodable(advanced)]
            )
            // audit-I: advanced=true 후 slider 가 0 이면 idle 과 동일 → 사용자 혼란.
            // current preset (idle 제외) 의 default tuning 자동 load.
            if advanced && current != .idle {
                loadPresetDefaultsToSliders(current)
            }
        }
    }
    /// 보폭 (앞, mm/cycle). 0..50. WalkEngine 의 x (m) 와 매핑: x_m = strideMm / 1000.
    public var strideMm: Double = 0
    /// 측면 보폭 (mm/cycle). -25..25. y_m = sideMm / 1000.
    public var sideMm: Double = 0
    /// 회전 (°/cycle). -20..20. a_rad = turnDeg * π/180.
    public var turnDeg: Double = 0
    public var customPeriodMs: Double = 600
    /// 발 들기 높이 (mm). **사이클 124 audit #1/#14 fix**: 종전 주석 "엔진 미반영
    /// (BLOCKER C3 까지)" 는 stale 정보 (사용자 비공개 issue tag).
    /// 현재 동작: WalkLabSession 의 Mac sparse engine 은 본 값 사용 (3D 시각화 반영).
    /// Onboard mode 의 실 robot daemon 은 본 필드 미전송 (별도 PRD).
    /// ApplyScope: 시뮬 + 시각화 ✓ / Onboard 송출 ✗.
    public var footHeightMm: Double = 40
    /// 균형 게인 (NimbRo lean_fb_gain 등가). **사이클 124 audit #2 fix**:
    /// Mac sparse engine 사용 ✓ / Onboard send 미반영 — ApplyScope.simOnly 명시.
    /// UI 가 ApplyScope badge 로 사용자 동작 범위 시각화 필요.
    public var balanceGain: Double = 1.0
    /// 사용자 명시적 안전 한도 해제. Smart-clamp 무시, 단 critical 점수는 여전히 차단.
    /// v1.11.25 audit log-F — 안전 우회는 영구 기록 필수 (warn level + SE).
    public var forceOverrideSafety: Bool = false {
        didSet {
            guard forceOverrideSafety != oldValue else { return }
            logSafetyEvent(
                kind: forceOverrideSafety ? .preflightFailure : .stateChange,
                message: forceOverrideSafety
                    ? "⚠️ 안전 한도 해제 ON — Smart-clamp 무시 (사용자 명시)"
                    : "안전 한도 해제 OFF — Smart-clamp 재활성"
            )
            Harness.shared.record(
                .walkLabConfigChange, level: forceOverrideSafety ? .warn : .info,
                actor: .user,
                data: ["field": AnyCodable("forceOverrideSafety"),
                       "new_value": AnyCodable(forceOverrideSafety)]
            )
        }
    }
    public var riskAcknowledged: Bool = false

    // MARK: - 레거시 호환 (기존 코드 경로 보존)
    /// `customX`/`customY`/`customA` 는 strideMm/sideMm/turnDeg 의 m 단위 view.
    /// 외부 코드(Walk.swift FFI 등) 는 m 단위를 기대하므로 변환.
    public var customX: Double {
        get { strideMm / 1000.0 }
        set { strideMm = newValue * 1000.0 }
    }
    public var customY: Double {
        get { sideMm / 1000.0 }
        set { sideMm = newValue * 1000.0 }
    }
    public var customA: Double {
        get { turnDeg * .pi / 180.0 }
        set { turnDeg = newValue * 180.0 / .pi }
    }

    // MARK: - 시뮬 / 실시간 상태
    public var elapsedMs: UInt32 = 0
    public var phaseLabel: String = "PHASE0"
    public var leftFoot: SIMD3<Double> = .zero
    public var rightFoot: SIMD3<Double> = .zero
    public var footTrail: [FootTrailPoint] = []

    // MARK: - v1.15.0 (2026-05-21) Phase 1 — Trial 통합 hook
    //
    // 신규 책임 (라벨 sheet 트리거 + start 시점 capture) 2개 stored property 만 추가.
    // 나머지 로직은 `WalkLabSession+Trials.swift` extension — god object 확장 금지 원칙.

    /// trial 종료 시 라벨링 sheet 표시 트리거. RootView/WalkLabView 가 `.sheet(item:)` 으로 listen.
    /// `nil` = sheet 닫힘 (또는 trial 없음).
    public var pendingLabelTrial: WalkTrial?

    /// trial start 시점 ephemeral capture. finalize 시 outcome 계산에 사용.
    /// internal 가시성 — same module extension 에서만 접근.
    var trialStartCapture: TrialStartCapture?

    /// **v1.15.5 (2026-05-21) — Phase 1.5**: ApplyScope warning 영구 채널.
    /// 종전 `lastRobotEvent` 가 18+ callers 가 overwrite 하는 single string 이라 badge
    /// message 가 즉시 사라짐 (critic MAJOR finding). 별도 property 로 scope 경고 (예:
    /// "balanceGain 은 Onboard 모드에서 송신 안 됨") 영구 표시 — 3D 뷰 하단 또는 sidebar.
    /// nil = 경고 없음. 사용자가 dismiss 시 nil 로 reset.
    public var lastScopeWarning: String?

    /// **v1.20.1 (사이클 7)** — Pilot bridge weak ref.
    /// finalize 시 bridge?.snapshotAndReset() → trial.config.pilotInputs 자동 첨부.
    /// nil = pilot 미연결 (UI preset 만 사용한 trial).
    public weak var pilotBridge: WalkLabRCBridge?

    /// **v1.14.8.1 (2026-05-21) perf — perf-engineer HIGH fix**: footTrail.lefts 캐시.
    /// 종전 WalkLabView 가 body 마다 `session.footTrail.map { $0.left }` → 200-element
    /// 새 SIMD3 배열 alloc + RobotScene3D struct 가 매번 다른 배열 → updateNSView
    /// 강제 호출. Fix #4 의 SceneKit fps 30 절감 일부 무효화.
    /// 신규: tick() 에서 footTrail 과 parallel update → view 는 캐시 read.
    public private(set) var footTrailLefts: [SIMD3<Double>] = []
    public var imuRollDeg: Double = 0
    public var imuPitchDeg: Double = 0
    /// **Stage 1 (v1.1 fall prevention)**: IMU 출처 표시 — UI 가 sim/real/stale 구분.
    /// **사이클 97 (Phase 3)**: setter `private(set)` → `internal(set)` 격상 —
    /// `WalkLabSession+SensorUpdates` extension method 가 write 필요. external API 는 read-only.
    public internal(set) var imuSource: ImuSource = .sim

    /// **v1.11.19**: display-only roll (NaN/Inf guard + ±50° clamp). UI 전용.
    public var displayImuRollDeg: Double {
        ImuAttitudeDisplayMapping.sanitize(imuRollDeg)
    }
    /// **v1.11.19**: display-only pitch (convention 정규화 + NaN/Inf guard + ±50° clamp). UI 전용.
    public var displayImuPitchDeg: Double {
        ImuAttitudeDisplayMapping.map(
            rawRoll: imuRollDeg,
            rawPitch: imuPitchDeg,
            convention: balanceExperimentConfig.pitchInputConvention
        ).pitch
    }
    /// **사이클 97 (Phase 3)**: setter `private(set)` → `internal(set)` 격상 —
    /// `WalkLabSession+SensorUpdates` extension method 가 write 필요. external API 는 read-only.
    public internal(set) var maxMotorTemp: Double = 35.0
    /// **2026-05-16**: 모터 온도 출처 — sim/real/stale. 이전 버그: 실 robot 연결 시에도
    /// `updateSimThermal()` 만 호출 → dashboard 가 항상 가짜 온도 표시.
    /// 정정: `updateMotorTempFromRealOrSim()` 가 `lastTelemetry?.joints` 의
    /// `presentTemperature` 중 max 사용 (실), 미연결 시 sim model fallback.
    /// **사이클 97 (Phase 3)**: setter `private(set)` → `internal(set)` 격상 —
    /// `WalkLabSession+SensorUpdates` extension method 가 write 필요. external API 는 read-only.
    public internal(set) var motorTempSource: MotorTempSource = .sim
    public var balanceLost: Bool = false
    public var thermalAlarm: Bool = false
    /// **v1.11.22.1 (Codex HIGH-1 fix)** — emergencyStop 진행 중/완료 표시.
    /// runWalkCycle/runContinuousWalk 의 exit phase (walkReady 복귀 setPosition) 가
    /// 토크 OFF 이후 호출되는 race 차단용. emergency 시 true → exit 자체 skip.
    /// start/reset 시 false 리셋.
    public private(set) var emergencyStopActive: Bool = false
    /// **v1.21.2 사이클 67 (코덱스 MEDIUM-3 fix)** — 마지막 emergency trigger 보존.
    /// `emergencyStop(trigger:)` 시 capture, `start(_:)` root guard 가 preflight failure
    /// payload 로 사용 → 사용자에게 "어떤 trigger 가 emergency 유발" 명시 노출.
    /// `exitEmergencyMode()` 시 nil reset (recovery 완료 = 과거 trigger 무관).
    private var _lastEmergencyTrigger: EmergencyTrigger?

    /// **사이클 67** — 외부 read-only accessor. WalkTrialAutoGenerator 등 root guard 우회
    /// path 가 동일 trigger payload 생성에 사용. nil 이면 아직 emergency 미발생 또는
    /// recovery 완료.
    public var lastEmergencyTrigger: EmergencyTrigger? { _lastEmergencyTrigger }

    // 2026-05-17 T3.1 partial split: MotorTempSource / ImuSource enum 정의는
    // WalkLabSession+Types.swift 로 이동. type identity 그대로 (extension nested).

    // MARK: - Stage 2 (v1.1 fall prevention): 다단계 임계

    /// 현재 IMU 기반 안전 상태. tick() 마다 갱신.
    public private(set) var balanceState: BalanceState = .normal
    /// 자동 fall prevention 토글. false 면 emergency (50°) 만 작동. default true.
    public var autoFallPrevention: Bool = true

    // MARK: - Stage 3 (v1.1 fall prevention): 예측 fall detection

    /// 최근 IMU sample ring buffer (최대 1초 / 5 sample).
    /// **사이클 107 (Phase 7)**: `private` → `internal` — `WalkLabSession+FallPrevention`
    /// 의 `updateFallPrediction()` 가 read/write.
    internal var imuBuffer: [FallPredictor.Sample] = []
    /// 마지막 buffer push 시각 — 5Hz polling 동기화.
    /// **사이클 107 (Phase 7)**: `private` → `internal` — extension write 허용.
    internal var lastBufferPushAt: Date?

    /// 예측 결과 — UI 게이지·countdown 용.
    /// **사이클 107 (Phase 7)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var fallPrediction: FallPredictor.Prediction = .zero

    // MARK: - Stage 4 (v1.1 fall prevention): 실 balance feedback

    /// Walking.cpp::sensoryFeedback 패턴 — IMU error → 4 관절 그룹 delta.
    /// `enableBalanceCorrection = true` 시 보행 cycle pose 에 적용.
    ///
    /// **v1.7 (2026-05-17) 변경 — default ON**: 사용자 보고 "목각인형처럼 뻣뻣". cm.rs/lib.rs
    /// 의 IMU u16 + 512 center + axis 정정 후 active balance 안전하게 적용 가능. ROBOTIS-OP
    /// Walking.cpp 공식 알고리즘 (BALANCE_HIP_ROLL_GAIN=0.5 등) 이 자동 작동.
    ///
    /// **Phase D 정정 (Agent 2 B-3)**: didSet 으로 toggle OFF → ON 재전환 시 ramp
    /// 재시작 보장. 이전엔 OFF 시 `correctionEnabledAt` 잔존 → 다음 ON 즉시 100%
    /// 적용 (ramp 우회).
    ///
    /// **v1.11.4 (2026-05-18) — 안전 default OFF**: 2026-05-18 실 robot 데이터에서
    /// (1) raw gait 자체가 mean pitch -13° 앞기울 bias 보임, (2) P-control 적용 시에도
    /// pitch -25°~+18° 흔들림. corrector 보정이 안정 기여하는지 보다 raw gait 진단이
    /// 먼저 필요. default OFF → 사용자가 명시 ON 후 검증.
    ///
    /// **v1.11.8 (2026-05-18) — relationship with algorithmMode.off**:
    /// 두 토글은 의도가 다르지만 결과적으로 같은 identity 출력 (Codex/Agent 지적).
    /// - `enableBalanceCorrection` (이것): v1.7 legacy **master switch** — 보정 전체 활성/비활성
    /// - `algorithmMode == .off`: v1.11 axis **세부 mode** — algorithm 자체를 .off 선택
    /// applyBalanceCorrectionIfEnabled 의 guard 순서: algorithmMode .off → enableBalanceCorrection
    /// → 둘 다 identity 반환. **master 가 OFF 면 mode 무관하게 비활성**. UI 가 두 토글
    /// 모두 노출 — 사용자는 master (이 토글) 만 사용 권장. expert disclosure 의 algorithmMode
    /// 는 master ON 상태에서 algorithm 선택 (off 포함) 용도.
    ///
    /// **사이클 145 (IMPLEMENTATION audit #14, #2)**: ApplyScope 명시.
    /// - Mac sparse engine: 사용 ✓ (cycle pose 에 적용)
    /// - Onboard 모드 daemon: 송신 ✗ (WalkingEngineCommand 필드 아님 — 별도 PRD)
    /// - 사용자는 Onboard 모드에서 본 토글 변경해도 robot 반응 변화 없음.
    ///   UI 가 ApplyScope badge 로 안내 필요.
    public var enableBalanceCorrection: Bool = false {
        didSet {
            if enableBalanceCorrection != oldValue {
                // v1.11.24 audit iter2-G — caution preset 보행 중 보정 OFF 차단.
                // 종전: FallPreventionMonitor / GyroCorrectorControls 의 intensity 슬라이더가
                // 0 으로 떨어지면 본 setter 가 false 로 flip → 활성 fastWalk/turn* 가
                // 보정 없이 계속 진행 → 낙상 위험 (P0-3 의 의도 우회).
                // fix: 활성 preset 이 caution + ON→OFF 시도면 setter rollback + 명시 경고.
                if !enableBalanceCorrection,
                   let active = activeRobotPreset,
                   active.safety == .caution,
                   isWalkActive {
                    // **v1.11.24 audit iter3-E + iter4-critic #3** — rollback re-entry 시
                    // ramp / .correctorOn 이벤트가 두 번 발사되는 부작용 방지. defer 로
                    // 예외 시에도 flag 가 stuck 되지 않도록 보장 (crash-safe).
                    isRefusingBalanceOff = true
                    defer { isRefusingBalanceOff = false }
                    enableBalanceCorrection = true
                    lastRobotEvent = "⚠️ 자세 보정 OFF 차단 — '\(active.label)' 보행 중. 정지(■) 후 변경"
                    logSafetyEvent(
                        kind: .correctorOff,
                        message: "자세 보정 OFF 거부 — caution preset '\(active.label)' 활성"
                    )
                    return
                }
                // 토글 전환 — ramp 재시작 (ON → 0초부터 / OFF → nil).
                // iter3-E rollback re-entry 시 silent — log/ramp 부작용 skip.
                if isRefusingBalanceOff { return }
                correctionEnabledAt = enableBalanceCorrection ? Date() : nil
                if !enableBalanceCorrection { lastCorrections = nil }
                rampCompletedLogged = false
                logSafetyEvent(
                    kind: enableBalanceCorrection ? .correctorOn : .correctorOff,
                    message: enableBalanceCorrection
                        ? "자세 보정 ON — 1초 ramp 시작"
                        : "자세 보정 OFF"
                )
                // **v1.14.2 (2026-05-21)** — config 변경 telemetry. 사용자 의도 추적 —
                // "보행 시작 직전에 보정 끄거나 켰는가" 같은 진단에 필수.
                Harness.shared.record(
                    .walkLabConfigChange, level: .info, actor: .user,
                    data: ["field": AnyCodable("enableBalanceCorrection"),
                           "value": AnyCodable(enableBalanceCorrection),
                           "active_preset": AnyCodable(activeRobotPreset?.label ?? "none"),
                           "is_walking": AnyCodable(isWalkActive)]
                )
            }
        }
    }
    /// v1.11.24 audit iter3-E — enableBalanceCorrection rollback 중인지 표시.
    /// true 일 때 didSet 의 inner re-entry 는 silent.
    private var isRefusingBalanceOff: Bool = false
    /// 보정 활성 시 0~1초 ramp 시작 시점. nil 이면 ramp 미시작.
    /// **v1.22.X 사이클 100 (Phase 5)**: private → internal — `+BalanceCorrection.swift`
    /// extension 의 `applyBalanceCorrectionIfEnabled` 가 ramp 시작 시각 mutate.
    var correctionEnabledAt: Date?
    /// 최근 산정 보정 delta (UI 표시·디버그 용).
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var lastCorrections: BalanceCorrector.Corrections?
    /// **Phase C (2026-05-16)**: balanceState .danger 시 동결 기준 pose. nil 이면 walkReady fallback.
    /// **v1.22.X 사이클 100 (Phase 5)**: private → internal — extension corrections apply 가
    /// safe pose snapshot 갱신.
    var lastSafePose: RobotPose?
    /// Corrector 인스턴스 — `WalkParams.default()` gain 정합. v1.8 정정: intensity 가
    /// `correctorIntensityLevel` 슬라이더에 따라 동적 변경.
    /// v1.11: gainProfile 변경 시 base 가 robotisOriginal ↔ v110Experimental 로 swap.
    public var balanceCorrector: BalanceCorrector = .robotisOriginal

    /// **v1.11 (2026-05-17)**: 자이로 보정 4축 통합 설정.
    /// algorithmMode / signConvention / gainProfile / applyToRobot 을 한 곳에서 관리.
    /// 사용자 prompt 의 4-axis UI 모델. didSet 으로 corrector 인스턴스 swap + 안전 gate 적용.
    public var balanceExperimentConfig: BalanceExperimentConfig = .defaultRobotis {
        didSet {
            guard balanceExperimentConfig != oldValue else { return }
            // gainProfile 또는 algorithmMode 변경 → corrector 인스턴스 재생성.
            //
            // **v1.11.1 (2026-05-18 사용자 review CRITICAL-1) — observeOnly forceHybrid fix**:
            // 종전: `forceHybrid: algorithmMode == .hybridBA` 였음.
            //   → v110Observe (observeOnly + v110Experimental gainProfile) 일 때
            //     forceHybrid=false 라 corrector.enableHybrid 가 false 로 강제됨.
            //   → useHybridPath = false → 실제로는 P-control 경로로 흐름.
            //   → "v1.10 관찰" UI 라벨과 다르게 Hybrid 알고리즘 검증이 안 됨 (CRITICAL).
            //
            // fix: observeOnly 시 gainProfile 의 native enableHybrid 를 보존.
            //   - v110Experimental.enableHybrid=true → Hybrid 알고리즘 관찰
            //   - robotisOriginal.enableHybrid=false → P-control 관찰
            //   사용자가 "이 gain 으로 이 algorithm 을 관찰" 의도 그대로 작동.
            let profileChanged = balanceExperimentConfig.gainProfile != oldValue.gainProfile
            let modeChanged = balanceExperimentConfig.algorithmMode != oldValue.algorithmMode
            if profileChanged || modeChanged {
                let forceHybrid: Bool? = {
                    switch balanceExperimentConfig.algorithmMode {
                    case .hybridBA:        return true   // 명시 Hybrid (실 적용)
                    case .robotisPControl: return false  // 명시 P-control (실 적용)
                    case .off:             return false  // 무관, 어떤 path 도 안 탐
                    case .observeOnly:
                        // observeOnly = "이 gainProfile 의 native algorithm 을 관찰".
                        // v110Experimental → Hybrid, robotisOriginal → P-control.
                        return nil  // makeCorrector 가 base.enableHybrid 사용.
                    }
                }()
                balanceCorrector = Self.makeCorrector(
                    level: correctorIntensityLevel,
                    gainProfile: balanceExperimentConfig.gainProfile,
                    forceHybrid: forceHybrid,
                    customHipRollGain: customHipRollGain,
                    customKneeGain: customKneeGain,
                    customAnklePitchGain: customAnklePitchGain,
                    customAnkleRollGain: customAnkleRollGain
                )
            }
            // 안전 차단 — alternateDiagnostic + 실 적용 조합은 자동으로 applyToRobot=false.
            // **v1.11.5.2 (2026-05-18, Codex Med #4 fix)**: pitchInputConvention 보존 추가.
            // 종전 누락 → blocked 강등 시 default `.imuRaw` 로 reset 되어 정규화 무효화.
            if case .blocked = balanceExperimentConfig.safetyVerdict {
                if balanceExperimentConfig.applyToRobot {
                    balanceExperimentConfig = BalanceExperimentConfig(
                        algorithmMode: balanceExperimentConfig.algorithmMode,
                        signConvention: balanceExperimentConfig.signConvention,
                        gainProfile: balanceExperimentConfig.gainProfile,
                        applyToRobot: false,
                        pitchInputConvention: balanceExperimentConfig.pitchInputConvention
                    )
                    logSafetyEvent(
                        kind: .correctorOff,
                        message: "안전 차단: 반대 부호 실험 + 실 적용 → observe-only 강제 전환"
                    )
                    return  // 재귀 didSet 한 번 더 실행됨, 거기서 끝
                }
            }
            logSafetyEvent(
                kind: .correctorOn,
                message: "보정 설정 변경 → \(balanceExperimentConfig.algorithmMode.label) / "
                       + "\(balanceExperimentConfig.signConvention.label) / "
                       + "\(balanceExperimentConfig.gainProfile.label)"
                       + (balanceExperimentConfig.applyToRobot ? " (실 적용)" : " (관찰)")
            )
            // **v1.14.8 (2026-05-21) perf #6**: pitchInputConvention 변경 시 캐시 무효화 + 재계산.
            // 종전 raw safetyTimeline 은 그대로지만 normalized 가 stale 한 convention 으로
            // 계산되어 있음. 사용자가 convention 토글 후 monitor 보면 잠시 잘못된 부호.
            if balanceExperimentConfig.pitchInputConvention != oldValue.pitchInputConvention {
                rebuildNormalizedSafetyTimeline()
            }
        }
    }

    /// **v1.14.8 (2026-05-21) perf #6** — convention 변경 시 normalized cache 재계산.
    /// O(N) 1회만 발생 (사용자가 toggle 할 때) — 매 tick O(1) amortize 의 대가.
    private func rebuildNormalizedSafetyTimeline() {
        let convention = balanceExperimentConfig.pitchInputConvention
        normalizedSafetyTimeline = safetyTimeline.map { sample in
            let mapped = ImuAttitudeDisplayMapping.normalizeConvention(
                rawRoll: sample.rollDeg,
                rawPitch: sample.pitchDeg,
                convention: convention
            )
            return NormalizedSafetySample(
                timestamp: sample.timestamp,
                rollDeg: mapped.roll,
                pitchDeg: mapped.pitch,
                predictionScore: sample.predictionScore
            )
        }
    }

    // MARK: - §3 v2 pipeline handoff wiring (2026-05-17)
    //
    // `docs/handoff/2026-05-17-walk-data-pipeline-v2-handoff.md` §3 의 String 기반
    // wiring 필드. v2 pipeline (worktree `naughty-chebyshev-713072`) 의
    // `WalkSessionRecorder.start(_:)` 가 자동으로 v2 header 에 반영하기 위함.
    // - 3개 (algorithm/sign/gain) 는 `balanceExperimentConfig` 의 read-only mirror.
    // - `correctionApplyMode` 는 4-state 통합 매핑 (off/observeOnly/simOnly/robotApplied).
    // - `imuSourceAtStart`, `imuScaleSuspicionAtStart` 는 start() 시점 snapshot.
    // - `operatorNote`, `comparisonTag` 는 사용자 입력.

    /// algorithmMode rawValue (`off`/`robotisPControl`/`hybridBA`/`observeOnly`).
    /// `balanceExperimentConfig` 의 mirror — handoff §3 호환.
    public var balanceAlgorithmMode: String {
        balanceExperimentConfig.algorithmMode.rawValue
    }
    /// signConvention rawValue (`robotisWalkingCpp`/`alternateDiagnostic`).
    public var balanceSignConvention: String {
        balanceExperimentConfig.signConvention.rawValue
    }
    /// gainProfile rawValue (`robotisOriginal`/`v110Experimental`/`custom`).
    /// **참고**: handoff §3 은 `v110Recommended` 라 적었지만 main 의 실제 enum 은
    /// `v110Experimental` (실 검증 전 명시) — 향후 v2 merge 시 단순 rename.
    public var balanceGainProfile: String {
        balanceExperimentConfig.gainProfile.rawValue
    }
    /// 4-state apply mode 매핑:
    /// - `.off` algorithm → "off"
    /// - `.observeOnly` algorithm → "observeOnly"
    /// - `.robotisPControl`/`.hybridBA` + applyToRobot=false → "observeOnly"
    /// - applyToRobot=true + store?.bus 없음 → "simOnly"
    /// - applyToRobot=true + store?.bus 존재 → "robotApplied"
    public var correctionApplyMode: String {
        let cfg = balanceExperimentConfig
        switch cfg.algorithmMode {
        case .off:         return "off"
        case .observeOnly: return "observeOnly"
        case .robotisPControl, .hybridBA:
            if !cfg.applyToRobot { return "observeOnly" }
            return (store?.bus == nil) ? "simOnly" : "robotApplied"
        }
    }
    /// session start 시점의 IMU 출처 ("sim"/"real"/"stale"). start() 가 갱신.
    public private(set) var imuSourceAtStart: String = "sim"
    /// session start 시점의 IMU scale 의심 ("normal"/"saturated"/"unknown" 등).
    public private(set) var imuScaleSuspicionAtStart: String = "unknown"
    /// 운영자 메모 — UI 에서 1줄 입력. v2 header 에 그대로 기록.
    public var operatorNote: String? = nil
    /// A/B 비교 tag — `WalkComparisonTag.arm` 으로 "A"/"B" 구분. nil 이면 비교 의도 없음.
    public var comparisonTag: WalkComparisonTag? = nil

    /// **v1.8 (2026-05-17 사용자 요청)**: 자이로 기반 자세 보정의 개입 강도 5단계.
    /// 사용자가 슬라이더로 조절. multiplier 매핑:
    ///   - 0: 꺼짐 (intensity 0.0 = 보정 없음)
    ///   - 1: 부드러움 (intensity 0.5 = ROBOTIS 절반)
    ///   - 2: 표준 (intensity 1.0 = ROBOTIS default — 권장)
    ///   - 3: 적극적 (intensity 1.5 = ROBOTIS 1.5배)
    ///   - 4: 최대 (intensity 2.0 = ROBOTIS 2배, 안전 clamp ±15° 유지)
    ///
    /// **사이클 145 (IMPLEMENTATION audit #14, #2)**: ApplyScope 명시.
    /// - Mac sparse engine: 사용 ✓ (corrector multiplier 적용)
    /// - Onboard 모드 daemon: 송신 ✗ (별도 PRD — robot firmware 측에 동일 mapping 없음)
    /// - Onboard 모드에서 사용자가 슬라이더 조정해도 실 robot 자이로 보정 강도는 변경 안 됨.
    public var correctorIntensityLevel: Int = 2 {
        didSet {
            let clamped = max(0, min(4, correctorIntensityLevel))
            if clamped != correctorIntensityLevel {
                correctorIntensityLevel = clamped
                return
            }
            guard clamped != oldValue else { return }
            // **v1.14.7 (2026-05-21) — 사용자 응답성 fix**: 종전 setter 안에서 동기로
            // makeCorrector + logSafetyEvent 실행 → 클릭 응답 지연. SwiftUI binding
            // 갱신은 즉시 (button highlight) — 무거운 작업은 다음 runloop tick 으로.
            Task { @MainActor [weak self, clamped, oldValue] in
                guard let self = self else { return }
                let forceHybrid: Bool? = {
                    switch self.balanceExperimentConfig.algorithmMode {
                    case .hybridBA:        return true
                    case .robotisPControl: return false
                    case .off:             return false
                    case .observeOnly:     return nil
                    }
                }()
                self.balanceCorrector = Self.makeCorrector(
                    level: clamped,
                    gainProfile: self.balanceExperimentConfig.gainProfile,
                    forceHybrid: forceHybrid,
                    customHipRollGain: self.customHipRollGain,
                    customKneeGain: self.customKneeGain,
                    customAnklePitchGain: self.customAnklePitchGain,
                    customAnkleRollGain: self.customAnkleRollGain
                )
                self.logSafetyEvent(
                    kind: .correctorOn,
                    message: "자이로 보정 강도 → \(Self.intensityLabel(level: clamped))"
                )
                _ = oldValue
            }
        }
    }

    /// 5단계 level → BalanceCorrector intensity multiplier.
    public static func intensityMultiplier(level: Int) -> Double {
        switch max(0, min(4, level)) {
        case 0: return 0.0
        case 1: return 0.5
        case 2: return 1.0
        case 3: return 1.5
        case 4: return 2.0
        default: return 1.0
        }
    }

    /// 5단계 level → 사용자 라벨.
    /// **v1.11 (2026-05-17)**: 실 robot 검증 전 default 는 ROBOTIS 기준 (level 2 = 1.0×)
    /// 로 환원. v1.10 시뮬 결과 (level 3 권장) 는 별도 "v1.10 실험" profile 로 격리.
    public static func intensityLabel(level: Int) -> String {
        switch max(0, min(4, level)) {
        case 0: return "꺼짐"
        case 1: return "부드러움 (×0.5)"
        case 2: return "표준 ROBOTIS (×1.0)"
        case 3: return "강함 (×1.5, 실험)"
        case 4: return "최대 (×2.0, 실험)"
        default: return "표준"
        }
    }

    /// **v1.11 phase fix**: walking cycle 의 effective period. tuning 이 nil 이면
    /// preset 의 defaultTuning fallback. preset walking 에서도 phase-locked correction
    /// 이 작동 가능.
    public func effectiveWalkPeriodMs() -> Double {
        if let tuning = currentWalkTuning() {
            return tuning.periodMs
        }
        guard current != .idle else { return 0 }
        return WalkMotionLibrary.defaultTuning(for: current).periodMs
    }

    /// Intensity level → BalanceCorrector 인스턴스 생성.
    /// **v1.10**: hybrid B+A 파라미터도 base 에서 전달.
    /// **v1.11 (2026-05-17 사용자 prompt)**: gainProfile + forceHybrid 축 추가.
    ///   - gainProfile: robotisOriginal (default) / v110Experimental
    ///   - forceHybrid: nil 면 base 의 enableHybrid 유지, true/false 면 override
    public static func makeCorrector(
        level: Int,
        gainProfile: BalanceGainProfile = .robotisOriginal,
        forceHybrid: Bool? = nil,
        // **v1.11.6 (2026-05-18)**: `.custom` profile 의 사용자 지정 gain. gainProfile=.custom
        // 일 때만 적용. nil 이면 robotisOriginal fallback (legacy backward-compat).
        customHipRollGain: Double? = nil,
        customKneeGain: Double? = nil,
        customAnklePitchGain: Double? = nil,
        customAnkleRollGain: Double? = nil
    ) -> BalanceCorrector {
        let mult = intensityMultiplier(level: level)
        let base = BalanceCorrector.forGainProfile(gainProfile)
        let useHybrid = forceHybrid ?? base.enableHybrid

        // v1.11.6: .custom 일 때 사용자 지정 gain 적용. 그 외 profile 은 base 값 그대로.
        let hipRoll = (gainProfile == .custom ? customHipRollGain : nil) ?? base.hipRollGain
        let knee = (gainProfile == .custom ? customKneeGain : nil) ?? base.kneeGain
        let anklePitch = (gainProfile == .custom ? customAnklePitchGain : nil) ?? base.anklePitchGain
        let ankleRoll = (gainProfile == .custom ? customAnkleRollGain : nil) ?? base.ankleRollGain

        return BalanceCorrector(
            intensity: mult,
            maxCorrectionDeg: base.maxCorrectionDeg,
            hipRollGain: hipRoll,
            kneeGain: knee,
            anklePitchGain: anklePitch,
            ankleRollGain: ankleRoll,
            internalGain: base.internalGain,
            enableHybrid: useHybrid,
            slowDriftTauSec: base.slowDriftTauSec,
            slowGain: base.slowGain,
            fastGain: base.fastGain,
            sagittalSwayAmpDeg: base.sagittalSwayAmpDeg,
            lateralSwayAmpDeg: base.lateralSwayAmpDeg
        )
    }

    // 2026-05-17 T3.1 partial split: BalanceState enum → WalkLabSession+Types.swift.

    /// **Phase G11 (2026-05-15)**: 3D 모델 시각화용 현재 자세.
    ///
    /// 보행 중 매 step 갱신 (`runContinuousWalk` / `runWalkCycle` 에서 송출 직전 publish).
    /// sim mode (실 로봇 미연결) 도 50ms tick 마다 phase pose 합성해서 갱신 →
    /// `WalkLabView` 의 `RobotScene3D(pose: session.visualPose)` 가 받아서 모델 동작.
    public var visualPose: RobotPose = .walkReady

    // MARK: - Monitoring Dashboard (2026-05-16): 시계열 안전 상태 + 이벤트 로그

    // 2026-05-17 T3.1 partial split: SafetySample / SafetyEvent → WalkLabSession+Types.swift.

    /// 시계열 안전 sample buffer — 최근 10초 (10Hz tick × 100, max 250).
    /// **사이클 111 (Phase 9)**: `private(set)` → `internal(set)` — `WalkLabSession+SafetySampling`
    /// 의 `recordSafetySampleAndEvents()` 가 write 필요.
    public internal(set) var safetyTimeline: [SafetySample] = []
    /// **v1.14.8 (2026-05-21) perf #6**: 정규화 캐시.
    /// FallPreventionMonitor.timeSeriesRow 가 body 마다 250×3 = 750 atan/asin 호출
    /// 하던 비용을 sample 추가 시 1회로 amortize. View 는 directly read.
    /// balanceExperimentConfig.pitchInputConvention 변경 시 rebuildNormalizedTimeline()
    /// 호출로 일관성 유지.
    /// **사이클 111 (Phase 9)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var normalizedSafetyTimeline: [NormalizedSafetySample] = []
    /// 안전 이벤트 로그 — 최근 50건 (가장 최신이 last). 별도 보존 — start() reset 시에도 유지.
    public private(set) var safetyEvents: [SafetyEvent] = []
    /// 모니터링 대시보드 펼침 상태 — UI 토글. 앱 재시작 후에도 유지 (UserDefaults).
    /// 키: `df.walklab.monitoringExpanded`. UI 가 @AppStorage 로 binding 추천.
    ///
    /// **v1.11.6 (2026-05-18) — default true 로 변경**:
    /// 종전 default false (Bool 미설정 시) → 첫 사용자가 chevron 클릭해서 펼쳐야
    /// FallPreventionMonitor + WalkingEnginePicker + BalanceExperimentControls +
    /// StaticTiltCalibrationPanel 모두 보임. UX 누락.
    /// 이제 UserDefaults 미설정 시 true 로 초기화. 사용자가 명시 OFF 후엔 OFF 유지.
    public var monitoringExpanded: Bool = {
        let key = "df.walklab.monitoringExpanded"
        if UserDefaults.standard.object(forKey: key) == nil {
            // 첫 실행 — default true (모든 패널 노출).
            UserDefaults.standard.set(true, forKey: key)
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet {
            UserDefaults.standard.set(monitoringExpanded,
                                      forKey: "df.walklab.monitoringExpanded")
        }
    }

    /// **사이클 111 (Phase 9)**: `private` → `internal` — `WalkLabSession+SafetySampling` 의 prune 정책.
    internal static let safetyTimelineMaxWindowSec: Double = 10.0
    internal static let safetyTimelineMaxSamples: Int = 250
    private static let safetyEventsMaxCount: Int = 50

    /// 이전 tick 의 balanceState — 전환 검출용.
    /// **사이클 111 (Phase 9)**: `private` → `internal` — `WalkLabSession+SafetySampling`
    /// 의 state transition 이벤트 비교 + 갱신.
    internal var previousBalanceState: BalanceState = .normal
    /// 이전 tick 의 imuSource — 전환 검출용.
    /// **사이클 111 (Phase 9)**: `private` → `internal` — extension event 발화 시 비교.
    internal var previousImuSource: ImuSource = .sim
    /// 이전 tick 의 motorTempSource — 전환 검출용.
    /// **사이클 111 (Phase 9)**: `private` → `internal` — extension event 발화 시 비교.
    internal var previousMotorTempSource: MotorTempSource = .sim
    /// 이전 tick 의 predictor recommendEmergency — rising-edge 만 이벤트.
    /// **사이클 111 (Phase 9)**: `private` → `internal` — extension event 발화 시 rising-edge 비교.
    internal var previousRecommendEmergency: Bool = false
    /// 이전 tick 의 ramp 완료 여부 — 한 번만 이벤트 발행.
    /// **사이클 111 (Phase 9)**: `private` → `internal` — extension ramp 완료 1회 로그 가드.
    internal var rampCompletedLogged: Bool = false

    /// **현재 ramp 진행률** (0..1). corrector OFF 또는 미시작 시 nil.
    public var rampProgress: Double? {
        guard enableBalanceCorrection, let t = correctionEnabledAt else { return nil }
        return max(0, min(1, Date().timeIntervalSince(t)))
    }

    // MARK: - 세션 기록
    public var history: [WalkLabRecord] = []

    // MARK: - 실 로봇 연결 (optional)
    /// 환경에서 주입되는 연결 store. nil 이면 sim only.
    /// **v1.15.0 (2026-05-21) Phase 1**: private → internal — `WalkLabSession+Trials.swift`
    /// extension 이 isRealRobot 판정 (`store?.bus != nil`) 위해 read 필요.
    weak var store: ConnectionStore?

    /// 2026-05-17 사용자 보고 critical: IMU scale 진단 결과 noop passthrough.
    /// FallPreventionMonitor 가 session 만 알기 때문에 session 통해 expose.
    public var imuScaleSuspicion: ConnectionStore.ImuScaleSuspicion {
        store?.imuScaleSuspicion ?? .unknown
    }
    public var imuAccelZMagnitude: Double {
        store?.imuAccelZMagnitudeAvg ?? 0
    }

    /// **v1.11.2 (2026-05-18) — CI Swift 5.9 strict concurrency 호환 helper**.
    /// Task.detached 의 inner closure 에서 `await MainActor.run { self?.store?... }`
    /// 가 weak self 재캡쳐 error. MainActor isolated method 로 추출.
    /// 사용처: runContinuousWalk / runWalkCycle 의 isBusAlive closure.
    public func isBusAliveSnapshot() -> Bool {
        store?.bus != nil
    }

    /// 2026-05-17 안전 강화: 보행 시작 전 종합 안전 체크리스트.
    /// 사용자가 "지금 시작하면 안전한가" 한 눈에 인지.
    /// nil 이면 모든 체크 통과 (시작 안전), 비어있지 않으면 차단 사유 명시.
    public struct PreflightStatus: Equatable, Sendable {
        public struct Check: Equatable, Sendable {
            public enum State: Equatable, Sendable {
                case pass         // ✓ 통과
                case info         // ℹ️ 정보 (차단 안 함, sim 모드 등)
                case warning      // ⚠️ 주의 (사용자 결정)
                case blocking     // 🛑 차단 (보행 시작 불가)
            }
            public let label: String
            public let state: State
            public let detail: String
        }
        public let checks: [Check]
        /// 보행 시작 가능 — blocking check 가 0건일 때 true.
        public var canStart: Bool {
            !checks.contains { $0.state == .blocking }
        }
        /// 사용자가 인지해야 할 주의 사항 (warning + blocking).
        public var attentionItems: [Check] {
            checks.filter { $0.state == .warning || $0.state == .blocking }
        }
    }

    /// 종합 안전 체크리스트 — UI 가 시작 전 표시.
    /// 6 layer 안전 시스템 + 신규 추가 layer (L0 voltage) 종합.
    public var preflightStatus: PreflightStatus {
        var checks: [PreflightStatus.Check] = []

        // L0 — 연결 / Cradle
        if store?.bus == nil {
            checks.append(.init(label: "로봇 연결",
                                state: .info,
                                detail: "시뮬 모드 — 실 로봇 미연결"))
        } else {
            checks.append(.init(label: "로봇 연결", state: .pass,
                                detail: "USB / 네트워크 연결됨"))
        }

        if cradleConfirmed {
            checks.append(.init(label: "L1 거치", state: .pass,
                                detail: "정비 스탠드 거치 확인됨"))
        } else if store?.bus != nil {
            checks.append(.init(label: "L1 거치", state: .blocking,
                                detail: "정비 스탠드 거치 후 '거치됨' 체크 필요"))
        } else {
            checks.append(.init(label: "L1 거치", state: .info,
                                detail: "시뮬 모드 — 거치 확인 불필요"))
        }

        // L0 — 배터리 voltage (실 로봇 연결 시만)
        if let s = store, s.bus != nil,
           let v = s.lastTelemetry?.board?.voltageVolts {
            if v < 10.5 {
                checks.append(.init(label: "L0 배터리",
                                    state: .blocking,
                                    detail: String(format: "%.1fV — 위험 (낮음). 충전 필요 (≥ 10.5V)", v)))
            } else if v < 11.1 {
                checks.append(.init(label: "L0 배터리",
                                    state: .warning,
                                    detail: String(format: "%.1fV — 주의 (≥ 11.1V 권장)", v)))
            } else {
                checks.append(.init(label: "L0 배터리",
                                    state: .pass,
                                    detail: String(format: "%.1fV — 정상", v)))
            }
        }

        // L3 — IMU 신선도 + scale
        if let s = store, s.bus != nil {
            if s.isImuUnavailable {
                checks.append(.init(label: "L3 IMU",
                                    state: .warning,
                                    detail: "IMU 응답 없음 — 자세 보정 불가"))
            } else if s.isImuStale {
                checks.append(.init(label: "L3 IMU", state: .warning,
                                    detail: "IMU 지연 5초+ — 자세 보정 OFF"))
            } else {
                switch s.imuScaleSuspicion {
                case .suspectedLegacy10Bit, .outOfRange:
                    checks.append(.init(label: "L3 IMU plausibility",
                                        state: .warning,
                                        detail: s.imuScaleSuspicion.rawValue))
                case .looksValid16Bit:
                    checks.append(.init(label: "L3 IMU", state: .pass,
                                        detail: "정상 (10-bit ADC, 1g 감지)"))
                case .unknown:
                    checks.append(.init(label: "L3 IMU", state: .info,
                                        detail: "샘플 수집 중…"))
                }
            }
        }

        // L5 — Balance corrector + caution preset
        if current.safety == .caution && !enableBalanceCorrection {
            checks.append(.init(label: "L5 자세 보정",
                                state: .blocking,
                                detail: "\(current.label) 은 자세 보정 활성화 필요 (낙상 위험)"))
        } else if enableBalanceCorrection {
            checks.append(.init(label: "L5 자세 보정", state: .pass,
                                detail: "활성 — IMU 기반 균형"))
        }

        // L6 — 모터 온도
        if maxMotorTemp >= 60 {
            checks.append(.init(label: "L6 모터 온도",
                                state: .blocking,
                                detail: String(format: "%.1f°C — 임계 초과. 냉각 후 다시 시도", maxMotorTemp)))
        } else if maxMotorTemp >= 55 {
            checks.append(.init(label: "L6 모터 온도",
                                state: .warning,
                                detail: String(format: "%.1f°C — 임계 직전", maxMotorTemp)))
        }

        return PreflightStatus(checks: checks)
    }
    /// 마지막 송출 상태 — UI 토스트용.
    /// **v1.16.0 (2026-05-21) Phase 2**: private(set) → internal(set).
    /// **v1.16.0.1 fix (code-reviewer H1)**: 종전 `public var` 는 너무 광범위 — preview/test
    /// 등 외부 mutation 허용. `public internal(set)` 으로 좁히면 same-module extension
    /// (예: `WalkLabSession+Recommender.swift`) 이 write 가능하면서 외부 (다른 module 의
    /// public API consumer) 는 read-only.
    public internal(set) var lastRobotEvent: String?

    /// **사이클 69 — pilotPostEvent facade (LOW-2 코덱스)**: 직전 발행 메시지 캐시.
    /// `WalkLabSession+Pilot.pilotPostEvent` 가 1초 내 동일 stamped 메시지 중복 발화 차단에 사용.
    /// nil = 첫 발행 또는 dedup window 만료 후 reset. internal — facade extension 전용.
    var _lastPilotEventMessage: String?

    /// **사이클 69 — pilotPostEvent facade (LOW-2 코덱스)**: 직전 발행 시각.
    /// `_lastPilotEventMessage` 와 함께 1초 dedup window 판정에 사용.
    var _lastPilotEventTime: Date?

    /// **사이클 71 — 코덱스 CRITICAL-2**: facade extension 이 preflight failure 를
    /// set 할 수 있도록 internal helper. `private(set)` 이라 extension 에서도 직접
    /// write 불가 → 본 helper 가 유일한 module-internal entry. 본체 본 file 안에 위치 →
    /// 직접 property 접근 OK.
    ///
    /// 호출 경로: `WalkLabSession+Pilot.pilotMarkPreflightFailure(_:)` 위임. 외부 caller
    /// (다른 module) 는 public facade 만 사용.
    internal func _internalSetPreflightFailure(_ failure: WalkPreflightFailure) {
        lastPreflightFailure = failure
        startBlockedReason = failure.diagnosticCode
    }

    /// 실 보행 cycle 진행 중인지 — UI badge / 토글 disable 용.
    public private(set) var isRobotWalking: Bool = false

    /// Codex P0 fix (2026-05-13 3차): preflight 결과 + cycle 종료 후 결과 집계.
    /// 이전 v1.0 은 모든 write 를 `_ = try?` 로 silently swallow → "정상 종료" 처럼 보였음.
    public private(set) var lastCycleResult: WalkCycleResult?
    public private(set) var lastPreflightFailure: WalkPreflightFailure?

    // MARK: - v1.11.24 audit (2026-05-20): 상태 분리
    //
    // 종전: `current` 한 변수가 UI selection / 3D preview / 로봇 active task / 로거 preset
    // 모두를 대표 → 보행 중 다른 preset 클릭 시 `current` 만 바뀌고 실제 task 는 안 바뀌어
    // UI/log/robot mismatch. (audit 보고서 §1, §2 — slowWalk 세션 안에 normalWalk/fastWalk
    // sample 이 섞이는 결정적 증거)
    //
    // fix: 세 가지 상태를 분리.
    // - `selectedPreset` (= `current`): 사용자가 마지막으로 클릭/선택한 preset (UI 강조용).
    // - `activeRobotPreset`: 실 motor task 가 시작된 preset. nil = task 없음.
    // - `requestedPreset`: 마지막으로 `start(_:)` 가 시도한 preset. preflight 실패 시
    //                      `activeRobotPreset = nil` 이지만 `requestedPreset` 은 남음.
    //
    // 로거 sample.preset 은 항상 `activeRobotPreset ?? selectedPreset` 우선 → 실 동작 반영.

    /// 실 motor task 가 진행 중인 preset. nil = walkCycleTask 없음 + onboardWalkingActive=false.
    /// **로거의 sample.preset 은 이 값을 우선 사용** — 사용자가 다른 preset 을 클릭해도 실 task
    /// 가 안 바뀌면 로그는 변경 전 preset 유지 (mixed-preset session 문제 차단).
    public private(set) var activeRobotPreset: WalkLabPreset?

    /// 마지막 `start(_:)` 가 시도한 preset (preflight 실패 포함). UI 의 "마지막 요청"
    /// 표시 및 로거 header 의 `requestedPreset` 필드에 기록.
    public private(set) var requestedPreset: WalkLabPreset?

    /// preflight 차단 사유 — `WalkPreflightFailure.diagnosticCode`. 로거 header 의
    /// `startBlockedReason` 필드. nil = preflight 통과 (성공 또는 미시도).
    public private(set) var startBlockedReason: String?

    /// 첫 setPosition 성공 시 true. 실제 명령이 motor 까지 도달했는지 회고적 진단용.
    /// `runWalkCycle` / `runContinuousWalk` 의 onBusWriteFailure callback 의 역.
    public private(set) var motorWriteStarted: Bool = false

    /// 실 motor write 누적 step 수. 로거 header / 자체 진단 dashboard 용.
    public private(set) var motorWriteStepCount: Int = 0

    /// ROBOTIS Onboard ACK 상태 — "ok" / "no_ack" / "timeout" / "error: ..." 또는 nil.
    /// `WalkLabOnboardBridge` 가 ACK 수신 시 update.
    public private(set) var onboardAckStatus: String?

    /// `isRobotWalking || onboardWalkingActive` — UI 가 preset 버튼 disable 시 사용.
    /// `walkCycleTask != nil` 은 private 이므로 view 에서 직접 못 보므로 published 두 값의 합.
    public var isWalkActive: Bool {
        isRobotWalking || onboardWalkingActive
    }

    /// **사이클 61 (codex HIGH-3 fix)** — "보행 중" 진짜 invariant. single source of truth.
    ///
    /// 종전 line 2064 / 2179 / 2232 의 중복 복합 술어:
    ///   `current != .idle || walkCycleTask != nil || onboardWalkingActive`
    /// 가 facade `pilotIsWalking` 의 단순화 (`current != .idle`) 와 어긋남 → race:
    /// preflight 통과 후 `walkCycleTask` 시작 직전 짧은 frame 에서 facade 가 false negative.
    /// bridge auto-start (`WalkLabRCBridge` line 295/313) 가 이 frame 에 stop 액션 받으면
    /// silent drop. 본 property 가 모든 walking 판정의 단일 진입점.
    ///
    /// `walkCycleTask` 가 private 이므로 본 file 안에서 computed → 외부 site 는 본 property
    /// 위임. `internal` — UI / test / facade 만 read.
    internal var isActuallyWalking: Bool {
        current != .idle || walkCycleTask != nil || onboardWalkingActive
    }

    /// **테스트 전용 helper** — bus 없이도 "보행 중" 상태를 시뮬해서 alreadyWalking 가드 검증.
    /// 운영 코드에서는 절대 사용 금지. 본 메서드는 `XCTest` bundle 에서만 호출되어야 함.
    /// **v1.11.24 audit iter4-critic #2**: 종전 단순 `#if DEBUG` 는 SwiftUI preview / debug
    /// view 등 비-test 코드도 접근 가능 → 우회 위험. `assert` 로 호출 환경 자체를 확인.
    #if DEBUG
    internal func _testForceWalkActive(_ preset: WalkLabPreset) {
        assert(
            NSClassFromString("XCTestCase") != nil,
            "_testForceWalkActive 는 XCTest 환경에서만 호출 가능. preview / debug view 에서 호출 금지."
        )
        isRobotWalking = true
        activeRobotPreset = preset
        current = preset
    }
    #endif

    // 2026-05-17 T3.1 partial split: WalkCycleResult / WalkPreflightFailure → WalkLabSession+Types.swift.

    /// 하체 (균형 critical) 관절 — bodyPart 기반으로 매번 계산.
    private static var lowerBodyJoints: Set<JointID> {
        Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
    }

    /// SwiftUI 한계 우회 — `.onAppear` 에서 env 가 도착하면 호출.
    public func attach(store: ConnectionStore) {
        self.store = store
    }

    // MARK: - 내부
    /// **사이클 109 (Phase 8)**: `private` → `internal` — `WalkLabSession+BalanceMitigation`
    /// 의 `applyBalanceMitigation()` 가 `engine.setCommand(...)` 호출 필요.
    internal let engine: WalkEngine
    private var simTimer: Timer?
    private var startTime: Date?
    /// Sim IMU 본체 흔들림 위상 (rad). tick 마다 ω·dt 누적.
    /// **사이클 97 (Phase 3)**: `private` → `internal` — `WalkLabSession+SensorUpdates`
    /// extension 의 `updateSimIMU` 가 read/write. module 내부만 접근.
    internal var simSwayPhase: Double = 0
    /// 실 보행 cycle Task — start(preset) 시 시작, stop / emergency 시 cancel.
    /// **사이클 91 (Phase 1C)**: `private` → `internal` 격상 — `WalkLabSession+Calibration`
    /// extension 의 `runStaticTiltCalibration` 이 본 Task 의 nil 여부로 보행 중 거부 판정
    /// 필요. module 내부 접근만 허용, 외부 module 은 여전히 not visible.
    internal var walkCycleTask: Task<Void, Never>?
    /// 고급 슬라이더 연속 drag 중 실 보행 page 재합성을 debounce.
    private var walkTuningRestartTask: Task<Void, Never>?

    /// Sim 한 tick 의 dt (s).
    /// **v1.14.8 (2026-05-21) perf #2**: 50ms → 100ms (20Hz → 10Hz).
    /// 종전: 매 50ms tick 마다 12~15 @Published 갱신 (leftFoot, rightFoot, elapsedMs,
    ///       phaseLabel, footTrail, visualPose, imuRollDeg, imuPitchDeg, ...) →
    ///       main actor SwiftUI invalidation 폭증 → 모든 reactive view 가 50ms 마다
    ///       body 재평가 → 클릭 응답 지연.
    /// 신규: 100ms (10Hz). 사람 눈에 부드러움 충분 (cinema 24fps 보다 빠름).
    ///       dt 도 같이 0.1 — 시뮬 위상/온도/swayPhase 가 자동으로 real-time 보조.
    /// **사이클 97 (Phase 3)**: `private` → `internal` — sensor update extension 가 read.
    internal let tickDtSec: Double = 0.1
    /// 모터 발열율 — 워킹 중 (°C/s). 약 6°C/min, 무거운 부하 가정.
    /// **사이클 97 (Phase 3)**: `private` → `internal` — `updateSimThermal` 가 read.
    internal let motorHeatRate: Double = 0.10
    /// 모터 자연 냉각율 — idle 중 (°C/s).
    /// **사이클 97 (Phase 3)**: `private` → `internal` — `updateSimThermal` 가 read.
    internal let motorCoolRate: Double = 0.04
    /// 모터 정상 평형 온도 (idle).
    /// **사이클 97 (Phase 3)**: `private` → `internal` — `updateSimThermal` 가 read.
    internal let motorAmbientTemp: Double = 35.0

    /// **v1.20.12 사이클 18** — emergency 상태 명시 recovery (사용자가 "I'm ready to continue").
    /// flag 만 clear — walking 시작 안 함. session.start 가 별도로 호출돼야 robot 다시 움직임.
    /// 사이클 10-fix CRITICAL 에서 emergency 후 preset 단축키 차단 → 본 메서드가 unblock entry point.
    public func exitEmergencyMode() {
        guard emergencyStopActive else { return }
        emergencyStopActive = false
        // **v1.21.2 사이클 67**: trigger payload 도 cleanup — recovery 완료 = 과거 trigger 무관.
        _lastEmergencyTrigger = nil
        lastRobotEvent = "✅ 긴급 정지 recovery — preset 입력 가능"
        logSafetyEvent(
            kind: .recovery,
            message: "사용자 emergency recovery — flag 해제, walking 미시작"
        )
    }

    public init() {
        self.engine = WalkEngine()
        // v1.7: enableBalanceCorrection default ON 이라 ramp 시작 시점을 init 시 기록.
        if enableBalanceCorrection {
            correctionEnabledAt = Date()
        }
        // v1.10: balanceCorrector 를 default level 에 맞춰 생성. didSet 은 init 에서 fire 안 함.
        // v1.11: init 시점엔 balanceExperimentConfig 가 .defaultRobotis (robotisOriginal / P-control).
        // v1.11.1 fix: observeOnly forceHybrid 일관 (didSet 과 동일 로직).
        let initForceHybrid: Bool? = {
            switch balanceExperimentConfig.algorithmMode {
            case .hybridBA:        return true
            case .robotisPControl: return false
            case .off:             return false
            case .observeOnly:     return nil
            }
        }()
        self.balanceCorrector = Self.makeCorrector(
            level: correctorIntensityLevel,
            gainProfile: balanceExperimentConfig.gainProfile,
            forceHybrid: initForceHybrid
        )
    }

    /// 2026-05-17 concurrency review (agent #1 CRITICAL): Timer / Task 누수 차단.
    /// stop() 호출 안 한 채 session deallocation 시 RunLoop 가 simTimer 를 strong
    /// retain → tick block 의 Task 가 영구 스케줄링. walkCycleTask / walkTuningRestartTask
    /// 도 동일. View 전환 / @State reinit 시 발생 가능.
    ///
    /// **v1.14.9 (2026-05-21) Fix #7 / Swift 6 대비**:
    /// @Observable + Swift 5.9+ 에서 deinit 은 nonisolated. main-actor-isolated
    /// stored property 접근 → compile error. MainActor.assumeIsolated 로 안전 보장
    /// (SwiftUI @State 의 deinit 은 main thread 에서 호출 — assumption 항상 참).
    /// Timer.invalidate() / Task.cancel() 둘 다 thread-safe atomic 이라 의미상 안전.
    deinit {
        MainActor.assumeIsolated {
            simTimer?.invalidate()
            walkCycleTask?.cancel()
            walkTuningRestartTask?.cancel()
        }
    }

    /// 현재 효과적인 command — advanced 모드면 custom, 아니면 preset.
    public var effectiveCommand: (x: Double, y: Double, a: Double, enabled: Bool) {
        if advanced {
            return (customX, customY, customA, current != .idle)
        }
        return current.command
    }

    /// 현재 효과적인 주기 (ms) — advanced 면 customPeriodMs, 아니면 preset.
    public var effectivePeriodMs: Double {
        if advanced {
            return customPeriodMs
        }
        return Double(current.periodMs)
    }

    /// 현재 슬라이더 조합의 낙상 위험 점수 (사이드바 게이지 + start gate 공유).
    /// advanced 모드일 때만 의미. 그 외는 preset 의 안전 분류가 우선.
    public var stabilityScore: WalkStabilityResult {
        WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: strideMm,
            sideMm: sideMm,
            turnDeg: turnDeg,
            periodMs: customPeriodMs,
            footHeightMm: footHeightMm,
            balanceGain: balanceGain
        ))
    }

    /// 시작 가능한가? advanced 모드의 critical 점수는 차단. preset 모드는 risk confirm 흐름.
    public var canStart: Bool {
        guard cradleConfirmed else { return false }
        if advanced {
            return stabilityScore.category != .critical
        }
        return true
    }

    /// 프리셋 시작 — 시뮬 50 ms tick + 실 로봇 정적 자세 송출 (bus 연결 시).
    ///
    /// **v1.11.24 audit (2026-05-20) — P0-1 fix**:
    /// 종전: `current = preset`, `engine.setCommand`, `simTimer` 시작을 먼저 수행한 뒤
    ///       `startWalkCycle` 내부에서 walkCycleTask/onboardWalkingActive/IMU 등을 검사 →
    ///       실패 시 UI/log/robot 상태가 갈라짐 (audit §1 mixed-preset 증거).
    /// 현재: `quickPreflight(for:)` 로 **state 변경 전에** 모든 free 검사. 차단 시 즉시 return
    ///       하고 `lastPreflightFailure` + `startBlockedReason` + `requestedPreset` 만 기록.
    ///       `current` / `engine` / `simTimer` / `activeRobotPreset` 등은 변경하지 않음.
    public func start(_ preset: WalkLabPreset) {
        // === P0-1 — state 변경 전 preflight ===
        // `requestedPreset` 는 시도 자체를 기록 (성공/실패 무관) — 사용자 진단용.
        requestedPreset = preset

        // **v1.20.46 사이클 61 — 코덱스 CRITICAL fix (root-level emergency guard)**:
        // 종전: bridge.handlePreset / handleMove / handleMotion 만 emergencyStopActive 검사 →
        // WalkLabView 의 일반 preset 버튼 (tap()), risk sheet 등 bridge 우회 path 가 직접
        // session.start 호출 시 emergency guard 우회. 게다가 본 메서드 line 1059 에서
        // emergencyStopActive = false 로 자동 해제 → "Space (emergency) → preset 버튼 클릭"
        // 시퀀스가 robot 재작동.
        // 신규: 모든 public start entry 차단. 사용자 명시 recovery (exitEmergencyMode) 전까지
        // 어떤 path 도 start 진행 불가. emergency guard 가 한 곳에 모임.
        // **v1.21.1 사이클 66 — 코덱스 CRITICAL-1 fix**: 전용 `.emergencyActive` cause 사용.
        // 종전: `.noConnection` 재사용 → facade (pilotStart) 가 failure.userMessage 를
        // "시뮬 모드 — 로봇 미연결" 로 전달 → 사용자 mental model corruption (emergency
        // 차단을 connection 문제로 오인). 신규: `.emergencyActive` 의 userMessage 가
        // 명시 recovery 안내. diagnosticCode = "emergencyActive" 로 telemetry 도 정확.
        //
        // **v1.21.2 사이클 67 — 코덱스 MEDIUM-3 fix**: trigger payload 도 전달.
        // 사용자 메시지에 "(L3 균형 손실)" 같은 출처 라벨 노출 + diagnosticCode 가
        // `emergencyActive_balanceLostL3` 형식으로 telemetry trigger 별 분류 가능.
        // `_lastEmergencyTrigger` 가 nil 인 race (init 직후 외부에서 flag set) 는
        // `.unknown` fallback — safe degrade.
        if emergencyStopActive {
            let f = WalkPreflightFailure(cause: .emergencyActive(trigger: _lastEmergencyTrigger ?? .unknown))
            lastPreflightFailure = f
            lastRobotEvent = f.userMessage
            startBlockedReason = f.diagnosticCode
            logSafetyEvent(
                kind: .preflightFailure,
                message: "start 차단 — \(f.diagnosticCode): emergency 상태에서 recovery 없이 재시작 시도"
            )
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode),
                       "guard": AnyCodable("root_emergency_guard")]
            )
            return
        }

        if let failure = quickPreflight(for: preset) {
            lastPreflightFailure = failure
            lastRobotEvent = failure.userMessage
            startBlockedReason = failure.diagnosticCode
            logSafetyEvent(
                kind: .preflightFailure,
                message: "start 차단 — \(failure.diagnosticCode): \(failure.userMessage)"
            )
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(failure.diagnosticCode),
                       "active_preset": AnyCodable(activeRobotPreset?.label ?? "none")]
            )
            return
        }
        // preflight 통과 — state 변경 진입.
        // **v1.12.2 (Codex P1-5 fix)** — walkLabStart 발행을 startWalkCycle 진입 후로
        // 이동. quickPreflight 만 통과한 시점에는 아직 startWalkCycle 의 추가 guard
        // (walkCycleTask 중복 / bus 재확인 / cradle 재확인 / balance critical 등)
        // 가 남아 있어 false-positive 가능.
        lastPreflightFailure = nil
        startBlockedReason = nil

        // **사이클 117 (explore agent dead-code fix)**: onboardHealthCheckWarnings
        // production wire-up. 사이클 97 분할 후 production 호출 site 0 이었음 (explore
        // agent flagged). 본 site 에서 호출 — non-blocking 진단 로그 (preflight 통과 후
        // robot/cradle/autoOnboardBrokering state 가 silent failure 위험 있을 때 경고).
        // preflight 차단 사유와 중복 아닌 새 정보 (autoOnboardBrokering off 등) 만 잡힘.
        let onboardWarnings = onboardHealthCheckWarnings()
        for warning in onboardWarnings {
            logSafetyEvent(
                kind: .preflightFailure,
                message: "[onboard 진단] \(warning)"
            )
        }

        // v1.11.24 audit iter2-C — 고급 모드에서 slider 동기화는 preflight 통과 후에만.
        // 종전: tap() 가 start() 호출 전에 loadPresetDefaultsToSliders 호출 → start() 가
        // preflight 차단되면 slider 만 바뀌고 motor task 는 안 바뀜 (UX 불일치).
        if advanced && preset != .idle {
            loadPresetDefaultsToSliders(preset)
        }

        // §3 wiring: session start 시점 snapshot — v2 header 에 그대로 기록.
        imuSourceAtStart = {
            switch imuSource {
            case .sim:   return "sim"
            case .real:  return "real"
            case .stale: return "stale"
            }
        }()
        imuScaleSuspicionAtStart = (store?.imuScaleSuspicion ?? .unknown).rawValue

        // **v1.15.0 (2026-05-21) Phase 1**: Trial 시작 capture — finalize 시 outcome 계산용.
        captureTrialStart(preset: preset)

        current = preset
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)
        footTrail.removeAll()
        footTrailLefts.removeAll()  // v1.14.8.1 parallel cache reset
        simSwayPhase = 0
        balanceLost = false
        thermalAlarm = false
        // v1.11.22.1: emergency flag clear — 새 session 시작 시 exit-phase 허용.
        emergencyStopActive = false
        // 사이클 67: trigger payload 도 cleanup — 다음 emergency 까지 stale 차단.
        _lastEmergencyTrigger = nil
        // v1.8: hysteresis reset — 이전 cycle 잔존 데이터로 false trigger 차단.
        warningStateConsecutiveSamples = 0
        dangerStateConsecutiveSamples = 0
        l3HardGateConsecutiveSamples = 0
        // **Stage 3 (v1.1 fall prevention)**: 새 보행 시작 시 buffer reset —
        // 이전 cycle 의 stale sample 로 score 거짓 발동 방지.
        imuBuffer.removeAll()
        lastBufferPushAt = nil
        fallPrediction = .zero
        balanceState = .normal
        // **Phase D 정정 (Agent 4 P1)**: imu 값도 reset — 이전 cycle 의 stale 28°
        // 가 남아 있으면 첫 tick 에 잘못된 balanceState 발동.
        imuRollDeg = 0
        imuPitchDeg = 0
        imuSource = .sim
        // **2026-05-16**: 모터 온도 source reset — 새 session 의 첫 tick 에서
        // updateMotorTempFromRealOrSim 이 정확한 source 로 갱신.
        motorTempSource = .sim
        // **Phase D 정정 (Agent 4 P2)**: 이전 cycle 결과/preflight failure 도 reset.
        lastPreflightFailure = nil
        lastCycleResult = nil
        // **Stage 4 (v1.1 fall prevention)**: corrector ramp 재시작.
        correctionEnabledAt = enableBalanceCorrection ? Date() : nil
        lastCorrections = nil
        lastSafePose = nil
        // **Monitoring dashboard reset**: 시계열 buffer / 이전 상태 reset.
        // safetyEvents 는 유지 — 사용자가 이전 세션의 이벤트 확인 가능.
        safetyTimeline.removeAll()
        // **v1.14.8 (2026-05-21) perf #6**: normalized 캐시도 동기 reset.
        normalizedSafetyTimeline.removeAll()
        previousBalanceState = .normal
        previousImuSource = .sim
        previousMotorTempSource = .sim
        previousRecommendEmergency = false
        rampCompletedLogged = false
        logSafetyEvent(kind: .sessionStart, message: "보행 시작 — \(preset.label)")
        startTime = Date()

        simTimer?.invalidate()
        // v1.11.2 (2026-05-18): CI Swift 5.9 호환 — Task closure 에 weak self 재캡쳐.
        simTimer = Timer.scheduledTimer(withTimeInterval: tickDtSec, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }

        // 실 보행 cycle 송출 — bus 연결 + cradle 확인 시 WalkMotionLibrary 의
        // 합성 step 시퀀스를 직접 모터에 전송. preset 종료 / cancel 시 walkReady 복귀.
        startWalkCycle(preset)
    }

    /// 진행 중 sim 에 현재 슬라이더/프리셋 값을 재밀어넣는다.
    /// advanced 슬라이더가 움직였을 때 view 측에서 호출.
    public func syncCommandToEngine() {
        // **v1.20.44 사이클 58 — security-auditor CRITICAL fix**:
        // emergencyStopActive 동안 engine 송출 hard-reject. 종전: 모든 호출 (외부 자동화 /
        // slider didSet / 미래 voice path) 이 무조건 engine.setCommand 송출 → emergency 후
        // robot 자동 깨어남 위험.
        // 신규: emergency 상태에서는 setCommand(0,0,0,false) 만 송출하고 즉시 return.
        if emergencyStopActive {
            engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
            return
        }
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)

        guard advanced, isRobotWalking, current != .idle else { return }
        guard stabilityScore.category != .critical else {
            cancelWalkCycle(eventLabel: "고급 슬라이더 위험도 critical — 보행 중단")
            return
        }

        let preset = current
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.advanced,
                  self.isRobotWalking,
                  self.current == preset else { return }
            self.startWalkCycle(preset)
            self.lastRobotEvent = "🤖 고급 슬라이더 반영 — \(preset.label)"
        }
    }

    /// 정지 — 시뮬 멈춤, 기록 누적, 실 보행 cycle cancel + walkReady 복귀.
    public func stop() {
        // **v1.15.0 (2026-05-21) Phase 1**: Trial 종료 hook — capture → Analyzer → Store → label sheet.
        // simTimer invalidate 전에 호출 — sessionLogger 가 아직 살아있을 때 file path 추출.
        finalizeTrialIfPending(endReason: .userStop)

        let wasRunningForHarness = startTime != nil
        let durationForHarness: Double = startTime.map { Date().timeIntervalSince($0) } ?? 0
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        let wasRunning = startTime != nil

        if wasRunningForHarness {
            // v1.12.0 telemetry — 정상 정지.
            Harness.shared.record(
                .walkLabStop, level: .notice, actor: .user,
                data: ["duration_s": AnyCodable(durationForHarness),
                       "preset": AnyCodable(current.label)]
            )
        }
        if let start = startTime {
            history.insert(WalkLabRecord(
                preset: current,
                durationSec: Int(Date().timeIntervalSince(start)),
                endedAt: Date()
            ), at: 0)
            if history.count > 12 { history.removeLast() }
        }
        startTime = nil
        if wasRunning {
            logSafetyEvent(kind: .sessionStop, message: "정상 정지 — \(current.label)")
        }
        current = .idle
        // v1.11.24 audit P1-1 — 실 motor task 가 멈춘 시점에 activeRobotPreset clear.
        activeRobotPreset = nil
        // sway 도 zero 로 디케이 — 다음 tick 에서 매끄럽게 감소.

        // **v1.11.7 (2026-05-18, GPT HIGH-2)** — onboard 모드도 lifecycle 정리.
        // walkingEngine == .robotisOnboard 일 때 walkCycleTask 가 없으므로 별도 cleanup.
        if onboardWalkingActive {
            onboardWalkingActive = false
            onboardAckStatus = nil
            logSafetyEvent(kind: .sessionStop,
                message: "ROBOTIS Onboard 정지 — robot 측 SSH stop 명령 별도 필요")
        }

        // 실 보행 cycle cancel — Task 내부에서 walkReady 복귀 후 종료.
        if wasRunning {
            cancelWalkCycle(eventLabel: "정지 — 직립 자세 복귀")
        }
        // v1.11.24 audit P1-1 — invariant: stop() 후엔 항상 isRobotWalking=false.
        // cancelWalkCycle 은 walkCycleTask 가 nil 이면 reset 안 함 (test/sim 경로).
        isRobotWalking = false
        // 사이클 159 (P0-1 fix): stop() 도 IMU slow polling 복원 — finalize race 회피.
        store?.imuFastPollActive = false
        // v1.11.24 audit iter2-B — 진단 필드 reset. 종전: 다음 session 의 로그 헤더에
        // 이전 session 의 requestedPreset / startBlockedReason 등이 leak.
        motorWriteStarted = false
        motorWriteStepCount = 0
        requestedPreset = nil
        startBlockedReason = nil
        onboardAckStatus = nil
        // v1.11.25 audit-C — stop() 후 highRisk preset 재시작 시 위험 동의 재확인 강제.
        // 종전: emergencyStop 만 reset → 사용자가 jog 동의 → 일반 정지 → 즉시 다시 jog 가능.
        // 매 보행 세션마다 idempotent 동의 위반.
        riskAcknowledged = false
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
    }

    /// 비상 정지 — Stop + risk reset + 실 로봇 토크 OFF.
    ///
    /// **v1.11.25 audit log-G**: trigger 출처 명시. 종전: 모든 emergency Harness 가
    /// actor=.user → 자동 trigger (balance lost / thermal / voltage) 와 사용자 클릭
    /// 구분 불가. 발생률 통계 추출 막힘.
    public func emergencyStop(trigger: EmergencyTrigger = .userClick) {
        // **v1.15.0 (2026-05-21) Phase 1**: Trial 종료 hook — capture → Analyzer → Store → label sheet.
        // trigger 가 fallPredictorRecommend 면 .fallPredictorTriggered, 그 외는 .emergencyStop.
        let trialEndReason: EndReason = (trigger == .fallPredictorRecommend)
            ? .fallPredictorTriggered : .emergencyStop
        finalizeTrialIfPending(endReason: trialEndReason)

        // v1.12.0 telemetry — WalkLab 비상 정지.
        let tiltForHarness = max(abs(imuRollDeg), abs(imuPitchDeg))
        Harness.shared.record(
            .walkLabEmergencyStop, level: .error,
            actor: trigger.harnessActor,
            data: ["tilt_deg": AnyCodable(tiltForHarness),
                   "fall_score": AnyCodable(fallPrediction.score),
                   "preset": AnyCodable(current.label),
                   "trigger_source": AnyCodable(trigger.rawValue)]
        )
        // **v1.11.22.1 (Codex HIGH-1 fix)** — exit-phase race 차단:
        // 0. emergencyStopActive flag 먼저 set → walkCycleTask 의 exit phase 가
        //    walkReady setPosition 시도 전 check 하여 skip. 토크 OFF 이후 명령 무효 보장.
        emergencyStopActive = true
        // **v1.21.2 사이클 67 (코덱스 MEDIUM-3 fix)** — trigger payload 보존.
        // start() root guard 의 .emergencyActive(trigger:) 가 사용자에게 출처 명시.
        _lastEmergencyTrigger = trigger
        // 1. 보행 cycle 즉시 cancel — 모터 송출 중지.
        walkCycleTask?.cancel()
        walkCycleTask = nil
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
        isRobotWalking = false
        // 2. 토크 OFF — 토크 OFF 가 들어가야 임의 모터 명령 잔여를 무력화.
        store?.emergencyStop()
        // 3. 시뮬 정지.
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        // **v1.20.14.1 사이클 20-fix HIGH 2 (코덱스)** — pilot EMA 잔재 hard-zero.
        // 종전: emergencyStop 후 engine.setCommand(0,...) 만 zero, session.strideMm 잔재 →
        // 차후 syncCommandToEngine 가 stale 값 재송출 가능.
        strideMm = 0
        sideMm = 0
        turnDeg = 0
        startTime = nil
        let tilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        logSafetyEvent(
            kind: .emergencyTriggered,
            message: String(format: "비상 정지 — 토크 OFF (tilt %.1f°, score %.0f)",
                            tilt, fallPrediction.score)
        )
        current = .idle
        // v1.11.24 audit P1-1 — 실 motor task 가 멈춘 시점에 activeRobotPreset clear.
        activeRobotPreset = nil
        onboardWalkingActive = false
        onboardAckStatus = nil
        // v1.11.24 audit iter2-B — 진단 필드 reset.
        motorWriteStarted = false
        motorWriteStepCount = 0
        requestedPreset = nil
        startBlockedReason = nil
        riskAcknowledged = false
        balanceLost = false
        lastRobotEvent = "🛑 토크 OFF — 비상 정지"
        // 온도는 그대로 — 사용자가 확인 후 자연 냉각.
    }

    /// 실 로봇에 정적 자세 송출. bus 미연결 / cradle 미확인 / cancelled 시 skip.
    /// 단발 자세 송출. 반복 보행은 `startWalkCycle` 경로가 담당.
    private func sendRobotPose(_ pose: RobotPose, eventLabel: String) {
        guard let store = store, store.bus != nil else {
            lastRobotEvent = "ℹ️ 시뮬 모드 — 로봇 미연결 (\(eventLabel))"
            return
        }
        guard cradleConfirmed else {
            lastRobotEvent = "⚠️ cradle 미확인 — 실 송출 차단"
            return
        }
        lastRobotEvent = "🤖 \(eventLabel)"
        Task { @MainActor in
            await store.applyPoseSmoothly(pose)
        }
    }

    // MARK: - 실 보행 cycle 송출 (Sprint 16+)

    /// `WalkMotionLibrary` 의 합성 step 시퀀스를 모터에 직접 송출 시작.
    ///
    /// **Codex P0 fix (2026-05-13 3차)**:
    /// - cycle 시작 전 preflight (bus / cradle / dxl_power / 하체 토크) 강제 확인.
    /// - 하체 토크 1개라도 실패면 cycle 차단 (silent failure 방지).
    /// - runWalkCycle 가 `WalkCycleResult` 반환 — cycle 종료 사유 사용자에게 표시.
    ///
    /// 이전 task 가 있으면 cancel + 완료 대기 후 새 cycle 시작 — preset 전환 race 방지.
    private func startWalkCycle(_ preset: WalkLabPreset) {
        // **v1.11.8 (2026-05-18) — HIGH-3 fix**: 보행 중 다중 진입 차단.
        if walkCycleTask != nil || onboardWalkingActive {
            lastRobotEvent = "⚠️ 보행 진행 중 — 정지(■) 후 다시 시도하세요 (\(preset.label))"
            // v1.12.2 (Codex P1-5) — 실 cycle 시작 거부도 telemetry.
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable("alreadyWalking")]
            )
            return
        }

        guard let store = store, let bus = store.bus else {
            let f = WalkPreflightFailure(cause: .noConnection)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = "🛑 시뮬레이션만 — 로봇 미연결. \(preset.label) 보행 신호는 송출 안 됨. 사이드바에서 연결 후 재시도"
            // v1.12.2 (Codex P1-5) — quickPreflight 통과 후라도 race 로 bus 가 사라진
            // 시점 추적용. 사용자가 "preflight 통과인데 왜 모터 안 움직이지?" 답 가능.
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable("noConnectionRace")]
            )
            return
        }
        guard cradleConfirmed else {
            let f = WalkPreflightFailure(cause: .cradleNotConfirmed)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable("cradleNotConfirmedRace")]
            )
            return
        }

        // **v1.12.2 (Codex P1-5 + re-review fix)** — walkLabStart 는 모든 guard
        // 통과 후 실 motor command issue 직전에 발행. 아래 guard 들은 각자 별도로
        // walkLabStartBlocked 발행.

        // **v1.11.3 (2026-05-18) — 보행 시작 진입 가드**: safetyVerdict 가 .blocked 면
        // applyToRobot 강등 후 진행. 의도: didSet 는 config 변경 시점에만 작동 → 보행
        // 시작 시점에 다시 한 번 확인. 사용자가 didSet 우회 경로 (test fixture, 직렬화
        // 복원 등) 로 위험 config 가 살아남는 케이스 차단. 보행 자체는 진행 (사용자
        // 의도 보존) — 단지 robot 송출 차단.
        if case .blocked(let reason) = balanceExperimentConfig.safetyVerdict,
           balanceExperimentConfig.applyToRobot {
            logSafetyEvent(
                kind: .correctorOff,
                message: "보행 시작 시 안전 차단: \(reason)"
            )
            // **v1.11.5.2 (2026-05-18, Codex Med #4 fix)**: pitchInputConvention 보존 추가.
            balanceExperimentConfig = BalanceExperimentConfig(
                algorithmMode: balanceExperimentConfig.algorithmMode,
                signConvention: balanceExperimentConfig.signConvention,
                gainProfile: balanceExperimentConfig.gainProfile,
                applyToRobot: false,
                pitchInputConvention: balanceExperimentConfig.pitchInputConvention
            )
        }

        // 2026-05-17 사용자 보고 critical fix: caution 등급 (fastWalk/turnLeft/turnRight)
        // 은 정적 plan + IMU balance 미활성 시 실 robot 낙상 위험. WalkStabilityPredictor
        // 는 사전 휴리스틱일 뿐 실시간 IMU 기반 자세 보정 없음. balanceCorrection 자동
        // OFF 이면 사용자가 명시 ON 후 재시작 요구.
        if preset.safety == .caution, !enableBalanceCorrection {
            let f = WalkPreflightFailure(cause: .balanceCorrectorRequiredForCautionPreset(presetLabel: preset.label))
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = f.userMessage
            // v1.12.2 (Codex re-review fix) — start_blocked 발행.
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode)]
            )
            return
        }

        // Preflight — dxl_power ON + 모든 토크 ON. 하체 1개라도 실패면 차단.
        if let failure = preflightForWalkCycle(bus: bus) {
            lastPreflightFailure = failure
            startBlockedReason = failure.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = failure.userMessage + " (\(preset.label))"
            Harness.shared.record(
                .walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(failure.diagnosticCode)]
            )
            return
        }

        // **v1.11.22.1 (Codex HIGH-2 fix)** — 실 robot 보행 시작 전 IMU live + plausible:
        //   - bus 있는데 IMU 한 번도 안 옴 → 차단 (gate L3/corrector 모두 무력화 위험)
        //   - IMU stale (5s+ 지연) → 차단
        //   - imuScaleSuspicion suspectedLegacy10Bit/outOfRange → 차단 (1g 감지 실패)
        // 정상 보행 시 fall prevention chain (L3 hard gate, corrector) 의 데이터 의존성
        // 확보. 정합 안 되면 실 robot 송출 자체 금지.
        if store.isImuUnavailable {
            let f = WalkPreflightFailure(cause: .imuUnavailable)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            logSafetyEvent(kind: .preflightFailure,
                           message: "보행 차단 — IMU unavailable (bus 연결 후 sample 없음)")
            Harness.shared.record(.walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode)])
            return
        }
        if store.isImuStale {
            let f = WalkPreflightFailure(cause: .imuStale)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            logSafetyEvent(kind: .preflightFailure,
                           message: "보행 차단 — IMU stale (5초+ 지연)")
            Harness.shared.record(.walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode)])
            return
        }
        if store.imuScaleSuspicion == .suspectedLegacy10Bit
            || store.imuScaleSuspicion == .outOfRange {
            let f = WalkPreflightFailure(cause: .imuPlausibilityFailed(store.imuScaleSuspicion.rawValue))
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            logSafetyEvent(kind: .preflightFailure,
                           message: "보행 차단 — IMU plausibility \(store.imuScaleSuspicion.rawValue)")
            Harness.shared.record(.walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode),
                       "imu_scale": AnyCodable(store.imuScaleSuspicion.rawValue)])
            return
        }
        lastPreflightFailure = nil
        startBlockedReason = nil

        // **v1.12.2 (Codex re-review fix)** — 모든 free + race + safety guard 통과.
        // 이 시점에 walkLabStart 발행 (단, onboard 경로면 SSH/brokering guard 가
        // 한 번 더 차단 가능 — 그 경로는 자체 start_blocked 발행). idle preset 은
        // sendRobotPose(.walkReady) 만 하므로 보행 이벤트가 아님 → 아래 idle branch 가
        // 먼저 분기되도록 walkLabStart 는 그 다음 단계 (실 cycle task 시작 직전) 로.

        // **Phase G10 (2026-05-15)**: 보행 모드 분기.
        //   - 연속 보행 가능 preset (march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight)
        //     → continuousWalkPlan + runContinuousWalk (entry → 무한 cycle → exit).
        //     매 cycle 끝마다 walkReady 자세로 돌아가지 않음 → 자연스러운 보행.
        //   - jog → page(for:tuning:) + runWalkCycle(loop=false) (기존 동작 — kick chain).
        //   - idle → 정적 walkReady.
        let prev = walkCycleTask
        prev?.cancel()
        let presetLabel = preset.label
        let maxDurationSec = preset.maxDurationSec
        let lowerBody = Self.lowerBodyJoints

        if preset == .idle {
            sendRobotPose(.walkReady, eventLabel: "보행 anchor — \(presetLabel)")
            // idle 은 static anchor — walking 이벤트 발행 안 함 (사용자는 정지/대기로 인식).
            return
        }

        // **v1.11.5 (2026-05-18) — ROBOTIS Onboard 모드 분기**:
        // walkingEngine == .robotisOnboard 면 Mac sparse keyframe 합성 + setPosition
        // 송출 경로 완전 우회. 사용자가 별도 UI 토글로 robot-side demo-pilot 활성화한
        // 상태라 가정. WalkLabSession 은 currentWalkingEngineCommand() 만 published —
        // 외부 component (예: WalkLabOnboardBridge) 가 RemoteShell 통해 SSH brokering.
        //
        // **v1.11.7 (2026-05-18, GPT HIGH-2 fix)** — lifecycle 명시:
        // - onboardWalkingActive=true 로 UI/log 가 "robot 측 active" 인식
        // - safety event 로깅
        // - cycleStartedAt 갱신 (UI 경과 시간 동기)
        // - autoOnboardBrokering ON 이면 WalkLabOnboardBridge 가 첫 명령 자동 송출
        if walkingEngine == .robotisOnboard {
            // **v1.11.24 (2026-05-20) audit P1-3 — health-check 를 hard block 으로 강화**:
            //
            // 종전: warning 만 — `onboardWalkingActive=true` 를 무조건 set → 사용자는 UI 상
            //       "active" 로 보지만 robot 은 가만히 있음 (silent fail).
            // 현재: SSH 미연결 또는 autoOnboardBrokering=false 면 명시적으로 차단 + 사유 표시.
            //       사용자가 SSH 연결 / 토글 ON 후 재시도 강제.
            //
            // (실제 ACK 검증은 첫 명령 송출 후 WalkLabOnboardBridge 가 onboardAckStatus 에
            //  결과 기록 — 본 시점에는 precondition 만 검사.)
            // 이 시점에서 store 는 위쪽 guard let 로 이미 unwrap. bus != nil 도 보장.
            // (실 environment 에서는 noConnection branch 가 이미 차단)
            let isSshConnected = (store.bus != nil)
            if !isSshConnected {
                let f = WalkPreflightFailure(cause: .onboardSshNotConnected)
                lastPreflightFailure = f
                lastRobotEvent = f.userMessage + " (\(presetLabel))"
                startBlockedReason = f.diagnosticCode
                logSafetyEvent(kind: .preflightFailure,
                               message: "Onboard 시작 차단 — SSH 미연결")
                Harness.shared.record(.walkLabStartBlocked, level: .warn, actor: .user,
                    data: ["requested_preset": AnyCodable(presetLabel),
                           "reason": AnyCodable(f.diagnosticCode)])
                return
            }
            if !autoOnboardBrokering {
                let f = WalkPreflightFailure(cause: .onboardAutoBrokeringOff)
                lastPreflightFailure = f
                lastRobotEvent = f.userMessage + " (\(presetLabel))"
                startBlockedReason = f.diagnosticCode
                logSafetyEvent(kind: .preflightFailure,
                               message: "Onboard 시작 차단 — autoOnboardBrokering OFF")
                Harness.shared.record(.walkLabStartBlocked, level: .warn, actor: .user,
                    data: ["requested_preset": AnyCodable(presetLabel),
                           "reason": AnyCodable(f.diagnosticCode)])
                return
            }
            // precheck 통과 — onboard cycle 활성. ACK 는 bridge 가 별도 trace.
            // v1.12.2 (Codex re-review fix) — onboard 도 실제 cycle 시작 시점에 발행.
            Harness.shared.record(
                .walkLabStart, level: .notice, actor: .user,
                data: ["preset": AnyCodable(presetLabel),
                       "engine": AnyCodable("robotisOnboard"),
                       "advanced": AnyCodable(advanced)]
            )
            onboardWalkingActive = true
            // 사이클 159 (P0-1 fix): onboard mode 도 IMU fast polling — robot 측 보정 외에도
            // Mac UI 의 LiveGyroPanel / FallPredictor 가 빠르게 반응. 단 Mac 보정은 미적용.
            store.imuFastPollActive = true
            activeRobotPreset = preset
            motorWriteStarted = false        // bridge 가 ACK ok 도착 시 set
            motorWriteStepCount = 0
            onboardAckStatus = "pending"     // ACK 도착하면 "ok" / "no_ack" 갱신
            cycleStartedAt = Date()
            logSafetyEvent(
                kind: .correctorOn,
                message: "ROBOTIS Onboard 시작: \(presetLabel) (Mac sparse 우회). brokering 자동"
            )
            lastRobotEvent = "▶ ROBOTIS Onboard: \(presetLabel) — Mac sparse 우회, 자동 brokering 활성"
            return
        }

        // v1.9 (2026-05-17 사용자 요청): 보행 session logging 시작.
        // autoTuner 의 권고 level 자동 적용 (autoApplyEnabled 시).
        // **v1.11.1 (2026-05-18 사용자 review HIGH-2) — 실 robot 자동 적용 차단**:
        // applyMode == "robotApplied" (실 모터 송출) 일 때 자동 튜닝 자동 적용 차단.
        // 이유: WalkSessionAnalyzer 의 데이터 품질 검증이 v2 quality analyzer 수준에
        // 도달 전 (IMU duplicate ratio / stale ratio / 독립 sample 수 정밀 미검증).
        // observeOnly / simOnly / off 모드에서는 안전 — pose 변경 없음.
        // 사용자가 autoApplyEnabled=true 토글했어도 실 적용 mode 면 무시.
        let appliedLevel: Int
        if correctionApplyMode == "robotApplied" && autoTuner.autoApplyEnabled {
            appliedLevel = correctorIntensityLevel
            logSafetyEvent(
                kind: .correctorOn,
                message: "자동 튜닝 차단: 실 robot 적용 모드 — 수동 강도 유지 (\(Self.intensityLabel(level: correctorIntensityLevel)))"
            )
        } else {
            appliedLevel = autoTuner.levelToApply(currentLevel: correctorIntensityLevel)
        }
        if appliedLevel != correctorIntensityLevel {
            correctorIntensityLevel = appliedLevel
            lastRobotEvent = "🧠 자동 튜닝: 보정 강도 \(WalkLabSession.intensityLabel(level: appliedLevel)) 적용"
        }
        // **v1.11 (Codex 2nd review MEDIUM-B fix)**: cycleStartedAt 은 logging 여부와
        // 무관하게 walk start 시 항상 set. 종전엔 logger init 안에 있어서, logging OFF
        // 또는 logger throw 시 Hybrid phase=0 / P-control walkPhase01=nil.
        cycleStartedAt = Date()

        if enableSessionLogging {
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
            do {
                // **v1.11 (Codex 2026-05-18 HIGH-2)**: handoff §3 5+3 필드를 헤더로 전달.
                sessionLogger = try WalkSessionLogger(
                    preset: preset.rawValue,
                    intensityLevel: correctorIntensityLevel,
                    appVersion: appVersion,
                    isRealRobot: true,  // startWalkCycle 안에서는 이미 bus guard 통과.
                    balanceAlgorithmMode: balanceAlgorithmMode,
                    balanceSignConvention: balanceSignConvention,
                    balanceGainProfile: balanceGainProfile,
                    correctionApplyMode: correctionApplyMode,
                    imuSourceAtStart: imuSourceAtStart,
                    imuScaleSuspicionAtStart: imuScaleSuspicionAtStart,
                    operatorNoteAtStart: operatorNote,
                    comparisonTag: comparisonTag,
                    // v1.11.10 V2 — 8 axis + tuning + experiment context
                    walkingEngine: walkingEngine.rawValue,
                    pitchInputConvention: balanceExperimentConfig.pitchInputConvention.rawValue,
                    enableBalanceCorrectionAtStart: enableBalanceCorrection,
                    autoOnboardBrokeringAtStart: autoOnboardBrokering,
                    hipPitchOffsetTrimDegAtStart: hipPitchOffsetTrimDeg,
                    tuningStrideMm: advanced ? strideMm : nil,
                    tuningSideMm: advanced ? sideMm : nil,
                    tuningTurnDeg: advanced ? turnDeg : nil,
                    tuningPeriodMs: advanced ? customPeriodMs : nil,
                    tuningFootHeightMm: advanced ? footHeightMm : nil,
                    tuningBalanceGain: advanced ? balanceGain : nil,
                    customGainHipRoll: balanceExperimentConfig.gainProfile == .custom ? customHipRollGain : nil,
                    customGainKnee: balanceExperimentConfig.gainProfile == .custom ? customKneeGain : nil,
                    customGainAnklePitch: balanceExperimentConfig.gainProfile == .custom ? customAnklePitchGain : nil,
                    customGainAnkleRoll: balanceExperimentConfig.gainProfile == .custom ? customAnkleRollGain : nil,
                    robotModel: "DARwIn-OP2",
                    // v1.11.14: 실험 컨텍스트 — applyExperimentChange 후 활성.
                    experimentId: activeExperimentId,
                    baselineSessionId: activeBaselineSessionId,
                    // v1.11.24 audit P1-2 — start diagnostic snapshot.
                    requestedPreset: requestedPreset?.rawValue,
                    startBlockedReason: startBlockedReason,
                    walkCycleTaskActiveAtStart: walkCycleTask != nil,
                    lastRobotEventAtStart: lastRobotEvent
                )
                // v1.9.2: Logger 의 startedAt 과 sync — summary.id 와 jsonl filename
                // 일치 보장. 종전: 별도 Date() → 3ms drift → matching 실패.
                sessionStartedAt = sessionLogger?.startedAt
            } catch {
                // logging 실패 시 silent (보행 자체는 진행).
                sessionLogger = nil
            }
        }

        // Phase G11 — 3D 모델 동기화 closure. weak self 로 retain cycle 회피.
        // v1.11.24 audit P1-2 — motor write counter. 첫 호출 시 motorWriteStarted=true,
        // 이후 호출마다 step count 증가. preflight 통과했지만 실 write 가 0 인 케이스
        // (예: bus 즉시 끊김) 를 사후 진단 가능.
        let onPose: @MainActor @Sendable (RobotPose) -> Void = { [weak self] pose in
            guard let self else { return }
            self.visualPose = pose
            if !self.motorWriteStarted { self.motorWriteStarted = true }
            self.motorWriteStepCount &+= 1
        }

        // **Stage 4b (v1.1 fall prevention)**: 실 motor 송출 경로에 corrector wire.
        // `enableBalanceCorrection = true` 시 매 step pose 에 IMU 기반 보정 적용.
        // default false (사용자 토글 ON 후 활성).
        let transformPose: @MainActor @Sendable (RobotPose) -> RobotPose = { [weak self] pose in
            self?.applyBalanceCorrectionIfEnabled(to: pose) ?? pose
        }

        // 연속 보행 plan 시도.
        if let plan = WalkMotionLibrary.continuousWalkPlan(for: preset, tuning: currentWalkTuning()) {
            isRobotWalking = true
            // 사이클 159 (P0-1 fix): 실 robot 송출 path → IMU fast polling (50ms = 20Hz).
            // freshness gate (250ms) 와 4 step 마진. stop 시 finalize 에서 false 복원.
            store.imuFastPollActive = true
            // v1.11.24 audit P1-1 — 실 motor task 시작 시점에 activeRobotPreset 갱신.
            // 로거 sample.preset 은 이 값을 우선 → 보행 중 사용자가 다른 preset 클릭해도
            // 실 task 가 안 바뀌면 로그는 변경 전 preset 유지.
            activeRobotPreset = preset
            motorWriteStarted = false
            motorWriteStepCount = 0
            lastRobotEvent = "🤖 연속 보행 시작 — \(presetLabel)"
            // v1.12.2 (Codex re-review fix) — 실 motor task spawn 직전. 모든 guard pass.
            Harness.shared.record(
                .walkLabStart, level: .notice, actor: .user,
                data: ["preset": AnyCodable(presetLabel),
                       "engine": AnyCodable(String(describing: walkingEngine)),
                       "advanced": AnyCodable(advanced),
                       "mode": AnyCodable("continuous")]
            )
            // 2026-05-17 chaos #1: weak store capture — Task 내부에서 매 step 마다
            // store?.bus !== nil 확인 가능. 종전엔 bus strong capture 로 dead handle
            // 송출 ~5 step 지속.
            // v1.11.2 (2026-05-18): CI Swift 5.9 strict concurrency 호환 — outer
            // `weak store = self.store` 가 inner closure 에서 var-like 로 재캡쳐되어
            // error. `[weak self]` 만 캡쳐하고 inner 가 self?.store 통해 access.
            walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
                await prev?.value
                let result = await Self.runContinuousWalk(
                    bus: bus, plan: plan,
                    maxDurationSec: maxDurationSec,
                    lowerBodyJoints: lowerBody,
                    onPose: onPose,
                    transformPose: transformPose,
                    isBusAlive: { [weak self] in
                        guard let self else { return false }
                        return await self.isBusAliveSnapshot()
                    },
                    // v1.11.22.1 (Codex HIGH-1 fix): emergencyStop 시 exit phase 스킵.
                    isHardStopped: { [weak self] in
                        guard let self else { return true }
                        return await MainActor.run { self.emergencyStopActive }
                    },
                    // v1.11.1 MEDIUM-5: bus write 실패 시 ConnectionStore counter 누적.
                    onBusWriteFailure: { [weak self] in
                        self?.store?._bumpBusWriteFailureCount()
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRobotWalking = false
                    // 사이클 159 (P0-1 fix): walk 종료 → IMU slow polling 복원 (perf).
                    self.store?.imuFastPollActive = false
                    // v1.11.24 audit P1-1 — cycle 정상/비정상 종료 시 활성 preset clear.
                    self.activeRobotPreset = nil
                    self.lastCycleResult = result
                    if result.isSuccess {
                        self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                    } else {
                        self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                    }
                    self.finalizeSessionLog()
                }
            }
            return
        }

        // jog (kick chain) — 단발 page + oneShot.
        guard let page = WalkMotionLibrary.page(for: preset, tuning: currentWalkTuning()) else {
            sendRobotPose(.walkReady, eventLabel: "보행 anchor — \(presetLabel)")
            return
        }
        isRobotWalking = true
        // 사이클 159 (P0-1 fix): jog kick chain 도 IMU fast polling 활성.
        store.imuFastPollActive = true
        // v1.11.24 audit P1-1 — jog 같은 single-page cycle 도 동일.
        activeRobotPreset = preset
        motorWriteStarted = false
        motorWriteStepCount = 0
        lastRobotEvent = "🤖 보행 cycle 송출 시작 — \(presetLabel)"
        // v1.12.2 (Codex re-review fix) — single-cycle 도 실 task spawn 직전.
        Harness.shared.record(
            .walkLabStart, level: .notice, actor: .user,
            data: ["preset": AnyCodable(presetLabel),
                   "engine": AnyCodable(String(describing: walkingEngine)),
                   "advanced": AnyCodable(advanced),
                   "mode": AnyCodable("kickChain")]
        )
        // v1.11.2 (2026-05-18): CI Swift 5.9 strict concurrency 호환 (line 960 와 동일).
        walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await prev?.value
            let result = await Self.runWalkCycle(
                bus: bus, page: page,
                maxDurationSec: maxDurationSec,
                lowerBodyJoints: lowerBody,
                loop: false,   // jog 는 kick chain 끝나면 종료.
                onPose: onPose,
                transformPose: transformPose,
                isBusAlive: { [weak self] in
                    guard let self else { return false }
                    return await self.isBusAliveSnapshot()
                },
                // v1.11.22.1 (Codex HIGH-1 fix): emergencyStop 시 walkReady 복귀 스킵.
                isHardStopped: { [weak self] in
                    guard let self else { return true }
                    return await MainActor.run { self.emergencyStopActive }
                },
                // v1.11.1 MEDIUM-5: bus write 실패 시 ConnectionStore counter 누적.
                onBusWriteFailure: { [weak self] in
                    self?.store?._bumpBusWriteFailureCount()
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRobotWalking = false
                // 사이클 159 (P0-1 fix): jog 종료 → IMU slow polling 복원.
                self.store?.imuFastPollActive = false
                // v1.11.24 audit iter3-A — jog 단발 cycle 도 cleanup 일치.
                self.activeRobotPreset = nil
                self.lastCycleResult = result
                if result.isSuccess {
                    self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                } else {
                    self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                }
                // v1.11.24 audit iter3-A — finalize log for natural jog completion
                // (loop=false → kick chain 끝나면 외부 stop() 없어도 cycle 종료).
                self.finalizeSessionLog()
            }
        }
    }

    private func currentWalkTuning() -> WalkMotionLibrary.AdvancedTuning? {
        // **v1.11.4 (2026-05-18)** — hipPitchOffsetTrimDeg 가 default (13°) 와 다르면
        // advanced=false 여도 trim 만은 적용. 사용자가 cradle 캘리브레이션 중 13/5/0°
        // 비교를 advanced disclosure 펴지 않고도 가능하게.
        let trimDefault = 13.0
        if !advanced && abs(hipPitchOffsetTrimDeg - trimDefault) < 0.01 {
            return nil
        }
        return WalkMotionLibrary.AdvancedTuning(
            strideMm: advanced ? strideMm : WalkMotionLibrary.defaultTuning(for: current).strideMm,
            sideMm: advanced ? sideMm : WalkMotionLibrary.defaultTuning(for: current).sideMm,
            turnDeg: advanced ? turnDeg : WalkMotionLibrary.defaultTuning(for: current).turnDeg,
            periodMs: advanced ? customPeriodMs : WalkMotionLibrary.defaultTuning(for: current).periodMs,
            footHeightMm: advanced ? footHeightMm : WalkMotionLibrary.defaultTuning(for: current).footHeightMm,
            balanceGain: advanced ? balanceGain : WalkMotionLibrary.defaultTuning(for: current).balanceGain,
            hipPitchOffsetDeg: hipPitchOffsetTrimDeg
        )
    }

    /// **v1.11.4 (2026-05-18)** — hipPitchOffset trim slider 값 (UI 노출).
    /// 0~20°, default 13° (ROBOTIS Walking.cpp 원본).
    /// 사용자가 cradle 캘리브레이션 중 0/5/13° 비교해서 mean pitch bias 측정 가능.
    public var hipPitchOffsetTrimDeg: Double = 13.0

    /// **v1.11.6 (2026-05-18)** — `.robotisOnboard` 모드의 자동 brokering 토글.
    /// true 면 preset / tuning 변경 시 `WalkLabOnboardBridge` 가 300ms debounce 후
    /// 자동으로 RemoteShell.send 호출. default OFF — 안전상 사용자가 명시 ON.
    /// v1.11.25 audit log-F — toggle 변경 시점 영구 기록.
    public var autoOnboardBrokering: Bool = false {
        didSet {
            guard autoOnboardBrokering != oldValue else { return }
            logSafetyEvent(
                kind: .stateChange,
                message: "자동 onboard brokering: \(autoOnboardBrokering ? "OFF→ON" : "ON→OFF")"
            )
            Harness.shared.record(
                .walkLabConfigChange, level: .info, actor: .user,
                data: ["field": AnyCodable("autoOnboardBrokering"),
                       "new_value": AnyCodable(autoOnboardBrokering)]
            )
        }
    }

    /// **v1.11.14 (2026-05-19)** — A/B 실험 컨텍스트 (사용자 명시 승인 후 set).
    /// `nil` = 일반 보행 (실험 X). Logger header 의 experimentId/baselineSessionId 로 기록.
    ///
    /// **사이클 97 (god object Phase 2)**: experiment system method/type 은
    /// `WalkLabSession+Experiment.swift` 로 이동. stored property 는 본체 잔존 (Swift 제약).
    public var activeExperimentId: String? = nil
    public var activeBaselineSessionId: String? = nil

    /// **v1.11.14**: ExperimentLoopController weak ref — 세션 종료 시 자동 폐루프.
    /// RootView 가 setExperimentLoop(_:) 로 inject. weak 라 actor lifecycle 의존성 없음.
    /// `@Published` 와 `weak` 호환 불가 — 단일 set 만 일어나므로 non-published 로 둠.
    public weak var experimentLoop: ExperimentLoopController? = nil

    /// rollback 용 snapshot. applyExperimentChange 가 set, rollbackExperiment 또는
    /// clearExperimentContext 가 clear.
    ///
    /// **사이클 97**: `private(set)` → `internal(set)` 격상 — extension 의 write 허용
    /// + 외부 API 는 read-only 유지.
    public internal(set) var rollbackSnapshot: ExperimentSnapshot? = nil

    // MARK: - Experiment system (moved to WalkLabSession+Experiment.swift in 사이클 97)
    // ExperimentDeltas / ExperimentSnapshot / ApplyExperimentResult / setExperimentLoop /
    // applyExperimentChange / clearExperimentContext / onboardHealthCheckWarnings* /
    // rollbackExperiment — 모두 WalkLabSession+Experiment.swift 잔존.

    /// **v1.11.7 (2026-05-18, GPT HIGH-2)** — ROBOTIS onboard 모드 활성 상태.
    /// startWalkCycle 진입 시 onboard 분기에서 true, stop / cancelWalkCycle 시 false.
    /// UI 가 이 값으로 "robot 측에서 보행 중" 표시 가능.
    /// Mac sparse 의 walkCycleTask 와 별개 — onboard 는 SSH brokering 으로만 동작.
    public private(set) var onboardWalkingActive: Bool = false

    /// **v1.11.16.1 (2026-05-19)** — Onboard health indicator state.
    /// Bridge 가 send/ping 결과를 set. UI (OnboardHealthIndicator) 가 시각 표시.
    public internal(set) var onboardLastAckAt: Date? = nil
    public internal(set) var onboardLastError: String? = nil
    public internal(set) var onboardConsecutiveFailures: Int = 0
    /// daemon 응답이 "NO_ACK" 이면 firmware 미패치 가능성.
    public internal(set) var onboardDaemonMissing: Bool = false

    /// **v1.11.6 (2026-05-18)** — `.custom` gainProfile 의 사용자 지정 gain 값.
    /// gainProfile == .custom 일 때만 makeCorrector 가 이 값들을 적용.
    /// 종전 (v1.11.5.2 이하) `.custom` 은 robotisOriginal fallback — UI 라벨과 동작 불일치.
    /// default: robotisOriginal 값 (사용자가 명시 변경해야 effect).
    public var customHipRollGain: Double = 0.5 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }
    public var customKneeGain: Double = 0.3 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }
    public var customAnklePitchGain: Double = 0.9 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }
    public var customAnkleRollGain: Double = 1.0 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }

    /// custom gain 변경 시 corrector 재생성 (gainProfile == .custom 일 때만).
    private func rebuildCorrectorIfCustomChanged() {
        guard balanceExperimentConfig.gainProfile == .custom else { return }
        let forceHybrid: Bool? = {
            switch balanceExperimentConfig.algorithmMode {
            case .hybridBA:        return true
            case .robotisPControl: return false
            case .off:             return false
            case .observeOnly:     return nil
            }
        }()
        balanceCorrector = Self.makeCorrector(
            level: correctorIntensityLevel,
            gainProfile: .custom,
            forceHybrid: forceHybrid,
            customHipRollGain: customHipRollGain,
            customKneeGain: customKneeGain,
            customAnklePitchGain: customAnklePitchGain,
            customAnkleRollGain: customAnkleRollGain
        )
    }

    /// **v1.11.5 (2026-05-18)** — 보행 엔진 선택 axis.
    /// `.macSparseKeyframe` (default) = 기존 6 phase 합성 + setPosition 순차.
    /// `.robotisOnboard` = robot-side `Walking::GetInstance()` 사용 (안정 보행, patch 필요).
    public var walkingEngine: WalkingEngine = .macSparseKeyframe {
        didSet {
            guard walkingEngine != oldValue else { return }
            // **v1.11.8 (2026-05-18) — HIGH-2 fix**: 엔진 전환 시 onboardWalkingActive
            // 도 reset. 종전엔 사용자가 `.robotisOnboard` 활성 후 `.macSparseKeyframe`
            // 로 전환해도 onboardWalkingActive=true 유지 → UI stale 표시.
            //
            // **v1.11.24 (2026-05-20) audit iter3-C** — 엔진 전환은 보행 중단을 의미.
            // 종전엔 onboardWalkingActive 만 reset → walkCycleTask 가 그대로 돌아 mixed-engine
            // 모터 송출이 발생할 수 있음. 안전 measure: 보행 중인 경우 stop() 호출로
            // 모든 cleanup 정렬 (walkCycleTask cancel + activeRobotPreset 클리어 + sample log finalize).
            // **사이클 61**: 중복 술어 → `isActuallyWalking` 단일 source 로 위임.
            let wasWalking = isActuallyWalking
            if walkingEngine != .robotisOnboard, onboardWalkingActive {
                onboardWalkingActive = false
                onboardAckStatus = nil
            }
            if wasWalking {
                stop()  // 모든 cleanup invariant 일괄 적용
                lastRobotEvent = "🔁 엔진 전환 \(oldValue.shortLabel) → \(walkingEngine.shortLabel) — 보행 자동 정지 (안전)"
            }
            // v1.11.25 audit log-D — kind 재사용 제거 (engineSwitched 전용 case).
            logSafetyEvent(
                kind: .engineSwitched,
                message: "보행 엔진: \(oldValue.shortLabel) → \(walkingEngine.shortLabel)"
            )
        }
    }

    /// 현재 preset + tuning 으로부터 ROBOTIS onboard 모드의 명령 패킷 생성.
    /// 사용자 UI 가 `RemoteShell` 통해 robot 에 SSH write 할 때 사용.
    ///
    /// **v1.11.5.2 (2026-05-18)**: `hipPitchOffsetDeg` 필드 추가. 종전 누락으로
    /// `.robotisOnboard` 모드에서 trim slider 변경이 robot 에 전달 안 되던 버그 fix.
    public func currentWalkingEngineCommand(enabled: Bool) -> WalkingEngineCommand {
        let tuning = currentWalkTuning() ?? WalkMotionLibrary.defaultTuning(for: current)
        return WalkingEngineCommand(
            enabled: enabled && current != .idle,
            xMm: tuning.strideMm,
            yMm: tuning.sideMm,
            aDeg: tuning.turnDeg,
            periodMs: tuning.periodMs,
            footHeightMm: tuning.footHeightMm,
            hipPitchOffsetDeg: tuning.hipPitchOffsetDeg
        )
    }

    // MARK: - Preflight (사이클 112 Phase 10 — extension 이동)
    //
    // `quickPreflight(for:)` (~67 line) 은 `WalkLabSession+Preflight.swift` 로 이동.
    // 호출 site `start(preset:)` 동일. 격상 0 — 모든 dependent 이미 internal 이상.

    /// v1.11.25 audit-D — thermal cool-down 진행 중 flag.
    /// 60°C 도달 시 true → maxMotorTemp 가 thermalCooldownExitTemp 미만 도달까지 유지.
    public private(set) var thermalCoolDownRequired: Bool = false
    /// cool-down 종료 임계 (°C). 60°C 알람 후 50°C 미만까지 보행 차단.
    public static let thermalCooldownExitTemp: Double = 50.0

    /// v1.11.24 audit P0-4 — 고급 모드에서 preset 클릭 시 슬라이더를 preset 기본값으로 로드.
    ///
    /// 종전 UX 함정: advanced ON 에서 사용자가 `turnLeft` 클릭 → 슬라이더 `turnDeg=0` 그대로
    /// → preset 이름은 turnLeft 인데 실제 명령은 turn 없음 (audit §4 표).
    ///
    /// 수정: `tap(preset)` 에서 advanced 면 본 함수 호출 → 슬라이더 = preset 기본값 + 시작.
    /// sideMm 만 항상 0 으로 reset (preset 들은 side step 없음).
    public func loadPresetDefaultsToSliders(_ preset: WalkLabPreset) {
        let tuning = WalkMotionLibrary.defaultTuning(for: preset)
        strideMm = tuning.strideMm
        turnDeg = tuning.turnDeg
        customPeriodMs = Double(tuning.periodMs)
        footHeightMm = tuning.footHeightMm
        balanceGain = tuning.balanceGain
        sideMm = 0
        // **v1.14.2 (2026-05-21)** — preset 슬라이더 기본값 적용 telemetry.
        // 사용자 의도 추적 — "어떤 preset 의 기본 튜닝을 가져왔는가".
        Harness.shared.record(
            .walkLabPresetApplied, level: .info, actor: .user,
            data: ["preset": AnyCodable(preset.label),
                   "stride_mm": AnyCodable(strideMm),
                   "turn_deg": AnyCodable(turnDeg),
                   "period_ms": AnyCodable(customPeriodMs),
                   "foot_height_mm": AnyCodable(footHeightMm),
                   "balance_gain": AnyCodable(balanceGain)]
        )
    }

    /// v1.11.24 audit iter2-E — onboard 수동 송출 (`WalkingEnginePicker` "현재 명령 송출"
    /// 버튼) 차단 사유. nil = 송출 허용.
    ///
    /// 종전: 버튼이 onSendCommand 콜백만 보고 disabled → cradle 미확인 / caution preset +
    /// 보정 OFF / SSH 미연결 모두 송출 허용 → P0-3 의 보호를 우회.
    /// 신규: 버튼 click 전에 quickPreflight 와 동일한 invariant 검사.
    public var onboardManualSendBlockReason: String? {
        guard cradleConfirmed else { return "정비 스탠드 거치 필요" }
        if store?.bus == nil { return "SSH (RemoteShell) 미연결" }
        // v1.11.24 audit iter3-B — 실 motor task 가 다른 preset 으로 active 면, 동일 preset
        // 의 idle 명령 (정지) 외엔 수동 송출 차단. session.current 와 activeRobotPreset 의
        // mismatch 가 그대로 robot 으로 송출되면 audit §1 mixed-preset 케이스 재현.
        let effective = activeRobotPreset ?? current
        if effective == .idle { return nil }   // idle command (enabled=0) 은 항상 안전 — stop 가능.
        if effective.safety == .caution && !enableBalanceCorrection {
            return "자세 보정 OFF — '\(effective.label)' 수동 송출 차단 (P0-3)"
        }
        if effective.requiresRiskConfirmation && !riskAcknowledged {
            return "위험 동의 필요 — '\(effective.label)'"
        }
        if let store = self.store {
            if store.isImuUnavailable { return "IMU 응답 없음" }
            if store.isImuStale { return "IMU 5초+ 지연" }
            // v1.11.24 audit iter3-D — IMU plausibility 도 quickPreflight 와 동일하게 차단.
            if store.imuScaleSuspicion == .suspectedLegacy10Bit
                || store.imuScaleSuspicion == .outOfRange {
                return "IMU plausibility 의심 (\(store.imuScaleSuspicion.rawValue))"
            }
        }
        return nil
    }

    /// v1.11.24 audit P0-4 — UI 의 "실제 송출값" preview 용. 고급 모드면 슬라이더 값,
    /// 아니면 preset 기본값을 반환. WalkLabView 가 인간 가독 문자열로 포맷.
    public var effectiveCommandPreview: (strideMm: Double, sideMm: Double, turnDeg: Double, periodMs: Double, footHeightMm: Double) {
        if advanced {
            return (strideMm, sideMm, turnDeg, customPeriodMs, footHeightMm)
        }
        let tuning = WalkMotionLibrary.defaultTuning(for: current == .idle ? (requestedPreset ?? .march) : current)
        return (tuning.strideMm, 0, tuning.turnDeg, Double(tuning.periodMs), tuning.footHeightMm)
    }

    /// Preflight: dxl_power ON + 모든 토크 ON. 하체 실패 / 상체 4개+ 실패 시 차단.
    /// Codex P0 권고: WalkLab cycle 이 torque OFF 상태에서 시작해도 silent 했던 버그 차단.
    private func preflightForWalkCycle(bus: Bus) -> WalkPreflightFailure? {
        // 1. dxl_power ON.
        do { try bus.setDxlPower(true) }
        catch { return WalkPreflightFailure(cause: .dxlPowerFailed(error.localizedDescription)) }

        // 2. 모든 관절 토크 ON. 실패 카운트.
        var failedJoints: [JointID] = []
        for j in JointID.allCases {
            do { try bus.setTorque(j, enable: true) }
            catch { failedJoints.append(j) }
        }
        let lowerBodyFails = failedJoints.filter { Self.lowerBodyJoints.contains($0) }
        if !lowerBodyFails.isEmpty {
            return WalkPreflightFailure(cause: .lowerBodyTorqueFailed(lowerBodyFails))
        }
        if failedJoints.count > 3 {
            return WalkPreflightFailure(cause: .bulkTorqueFailed(
                failedCount: failedJoints.count,
                total: JointID.allCases.count
            ))
        }
        return nil
    }

    /// 보행 cycle cancel + walkReady 안전 복귀. stop / emergency / preset 전환 시 호출.
    /// task 가 자체적으로 walkReady 복귀를 수행하지만, cancel 응답 지연을 보장하기 위해
    /// `sendRobotPose` 로 명시 송출 (applyPoseSmoothly 의 검증된 분할/부하 watchdog 경로).
    /// **사이클 109 (Phase 8)**: `private` → `internal` — `WalkLabSession+BalanceMitigation`
    /// 의 warning/danger hysteresis 자동 cancel 경로가 본 method 호출 필요.
    internal func cancelWalkCycle(eventLabel: String) {
        guard let task = walkCycleTask else { return }
        task.cancel()
        walkCycleTask = nil
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
        isRobotWalking = false
        // v1.11.24 audit iter2-A — invariant: cycle cancel 시 active preset / motor counter 도 clear.
        // 종전: applyBalanceMitigation (warning/danger 자동 정지) / syncCommandToEngine
        // 경로에서 호출 시 activeRobotPreset 가 stuck → 다음 sample logger 가 stale preset 기록.
        activeRobotPreset = nil
        motorWriteStarted = false
        motorWriteStepCount = 0
        // v1.9: cycle 종료 시 session log 마무리 + 분석.
        finalizeSessionLog()
        sendRobotPose(.walkReady, eventLabel: eventLabel)
    }

    /// 2026-05-17 안전 강화: bus disconnect 감지 시 cradleConfirmed 자동 해제.
    /// 종전: bus 끊김 → 재연결 후 사용자 명시 cradle 거치 확인 없이 보행 시작 가능
    ///       → wake / disconnect 사이 robot 자세 변화 인지 못 한 채 송출 = 낙상 위험.
    /// 신규: 한 번이라도 bus = nil 관찰되면 cradleConfirmed 자동 false.
    ///       사용자가 "정비 스탠드에 거치됨" 토글 다시 체크해야 보행 가능.
    private var lastSeenBusConnected: Bool = false

    private func tick() {
        // 2026-05-17 disconnect 감지 + cradle 재확인 강제.
        let currentlyConnected = store?.bus != nil
        if lastSeenBusConnected && !currentlyConnected {
            // 연결 끊김 감지 — cradleConfirmed 강제 해제 + 이벤트 로그.
            if cradleConfirmed {
                cradleConfirmed = false
                logSafetyEvent(
                    kind: .preflightFailure,
                    message: "로봇 연결 끊김 — 거치 확인 자동 해제 (재연결 후 다시 확인 필요)"
                )
            }
        }
        lastSeenBusConnected = currentlyConnected

        // **v1.14.8.2 (2026-05-21) — 2차 code-reviewer CRITICAL fix**:
        // 종전 hard-coded 50ms. v1.14.8 Fix #2 가 tickDtSec 50→100ms 로 바꾼 후에도
        // 이 값이 그대로 남아 engine 내부 phase 가 wall-clock 의 절반 속도로 진행 →
        // 모든 preset 의 시각 보행 cadence 50% slow 회귀.
        // 신규: tickDtSec 와 정합 — 단일 source of truth.
        let foot = engine.tick(dtMs: UInt32(tickDtSec * 1000))
        leftFoot = foot.leftXYZ
        rightFoot = foot.rightXYZ
        elapsedMs = UInt32(foot.elapsedMs)
        phaseLabel = foot.phase.label

        // foot trail 누적
        footTrail.append(FootTrailPoint(
            t: Date(),
            left: foot.leftXYZ,
            right: foot.rightXYZ
        ))
        if footTrail.count > 200 { footTrail.removeFirst(footTrail.count - 200) }
        // **v1.14.8.1 (2026-05-21) perf**: lefts 캐시 parallel update.
        // RobotScene3D 가 직접 read — body 마다 .map alloc 차단.
        footTrailLefts.append(foot.leftXYZ)
        if footTrailLefts.count > 200 { footTrailLefts.removeFirst(footTrailLefts.count - 200) }

        // **Phase G11 (2026-05-15)**: sim mode 에서도 3D 모델 보행 시각화.
        //
        // 실 로봇 연결 안 됐을 때 (또는 ARM 안 된 상태) `isRobotWalking == false` 라
        // `runContinuousWalk` 의 onPose 가 호출되지 않음. sim 50ms tick 으로 phase 보간 후
        // visualPose 갱신해서 모델이 보행 따라 움직이도록.
        //
        // 실 로봇 송출 중 (`isRobotWalking == true`) 이면 onPose 가 권한 — sim 덮어쓰기 회피.
        //
        // **Phase G12 (Codex audit 4th pass, 2026-05-15)**: 이전 sim mode 가
        // `(strideMm: 25, sideMm: 0, turnDeg: 0)` 하드코드 → preset 무시 → 모든 preset 이
        // 동일 보행 자세로 시각화됐던 P0 버그. `defaultTuning(for: current)` 로 정정해서
        // march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight 가 각각 다른 보행 자세.
        if !isRobotWalking, current != .idle {
            let effectiveTuning: WalkMotionLibrary.AdvancedTuning = advanced
                ? WalkMotionLibrary.AdvancedTuning(
                    strideMm: strideMm, sideMm: sideMm, turnDeg: turnDeg,
                    periodMs: customPeriodMs, footHeightMm: footHeightMm, balanceGain: balanceGain
                  )
                : WalkMotionLibrary.defaultTuning(for: current)
            let period = effectiveTuning.periodMs
            let phaseFraction = (Double(elapsedMs).truncatingRemainder(dividingBy: period)) / period
            let phasedTimeMs = phaseFraction * period
            if let pose = WalkMotionLibrary.simWalkingPose(timeMs: phasedTimeMs, tuning: effectiveTuning) {
                // **Stage 4 (v1.1 fall prevention)**: sim mode 에서도 corrector 적용
                // → 시각화에 보정 효과 미리보기 (실 robot 미연결 상태에서도 검증).
                visualPose = applyBalanceCorrectionIfEnabled(to: pose)
            }
        } else if current == .idle, !isRobotWalking {
            // idle 상태 → walkReady 로 부드럽게 복귀 (sim).
            visualPose = .walkReady
        }

        updateImuFromRealOrSim()
        updateMotorTempFromRealOrSim()
        updateFallPrediction()

        // **Stage 2 (v1.1 fall prevention)**: 다단계 임계 분기.
        // `autoFallPrevention = false` 면 emergency (30°) 만 작동 — 기존 동작 보존.
        let maxTilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        balanceState = BalanceState.from(maxTilt: maxTilt)

        // v1.9 (사용자 요청): 보행 중 매 tick 데이터 logging.
        appendSessionSampleIfLogging()

        // 2026-05-17 v1.7: cm.rs/lib.rs 10-bit ADC 정정 후 — IMU plausibility 통과 시만
        // L3 hard gate + predictor 작동. `.looksValid16Bit` (enum 이름 보존, 의미는 "1g
        // 중력 정상 감지") 또는 sim 모드 또는 아직 unknown 일 때 trust.
        let imuTrustedForEmergency = (imuScaleSuspicion == .looksValid16Bit
                                      || imuScaleSuspicion == .unknown  // 아직 진단 X — 보수적 trust
                                      || imuSource == .sim)             // sim 모드는 항상 신뢰

        if autoFallPrevention {
            applyBalanceMitigation()

            // **v1.8 (2026-05-17) 정정**: predictor emergency 비활성화 — 사용자 보고
            // "조금만 기울어도 중단". score 60 임계가 정상 보행 (5-15° 흔들림) 에서도
            // 자주 트리거. 진짜 fall (실제 30°+ 누적) 은 L3 hard gate (50°) 가 잡음.
            // 향후 score 가중치 보정 후 재활성 — 현재는 정보용 표시만.
        }

        // 자동 stop (시간 초과)
        if let start = startTime {
            let secs = Date().timeIntervalSince(start)
            if current.maxDurationSec > 0 && Int(secs) >= current.maxDurationSec {
                stop()
            }
        }

        // L3 — 균형 손실 (실 IMU 또는 sim 둘 다 동일 임계).
        // **v1.8 (2026-05-17) 정정 — hysteresis 추가**: 30° → 50° (ROBOTIS FALLEN 수준).
        // 그리고 한 sample 만 충족해도 즉시 trigger 던 종전 → 3 연속 sample (600ms @ 5Hz)
        // 충족 시만 trigger. 정상 보행의 순간적 spike 노이즈 흡수.
        let l3MaxTilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        if imuTrustedForEmergency, l3MaxTilt >= 50 {
            l3HardGateConsecutiveSamples += 1
        } else {
            l3HardGateConsecutiveSamples = 0
        }
        if l3HardGateConsecutiveSamples >= 3 {
            balanceLost = true
            logSafetyEvent(
                kind: .emergencyTriggered,
                message: String(format: "L3 hard gate — tilt R%+.1f° P%+.1f° 3샘플 연속 ≥50° → 정지",
                                imuRollDeg, imuPitchDeg)
            )
            emergencyStop(trigger: .balanceLostL3)
            l3HardGateConsecutiveSamples = 0
        }

        // L4 — 온도 임계
        if maxMotorTemp >= 60 {
            thermalAlarm = true
            // v1.11.25 audit-D — cool-down gate 활성. 60°C 도달 시점부터 50°C 미만 도달까지
            // 모든 preset 차단. 종전: banner "닫기" 즉시 풀림 → 1초 후 재시작 가능.
            thermalCoolDownRequired = true
            logSafetyEvent(
                kind: .thermalAlarm,
                message: String(format: "모터 %.1f°C — 60°C 임계 도달 → 정지 + cool-down %.0f°C 대기",
                                maxMotorTemp, Self.thermalCooldownExitTemp)
            )
            emergencyStop(trigger: .thermalOverheat)
        } else if thermalCoolDownRequired && maxMotorTemp < Self.thermalCooldownExitTemp {
            // v1.11.25 audit-D — cool-down 완료. 50°C 미만 도달 시 gate 해제.
            thermalCoolDownRequired = false
            logSafetyEvent(
                kind: .thermalAlarm,
                message: String(format: "모터 %.1f°C — cool-down 완료 (%.0f°C 미만)",
                                maxMotorTemp, Self.thermalCooldownExitTemp)
            )
        }

        // 2026-05-17 안전 강화 — L0 voltage layer (under-volt 자동 정지).
        // 사용자 보고 fix: 종전 단일 sample < 9.5V 가 transient droop (보행 시작 시
        // 모터 일제 활성화) 에 false-positive trigger. 연속 N tick 동안 지속 시만 trigger.
        // ROBOTIS-OP2 LiPo 11.1V nominal, 10.5V cutoff. 9.5V 이하 = critical
        // (모터 brown-out 위험, 배터리 영구 손상).
        updateVoltageDroopTracking()
        if voltageDroopConsecutiveSamples >= Self.voltageDroopTriggerCount,
           let v = store?.lastTelemetry?.board?.voltageVolts {
            // v1.11.25 audit log-D — voltageDroop dedicated case (kind 재사용 제거).
            logSafetyEvent(
                kind: .voltageDroop,
                message: String(format: "L0 배터리 %.1fV — %d 연속 sample critical → 정지",
                                v, Self.voltageDroopTriggerCount)
            )
            emergencyStop(trigger: .voltageDroop)
            voltageDroopConsecutiveSamples = 0   // 리셋
        }

        // Monitoring dashboard — 시계열 sample 기록 + 이벤트 전환 감지.
        recordSafetySampleAndEvents()
    }

    // MARK: - Safety Sampling (사이클 111 Phase 9 — extension 이동)
    //
    // `recordSafetySampleAndEvents()` (~110 line) 은 `WalkLabSession+SafetySampling.swift`
    // 로 이동. 7개 stored property `private(set)/private` → `internal(set)/internal` 격상.
    // 호출 site `tick()` 동일.

    /// 안전 이벤트 추가 — `safetyEvents` 에 append + 50건 상한.
    /// MainActor 보장 — caller (tick / start / stop / didSet 등) 모두 MainActor.
    ///
    /// **이슈 처리 (2026-05-16)**: 이전엔 append + removeFirst 2 mutations =
    /// 2 publisher notifications. 정정: local var batched → 1 notification
    /// (safetyTimeline 와 동일 패턴).
    /// **v1.11.16 (2026-05-19)**: `lastRobotEvent` 외부 setter — Bridge 가 onboard
    /// send 결과 표시할 때 호출. 종전 `private(set)` → bridge 가 직접 set 불가.
    /// 명시 메서드 형태로 노출하여 호출처 명확화.
    public func setLastRobotEvent(_ message: String?) {
        lastRobotEvent = message
    }

    /// **v1.11.24 audit iter4-A** — bridge 가 ACK 결과를 session 에 반영.
    /// 값: `"ok"` / `"no_ack"` / `"stale"` / `"error: ..."` / `nil` (reset).
    /// 로거 footer 의 onboardAckStatus 필드가 정확한 종료 상태를 기록할 수 있게.
    public func setOnboardAckStatus(_ status: String?) {
        onboardAckStatus = status
    }

    /// **v1.11.16 (2026-05-19)**: visibility — private → internal.
    /// WalkLabOnboardBridge (다른 파일, 같은 module) 가 onboard send 실패 시 직접
    /// 호출하기 위해 노출. external 모듈에선 여전히 비공개.
    func logSafetyEvent(kind: SafetyEvent.Kind, message: String) {
        var newEvents = safetyEvents
        newEvents.append(SafetyEvent(timestamp: Date(), kind: kind, message: message))
        if newEvents.count > Self.safetyEventsMaxCount {
            newEvents.removeFirst(newEvents.count - Self.safetyEventsMaxCount)
        }
        safetyEvents = newEvents
        // 2026-05-17 안전 강화: 영구 로그 — UserDefaults postmortem.
        Self.persistEvent(kind: kind, message: message)
    }

    /// 이벤트 로그 비우기 — UI 의 "지우기" 버튼.
    public func clearSafetyEvents() {
        safetyEvents.removeAll()
    }

    // MARK: - 영구 이벤트 로그 (2026-05-17 안전 강화)
    // **v1.22.1 (2026-05-22) 사이클 90 god object Phase 1B 분할**:
    // PersistentEvent struct / persistentEventsKey / persistentEventsMaxCount /
    // persistEvent / loadPersistentEvents / clearPersistentEvents →
    // `WalkLabSession+PersistentLog.swift` 로 이동. `private static` → `internal
    // static` 격상 — 본체 `logSafetyEvent` 의 호출 site 유지 (다른 file 의 extension
    // 에서 호출하므로 file-level private 불가). 외부 API (loadPersistentEvents /
    // clearPersistentEvents) signature 변경 0.

    // MARK: - Balance Correction (v1.22.X 사이클 100 Phase 5 — extension 이동)
    //
    // `applyBalanceCorrectionIfEnabled` (~213 line) + static helper `scaleCorrections` /
    // `applyCorrections` 는 `WalkLabSession+BalanceCorrection.swift` 로 이동. stored
    // property 본체 잔존 (Swift extension 제약) — extension write 위해 다수 `private(set)` →
    // `internal(set)` 격상 + `correctionEnabledAt` / `correctorFilteredRoll/Pitch` /
    // `lastSafePose` 는 `private` → `internal` (var) 격상. 호출 site `tick()` /
    // `runContinuousWalk` 의 `transformPose` 는 본체 동일.

    /// v1.11: 마지막 tick 에서 corrections 가 실제 pose 에 적용됐는지 (observe-only / applyToRobot=false 면 false).
    /// Logging + UI status indicator 용.
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var lastCorrectionApplied: Bool = false

    /// 사이클 160 (P0-3 fix, gyro closed-loop review): IMU stale 로 보정이 차단/감쇠 된 상태.
    ///
    /// # 의미
    /// - `.normal`: freshnessGate = 1.0 — 보정 정상 적용 (또는 보정 disabled).
    /// - `.degraded`: freshnessGate 0 < x < 1.0 — IMU age 250~500ms, linear 감쇠.
    /// - `.blocked`: freshnessGate = 0 — IMU age ≥ 500ms 또는 bus connected + IMU 한 번도 없음.
    ///
    /// UI / HUD 가 본 상태를 표시해 사용자가 "보정 ON 인데 안 움직임" 침묵을 인지 가능.
    /// 종전: lastCorrectionApplied=false 만 internal — UI 분기 어려움.
    public internal(set) var balanceCorrectionFreshness: BalanceCorrectionFreshness = .normal

    /// 사이클 160: balanceCorrectionFreshness 의 표시 상태.
    public enum BalanceCorrectionFreshness: String, Sendable, Equatable, CaseIterable {
        case normal      // IMU fresh, 보정 정상
        case degraded    // IMU partial stale, 감쇠 적용
        case blocked     // IMU 너무 stale 또는 bus connected + IMU 없음, 보정 차단

        public var koreanLabel: String {
            switch self {
            case .normal:   return "정상"
            case .degraded: return "IMU 지연 — 보정 감쇠"
            case .blocked:  return "IMU 차단 — 보정 정지"
            }
        }
    }

    /// **v1.11 (Codex review 2026-05-18 HIGH-1)**: ramp 적용 **전** 의 raw candidate corrections.
    /// handoff §4 의 `candidateDeltas` 정확한 의미 — corrector.corrections() 결과 그대로.
    /// `lastCorrections` 는 ramp 적용 후 (legacy UI/log 호환). 두 개를 분리해야 분석 시
    /// "corrector 자체의 효과" vs "ramp + corrector 의 합성 효과" 를 구분 가능.
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var lastRawCandidate: BalanceCorrector.Corrections?

    /// v1.11: 마지막 Hybrid B+A 결과 — slow/fast delta + effective err 로깅용.
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var lastHybridResult: BalanceCorrector.HybridResult?

    /// v1.11: 마지막 tick 의 walking cycle 안 elapsed (ms). Hybrid 경로일 때만 값.
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var lastWalkCycleElapsedMs: Double?

    /// v1.11: 마지막 tick 의 walking cycle period (ms). Hybrid 경로일 때만 값.
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var lastWalkPeriodMs: Double?

    // MARK: - v1.22.X 사이클 100 (Phase 5) — scaleCorrections / applyCorrections moved
    //
    // 두 static helper 는 `WalkLabSession+BalanceCorrection.swift` 로 이동 (file-level
    // private → internal static 격상 — 호출 site `applyBalanceCorrectionIfEnabled` 이
    // 동일 extension 안에 있음).

    /// v1.9 critic fix — LPF state for corrector (sway 제거).
    /// **v1.22.X 사이클 100 (Phase 5)**: private → internal — extension P-control 경로가
    /// alpha-filter state mutate.
    var correctorFilteredRoll: Double = 0
    var correctorFilteredPitch: Double = 0

    /// v1.10 (2026-05-17) Hybrid B+A state — slow EMA pitch/roll baseline.
    /// `applyBalanceCorrectionIfEnabled` 가 매 tick mutate.
    /// **v1.22.X 사이클 100 (Phase 5)**: `private(set)` → `internal(set)` — extension write 허용.
    public internal(set) var hybridBalanceState = HybridBalanceState()

    /// **v1.11 (2026-05-17 phase fix)**: walking cycle 시작 시각. session 전체 시각
    /// (`sessionStartedAt`) 과 별개 — Hybrid phase-locked correction 의 정확한 phase
    /// 계산을 위함. `runContinuousWalk` 진입 시 갱신, 한 cycle 종료 시 갱신 안 함
    /// (cycle 가 연속이므로 truncatingRemainder 로 wrap).
    /// **v1.22.X 사이클 100 (Phase 5)**: `public private(set)` → `public internal(set)` —
    /// `+BalanceCorrection.swift` 의 hybrid 경로가 read; `+Logging.swift` 등은 read 만,
    /// 본체 `runContinuousWalk` 만 write. extension read 가능하도록 internal 격상.
    public internal(set) var cycleStartedAt: Date?

    // MARK: - v1.9 Learning system (사용자 요청: 데이터 저장 + 자동 튜닝)

    /// 활성 session 의 logger. nil = 보행 중 아님 또는 logging OFF.
    /// **v1.15.0 (2026-05-21) Phase 1**: private → internal — `WalkLabSession+Trials.swift`
    /// extension 이 finalize 시 sessionId / filePath / sampleCount 추출 위해 read 필요.
    var sessionLogger: WalkSessionLogger?
    /// session 시작 시각 — sample timestamp 계산.
    /// **v1.22.5 사이클 94 (Phase 6)**: private → internal — `+Logging.swift` extension 의
    /// `appendSessionSampleIfLogging` / `finalizeSessionLog` 가 read+write.
    var sessionStartedAt: Date?

    // MARK: - v1.11.25 (2026-05-20) robot data sparse-cadence trackers
    //
    // sample size 폭증 방지 (audit #54 robot-Z) — 매 tick 마다 18 joint × 7 field 를 저장하면
    // 30분 = ~54MB. 대신 telemetry tick 새 데이터 도착 시에만 jointStates 채움.
    //
    // **v1.22.5 사이클 94 (Phase 6)**: 3 trackers private → internal — `+Logging.swift`
    // extension 의 append/finalize 가 read+write 필요.

    /// 마지막 jointStates dump 시점의 lastTelemetry.timestamp — 같은 telemetry 면 nil.
    var lastLoggedTelemetryAt: Date?
    /// 마지막 dump 시점의 imuSequenceCount — 같은 IMU read 면 raw 6축 nil 로 처리.
    var lastLoggedImuSequence: UInt32?
    /// 이전 tick 의 per-joint failure counter — 변화한 joint 만 sparse dump.
    var lastLoggedJointFailures: [JointID: Int] = [:]

    /// **자동 튜닝 시스템** — 매 session 종료 시 분석 + 권고 산출 + (옵션) 자동 적용.
    /// UI 에서 토글 가능.
    public var autoTuner: WalkSessionAutoTuner = WalkSessionAutoTuner()

    /// **session logging ON/OFF** — 사용자가 disable 시 디스크 쓰기 안 함 (privacy / disk).
    public var enableSessionLogging: Bool = true

    /// v1.11: 마지막 IMU 샘플 도착 시각 — sample age 계산. nil = 아직 IMU 미수신.
    /// ConnectionStore 의 `lastImuSuccessAt` 가 source of truth (실 로봇). sim 모드 시 nil.
    /// **v1.22.5 사이클 94 (Phase 6)**: private → internal — `+Logging.swift` extension 의
    /// `appendSessionSampleIfLogging` 가 sample age 계산 위해 read.
    /// computed property 라 본체 잔존 (store 접근). 본체는 `var` (extension getter 불가).
    var lastImuSampleAt: Date? {
        store?.lastImuSuccessAt
    }

    // 사이클 94 분할: appendSessionSampleIfLogging / finalizeSessionLog /
    // triggerAutoLoopIfActive / loadSummaryFromDisk / extractSessionIdFromSummary /
    // loadAllExperimentSummaries / readFirstLine 는 `WalkLabSession+Logging.swift`
    // extension 으로 이동.

    // MARK: - Fall Prediction (사이클 107 Phase 7 — extension 이동)
    //
    // `updateFallPrediction()` (~50 line) 은 `WalkLabSession+FallPrevention.swift` 로
    // 이동. `imuBuffer / lastBufferPushAt / fallPrediction` 은 `internal/internal(set)`
    // 격상 — extension write 허용. 호출 site `tick()` 의 `updateFallPrediction()` 동일.

    /// **Stage 2 + Phase C/D (v1.1 fall prevention)**: 다단계 임계 별 자동 mitigation.
    /// v1.11.19 (2026-05-20) 정합: 25/35/45/50° BalanceState 임계.
    ///
    /// Warning (35° 이상) — sim engine 속도 70% 감속 + 3 tick hysteresis 후 실 robot
    /// `cancelWalkCycle` (안전한 walkReady 복귀, 사용자가 슬라이더 줄이고 재시작 권장).
    /// Danger (45° 이상) — sim engine 정지 + 3 tick hysteresis 후 cancelWalkCycle
    /// (`transformPose` 가 lastSafePose 반환, 자세 동결).
    /// Emergency (≥ 50°) — 별도 L3 hard gate (3 연속 sample → 토크 OFF + walkReady).
    ///
    /// `autoFallPrevention = false` 면 호출 안 됨 — emergency 만 작동.
    ///
    /// **Phase D 정정 (Agent 4 P1)**: normal/caution 복귀 시 engine 명령 복원 —
    /// 이전엔 warning 의 0.7× scale 이 영구 잔존.
    ///
    /// 2026-05-17 사용자 보고 critical fix: 종전 Warning 모드 70% 감속 은 sim
    /// engine 의 x_amplitude 만 적용. 실 motor 송출 plan (walkCycleTask) 은 미리
    /// 합성되어 stride/sideMm/turnDeg 모두 원래 값 그대로 — UI 는 "70% 감속" 표시
    /// 되지만 실 robot 은 변화 없음 → **사용자 신뢰 손상 + 안전 critical**.
    ///
    /// 안전한 새 동작 (Warning 진입 시):
    ///   - sim engine 70% 감속 (기존)
    ///   - 실 robot walkCycle 즉시 정지 (cancelWalkCycle) + walkReady 복귀
    ///   - lastRobotEvent 로 사용자에게 명확 안내: "기울기 35°+ — 감속 정지"
    ///   - 사용자가 직접 stride 줄여서 재시작 (자동 재시작 안 함 = 안전)
    /// 즉시 동적 plan 재합성은 위험 (motor 명령 mid-step 갈아치기 → jerk + 낙상 가능).
    // MARK: - Balance Mitigation (사이클 109 Phase 8 — extension 이동)
    //
    // `applyBalanceMitigation()` (~42 line) 은 `WalkLabSession+BalanceMitigation.swift`
    // 로 이동. `engine / warningStateConsecutiveSamples / dangerStateConsecutiveSamples /
    // cancelWalkCycle` 4개 격상 (`private` → `internal`). 호출 site `tick()` 동일.

    /// v1.8 (2026-05-17): warning/danger hysteresis — 정상 보행의 순간 spike 흡수.
    /// **사이클 109 (Phase 8)**: `private` → `internal` — `WalkLabSession+BalanceMitigation`
    /// 의 `applyBalanceMitigation()` 가 read/write 필요.
    internal var warningStateConsecutiveSamples: Int = 0
    internal var dangerStateConsecutiveSamples: Int = 0

    /// v1.8 safety constants — 10x review P2 fix: magic number → 상수화.
    public static let hysteresisTriggerCount: Int = 3
    public static let setPositionRetryBackoffNs: UInt64 = 5_000_000  // 5ms
    public static let lowerBodyDistinctFailureThreshold: Int = 3
    /// v1.8 critical safety — 10x review Major #1 fix: 단일 모터 hardware 결함 감지.
    /// 같은 joint 가 연속 N step fail 시 abort (Set count 가 1 이라도 hardware fault 의심).
    public static let perJointConsecutiveFailureLimit: Int = 5

    /// 10x review Major #1: per-joint consecutive failure counter — `runContinuousWalk` /
    /// `runWalkCycle` 의 local var. instance var X (static func 라 mutate 불가, concurrency
    /// 안전성 위해). 단일 joint 5회 연속 fail 시 cycle abort.

    /// **테스트용 hooks (internal)** — 10x review P0 fix: hysteresis state machine 테스트.
    /// `applyBalanceMitigation` 가 private 이라 직접 호출 불가 → 카운터 inspection.
    /// **사이클 118 (security-auditor LOW-2 fix)**: `public` → `internal` —
    /// 사이클 100+ 의 internal(set) 격상 후 hysteresis counter 가 internal 로 접근 가능 →
    /// public 노출 redundant. 외부 module 노출 차단 (DarwinForgeApp 만 import 하지만 보안 격상).
    internal func _testInspectWarningHysteresis() -> Int { warningStateConsecutiveSamples }
    internal func _testInspectDangerHysteresis() -> Int { dangerStateConsecutiveSamples }
    // v1.11.25 audit dead-code #1 — `_testInspectL3Hysteresis` 제거 (Sources+Tests 0 사용).

    /// 테스트용 — IMU 값 강제 set 후 tick 한 번 실행 (hysteresis 동작 검증).
    /// **사이클 118 (security-auditor LOW-2 fix)**: `public` → `internal` —
    /// 외부 module noise reduction. test 가 same-module `@testable import` 라 internal 충분.
    internal func _testForceImuAndTick(rollDeg: Double, pitchDeg: Double) {
        imuRollDeg = rollDeg
        imuPitchDeg = pitchDeg
        let maxTilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        balanceState = BalanceState.from(maxTilt: maxTilt)
        if autoFallPrevention {
            applyBalanceMitigation()
        }
    }

    /// 실 telemetry stale 임계 — IMU / 모터 온도 둘 다 동일.
    /// `ImuFilter.isStale()` 내부 5.0초 임계와 정합. 한 곳에서 변경 시 양쪽 자동 동기화.
    /// 2026-05-17 통일: 이전엔 모터 온도가 하드코딩 `< 5.0` → IMU 와 chimera state 위험.
    public static let staleTelemetryThresholdSec: TimeInterval = 5.0

    // MARK: - L0 voltage droop 가드 (2026-05-17 사용자 보고 fix)

    /// L0 voltage critical 연속 sample 카운트 — transient droop (모터 일제 활성화 시
    /// 일시 < 9.5V) 와 sustained brown-out 구분.
    /// **사이클 97 (Phase 3)**: `private` → `internal` — `WalkLabSession+SensorUpdates`
    /// extension 의 `updateVoltageDroopTracking` 가 increment/reset. module 내부만 접근.
    internal var voltageDroopConsecutiveSamples: Int = 0
    /// 연속 trigger 임계 — 50ms tick × 5 = 250ms 동안 지속 시 emergency.
    /// 모터 inrush current 는 ~100ms 안에 안정화 — 250ms 면 충분.
    /// **사이클 97 (Phase 3)**: `private` → `internal` — tick() 의 본체 가드 + extension
    /// 의 카운터 reset 양쪽이 본 상수 read. 외부 module 은 not visible.
    internal static let voltageDroopTriggerCount: Int = 5

    /// v1.8 (2026-05-17): L3 hard gate (50°) 연속 sample 카운트 — 정상 보행의 spike
    /// 노이즈와 진짜 fall 구분. 3 sample 연속 (600ms @ 5Hz) 충족 시만 emergency.
    /// **사이클 97 (Phase 3)**: `private` → `internal` — Phase 3 분할 정책 정합 (sensor
    /// state 묶음 internal 노출). 현재 read 는 tick() 본체, 향후 extension 분리 대비.
    /// 외부 module 은 not visible.
    internal var l3HardGateConsecutiveSamples: Int = 0

    // 사이클 97 분할: updateVoltageDroopTracking / updateImuFromRealOrSim / updateSimIMU /
    // updateMotorTempFromRealOrSim / updateSimThermal 는
    // `WalkLabSession+SensorUpdates.swift` extension 으로 이동.

    // MARK: - v1.11.3 (2026-05-18) — P1.0 정적 IMU 캘리브레이션 (사이클 91 Phase 1C: method 분할)

    /// 5축 캡처 보관소 — 앱 세션 중에만 유지. Disk 저장은 별도 helper.
    /// **사이클 91 (Phase 1C)**: setter `private(set)` → `internal(set)` 격상 —
    /// `WalkLabSession+Calibration` extension method 가 write 필요. external API 는 read-only.
    public internal(set) var calibrationCaptures: [StaticTiltCalibration.Capture] = []

    // MARK: - v1.11.9 (2026-05-19) — Claude CLI 보행 분석 (사이클 89: method 분할)

    /// 마지막 Claude 분석 결과 markdown.
    /// **사이클 89**: setter `private(set)` → `internal(set)` — extension method 가
    /// 다른 파일이라 private 접근 불가. external API (다른 module) 는 여전히 read-only.
    public internal(set) var claudeAnalysisMarkdown: String? = nil

    /// 분석 진행 중 여부 — UI 의 progress indicator.
    public internal(set) var claudeAnalysisInProgress: Bool = false

    /// 마지막 분석 에러 메시지 — nil 이면 정상.
    public internal(set) var claudeAnalysisError: String? = nil

    /// 사용자 자연어 보고 — UI binding.
    public var claudeUserReport: String = ""

    // 사이클 89 분할: invokeClaudeAnalysis / clearClaudeAnalysis 는
    // `WalkLabSession+ClaudeAnalysis.swift` extension 으로 이동.
}

public struct FootTrailPoint: Identifiable, Hashable {
    public let id = UUID()
    public let t: Date
    public let left: SIMD3<Double>
    public let right: SIMD3<Double>
}

public struct WalkLabRecord: Identifiable, Hashable {
    public let id = UUID()
    public let preset: WalkLabPreset
    public let durationSec: Int
    public let endedAt: Date

    public var summary: String {
        "\(preset.label) × \(durationSec)s"
    }
}
