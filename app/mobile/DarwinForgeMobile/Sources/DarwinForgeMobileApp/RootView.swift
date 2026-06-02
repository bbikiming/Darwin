import SwiftUI

public struct RootView: View {

    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    // 첫 탭은 검증된 preset/action 중심 PilotScreen. 조종기(RemotePilotScreen)는
    // 아날로그 조이스틱 + 외부 컨트롤러(MFi / DJI RC) 입력 경로 — Mac 서버의
    // capabilities.walkFreeform 이 true 일 때 실 로봇으로 명령을 전달한다.
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
                .tabItem { Label("조종기", systemImage: "gamecontroller.fill") }
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
        // V297-6 (PM Story S2.3): bootstrap 후 자동 페어링 시도.
        .task {
            state.bootstrap()
            await state.attemptAutoPair()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // 포그라운드 복귀 — 백그라운드에서 iOS 가 끊은 연결을 되살린다.
                state.appDidBecomeActive()
            } else {
                state.appWillResignActive()
            }
        }
        .onChange(of: selectedTab) { old, new in
            guard old != new, state.activeWalkPreset != nil else { return }
            Task { await state.stopWalk(reason: .tabSwitch) }
        }
    }
}

#Preview {
    RootView()
}
