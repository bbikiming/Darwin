import Foundation

/// **v1.15.5 (2026-05-21) — Phase 1.5: WalkLab 설정값 적용 범위 시각화**.
///
/// verification 문서 (`docs/diagnosis/WALKLAB_REALTIME_SETTING_APPLICATION_VERIFICATION_*`)
/// 가 발견한 critical gap: `balanceGain`, `enableBalanceCorrection`, `correctorIntensityLevel`
/// 등이 `.robotisOnboard` 모드에서 펌웨어로 송신되지 않아 사용자가 "슬라이더 올렸는데 왜
/// 로봇은 그대로지?" 오해.
///
/// 본 enum + Resolver 가 각 설정 항목 + 현재 walking engine 의 조합으로 **적용 범위**
/// 를 결정. UI 가 이 결과로 사용자에게 "이 설정이 실제로 어디로 가는가" 시각화.
///
/// # 6 case
///
/// - `.sentBoth(timing:)` — Mac sparse + Onboard 모두 송신 (timing 정보 보존)
/// - `.macSparseOnly` — Onboard 미송신 (Mac corrector 만, 펌웨어 미지원)
/// - `.previewOnly` — 화면만 (sim 또는 observeOnly 알고리즘 — pose 변경 X)
/// - `.startGateOnly` — preflight 게이트만 (cradle/risk)
/// - `.nextSession` — 다음 세션부터 (operatorNote/comparisonTag)
/// - `.disabledOnboard` — Onboard 모드에서 비활성화 권장 (HIGH-risk gap, 예: balanceGain)
public enum WalkLabApplyScope: Equatable, Hashable, Sendable {

    /// Mac sparse + Onboard 양쪽 모두 송신. associated timing 으로 구체 시점 보존.
    case sentBoth(timing: SendTiming)

    /// `.robotisOnboard` 모드에서 펌웨어로 미송신 — Mac sparse 모드에서만 의미.
    /// 사용자 결정: 활성 유지 + "Mac 전용" 안내 배지 표시.
    case macSparseOnly

    /// 화면 (시뮬 visualizer / observe-only 알고리즘) 만 반영. 실 모터 송출 X.
    /// observeOnly algorithm — corrections 계산하지만 pose 변경 안 함.
    case previewOnly

    /// preflight gate 용 — 시작 시점에만 검사. 보행 중 변경 무영향.
    case startGateOnly

    /// 다음 세션의 logger header 에만 기록. 현재 세션 무영향.
    case nextSession

    /// **HIGH-risk gap**: Onboard 모드에서 비활성화 권장 (`balanceGain` 등).
    /// 사용자 결정 hybrid 옵션 — 옵션 (a) disable 으로 처리.
    case disabledOnboard

    // MARK: - Computed display

    public var label: String {
        switch self {
        case .sentBoth(let timing):  return "로봇 송신 \(timing.label)"
        case .macSparseOnly:         return "Mac 전용"
        case .previewOnly:           return "화면만"
        case .startGateOnly:         return "시작 전 게이트"
        case .nextSession:           return "다음 세션"
        case .disabledOnboard:       return "Onboard 미지원 — 비활성"
        }
    }

    public var icon: String {
        switch self {
        case .sentBoth:           return "wave.3.right.circle.fill"
        case .macSparseOnly:      return "laptopcomputer"
        case .previewOnly:        return "eye"
        case .startGateOnly:      return "lock.shield"
        case .nextSession:        return "arrow.right.circle"
        case .disabledOnboard:    return "exclamationmark.triangle.fill"
        }
    }

    /// Codex MED 권고: raw `Color.green` 대신 `DFColor` 토큰 사용 — dark/light/lightFlat
    /// 모드 정합 + 미래 theme 확장 자동 반영.
    /// (Note: SwiftUI Color 직접 반환 — 호출자가 `.foregroundStyle` 등에 사용)
    public var colorName: ColorRole {
        switch self {
        case .sentBoth:           return .success
        case .macSparseOnly:      return .info
        case .previewOnly:        return .secondary
        case .startGateOnly:      return .accent
        case .nextSession:        return .secondary
        case .disabledOnboard:    return .danger
        }
    }

