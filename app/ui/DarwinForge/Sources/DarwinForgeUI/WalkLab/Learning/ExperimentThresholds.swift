import Foundation

/// **v1.11.14.7 (2026-05-19) — 사용자 평가 MED fix**: verdict 임계값 외부화.
///
/// 종전: `WalkLabExperimentLoop.compareWithBaseline` 안에 모든 임계값 hardcode.
/// (peakPitchDelta>=10, peakRollDelta>=8, avgBusFails>5, avgStaleRatio>0.15, ...)
/// 사용자 환경 (ROBOTIS-OP2 + tile 바닥 vs 카펫 등) 별로 tuning 불가.
///
/// 본 struct 가 모든 임계값 보관. `shared` singleton 이 UserDefaults 영속화.
/// UI (`ExperimentThresholdsPanel` — 후속 PR) 가 사용자 명시 조절 가능.
///
/// 임계값 분류 (priority desc):
/// 1. **failRollback** — 즉시 rollback 권고 (안전 우선).
/// 2. **inconclusive** — 추가 데이터 권고 (재실험).
/// 3. **success** — 모든 조건 충족 → 변경 수락.
public struct ExperimentThresholds: Codable, Equatable, Sendable {
    // MARK: - failRollback 트리거

    /// 실험 세션 sampleCount / baseline sampleCount < 이 값 → abort/fall 의심.
    /// default 0.7 — 30% 이상 단축은 비정상.
    public var abortSampleRatio: Double = 0.7

    /// 실험 peakAbsPitch - baseline peakAbsPitch ≥ 이 값 → fail.
    /// default 10.0° — 평균 8.5° 보행 robot 기준 fall 임박.
    public var peakPitchDeltaFailDeg: Double = 10.0

    /// 실험 peakAbsRoll - baseline peakAbsRoll ≥ 이 값 → fail.
    /// default 8.0° — lateral 안정성 손실.
    public var peakRollDeltaFailDeg: Double = 8.0

    /// 실험 누적 busWriteFailures > 이 값 → fail (통신 불안정).
    /// default 5 — 보행 1회당 5건 초과는 robot 측 문제.
    public var busFailsMax: Int = 5

    // MARK: - inconclusive 트리거

    /// staleSampleRatio > 이 값 → 데이터 신뢰도 부족.
    /// default 0.15 — 15% 이상 IMU stale 은 분석 의미 X.
    public var maxStaleRatio: Double = 0.15

    // MARK: - success 조건 (모두 충족)

    /// pitchDelta ≤ 이 값 (음수 = 개선) → success 첫 조건.
    /// default -0.5 — 0.5° 이상 개선 필요.
    public var successPitchDelta: Double = -0.5

    /// peakPitchDelta ≤ 이 값 → success 둘째 조건.
    /// default 5.0 — peak 도 너무 증가하면 안 됨.
    public var successPeakPitchDelta: Double = 5.0

    /// rollDelta ≤ 이 값 → success 셋째 조건.
    /// default 1.0 — roll 약간 증가는 허용.
    public var successRollDelta: Double = 1.0

    /// peakRollDelta ≤ 이 값 → success 넷째 조건.
    /// default 5.0 — peak roll 안전 마진.
    public var successPeakRollDelta: Double = 5.0

    public init() {}

    // MARK: - Persistence

    /// UserDefaults 키 (단일).
    private static let storageKey = "DarwinForge.ExperimentThresholds"

    /// 디스크에서 load. 없으면 default 반환. corrupt 면 default 반환 (silent).
    public static func loadFromDisk() -> ExperimentThresholds {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ExperimentThresholds.self, from: data)
        else { return ExperimentThresholds() }
        return decoded
    }

    /// 디스크에 save. JSON encode 실패는 silent (default 로 fallback).
    public func saveToDisk() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// 모든 값 reset (default).
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// **v1.11.14.7**: `ExperimentThresholds` singleton 매니저.
/// `WalkLabExperimentLoop.compareWithBaseline` 가 본 instance 참조.
/// UI 가 변경 시 `setThresholds` 호출 → 자동 영속화.
@MainActor
public final class ExperimentThresholdsManager: ObservableObject {
    public static let shared = ExperimentThresholdsManager()

    @Published public private(set) var thresholds: ExperimentThresholds

    public init() {
        self.thresholds = ExperimentThresholds.loadFromDisk()
    }

    public func setThresholds(_ t: ExperimentThresholds) {
        thresholds = t
        t.saveToDisk()
    }

    public func reset() {
        ExperimentThresholds.reset()
        thresholds = ExperimentThresholds()
    }
}
