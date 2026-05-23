import SwiftUI

// MARK: - EnvironmentValues.harness (Wave 3 Phase 3.1, 사이클 241)
//
// SwiftUI Environment key — `\.harness` 로 view tree 어디서든 주입된 Harness 접근.
// default 는 NoopHarness — Preview / 단위 테스트에서 디스크 기록 0.
//
// 사용 예:
//
//   // App init:
//   WindowGroup { ContentView().environment(\.harness, LiveHarness.shared) }
//
//   // Preview / 테스트:
//   ContentView().environment(\.harness, NoopHarness())
//
//   // View 내부:
//   struct SomeView: View {
//       @Environment(\.harness) private var harness
//       var body: some View {
//           Button("tap") { harness.record(.uiButtonTapped) }
//       }
//   }

private struct HarnessKey: EnvironmentKey {
    /// **MainActor default** — HarnessFacade 메서드 대부분이 @MainActor 이므로
    /// default 도 같은 isolation. SwiftUI Environment 는 default 가 nonisolated 여야
    /// 하지만 `any HarnessFacade` 는 existential 로 boxed — NoopHarness() 인스턴스
    /// 생성만 nonisolated 면 됨. NoopHarness.init 은 @MainActor 인스턴스를 만들지만
    /// EnvironmentKey static 컨텍스트에서 즉시 생성 가능 (Swift 의 lazy init 보장).
    @MainActor
    static var defaultValue: any HarnessFacade { NoopHarness() }
}

public extension EnvironmentValues {
    /// 현재 view 가 사용할 Harness. 기본은 NoopHarness.
    var harness: any HarnessFacade {
        get { self[HarnessKey.self] }
        set { self[HarnessKey.self] = newValue }
    }
}