    /// VoiceOver / tooltip 용 긴 설명. nil = 추가 설명 불필요.
    public var detailedMessage: String? {
        switch self {
        case .sentBoth(let timing):
            return "이 설정은 현재 보행 엔진의 \(timing.label) 시점에 로봇으로 송신됩니다."
        case .macSparseOnly:
            return "현재 ROBOTIS Onboard 모드에서는 이 값이 로봇 펌웨어로 송신되지 않습니다. "
                 + "Mac sparse 모드에서만 실제 효과가 나타납니다. "
                 + "엔진을 Mac sparse 로 전환하면 이 슬라이더 변경이 즉시 반영됩니다."
        case .previewOnly:
            return "이 설정은 화면 시뮬레이션 또는 관찰용 알고리즘에서만 사용됩니다. "
                 + "실제 로봇 모터에는 영향을 주지 않습니다."
        case .startGateOnly:
            return "이 토글은 보행 시작 시점의 안전 검사용입니다. "
                 + "보행 중에 변경해도 현재 사이클에는 영향이 없습니다."
        case .nextSession:
            return "이 값은 다음 보행 세션부터 로그 헤더에 기록됩니다. "
                 + "현재 진행 중인 세션에는 영향이 없습니다."
        case .disabledOnboard:
            return "Onboard 모드에서는 이 값이 펌웨어로 송신되지 않아 효과가 없습니다. "
                 + "혼동 방지를 위해 비활성화되었습니다. Mac sparse 엔진으로 전환하면 사용 가능합니다."
        }
    }
}

// MARK: - Send timing (sentBoth associated value)

/// `sentBoth` 의 송신 cadence — verification §7.2 의 "즉시 송신 / 300ms / 220ms 재시작"
/// 3 표현 보존. Mac sparse 220ms vs Onboard immediate/300ms 구분.
public enum SendTiming: Equatable, Hashable, Sendable {
    /// 즉시 송신 — Onboard IMMEDIATE 큐 (preset 변경 등).
    case immediate
    /// 220ms debounce 후 보행 cycle 재시작 — Mac sparse 슬라이더 변경.
    case debounced220
    /// 300ms debounce 후 송신 — Onboard slider 변경.
    case debounced300

    public var label: String {
        switch self {
        case .immediate:      return "(즉시)"
        case .debounced220:   return "(220ms 후 재시작)"
        case .debounced300:   return "(300ms 후)"
        }
    }
}

// MARK: - Color role (decoupled from Color type)

/// Badge 의 color 의도 — view layer 가 DFColor 또는 system 색상으로 매핑.
public enum ColorRole: Equatable, Hashable, Sendable {
    case success
    case info
    case secondary
    case accent
    case danger
}

// MARK: - WalkLabField

/// verification 문서 §3 매트릭스의 모든 설정 항목 enumerate.
/// **Critic + Architect 권고 반영**: 17 field 모두 포함 (gainProfile, forceOverrideSafety
/// 누락 보강), meta toggle 2개 (autoFallPrevention, autoOnboardBrokering) 도 포함.
public enum WalkLabField: String, CaseIterable, Hashable, Sendable {
    // 보행 기본 (sentBoth 류)
    case preset
    case strideMm
    case sideMm
    case turnDeg
    case customPeriodMs
    case footHeightMm
    case hipPitchOffsetTrimDeg

    // 보정 (macSparseOnly @ Onboard — gap)
    case balanceGain
    case enableBalanceCorrection
    case correctorIntensityLevel
    case balanceExperimentConfig
    case gainProfile

    // 안전 + meta
    case autoFallPrevention
    case autoOnboardBrokering
    case forceOverrideSafety

    // preflight gate
    case cradleConfirmed
    case riskAcknowledged

    // next session
    case operatorNote
    case comparisonTag

    // engine 자체 (mode switcher)
    case walkingEngine

    public var displayLabel: String {
        switch self {
        case .preset:                   return "프리셋"
        case .strideMm:                 return "보폭"
        case .sideMm:                   return "측면"
        case .turnDeg:                  return "회전"
        case .customPeriodMs:           return "주기"
        case .footHeightMm:             return "발 높이"
        case .hipPitchOffsetTrimDeg:    return "Hip Pitch Trim"
        case .balanceGain:              return "균형 게인"
        case .enableBalanceCorrection:  return "자세 보정 토글"
        case .correctorIntensityLevel:  return "보정 강도"
        case .balanceExperimentConfig:  return "보정 실험 설정"
        case .gainProfile:              return "게인 프로파일"
        case .autoFallPrevention:       return "자동 균형 보정"
        case .autoOnboardBrokering:     return "Onboard 자동 브로커링"
        case .forceOverrideSafety:      return "안전 한도 해제"
        case .cradleConfirmed:          return "거치 확인"
        case .riskAcknowledged:         return "위험 동의"
        case .operatorNote:             return "조작자 메모"
        case .comparisonTag:            return "비교 태그"
        case .walkingEngine:            return "보행 엔진"
        }
    }
}

