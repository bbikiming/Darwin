import Foundation

/// **v1.11 wiring (2026-05-17) — handoff §3 호환 stub**.
///
/// `docs/handoff/2026-05-17-walk-data-pipeline-v2-handoff.md` §3 의 `comparisonTag`
/// 필드를 위한 경량 struct. v2 pipeline (worktree `naughty-chebyshev-713072`) 이
/// main 으로 merge 될 때 본 stub 이 그 구현으로 대체됩니다. main 에서는 단순히
/// `arm` 라벨 ("A" / "B") + 사용자 메모 만 저장합니다.
///
/// **상호운용성**: v2 의 `WalkComparisonTag` 와 동일한 keyed Codable 표현이므로
/// JSONL 로 기록된 데이터는 worktree merge 후에도 그대로 decode 됩니다.
public struct WalkComparisonTag: Codable, Equatable, Sendable {
    /// A/B 비교 arm 라벨 (예: "A", "B"). 단일 변수 비교 시 두 세션이 같은 base 에서
    /// 한 축만 다르게 기록될 때 의미. nil 이면 비교 의도 없음.
    public var arm: String?
    /// 자유 메모 — 환경 (cradle/floor), 배터리, 표면 등.
    public var note: String?

    public init(arm: String? = nil, note: String? = nil) {
        self.arm = arm
        self.note = note
    }
}
