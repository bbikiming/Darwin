import Foundation
@testable import DarwinForgeUI

/// 테스트용 JSONL / sample / header fixture 생성기.
enum WalkSessionFixtures {

    /// 실제 21개 기존 로그 중 첫 줄과 같은 구조의 v1 header.
    static func v1HeaderLine(sessionId: String = "2026-05-17T11-28-42.991Z",
                             preset: String = "march",
                             intensity: Int = 2) -> String {
        let dict: [String: Any] = [
            "appVersion": "1.0.0-20ff37a",
            "intensityLevelAtStart": intensity,
            "isRealRobot": true,
            "preset": preset,
            "startTimeIso": "2026-05-17T11:28:42.991Z",
            "sessionId": sessionId
        ]
        return jsonLine(dict)
    }

    /// 실제 21개 로그와 같은 구조의 v1 sample.
    static func v1SampleLine(tMs: Double,
                             imuRoll: Double = 1.0,
                             imuPitch: Double = -10.0,
                             intensity: Int = 2,
                             correctorDeltas: [Double] = [0, 0, -0.1, 0.1, -0.3, 0.3, 0, 0],
                             balanceState: String = "caution") -> String {
        let dict: [String: Any] = [
            "t": tMs,
            "correctorDeltas": correctorDeltas,
            "motorAvgTemp": 45.25,
            "imuSource": "real",
            "imuPitchDeg": imuPitch,
            "correctorRollErrDeg": 0.0,
            "intensityLevel": intensity,
            "correctorPitchErrDeg": -9.0,
            "batteryVolts": 11.9,
            "imuRollDeg": imuRoll,
            "preset": "march",
            "balanceState": balanceState
        ]
        return jsonLine(dict)
    }

    /// 21개 로그를 통째로 흉내내는 v1 file content. duplicate ratio 가 ~90% 가 되도록
    /// 의도적으로 같은 imu 값을 반복.
    static func v1LegacyFile(durationSec: Double = 8.0, sampleRateHz: Double = 14.8,
                              presetName: String = "march") -> String {
        var lines: [String] = []
        lines.append(v1HeaderLine(preset: presetName))
        let n = Int(durationSec * sampleRateHz)
        let dt = 1000.0 / sampleRateHz
        for i in 0..<n {
            let t = Double(i) * dt + 144.0
            // 매 10 sample 마다만 IMU 값 변경 — 약 90% duplicate.
            let imuRoll: Double = 1.0 + Double(i / 10) * 0.3
            let imuPitch: Double = -10.0 + Double(i / 10) * 0.4
            lines.append(v1SampleLine(tMs: t, imuRoll: imuRoll, imuPitch: imuPitch))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 깨끗한 v2 file — A 등급에 거의 도달하도록 IMU 값이 매 sample 마다 변함.
    static func v2CleanFile(sessionId: String = "2026-05-17T12-00-00-000Z",
                            preset: String = "march",
                            algorithmMode: String = "hybridBA",
                            applyMode: String = "robotApplied",
                            sign: String = "robotisWalkingCpp",
                            gain: String = "v110Recommended",
                            durationSec: Double = 12.0,
                            sampleRateHz: Double = 20.0,
                            intensityLevel: Int = 2,
                            comparisonTag: WalkComparisonTag? = nil) -> String {
        var lines: [String] = []
        let header = WalkSessionHeaderV2(
            sessionId: sessionId,
            startTimeIso: "2026-05-17T12:00:00.000Z",
            appVersion: "1.0.0-test",
            isRealRobot: true,
            supportMode: "floor",
            preset: preset,
            walkTuning: WalkTuningSnapshot(periodMs: 600, xStrideM: 0.02, yStrideM: 0, aTurnRad: 0),
            balanceAlgorithmMode: algorithmMode,
            balanceSignConvention: sign,
            balanceGainProfile: gain,
            correctorIntensityLevelAtStart: intensityLevel,
            correctionApplyMode: applyMode,
            imuSourceAtStart: "real",
            comparisonTag: comparisonTag
        )
        lines.append(encodeLine(header))
        let n = Int(durationSec * sampleRateHz)
        let dt = 1000.0 / sampleRateHz
        for i in 0..<n {
            let t = Double(i) * dt
            let phase01 = (t.truncatingRemainder(dividingBy: 600)) / 600
            // 매 sample 마다 IMU 값이 모두 다르도록 sin 파 + 미세 drift + tick-specific jitter.
            // (실 IMU 도 양자화 + 노이즈 때문에 완전히 같은 값이 반복되지는 않는다.)
            let drift = Double(i) * 0.0005
            let jitter = sin(Double(i) * 0.37) * 0.05
            let imuRoll = 4.0 * sin(2 * .pi * phase01 + .pi / 2) + drift + jitter
            let imuPitch = -1.0 + 2.0 * sin(2 * .pi * phase01) + drift * 0.3 + jitter * 0.5
            let candidate = [0.0, 0.0, -0.5 * imuPitch, 0.5 * imuPitch, 0.3, -0.3, 0.0, 0.0]
            let applied = applyMode == "observeOnly" ? [Double](repeating: 0, count: 8) : candidate
            let s = WalkSessionSampleV2(
                tMs: t,
                wallTimeIso: "2026-05-17T12:00:00.000Z",
                tickIndex: i,
                tickDtMs: dt,
                preset: preset,
                walkPeriodMs: 600,
                walkCycleElapsedMs: t.truncatingRemainder(dividingBy: 600),
                walkPhase01: phase01,
                imuSource: "real",
                imuSampleAgeMs: 20,
                imuDuplicate: false,
                imuStale: false,
                imuRollDeg: imuRoll,
                imuPitchDeg: imuPitch,
                balanceAlgorithmMode: algorithmMode,
                balanceSignConvention: sign,
                balanceGainProfile: gain,
                correctionAppliedToRobot: applyMode == "robotApplied",
                observeOnly: applyMode == "observeOnly",
                expectedPitchDeg: 0,
                expectedRollDeg: 0,
                emaPitchDeg: -1.0,
                emaRollDeg: 0,
                effectivePitchErrDeg: imuPitch,
                effectiveRollErrDeg: imuRoll,
                correctorDeltas: candidate,
                candidateDeltas: candidate,
                appliedDeltas: applied,
                maxCorrectionDeg: 15,
                balanceState: "ok",
                intensityLevel: intensityLevel
            )
            lines.append(encodeLine(s))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func writeTempFile(_ content: String, name: String = "session.jsonl") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? content.data(using: .utf8)?.write(to: url)
        return url
    }

    static func jsonLine(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func encodeLine<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let data = try! enc.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
