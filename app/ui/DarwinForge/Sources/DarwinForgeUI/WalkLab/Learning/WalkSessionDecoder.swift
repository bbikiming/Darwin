import Foundation

/// Decode 된 한 세션의 in-memory 모델. v1 / v2 모두 같은 형태로 정규화된다.
public struct DecodedWalkSession: Equatable, Sendable {
    public let schemaVersion: WalkSessionSchemaVersion
    public let header: WalkSessionHeaderResolved
    public let samples: [WalkSessionSampleResolved]
    public let events: [WalkSessionEventV2]
    public let footer: WalkSessionFooterV2?
    public let parseErrors: Int

    public init(schemaVersion: WalkSessionSchemaVersion,
                header: WalkSessionHeaderResolved,
                samples: [WalkSessionSampleResolved],
                events: [WalkSessionEventV2],
                footer: WalkSessionFooterV2?,
                parseErrors: Int) {
        self.schemaVersion = schemaVersion
        self.header = header
        self.samples = samples
        self.events = events
        self.footer = footer
        self.parseErrors = parseErrors
    }
}

public enum WalkSessionDecoderError: Error, Equatable {
    case fileNotFound(String)
    case emptyFile
    case missingHeader
    case invalidJson(line: Int)
}

/// v1 / v2 JSONL 파일을 읽어서 공통 in-memory 표현으로 변환.
///
/// 설계:
/// - 첫 줄을 보고 v1 / v2 판단. v2 면 `"type": "header"` 가 있다.
/// - 모르는 필드는 무시한다 (forward-compat).
/// - 잘못된 줄은 `parseErrors` 카운트만 올리고 계속 진행 — fail-fast 하지 않음.
/// - decoder 가 `IMU duplicate` 플래그를 직접 계산. v1 로그는 imuDuplicate 필드가
///   없으니 이전 sample 의 (roll, pitch) 와 비교해서 채운다.
public enum WalkSessionDecoder {
    public static func decode(file url: URL) throws -> DecodedWalkSession {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WalkSessionDecoderError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw WalkSessionDecoderError.emptyFile }
        return try decode(data: data)
    }

    public static func decode(data: Data) throws -> DecodedWalkSession {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return try decode(lines: lines.map(String.init))
    }

    public static func decode(lines: [String]) throws -> DecodedWalkSession {
        guard !lines.isEmpty else { throw WalkSessionDecoderError.emptyFile }

        var header: WalkSessionHeaderResolved?
        var samples: [WalkSessionSampleResolved] = []
        var events: [WalkSessionEventV2] = []
        var footer: WalkSessionFooterV2?
        var parseErrors = 0
        var detectedSchema: WalkSessionSchemaVersion = .v1

        // 첫 비-빈 줄을 header 로 시도.
        var lastImuRoll: Double?
        var lastImuPitch: Double?

        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8) else {
                parseErrors += 1
                continue
            }
            guard let jsonAny = try? JSONSerialization.jsonObject(with: lineData),
                  let obj = jsonAny as? [String: Any] else {
                parseErrors += 1
                continue
            }

            let rawType = obj["type"] as? String
            let hasSessionId = obj["sessionId"] != nil
            let hasSampleT = obj["t"] != nil || obj["tMs"] != nil
            let hasEventKind = obj["kind"] != nil

            // schema 판단 — v2 line type 필드가 있거나 schemaVersion >= 2 면 v2.
            if let sv = obj["schemaVersion"] as? Int, sv >= 2 {
                detectedSchema = .v2
            } else if rawType != nil {
                detectedSchema = .v2
            }

            let kind = WalkSessionLineKind.from(
                rawType: rawType,
                hasSessionId: hasSessionId,
                hasSampleT: hasSampleT,
                hasEventKind: hasEventKind
            )

            switch kind {
            case .header:
                header = parseHeader(obj, detectedSchema: detectedSchema)
            case .sample:
                if let s = parseSample(obj,
                                       detectedSchema: detectedSchema,
                                       lastImuRoll: lastImuRoll,
                                       lastImuPitch: lastImuPitch) {
                    samples.append(s)
                    if let r = s.imuRollDeg { lastImuRoll = r }
                    if let p = s.imuPitchDeg { lastImuPitch = p }
                } else {
                    parseErrors += 1
                }
            case .event:
                if let e = parseEvent(obj) {
                    events.append(e)
                }
            case .footer:
                footer = parseFooter(obj)
            case .unknown:
                // 첫 줄에 type 도 sessionId 도 t 도 없으면 무시.
                parseErrors += 1
                _ = idx
            }
        }

        guard let h = header else { throw WalkSessionDecoderError.missingHeader }

        return DecodedWalkSession(
            schemaVersion: detectedSchema,
            header: h,
            samples: samples,
            events: events,
            footer: footer,
            parseErrors: parseErrors
        )
    }

    // MARK: - parsers

    static func parseHeader(_ obj: [String: Any], detectedSchema: WalkSessionSchemaVersion) -> WalkSessionHeaderResolved? {
        guard let sessionId = obj["sessionId"] as? String,
              let startTimeIso = obj["startTimeIso"] as? String,
              let preset = obj["preset"] as? String else {
            return nil
        }
        let walkTuning: WalkTuningSnapshot? = {
            guard let dict = obj["walkTuning"] as? [String: Any] else { return nil }
            return WalkTuningSnapshot(
                periodMs: doubleVal(dict["periodMs"]) ?? 0,
                xStrideM: doubleVal(dict["xStrideM"]) ?? 0,
                yStrideM: doubleVal(dict["yStrideM"]) ?? 0,
                aTurnRad: doubleVal(dict["aTurnRad"]) ?? 0,
                footHeightMm: doubleVal(dict["footHeightMm"]),
                balanceGain: doubleVal(dict["balanceGain"])
            )
        }()
        let safetyPolicy: SafetyPolicySnapshot? = {
            guard let dict = obj["safetyPolicy"] as? [String: Any] else { return nil }
            return SafetyPolicySnapshot(
                maxTiltDeg: doubleVal(dict["maxTiltDeg"]) ?? 30,
                maxMotorTempC: doubleVal(dict["maxMotorTempC"]) ?? 60,
                cradleRequired: (dict["cradleRequired"] as? Bool) ?? true,
                highRiskAcknowledged: (dict["highRiskAcknowledged"] as? Bool) ?? false
            )
        }()
        let comparisonTag: WalkComparisonTag? = {
            guard let dict = obj["comparisonTag"] as? [String: Any],
                  let groupId = dict["groupId"] as? String,
                  let arm = dict["arm"] as? String,
                  let varStr = dict["variableChanged"] as? String,
                  let variable = WalkComparisonVariable(rawValue: varStr) else { return nil }
            return WalkComparisonTag(
                groupId: groupId,
                arm: arm,
                variableChanged: variable,
                baselineSessionId: dict["baselineSessionId"] as? String
            )
        }()
        return WalkSessionHeaderResolved(
            schemaVersion: detectedSchema,
            sessionId: sessionId,
            startTimeIso: startTimeIso,
            appVersion: obj["appVersion"] as? String,
            gitCommit: obj["gitCommit"] as? String,
            preset: preset,
            isRealRobot: obj["isRealRobot"] as? Bool,
            intensityLevelAtStart: obj["intensityLevelAtStart"] as? Int ?? obj["correctorIntensityLevelAtStart"] as? Int,
            supportMode: obj["supportMode"] as? String,
            walkTuning: walkTuning,
            balanceAlgorithmMode: obj["balanceAlgorithmMode"] as? String,
            balanceSignConvention: obj["balanceSignConvention"] as? String,
            balanceGainProfile: obj["balanceGainProfile"] as? String,
            correctionApplyMode: obj["correctionApplyMode"] as? String,
            imuSourceAtStart: obj["imuSourceAtStart"] as? String,
            imuScaleSuspicionAtStart: obj["imuScaleSuspicionAtStart"] as? String,
            safetyPolicy: safetyPolicy,
            comparisonTag: comparisonTag
        )
    }

    static func parseSample(_ obj: [String: Any],
                            detectedSchema: WalkSessionSchemaVersion,
                            lastImuRoll: Double?,
                            lastImuPitch: Double?) -> WalkSessionSampleResolved? {
        let tMs = doubleVal(obj["tMs"]) ?? doubleVal(obj["t"]) ?? 0
        let imuRoll = doubleVal(obj["imuRollDeg"])
        let imuPitch = doubleVal(obj["imuPitchDeg"])

        // imuDuplicate 자동 계산 — v1 로그는 명시 필드가 없으니 이전 값과 비교.
        let imuDuplicate: Bool = {
            if let explicit = obj["imuDuplicate"] as? Bool { return explicit }
            guard let r = imuRoll, let p = imuPitch,
                  let lr = lastImuRoll, let lp = lastImuPitch else { return false }
            return r == lr && p == lp
        }()
        let imuStale: Bool = {
            if let explicit = obj["imuStale"] as? Bool { return explicit }
            if let age = doubleVal(obj["imuSampleAgeMs"]) { return age > 250 }
            return false
        }()

        return WalkSessionSampleResolved(
            schemaVersion: detectedSchema,
            tMs: tMs,
            tickIndex: obj["tickIndex"] as? Int,
            tickDtMs: doubleVal(obj["tickDtMs"]),
            preset: obj["preset"] as? String,
            walkPeriodMs: doubleVal(obj["walkPeriodMs"]),
            walkCycleElapsedMs: doubleVal(obj["walkCycleElapsedMs"]),
            walkPhase01: doubleVal(obj["walkPhase01"]),
            imuSource: obj["imuSource"] as? String,
            imuSampleAgeMs: doubleVal(obj["imuSampleAgeMs"]),
            imuDuplicate: imuDuplicate,
            imuStale: imuStale,
            imuRollDeg: imuRoll,
            imuPitchDeg: imuPitch,
            balanceAlgorithmMode: obj["balanceAlgorithmMode"] as? String,
            balanceSignConvention: obj["balanceSignConvention"] as? String,
            balanceGainProfile: obj["balanceGainProfile"] as? String,
            correctionAppliedToRobot: obj["correctionAppliedToRobot"] as? Bool,
            observeOnly: obj["observeOnly"] as? Bool,
            expectedPitchDeg: doubleVal(obj["expectedPitchDeg"]),
            expectedRollDeg: doubleVal(obj["expectedRollDeg"]),
            emaPitchDeg: doubleVal(obj["emaPitchDeg"]),
            emaRollDeg: doubleVal(obj["emaRollDeg"]),
            effectivePitchErrDeg: doubleVal(obj["effectivePitchErrDeg"]) ?? doubleVal(obj["correctorPitchErrDeg"]),
            effectiveRollErrDeg: doubleVal(obj["effectiveRollErrDeg"]) ?? doubleVal(obj["correctorRollErrDeg"]),
            correctorDeltas: (obj["correctorDeltas"] as? [Any])?.compactMap(doubleVal),
            candidateDeltas: (obj["candidateDeltas"] as? [Any])?.compactMap(doubleVal),
            appliedDeltas: (obj["appliedDeltas"] as? [Any])?.compactMap(doubleVal),
            balanceState: obj["balanceState"] as? String,
            batteryVolts: doubleVal(obj["batteryVolts"]),
            motorAvgTemp: doubleVal(obj["motorAvgTemp"]),
            intensityLevel: obj["intensityLevel"] as? Int,
            busWriteFailureCount: obj["busWriteFailureCount"] as? Int,
            busReadFailureCount: obj["busReadFailureCount"] as? Int
        )
    }

    static func parseEvent(_ obj: [String: Any]) -> WalkSessionEventV2? {
        guard let tMs = doubleVal(obj["tMs"]),
              let wallTimeIso = obj["wallTimeIso"] as? String,
              let kind = obj["kind"] as? String,
              let message = obj["message"] as? String else { return nil }
        let payload = obj["payload"] as? [String: String] ?? [:]
        return WalkSessionEventV2(
            tMs: tMs,
            wallTimeIso: wallTimeIso,
            kind: kind,
            severity: obj["severity"] as? String ?? "info",
            message: message,
            payload: payload
        )
    }

    static func parseFooter(_ obj: [String: Any]) -> WalkSessionFooterV2? {
        guard let endTimeIso = obj["endTimeIso"] as? String,
              let totalSamples = obj["totalSamples"] as? Int,
              let totalEvents = obj["totalEvents"] as? Int,
              let endedNormally = obj["endedNormally"] as? Bool,
              let endReason = obj["endReason"] as? String else { return nil }
        return WalkSessionFooterV2(
            endTimeIso: endTimeIso,
            totalSamples: totalSamples,
            totalEvents: totalEvents,
            endedNormally: endedNormally,
            endReason: endReason
        )
    }

    static func doubleVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
