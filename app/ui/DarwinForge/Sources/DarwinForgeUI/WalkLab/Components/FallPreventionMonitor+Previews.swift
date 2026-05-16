#if DEBUG
import SwiftUI
import ForgeCore

/// **FallPreventionMonitor 시각 회귀 preview**.
///
/// Xcode Canvas 에서 다양한 폭 / 상태 / 접근성 모드 시각 확인.
///
/// 2026-05-16 Phase D-1: 경량 snapshot scaffold — external dep 없이
/// Xcode Preview 만으로 시각 회귀 1차 검증.
///
/// **Mac 검증 절차**:
/// 1. Xcode 에서 본 파일 열기
/// 2. Canvas 활성 (⌘⌥↩)
/// 3. 5 시나리오 모두 의도된 모습 확인
/// 4. Variants → "Dynamic Type" / "Color Scheme" / "Orientation"
///
/// **별도 PR (Phase D-2)**: swift-snapshot-testing 라이브러리 dep + 자동 회귀.
struct FallPreventionMonitor_VisualPreview: View {
    let scenario: Scenario

    enum Scenario: String, CaseIterable, Identifiable {
        case normal       = "정상 상태"
        case warning      = "경고 (22°+)"
        case danger       = "위험 (28°+)"
        case correctorOn  = "Corrector ON"
        case eventsLog    = "이벤트 로그"
        var id: String { rawValue }
    }

    var body: some View {
        let session = makeSession(scenario)
        return FallPreventionMonitor(session: session)
            .padding()
            .background(DFColor.canvas)
    }

    @MainActor
    private func makeSession(_ s: Scenario) -> WalkLabSession {
        let session = WalkLabSession()
        // 직접 published property 변경 — preview 전용.
        // 실 코드는 tick() 가 갱신.
        switch s {
        case .normal:
            session.imuRollDeg = 2.1
            session.imuPitchDeg = 1.3
        case .warning:
            session.imuRollDeg = 23.5
            session.imuPitchDeg = -5.2
        case .danger:
            session.imuRollDeg = 28.8
            session.imuPitchDeg = 4.1
        case .correctorOn:
            session.imuRollDeg = 8.5
            session.imuPitchDeg = 3.2
            session.enableBalanceCorrection = true
        case .eventsLog:
            session.enableBalanceCorrection = true
            session.enableBalanceCorrection = false
            session.enableBalanceCorrection = true
        }
        return session
    }
}

// MARK: - Preview macros (Xcode 15+)

#Preview("정상 상태 — 800pt") {
    FallPreventionMonitor_VisualPreview(scenario: .normal)
        .frame(width: 800)
}

#Preview("경고 — 800pt") {
    FallPreventionMonitor_VisualPreview(scenario: .warning)
        .frame(width: 800)
}

#Preview("위험 — 800pt") {
    FallPreventionMonitor_VisualPreview(scenario: .danger)
        .frame(width: 800)
}

#Preview("Corrector ON — 1200pt") {
    FallPreventionMonitor_VisualPreview(scenario: .correctorOn)
        .frame(width: 1200)
}

#Preview("이벤트 로그 — 600pt narrow") {
    FallPreventionMonitor_VisualPreview(scenario: .eventsLog)
        .frame(width: 600)
}

// MARK: - Width responsive 회귀

#Preview("반응형 240pt (HSplitView min 미만)") {
    FallPreventionMonitor_VisualPreview(scenario: .normal)
        .frame(width: 240)
}

#Preview("반응형 480pt (HSplitView detail min)") {
    FallPreventionMonitor_VisualPreview(scenario: .warning)
        .frame(width: 480)
}

#Preview("반응형 1920pt (FHD)") {
    FallPreventionMonitor_VisualPreview(scenario: .correctorOn)
        .frame(width: 1920)
}

// MARK: - Accessibility 회귀

#Preview("Dark Mode") {
    FallPreventionMonitor_VisualPreview(scenario: .danger)
        .frame(width: 800)
        .preferredColorScheme(.dark)
}

#Preview("Dynamic Type — xxxLarge") {
    FallPreventionMonitor_VisualPreview(scenario: .normal)
        .frame(width: 800)
        .environment(\.dynamicTypeSize, .xxxLarge)
}
#endif
