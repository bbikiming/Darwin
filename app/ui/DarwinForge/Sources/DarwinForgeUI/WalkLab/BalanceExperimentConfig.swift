import Foundation

/// **v1.11 (2026-05-17)** — 자이로 보정의 4축 분리 (사용자 prompt).
///
/// Hybrid B+A 와 ROBOTIS 부호는 다른 차원이고, gain profile 도 분리되어야 함.
/// 시뮬레이션 결과를 "정답" 으로 박지 말고, 사용자가 4축 조합을 선택하여 실 robot 으로
/// A/B 비교할 수 있게 함.

/// 보정 알고리즘 mode (algorithm 축).
public enum BalanceAlgorithmMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 보정 자체 OFF — pose 그대로 송출. fall prevention 자체는 다른 가드 (L3/predictor) 가 작동.
    case off
    /// ROBOTIS Walking.cpp 의 단순 P-control + LPF + deadband. v1.9.x 의 기존 동작.
    case robotisPControl
    /// v1.10 실험 — slow EMA (chronic drift) + phase-locked residual (walking sway 제외).
    /// 시뮬상 mean pitch 45배 개선 보고 (unverified on real hardware).
    case hybridBA
    /// observe-only — corrections 계산하고 로그에 기록하지만 pose 적용 X.
    /// 위험한 실험 (alternateDiagnostic sign, intensity 4 등) 의 safe preview.
    case observeOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:              return "꺼짐"
        case .robotisPControl:  return "ROBOTIS 기본"
        case .hybridBA:         return "Hybrid B+A (실험)"
        case .observeOnly:      return "관찰만 (로그)"
        }
    }

    public var icon: String {
        switch self {
        case .off:              return "power.circle"
        case .robotisPControl:  return "shield.fill"
        case .hybridBA:         return "brain"
        case .observeOnly:      return "eye"
        }
    }
}

/// 부호 convention 축 (sign 축).
/// **주의**: alternateDiagnostic 은 진단 실험 — 실 robot 적용 시 fall 가속 위험.
public enum BalanceSignConvention: String, CaseIterable, Codable, Sendable, Identifiable {
    /// ROBOTIS Walking.cpp oracle (정상 회복 방향).
    case robotisWalkingCpp
    /// 진단 실험 — knee R/L + anklePitch R/L 4관절의 부호 반전. lateral (hipRoll/ankleRoll)
    /// 은 안전상 그대로. **실 robot 적용 시 fall 가속** — observe-only 강제 권장.
    case alternateDiagnostic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .robotisWalkingCpp:    return "ROBOTIS 기준"
        case .alternateDiagnostic:  return "반대 부호 실험 ⚠️"
        }
    }
}

/// **v1.11.3 (2026-05-18) — P1.1 부호 정규화 축**.
///
/// 코드 컨벤션 (BalanceCorrector 의 `pitchErrDeg` 양수=앞기울) 과 실 robot IMU 부호 일치
/// 여부에 따라 입력 단계에서 정규화. 기존 동작 보존을 위해 default = `.imuRaw`.
///
/// **GPT 검증 (2026-05-18)**: 부호 전체 뒤집기 전에 정적 캘리브레이션 → 결과 기반 토글.
/// `imuFilter.pitchDeg` 자체는 건드리지 않고 corrections 입력에서 명시적 정규화.
/// → blast radius 최소 (UI 게이지 / fall predictor / safety state 등 IMU 소비자 영향 X).
public enum BalancePitchInputConvention: String, CaseIterable, Codable, Sendable, Identifiable {
    /// **Default** — `corrections(pitchErrDeg: imuPitchDeg)` 그대로 전달 (현재 동작).
    /// 코드 컨벤션 가정: 양수 = 앞기울.
    case imuRaw
    /// **Opt-in** — `corrections(pitchErrDeg: -imuPitchDeg)`. 실 robot 에서 앞기울 = 음수
    /// 일 때 정규화. P1.0 정적 캘리브레이션으로 확인 후 사용.
    case negateForwardIsNegative

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .imuRaw:                  return "원본 (양수=앞기울 가정)"
        case .negateForwardIsNegative: return "정규화 (음수=앞기울 보정)"
        }
    }
}

