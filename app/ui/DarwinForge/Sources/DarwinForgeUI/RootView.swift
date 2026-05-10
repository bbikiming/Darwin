import ForgeCore
import SwiftUI

/// 앱 메인. NavigationSplitView (사이드바 + 디테일).
public struct RootView: View {
    @StateObject private var store = ConnectionStore()
    @State private var selectedTab: AppTab = .board

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                ConnectionView()
                    .padding()

                Divider()

                List(AppTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }

                Spacer()

                versionFooter
            }
            .frame(minWidth: 280, idealWidth: 320)
        } detail: {
            detailFor(selectedTab)
                .frame(minWidth: 700, minHeight: 500)
        }
        .navigationTitle("DarwinForge")
        .environmentObject(store)
    }

    @ViewBuilder
    private func detailFor(_ tab: AppTab) -> some View {
        switch tab {
        case .board:    BoardStatusView()
        case .joints:   JointControlView()
        case .motion:   MotionLibraryView()
        case .walk:     WalkSimView()
        case .strategy: StrategyView()
        }
    }

    private var versionFooter: some View {
        HStack {
            Image(systemName: "cube.box")
            Text("forge-core \(forgeCoreVersion())")
                .font(.caption.monospaced())
        }
        .foregroundStyle(.secondary)
        .padding()
    }
}

enum AppTab: String, CaseIterable {
    case board, joints, motion, walk, strategy

    var title: String {
        switch self {
        case .board:    return "Board Status"
        case .joints:   return "Joint Control"
        case .motion:   return "Motion Library"
        case .walk:     return "Walk Sim"
        case .strategy: return "Strategy FSM"
        }
    }

    var icon: String {
        switch self {
        case .board:    return "cpu"
        case .joints:   return "slider.horizontal.3"
        case .motion:   return "play.rectangle.on.rectangle"
        case .walk:     return "figure.walk"
        case .strategy: return "brain.head.profile"
        }
    }
}
