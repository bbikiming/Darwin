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
        for w in NSApp.windows {
            configureWindow(w)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow {
                Self.configureWindow(w)
            }
        }
    }

    /// 윈도우 fullscreen + zoom 동작 활성화.
    ///
    /// - `titleVisibility = .hidden`: 신호등 + toolbar 영역은 macOS 가 자동 관리.
    ///   fullSizeContentView 는 적용하지 않음 — toolbar 영역과 컨텐츠 영역의 경계가 명확해야
    ///   SwiftUI .toolbar API 의 ToolbarItem 이 정확한 자리에 그려진다.
    /// - `collectionBehavior += [.fullScreenPrimary, .fullScreenAllowsTiling]`:
    ///   macOS 녹색 신호등 / "View → Enter Full Screen" / ⌃⌘F 가 정상 동작.
    ///   종전엔 SwiftUI 기본값이라 fullscreen 진입이 가끔 막혔음.
    /// - `styleMask += .resizable`: 윈도우 corner / edge 드래그 resize 명시.
    ///   `.windowResizability(.contentSize)` 와 결합해 RootView frame 의 maxWidth/Height = .infinity
    ///   가 발효되어 전체화면 가득 채움.
    private func configureWindow(_ w: NSWindow) {
        w.titleVisibility = .hidden
        w.collectionBehavior.formUnion([.fullScreenPrimary, .fullScreenAllowsTiling])
        w.styleMask.formUnion([.resizable])
    }
    private static func configureWindow(_ w: NSWindow) {
        w.titleVisibility = .hidden
        w.collectionBehavior.formUnion([.fullScreenPrimary, .fullScreenAllowsTiling])
        w.styleMask.formUnion([.resizable])
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
                // **maxWidth/maxHeight = .infinity**: 사용자가 윈도우를 확장하거나 fullscreen
                // 진입 시 콘텐츠가 화면 가득 채움. 종전엔 max 누락으로 idealWidth(1440) 에서 막힘.
                .frame(
                    minWidth: 1024, idealWidth: 1440, maxWidth: .infinity,
                    minHeight: 640, idealHeight: 880, maxHeight: .infinity
                )
        }
        // `.contentSize` → minSize 이상 / 사용자 / fullscreen 모두 자유 resize.
        // 종전 `.contentMinSize` 는 max 없으면 ideal 에 머무는 케이스가 있었음.
        .windowResizability(.contentSize)
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

                Divider()

                // 전체화면 단축키 — macOS 자체 제공 (⌃⌘F) 지만 "보기" 메뉴에 명시 노출.
                // Apple HIG: 핵심 동작은 메뉴바에서 발견 가능해야 함 (Discoverability).
                Button("전체 화면 시작/종료") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
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