// MARK: - Resolver

/// 순수 함수 — field + walking engine 으로부터 적용 범위 결정.
///
/// **Critical (code-reviewer C1 + test-engineer + critic 합의)**: nested switch 로
/// exhaustive 강제. `default:` 금지 — 신규 engine 추가 시 컴파일 에러 → silent fallback 차단.
public enum WalkLabApplyScopeResolver {

    /// 메인 진입점.
    public static func scope(
        for field: WalkLabField,
        engine: WalkingEngine
    ) -> WalkLabApplyScope {
        switch field {

        // ── 보행 기본 — 모든 엔진에서 송신. 단 timing 다름.
        case .preset:
            switch engine {
            case .macSparseKeyframe: return .sentBoth(timing: .debounced220)
            case .robotisOnboard:    return .sentBoth(timing: .immediate)
            }
        case .strideMm, .sideMm, .turnDeg, .customPeriodMs, .footHeightMm, .hipPitchOffsetTrimDeg:
            switch engine {
            case .macSparseKeyframe: return .sentBoth(timing: .debounced220)
            case .robotisOnboard:    return .sentBoth(timing: .debounced300)
            }

        // ── 보정 — Onboard 미송신 (verification 핵심 gap).
        // balanceGain 만 HIGH-risk → disabledOnboard (사용자 hybrid 선택).
        case .balanceGain:
            switch engine {
            case .macSparseKeyframe: return .sentBoth(timing: .debounced220)
            case .robotisOnboard:    return .disabledOnboard
            }
        case .enableBalanceCorrection, .correctorIntensityLevel, .gainProfile:
            switch engine {
            case .macSparseKeyframe: return .sentBoth(timing: .debounced220)
            case .robotisOnboard:    return .macSparseOnly
            }
        case .balanceExperimentConfig:
            // observeOnly algorithm 은 sub-field 모호성 — 호출자가 sub-context 별도 전달
            // 필요할 수 있으나, 단일 scope 로는 Mac sparse 전용으로 통합 (caller 가
            // observeOnly 일 때 `previewOnly` 별도 표시 가능).
            switch engine {
            case .macSparseKeyframe: return .sentBoth(timing: .debounced220)
            case .robotisOnboard:    return .macSparseOnly
            }

        // ── 안전 + meta
        case .autoFallPrevention:
            // Mac 안전망 — 어느 엔진에서도 Mac 측 FallPredictor 토글. 펌웨어 안전망과 무관.
            return .macSparseOnly
        case .autoOnboardBrokering:
            switch engine {
            case .macSparseKeyframe: return .previewOnly  // Mac sparse 엔진에선 무관 toggle.
            case .robotisOnboard:    return .sentBoth(timing: .immediate)
            }
        case .forceOverrideSafety:
            // UI cap 우회 — 양쪽 엔진에 영향 (UI 검증만 우회, critical 차단은 유지).
            return .startGateOnly

        // ── preflight gate
        case .cradleConfirmed, .riskAcknowledged:
            return .startGateOnly

        // ── next session (header 만)
        case .operatorNote, .comparisonTag:
            return .nextSession

        // ── engine 자체
        case .walkingEngine:
            // engine switcher 자체는 즉시 적용 + 보행 자동 정지 + ACK 후 전환.
            return .sentBoth(timing: .immediate)
        }
    }

    /// **observeOnly 처리 (test-engineer 권고)**: `balanceExperimentConfig` 의 algorithmMode
    /// 가 `.observeOnly` 일 때는 corrections 계산만 + pose 변경 X → `.previewOnly` 가 정확.
    /// 호출자가 별도 hint 가능.
    public static func scopeForBalanceConfig(
        engine: WalkingEngine,
        algorithmMode: BalanceAlgorithmMode
    ) -> WalkLabApplyScope {
        if algorithmMode == .observeOnly || algorithmMode == .off {
            return .previewOnly
        }
        return scope(for: .balanceExperimentConfig, engine: engine)
    }
}
