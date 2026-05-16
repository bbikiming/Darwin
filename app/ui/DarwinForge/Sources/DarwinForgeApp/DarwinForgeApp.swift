import AppKit
import DarwinForgeUI
import SwiftUI

/// AppDelegate — `swift run`으로 실행하면 .app 번들이 없어서 macOS가
/// activation policy를 자동으로 잡지 못한다. 명시적으로 .regular로 올려
/// dock 아이콘 + 메뉴 + 윈도우 활성화를 강제한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 첫 launch maximize 가 한 번 적용됐는지. 사용자가 그 후 작게 만들면 회복 안 함.
    private var didMaximizeOnLaunch: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 앱 아이콘 — SwiftPM 번들 PNG (사용자 지정 자산) 우선, 누락 시 코드 생성 fallback.
        // `.app` bundle 의 AppIcon.icns 가 있으면 macOS 가 우선 사용.
        // 2026-05-16 (재복구): 사용자 명시 — option/ChatGPT Image 10_57_32 (1).png 영구 적용.
        NSApp.applicationIconImage = AppIcon.loadBundledPNG() ?? AppIcon.make()

        for w in NSApp.windows {
            configureWindow(w)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let w = note.object as? NSWindow {
                Self.configureWindow(w)
                // 첫 visible window 가 잡혔을 때 1회 추가 maximize 시도.
                // didFinishLaunching 직후엔 window 가 아직 visible 아닐 수 있어 보강.
                if let self = self, !self.didMaximizeOnLaunch, w.isVisible {
                    self.maximizeWindow(w, isInitialLaunch: true)
                    self.didMaximizeOnLaunch = true
                }
            }
        }

        // 첫 실행 시 자동 maximize — 모니터 visibleFrame 가득 채움 (메뉴바/Dock 영역 제외).
        // 2026-05-16 보강: asyncAfter 0.3s 로 충분한 window-creation 시간 확보 (macOS
        // Sonoma+ SwiftUI life-cycle 에서 window 가 didFinishLaunching 직후엔 invisible).
        // didBecomeKey observer 와 이중 안전망 — 둘 중 어느 쪽이든 먼저 잡으면 1회 적용.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.didMaximizeOnLaunch else { return }
            self.maximizeMainWindow(isInitialLaunch: true)
            self.didMaximizeOnLaunch = true
        }
    }

    /// 메인 윈도우를 모니터 visibleFrame 가득 채움 (zoom = maximize).
    /// 시스템 환경설정의 "Dock / Menu Bar" 영역 자동 회피.
    /// `isInitialLaunch: true` 면 첫 launch 의 SwiftUI Scene race 차단용 stage 3 적용.
    func maximizeMainWindow(isInitialLaunch: Bool = false) {
        guard let w = NSApp.windows.first(where: { $0.isVisible }) else { return }
        maximizeWindow(w, isInitialLaunch: isInitialLaunch)
    }

    /// 지정 window 를 모니터 visibleFrame 가득 채움.
    ///
    /// **2026-05-16 강화**: 종전 `setFrame` 단독 호출이 SwiftUI Scene 의 `.defaultSize`
    /// / `.windowResizability(.contentSize)` 와 충돌해 적용 후 다시 ideal size 로 복귀
    /// 되는 회귀 발견. 3-stage 강제:
    ///   1. `performZoom(nil)` — macOS native zoom (delegate `windowWillUseStandardFrame`
    ///      자동 호출, visibleFrame 반환)
    ///   2. `setFrame(visibleFrame, animate: false)` 직접 호출 — performZoom 미반응 안전망
    ///   3. asyncAfter 0.2s 한 번 더 setFrame — SwiftUI re-layout 이후 override 차단
    ///
    /// **2026-05-17 24차 cycle 2 fix**: `isInitialLaunch` 인자 추가. 첫 launch 시만
    /// stage 3 적용 — 사용자가 메뉴 "창 최대화" / 명시 호출 시 0.2s 후 사용자 manual
    /// resize 덮어쓰는 race 차단. flag check 는 stage 3 closure 안에서 추가 안전망.
    func maximizeWindow(_ w: NSWindow, isInitialLaunch: Bool = false) {
        guard let screen = w.screen ?? NSScreen.main else { return }
        let target = screen.visibleFrame

        // Stage 1: macOS native zoom — Apple HIG 표준 maximize 동작.
        if !w.isZoomed {
            w.performZoom(nil)
        }

        // Stage 2: zoom 미반응 시 직접 setFrame (애니메이션 없이 즉시).
        if w.frame != target {
            w.setFrame(target, display: true, animate: false)
        }

        // Stage 3: 첫 launch 의 SwiftUI Scene defaultSize race 만 차단.
        // 사용자 명시 호출 (메뉴 / 단축키) 시 skip — 사용자가 0.2s 안에 manual resize
        // 한 경우 덮어쓰는 회귀 방지.
        guard isInitialLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // didMaximizeOnLaunch 이미 set 됐어도 사용자가 그 사이 resize 했을 수
            // 있음 → frame == target 일 때만 한 번 더 강제.
            guard self != nil, w.frame != target else { return }
            w.setFrame(target, display: true, animate: false)
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
                    minWidth: 1024, idealWidth: 1600, maxWidth: .infinity,
                    minHeight: 640, idealHeight: 1000, maxHeight: .infinity
                )
        }
        // 2026-05-16 fix: maximize 회귀 차단 — defaultSize 를 visibleFrame 보다 큰 값
        // (4096×2560 = 5K iMac visibleFrame 상위) 으로 두면 시스템이 자동 clamp →
        // 모든 모니터에서 첫 launch 부터 화면 가득. SceneStorage 가 frame 기억하더라도
        // AppDelegate.maximizeMainWindow 의 3-stage retry 가 보강.
        .defaultSize(width: 4096, height: 2560)
        // 2026-05-16: `.contentSize` → `.contentMinSize` 변경.
        // - `.contentSize` 는 max 도 SwiftUI 가 강제 (maxWidth: .infinity 무시 사례
        //   재발) → setFrame visibleFrame 적용 후 다시 ideal size 로 되돌리는 race.
        // - `.contentMinSize` 는 SwiftUI minSize 만 관여 — NSWindow setFrame 자유.
        // RootView frame 의 `maxWidth/maxHeight: .infinity` 와 결합해 안정.
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

                Divider()

                // 전체화면 단축키 — macOS 자체 제공 (⌃⌘F) 지만 "보기" 메뉴에 명시 노출.
                // Apple HIG: 핵심 동작은 메뉴바에서 발견 가능해야 함 (Discoverability).
                Button("전체 화면 시작/종료") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])

                // 창 최대화 (zoom) — 모니터 visibleFrame 가득 (메뉴바/Dock 자동 회피).
                // fullscreen 과 다름: 메뉴바 / Dock 은 보이고 윈도우만 확장.
                Button("창 최대화") {
                    if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                        if let screen = w.screen ?? NSScreen.main {
                            w.setFrame(screen.visibleFrame, display: true, animate: true)
                        }
                    }
                }
                .keyboardShortcut("m", modifiers: [.control, .command])

                Divider()

                // **2026-05-16**: Fall Prevention 모니터링 dashboard 토글.
                // ⌘⇧M — WalkLab 활성 시 시계열/이벤트 로그/6-Layer 상태 패널 펼침.
                // Apple HIG Discoverability — 키보드 단축키를 메뉴바에서 발견 가능.
                Button("Fall Prevention 모니터링") {
                    NotificationCenter.default.post(name: .dfToggleMonitoring, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                // **2026-05-16**: 로봇 카메라 floating window — 모션 도중에도 호출 가능.
                // ⌘⌥C — `Window` Scene (id: "robot-camera") 새 인스턴스 / 활성화.
                OpenCameraWindowButton()
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

        // 2026-05-16: 로봇 카메라 floating window — 별도 scene (단일 instance).
        // 어떤 메뉴 / 모드 (스튜디오, WalkLab, 모션 스튜디오 등) 작업 도중 카메라
        // 실시간 stream 동시 표시 가능. motion_play (Dynamixel bus) 와 별개 채널
        // (HTTP 8080 stream) — 동시 동작 충돌 없음.
        // ⌘⌥C — `OpenCameraWindowButton` 의 SwiftUI `openWindow` action 으로 표시.
        Window("로봇 카메라", id: "robot-camera") {
            RobotCameraWindow()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 540)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
    }
}

/// `commands` closure 안에서 `@Environment(\.openWindow)` 를 사용하려면 별도 view
/// struct 가 필요. closure 직접에는 environment 키 캡처 안 됨.
private struct OpenCameraWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("로봇 카메라 윈도우") {
            openWindow(id: "robot-camera")
        }
        .keyboardShortcut("c", modifiers: [.command, .option])
    }
}
