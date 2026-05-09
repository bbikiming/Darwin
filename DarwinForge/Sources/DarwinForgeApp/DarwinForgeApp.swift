import SwiftUI
import DarwinForgeUI

@main
struct DarwinForgeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DarwinForge") {
                    // TODO: present an About panel sourced from the bundle's Info.plist
                }
            }
        }
    }
}
