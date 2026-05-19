import Combine
import ForgeCore
import SwiftUI

/// Walk Lab 의 ObservableObject — 현재 프리셋 / 고급 슬라이더 / 시뮬 결과 / 안전 상태.
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
public final class WalkLabSession: ObservableObject {
    // MARK: - 사용자 입력
    @Published public var current: WalkLabPreset = .idle
    @Published public var cradleConfirmed: Bool = false
    @Published public var advanced: Bool = false
    /// 보폭 (앞, mm/cycle). 0..50. WalkEngine 의 x (m) 와 매핑: x_m = strideMm / 1000.
    @Published public var strideMm: Double = 0
    /// 측면 보폭 (mm/cycle). -25..25. y_m = sideMm / 1000.
    @Published public var sideMm: Double = 0
    /// 회전 (°/cycle). -20..20. a_rad = turnDeg * π/180.
    @Published public var turnDeg: Double = 0
    @Published public var customPeriodMs: Double = 600
    /// 발 들기 높이 (mm). sim 영향 — 엔진 미반영 (BLOCKER C3 까지).
    @Published public var footHeightMm: Double = 40
    /// 균형 게인 (NimbRo lean_fb_gain 등가). sim 영향 — 엔진 미반영.
    @Published public var balanceGain: Double = 1.0
    /// 사용자 명시적 안전 한도 해제. Smart-clamp 무시, 단 critical 점수는 여전히 차단.
    @Published public var forceOverrideSafety: Bool = false
    @Published public var riskAcknowledged: Bool = false

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
    @Published public var elapsedMs: UInt32 = 0
    @Published public var phaseLabel: String = "PHASE0"
    @Published public var leftFoot: SIMD3<Double> = .zero
    @Published public var rightFoot: SIMD3<Double> = .zero
    @Published public var footTrail: [FootTrailPoint] = []
    @Published public var imuRollDeg: Double = 0
    @Published public var imuPitchDeg: Double = 0
    /// **Stage 1 (v1.1 fall prevention)**: IMU 출처 표시 — UI 가 sim/real/stale 구분.
    @Published public private(set) var imuSource: ImuSource = .sim
    @Published public private(set) var maxMotorTemp: Double = 35.0
    /// **2026-05-16**: 모터 온도 출처 — sim/real/stale. 이전 버그: 실 robot 연결 시에도
    /// `updateSimThermal()` 만 호출 → dashboard 가 항상 가짜 온도 표시.
    /// 정정: `updateMotorTempFromRealOrSim()` 가 `lastTelemetry?.joints` 의
    /// `presentTemperature` 중 max 사용 (실), 미연결 시 sim model fallback.
    @Published public private(set) var motorTempSource: MotorTempSource = .sim
    @Published public var balanceLost: Bool = false
    @Published public var thermalAlarm: Bool = false

    // 2026-05-17 T3.1 partial split: MotorTempSource / ImuSource enum 정의는
    // WalkLabSession+Types.swift 로 이동. type identity 그대로 (extension nested).

    // MARK: - Stage 2 (v1.1 fall prevention): 다단계 임계

    /// 현재 IMU 기반 안전 상태. tick() 마다 갱신.
    @Published public private(set) var balanceState: BalanceState = .normal
    /// 자동 fall prevention 토글. false 면 emergency (30°) 만 작동. default true.
    @Published public var autoFallPrevention: Bool = true

    // MARK: - Stage 3 (v1.1 fall prevention): 예측 fall detection

    /// 최근 IMU sample ring buffer (최대 1초 / 5 sample).
    private var imuBuffer: [FallPredictor.Sample] = []
    /// 마지막 buffer push 시각 — 5Hz polling 동기화.
    private var lastBufferPushAt: Date?

    /// 예측 결과 — UI 게이지·countdown 용.
    @Published public private(set) var fallPrediction: FallPredictor.Prediction = .zero

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
    @Published public var enableBalanceCorrection: Bool = false {
        didSet {
            if enableBalanceCorrection != oldValue {
                // 토글 전환 — ramp 재시작 (ON → 0초부터 / OFF → nil).
                correctionEnabledAt = enableBalanceCorrection ? Date() : nil
                if !enableBalanceCorrection { lastCorrections = nil }
                rampCompletedLogged = false
                logSafetyEvent(
                    kind: enableBalanceCorrection ? .correctorOn : .correctorOff,
                    message: enableBalanceCorrection
                        ? "자세 보정 ON — 1초 ramp 시작"
                        : "자세 보정 OFF"
                )
            }
        }
    }
    /// 보정 활성 시 0~1초 ramp 시작 시점. nil 이면 ramp 미시작.
    private var correctionEnabledAt: Date?
    /// 최근 산정 보정 delta (UI 표시·디버그 용).
    @Published public private(set) var lastCorrections: BalanceCorrector.Corrections?
    /// **Phase C (2026-05-16)**: balanceState .danger 시 동결 기준 pose. nil 이면 walkReady fallback.
    private var lastSafePose: RobotPose?
    /// Corrector 인스턴스 — `WalkParams.default()` gain 정합. v1.8 정정: intensity 가
    /// `correctorIntensityLevel` 슬라이더에 따라 동적 변경.
    /// v1.11: gainProfile 변경 시 base 가 robotisOriginal ↔ v110Experimental 로 swap.
    public var balanceCorrector: BalanceCorrector = .robotisOriginal

