import Foundation

/// 바인딩 변경 결과 → 사용자 피드백 문구 (설계 §B 토스트, 순수 함수).
///
/// 스왑이 조용히 일어나던 동작을 가시화한다: "X ← 긴급 정지 (볼 트래킹은 미설정됨)".
public enum BindingChangeFeedback {

    public static func message(
        action: CockpitAction,
        binding: ControllerBinding,
        result: ControllerSetBindingResult
    ) -> String {
        switch result {
        case .applied:
            return binding.isUnbound
                ? "‘\(action.label)’ 매핑 해제됨"
                : "\(binding.rgg01Label) ← \(action.label)"
        case .appliedWithSwap(let swapped):
            let displaced = swapped.map(\.label).joined(separator: ", ")
            return "\(binding.rgg01Label) ← \(action.label) (\(displaced)은 미설정됨)"
        case .rejectedSafetyUnbound(let safety):
            return "‘\(safety.label)’ 은 안전 동작이라 해제할 수 없어요."
        case .rejectedSafetyStolen(let safety):
            return "‘\(safety.label)’(안전)에 할당된 입력이라 가져올 수 없어요."
        }
    }

    /// 실행취소 버튼을 보여줄지 — 프로파일이 실제로 바뀐 경우만.
    public static func isUndoable(_ result: ControllerSetBindingResult) -> Bool {
        switch result {
        case .applied, .appliedWithSwap: return true
        case .rejectedSafetyUnbound, .rejectedSafetyStolen: return false
        }
    }
}
