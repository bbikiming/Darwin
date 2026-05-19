import Foundation

/// **v1.11.10 (2026-05-19)** — Claude critic 응답 Codable.
///
/// 진단 문서 §P0-4 + §3 권장 schema 그대로 + Agent 3 설계.
///
/// **설계 원칙**:
/// - `from / to` String 통일 (Double "13.0" vs preset "slowWalk" 일관)
/// - enum `.unknown` fallback (forward-compat)
/// - `additionalProperties:false` (top level) — hallucination 차단
/// - `changeOneAxisOnly: const true` — schema 단에서 multi-axis 차단
public struct ClaudeCriticResponse: Codable, Equatable, Sendable {
    public let summary: String?
    public let sessionsAnalyzed: [String]?
    public let dataQuality: DataQualityVerdict
    public let diagnosis: [DiagnosisItem]
    public let nextExperiment: NextExperiment?    // nil 가능 — quality.fail 시
    public let forbiddenChanges: [String]
    public let recommendation: Recommendation?
    public let confidence: Double?

    public init(
        summary: String? = nil,
        sessionsAnalyzed: [String]? = nil,
        dataQuality: DataQualityVerdict,
        diagnosis: [DiagnosisItem],
        nextExperiment: NextExperiment? = nil,
        forbiddenChanges: [String],
        recommendation: Recommendation? = nil,
        confidence: Double? = nil
    ) {
        self.summary = summary
        self.sessionsAnalyzed = sessionsAnalyzed
        self.dataQuality = dataQuality
        self.diagnosis = diagnosis
        self.nextExperiment = nextExperiment
        self.forbiddenChanges = forbiddenChanges
        self.recommendation = recommendation
        self.confidence = confidence
    }
}

public struct DataQualityVerdict: Codable, Equatable, Sendable {
    public let verdict: Verdict
    public let reasons: [String]

    public enum Verdict: String, Codable, Sendable {
        case pass, weak, fail
    }
}

public struct DiagnosisItem: Codable, Equatable, Sendable {
    public let axis: ResponseAxis
    public let severity: Severity
    public let evidence: [String]
    public let confidence: Double

    public enum Severity: String, Codable, Sendable {
        case low, med, high, critical
    }
}

public struct NextExperiment: Codable, Equatable, Sendable {
    public let changeOneAxisOnly: Bool       // must be true
    public let axis: ResponseAxis
    public let from: String                  // "13" or "slowWalk"
    public let to: String
    public let preset: String                // 자유 문자열 (slowWalk/march/...)
    public let safety: String
    public let successMetric: String
    public let rollbackCondition: String
    public let riskNote: String?
}

public struct Recommendation: Codable, Equatable, Sendable {
    public let action: Action
    public let requiresHumanApproval: Bool

    public enum Action: String, Codable, Sendable {
        case applyToBaseline = "applyToBaseline"
        case recollect = "recollect"
        case holdAndObserve = "holdAndObserve"
        case abort = "abort"
        case unknown
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Action(rawValue: raw) ?? .unknown
        }
    }
}

/// 8 axis + null (no axis) + unknown (forward-compat).
public enum ResponseAxis: String, Codable, Sendable {
    case walkingEngine
    case algorithmMode
    case signConvention
    case gainProfile
    case pitchInputConvention
    case applyToRobot
    case enableBalanceCorrection
    case hipPitchOffsetTrimDeg
    // tuning slider:
    case strideMm
    case sideMm
    case turnDeg
    case periodMs
    case footHeightMm
    case balanceGain
    // custom gain:
    case customGainHipRoll
    case customGainKnee
    case customGainAnklePitch
    case customGainAnkleRoll
    // 의도적 "no specific axis".
    case none = "null"
    // forward-compat fallback.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ResponseAxis(rawValue: raw) ?? .unknown
    }
}

// MARK: - Deterministic re-validation (controller side)

extension ClaudeCriticResponse {
    /// **v1.11.10**: 응답 받은 후 controller 가 추가 검증.
    /// - `nextExperiment.changeOneAxisOnly` == true 확인
    /// - `nextExperiment` 변경 조합이 forbidden list 위반 X
    /// - `quality.fail` 인 경우 `nextExperiment` nil 확인
    public func validate() -> ValidationResult {
        var issues: [String] = []
        if let exp = nextExperiment {
            if !exp.changeOneAxisOnly {
                issues.append("changeOneAxisOnly=false — schema 위반 (multi-axis 변경 시도)")
            }
            // forbidden 조합 검증 (axis + value 매칭은 deterministic).
            // 예: algorithmMode → "hybridBA" 이면서 applyToRobot=true 권고 시 reject.
            // 현재 schema 가 한 axis 만 변경하므로, 다른 axis 가 true 가 되는지 확인은
            // 호출자가 현재 config 알아야 함. 여기는 명시적 forbidden phrase 검사.
            if exp.axis == .applyToRobot, exp.to == "true" {
                issues.append("applyToRobot=true 직접 권고 — deterministic safety layer 만 결정 (사용자 명시 승인 필요)")
            }
        }
        if dataQuality.verdict == .fail, nextExperiment != nil {
            issues.append("quality.fail 인데 nextExperiment 가 nil 아님 — 데이터 재수집 권고만 허용")
        }
        return ValidationResult(passed: issues.isEmpty, issues: issues)
    }