/// Gain profile 축.
public enum BalanceGainProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    /// ROBOTIS Walking.cpp oracle gain (hipR 0.5, knee 0.3, ankP 0.9, ankR 1.0).
    case robotisOriginal
    /// v1.10 random search 결과 (anklePitch 0.9→1.5, ankleRoll 1.0→0.5). 실 검증 전.
    case v110Experimental
    /// 사용자 슬라이더 (현재 intensityLevel 만 노출, 4 gain 개별 조절은 expert).
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .robotisOriginal:   return "ROBOTIS 원본"
        case .v110Experimental:  return "v1.10 실험"
        case .custom:            return "사용자 지정"
        }
    }
}

/// 자이로 보정 4축 통합 config.
public struct BalanceExperimentConfig: Codable, Equatable, Sendable {
    public var algorithmMode: BalanceAlgorithmMode
    public var signConvention: BalanceSignConvention
    public var gainProfile: BalanceGainProfile
    /// true 면 corrections 가 실 robot pose 에 적용. false 면 observe-only 등가.
    /// 사용자가 명시 토글 — alternateDiagnostic 일 때 자동 false.
    public var applyToRobot: Bool
    /// **v1.11.3 (2026-05-18)** — corrections 입력 부호 정규화 (P1.1, opt-in).
    /// Default `.imuRaw` = 현재 동작 (코드 컨벤션 가정 그대로). 사용자가 P1.0 정적
    /// 캘리브레이션 결과 보고 `.negateForwardIsNegative` 로 전환 가능.
    public var pitchInputConvention: BalancePitchInputConvention

    public init(
        algorithmMode: BalanceAlgorithmMode = .robotisPControl,
        signConvention: BalanceSignConvention = .robotisWalkingCpp,
        gainProfile: BalanceGainProfile = .robotisOriginal,
        applyToRobot: Bool = true,
        pitchInputConvention: BalancePitchInputConvention = .imuRaw
    ) {
        self.algorithmMode = algorithmMode
        self.signConvention = signConvention
        self.gainProfile = gainProfile
        self.applyToRobot = applyToRobot
        self.pitchInputConvention = pitchInputConvention
    }

    // MARK: - Codable backward compat
    //
    // v1.11.3 신규 필드 `pitchInputConvention` 은 기존 JSON / persisted state 디코드
    // 시 default = `.imuRaw` 적용. 명시적 init(from:) 으로 옵션 처리.
    private enum CodingKeys: String, CodingKey {
        case algorithmMode, signConvention, gainProfile, applyToRobot, pitchInputConvention
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.algorithmMode = try c.decode(BalanceAlgorithmMode.self, forKey: .algorithmMode)
        self.signConvention = try c.decode(BalanceSignConvention.self, forKey: .signConvention)
        self.gainProfile = try c.decode(BalanceGainProfile.self, forKey: .gainProfile)
        self.applyToRobot = try c.decode(Bool.self, forKey: .applyToRobot)
        self.pitchInputConvention = try c.decodeIfPresent(BalancePitchInputConvention.self, forKey: .pitchInputConvention) ?? .imuRaw
    }

    /// **Default — 사용자 robot 의 baseline. ROBOTIS 검증된 기준.**
    public static let defaultRobotis = BalanceExperimentConfig()

    /// **v1.10 실험 profile — 시뮬상 권장이지만 실 검증 전. observe-only 가 안전 default.**
    public static let v110Observe = BalanceExperimentConfig(
        algorithmMode: .observeOnly,
        signConvention: .robotisWalkingCpp,
        gainProfile: .v110Experimental,
        applyToRobot: false
    )

