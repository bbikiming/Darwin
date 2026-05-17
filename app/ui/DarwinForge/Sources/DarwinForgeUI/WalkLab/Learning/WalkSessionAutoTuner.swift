import Foundation
import SwiftUI

/// **v1.9 (2026-05-17)**: 무한 반복 학습 시스템 — session 결과 누적 + 자동 튜닝.
///
/// **흐름**:
/// 1. 보행 cycle 종료 → `WalkSessionLogger` 가 sample 배열 보유
/// 2. `WalkSessionAnalyzer` 가 summary 산출 (권고 level + 이유 + confidence)
/// 3. `record(summary:)` 호출 → tuner 가 최근 N session history 보관
/// 4. `nextRecommendedLevel` 계산 (최근 권고 평균 + 안전 가드)
/// 5. `autoApplyEnabled = true` 면 다음 cycle 시작 시 `correctorIntensityLevel` 자동 변경
///
/// **안전 가드**:
/// - 한 번에 ±1 단계만 변경 (급변 방지)
/// - confidence < 0.5 면 변경 안 함
/// - 최근 N session 권고가 일관 (같은 방향) 일 때만 변경
/// - 사용자가 수동으로 level 변경 시 auto-apply 일시 중단 (override 존중)
@MainActor
public final class WalkSessionAutoTuner: ObservableObject {

    /// 자동 적용 ON/OFF — 사용자 토글.
    @Published public var autoApplyEnabled: Bool = false

    /// 최근 session summary list — 신규가 앞.
    @Published public private(set) var recentSummaries: [WalkSessionSummary] = []

    /// 다음 cycle 에 적용할 추천 level. nil = 변경 없음.
    @Published public private(set) var pendingRecommendation: (level: Int, reason: String)? = nil

    /// 최근 N session 의 권고 history (consistency 판단용).
    public static let consistencyWindow: Int = 3

    /// 권고 적용을 위한 최소 confidence.
    public static let minConfidenceForApply: Double = 0.50

    /// 디스크 cleanup 트리거.
    private var sessionsSinceCleanup: Int = 0
    public static let cleanupEvery: Int = 5

    public init() {
        // 시작 시 디스크 summary load — 사용자 history 보존.
        self.recentSummaries = WalkSessionStore.loadAllSummaries()
    }

    /// 종료된 session 의 분석 결과 record.
    /// 이미 디스크에 .summary.json 저장된 상태 가정.
    public func record(_ summary: WalkSessionSummary, currentLevel: Int) {
        recentSummaries.insert(summary, at: 0)
        if recentSummaries.count > 50 {
            recentSummaries.removeLast(recentSummaries.count - 50)
        }
        // 권고 계산.
        pendingRecommendation = computeRecommendation(currentLevel: currentLevel)
        sessionsSinceCleanup += 1
        if sessionsSinceCleanup >= Self.cleanupEvery {
            sessionsSinceCleanup = 0
            WalkSessionStore.cleanupOldSessions()
        }
    }

    /// 사용자가 수동으로 level 변경 → auto-apply 일시 중단 (다음 session 의 권고 reset).
    public func userOverride() {
        pendingRecommendation = nil
    }

    /// 다음 cycle 시작 시 호출. autoApplyEnabled 면 권고 level 반환, 아니면 currentLevel.
    public func levelToApply(currentLevel: Int) -> Int {
        guard autoApplyEnabled, let rec = pendingRecommendation else { return currentLevel }
        let applied = max(0, min(4, rec.level))
        // 한 번에 ±1 단계 제한.
        let delta = applied - currentLevel
        let limited = currentLevel + (delta > 0 ? min(1, delta) : max(-1, delta))
        return limited
    }

    // MARK: - Private

    private func computeRecommendation(currentLevel: Int) -> (level: Int, reason: String)? {
        let window = recentSummaries.prefix(Self.consistencyWindow)
        guard window.count >= 1 else { return nil }
        // 최신 session 의 권고.
        let latest = window.first!
        guard latest.confidence >= Self.minConfidenceForApply else {
            return nil
        }
        // consistency check — 최근 N session 모두 같은 방향 권고?
        if window.count >= 2 {
            let directions = window.map { sgn($0.recommendedIntensityLevel - $0.intensityLevelUsed) }
            // 모두 0 이면 유지 권고로 간주.
            // 부호 일치 (양수 또는 음수) 시만 적용.
            let allUp = directions.allSatisfy { $0 >= 0 } && directions.contains { $0 > 0 }
            let allDown = directions.allSatisfy { $0 <= 0 } && directions.contains { $0 < 0 }
            if !(allUp || allDown) {
                // 권고가 일관 X — 보수적으로 유지.
                return nil
            }
        }
        let recommended = latest.recommendedIntensityLevel
        guard recommended != currentLevel else { return nil }
        let arrow = recommended > currentLevel ? "↑" : "↓"
        let reason = "최근 \(window.count)회 session 분석: \(arrow) level \(currentLevel)→\(recommended) — \(latest.recommendationReason)"
        return (recommended, reason)
    }

    private func sgn(_ x: Int) -> Int {
        if x > 0 { return 1 }
        if x < 0 { return -1 }
        return 0
    }
}
