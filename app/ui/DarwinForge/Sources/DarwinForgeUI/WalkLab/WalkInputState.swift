import Foundation

/// 사이클 V261-2 (Wave 4.1.1) — `WalkLabSession` 의 UI slider 12개 value struct.
///
/// # 비유
///
/// 자동차의 운전석 다이얼 묶음 — 핸들 각도, 가속 페달 깊이, 변속 레버 위치, 에어컨 강도.
/// 이것들은 한 묶음의 "운전자 입력" 이지만, 엔진 제어 / 변속 / 에어컨 시스템 자체는 별개다.
/// 본 struct 는 보행 slider 13개 의 "사용자 입력 묶음" 만 보관 — 실제 보행 lifecycle
/// (`start` / `syncCommandToEngine` / `runWalkCycle`) 결정은 여전히 `WalkLabSession` 이 한다.
///
/// # 분리 동기 (ADR-002 Phase 4.1.1)
///
/// 종전: `WalkLabSession` (2257 LOC) 안에 UI slider 12개 (`strideMm` / `sideMm` /
/// `turnDeg` / `customPeriodMs` / `footHeightMm` / `balanceGain` / `correctorIntensityLevel` /
/// `hipPitchOffsetTrimDeg` / `customHipRollGain` / `customKneeGain` / `customAnklePitchGain` /
/// `customAnkleRollGain`) 가 hardware-coupled state (status / IMU / pose-apply / safety
/// sampling / fallPrevention) 와 혼재. internal access surface 147 — 변경 영향 추적 곤란.
///
/// 신규: `WalkInputState` 가 slider 12개 만 보관 (pure data, hardware 무관). `WalkLabSession`
/// 가 `inputs: WalkInputState` 로 보유 + 기존 12개 property 는 backward-compat computed
/// delegate 로 transparent forwarding. 외부 view/test 코드 (`session.strideMm = 30` 등)
/// 전부 무수정.
///
/// # 책임 (pure data, lifecycle 없음)
///
/// - 보행 명령: `strideMm` / `sideMm` / `turnDeg` / `customPeriodMs` / `footHeightMm` /
///   `balanceGain`
/// - 자이로 보정: `correctorIntensityLevel` (5단계 discrete)
/// - 자세 trim: `hipPitchOffsetTrimDeg`
/// - Custom gain (`.custom` profile 전용): `customHipRollGain` / `customKneeGain` /
///   `customAnklePitchGain` / `customAnkleRollGain`
///
/// # 비-책임 (`WalkLabSession` 에 잔존)
///
/// 다음은 본 struct 에 옮기지 않는다 — corrector rebuild / engine sync / safety log /
/// harness telemetry 등 부수 효과 cross-cutting 필요:
/// - `didSet` 의 corrector rebuild (`rebuildCorrectorIfCustomChanged`)
/// - `didSet` 의 safety event 로깅 (`logSafetyEvent`)
/// - `didSet` 의 harness telemetry (`.walkLabConfigChange` 등)
/// - `syncCommandToEngine` / `loadPresetDefaultsToSliders` 등 lifecycle method
///
/// `WalkLabSession` 의 computed delegate setter 가 `inputs.foo = newValue` 한 뒤 부수
/// 효과를 자체 트리거. 본 struct 는 pure mutation 만 — 부수 효과 0.
///
/// # 안전 자세 보존 (CRITICAL)
///
/// `WalkInputState()` default 값은 `WalkLabSession` 의 종전 12개 default 와 완전 동일.
/// preset 미선택 시 robot 정지 / 안정 자세 invariant 보존. 변경 금지.
///
/// # Codable
///
/// preset save/load 또는 experiment snapshot 직렬화 용. `WalkLabSession.applyExperimentChange`
/// 가 향후 본 struct 를 단위로 swap 가능.
public struct WalkInputState: Sendable, Equatable, Codable {

    // MARK: - 보행 명령 (Mac sparse engine + onboard 송출 양쪽 반영)

    /// 보폭 (앞, mm/cycle). 0..50. WalkEngine 의 x (m) 와 매핑: x_m = strideMm / 1000.
    public var strideMm: Double