    /// **v1.11.3 (2026-05-18) — 실 fall 데이터 입증 후 observe-only 로 강등**.
    ///
    /// 종전 (`applyToRobot=true`) 은 2026-05-18 실 robot 세션에서 mean pitch -25~-31°,
    /// peak -38°, 1.4~2.6s 내 fall 확인 → 사용자 안전을 위해 preset 자체를 observe-only
    /// 로 강제. struct 는 backward-compat 유지하되 동작은 v110Observe 와 동일.
    /// 실 적용을 다시 시도하려면 (1) 부호 컨벤션 재검증 + (2) gain 재튜닝 + (3) Mac 실
    /// robot 회귀 protocol 통과 후 별도 PR 로 부활.
    public static let v110Apply = BalanceExperimentConfig(
        algorithmMode: .hybridBA,
        signConvention: .robotisWalkingCpp,
        gainProfile: .v110Experimental,
        applyToRobot: false  // 실 fall 데이터 입증으로 강등 — observe-only 동작
    )

    // MARK: - Safety validation

    /// 위험 조합 검사 — 실 robot 적용 차단 또는 경고.
    public enum SafetyVerdict: Equatable, Sendable {
        case safe
        case caution(String)
        case blocked(String)
    }

    public var safetyVerdict: SafetyVerdict {
        // 1. alternateDiagnostic sign 은 실 적용 시 fall 가속 — 강제 차단.
        if signConvention == .alternateDiagnostic && applyToRobot {
            return .blocked("반대 부호 실험은 실 robot 적용 차단됨 (fall 가속 위험). observe-only 로 전환하세요.")
        }
        // 2. observeOnly 는 항상 안전 (pose 변경 안 함).
        if algorithmMode == .observeOnly {
            return .safe
        }
        // **v1.11.3 (2026-05-18) — 실 데이터 입증 격상: caution → blocked**.
        // 2026-05-18 실 robot 세션 (10:30:42, 10:30:49, 10:31:04) 에서 hybridBA +
        // v110Experimental + applyToRobot 조합이 mean pitch -25~-31°, peak -38°,
        // 1.4~2.6s 내 fall 시도 확인. caution 등급으로는 사용자 보호 불충분 — blocked
        // 격상하여 실 적용 자체를 차단. observe-only 는 그대로 허용 (데이터 수집).
        // 3. hybridBA + 실 적용 — 실 fall 데이터 입증 차단.
        if algorithmMode == .hybridBA && applyToRobot {
            return .blocked("Hybrid B+A 실 적용 차단 — 2026-05-18 실 데이터: mean pitch -25~-31°, peak -38°, 1.4-2.6s 내 fall. observe-only 로 전환하세요.")
        }
        // 4. v110Experimental gain + 실 적용 — 실 fall 데이터 입증 차단.
        if gainProfile == .v110Experimental && applyToRobot {
            return .blocked("v1.10 gain 실 적용 차단 — 2026-05-18 실 데이터 fall 확인. observe-only 또는 robotisOriginal gain 으로 전환하세요.")
        }
        return .safe
    }

    /// **v1.11.2 (2026-05-18 사용자 review P1) — 실 robot 적용 위험 조합 판정**.
    /// 모든 config 변경 진입점이 이 값으로 confirmation 필요 여부 결정.
    /// 종전엔 BalanceExperimentControls 의 toggle setter 안에만 있어서 profile picker /
    /// 다른 axis picker 경로로 우회되었음. 이제 단일 출처.
    ///
    /// 위험 조합 = applyToRobot=true && (any of):
    ///   - algorithmMode == .hybridBA (실 미검증 알고리즘)
    ///   - gainProfile == .v110Experimental (실 미검증 gain)
    ///   - signConvention == .alternateDiagnostic (fall 가속 실험)
    public var isRiskyToApply: Bool {
        guard applyToRobot else { return false }
        return algorithmMode == .hybridBA
            || gainProfile == .v110Experimental
            || signConvention == .alternateDiagnostic
    }
}
