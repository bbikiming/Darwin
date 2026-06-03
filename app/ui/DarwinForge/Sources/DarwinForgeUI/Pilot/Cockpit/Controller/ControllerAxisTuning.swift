import Foundation

/// 축별 입력 성형 파라미터 — 순수 값 타입.
///
/// DS4Windows / AntiMicroX / Betaflight Rates 의 모범 사례를 통합:
/// innerDeadzone → anti-deadzone → expo → sensitivity → invert.
///
/// `shaped(_:)` 는 **순수 함수** 로 side-effect 없이 [-1, 1] → [-1, 1] 변환한다.
public struct ControllerAxisTuning: Codable, Equatable, Sendable {

    // MARK: - 파라미터 기본값 상수

    /// VirtualJoystickMapper 와 동일 데드존 관례 (0.10).
    public static let defaultInnerDeadzone: Double = 0.10
    /// 안티-데드존 기본 0 (비활성).
    public static let defaultAntiDeadzone:  Double = 0.0
    /// 최대 입력 범위 (1.0 = 100%).
    public static let defaultMaxZone:       Double = 1.0
    /// expo 기본 0 (선형).
    public static let defaultExpo:          Double = 0.0
    /// 감도 기본 1.0.
    public static let defaultSensitivity:   Double = 1.0

    // MARK: - 파라미터 클램프 범위

    /// expo 범위 0(선형) … 1(큐빅 전체).
    public static let expoRange:       ClosedRange<Double> = 0.0...1.0
    /// 감도 범위 0.1 … 3.0.
    public static let sensitivityRange: ClosedRange<Double> = 0.1...3.0

    // MARK: - 프로퍼티

    /// 중앙 데드존 — 이 크기 미만의 입력은 0 처리. 드리프트 방지. [0, 1)
    public var innerDeadzone: Double
    /// 데드존 직후 최소 출력 보장 — 로봇이 스틱 약간 움직여도 즉시 반응. [0, 1)
    public var antiDeadzone:  Double
    /// 유효 입력 최대값 — 1.0 미만이면 스틱 끝까지 눌러도 maxZone 까지만. (0, 1]
    public var maxZone:       Double
    /// 지수 혼합 계수 — 0 = 선형, 1 = 순수 t^3. 중앙 둔감 / 끝단 보존. [0, 1]
    public var expo:          Double
    /// 출력 전체 스케일. [0.1, 3.0]
    public var sensitivity:   Double
    /// true 이면 출력 부호 반전.
    public var invert:        Bool

    // MARK: - Initializer

    public init(
        innerDeadzone: Double = defaultInnerDeadzone,
        antiDeadzone:  Double = defaultAntiDeadzone,
        maxZone:       Double = defaultMaxZone,
        expo:          Double = defaultExpo,
        sensitivity:   Double = defaultSensitivity,
        invert:        Bool   = false
    ) {
        self.innerDeadzone = innerDeadzone
        self.antiDeadzone  = antiDeadzone
        self.maxZone       = maxZone
        self.expo          = expo
        self.sensitivity   = sensitivity
        self.invert        = invert
    }

    // MARK: - shaped(_:)

    /// 원시 축 값 `raw ∈ [-1, 1]` → 성형된 값 `[-1, 1]`.
    ///
    /// # 처리 순서
    /// 1. raw → [-1, 1] clamp
    /// 2. magnitude `m = |raw|`, `sign = raw ≥ 0 ? +1 : -1`
    /// 3. `m < innerDeadzone` → 0 반환 (데드존)
    /// 4. rescale: `t = (m − innerDeadzone) / (maxZone − innerDeadzone)` clamp [0, 1]
    /// 5. expo 혼합: `e = (1 − expo) * t + expo * t³`  (f(0)=0, f(1)=1, 단조증가)
    /// 6. anti-deadzone: `out = antiDeadzone + (1 − antiDeadzone) * e`  (단 e > 0 일 때만)
    /// 7. `out × sensitivity` → [0, 1] clamp
    /// 8. sign 복원 → invert 이면 부호 반전 → [-1, 1] clamp
    public func shaped(_ raw: Double) -> Double {
        // 1. clamp raw to [-1, 1]
        let clamped = max(-1.0, min(1.0, raw))

        // 2. magnitude & sign
        let m    = abs(clamped)
        let sign = clamped >= 0 ? 1.0 : -1.0

        // 3. innerDeadzone 적용
        guard m >= innerDeadzone else { return 0.0 }

        // 4. rescale to [0, 1] using [innerDeadzone, maxZone] 범위
        let denominator = maxZone - innerDeadzone
        let t: Double
        if denominator <= 0 {
            // maxZone ≤ innerDeadzone 인 퇴화 케이스: 입력=1로 처리
            t = 1.0
        } else {
            t = max(0.0, min(1.0, (m - innerDeadzone) / denominator))
        }

        // 5. expo 혼합: e = (1 - expo) * t + expo * t^3
        //    expo=0 → 선형, expo=1 → 큐빅. 중앙 둔감, 끝단 보존.
        //    f(0)=0, f(1)=1, 단조증가 (모든 expo ∈ [0,1]).
        let expoC = max(0.0, min(1.0, expo))
        let e = (1.0 - expoC) * t + expoC * t * t * t

        // 6. anti-deadzone 보정: e > 0 일 때만 최소 출력 antiDeadzone 보장
        let antiOut: Double
        if e > 0 {
            antiOut = antiDeadzone + (1.0 - antiDeadzone) * e
        } else {
            antiOut = 0.0
        }

        // 7. sensitivity 적용 + [0, 1] clamp
        let sensC = max(ControllerAxisTuning.sensitivityRange.lowerBound,
                        min(ControllerAxisTuning.sensitivityRange.upperBound, sensitivity))
        let scaled = max(0.0, min(1.0, antiOut * sensC))

        // 8. sign 복원, invert 처리, 최종 [-1, 1] clamp
        let signed = scaled * sign
        let result = invert ? -signed : signed
        return max(-1.0, min(1.0, result))
    }
}
