import SwiftUI

public struct RootView: View {

    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    // P0-2 fix (truth-gap report, 2026-05-25): 첫 탭은 검증된 preset/action
    // 중심 PilotScreen. 조종기 탭(RemotePilotScreen)은 Mock/Review 모드용
    // 시뮬레이션 보조 화면으로 두 번째에 배치한다.
    @State private var selectedTab: Tab = .actions

    public init() {}

    public enum Tab: String, Sendable {
        case actions, pilot, connect, test, logs
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            PilotScreen()
                .tabItem { Label("동작", systemImage: "figure.walk.motion") }
                .tag(Tab.actions)
                .accessibilityIdentifier("tab.actions")

            RemotePilotScreen()
                .tabItem { Label("조종기 (연습)", systemImage: "gamecontroller.fill") }
                .tag(Tab.pilot)
                .accessibilityIdentifier("tab.pilot")

            ConnectScreen()
                .tabItem { Label("연결", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.connect)
                .accessibilityIdentifier("tab.connect")

            TestScreen()
                .tabItem { Label("테스트", systemImage: "checklist") }
                .tag(Tab.test)
                .accessibilityIdentifier("tab.test")

            LogsScreen()
                .tabItem { Label("기록", systemImage: "list.bullet.rectangle") }
                .tag(Tab.logs)
                .accessibilityIdentifier("tab.logs")
        }
        .environmentObject(state)
        .task { state.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                state.appWillResignActive()
            }
        }
        .onChange(of: selectedTab) { old, new in
            // Leaving any pilot-style tab while an active command is running
            // must trigger a stop — applies to both 조종기 (.pilot) and 동작 (.actions).
            if (old == .pilot || old == .actions) && (new != .pilot && new != .actions) {
                Task { await state.stopWalk(reason: .tabSwitch) }
            }
        }
    }
}

#Preview {
    RootView()
}
