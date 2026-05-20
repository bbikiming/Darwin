import Foundation

/// **v1.11.21 (2026-05-20)** — Scene HUD 의 derivation 헬퍼.
///
/// 별도 struct 로 분리한 이유:
/// 1. 단위 테스트 가능 (SwiftUI View private 의존성 제거)
/// 2. 모델 가정값 (h_com, support polygon) 단일 진실 출처
/// 3. 다른 컴포넌트 (FallPreventionMonitor 등) 재사용 가능
///
/// 모든 함수는 pure — 입력만으로 출력 결정, 외부 의존 없음.
public enum HUDMetrics {

    // MARK: - 모델 가정값

    /// ROBOTIS DARwIn-OP2 standing CoM height — hip pivot 근방 추정 (mm).
    ///
    /// **v1.11.22 (2026-05-20) 정정**: 종전 290mm 는 pelvis 위 (어깨 근방) 으로
    /// 과대평가. 정정:
    /// - ROBOTIS DARwIn-OP2 공식 spec: height 454.5mm
    /// - Humanoid robot 통상 standing CoM ≈ 약 0.5 × height ≈ 약 220mm (hip pivot 근방)
    /// - 출처: ROBOTIS 공식 datasheet height 454.5mm, humanoid 통상 CoM ratio 0.48-0.52
    ///
    /// 정확한 CoM 은 forward kinematics + 각 link mass 가중평균 필요. 본 모델은
    /// inverted-pendulum approximation — diagnostic UI 용. 다른 robot 모델 지원 시
    /// `RobotModelConfig.comHeightMm` 로 분리 권장.
    public static let comHeightMm: Double = 220.0

    /// 발 지지 폴리곤 반경 — single-foot stance lateral 기준 (mm).
    ///
    /// **v1.11.22 (2026-05-20) 정정**: 종전 70mm 는 single-foot stance 한계로
    /// 과대평가. 정정:
    /// - ROBOTIS-OP2 발 dimensions: 약 100mm (length) × 60mm (width)
    /// - single-foot stance lateral 안전 반경: foot width / 2 = 30mm
    /// - forward/back 방향은 더 여유 있음 (50mm) 이나 lateral 보수 사용
    ///
    /// CoM saturation% = `|offset| / supportRadiusMm × 100`. 100% = 발 경계 도달.
    /// 사용자 안전 측면에서 보수적으로 lateral 한계 사용.
    public static let supportRadiusMm: Double = 30.0

    // MARK: - Center of Mass 추정 (EST)

    /// 무게중심 평면 offset (mm). small-angle inverted-pendulum approx.
    /// `offset_mm = h × sin(θ)`.
    ///
    /// - Parameters:
    ///   - angleDeg: pitch (forward offset) 또는 roll (lateral offset).
    ///   - h: CoM 높이. 기본 `comHeightMm`.
    /// - Returns: angle 양수 → 양수 offset. NaN/Inf 입력 → 0.
    public static func comOffsetMm(angleDeg: Double, h: Double = comHeightMm) -> Double {
        guard angleDeg.isFinite else { return 0 }
        return h * sin(angleDeg * .pi / 180.0)
    }

    /// offset → support polygon % (0..100). NaN/Inf guard 포함.
    /// v1.11.22.1 (Codex LOW-1 fix): `offsetMm.isFinite` 가드 — `min(100, NaN) = 100`
    /// 의 misleading 차단.
    public static func comSaturationPct(offsetMm: Double,
                                         polygonR: Double = supportRadiusMm) -> Double {
        guard offsetMm.isFinite, polygonR > 0 else { return 0 }
        return min(100, abs(offsetMm) / polygonR * 100)
    }

    // MARK: - Ankle leveling (EST)

