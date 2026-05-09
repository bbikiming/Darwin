import SwiftUI
import RobotKit

public struct RootView: View {
    @State private var robots: [Robot] = [.darwinOne, .darwinTwo]

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(robots) { robot in
                NavigationLink(robot.name, value: robot.id)
            }
            .navigationTitle("DarwinForge")
        } detail: {
            ContentUnavailableView("Select a robot",
                                   systemImage: "figure.stand",
                                   description: Text("Pick Darwin-1G or Darwin-2G to inspect."))
        }
    }
}