    public struct ValidationResult: Equatable, Sendable {
        public let passed: Bool
        public let issues: [String]
    }

    /// **v1.11.14 (2026-05-19) — 진단 문서 #5 fix**: 현재 config 기준 forbidden 조합 검증.
    ///
    /// 종전 `validate()` 는 응답 자체의 self-consistency 만 검사 (단축 표현). 그러나
    /// 실제 위험은 "현재 사용자 config + 제안 변경" 조합에 있음. 이 overload 가
    /// `BalanceExperimentConfig.safetyVerdict` 로직을 한 axis 변경 후 미리 시뮬레이션해
    /// blocked 면 issue 추가. hipPitchOffsetTrimDeg 같은 non-config axis 도 별도 검사.
    ///
    /// - Parameters:
    ///   - currentConfig: 현재 WalkLabSession 의 BalanceExperimentConfig
    ///   - currentTrim: 현재 hipPitchOffsetTrimDeg (default 13)
    /// - Returns: 응답 자체 + 조합 검사 결과
    public func validate(currentConfig: BalanceExperimentConfig,
                         currentTrim: Double = 13.0) -> ValidationResult {
        var issues = self.validate().issues
        guard let exp = nextExperiment else {
            return ValidationResult(passed: issues.isEmpty, issues: issues)
        }
        // forbidden phrase 매칭 (Claude 가 명시한 금지 조합과 일치 시).
        // 예: forbiddenChanges: ["algorithmMode→hybridBA + applyToRobot=true"]
        let forbiddenPhrase = "\(exp.axis.rawValue)→\(exp.to)"
        for f in forbiddenChanges {
            if f.contains(forbiddenPhrase) {
                issues.append("제안 변경이 응답의 forbiddenChanges 와 충돌: \(f)")
            }
        }
        // 한 axis 변경 후 safetyVerdict 시뮬레이션.
        let simulated = simulateChange(exp: exp, from: currentConfig)
        if case .blocked(let reason) = simulated.safetyVerdict {
            issues.append("제안 적용 시 safetyVerdict=blocked: \(reason)")
        }
        // **v1.11.14.3 (2026-05-19) — 진단 문서 cold #A/#G fix**:
        // hipPitchOffsetTrimDeg 범위 가드 강화. ROBOTIS DARwIn-OP 실 안전 범위는
        // 12°~18°. ±20°/±35° 는 너무 넓음 (절대값 25° 도 fall 가속).
        if exp.axis == .hipPitchOffsetTrimDeg, let target = Double(exp.to) {
            if abs(target - currentTrim) > 5.0 {
                issues.append("hipPitchOffsetTrimDeg 변경 폭 \(String(format: "%.1f", abs(target - currentTrim)))° > 5° — 단일 실험으로 위험. 2~3° 점진 권장.")
            }
            if target < 5 || target > 25 {
                issues.append("hipPitchOffsetTrimDeg=\(target)° 절대 안전 범위 (5..25) 초과 — fall 위험.")
            } else if target < 8 || target > 20 {
                issues.append("hipPitchOffsetTrimDeg=\(target)° 권장 범위 (8..20) 밖 — caution. 12~18 권장.")
            }
        }
        // **v1.11.14.3 — 진단 문서 cold #C fix**: tuning slider + customGain* axis
        // 의 범위 가드. WalkLabSession 의 slider 범위와 일치시켜 critic 의 비현실
        // 권고 (예: customPeriodMs=2000) silent 적용 차단.
        // 임계값 출처: BalanceExperimentControls.swift slider range + 실 robot 안전.
        validateAxisRange(exp: exp, issues: &issues)
        // enableBalanceCorrection=false 인 환경에서 algorithm/sign/gain/pitch 변경은 no-op.
        // (사용자가 toggleable 상태가 아닌 환경에서 critic 이 무의미한 제안)
        // 본 PR 에선 issue 만 표시 — caller 가 알림 + 사용자 인지 후 진행.
        return ValidationResult(passed: issues.isEmpty, issues: issues)
    }

    /// **v1.11.14.3**: axis 별 안전 범위 검사. critic 이 비현실적 값 권고 시 reject.
    /// 범위는 WalkLabSession 의 slider min/max + ROBOTIS 안전 documentation 기준.
    private func validateAxisRange(exp: NextExperiment, issues: inout [String]) {
        guard let target = Double(exp.to) else { return }
        let ranges: [(ResponseAxis, ClosedRange<Double>, String)] = [
            (.strideMm, -80...80, "보폭 (mm)"),
            (.sideMm, -50...50, "측보 (mm)"),
            (.turnDeg, -25...25, "회전 (°)"),
            (.periodMs, 400...800, "주기 (ms)"),
            (.footHeightMm, 20...60, "발 들어올림 (mm)"),
            (.balanceGain, 0.0...2.0, "balance 강도"),
            (.customGainHipRoll, 0.0...2.0, "custom hip roll gain"),
            (.customGainKnee, 0.0...2.0, "custom knee gain"),
            (.customGainAnklePitch, 0.0...2.0, "custom ankle pitch gain"),
            (.customGainAnkleRoll, 0.0...2.0, "custom ankle roll gain"),
        ]
        for (axis, range, label) in ranges where exp.axis == axis {
            if !range.contains(target) {
                issues.append("\(label) \(target) 안전 범위 \(range.lowerBound)..\(range.upperBound) 밖 — slider 한도 초과.")
            }
        }
    }

