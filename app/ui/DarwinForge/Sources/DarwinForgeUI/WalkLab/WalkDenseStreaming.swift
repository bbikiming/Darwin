import Foundation
import ForgeCore

/// **Wave D1 (2026-06-12, bus-direct-teleop-upgrade §4)** — 직결(bus) 보행의
/// 시간 기반 50Hz 연속 스트리밍 공유 인프라.
///
/// # 비유
///
/// 종전 직결 보행은 한 사이클을 사진 6장(6 키프레임)으로 찍어 모터에게 "이 자세들
/// 사이를 알아서 보간하라"고 맡겼다(≈10Hz 등가). 본 모듈은 같은 연속 시간 함수
/// `robotisWalkingApproxPose(timeMs:)` 를 **20ms마다 직접 평가**(50Hz)해 동영상처럼
/// 촘촘히 흘려보낸다. 새 알고리즘이 아니라 *같은 함수의 샘플 밀도만* 올린 것이라
/// 궤적 자체는 6 키프레임과 동일하다(동치 테스트로 증명).
///
/// # 두 송출 루프 공유 (사용자 결정 2026-06-12)
///
/// 프리셋 보행(`runContinuousWalk`)과 라이브 컨트롤러 자유 조종
/// (`runMobileFreeformWalk`) 둘 다 이 모듈의 `sample` / `WalkAmplitudeLatch` 를
/// 소비한다. 단일 정의라 양 경로의 조종감이 일치한다(트윈 일관성, DG3).
///
/// # 상수 공유 관례 (O2 패리티)
///
/// 래치 슬루 한계는 **온보드 O2 의 `WalkLabTransport.h` SLEW_*_MAX 와 값이 동일**하다.
/// Swift↔C++ 는 컴파일 공유가 불가하므로 값 패리티를 주석 + 단위 테스트로 고정한다.
/// **변경 시 양쪽(이 파일 + `firmware-patches/walklab-brokerage/WalkLabTransport.h`)을
/// 동시에 갱신**할 것.
public enum WalkDenseStreaming {

    // MARK: - 케이던스 상수 (단일 정의)

    /// 시간 기반 모드의 고정 step 간격 — 50Hz. (DG1 게이트 해상도 6배↑)
    public static let denseStepMs: Int = 20

    /// **진동 후퇴 step** — 실기에서 MX-28(P=32 고정)이 20ms 추종 중 진동하면
    /// 33Hz 로 후퇴. `df.walklab.denseStepFallback` 플래그로 선택(설계 §4-D1-e 완화책).
    public static let denseStepFallbackMs: Int = 30

    /// 시간 기반 모드의 period 하한 — 키프레임 모드의 `playMs ≥ 80ms`(=사이클 480ms)
    /// 하한을 대체. 의미가 명확해짐: "사이클이 440ms보다 짧아질 수 없다"(콕핏 범위).
    public static let denseMinPeriodMs: Double = 440

    /// liveness PING 주기 — 스텝 수 기준(매 step)에서 **시간 기준 1Hz**로 변경.
    /// 50Hz 스트리밍에서 매 step PING 은 버스 예산 낭비라 1초당 1회로 라운드로빈.
    public static let denseLivenessPingIntervalMs: Double = 1000

    // MARK: - 래치 슬루 한계 (O2 WalkLabTransport.h 와 값 동일 — 변경 시 양쪽 동시)

    /// 출처: `WalkLabTransport.h` `SLEW_DX_MAX` 와 값 동일(8.0mm) — 변경 시 양쪽 동시.
    public static let slewDxMaxMm: Double = 8.0
    /// 출처: `WalkLabTransport.h` `SLEW_DY_MAX` 와 값 동일(6.0mm) — 변경 시 양쪽 동시.
    public static let slewDyMaxMm: Double = 6.0
    /// 출처: `WalkLabTransport.h` `SLEW_DA_MAX` 와 값 동일(4.0deg) — 변경 시 양쪽 동시.
    public static let slewDaMaxDeg: Double = 4.0
    /// 출처: `WalkLabTransport.h` `SLEW_DPERIOD_MAX` 와 값 동일(60.0ms) — 변경 시 양쪽 동시.
    public static let slewDPeriodMaxMs: Double = 60.0