    /// 측면 보폭 (mm/cycle). -25..25. y_m = sideMm / 1000.
    public var sideMm: Double

    /// 회전 (°/cycle). -20..20. a_rad = turnDeg * π/180.
    public var turnDeg: Double

    /// 보행 주기 (ms/cycle). 350..1000. 작을수록 빠른 step. default 600.
    public var customPeriodMs: Double

    /// 발 들기 높이 (mm). 15..80. sweet-spot 30..50. ApplyScope: 시뮬 + 시각화 ✓ /
    /// Onboard 송출 ✗ (별도 PRD).
    public var footHeightMm: Double

    /// 균형 게인 (NimbRo lean_fb_gain 등가). 0..5. sweet-spot 0.5..2.0.
    /// ApplyScope.simOnly — Mac sparse engine ✓ / Onboard send ✗.
    public var balanceGain: Double

    // MARK: - 자이로 보정 강도 (discrete picker, 5 단계)

    /// 자이로 보정 강도 level. 0..4. multiplier: 0=0×, 1=0.5×, 2=1.0× (ROBOTIS default),
    /// 3=1.5×, 4=2.0×. ApplyScope: Mac sparse engine ✓ / Onboard daemon ✗.
    public var correctorIntensityLevel: Int

    // MARK: - 자세 trim

    /// Hip pitch trim slider (°). 0..20. default 13° (ROBOTIS Walking.cpp 원본).
    /// 사용자가 cradle 캘리브레이션 중 0/5/13° 비교해서 mean pitch bias 측정.
    public var hipPitchOffsetTrimDeg: Double

    // MARK: - Custom gain (`.custom` gainProfile 전용)
    //
    // `gainProfile == .custom` 일 때만 `makeCorrector` 가 본 값을 적용. 그 외 profile 은
    // robotisOriginal / v110Experimental 의 base 값 사용 — 본 값 무시.

    /// Custom hip roll gain. 0..2. default 0.5 (robotisOriginal fallback).
    public var customHipRollGain: Double

    /// Custom knee gain. 0..2. default 0.3.
    public var customKneeGain: Double

    /// Custom ankle pitch gain. 0..2. default 0.9.
    public var customAnklePitchGain: Double

    /// Custom ankle roll gain. 0..2. default 1.0.
    public var customAnkleRollGain: Double

    // MARK: - Init (default = 안전 자세 / ROBOTIS 표준)

    /// 모든 slider 12개를 안전 baseline 으로 초기화.
    ///
    /// - 보행 명령: 0/0/0 (정지)
    /// - 주기/발들기/균형: 600ms / 40mm / 1.0 (ROBOTIS 표준)
    /// - 자이로 보정: level 2 (×1.0 ROBOTIS)
    /// - Hip pitch trim: 13° (ROBOTIS 원본)
    /// - Custom gain: robotisOriginal fallback (0.5/0.3/0.9/1.0)
    public init(
        strideMm: Double = 0,
        sideMm: Double = 0,
        turnDeg: Double = 0,
        customPeriodMs: Double = 600,
        footHeightMm: Double = 40,
        balanceGain: Double = 1.0,
        correctorIntensityLevel: Int = 2,
        hipPitchOffsetTrimDeg: Double = 13.0,
        customHipRollGain: Double = 0.5,
        customKneeGain: Double = 0.3,
        customAnklePitchGain: Double = 0.9,
        customAnkleRollGain: Double = 1.0
    ) {
        self.strideMm = strideMm
        self.sideMm = sideMm
        self.turnDeg = turnDeg
        self.customPeriodMs = customPeriodMs
        self.footHeightMm = footHeightMm
        self.balanceGain = balanceGain
        self.correctorIntensityLevel = correctorIntensityLevel
        self.hipPitchOffsetTrimDeg = hipPitchOffsetTrimDeg
        self.customHipRollGain = customHipRollGain
        self.customKneeGain = customKneeGain
        self.customAnklePitchGain = customAnklePitchGain
        self.customAnkleRollGain = customAnkleRollGain
    }
}