    /// 한 axis 변경 적용한 BalanceExperimentConfig 시뮬레이션 — safetyVerdict 만 검사용.
    /// **v1.11.14.4 — cold 3차 HIGH 4**: exhaustive switch — ResponseAxis 신규 case
    /// 추가 시 silent skip 차단. compiler 가 미처리 case 경고.
    private func simulateChange(exp: NextExperiment,
                                from current: BalanceExperimentConfig) -> BalanceExperimentConfig {
        var algorithm = current.algorithmMode
        var sign = current.signConvention
        var gain = current.gainProfile
        var apply = current.applyToRobot
        var pitchInput = current.pitchInputConvention
        switch exp.axis {
        case .algorithmMode:
            if let v = BalanceAlgorithmMode(rawValue: exp.to) { algorithm = v }
        case .signConvention:
            if let v = BalanceSignConvention(rawValue: exp.to) { sign = v }
        case .gainProfile:
            if let v = BalanceGainProfile(rawValue: exp.to) { gain = v }
        case .pitchInputConvention:
            if let v = BalancePitchInputConvention(rawValue: exp.to) { pitchInput = v }
        case .applyToRobot:
            apply = (exp.to.lowercased() == "true")
        // 명시 모든 non-config axis — 시뮬 X (BalanceExperimentConfig 영향 X).
        case .walkingEngine, .enableBalanceCorrection, .hipPitchOffsetTrimDeg,
             .strideMm, .sideMm, .turnDeg, .periodMs, .footHeightMm, .balanceGain,
             .customGainHipRoll, .customGainKnee, .customGainAnklePitch, .customGainAnkleRoll,
             .none, .unknown:
            break  // 시뮬 변경 X — config 자체에 영향 없는 axis. axis 별 가드는 validate(currentConfig:) 본체에서 처리.
        }
        return BalanceExperimentConfig(
            algorithmMode: algorithm, signConvention: sign,
            gainProfile: gain, applyToRobot: apply,
            pitchInputConvention: pitchInput
        )
    }
}

// MARK: - JSON Schema (draft-7) — prompt 에 embed

public enum ClaudeCriticSchema {
    public static let schemaJson: String = #"""
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "ClaudeCriticResponse",
      "type": "object",
      "required": ["dataQuality", "diagnosis", "forbiddenChanges"],
      "additionalProperties": false,
      "properties": {
        "summary": { "type": "string", "maxLength": 160 },
        "sessionsAnalyzed": { "type": "array", "items": { "type": "string" } },
        "dataQuality": { "$ref": "#/definitions/Verdict" },
        "diagnosis": {
          "type": "array",
          "items": { "$ref": "#/definitions/Diag" },
          "maxItems": 8
        },
        "nextExperiment": {
          "oneOf": [{ "type": "null" }, { "$ref": "#/definitions/Exp" }]
        },
        "forbiddenChanges": { "type": "array", "items": { "type": "string" } },
        "recommendation": { "$ref": "#/definitions/Recommendation" },
        "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
      },
      "definitions": {
        "Verdict": {
          "type": "object",
          "required": ["verdict", "reasons"],
          "properties": {
            "verdict": { "enum": ["pass", "weak", "fail"] },
            "reasons": { "type": "array", "items": { "type": "string" } }
          }
        },
        "Diag": {
          "type": "object",
          "required": ["axis", "severity", "evidence", "confidence"],
          "properties": {
            "axis": { "type": "string" },
            "severity": { "enum": ["low", "med", "high", "critical"] },
            "evidence": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
            "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
          }
        },
        "Exp": {
          "type": "object",
          "required": ["changeOneAxisOnly", "axis", "from", "to", "preset", "safety", "successMetric", "rollbackCondition"],
          "properties": {
            "changeOneAxisOnly": { "const": true },
            "axis": { "type": "string" },
            "from": { "type": "string" },
            "to": { "type": "string" },
            "preset": { "type": "string" },
            "safety": { "type": "string" },
            "successMetric": { "type": "string" },
            "rollbackCondition": { "type": "string" },
            "riskNote": { "type": "string" }
          }
        },
        "Recommendation": {
          "type": "object",
          "required": ["action", "requiresHumanApproval"],
          "properties": {
            "action": { "enum": ["applyToBaseline", "recollect", "holdAndObserve", "abort"] },
            "requiresHumanApproval": { "type": "boolean" }
          }
        }
      }
    }
    """#
}
