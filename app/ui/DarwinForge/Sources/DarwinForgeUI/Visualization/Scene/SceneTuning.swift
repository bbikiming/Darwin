import SwiftUI

/// 조명·머티리얼 라이브 튜닝 상태 — 뷰포트 오버레이 패널이 바인딩하는 단일 소스.
///
/// **2026-06-11**: 헤드리스 스냅샷엔 로봇이 안 나와 머티리얼/조명 미적 튜닝을 실기
/// 렌더에서만 할 수 있다([[headless-snapshot-robot-invisible]]). 사용자가 슬라이더로
/// 직접 조절하도록 도입. 기본값 = W1 커밋 수치이므로 디폴트 상태 렌더는 불변.
///
/// 적용 경로: 패널 슬라이더 → `@Published` 변경 → `RobotSceneCoordinator` 가
/// `objectWillChange` 를 Combine 구독해 `applyTuning()` 호출(뷰 계층 비의존 →
/// 모든 활성 3D 씬에 동시 반영). 세션 한정(미영속) — UserDefaults 미사용(테스트 오염 회피).
public final class SceneTuning: ObservableObject {
    public static let shared = SceneTuning()

    // ── 조명 ──────────────────────────────────────────────────────────────
    @Published public var keyIntensity: Double = 550      // SceneStage.keyIntensity
    @Published public var rimIntensity: Double = 180      // SceneStage.rimIntensity
    @Published public var iblIntensity: Double = 1.0      // SceneStage.iblIntensity
    @Published public var shadowRadius: Double = 7        // SceneStage.keyShadowRadius

    // ── 머티리얼 ──────────────────────────────────────────────────────────
    // 머리·전완은 흰 쉘로 통일 — whiteShellRoughness 가 함께 제어.
    @Published public var whiteShellRoughness: Double = 0.42
    @Published public var aluminumMetalness: Double = 0.85
    @Published public var aluminumRoughness: Double = 0.35

    // ── 바닥 ──────────────────────────────────────────────────────────────
    @Published public var floorBrightness: Double = 0.10
    @Published public var floorRoughness: Double = 0.85

    private init() {}

    /// 모든 값을 W1 기본값으로 복원.
    public func resetToDefaults() {
        keyIntensity = 550;  rimIntensity = 180;  iblIntensity = 1.0;  shadowRadius = 7
        whiteShellRoughness = 0.42
        aluminumMetalness = 0.85;  aluminumRoughness = 0.35
        floorBrightness = 0.10;  floorRoughness = 0.85
    }
}
