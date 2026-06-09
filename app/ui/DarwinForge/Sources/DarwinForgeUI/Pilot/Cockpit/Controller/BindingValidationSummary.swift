import Foundation

/// 하단 검증 레일의 표시 상태 — 프로파일 충돌/안전 검증 요약 (설계 §D, 순수 함수).
///
/// 충돌이 있으면 첫 이슈를 헤드라인으로 보여주고, 중복 입력이면 그 바인딩을
/// `focusBinding` 으로 노출해 클릭 시 해당 컨트롤로 이동할 수 있게 한다.
public struct BindingValidationSummary: Equatable, Sendable {

    public let isValid: Bool
    /// 레일에 표시할 한 줄 요약.
    public let headline: String
    /// 클릭 시 선택할 충돌 바인딩 (중복 입력일 때만).
    public let focusBinding: ControllerBinding?

    public static func from(_ profile: ControllerBindingProfile) -> BindingValidationSummary {
        let conflicts = profile.conflicts()
        guard !conflicts.isEmpty else {
            return BindingValidationSummary(isValid: true, headline: "충돌 0 · 안전 OK", focusBinding: nil)
        }

        let first = message(for: conflicts[0])
        let headline = conflicts.count > 1 ? "\(first) 외 \(conflicts.count - 1)건" : first
        let focus: ControllerBinding? = conflicts.compactMap { conflict -> ControllerBinding? in
            if case .duplicateInput(let binding, _) = conflict { return binding }
            return nil
        }.first

        return BindingValidationSummary(isValid: false, headline: headline, focusBinding: focus)
    }

    private static func message(for conflict: ControllerBindingConflict) -> String {
        switch conflict {
        case .duplicateInput(let binding, let actions):
            return "중복: \(binding.rgg01Label) — \(actions.map(\.label).joined(separator: ", "))"
        case .safetyCriticalUnbound(let action):
            return "안전 미할당: \(action.label)"
        }
    }
}
