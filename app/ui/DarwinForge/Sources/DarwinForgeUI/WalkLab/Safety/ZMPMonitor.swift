import Foundation

/// **V287-2 (2026-05-24, V286-3 권고)** — ZMP (Zero Moment Point) stability gate.
///
/// # 비유
///
/// 사람이 줄타기 할 때 발 아래 줄에서 너무 벗어나면 떨어진다. ZMP 도 같다 —
/// CoP (체압 중심) 가 양 발이 만드는 polygon 안에 있어야 안정. 밖으로 나가면
/// 곧 넘어진다.
///
/// # 알고리즘 (Vukobratović 1969 기반)
///
/// 1. IMU pitch/roll + foot pose 로 CoP 추정 (FSR 있으면 그대로 사용)
/// 2. support polygon = 양 발 사각형 + tolerance
/// 3. margin = polygon edge 까지 거리 — 양수 = 안전, 음수 = 위험
/// 4. hysteresis: 연속 N cycle 위험 시만 veto (false-positive 방지)
///
/// # 안전 정책 (Conservative — V286-3 fall risk H3 mitigation)
///
/// default = observe-only (margin 로깅만, 실제 차단 X). `enforceEnabled = true`
/// 명시 시만 step veto / amplitude scale. 사용자가 위험 confirmation 후 켜기.
///
/// # 통합 site
///
/// `WalkLabSession+Tick.swift::tickRunSafetyPipeline()` 의 L3/L4/L0 layer 와
/// 동일 phase. observe-only 면 telemetry 만, enforce 면 veto verdict.
@MainActor
public final class ZMPMonitor {

    /// support polygon margin 임계 (m). 양수 = 안전.
    /// V286-3 권고 2cm — 측정 noise (IMU ±0.5°, foot pose ±5mm) 보다 큼.
    public static let marginThresholdMeters: Double = 0.02

    /// hysteresis cycle count (false-positive 차단).
    /// V286-3 safety risk mitigation — 단일 sample veto 가 정상 sway 의 spike 에
    /// false-positive trigger 하지 않도록 2 cycle (400ms @ 5Hz) 연속 충족 시만 발화.
    public static let hysteresisCycles: Int = 2

    /// CoM 높이 (m) — ROBOTIS OP2 약 0.30m (hip joint 기준 stride 중점 추정).
    /// 정확한 inverted-pendulum CoP 식은 mass distribution 필요하나, IMU tilt 만으로
    /// 1차 근사 가능: CoP ≈ CoM_height × tan(θ).
    public static let comHeightMeters: Double = 0.30

    /// 발 padding — foot rectangle 가장자리 tolerance (m).
    /// `xPaddingMeters` = sagittal (앞뒤) 5cm, `yPaddingMeters` = lateral 3cm.
    /// OP2 foot size 약 100mm × 60mm 의 보수적 boundary.
    public static let xPaddingMeters: Double = 0.05
    public static let yPaddingMeters: Double = 0.03

    /// 연속 위험 cycle 카운터. `evaluate(...)` 가 borderline/safe 진입 시 0 리셋.
    private var dangerCycleCount: Int = 0

    /// observe-only vs enforce mode.
    /// default = false (observe-only). 사용자가 명시 토글 시만 true.
    public var enforceEnabled: Bool = false

    /// 마지막 평가 시 margin (m, UI 표시용). 양수 = 안전.
    public private(set) var lastMargin: Double = 0

    /// ZMP 평가 결과.
    public enum Verdict: Equatable, Sendable {
        /// margin >= threshold — 안정.
        case safe
        /// 0 <= margin < threshold — 경계. enforce 시에도 veto 안 함.
        case borderline
        /// margin < 0 — polygon 밖. 연속 횟수 누적 중 (veto 임박).
        case unsafe(consecutive: Int)
        /// hysteresis 충족 + enforce ON — 실제 차단.
        case veto
    }

    /// 마지막 verdict (snapshot, telemetry/UI 용).
    public private(set) var lastVerdict: Verdict = .safe

