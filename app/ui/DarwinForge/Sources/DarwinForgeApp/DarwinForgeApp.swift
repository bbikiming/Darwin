import AppKit
import DarwinForgeUI
import SwiftUI

/// AppDelegate — `swift run`으로 실행하면 .app 번들이 없어서 macOS가
/// activation policy를 자동으로 잡지 못한다. 명시적으로 .regular로 올려
/// dock 아이콘 + 메뉴 + 윈도우 활성화를 강제한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 시스템 타이틀 텍스트만 hide (신호등 + toolbar 영역은 macOS 가 자동 관리).
        // fullSizeContentView 는 적용하지 않음 — toolbar 영역과 컨텐츠 영역의 경계가 명확해야
        // SwiftUI .toolbar API 의 ToolbarItem 이 정확한 자리에 그려진다.
        for w in NSApp.windows {
            w.titleVisibility = .hidden
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                w.titleVisibility = .hidden
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DarwinForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                // minWidth 1024 → 13" MacBook (1280×800) 미만 외부 모니터 + 일반 노트북 모두 지원.
                // minHeight 640 → 일부 압축된 dock/menu 환경의 13" 화면에서도 동작.
                .frame(minWidth: 1024, idealWidth: 1440, minHeight: 640, idealHeight: 880)
        }
        .windowResizability(.contentMinSize)
        // macOS native unified toolbar — NavigationSplitView .toolbar API 와 자연스럽게
        // 통합되어 신호등 + sidebar toggle + 상태 정보 (배터리/온도/토크) 가 한 줄에 그려진다.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // ── P0-G: macOS Menu — 단축키를 메뉴바에 노출 (Apple HIG "Discoverability").
            //         RootView의 hidden Button (.keyboardShortcut)과 단축키가 중복돼도
            //         메뉴는 단축키를 *발견*하는 1차 채널이므로 별도로 둔다.
            //         메뉴 클릭 → NotificationCenter post → RootView가 onReceive로 처리.

            CommandMenu("보기") {
                Button("스튜디오") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "studio")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("티칭 모드") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "teach")
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("모션 스튜디오") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "motion")
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("워크 랩") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "walk")
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("대화") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "conversation")
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("원격 명령") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "remote")
                }
                .keyboardShortcut("6", modifiers: .command)

                Button("전문가") {
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "expert")
                }
                .keyboardShortcut("7", modifiers: .command)

                Divider()

                Button("명령 팔레트…") {
                    NotificationCenter.default.post(name: .dfOpenPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("로봇") {
                Button("자동 USB 연결") {
                    NotificationCenter.default.post(name: .dfAutoConnect, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Divider()

                Button("긴급 정지") {
                    NotificationCenter.default.post(name: .dfEmergencyStop, object: nil)
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appInfo) {
                Link("ROBOTIS e-Manual",
                     destination: URL(string: "https://emanual.robotis.com/docs/en/platform/op2/getting_started/")!)
                Link("Project README",
                     destination: URL(string: "https://github.com/bbikiming/Darwin")!)
            }
        }
    }
}