    /// **v1.11 (2026-05-17)**: 자이로 보정 4축 통합 설정.
    /// algorithmMode / signConvention / gainProfile / applyToRobot 을 한 곳에서 관리.
    /// 사용자 prompt 의 4-axis UI 모델. didSet 으로 corrector 인스턴스 swap + 안전 gate 적용.
    @Published public var balanceExperimentConfig: BalanceExperimentConfig = .defaultRobotis {
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
    @Published public var operatorNote: String? = nil
    /// A/B 비교 tag — `WalkComparisonTag.arm` 으로 "A"/"B" 구분. nil 이면 비교 의도 없음.
    @Published public var comparisonTag: WalkComparisonTag? = nil

    /// **v1.8 (2026-05-17 사용자 요청)**: 자이로 기반 자세 보정의 개입 강도 5단계.
    /// 사용자가 슬라이더로 조절. multiplier 매핑:
    ///   - 0: 꺼짐 (intensity 0.0 = 보정 없음)
    ///   - 1: 부드러움 (intensity 0.5 = ROBOTIS 절반)
    ///   - 2: 표준 (intensity 1.0 = ROBOTIS default — 권장)
    ///   - 3: 적극적 (intensity 1.5 = ROBOTIS 1.5배)
    ///   - 4: 최대 (intensity 2.0 = ROBOTIS 2배, 안전 clamp ±15° 유지)
    @Published public var correctorIntensityLevel: Int = 2 {
        didSet {
            let clamped = max(0, min(4, correctorIntensityLevel))
            if clamped != correctorIntensityLevel {
                correctorIntensityLevel = clamped
                return
            }
            if clamped != oldValue {
                // v1.11.1 fix: observeOnly forceHybrid 일관성 (balanceExperimentConfig didSet 와 동일).
                let forceHybrid: Bool? = {
                    switch balanceExperimentConfig.algorithmMode {
                    case .hybridBA:        return true
                    case .robotisPControl: return false
                    case .off:             return false
                    case .observeOnly:     return nil  // gainProfile native enableHybrid 보존
                    }
                }()
                balanceCorrector = Self.makeCorrector(
                    level: clamped,
                    gainProfile: balanceExperimentConfig.gainProfile,
                    forceHybrid: forceHybrid,
                    customHipRollGain: customHipRollGain,
                    customKneeGain: customKneeGain,
                    customAnklePitchGain: customAnklePitchGain,
                    customAnkleRollGain: customAnkleRollGain
                )
                logSafetyEvent(
                    kind: .correctorOn,
                    message: "자이로 보정 강도 → \(Self.intensityLabel(level: clamped))"
                )
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
    @Published public var visualPose: RobotPose = .walkReady

    // MARK: - Monitoring Dashboard (2026-05-16): 시계열 안전 상태 + 이벤트 로그

    // 2026-05-17 T3.1 partial split: SafetySample / SafetyEvent → WalkLabSession+Types.swift.

    /// 시계열 안전 sample buffer — 최근 10초 (50ms tick × 200).
    @Published public private(set) var safetyTimeline: [SafetySample] = []
    /// 안전 이벤트 로그 — 최근 50건 (가장 최신이 last). 별도 보존 — start() reset 시에도 유지.
    @Published public private(set) var safetyEvents: [SafetyEvent] = []
    /// 모니터링 대시보드 펼침 상태 — UI 토글. 앱 재시작 후에도 유지 (UserDefaults).
    /// 키: `df.walklab.monitoringExpanded`. UI 가 @AppStorage 로 binding 추천.
    ///
    /// **v1.11.6 (2026-05-18) — default true 로 변경**:
    /// 종전 default false (Bool 미설정 시) → 첫 사용자가 chevron 클릭해서 펼쳐야
    /// FallPreventionMonitor + WalkingEnginePicker + BalanceExperimentControls +
    /// StaticTiltCalibrationPanel 모두 보임. UX 누락.
    /// 이제 UserDefaults 미설정 시 true 로 초기화. 사용자가 명시 OFF 후엔 OFF 유지.
    @Published public var monitoringExpanded: Bool = {
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

    private static let safetyTimelineMaxWindowSec: Double = 10.0
    private static let safetyTimelineMaxSamples: Int = 250
    private static let safetyEventsMaxCount: Int = 50

    /// 이전 tick 의 balanceState — 전환 검출용.
    private var previousBalanceState: BalanceState = .normal
    /// 이전 tick 의 imuSource — 전환 검출용.
    private var previousImuSource: ImuSource = .sim
    /// 이전 tick 의 motorTempSource — 전환 검출용.
    private var previousMotorTempSource: MotorTempSource = .sim
    /// 이전 tick 의 predictor recommendEmergency — rising-edge 만 이벤트.
    private var previousRecommendEmergency: Bool = false
    /// 이전 tick 의 ramp 완료 여부 — 한 번만 이벤트 발행.
    private var rampCompletedLogged: Bool = false

    /// **현재 ramp 진행률** (0..1). corrector OFF 또는 미시작 시 nil.
    public var rampProgress: Double? {
        guard enableBalanceCorrection, let t = correctionEnabledAt else { return nil }
        return max(0, min(1, Date().timeIntervalSince(t)))
    }

    // MARK: - 세션 기록
    @Published public var history: [WalkLabRecord] = []

    // MARK: - 실 로봇 연결 (optional)
    /// 환경에서 주입되는 연결 store. nil 이면 sim only.
    private weak var store: ConnectionStore?

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
    @Published public private(set) var lastRobotEvent: String?
    /// 실 보행 cycle 진행 중인지 — UI badge / 토글 disable 용.
    @Published public private(set) var isRobotWalking: Bool = false

    /// Codex P0 fix (2026-05-13 3차): preflight 결과 + cycle 종료 후 결과 집계.
    /// 이전 v1.0 은 모든 write 를 `_ = try?` 로 silently swallow → "정상 종료" 처럼 보였음.
    @Published public private(set) var lastCycleResult: WalkCycleResult?
    @Published public private(set) var lastPreflightFailure: WalkPreflightFailure?

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
    private let engine: WalkEngine
    private var simTimer: Timer?
    private var startTime: Date?
    /// Sim IMU 본체 흔들림 위상 (rad). tick 마다 ω·dt 누적.
    private var simSwayPhase: Double = 0
    /// 실 보행 cycle Task — start(preset) 시 시작, stop / emergency 시 cancel.
    private var walkCycleTask: Task<Void, Never>?
    /// 고급 슬라이더 연속 drag 중 실 보행 page 재합성을 debounce.
    private var walkTuningRestartTask: Task<Void, Never>?

    /// Sim 한 tick 의 dt (s). 50 ms.
    private let tickDtSec: Double = 0.05
    /// 모터 발열율 — 워킹 중 (°C/s). 약 6°C/min, 무거운 부하 가정.
    private let motorHeatRate: Double = 0.10
    /// 모터 자연 냉각율 — idle 중 (°C/s).
    private let motorCoolRate: Double = 0.04
    /// 모터 정상 평형 온도 (idle).
    private let motorAmbientTemp: Double = 35.0

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
    /// 도 동일. View 전환 / @StateObject reinit 시 발생 가능.
    deinit {
        simTimer?.invalidate()
        walkCycleTask?.cancel()
        walkTuningRestartTask?.cancel()
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
    public func start(_ preset: WalkLabPreset) {
        guard cradleConfirmed else { return }
        if preset.requiresRiskConfirmation, !riskAcknowledged { return }
        // advanced 모드에서 critical 조합이면 시작 차단 — 사용자가 슬라이더로 직접 위험 조합을
        // 만든 경우 (preset 의 risk confirm 과는 별개).
        if advanced && stabilityScore.category == .critical { return }

        // §3 wiring: session start 시점 snapshot — v2 header 에 그대로 기록.
        imuSourceAtStart = {
            switch imuSource {
            case .sim:   return "sim"
            case .real:  return "real"
            case .stale: return "stale"
            }
        }()
        imuScaleSuspicionAtStart = (store?.imuScaleSuspicion ?? .unknown).rawValue

        current = preset
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)
        footTrail.removeAll()
        simSwayPhase = 0
        balanceLost = false
        thermalAlarm = false
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
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        let wasRunning = startTime != nil
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
        // sway 도 zero 로 디케이 — 다음 tick 에서 매끄럽게 감소.

        // **v1.11.7 (2026-05-18, GPT HIGH-2)** — onboard 모드도 lifecycle 정리.
        // walkingEngine == .robotisOnboard 일 때 walkCycleTask 가 없으므로 별도 cleanup.
        if onboardWalkingActive {
            onboardWalkingActive = false
            logSafetyEvent(kind: .sessionStop,
                message: "ROBOTIS Onboard 정지 — robot 측 SSH stop 명령 별도 필요")
        }

        // 실 보행 cycle cancel — Task 내부에서 walkReady 복귀 후 종료.
        if wasRunning {
            cancelWalkCycle(eventLabel: "정지 — 직립 자세 복귀")
        }
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
    }

    /// 비상 정지 — Stop + risk reset + 실 로봇 토크 OFF.
    public func emergencyStop() {
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
        startTime = nil
        let tilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        logSafetyEvent(
            kind: .emergencyTriggered,
            message: String(format: "비상 정지 — 토크 OFF (tilt %.1f°, score %.0f)",
                            tilt, fallPrediction.score)
        )
        current = .idle
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
        // 종전: 사용자가 보행 활성 상태에서 다른 preset 클릭 또는 walkingEngine 토글 시
        // 새 cycle 이 진행 중 cycle 위에 겹쳐 호출됐다 (walkCycleTask cancel 이 async
        // 라 immediate 효과 X). 같은 cycle 안에 호출하면 lifecycle inconsistent.
        // 명시 차단으로 사용자가 stop() 후 재시작 강제 — race condition 차단.
        if walkCycleTask != nil || onboardWalkingActive {
            lastRobotEvent = "⚠️ 보행 진행 중 — 정지(■) 후 다시 시도하세요 (\(preset.label))"
            return
        }

        guard let store = store, let bus = store.bus else {
            // v1.8: 사용자 보고 "모션 시각만 움직이고 실 robot 안 움직임" — 명확한 toast
            // 강화. sim 시각 미리보기는 유지 (모델 미리보기 용도). lastRobotEvent 가
            // 빨간 톤으로 사용자에게 확실히 표시.
            let f = WalkPreflightFailure(cause: .noConnection)
            lastPreflightFailure = f
            lastRobotEvent = "🛑 시뮬레이션만 — 로봇 미연결. \(preset.label) 보행 신호는 송출 안 됨. 사이드바에서 연결 후 재시도"
            return
        }
        guard cradleConfirmed else {
            let f = WalkPreflightFailure(cause: .cradleNotConfirmed)
            lastPreflightFailure = f
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            return
        }

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
            lastRobotEvent = f.userMessage
            return
        }

        // Preflight — dxl_power ON + 모든 토크 ON. 하체 1개라도 실패면 차단.
        if let failure = preflightForWalkCycle(bus: bus) {
            lastPreflightFailure = failure
            lastRobotEvent = failure.userMessage + " (\(preset.label))"
            return
        }
        lastPreflightFailure = nil

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
            onboardWalkingActive = true
            cycleStartedAt = Date()
            logSafetyEvent(
                kind: .correctorOn,
                message: "ROBOTIS Onboard 시작: \(presetLabel) (Mac sparse 우회). 자동 brokering=\(autoOnboardBrokering ? "ON" : "OFF")"
            )
            let brokeringHint = autoOnboardBrokering
                ? "자동 명령 송출 활성"
                : "수동 송출 (현재 명령 송출 버튼 필요)"
            lastRobotEvent = "▶ ROBOTIS Onboard 모드: \(presetLabel) — Mac sparse 우회, \(brokeringHint)"
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
                    baselineSessionId: activeBaselineSessionId
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
        let onPose: @MainActor @Sendable (RobotPose) -> Void = { [weak self] pose in
            self?.visualPose = pose
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
            lastRobotEvent = "🤖 연속 보행 시작 — \(presetLabel)"
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
                    // v1.11.1 MEDIUM-5: bus write 실패 시 ConnectionStore counter 누적.
                    onBusWriteFailure: { [weak self] in
                        self?.store?._bumpBusWriteFailureCount()
                    }
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRobotWalking = false
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
        lastRobotEvent = "🤖 보행 cycle 송출 시작 — \(presetLabel)"
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
                // v1.11.1 MEDIUM-5: bus write 실패 시 ConnectionStore counter 누적.
                onBusWriteFailure: { [weak self] in
                    self?.store?._bumpBusWriteFailureCount()
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRobotWalking = false
                self.lastCycleResult = result
                if result.isSuccess {
                    self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                } else {
                    self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                }
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
    @Published public var hipPitchOffsetTrimDeg: Double = 13.0

    /// **v1.11.6 (2026-05-18)** — `.robotisOnboard` 모드의 자동 brokering 토글.
    /// true 면 preset / tuning 변경 시 `WalkLabOnboardBridge` 가 300ms debounce 후
    /// 자동으로 RemoteShell.send 호출. default OFF — 안전상 사용자가 명시 ON.
    @Published public var autoOnboardBrokering: Bool = false

    /// **v1.11.14 (2026-05-19)** — A/B 실험 컨텍스트 (사용자 명시 승인 후 set).
    /// `nil` = 일반 보행 (실험 X). Logger header 의 experimentId/baselineSessionId 로 기록.
    @Published public var activeExperimentId: String? = nil
    @Published public var activeBaselineSessionId: String? = nil

    /// **v1.11.14**: ExperimentLoopController weak ref — 세션 종료 시 자동 폐루프.
    /// RootView 가 setExperimentLoop(_:) 로 inject. weak 라 actor lifecycle 의존성 없음.
    /// `@Published` 와 `weak` 호환 불가 — 단일 set 만 일어나므로 non-published 로 둠.
    public weak var experimentLoop: ExperimentLoopController? = nil

    /// RootView 또는 외부 caller 가 controller 주입.
    /// **v1.11.14.1**: controller.onCleared callback 등록 — finalize/cancel 시 자동
    /// clearExperimentContext 호출. 종전엔 activeExperimentId 가 leak 되어 다음 일반
    /// 보행도 experiment 로 인식되는 버그.
    public func setExperimentLoop(_ controller: ExperimentLoopController?) {
        self.experimentLoop = controller
        controller?.onCleared = { [weak self] in
            self?.clearExperimentContext()
        }
    }

    /// **v1.11.14.1**: critic 이 제안 가능한 모든 non-config axis 의 delta.
    /// nil = 변경 없음 (현재값 유지). 한 번에 1개만 non-nil 이어야 changeOneAxisOnly 준수.
    /// **v1.11.14.5 (2026-05-19)**: walkingEngine + enableBalanceCorrection 추가.
    /// 종전엔 ResponseAxis 에는 있지만 applyExperimentChange 가 적용 안 함 — silent
    /// no-op (critic 이 "ROBOTIS onboard 로 바꿔라" 권고해도 변화 X).
    public struct ExperimentDeltas: Sendable, Equatable {
        public var hipPitchOffsetTrimDeg: Double? = nil
        public var strideMm: Double? = nil
        public var sideMm: Double? = nil
        public var turnDeg: Double? = nil
        public var customPeriodMs: Double? = nil
        public var footHeightMm: Double? = nil
        public var balanceGain: Double? = nil
        public var customHipRollGain: Double? = nil
        public var customKneeGain: Double? = nil
        public var customAnklePitchGain: Double? = nil
        public var customAnkleRollGain: Double? = nil
        public var walkingEngine: WalkingEngine? = nil
        public var enableBalanceCorrection: Bool? = nil

        public init() {}

        /// 모든 delta 가 nil 인 경우 — config axis 변경만 적용.
        public var isEmpty: Bool {
            hipPitchOffsetTrimDeg == nil && strideMm == nil && sideMm == nil
                && turnDeg == nil && customPeriodMs == nil && footHeightMm == nil
                && balanceGain == nil && customHipRollGain == nil && customKneeGain == nil
                && customAnklePitchGain == nil && customAnkleRollGain == nil
                && walkingEngine == nil && enableBalanceCorrection == nil
        }

        /// tuning slider (stride/side/turn/period/foot/balanceGain) 가 포함되면 true.
        /// applyExperimentChange 에서 session.advanced 자동 true 강제 — 종전엔 advanced=false
        /// 면 currentWalkTuning 이 preset default 사용해 silent no-op 였음.
        public var hasTuningSlider: Bool {
            strideMm != nil || sideMm != nil || turnDeg != nil
                || customPeriodMs != nil || footHeightMm != nil || balanceGain != nil
        }
    }

    /// **v1.11.14.5 (2026-05-19) — 사용자 평가 CRIT 1 fix**: rollback snapshot.
    /// applyExperimentChange 직전 모든 mutable axis 값 저장. failRollback verdict 시
    /// 또는 사용자 명시 rollback 호출 시 복원.
    public struct ExperimentSnapshot: Sendable {
        public let balanceExperimentConfig: BalanceExperimentConfig
        public let hipPitchOffsetTrimDeg: Double
        public let strideMm: Double
        public let sideMm: Double
        public let turnDeg: Double
        public let customPeriodMs: Double
        public let footHeightMm: Double
        public let balanceGain: Double
        public let customHipRollGain: Double
        public let customKneeGain: Double
        public let customAnklePitchGain: Double
        public let customAnkleRollGain: Double
        public let walkingEngine: WalkingEngine
        public let enableBalanceCorrection: Bool
        public let advanced: Bool
    }

    /// rollback 용 snapshot. applyExperimentChange 가 set, rollbackExperiment 또는
    /// clearExperimentContext 가 clear.
    @Published public private(set) var rollbackSnapshot: ExperimentSnapshot? = nil

    /// **v1.11.14**: ExperimentApprovalUI 가 사용자 승인 후 호출. axis 한 개만 변경.
    /// **v1.11.14.1**: deltas struct 도입 — tuning slider + customGain* axis 통합.
    /// - safetyVerdict.blocked → reject (deterministic gate)
    /// - 활성 실험 진행 중이면 reject (reentry 가드)
    /// - changeOneAxisOnly invariant — 호출자가 axis 하나만 변경한 config 전달 책임
    public func applyExperimentChange(
        experimentId: String,
        baselineSessionId: String,
        proposedConfig: BalanceExperimentConfig,
        deltas: ExperimentDeltas = ExperimentDeltas()
    ) -> ApplyExperimentResult {
        if case .blocked(let reason) = proposedConfig.safetyVerdict {
            return .failed(reason: "safetyVerdict.blocked — \(reason)")
        }
        // **v1.11.14.1**: reentry 가드 — 활성 실험 진행 중에 새 실험 적용 차단.
        // 종전엔 activeExperimentId 덮어쓰기 + leak 으로 이전 실험 데이터 추적 단절.
        if let existing = activeExperimentId {
            return .failed(reason: "이미 활성 실험 (\(existing)) — 종료 후 재시도")
        }
        // **v1.11.14.5 — 사용자 평가 CRIT 1 fix**: rollback snapshot 저장 (mutation 전).
        rollbackSnapshot = ExperimentSnapshot(
            balanceExperimentConfig: balanceExperimentConfig,
            hipPitchOffsetTrimDeg: hipPitchOffsetTrimDeg,
            strideMm: strideMm, sideMm: sideMm, turnDeg: turnDeg,
            customPeriodMs: customPeriodMs, footHeightMm: footHeightMm,
            balanceGain: balanceGain,
            customHipRollGain: customHipRollGain, customKneeGain: customKneeGain,
            customAnklePitchGain: customAnklePitchGain, customAnkleRollGain: customAnkleRollGain,
            walkingEngine: walkingEngine,
            enableBalanceCorrection: enableBalanceCorrection,
            advanced: advanced
        )
        // 실제 config 변경.
        balanceExperimentConfig = proposedConfig
        // v1.11.14.1: 모든 non-config axis delta 적용 (nil 인 axis 는 현재값 유지).
        if let v = deltas.hipPitchOffsetTrimDeg { hipPitchOffsetTrimDeg = v }
        if let v = deltas.strideMm { strideMm = v }
        if let v = deltas.sideMm { sideMm = v }
        if let v = deltas.turnDeg { turnDeg = v }
        if let v = deltas.customPeriodMs { customPeriodMs = v }
        if let v = deltas.footHeightMm { footHeightMm = v }
        if let v = deltas.balanceGain { balanceGain = v }
        if let v = deltas.customHipRollGain { customHipRollGain = v }
        if let v = deltas.customKneeGain { customKneeGain = v }
        if let v = deltas.customAnklePitchGain { customAnklePitchGain = v }
        if let v = deltas.customAnkleRollGain { customAnkleRollGain = v }
        // **v1.11.14.5 — 사용자 평가 HIGH 2 fix**: walkingEngine + enableBalanceCorrection
        // 도 실 적용. 종전엔 ResponseAxis 에 있지만 silent no-op.
        if let v = deltas.walkingEngine { walkingEngine = v }
        if let v = deltas.enableBalanceCorrection { enableBalanceCorrection = v }
        // **v1.11.14.5 — 사용자 평가 HIGH 3 fix**: tuning slider delta 있으면 advanced=true.
        // 종전엔 advanced=false 시 currentWalkTuning 이 preset default 사용 → 데이터상
        // "실험 적용" 처럼 보이지만 실 보행은 거의 그대로. critic 의 강건한 비교 차단.
        if deltas.hasTuningSlider {
            advanced = true
        }
        activeExperimentId = experimentId
        activeBaselineSessionId = baselineSessionId
        logSafetyEvent(
            kind: .correctorOn,
            message: "실험 적용: \(experimentId) (baseline=\(baselineSessionId))"
        )
        return .applied
    }

    /// **v1.11.14**: 실험 종료 (사용자 명시 또는 finalize).
    /// **v1.11.14.5**: rollbackSnapshot 도 clear — 사용자가 변경 결과 수락한 것으로 간주.
    /// 종전엔 snapshot 남아있어 다음 applyExperimentChange 가 다른 baseline 으로 잘못
    /// 복원할 위험. 사용자가 rollback 원하면 rollbackExperiment() 명시 호출 필요.
    public func clearExperimentContext() {
        activeExperimentId = nil
        activeBaselineSessionId = nil
        rollbackSnapshot = nil
    }

    /// **v1.11.14.5 (2026-05-19) — 사용자 평가 CRIT 1 fix**: 변경 원상복구.
    /// applyExperimentChange 가 저장한 snapshot 으로 모든 axis 복원 + activeExperimentId
    /// clear. failRollback verdict 시 자동 호출 또는 사용자 명시 호출.
    /// snapshot 없으면 no-op.
    @discardableResult
    public func rollbackExperiment() -> Bool {
        guard let snapshot = rollbackSnapshot else { return false }
        balanceExperimentConfig = snapshot.balanceExperimentConfig
        hipPitchOffsetTrimDeg = snapshot.hipPitchOffsetTrimDeg
        strideMm = snapshot.strideMm
        sideMm = snapshot.sideMm
        turnDeg = snapshot.turnDeg
        customPeriodMs = snapshot.customPeriodMs
        footHeightMm = snapshot.footHeightMm
        balanceGain = snapshot.balanceGain
        customHipRollGain = snapshot.customHipRollGain
        customKneeGain = snapshot.customKneeGain
        customAnklePitchGain = snapshot.customAnklePitchGain
        customAnkleRollGain = snapshot.customAnkleRollGain
        walkingEngine = snapshot.walkingEngine
        enableBalanceCorrection = snapshot.enableBalanceCorrection
        advanced = snapshot.advanced
        let expId = activeExperimentId ?? "?"
        activeExperimentId = nil
        activeBaselineSessionId = nil
        rollbackSnapshot = nil
        logSafetyEvent(
            kind: .correctorOff,
            message: "🔄 실험 rollback: \(expId) → 변경 전 상태 복원"
        )
        lastRobotEvent = "🔄 실험 rollback — 변경 전 config 복원됨"
        return true
    }

    public enum ApplyExperimentResult: Sendable {
        case applied
        case failed(reason: String)
    }

    /// **v1.11.7 (2026-05-18, GPT HIGH-2)** — ROBOTIS onboard 모드 활성 상태.
    /// startWalkCycle 진입 시 onboard 분기에서 true, stop / cancelWalkCycle 시 false.
    /// UI 가 이 값으로 "robot 측에서 보행 중" 표시 가능.
    /// Mac sparse 의 walkCycleTask 와 별개 — onboard 는 SSH brokering 으로만 동작.
    @Published public private(set) var onboardWalkingActive: Bool = false

    /// **v1.11.6 (2026-05-18)** — `.custom` gainProfile 의 사용자 지정 gain 값.
    /// gainProfile == .custom 일 때만 makeCorrector 가 이 값들을 적용.
    /// 종전 (v1.11.5.2 이하) `.custom` 은 robotisOriginal fallback — UI 라벨과 동작 불일치.
    /// default: robotisOriginal 값 (사용자가 명시 변경해야 effect).
    @Published public var customHipRollGain: Double = 0.5 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }
    @Published public var customKneeGain: Double = 0.3 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }
    @Published public var customAnklePitchGain: Double = 0.9 {
        didSet { rebuildCorrectorIfCustomChanged() }
    }
    @Published public var customAnkleRollGain: Double = 1.0 {
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
    @Published public var walkingEngine: WalkingEngine = .macSparseKeyframe {
        didSet {
            guard walkingEngine != oldValue else { return }
            // **v1.11.8 (2026-05-18) — HIGH-2 fix**: 엔진 전환 시 onboardWalkingActive
            // 도 reset. 종전엔 사용자가 `.robotisOnboard` 활성 후 `.macSparseKeyframe`
            // 로 전환해도 onboardWalkingActive=true 유지 → UI stale 표시.
            if walkingEngine != .robotisOnboard, onboardWalkingActive {
                onboardWalkingActive = false
            }
            logSafetyEvent(
                kind: .correctorOff,
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
    private func cancelWalkCycle(eventLabel: String) {
        guard let task = walkCycleTask else { return }
        task.cancel()
        walkCycleTask = nil
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
        isRobotWalking = false
        // v1.9: cycle 종료 시 session log 마무리 + 분석.
        finalizeSessionLog()
        sendRobotPose(.walkReady, eventLabel: eventLabel)
    }

    /// **Phase G10 (2026-05-15)** — 연속 보행 실제 송출 루프.
    ///
    /// 한 cycle 끝마다 walkReady 자세로 돌아가지 않고 phase[5] → phase[0] 으로 직접
    /// 이어붙임. 사용자 체감: 끊김 없는 자연스러운 보행.
    ///
    /// 흐름:
    ///   1. moving speed 설정 (1회).
    ///   2. **entry** step 송출 (walkReady → phase[0] 전환, longer playMs).
    ///   3. **cycle** step 무한 반복:
    ///      - 6 phase 송출 (anchor 없음)
    ///      - phase[5] 끝나면 다음 iter 의 phase[0] 으로 자연 wrap
    ///        (모터 trapezoidal motion 이 playMs 안에서 보간)
    ///      - cancel / maxDuration / 하체 통신 실패 시 break.
    ///   4. **exit** step — walkReady 안전 복귀.
    private static func runContinuousWalk(
        bus: Bus, plan: WalkMotionLibrary.ContinuousWalkPlan, maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil,
        transformPose: (@MainActor @Sendable (RobotPose) -> RobotPose)? = nil,
        // 2026-05-17 chaos #1 fix: store.bus 가 nil (disconnect) 됐는지 매 step
        // 시작 전 체크. true 면 정상, false 면 즉시 .busDisconnected 로 abort.
        // 종전 ~5 step (400-800ms) 의 dead bus 송출 latency → 즉시 차단.
        isBusAlive: @Sendable () async -> Bool = { true },
        // v1.11.1 MEDIUM-5: bus write 실패 callback (ConnectionStore 누적).
        onBusWriteFailure: (@MainActor @Sendable () -> Void)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0
        // v1.8 (10x review Major #1): per-joint consecutive failure counter (local, static-safe).
        var perJointFailsLocal: [JointID: Int] = [:]

        // 1. moving speed 설정 (1회).
        let cycleSpeed: UInt16 = 256
        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: cycleSpeed) }
            catch {
                speedFailures += 1
                // v1.11.2 (사용자 review P2-A): setMovingSpeed 실패도 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "\(joint.name) 목표 속도 전송: \(error.localizedDescription)"
            }
        }

        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        // 한 step 송출 helper — closure 캡처 X (concurrency 안전).
        func sendStep(_ step: MotionStep, previousIn: RobotPose) async -> RobotPose {
            let rawTarget = step.toPose()
            // **Stage 4b (v1.1 fall prevention, 2026-05-16)**: IMU 기반 corrector
            // 적용 — 호출자가 `transformPose` 로 `applyBalanceCorrectionIfEnabled`
            // 전달. nil 이면 identity (기존 동작).
            let target: RobotPose
            if let transformPose {
                target = await transformPose(rawTarget)
            } else {
                target = rawTarget
            }
            // **Phase G11**: 3D 모델 갱신 — main actor 로 publish (실 로봇 송출 전에).
            if let onPose {
                await onPose(target)
            }
            // v1.8 setPosition 1회 retry + 10x review Major #1: per-joint consecutive counter.
            // Set count >= 3 (서로 다른 joint 3개 fail) 또는 단일 joint 5회 연속 fail.
            let changed = target.changedJoints(from: previousIn)
            for joint in changed {
                let rawVal = UInt16(clamping: target.raw(joint))
                var lastErr: Error?
                for attempt in 0..<2 {
                    do {
                        _ = try bus.setPosition(joint, raw: rawVal)
                        lastErr = nil
                        break
                    } catch {
                        lastErr = error
                        if attempt == 0 {
                            try? await Task.sleep(nanoseconds: Self.setPositionRetryBackoffNs)
                        }
                    }
                }
                if let err = lastErr {
                    positionFailures += 1
                    // v1.11.1 MEDIUM-5: bus write 실패 callback.
                    if let cb = onBusWriteFailure {
                        Task { @MainActor in cb() }
                    }
                    sampleError = "\(joint.name) 목표 위치 전송: \(err.localizedDescription)"
                    if lowerBodyJoints.contains(joint) {
                        lowerBodyPositionFails.insert(joint)
                    }
                    perJointFailsLocal[joint, default: 0] += 1
                } else {
                    // 성공 시 해당 joint counter reset (one-off transient 흡수).
                    perJointFailsLocal[joint] = 0
                }
            }
            let totalMs = max(80, step.playMs + step.pauseMs)
            let ns = UInt64(totalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            return target
        }

        // 2. Entry — walkReady → phase[0] (1회만).
        entryLoop: for step in plan.entry {
            if Task.isCancelled { cancelledMidStep = true; break entryLoop }
            if !(await isBusAlive()) {
                endReason = .busDisconnected
                break entryLoop
            }
            previous = await sendStep(step, previousIn: previous)
            stepsExecuted += 1
            if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                endReason = .lowerBodyWriteFailure
                break entryLoop
            }
            if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit }) {
                endReason = .lowerBodyWriteFailure
                break entryLoop
            }
        }

        // 3. Cycle — 6 phase 무한 반복.
        if endReason == .completedMaxDuration && !cancelledMidStep && lowerBodyPositionFails.count < Self.lowerBodyDistinctFailureThreshold {
            cycleLoop: while !Task.isCancelled {
                if let end = endDate, Date() >= end { break cycleLoop }
                for step in plan.cycle {
                    if Task.isCancelled { cancelledMidStep = true; break cycleLoop }
                    if let end = endDate, Date() >= end { break cycleLoop }
                    if !(await isBusAlive()) {
                        endReason = .busDisconnected
                        break cycleLoop
                    }
                    previous = await sendStep(step, previousIn: previous)
                    stepsExecuted += 1

                    if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                        endReason = .lowerBodyWriteFailure
                        break cycleLoop
                    }
                    // v1.8 Major #1: 단일 joint 5회 연속 fail → 진짜 hardware fault 의심.
                    if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit }) {
                        sampleError = "단일 모터 \(Self.perJointConsecutiveFailureLimit)회 연속 응답 없음 — hardware 확인"
                        endReason = .lowerBodyWriteFailure
                        break cycleLoop
                    }
                    if positionFailures > max(10, JointID.allCases.count) {
                        endReason = .bulkWriteFailure
                        break cycleLoop
                    }
                }
            }
        }
        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        // 4. Exit — walkReady 안전 복귀. cancel 후에도 토크 OFF 보다는 복귀가 안전 (낙상 risk).
        for step in plan.exit {
            let rawTarget = step.toPose()
            // **Stage 4b (v1.1 fall prevention)**: exit phase 도 corrector 적용.
            let target: RobotPose
            if let transformPose {
                target = await transformPose(rawTarget)
            } else {
                target = rawTarget
            }
            // Phase G11 — 3D 모델 갱신.
            if let onPose {
                await onPose(target)
            }
            let changedFinal = target.changedJoints(from: previous)
            for joint in changedFinal {
                let rawVal = UInt16(clamping: target.raw(joint))
                do { _ = try bus.setPosition(joint, raw: rawVal) }
                catch {
                    positionFailures += 1
                    // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                    if let cb = onBusWriteFailure {
                        Task { @MainActor in cb() }
                    }
                    sampleError = "\(joint.name) 복귀쓰기: \(error.localizedDescription)"
                }
            }
            // Exit 의 playMs 동안 모터가 walkReady 도달하도록 대기.
            let totalMs = max(80, step.playMs + step.pauseMs)
            let ns = UInt64(totalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            previous = target
        }

        return WalkCycleResult(
            reason: endReason,
            stepsExecuted: stepsExecuted,
            speedWriteFailures: speedFailures,
            positionWriteFailures: positionFailures,
            lowerBodyPositionFails: Array(lowerBodyPositionFails),
            sampleError: sampleError
        )
    }

    /// 보행 cycle 실제 송출 루프 — `Task.detached` 내부 실행.
    ///
    /// **Codex P0 fix (2026-05-13 3차)**:
    /// - 모든 `try?` 제거 — speed/position write 실패 카운트 + 마지막 에러 sample.
    /// - 하체 position write 실패 1개 이상 → 즉시 cycle 중단 (균형 위험).
    /// - 결과를 `WalkCycleResult` 로 반환 — 호출자가 사용자에게 surface.
    ///
    /// 설계:
    /// - moving speed 1회만 설정 (매 step 호출 안 함 — 패킷 절약).
    /// - 변경된 관절만 setPosition — `RobotPose.changedJoints(from:)` 사용.
    /// - playMs + pauseMs 동안 모터의 trapezoidal motion 자체 보간을 신뢰 → 그 후 다음 step.
    /// - Task.detached 이므로 main thread block 없음.
    private static func runWalkCycle(
        bus: Bus, page: MotionPage, maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        loop: Bool = true,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil,
        transformPose: (@MainActor @Sendable (RobotPose) -> RobotPose)? = nil,
        // 2026-05-17 chaos #1 fix: bus 끊김 즉시 abort. runContinuousWalk 와 동일.
        isBusAlive: @Sendable () async -> Bool = { true },
        // v1.11.1 MEDIUM-5: bus write 실패 callback (ConnectionStore 누적).
        onBusWriteFailure: (@MainActor @Sendable () -> Void)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0
        var perJointFailsLocal: [JointID: Int] = [:]

        // 1. cycle 시작 — moving speed 1회 설정. RoboPlus 기본 32 ≈ 60 rpm 의 4배 — 빠른 보행 대응.
        let cycleSpeed: UInt16 = 256
        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: cycleSpeed) }
            catch {
                speedFailures += 1
                // v1.11.2 (사용자 review P2-A): setMovingSpeed 실패도 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "\(joint.name) 목표 속도 전송: \(error.localizedDescription)"
            }
        }

        // 2. step loop. walkReady 가 항상 prev — 변경된 관절만 차분 송출.
        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        cycleLoop: repeat {
            for step in page.steps {
                if Task.isCancelled { cancelledMidStep = true; break cycleLoop }
                if let end = endDate, Date() >= end { break cycleLoop }
                if !(await isBusAlive()) {
                    endReason = .busDisconnected
                    break cycleLoop
                }

                let rawTarget = step.toPose()
                let target: RobotPose
                if let transformPose {
                    target = await transformPose(rawTarget)
                } else {
                    target = rawTarget
                }
                if let onPose {
                    await onPose(target)
                }
                let changed = target.changedJoints(from: previous)
                for joint in changed {
                    let rawVal = UInt16(clamping: target.raw(joint))
                    var lastErr: Error?
                    for attempt in 0..<2 {
                        do {
                            _ = try bus.setPosition(joint, raw: rawVal)
                            lastErr = nil
                            break
                        } catch {
                            lastErr = error
                            if attempt == 0 {
                                try? await Task.sleep(nanoseconds: Self.setPositionRetryBackoffNs)
                            }
                        }
                    }
                    if let err = lastErr {
                        positionFailures += 1
                        // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                        if let cb = onBusWriteFailure {
                            Task { @MainActor in cb() }
                        }
                        sampleError = "\(joint.name) 목표 위치 전송: \(err.localizedDescription)"
                        if lowerBodyJoints.contains(joint) {
                            lowerBodyPositionFails.insert(joint)
                        }
                        perJointFailsLocal[joint, default: 0] += 1
                    } else {
                        perJointFailsLocal[joint] = 0
                    }
                }
                previous = target
                stepsExecuted += 1

                if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                // v1.8 Major #1: 단일 joint 5회 연속 fail → hardware fault 의심.
                if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit }) {
                    sampleError = "단일 모터 \(Self.perJointConsecutiveFailureLimit)회 연속 응답 없음 — hardware 확인"
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                // v1.8: 누적 카운터 임계 완화.
                if positionFailures > max(10, JointID.allCases.count) {
                    endReason = .bulkWriteFailure
                    break cycleLoop
                }

                let totalMs = max(80, step.playMs + step.pauseMs)
                let ns = UInt64(totalMs) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        } while loop && !Task.isCancelled
        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        // 3. 종료 정리 — walkReady 안전 복귀. 하체 실패 후에도 토크 OFF 보다는
        // walkReady 시도가 안전 (낙상 risk 가 더 큼). 실패해도 결과에 반영.
        let walkReady = RobotPose.walkReady
        // Phase G11 — 3D 모델 walkReady 복귀 시각화.
        if let onPose {
            await onPose(walkReady)
        }
        let changedFinal = walkReady.changedJoints(from: previous)
        for joint in changedFinal {
            let rawVal = UInt16(clamping: walkReady.raw(joint))
            do { _ = try bus.setPosition(joint, raw: rawVal) }
            catch {
                positionFailures += 1
                // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "\(joint.name) 복귀쓰기: \(error.localizedDescription)"
            }
        }

        return WalkCycleResult(
            reason: endReason,
            stepsExecuted: stepsExecuted,
            speedWriteFailures: speedFailures,
            positionWriteFailures: positionFailures,
            lowerBodyPositionFails: Array(lowerBodyPositionFails),
            sampleError: sampleError
        )
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

        let foot = engine.tick(dtMs: 50)
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
            emergencyStop()
            l3HardGateConsecutiveSamples = 0
        }

        // L4 — 온도 임계
        if maxMotorTemp >= 60 {
            thermalAlarm = true
            logSafetyEvent(
                kind: .thermalAlarm,
                message: String(format: "모터 %.1f°C — 60°C 임계 도달 → 정지", maxMotorTemp)
            )
            emergencyStop()
        }

        // 2026-05-17 안전 강화 — L0 voltage layer (under-volt 자동 정지).
        // 사용자 보고 fix: 종전 단일 sample < 9.5V 가 transient droop (보행 시작 시
        // 모터 일제 활성화) 에 false-positive trigger. 연속 N tick 동안 지속 시만 trigger.
        // ROBOTIS-OP2 LiPo 11.1V nominal, 10.5V cutoff. 9.5V 이하 = critical
        // (모터 brown-out 위험, 배터리 영구 손상).
        updateVoltageDroopTracking()
        if voltageDroopConsecutiveSamples >= Self.voltageDroopTriggerCount,
           let v = store?.lastTelemetry?.board?.voltageVolts {
            logSafetyEvent(
                kind: .preflightFailure,
                message: String(format: "L0 배터리 %.1fV — %d 연속 sample critical → 정지",
                                v, Self.voltageDroopTriggerCount)
            )
            emergencyStop()
            voltageDroopConsecutiveSamples = 0   // 리셋
        }

        // Monitoring dashboard — 시계열 sample 기록 + 이벤트 전환 감지.
        recordSafetySampleAndEvents()
    }

    /// **Monitoring dashboard (2026-05-16)**: 매 tick 시계열 sample 기록 + 상태 전환
    /// 이벤트 감지. tick() 마지막에 호출.
    ///
    /// - sample: 매 tick 마다 1건 append, 10초 윈도우 + 250 sample 상한.
    /// - 이벤트:
    ///   - balanceState 변경 (rising/falling 모두) → `.stateChange`
    ///   - predictor recommendEmergency rising-edge → `.predictorRecommend`
    ///   - imuSource 변경 → `.imuSourceChange`
    ///   - ramp 0..1 완료 (rising-edge) → `.rampComplete`
    private func recordSafetySampleAndEvents() {
        let now = Date()
        let maxDelta = lastCorrections?.maxAbs ?? 0
        let sample = SafetySample(
            timestamp: now,
            rollDeg: imuRollDeg,
            pitchDeg: imuPitchDeg,
            predictionScore: fallPrediction.score,
            balanceState: balanceState,
            correctorMaxDelta: maxDelta
        )
        // **2026-05-16 최적화 (Phase 2)**: 매 tick 의 3-step @Published 변경을
        // 단일 assignment 로 batch — publisher notification 3 → 1.
        // 이전: append + removeFirst (expired) + removeFirst (cap) = 3 mutations
        // 정정: local var 에서 작업 후 1회 assign — SwiftUI subscriber 부담 ↓.
        //
        // chronological 정렬 invariant 유지 — append always at end, prune from front.
        var newTimeline = safetyTimeline
        newTimeline.append(sample)
        let cutoff = now.addingTimeInterval(-Self.safetyTimelineMaxWindowSec)
        var firstValidIdx = 0
        while firstValidIdx < newTimeline.count,
              newTimeline[firstValidIdx].timestamp < cutoff {
            firstValidIdx += 1
        }
        if firstValidIdx > 0 {
            newTimeline.removeFirst(firstValidIdx)
        }
        if newTimeline.count > Self.safetyTimelineMaxSamples {
            newTimeline.removeFirst(newTimeline.count - Self.safetyTimelineMaxSamples)
        }
        safetyTimeline = newTimeline

        // 이벤트 — balanceState 전환.
        if balanceState != previousBalanceState {
            logSafetyEvent(
                kind: .stateChange,
                message: "안전 상태: \(previousBalanceState.label) → \(balanceState.label)"
            )
            previousBalanceState = balanceState
        }

        // 이벤트 — predictor rising-edge.
        let recommend = fallPrediction.recommendEmergency
        if recommend, !previousRecommendEmergency {
            let etaStr = fallPrediction.etaMs.map { String(format: " (ETA %.0fms)", $0) } ?? ""
            logSafetyEvent(
                kind: .predictorRecommend,
                message: String(format: "예측 fall — score %.0f%@", fallPrediction.score, etaStr)
            )
        }
        previousRecommendEmergency = recommend

        // 이벤트 — IMU 출처 변경.
        if imuSource != previousImuSource {
            logSafetyEvent(
                kind: .imuSourceChange,
                message: "IMU 출처: \(previousImuSource.label) → \(imuSource.label)"
            )
            previousImuSource = imuSource
        }

        // 이벤트 — 모터 온도 출처 변경 (2026-05-16).
        if motorTempSource != previousMotorTempSource {
            logSafetyEvent(
                kind: .motorTempSourceChange,
                message: "모터 온도 출처: \(previousMotorTempSource.label) → \(motorTempSource.label)"
            )
            previousMotorTempSource = motorTempSource
        }

        // 이벤트 — ramp 완료 (rising-edge, OFF→ON 후 1초 도달 시 1회만).
        if enableBalanceCorrection,
           let progress = rampProgress,
           progress >= 1.0,
           !rampCompletedLogged {
            logSafetyEvent(kind: .rampComplete, message: "자세 보정 ramp 100% 도달 — 풀 적용")
            rampCompletedLogged = true
        }
    }

    /// 안전 이벤트 추가 — `safetyEvents` 에 append + 50건 상한.
    /// MainActor 보장 — caller (tick / start / stop / didSet 등) 모두 MainActor.
    ///
    /// **이슈 처리 (2026-05-16)**: 이전엔 append + removeFirst 2 mutations =
    /// 2 publisher notifications. 정정: local var batched → 1 notification
    /// (safetyTimeline 와 동일 패턴).
    private func logSafetyEvent(kind: SafetyEvent.Kind, message: String) {
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

    /// UserDefaults 키 — 안전 이벤트 영구 저장 (최근 100건).
    /// 앱 재시작 후에도 유지. 실 robot 사고 시 재현 가능한 trace 제공.
    private static let persistentEventsKey = "df.walklab.persistentSafetyEvents"
    private static let persistentEventsMaxCount = 100

    /// 영구 저장된 이벤트 1건 — JSON serializable.
    public struct PersistentEvent: Codable, Equatable, Sendable {
        public let timestamp: Date
        public let kindRaw: String  // SafetyEvent.Kind.rawValue
        public let message: String
    }

    /// 이벤트 영구 저장 — UserDefaults 에 최근 100건 ring buffer.
    private static func persistEvent(kind: SafetyEvent.Kind, message: String) {
        var existing = loadPersistentEvents()
        existing.append(PersistentEvent(
            timestamp: Date(),
            kindRaw: kind.rawValue,
            message: message
        ))
        if existing.count > persistentEventsMaxCount {
            existing.removeFirst(existing.count - persistentEventsMaxCount)
        }
        if let data = try? JSONEncoder().encode(existing) {
            UserDefaults.standard.set(data, forKey: persistentEventsKey)
        }
    }

    /// 영구 저장된 이벤트 로드 — 앱 시작 시 / postmortem UI 표시.
    /// JSON decode 실패 시 빈 배열 반환 (storage 오염 안전 처리).
    public static func loadPersistentEvents() -> [PersistentEvent] {
        guard let data = UserDefaults.standard.data(forKey: persistentEventsKey),
              let events = try? JSONDecoder().decode([PersistentEvent].self, from: data)
        else { return [] }
        return events
    }

    /// 영구 로그 전체 비우기 — 사용자 명시 액션 (privacy / disk 관리).
    public static func clearPersistentEvents() {
        UserDefaults.standard.removeObject(forKey: persistentEventsKey)
    }

    /// **Stage 4 + Phase C (v1.1 fall prevention)**: Balance corrector + balanceState
    /// 둘 다 실 motor 송출 경로에 적용. sim/실 일관.
    ///
    /// 2026-05-16 Phase C 정정 (Agent 4 발견): 이전엔 Stage 2 의 warning 70% 감속 /
    /// danger 자세 동결이 sim engine 만 영향. 실 motor 경로는 미적용. 이번 정정에서
    /// **transformPose 가 balanceState 별로 pose 변환** 으로 실 motor 에도 적용:
    /// - `.danger` (28-30°): 마지막 안전 pose (lastSafePose) 반환 = 자세 동결
    /// - 그 외: corrector 만 적용 (default false 면 identity)
    /// `.warning` (22-28°) 의 속도 감속은 pose 변환으로는 표현 불가 → engine 감속만 유지
    /// (실 motor 의 cycle plan 은 미리 합성됨, 동적 stride 변경은 추후 Sprint).
    ///
    /// 입력 pose 는 보통 보행 cycle 의 phase target. roll/pitch error 는 현재 IMU.
    ///
    /// **v1.11 (2026-05-17 사용자 prompt) 분기**:
    /// `balanceExperimentConfig.algorithmMode` 별 corrections 계산 + `applyToRobot` 게이팅.
    ///   - `.off` → identity (corrections 0)
    ///   - `.robotisPControl` → LPF + deadband + P-control (v1.9.x 기존)
    ///   - `.hybridBA` → slow EMA + phase-locked residual (v1.10 시뮬 권장)
    ///   - `.observeOnly` → corrections 계산하고 lastCorrections 에 기록 + 로그만, pose 적용 X
    /// `applyToRobot=false` (observeOnly 외에도) → corrections 기록만, pose 적용 X.
    public func applyBalanceCorrectionIfEnabled(to pose: RobotPose) -> RobotPose {
        if autoFallPrevention, balanceState == .danger {
            // **Codex 3rd review fix**: danger return 도 candidate stale 방지.
            lastCorrections = nil
            lastRawCandidate = nil
            lastCorrectionApplied = false
            return lastSafePose ?? pose
        }

        // **v1.11.1 (2026-05-18 사용자 review HIGH-3 + Codex #2/#5) — IMU freshness gate**:
        // 워킹 보정은 20Hz (50ms tick) 제어. 150-250ms 이상 stale IMU 로 corrections
        // 적용 시 제어 lag → oscillation / fall 가속 위험. 종전 stale 기준 5초는
        // UI 표시용으론 충분하지만 보정 제어용으론 위험.
        //
        // 정책 (Codex #2 권고 — IMU 5Hz polling jitter 흡수 위해 250ms 부터 감쇠):
        //   - imuSampleAgeMs > 250 → corrections 감쇠 (linear 250→500ms 동안 1.0→0.0)
        //   - imuSampleAgeMs ≥ 500 → corrections 강제 0 + apply 차단
        //   - sim 모드 (store?.bus == nil + lastImuSampleAt nil) → gate 미적용
        //
        // **Codex #5 추가 발견**: bus 연결됐는데 lastImuSampleAt 가 nil (IMU 한 번도
        // 안 옴) → 가장 위험. 보정 들어가면 fall 위험. → 차단.
        let imuAgeMs: Double? = lastImuSampleAt.map {
            Date().timeIntervalSince($0) * 1000.0
        }
        let freshnessGate: Double
        let busConnected = (store?.bus != nil)
        if busConnected && lastImuSampleAt == nil {
            // 실 robot 연결됐지만 IMU 한 번도 안 옴 → 가장 위험 (보정 불가).
            lastCorrections = nil
            lastRawCandidate = nil
            lastCorrectionApplied = false
            lastSafePose = pose
            return pose
        }
        if let age = imuAgeMs {
            if age >= 500 {
                // 매우 stale — corrections 0 + apply 차단.
                lastCorrections = nil
                lastRawCandidate = nil
                lastCorrectionApplied = false
                lastSafePose = pose
                return pose
            } else if age > 250 {
                // 부분 stale — linear 감쇠 (250→500ms : 1.0→0.0).
                freshnessGate = max(0, 1.0 - (age - 250) / 250)
            } else {
                freshnessGate = 1.0
            }
        } else {
            // sim 모드 (bus 없음) — IMU 가 즉시 갱신되는 simulation 신뢰.
            freshnessGate = 1.0
        }

        let config = balanceExperimentConfig

        // **v1.11.3 (2026-05-18) — P1.1 부호 정규화 (opt-in)**.
        // GPT 검증 (2026-05-18) 권고: `imuFilter.pitchDeg` 자체는 건드리지 않고 corrector
        // 입력에서 명시적 정규화 → blast radius 최소 (UI 게이지·fall predictor·safety
        // state 등 IMU 소비자 영향 X). default `.imuRaw` 이면 변경 없음.
        let normalizedImuPitchDeg: Double = {
            switch config.pitchInputConvention {
            case .imuRaw: return imuPitchDeg
            case .negateForwardIsNegative: return -imuPitchDeg
            }
        }()
        // roll 정규화는 P1.0 측정 후 도입 (현재는 raw 유지 — 데이터상 roll 부호는 정상 분포).
        let normalizedImuRollDeg = imuRollDeg

        // Mode .off → identity (corrections 비움, log 도 0).
        if config.algorithmMode == .off {
            lastCorrections = nil
            lastRawCandidate = nil  // **Codex 2nd review MEDIUM-A fix**: stale candidate 방지.
            lastSafePose = pose
            lastCorrectionApplied = false
            return pose
        }

        // Legacy toggle 차단 (UI 의 enableBalanceCorrection 와 호환).
        guard enableBalanceCorrection else {
            lastCorrections = nil
            lastRawCandidate = nil  // **Codex 2nd review MEDIUM-A fix**: stale candidate 방지.
            lastSafePose = pose
            lastCorrectionApplied = false
            return pose
        }

        let now = Date()
        let startedAt = correctionEnabledAt ?? now
        if correctionEnabledAt == nil { correctionEnabledAt = startedAt }
        let ramp = max(0, min(1, now.timeIntervalSince(startedAt)))

        // observeOnly 또는 applyToRobot=false → corrections 계산만, pose 적용 X.
        let shouldApplyToPose = config.applyToRobot && config.algorithmMode != .observeOnly

        // Hybrid B+A 또는 observeOnly 가 hybrid 알고리즘을 미리보기 하는 케이스.
        // observeOnly + hybrid corrector → hybrid corrections 계산.
        // observeOnly + P-control corrector → P-control corrections 계산.
        let useHybridPath = balanceCorrector.enableHybrid
            && (config.algorithmMode == .hybridBA || config.algorithmMode == .observeOnly)

        if useHybridPath {
            // **v1.11 phase fix (사용자 prompt + 5 agent 검증)**:
            // 종전: sessionStartedAt 기준 elapsed → walking cycle phase 와 무관.
            // 신규: cycleStartedAt 기준 + truncatingRemainder(periodMs) → cycle 안 phase.
            // periodMs: currentWalkTuning() nil 이면 WalkMotionLibrary.defaultTuning fallback.
            let periodMs = effectiveWalkPeriodMs()
            let elapsedMs: Double
            if let cycleStart = cycleStartedAt, current != .idle, periodMs > 0 {
                let total = Date().timeIntervalSince(cycleStart) * 1000.0
                elapsedMs = total.truncatingRemainder(dividingBy: periodMs)
            } else {
                elapsedMs = 0
            }

            // **v1.11.3 P1.1**: normalizedImuPitchDeg 사용 (default `.imuRaw` 면 imuPitchDeg 그대로).
            let result = balanceCorrector.hybridCorrections(
                imuRollDeg: normalizedImuRollDeg,
                imuPitchDeg: normalizedImuPitchDeg,
                elapsedMs: elapsedMs,
                periodMs: periodMs,
                state: &hybridBalanceState,
                now: now,
                signConvention: config.signConvention
            )
            // **Codex review (2026-05-18) HIGH-1 fix**: candidate vs applied 명확 분리.
            // - lastRawCandidate = corrector 가 계산한 **raw** corrections (ramp 적용 전)
            //   → handoff §4 의 `candidateDeltas` 정확한 의미.
            // - lastCorrections = ramp 적용 후 (legacy 호환, UI 표시 + applied 후보).
            // - v1.11.1 HIGH-3: freshnessGate (200-500ms stale 감쇠) 적용 → ramp 곱.
            lastRawCandidate = result.corrections
            let effectiveScale = ramp * freshnessGate
            let rampedCorr = Self.scaleCorrections(result.corrections, by: effectiveScale)
            lastCorrections = rampedCorr
            // hybrid input for UI logging (correctorFilteredRoll/Pitch reuse).
            correctorFilteredRoll = result.effectiveRollErr
            correctorFilteredPitch = result.effectivePitchErr
            // v1.11 logging fields
            lastHybridResult = result
            lastWalkCycleElapsedMs = elapsedMs
            lastWalkPeriodMs = periodMs

            if !shouldApplyToPose {
                // observeOnly 또는 applyToRobot=false → pose 그대로.
                lastCorrectionApplied = false
                return pose
            }
            let corrected = Self.applyCorrections(rampedCorr, to: pose)
            lastSafePose = corrected
            lastCorrectionApplied = true
            return corrected
        }

        // P-control 경로 (algorithmMode .robotisPControl 또는 observeOnly with P-control corrector).
        // Legacy v1.9.1 LPF + deadband.
        let isWalkingActive = (current != .idle)
        let deadband: Double = isWalkingActive ? 2.5 : 1.0
        let alpha = 0.5
        // **v1.11.3 P1.1**: normalized 입력 (default `.imuRaw` 면 imuRollDeg/imuPitchDeg 그대로).
        correctorFilteredRoll = alpha * normalizedImuRollDeg + (1 - alpha) * correctorFilteredRoll
        correctorFilteredPitch = alpha * normalizedImuPitchDeg + (1 - alpha) * correctorFilteredPitch
        let effRoll = abs(correctorFilteredRoll) > deadband
            ? correctorFilteredRoll - copysign(deadband, correctorFilteredRoll)
            : 0.0
        let effPitch = abs(correctorFilteredPitch) > deadband
            ? correctorFilteredPitch - copysign(deadband, correctorFilteredPitch)
            : 0.0

        // **Codex review (2026-05-18) HIGH-1 fix + v1.11.1 HIGH-3 freshness gate**.
        // P-control 경로의 raw candidate = ramp 적용 전 corrections (effRoll/effPitch 그대로).
        let rawCorr = balanceCorrector.corrections(
            rollErrDeg: effRoll,
            pitchErrDeg: effPitch,
            signConvention: config.signConvention
        )
        lastRawCandidate = rawCorr
        let effectiveScale = ramp * freshnessGate
        let rampedCorr = balanceCorrector.corrections(
            rollErrDeg: effRoll * effectiveScale,
            pitchErrDeg: effPitch * effectiveScale,
            signConvention: config.signConvention
        )
        lastCorrections = rampedCorr
        lastHybridResult = nil
        // **Codex review MEDIUM-4 fix**: P-control 경로도 walkPhase01 채움.
        let periodMsLog = effectiveWalkPeriodMs()
        if let cycleStart = cycleStartedAt, current != .idle, periodMsLog > 0 {
            let total = Date().timeIntervalSince(cycleStart) * 1000.0
            lastWalkCycleElapsedMs = total.truncatingRemainder(dividingBy: periodMsLog)
            lastWalkPeriodMs = periodMsLog
        } else {
            lastWalkCycleElapsedMs = nil
            lastWalkPeriodMs = nil
        }

        if !shouldApplyToPose {
            // observeOnly 또는 applyToRobot=false → pose 그대로.
            lastCorrectionApplied = false
            return pose
        }
        let corrected = balanceCorrector.apply(
            to: pose,
            rollErrDeg: effRoll,
            pitchErrDeg: effPitch,
            enabled: true,
            // v1.11.1 HIGH-3: freshnessGate 가 secondsSinceEnable 에 곱해져 corrections 감쇠.
            // apply() 가 ramp 0..1 로 clamp → effectiveScale 도 안전.
            secondsSinceEnable: ramp * freshnessGate,
            signConvention: config.signConvention
        )
        lastSafePose = corrected
        lastCorrectionApplied = true
        return corrected
    }

    /// v1.11: 마지막 tick 에서 corrections 가 실제 pose 에 적용됐는지 (observe-only / applyToRobot=false 면 false).
    /// Logging + UI status indicator 용.
    @Published public private(set) var lastCorrectionApplied: Bool = false

    /// **v1.11 (Codex review 2026-05-18 HIGH-1)**: ramp 적용 **전** 의 raw candidate corrections.
    /// handoff §4 의 `candidateDeltas` 정확한 의미 — corrector.corrections() 결과 그대로.
    /// `lastCorrections` 는 ramp 적용 후 (legacy UI/log 호환). 두 개를 분리해야 분석 시
    /// "corrector 자체의 효과" vs "ramp + corrector 의 합성 효과" 를 구분 가능.
    public private(set) var lastRawCandidate: BalanceCorrector.Corrections?

    /// v1.11: 마지막 Hybrid B+A 결과 — slow/fast delta + effective err 로깅용.
    public private(set) var lastHybridResult: BalanceCorrector.HybridResult?

    /// v1.11: 마지막 tick 의 walking cycle 안 elapsed (ms). Hybrid 경로일 때만 값.
    public private(set) var lastWalkCycleElapsedMs: Double?

    /// v1.11: 마지막 tick 의 walking cycle period (ms). Hybrid 경로일 때만 값.
    public private(set) var lastWalkPeriodMs: Double?

    /// Corrections 를 ramp factor 로 scale.
    private static func scaleCorrections(_ c: BalanceCorrector.Corrections, by k: Double) -> BalanceCorrector.Corrections {
        BalanceCorrector.Corrections(
            rHipRoll: c.rHipRoll * k, lHipRoll: c.lHipRoll * k,
            rKnee: c.rKnee * k,       lKnee: c.lKnee * k,
            rAnklePitch: c.rAnklePitch * k, lAnklePitch: c.lAnklePitch * k,
            rAnkleRoll: c.rAnkleRoll * k,   lAnkleRoll: c.lAnkleRoll * k
        )
    }

    /// Corrections deg delta 를 pose 의 각 joint raw 에 적용.
    private static func applyCorrections(_ c: BalanceCorrector.Corrections, to pose: RobotPose) -> RobotPose {
        var dict = pose.positions
        let deltas: [JointID: Double] = [
            .rHipRoll: c.rHipRoll, .lHipRoll: c.lHipRoll,
            .rKnee: c.rKnee, .lKnee: c.lKnee,
            .rAnklePitch: c.rAnklePitch, .lAnklePitch: c.lAnklePitch,
            .rAnkleRoll: c.rAnkleRoll, .lAnkleRoll: c.lAnkleRoll
        ]
        for (jid, delta) in deltas {
            guard abs(delta) > 1e-6 else { continue }
            guard let base = dict[jid] else { continue }
            let baseDeg = Kinematics.degrees(fromRaw: base)
            dict[jid] = Kinematics.raw(fromDegrees: baseDeg + delta)
        }
        return RobotPose(positions: dict)
    }

    /// v1.9 critic fix — LPF state for corrector (sway 제거).
    private var correctorFilteredRoll: Double = 0
    private var correctorFilteredPitch: Double = 0

    /// v1.10 (2026-05-17) Hybrid B+A state — slow EMA pitch/roll baseline.
    /// `applyBalanceCorrectionIfEnabled` 가 매 tick mutate.
    public private(set) var hybridBalanceState = HybridBalanceState()

    /// **v1.11 (2026-05-17 phase fix)**: walking cycle 시작 시각. session 전체 시각
    /// (`sessionStartedAt`) 과 별개 — Hybrid phase-locked correction 의 정확한 phase
    /// 계산을 위함. `runContinuousWalk` 진입 시 갱신, 한 cycle 종료 시 갱신 안 함
    /// (cycle 가 연속이므로 truncatingRemainder 로 wrap).
    public private(set) var cycleStartedAt: Date?

    // MARK: - v1.9 Learning system (사용자 요청: 데이터 저장 + 자동 튜닝)

    /// 활성 session 의 logger. nil = 보행 중 아님 또는 logging OFF.
    private var sessionLogger: WalkSessionLogger?
    /// session 시작 시각 — sample timestamp 계산.
    private var sessionStartedAt: Date?

    /// **자동 튜닝 시스템** — 매 session 종료 시 분석 + 권고 산출 + (옵션) 자동 적용.
    /// UI 에서 토글 가능.
    @Published public var autoTuner: WalkSessionAutoTuner = WalkSessionAutoTuner()

    /// **session logging ON/OFF** — 사용자가 disable 시 디스크 쓰기 안 함 (privacy / disk).
    @Published public var enableSessionLogging: Bool = true

    /// 보행 중 매 tick 호출 — sample 한 줄 logger 에 append.
    /// **v1.11 (2026-05-17 handoff §4 wiring + Codex 2026-05-18 HIGH-1 fix)**:
    /// candidate = ramp 적용 **전** raw corrector 결과 (`lastRawCandidate`),
    /// applied = pose 에 실제 들어간 값 (lastCorrectionApplied 면 `lastCorrections`, 아니면 0).
    /// 정확한 분리로 quality analyzer 가 "corrector 자체" vs "corrector+ramp" 효과 구분 가능.
    private func appendSessionSampleIfLogging() {
        guard let logger = sessionLogger, let started = sessionStartedAt else { return }
        let elapsedMs = Date().timeIntervalSince(started) * 1000.0
        // candidate = corrector.corrections() 결과 (ramp 적용 전, raw).
        // observeOnly / applyToRobot=false 라도 채워짐.
        let candidate: [Double] = [
            lastRawCandidate?.rHipRoll    ?? 0,
            lastRawCandidate?.lHipRoll    ?? 0,
            lastRawCandidate?.rKnee       ?? 0,
            lastRawCandidate?.lKnee       ?? 0,
            lastRawCandidate?.rAnklePitch ?? 0,
            lastRawCandidate?.lAnklePitch ?? 0,
            lastRawCandidate?.rAnkleRoll  ?? 0,
            lastRawCandidate?.lAnkleRoll  ?? 0,
        ]
        // applied = pose 에 실제 들어간 값. observeOnly / applyToRobot=false → 0.
        // ramp 적용된 lastCorrections 가 실제로 pose 에 들어간 값과 동일.
        let appliedFromRamped: [Double] = [
            lastCorrections?.rHipRoll    ?? 0,
            lastCorrections?.lHipRoll    ?? 0,
            lastCorrections?.rKnee       ?? 0,
            lastCorrections?.lKnee       ?? 0,
            lastCorrections?.rAnklePitch ?? 0,
            lastCorrections?.lAnklePitch ?? 0,
            lastCorrections?.rAnkleRoll  ?? 0,
            lastCorrections?.lAnkleRoll  ?? 0,
        ]
        let applied: [Double] = lastCorrectionApplied ? appliedFromRamped : Array(repeating: 0, count: 8)
        // legacy `correctorDeltas` 는 applied 와 동일 (backward compat).
        let battery: Double? = (store?.lastTelemetry?.board?.voltageVolts)
        let motorTemp: Double? = (store?.lastTelemetry?.avgTemperature)
        // v1.11 logging fields
        let cfg = balanceExperimentConfig
        let imuAgeMs: Double? = lastImuSampleAt.map {
            Date().timeIntervalSince($0) * 1000.0
        }
        let expectedPitch: Double? = lastHybridResult.map { _ -> Double in
            // Hybrid 가 사용한 sway 모델 — periodMs/elapsedMs 로 재계산.
            guard let p = lastWalkPeriodMs, let e = lastWalkCycleElapsedMs, p > 0 else { return 0 }
            let phase = (2 * .pi) * e / p
            return balanceCorrector.sagittalSwayAmpDeg * sin(phase)
        }
        let expectedRoll: Double? = lastHybridResult.map { _ -> Double in
            guard let p = lastWalkPeriodMs, let e = lastWalkCycleElapsedMs, p > 0 else { return 0 }
            let phase = (2 * .pi) * e / p
            return balanceCorrector.lateralSwayAmpDeg * sin(phase)
        }
        let emaPitch: Double? = lastHybridResult != nil ? hybridBalanceState.pitchEma : nil
        let emaRoll:  Double? = lastHybridResult != nil ? hybridBalanceState.rollEma  : nil
        let effPitchErr: Double? = lastHybridResult?.effectivePitchErr
        let effRollErr:  Double? = lastHybridResult?.effectiveRollErr
        // §4 walkPhase01 — 0..1 정규화 위상. Hybrid path 에서 채운 lastWalkCycleElapsedMs 사용.
        let phase01: Double? = {
            guard let p = lastWalkPeriodMs, let e = lastWalkCycleElapsedMs, p > 0 else { return nil }
            return max(0, min(1, e / p))
        }()
        // §4 IMU sequence + bus failure counters — ConnectionStore 노출.
        let imuSeq: UInt32? = store?.imuSequenceCount
        let busWFail: Int? = store?.busWriteFailureCount
        let busRFail: Int? = store?.busReadFailureCount
        let sample = WalkSessionSample(
            t: elapsedMs,
            preset: current.rawValue,
            intensityLevel: correctorIntensityLevel,
            imuRollDeg: imuRollDeg,
            imuPitchDeg: imuPitchDeg,
            correctorRollErrDeg: correctorFilteredRoll,
            correctorPitchErrDeg: correctorFilteredPitch,
            balanceState: String(describing: balanceState),
            correctorDeltas: applied,   // backward compat — applied (legacy correctorDeltas)
            imuSource: String(describing: imuSource),
            batteryVolts: battery,
            motorAvgTemp: motorTemp,
            balanceAlgorithmMode: cfg.algorithmMode.rawValue,
            balanceSignConvention: cfg.signConvention.rawValue,
            balanceGainProfile: cfg.gainProfile.rawValue,
            correctionAppliedToRobot: lastCorrectionApplied,
            walkCycleElapsedMs: lastWalkCycleElapsedMs,
            walkPeriodMs: lastWalkPeriodMs,
            imuSampleAgeMs: imuAgeMs,
            expectedPitchDeg: expectedPitch,
            emaPitchDeg: emaPitch,
            effectivePitchErrDeg: effPitchErr,
            // §4 wiring (2026-05-17 handoff)
            walkPhase01: phase01,
            candidateDeltas: candidate,
            appliedDeltas: applied,
            imuSequence: imuSeq,
            busWriteFailureCount: busWFail,
            busReadFailureCount: busRFail,
            effectiveRollErrDeg: effRollErr,
            expectedRollDeg: expectedRoll,
            emaRollDeg: emaRoll
        )
        logger.append(sample)
    }

    /// v1.11: 마지막 IMU 샘플 도착 시각 — sample age 계산. nil = 아직 IMU 미수신.
    /// ConnectionStore 의 `lastImuSuccessAt` 가 source of truth (실 로봇). sim 모드 시 nil.
    private var lastImuSampleAt: Date? {
        store?.lastImuSuccessAt
    }

    /// 보행 cycle 종료 시 호출 — logger close + analyzer 실행 + autoTuner.record.
    /// stop / cancelWalkCycle / runContinuousWalk Task 종료 시 모두 호출.
    /// **v1.11 (Codex 3rd review fix)**: cycleStartedAt 은 logger 존재 여부와 무관하게
    /// 항상 cleanup. 종전엔 logger=nil 일 때 early return 으로 cycleStartedAt 안 nil
    /// 처리됨 → 다음 walk start 시 이전 cycle 잔존 phase 사용 위험.
    public func finalizeSessionLog() {
        // 항상 cleanup (logging OFF / logger throw 케이스 cover).
        defer {
            cycleStartedAt = nil
        }
        guard let logger = sessionLogger, let started = sessionStartedAt else { return }
        let duration = Date().timeIntervalSince(started)
        let summary = WalkSessionAnalyzer.analyze(
            logger.samples,
            preset: logger.header.preset,
            startTime: started,
            durationSec: duration,
            intensityLevelUsed: correctorIntensityLevel,
            header: logger.header   // v1.11.10: V2 metric (quality + sagittal + candidateApplied)
        )
        try? logger.writeSummary(summary)
        logger.close()
        sessionLogger = nil
        sessionStartedAt = nil
        autoTuner.record(summary, currentLevel: correctorIntensityLevel)
        lastRobotEvent = "📊 session 분석 완료 — \(summary.recommendationReason)"

        // **v1.11.14 (2026-05-19)** — 활성 실험이 있으면 자동 폐루프.
        // **v1.11.14.4 cold 3차 MED 6**: orchestration 을 testable async helper 로 추출.
        // 종전엔 Task closure 내부에 inlined — test 에서 trigger 불가.
        triggerAutoLoopIfActive(summaryId: summary.id)
    }

    /// **v1.11.14.4**: 자동 폐루프 orchestration — session end 후 호출.
    /// activeExperimentId/baselineSessionId 가 있으면 controller append + compare 자동.
    /// disk IO 는 detached Task (UI hang 방지). test 에서 직접 호출 가능하도록
    /// internal 노출 + `baseDir` inject.
    @MainActor
    func triggerAutoLoopIfActive(summaryId: String, baseDir: URL? = nil) {
        guard let expId = activeExperimentId, let baselineId = activeBaselineSessionId,
              let controller = experimentLoop else { return }
        Task { @MainActor [weak self, weak controller] in
            // Disk IO 는 detached background Task 로 await — main actor 비차단.
            let baseline = await Task.detached(priority: .userInitiated) {
                WalkLabSession.loadSummaryFromDisk(sessionId: baselineId, baseDir: baseDir)
            }.value
            let experimentSummaries = await Task.detached(priority: .userInitiated) {
                WalkLabSession.loadAllExperimentSummaries(experimentId: expId, baseDir: baseDir)
            }.value
            guard let controller = controller else { return }
            await controller.appendExperimentSession(summaryId)
            guard let b = baseline else { return }
            await controller.compareWithBaseline(
                baselineSummary: b,
                experimentSummaries: experimentSummaries
            )
            if let comp = controller.lastComparison {
                self?.lastRobotEvent =
                    "🔬 A/B 비교: \(comp.verdict.rawValue) — \(comp.reason)"
                // **v1.11.14.5 — 사용자 평가 CRIT 1 fix**: failRollback verdict 시 자동
                // rollback. 종전엔 verdict 만 표시되고 위험한 config 가 그대로 남음 →
                // 다음 보행에서 fall 가속 위험. 안전한 자동 보호.
                if comp.verdict == .failRollback {
                    _ = self?.rollbackExperiment()
                    // 사용자에게 명시 알림 — rollback 사유 (verdict reason) 포함.
                    self?.lastRobotEvent = "🔄 자동 rollback — \(comp.reason)"
                }
            }
        }
    }

    /// **v1.11.14**: baseline session 디스크 load (summary.json).
    /// **v1.11.14.1**: static + Sendable — Task.detached 에서 background 호출.
    /// **v1.11.14.2 (2026-05-19)**: substring match 제거 — WalkSessionLogger 의 명명
    /// 규칙 "{sessionId}-{preset}.summary.json" 따라 prefix match 로 강화. 종전
    /// `contains(sessionId)` 는 sessionId A 가 B 의 substring 일 때 false positive
    /// 가능 (현실에선 ISO timestamp 라 거의 충돌 X, 그러나 defensive coding).
    nonisolated static func loadSummaryFromDisk(sessionId: String,
                                                 baseDir: URL? = nil) -> WalkSessionSummary? {
        guard let dir = baseDir ?? WalkSessionStore.sessionsDir else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let match = files.first { url in
            extractSessionIdFromSummary(url) == sessionId
        }
        guard let url = match, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalkSessionSummary.self, from: data)
    }

    /// **v1.11.14.3 cold 2차**: prefix match 강화. WalkSessionLogger 의 명명 규칙
    /// "{sessionId}-{preset}.summary.json" 에서 마지막 hyphen 으로 sessionId 추출.
    /// 종전 `hasPrefix("\(sessionId)-")` 는 sessionId 가 hyphen 포함한 ISO timestamp
    /// (예: 2026-05-19T08-30) 라 짧은 prefix 가 false positive 매치.
    /// 본 함수는 ".summary.json" 제거 + 마지막 hyphen 분리 → 정확한 sessionId 추출.
    nonisolated private static func extractSessionIdFromSummary(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.hasSuffix(".summary.json") else { return nil }
        let stem = String(name.dropLast(".summary.json".count))
        // stem = "{sessionId}-{preset}". 마지막 hyphen 으로 분리.
        guard let lastHyphenIdx = stem.lastIndex(of: "-") else { return nil }
        return String(stem[stem.startIndex..<lastHyphenIdx])
    }

    /// **v1.11.14**: 같은 experimentId 의 모든 실험 세션 summary load.
    /// **v1.11.14.1**: static + Sendable — Task.detached 에서 background 호출.
    /// **v1.11.14.3**: baseDir inject — test 에서 임시 디렉토리 사용 가능.
    nonisolated static func loadAllExperimentSummaries(experimentId: String,
                                                       baseDir: URL? = nil) -> [WalkSessionSummary] {
        guard let dir = baseDir ?? WalkSessionStore.sessionsDir else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        // jsonl 의 header 에 experimentId 매치 → summary load.
        // **v1.11.14.3 (2026-05-19) — 진단 cold #D fix**: jsonl 전체 load 가 큰 sample
        // (수만 줄) 시 메모리 부담. 첫 줄 (header) 만 streaming read → O(header size).
        var summaries: [WalkSessionSummary] = []
        for jsonlURL in files where jsonlURL.pathExtension == "jsonl" {
            guard let firstLineData = readFirstLine(from: jsonlURL),
                  let header = try? decoder.decode(WalkSessionHeader.self, from: firstLineData),
                  header.experimentId == experimentId else { continue }
            let summaryURL = jsonlURL.deletingPathExtension()
                .appendingPathExtension("summary.json")
            guard let sData = try? Data(contentsOf: summaryURL),
                  let s = try? decoder.decode(WalkSessionSummary.self, from: sData) else { continue }
            summaries.append(s)
        }
        return summaries
    }

    /// **v1.11.14.3**: jsonl 의 첫 줄만 streaming read (전체 load X).
    /// FileHandle 로 chunk 단위 read → newline 만나면 즉시 종료.
    /// `nonisolated` — loadAllExperimentSummaries 가 nonisolated 라 동일하게 표시.
    /// **v1.11.14.4 (2026-05-19) — cold 3차 CRIT 1**: 동적 chunk 확장. header 의
    /// operatorNoteAtStart 등 사용자 입력 길이 무제한 → 8KB 초과 시 silent miss.
    /// newline 만날 때까지 반복 read. 최대 1MB 안전 한도 (그 이상은 header 오염).
    nonisolated private static func readFirstLine(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var accumulated = Data()
        let chunkSize = 8192
        let maxBytes = 1_048_576  // 1MB — header 안전 한도. 넘으면 비정상 jsonl.
        while accumulated.count < maxBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                // EOF — newline 못 찾았지만 끝까지 read. 누적 데이터 반환 (caller 가 parse 시도).
                return accumulated.isEmpty ? nil : accumulated
            }
            accumulated.append(chunk)
            if let newlineIdx = accumulated.firstIndex(of: 0x0a) {
                return accumulated.prefix(upTo: newlineIdx)
            }
        }
        return nil  // 1MB 넘는 header — 비정상.
    }

    /// **Stage 3 (v1.1 fall prevention)**: IMU ring buffer 갱신 + predictor 호출.
    ///
    /// 5Hz IMU polling 동기화 — `lastBufferPushAt` 기준 ≥ 150ms 경과 시에만 push.
    /// (50ms tick × 4 ≈ 200ms 의미. 150ms 임계는 polling jitter 허용).
    /// sim mode 에서도 호출 — sim IMU 의 sin 흔들림으로 predictor 동작 검증 가능.
    ///
    /// gyro 데이터:
    /// - 실 mode (`imuSource == .real`): `store.lastTelemetry.imu` 의 gyroXDps/YDps
    /// - sim mode: derivative — `(roll_now - roll_prev) / dt` 를 gyro 로 근사
    private func updateFallPrediction() {
        let now = Date()

        // 2026-05-17 stale gate (Codex/agent #6 권고): IMU 가 5초+ 지연 시 predictor 우회.
        // 위험 시나리오: real → stale 전환 시 imuRollDeg/Pitch 가 freeze 되며 buffer 에
        // mixed (real + frozen) sample 누적 → 일시적으로 false positive emergency trigger.
        // L3 30° hard gate 는 imuRollDeg/Pitch 자체로 작동 (mitigationForState 분기) —
        // 본 predictor 만 차단해도 안전 net 손실 없음. C4 balance corrector 와 동일 원칙.
        if imuSource == .stale {
            if fallPrediction != .zero { fallPrediction = .zero }
            if !imuBuffer.isEmpty {
                imuBuffer.removeAll(keepingCapacity: true)
                lastBufferPushAt = nil
            }
            return
        }

        // Polling jitter 허용 — 너무 잦은 push 회피.
        if let last = lastBufferPushAt, now.timeIntervalSince(last) < 0.15 {
            // 그대로 마지막 prediction 유지 (재계산 X — score 변동 줄임).
            return
        }

        // Gyro 추출 — 실 IMU 우선, sim 은 derivative 근사.
        var gyroX: Double = 0
        var gyroY: Double = 0
        if imuSource == .real, let s = store, let imu = s.lastTelemetry?.imu {
            gyroX = Double(imu.gyroXDps)
            gyroY = Double(imu.gyroYDps)
        } else if let prev = imuBuffer.last {
            let dt = now.timeIntervalSince(prev.timestamp)
            if dt > 0.001 {
                gyroX = (imuRollDeg - prev.rollDeg) / dt    // deg / sec
                gyroY = (imuPitchDeg - prev.pitchDeg) / dt
            }
        }

        let sample = FallPredictor.Sample(
            timestamp: now,
            rollDeg: imuRollDeg,
            pitchDeg: imuPitchDeg,
            gyroXDps: gyroX,
            gyroYDps: gyroY
        )
        FallPredictor.append(sample, to: &imuBuffer)
        lastBufferPushAt = now

        fallPrediction = FallPredictor.predict(samples: imuBuffer, now: now)
    }

    /// **Stage 2 + Phase C/D (v1.1 fall prevention)**: 다단계 임계 별 자동 mitigation.
    ///
    /// Warning (22-28°) — sim engine 속도 70% 감속 + 실 motor 는 corrector + 다음
    /// `runWalkCycle` 재합성 (TODO: 추후 Sprint).
    /// Danger (28-30°) — sim engine 정지 + 실 motor 는 `transformPose` 가
    /// lastSafePose 반환 (자세 동결, Phase C 추가).
    /// Emergency (≥ 30°) — 별도 L3 게이트 (토크 OFF + walkReady).
    ///
    /// `autoFallPrevention = false` 면 호출 안 됨 — 기존 30° emergency 만 작동.
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
    ///   - lastRobotEvent 로 사용자에게 명확 안내: "기울기 22°+ — 감속 정지"
    ///   - 사용자가 직접 stride 줄여서 재시작 (자동 재시작 안 함 = 안전)
    /// 즉시 동적 plan 재합성은 위험 (motor 명령 mid-step 갈아치기 → jerk + 낙상 가능).
    private func applyBalanceMitigation() {
        let cmd = effectiveCommand
        switch balanceState {
        case .normal, .caution:
            // **Phase D 정정**: 회복 시 engine 100% 복원. 이전 warning 의 0.7× 잔존 방지.
            engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
            // v1.8: warning hysteresis 리셋.
            warningStateConsecutiveSamples = 0
            dangerStateConsecutiveSamples = 0
        case .warning:
            // 70% 자동 감속 — sim engine 의 x_amplitude 만 줄임.
            engine.setCommand(
                x: cmd.x * BalanceState.warning.speedScale,
                y: cmd.y,
                a: cmd.a,
                enabled: cmd.enabled
            )
            // v1.8 (2026-05-17): hysteresis 도입. 한 sample spike → 즉시 cancel false-positive
            // 차단. 3 tick 연속 (150ms @ 50ms tick) warning 일 때만 실 robot 보행 정지.
            warningStateConsecutiveSamples += 1
            dangerStateConsecutiveSamples = 0
            if warningStateConsecutiveSamples >= 3,
               isRobotWalking, store?.bus != nil {
                lastRobotEvent = "⚠️ 기울기 35°+ 지속 — 실 robot 보행 정지. 슬라이더 줄이고 재시작 권장"
                cancelWalkCycle(eventLabel: "Warning state 지속 자동 정지")
                warningStateConsecutiveSamples = 0
            }
        case .danger:
            // **Phase C**: sim engine 정지 + `transformPose` 가 lastSafePose 반환.
            engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
            // v1.8: danger 도 3 tick hysteresis.
            dangerStateConsecutiveSamples += 1
            if dangerStateConsecutiveSamples >= 3,
               isRobotWalking, store?.bus != nil {
                lastRobotEvent = "🛑 기울기 45°+ 지속 — 자세 동결 (낙상 직전)"
                cancelWalkCycle(eventLabel: "Danger state 지속 자세 동결")
                dangerStateConsecutiveSamples = 0
            }
        case .emergency:
            // 즉시 L3 게이트 (별도 처리).
            break
        }
    }

    /// v1.8 (2026-05-17): warning/danger hysteresis — 정상 보행의 순간 spike 흡수.
    private var warningStateConsecutiveSamples: Int = 0
    private var dangerStateConsecutiveSamples: Int = 0

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
    public func _testInspectWarningHysteresis() -> Int { warningStateConsecutiveSamples }
    public func _testInspectDangerHysteresis() -> Int { dangerStateConsecutiveSamples }
    public func _testInspectL3Hysteresis() -> Int { l3HardGateConsecutiveSamples }

    /// 테스트용 — IMU 값 강제 set 후 tick 한 번 실행 (hysteresis 동작 검증).
    public func _testForceImuAndTick(rollDeg: Double, pitchDeg: Double) {
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
    private var voltageDroopConsecutiveSamples: Int = 0
    /// 연속 trigger 임계 — 50ms tick × 5 = 250ms 동안 지속 시 emergency.
    /// 모터 inrush current 는 ~100ms 안에 안정화 — 250ms 면 충분.
    private static let voltageDroopTriggerCount: Int = 5

    /// v1.8 (2026-05-17): L3 hard gate (50°) 연속 sample 카운트 — 정상 보행의 spike
    /// 노이즈와 진짜 fall 구분. 3 sample 연속 (600ms @ 5Hz) 충족 시만 emergency.
    private var l3HardGateConsecutiveSamples: Int = 0

    /// L0 voltage droop tracking — tick() 안에서 호출.
    private func updateVoltageDroopTracking() {
        guard let s = store, s.bus != nil,
              let v = s.lastTelemetry?.board?.voltageVolts,
              v > 0   // sensor 미응답 (0) 가드
        else {
            voltageDroopConsecutiveSamples = 0
            return
        }
        if v < 9.5 {
            voltageDroopConsecutiveSamples += 1
        } else {
            // 회복 — 카운터 리셋. 한 sample 만 droop 했다 회복하면 즉시 false-positive 차단.
            voltageDroopConsecutiveSamples = 0
        }
    }

    /// **Stage 1 (v1.1 fall prevention)**: 실 robot 연결 시 `ConnectionStore.imuFilter`
    /// 의 실 IMU 값 사용 (5Hz polling 자동 갱신). 미연결·stale 시 sim 모델 fallback.
    ///
    /// L3 자동 정지 게이트 (`|roll/pitch| > 30°`) 는 동일하게 작동 — 실 IMU 가
    /// 30° 도달하면 즉시 emergency.
    private func updateImuFromRealOrSim() {
        // 2026-05-17 v1.7 정정 (사용자 보고 "실 데이터 안 보임"): bus 연결됐으면 무조건
        // real 시도. 종전 suspicion 기반 sim fallback (suspectedLegacy10Bit/outOfRange)
        // 은 chip variant 다양성 못 cover → 사용자가 robot 연결했는데도 sim 표시되는
        // 케이스 발생. 진단 chip (imuScaleWarningChip) 으로 plausibility 경고만 표시.
        //
        // bus == nil → sim fallback (미연결 자동 시뮬).
        // bus != nil + sample 있음 → real (suspicion 무관 - chip variant 신뢰).
        // bus != nil + stale → stale.

        // 1) 실 robot 연결 + IMU 신선도 확인 — suspicion 무관 real 신뢰.
        if let s = store, s.bus != nil, !s.imuFilter.isStale() {
            imuRollDeg = s.imuFilter.rollDeg
            imuPitchDeg = s.imuFilter.pitchDeg
            imuSource = .real
            return
        }
        // 2) IMU stale (5초+ 갱신 없음) → 안전 가드. UI 에 노출.
        if let s = store, s.bus != nil, s.imuFilter.isStale() {
            let wasStale = (imuSource == .stale)
            imuSource = .stale
            // 2026-05-17 C4 fix: stale IMU 로 balance corrector 가 outdated 데이터 기반
            // 으로 잘못 보정하는 위험 차단. 자동 OFF + 이벤트 로그 (사용자에게 안내).
            if enableBalanceCorrection {
                enableBalanceCorrection = false
                logSafetyEvent(
                    kind: .imuSourceChange,
                    message: "IMU 지연 — 자세 보정 자동 OFF (outdated 데이터 위험)"
                )
            }
            // 2026-05-17 chaos audit HIGH #4: stale 진입 시 마지막 값 |≥25°| 면
            // L3 hard gate (30°) 가 frozen 값으로 잘못 emergency trigger 또는 false sense
            // of safety 위험. 안전 측에서 보수적으로 0 으로 reset — fall predictor 도
            // stale gate (직전 commit) 로 차단되므로 정합.
            // 값 freeze 유지의 이유 (UI 컨텍스트 보존) 와 위험 (frozen 가까운 30° 평가)
            // 사이 trade-off 에서 안전 우선.
            if !wasStale {
                let frozenMax = max(abs(imuRollDeg), abs(imuPitchDeg))
                if frozenMax >= 25 {
                    logSafetyEvent(
                        kind: .imuSourceChange,
                        message: "IMU 지연 — 직전 기울기 \(Int(frozenMax))° 위험 영역, 안전상 0으로 재설정"
                    )
                    imuRollDeg = 0
                    imuPitchDeg = 0
                }
            }
            return
        }
        // 3) 그 외 (미연결 / 테스트) → 기존 sim 모델 fallback.
        updateSimIMU()
        imuSource = .sim
    }

    /// Sim IMU — 워킹 중 본체 흔들림 모델.
    /// roll ≈ 4° 피크 (좌우), pitch ≈ 2° 피크 (전후), 속도 ↑ → 진폭 ↑.
    /// idle 일 때는 0 으로 수렴 (지수 디케이).
    private func updateSimIMU() {
        let cmd = effectiveCommand
        let periodMs = max(effectivePeriodMs, 200.0)
        let omega = 2.0 * .pi / (periodMs / 1000.0)
        simSwayPhase += omega * tickDtSec

        if cmd.enabled {
            // 속도 비례 보정 — x_amplitude 가 0.04 이면 +50% 진폭.
            let speedFactor = 1.0 + min(abs(cmd.x) / 0.04, 1.0) * 0.5
            let baseRoll = 4.0 * speedFactor
            let basePitch = 2.0 * speedFactor
            imuRollDeg = baseRoll * sin(simSwayPhase + .pi / 2)
            imuPitchDeg = basePitch * sin(simSwayPhase * 2)
        } else {
            // 자연 감쇠 — 한 tick 에 15% 감소.
            imuRollDeg *= 0.85
            imuPitchDeg *= 0.85
            if abs(imuRollDeg) < 0.05 { imuRollDeg = 0 }
            if abs(imuPitchDeg) < 0.05 { imuPitchDeg = 0 }
        }
    }

    /// **모터 온도 — 실 robot / sim 자동 분기 (2026-05-16)**.
    ///
    /// 이전 버그: `tick()` 이 항상 `updateSimThermal()` 만 호출 → 실 robot 연결 시에도
    /// dashboard 의 L6 Thermal 이 시뮬 값만 표시. 60°C 임계 자동 정지 게이트가 sim
    /// 모델로만 트리거 → 실 모터가 60°C 넘어도 정지 안 됨 (P0).
    ///
    /// 정정: ConnectionStore 의 `lastTelemetry?.joints` 중 max `presentTemperature`
    /// 사용. cadence == .essentials (default) 시 4 sample joints (headPan/Tilt/
    /// rShoulderPitch/rKnee) 중 max. cadence == .full 시 20 관절 모두 중 max.
    ///
    /// 단계:
    /// 1. 실 robot 연결 + telemetry fresh (< 5초) + joints 비어있지 않음 → 실 데이터.
    /// 2. 실 robot 연결 됐으나 telemetry stale (≥ 5초) → 마지막 값 hold, source = .stale.
    /// 3. 그 외 (미연결 / 테스트) → sim model fallback.
    ///
    /// **freshness 임계**: 5초 — ConnectionStore.isImuStale 과 정합.
    private func updateMotorTempFromRealOrSim() {
        // 1) 실 robot 연결 + telemetry 신선도 확인.
        // 2026-05-17 통일: 하드코딩 5.0 → staleTelemetryThresholdSec.
        // ImuFilter.isStale() 의 5초 임계와 동일 상수 — IMU/motor chimera state 차단.
        if let s = store, s.bus != nil,
           let snap = s.lastTelemetry,
           Date().timeIntervalSince(snap.timestamp) < Self.staleTelemetryThresholdSec,
           let hottest = snap.hottestJoint?.1 {
            // 실 robot — joint 의 max present_temperature 사용.
            maxMotorTemp = Double(hottest.presentTemperature)
            motorTempSource = .real
            return
        }
        // 2) Telemetry stale (5초+ 갱신 없음) → 마지막 값 hold.
        if let s = store, s.bus != nil {
            motorTempSource = .stale
            // 값 유지 (마지막 알려진) — sim 덮어쓰기 회피.
            return
        }
        // 3) 그 외 → sim 모델.
        motorTempSource = .sim
        updateSimThermal()
    }

    /// Sim thermal — 워킹 중 모터 발열 + idle 시 자연 냉각.
    /// 단조 증가/감소. 자동정지(60°C) 게이트 검증을 위한 시뮬.
    private func updateSimThermal() {
        let cmd = effectiveCommand
        if cmd.enabled {
            maxMotorTemp += motorHeatRate * tickDtSec
        } else if maxMotorTemp > motorAmbientTemp {
            maxMotorTemp -= motorCoolRate * tickDtSec
            if maxMotorTemp < motorAmbientTemp {
                maxMotorTemp = motorAmbientTemp
            }
        }
    }

    // MARK: - v1.11.3 (2026-05-18) — P1.0 정적 IMU 캘리브레이션

    /// 5축 캡처 보관소 — 앱 세션 중에만 유지. Disk 저장은 별도 helper.
    @Published public private(set) var calibrationCaptures: [StaticTiltCalibration.Capture] = []

    /// 단일 자세의 IMU 캡처. 사용자가 robot 을 손으로 자세 잡고 호출.
    /// **주의**: 보행 중 (`walkCycleTask != nil`) 호출 시 보행 데이터와 간섭 가능 — 거부.
    /// - Parameters:
    ///   - axis: 캡처 자세 (직립 / 앞·뒤·오·왼 30°)
    ///   - durationSec: 캡처 시간 (기본 5초)
    ///   - sampleIntervalMs: sample 간격 (기본 50ms = 20Hz)
    /// - Returns: 캡처 결과 (samples + summary). nil 이면 보행 중 거부.
    @discardableResult
    public func runStaticTiltCalibration(
        axis: StaticTiltCalibration.Axis,
        durationSec: Double = 5.0,
        sampleIntervalMs: Double = 50.0
    ) async -> StaticTiltCalibration.Capture? {
        guard walkCycleTask == nil else {
            lastRobotEvent = "캘리브레이션 거부: 보행 중에는 자세 캡처 불가 (정지 후 재시도)"
            return nil
        }
        let startDate = Date()
        let iso = ISO8601DateFormatter().string(from: startDate)
        let imuSrcLabel: String = {
            switch imuSource {
            case .real: return "real"
            case .sim:  return "sim"
            case .stale:return "stale"
            }
        }()

        var samples: [StaticTiltCalibration.Sample] = []
        let durationMs = max(100.0, durationSec * 1000.0)
        let intervalMs = max(10.0, sampleIntervalMs)
        let nanosPerSample = UInt64(intervalMs * 1_000_000)
        var elapsedMs: Double = 0

        while elapsedMs <= durationMs {
            // tick() 가 imuRollDeg / imuPitchDeg 를 갱신 — 그 값 직접 read.
            samples.append(StaticTiltCalibration.Sample(
                rollDeg: imuRollDeg,
                pitchDeg: imuPitchDeg,
                tMs: elapsedMs
            ))
            try? await Task.sleep(nanoseconds: nanosPerSample)
            elapsedMs += intervalMs
            // Task cancellation 존중.
            if Task.isCancelled { break }
        }

        let capture = StaticTiltCalibration.Capture(
            axis: axis,
            startTimeIso: iso,
            durationSec: Date().timeIntervalSince(startDate),
            samples: samples,
            imuSource: imuSrcLabel
        )
        // 같은 axis 의 이전 캡처는 교체 (가장 최근만 보관) — 진단 시 by-axis grouping 의 .last 사용.
        calibrationCaptures.removeAll { $0.axis == axis }
        calibrationCaptures.append(capture)
        lastRobotEvent = "✅ 캘리브레이션 [\(axis.label)] 캡처 완료 — \(samples.count) samples, meanPitch=\(String(format: "%.1f", capture.summary.meanPitch))°, meanRoll=\(String(format: "%.1f", capture.summary.meanRoll))°"
        return capture
    }

    /// 현재까지 캡처된 5축 데이터로 부호 컨벤션 진단.
    public func currentCalibrationDiagnosis() -> StaticTiltCalibration.Diagnosis {
        StaticTiltCalibration.diagnose(captures: calibrationCaptures)
    }

    /// 모든 캘리브레이션 캡처 초기화.
    public func resetCalibrationCaptures() {
        calibrationCaptures = []
    }

    // MARK: - v1.11.9 (2026-05-19) — Claude CLI 보행 분석

    /// 마지막 Claude 분석 결과 markdown.
    @Published public private(set) var claudeAnalysisMarkdown: String? = nil

    /// 분석 진행 중 여부 — UI 의 progress indicator.
    @Published public private(set) var claudeAnalysisInProgress: Bool = false

    /// 마지막 분석 에러 메시지 — nil 이면 정상.
    @Published public private(set) var claudeAnalysisError: String? = nil

    /// 사용자 자연어 보고 — UI binding.
    @Published public var claudeUserReport: String = ""

    /// **최근 N 세션 + 사용자 보고 → Claude CLI 분석 invoke**.
    ///
    /// - Parameter limit: 분석에 포함할 세션 수 (default 5, 최대 `WalkSessionClaudePrompt.maxSessions`)
    /// - 동작:
    ///   1. autoTuner.recentSummaries 의 최신 N session 가져옴
    ///   2. 각 session 의 jsonl 에서 sample 배열 load (메모리 buffer 우선, 없으면 디스크)
    ///   3. phase 별 통계 계산
    ///   4. WalkSessionClaudePrompt.build → markdown prompt
    ///   5. WalkSessionClaudeAnalyst.analyze → claude CLI 호출
    ///   6. 결과 markdown 을 claudeAnalysisMarkdown 에 publish
    public func invokeClaudeAnalysis(limit: Int = 5) async {
        claudeAnalysisInProgress = true
        claudeAnalysisError = nil
        defer { claudeAnalysisInProgress = false }

        let summaries = Array(autoTuner.recentSummaries.prefix(limit))
        if summaries.isEmpty {
            claudeAnalysisError = "분석할 보행 세션이 없습니다. 보행을 1회 이상 실행해주세요."
            return
        }

        // sample 통계 builder — sessionId → PhaseStats 배열.
        // 세션 jsonl 을 디스크에서 read.
        let builder: (String) -> [WalkSessionClaudePrompt.PhaseStats] = { sessionId in
            guard let dir = WalkSessionStore.sessionsDir else { return [] }
            // sessionId 기준으로 .jsonl 파일 찾기.
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return []
            }
            let match = files.first { $0.lastPathComponent.contains(sessionId) && $0.pathExtension == "jsonl" }
            guard let url = match else { return [] }
            guard let data = try? Data(contentsOf: url) else { return [] }
            let lines = data.split(separator: 0x0a)  // newline
            let decoder = JSONDecoder()
            var samples: [WalkSessionSample] = []
            // 첫 줄은 header — skip.
            for line in lines.dropFirst() {
                if let sample = try? decoder.decode(WalkSessionSample.self, from: Data(line)) {
                    samples.append(sample)
                }
            }
            return WalkSessionClaudePrompt.phaseStats(from: samples)
        }

        let prompt = WalkSessionClaudePrompt.build(
            sessions: summaries,
            userReport: claudeUserReport,
            sampleStatsBuilder: builder
        )

        // Claude CLI 호출 (60초 timeout).
        let analyst = WalkSessionClaudeAnalyst(timeoutSeconds: 60)
        do {
            let markdown = try await analyst.analyze(prompt: prompt)
            claudeAnalysisMarkdown = markdown
        } catch {
            claudeAnalysisError = error.localizedDescription
        }
    }

    /// 분석 결과 초기화.
    public func clearClaudeAnalysis() {
        claudeAnalysisMarkdown = nil
        claudeAnalysisError = nil
    }
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