    // MARK: - 래치 경계 위상 (Walking.cpp 의미론)
    //
    // dspRatio=0.1 → ssp 경계: sspStartL=0.025, sspEndL=0.475, sspStartR=0.525,
    // sspEndR=0.975 (RobotisWalkingState 와 동일 산식). 스윙 중간 = SSP 중점:
    //   leftSwingMid  ≈ (0.025+0.475)/2 = 0.25
    //   rightSwingMid ≈ (0.525+0.975)/2 = 0.75
    // DSP 경계 = 사이클 wrap(위상 0.0) — period 래치 지점.

    /// X/Y/A 진폭 래치 경계(위상 분수) — 스윙 중간(O2 와 동일 의미론).
    static let amplitudeLatchPhases: [Double] = [0.25, 0.75]
    /// period 래치 경계(위상 분수) — DSP 경계(사이클 wrap).
    static let periodLatchPhase: Double = 0.0

    // MARK: - 기능 플래그

    /// `df.walklab.denseStreaming` — 시간 기반 50Hz 모드 활성(기본 off → 검증 후 on).
    /// **테스트 직렬 실행 주의**(CLAUDE.md: `df.walklab.*` 키는 process-global).
    public static let denseStreamingDefaultsKey = "df.walklab.denseStreaming"
    /// `df.walklab.denseStepFallback` — 진동 후퇴(30ms/33Hz) 선택.
    public static let denseStepFallbackDefaultsKey = "df.walklab.denseStepFallback"

    public static func denseStreamingEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: denseStreamingDefaultsKey)
    }

    /// 실효 step 간격 — 후퇴 플래그 ON 이면 30ms, 아니면 20ms.
    public static func effectiveStepMs(_ defaults: UserDefaults = .standard) -> Int {
        defaults.bool(forKey: denseStepFallbackDefaultsKey) ? denseStepFallbackMs : denseStepMs
    }

    // MARK: - 시간 기반 샘플러 (순수)

    /// 사이클 시작 이후 경과(ms)와 period 로 사이클 내 위상 시각을 산출.
    /// `tCycle = elapsedMs mod period`. period 는 `denseMinPeriodMs` 로 클램프.
    public static func cycleTimeMs(elapsedMs: Double, periodMs: Double) -> Double {
        let period = max(denseMinPeriodMs, periodMs)
        let t = elapsedMs.truncatingRemainder(dividingBy: period)
        return t < 0 ? t + period : t
    }

    /// 시간 기반 포즈 — 키프레임 모드와 **동일 함수**(`simWalkingPose`)를 호출하므로
    /// 같은 시각·같은 tuning 에서 6 키프레임과 비트 단위로 일치(궤적 회귀 0).
    public static func pose(atCycleMs tCycle: Double,
                            tuning: WalkMotionLibrary.AdvancedTuning) -> RobotPose {
        WalkMotionLibrary.simWalkingPose(timeMs: tCycle, tuning: tuning) ?? .walkReady
    }
}

/// **Wave D1** — 진폭/주기 래치 객체(O2 `SlewState` 의미론의 Swift 미러).
///
/// 콕핏 EMA 가 명령을 부드럽게 한 뒤에도, 보행 안정(첫걸음 capturability)을 위해
/// 진폭은 **스윙 중간 경계**에서, 주기는 **DSP 경계**에서만 채택하고, 인접 래치 간
/// 변화량을 `WalkDenseStreaming.slew*Max` 로 제한한다(가속 제한).
///
/// `valid=false`(첫 호출)면 슬루 없이 target 을 즉시 수용한다 — O2 와 동일.
/// 순수 struct 라 실시간 sleep 없이 단위 테스트로 경계 의미론을 증명한다.
public struct WalkAmplitudeLatch: Equatable {
    /// 현재 적용 중인 tuning(committed).
    public private(set) var committed: WalkMotionLibrary.AdvancedTuning
    private var valid: Bool
    private var prevFraction: Double

