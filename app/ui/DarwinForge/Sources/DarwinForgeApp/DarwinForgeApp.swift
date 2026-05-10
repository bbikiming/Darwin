import DarwinForgeUI
import SwiftUI

@main
struct DarwinForgeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1024, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Link("ROBOTIS e-Manual",
                     destination: URL(string: "https://emanual.robotis.com/docs/en/platform/op2/getting_started/")!)
                Link("Project README",
                     destination: URL(string: "https://github.com/bbikiming/Darwin")!)
            }
        }
    }
}
