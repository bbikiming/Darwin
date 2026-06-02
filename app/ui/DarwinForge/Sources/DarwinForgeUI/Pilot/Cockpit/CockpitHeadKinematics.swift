import Foundation

/// 머리(pan/tilt) **rate-모드 각도 적분** — pure 함수로 단위 테스트 가능.
///
/// # 비유
///
/// 자동차 전동 사이드미러 조절 스위치. 스위치를 누르고 있는 동안 거울이 그 방향으로
/// 계속 움직이고, 손을 떼면 그 각도에서 멈춰 유지된다. 끝까지 가면 기계적 한계에서
/// 더 안 움직인다. 머리 조종도 같다 — 축을 기울인 동안만 회전, 놓으면 그 시선 유지.
///
/// # rate 모드란
///
/// 입력 축의 기울기(`inputNorm`, -1...1)가 머리의 **각속도**가 된다. 매 tick
/// `currentDeg += inputNorm × rateDegPerSec × dt` 로 적분하고 `limit` 으로 clamp.
/// 입력이 0이면 적분이 멈춰 머리가 그 각도를 유지하고, 끝까지 밀면 공식 한계에서
/// saturate.
///
/// self-centering 스틱(손 떼면 0 복귀)에서도 머리가 정면으로 튕겨 돌아오지 않아
/// "둘러보기(look-around)" UX 에 적합 — 절대 매핑(축 위치=각도)의 반대.
public enum CockpitHeadKinematics {
    /// 머리 pan(좌우) full-deflection 각속도 (deg/sec).
    /// **2026-06-02 하향 (160→55)**: 160°/s 는 전 범위를 ~1초에 쓸어버려 "너무 빠르고
    /// 가변성 없음"으로 느껴졌다(끝까지 밀든 살짝 밀든 즉시 한계 도달). 속도=inputNorm×rate
    /// 비례식이므로 rate 를 낮추면 미세 입력=느림 / 끝까지=중간속도로 **가변 제어**가 살아난다.
    /// **2026-06-02 추가 하향 (55→42)**: 온보드(SSH)는 로봇 헤드 서보 moving-speed 가
    /// 0(무제한)이라 매 cmd 폴(10Hz)마다 목표각으로 *즉시 점프* → 빠릿빠릿. sweep 속도를 더
    /// 낮추면 폴당 각도 step(=rate÷10Hz)이 작아져 점프 크기가 줄어 체감이 부드러워진다.
    /// (완전한 부드러움은 로봇측 서보 속도 제한 필요 — 펌웨어. 그 전까지의 Mac측 완화책.)
    public static let panRateDegPerSec: Double = 42.0
    /// 머리 tilt(상하) full-deflection 각속도 (deg/sec). **40→30 하향** (동일 원리).
    public static let tiltRateDegPerSec: Double = 30.0

    /// 한 tick 적분 + clamp.
    ///
    /// - Parameters:
    ///   - currentDeg: 현재 머리 각도(deg).
    ///   - inputNorm: 입력 축 정규화 값 (-1...1). 부호 = 회전 방향.
    ///   - rateDegPerSec: full deflection 각속도.
    ///   - dt: 경과 시간(초).
    ///   - limit: 공식 허용 각도 범위 (예: headPan -90...90, headTilt -45...45).
    /// - Returns: clamp 된 새 각도.
    public static func integrate(currentDeg: Double,
                                 inputNorm: Double,
                                 rateDegPerSec: Double,
                                 dt: Double,
                                 limit: ClosedRange<Double>) -> Double {
        let next = currentDeg + inputNorm * rateDegPerSec * dt
        return min(limit.upperBound, max(limit.lowerBound, next))
    }

    /// Dynamixel(MX-28) **moving-speed 레지스터 단위**로 각속도를 변환.
    ///
    /// MX-28 의 moving-speed 1 단위 ≈ 0.114 rpm ≈ 0.684 °/s. 머리 모터를 적분 rate 와
    /// **같은 속도**로 설정하면, 50ms 간격으로 목표각을 갱신해도 모터가 그 사이를 일정
    /// 속도로 메워 stop-and-go(드드득) 없이 매끄럽게 추종한다. (speed=0 은 factory
    /// default = 무제한 → 즉시 점프이므로 부드러움에 부적합.)
    ///
    /// - Returns: 1...1023 으로 clamp 된 moving-speed 단위.
    public static func movingSpeedUnits(forRateDegPerSec rate: Double) -> UInt16 {
        let degPerSecPerUnit = 0.684
        let units = (abs(rate) / degPerSecPerUnit).rounded()
        return UInt16(max(1.0, min(1023.0, units)))
    }
}