    public init(initial: WalkMotionLibrary.AdvancedTuning? = nil) {
        if let initial {
            committed = initial
            valid = true
        } else {
            // 미초기화 — 첫 advance 가 target 을 슬루 없이 수용.
            committed = WalkMotionLibrary.AdvancedTuning(
                strideMm: 0, sideMm: 0, turnDeg: 0, periodMs: WalkDenseStreaming.denseMinPeriodMs,
                footHeightMm: 40, balanceGain: 1.0)
            valid = false
        }
        prevFraction = 0
    }

    /// 사이클 경과 시각으로 위상을 갱신하고, 경계 통과 시 target 진폭/주기를
    /// (슬루 제한 하에) committed 로 채택한다.
    /// - Parameters:
    ///   - elapsedMs: 사이클 시작 이후 경과(ms).
    ///   - target: 최신 목표 tuning(콕핏 명령 또는 프리셋 고정값).
    public mutating func advance(elapsedMs: Double, target: WalkMotionLibrary.AdvancedTuning) {
        let period = max(WalkDenseStreaming.denseMinPeriodMs, committed.periodMs)
        let frac = WalkDenseStreaming.cycleTimeMs(elapsedMs: elapsedMs, periodMs: period) / period

        guard valid else {
            committed = target
            valid = true
            prevFraction = frac
            return
        }

        // 진폭(X/Y/A + foot/balance/hip pass-through) — 스윙 중간 경계.
        let ampDue = WalkDenseStreaming.amplitudeLatchPhases.contains {
            Self.crossed(boundary: $0, prev: prevFraction, cur: frac)
        }
        if ampDue {
            committed = WalkMotionLibrary.AdvancedTuning(
                strideMm: Self.slew(committed.strideMm, target.strideMm, WalkDenseStreaming.slewDxMaxMm),
                sideMm: Self.slew(committed.sideMm, target.sideMm, WalkDenseStreaming.slewDyMaxMm),
                turnDeg: Self.slew(committed.turnDeg, target.turnDeg, WalkDenseStreaming.slewDaMaxDeg),
                periodMs: committed.periodMs,  // period 는 DSP 경계에서만.
                footHeightMm: target.footHeightMm,
                balanceGain: target.balanceGain,
                hipPitchOffsetDeg: target.hipPitchOffsetDeg)
        }

        // 주기 — DSP 경계(사이클 wrap).
        if Self.crossed(boundary: WalkDenseStreaming.periodLatchPhase, prev: prevFraction, cur: frac) {
            committed = WalkMotionLibrary.AdvancedTuning(
                strideMm: committed.strideMm,
                sideMm: committed.sideMm,
                turnDeg: committed.turnDeg,
                periodMs: Self.slew(committed.periodMs, target.periodMs, WalkDenseStreaming.slewDPeriodMaxMs),
                footHeightMm: committed.footHeightMm,
                balanceGain: committed.balanceGain,
                hipPitchOffsetDeg: committed.hipPitchOffsetDeg)
        }

        prevFraction = frac
    }

    /// 1-스텝 슬루 클램프 — O2 `SlewToward` 의 축당 로직과 동일(target 으로 max 만큼 전진).
    static func slew(_ current: Double, _ target: Double, _ maxStep: Double) -> Double {
        let delta = target - current
        if delta > maxStep { return current + maxStep }
        if delta < -maxStep { return current - maxStep }
        return target
    }

    /// 경계 위상 `boundary` 가 (prev, cur] 구간 안에 들었는가(사이클 wrap 처리).
    /// DSP 경계(0.0)는 wrap(cur<prev) 시 정확히 1회 발화한다.
    static func crossed(boundary b: Double, prev: Double, cur: Double) -> Bool {
        if prev <= cur {
            return b > prev && b <= cur
        } else {
            // wrap: (prev, 1) ∪ [0, cur]
            return b > prev || b <= cur
        }
    }
}
