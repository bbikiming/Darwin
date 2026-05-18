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
