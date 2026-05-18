import Foundation
import SwiftUI

/// **v1.11.13 (2026-05-19)** — `WalkLabExperimentLoop` actor 의 SwiftUI wrapper.
///
/// actor 는 SwiftUI `@EnvironmentObject` 로 직접 inject 불가. wrapper class 가
/// @Published state 를 view 에 노출 + actor 호출 Task 위임.
///
/// 사용:
/// ```swift
/// // RootView
/// @StateObject private var experimentLoop = ExperimentLoopController()
///   .environmentObject(experimentLoop)
///
/// // ExperimentApprovalUI
/// @EnvironmentObject var experimentLoop: ExperimentLoopController
///   await experimentLoop.startExperiment(...)
/// ```
@MainActor
public final class ExperimentLoopController: ObservableObject {
    private let loop = WalkLabExperimentLoop()

    @Published public private(set) var current: WalkLabExperimentLoop.Experiment? = nil
    @Published public private(set) var history: [WalkLabExperimentLoop.Experiment] = []
    @Published public private(set) var lastComparison: WalkLabExperimentLoop.ComparisonResult? = nil
    @Published public private(set) var lastError: String? = nil

    public init() {
        Task { @MainActor in
            self.history = await loop.history
        }
    }

    /// 실험 시작 — critic 응답 + 사용자 승인 후.
    @discardableResult
    public func startExperiment(
        from response: ClaudeCriticResponse,
        baselineSessionId: String,
        proposedConfig: BalanceExperimentConfig
    ) async -> Bool {
        lastError = nil
        let result = await loop.startExperiment(
            from: response,
            baselineSessionId: baselineSessionId,
            proposedConfig: proposedConfig
        )
        switch result {
        case .success:
            current = await loop.current
            return true
        case .failure(let reason):
            lastError = reason
            return false
        }
    }

    public func appendExperimentSession(_ sessionId: String) async {
        await loop.appendExperimentSession(sessionId)
        current = await loop.current
    }

    public func compareWithBaseline(
        baselineSummary: WalkSessionSummary,
        experimentSummaries: [WalkSessionSummary]
    ) async {
        let comp = await loop.compareWithBaseline(
            baselineSummary: baselineSummary,
            experimentSummaries: experimentSummaries
        )
        lastComparison = comp
        current = await loop.current
    }

    public func finalize() async {
        await loop.finalize()
        current = await loop.current
        history = await loop.history
    }

    public func cancel() async {
        await loop.cancel()
        current = await loop.current
    }

    /// **v1.11.14**: WalkDataView 의 validate(currentConfig:) 결과를 사용자에게 표시.
    /// 외부 caller 가 issue 를 lastError 채널로 전달하기 위한 setter.
    public func setLastError(_ message: String?) {
        lastError = message
    }
}