    /// 발판 잔여각 추정 — body pitch 가 보정 후 footplate 에 남는 각도.
    ///
    /// **v1.11.22 (2026-05-20) — 부호 정정**: 종전 `bodyPitch + correctionAnklePitch`
    /// 는 R 발에서 잘못된 결과 (BalanceCorrector 가 L/R motor mirror 부호로 출력 →
    /// 외부 footplate 효과는 두 발 모두 dorsiflex 같은 방향). magnitude 기반 모델로
    /// 정정 — motor sign convention 무관, 외부 동작 의도와 일관.
    ///
    /// 식:
    /// - corrector OFF / actuallyApplied=false: `bodyPitch` (보정 미적용 그대로)
    /// - corrector ON + actuallyApplied=true:
    ///   `sign(bodyPitch) × max(0, |bodyPitch| - |correctionAnklePitch|)`
    ///   (corrector 가 body 의 반대 방향으로 동작 가정 — footplate 평행 의도)
    ///
    /// **v1.11.22.1 (Codex HIGH-3 fix)**: `actuallyApplied` 추가 — observeOnly 또는
    /// applyToRobot=false 모드에서는 corrections 가 계산되지만 motor 에 실제 적용 X.
    /// 이 경우 잔여각 식 적용 시 "보정 효과 가짜 표시" misleading → body 그대로 표기.
    ///
    /// 한계 (EST): forge-core 의 정확한 motor → external angle 변환 미사용. 실 footplate
    /// 각도는 forward kinematics 로만 정확히 산출 가능. 본 모델은 magnitude approx.
    /// 0 에 가까울수록 발판이 지면과 평행.
    public static func ankleResidualDeg(bodyPitch: Double,
                                         correctionAnklePitch: Double?,
                                         correctorEnabled: Bool,
                                         actuallyApplied: Bool = true) -> Double {
        guard bodyPitch.isFinite else { return 0 }
        guard correctorEnabled, actuallyApplied,
              let c = correctionAnklePitch, c.isFinite else {
            return bodyPitch
        }
        let absBody = abs(bodyPitch)
        let absCorr = abs(c)
        let absResidual = max(0, absBody - absCorr)
        // sign 보존 — body 방향 (앞/뒤) 유지.
        return absBody > 0 ? copysign(absResidual, bodyPitch) : 0
    }

    // MARK: - Walking metrics (DERIVED)

    /// 보행 속도 (km/h). `strideMm / periodMs × 3.6`.
    /// periodMs 가 너무 작으면 50ms 로 clamp (div-by-zero 가드).
    public static func speedKmh(strideMm: Double, periodMs: Double) -> Double {
        let safePeriod = max(50.0, periodMs.isFinite ? periodMs : 50.0)
        let safeStride = strideMm.isFinite ? strideMm : 0
        let mPerSec = safeStride / safePeriod  // mm/ms = m/s
        return mPerSec * 3.6
    }

    /// Cadence (steps per minute). cycle 1회 = 2 step 가정.
    /// `2 × 60000 / periodMs`.
    public static func cadenceSpm(periodMs: Double) -> Double {
        let safePeriod = max(50.0, periodMs.isFinite ? periodMs : 50.0)
        return 2.0 * 60000.0 / safePeriod
    }

    // MARK: - Link freshness (LIVE)

    /// Lag tier — 색 group 결정용.
    /// - 0: <200ms (excellent)
    /// - 1: <500ms (acceptable)
    /// - 2: <2000ms (degraded)
    /// - 3: ≥2000ms (stale)
    public static func lagTier(_ lagMs: Double) -> Int {
        if !lagMs.isFinite || lagMs < 0 { return 3 }
        if lagMs < 200  { return 0 }
        if lagMs < 500  { return 1 }
        if lagMs < 2000 { return 2 }
        return 3
    }

    /// Lag formatting — `<1s` 면 ms, `<60s` 면 s, 그 외 STALE.
    public static func formatLag(_ ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "STALE" }
        if ms < 1000 { return String(format: "%.0fms", ms) }
        if ms < 60000 { return String(format: "%.1fs", ms / 1000) }
        return "STALE"
    }

    // MARK: - Phase parsing (LIVE)

    /// "PHASE3" → 3. 안 맞으면 nil (idle/invalid).
    public static func phaseIndex(label: String) -> Int? {
        guard let lastChar = label.last, let n = Int(String(lastChar)) else { return nil }
        return max(0, min(5, n))
    }
}