    public init() {}

    /// 매 tick 호출. CoP estimate + support polygon margin 평가.
    ///
    /// # CoP 추정 식
    ///
    /// inverted-pendulum 1차 근사:
    ///   CoP_x = sin(pitch) × CoM_height   (pitch > 0 = 앞으로 기울 = CoP 앞쪽)
    ///   CoP_y = sin(roll) × CoM_height    (roll > 0 = 우측 기울 = CoP 우측)
    ///
    /// # support polygon
    ///
    /// 양 발 bounding box + padding. 단일 발 지지 phase 도 동일 식 (footCenter 가
    /// 같은 발이면 polygon 작아짐 — 자연스럽게 보수적).
    ///
    /// - Parameters:
    ///   - imuRollDeg: 현재 IMU roll (deg, 양수 = 우측 기울임)
    ///   - imuPitchDeg: 현재 IMU pitch (deg, 양수 = 앞으로 기울임)
    ///   - leftFootCenter: 좌측 발 중심 (x, y 미터, robot frame)
    ///   - rightFootCenter: 우측 발 중심
    /// - Returns: Verdict — safe/borderline/unsafe/veto.
    @discardableResult
    public func evaluate(
        imuRollDeg: Double,
        imuPitchDeg: Double,
        leftFootCenter: (x: Double, y: Double),
        rightFootCenter: (x: Double, y: Double)
    ) -> Verdict {
        let margin = computeMargin(
            imuRollDeg: imuRollDeg,
            imuPitchDeg: imuPitchDeg,
            leftFootCenter: leftFootCenter,
            rightFootCenter: rightFootCenter
        )
        lastMargin = margin

        let verdict = classifyMargin(margin)
        lastVerdict = verdict
        return verdict
    }

    /// margin 계산 — CoP estimate + support polygon distance.
    /// helper 분리 — `evaluate(...)` 30 line 제약 + 단위 테스트 용이.
    private func computeMargin(
        imuRollDeg: Double,
        imuPitchDeg: Double,
        leftFootCenter: (x: Double, y: Double),
        rightFootCenter: (x: Double, y: Double)
    ) -> Double {
        // CoP estimate — inverted-pendulum 1차 근사.
        let copX = sin(imuPitchDeg * .pi / 180) * Self.comHeightMeters
        let copY = sin(imuRollDeg * .pi / 180) * Self.comHeightMeters

        // support polygon = 양 발 bounding box + padding.
        let minX = min(leftFootCenter.x, rightFootCenter.x) - Self.xPaddingMeters
        let maxX = max(leftFootCenter.x, rightFootCenter.x) + Self.xPaddingMeters
        let minY = min(leftFootCenter.y, rightFootCenter.y) - Self.yPaddingMeters
        let maxY = max(leftFootCenter.y, rightFootCenter.y) + Self.yPaddingMeters

        // margin = polygon 4 edge 까지 최소 거리 (음수 = 밖).
        let marginX = min(copX - minX, maxX - copX)
        let marginY = min(copY - minY, maxY - copY)
        return min(marginX, marginY)
    }

    /// margin → Verdict 분류 + hysteresis counter 갱신.
    /// guard clause + hysteresis: safe/borderline 진입 시 counter 0 리셋.
    private func classifyMargin(_ margin: Double) -> Verdict {
        if margin >= Self.marginThresholdMeters {
            dangerCycleCount = 0
            return .safe
        }
        if margin >= 0 {
            dangerCycleCount = 0
            return .borderline
        }
        dangerCycleCount += 1
        if enforceEnabled && dangerCycleCount >= Self.hysteresisCycles {
            return .veto
        }
        return .unsafe(consecutive: dangerCycleCount)
    }

    /// reset — start/stop/recovery 시 호출. hysteresis counter + cached margin 초기화.
    public func reset() {
        dangerCycleCount = 0
        lastMargin = 0
        lastVerdict = .safe
    }
}
