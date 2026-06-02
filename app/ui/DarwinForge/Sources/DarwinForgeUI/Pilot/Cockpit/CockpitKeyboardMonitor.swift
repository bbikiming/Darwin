import AppKit
import SwiftUI

/// **방법론 (Unity InputManager / Unreal Enhanced Input)**
///
/// SwiftUI 의 `.keyboardShortcut(_:modifiers:)` 는 keyDown 한 번만 발사 — hold /
/// release 를 구분하지 못해 사용자가 키를 떼도 motion 이 멈추지 않는 결함이 있다.
/// 게임/시뮬에서는 keyDown · keyUp · repeat 세 가지 state 가 분리되어 hold 동안
/// 입력이 유지되고 release 즉시 정지한다.
///
/// macOS 등가는 `NSEvent.addLocalMonitorForEvents(matching:[.keyDown, .keyUp])`.
/// 본 monitor 는 cockpit view 활성 동안만 install 되고 disappear 시 remove —
/// 다른 화면 (워크 랩 등) 의 키보드 입력은 영향 X.
///
/// # Single source-of-truth (code review HIGH #1)
///
/// 본 monitor 는 **state.heldKeys 만** 갱신하는 권위 store. 자체 local set 을 두지
/// 않아 hotkeys (`.keyboardShortcut`) 와 monitor 가 서로 view 가 divergent 되는
/// race 를 차단. `state.insertHeldKey` / `state.removeHeldKey` 가 set + applyHeldKeys
/// 를 atomic 하게 처리.
@MainActor
public final class CockpitKeyboardMonitor {

    private weak var state: CockpitState?
    private var localMonitor: Any?

    public init(state: CockpitState) {
        self.state = state
    }

    public func start() {
        guard localMonitor == nil else { return }
        // **hybrid 전략 (사용자 보고: NSEvent monitor 단독 fail)**:
        //   - keyDown 은 SwiftUI `.keyboardShortcut` (CockpitKeyboardHotkeys) 가
        //     처리해 OS auto-repeat 까지 잡음. 본 monitor 는 통과 (return event).
        //   - 본 monitor 는 **keyUp 만** 책임 → 키 떼면 즉시 state.removeHeldKey.
        // monitor 가 어떤 이유로 install 실패해도 keyboardShortcut + 250ms timer
        // fallback 이 robot 정지를 보장한다.
        //
        // **modifier filter**: `.deviceIndependentFlagsMask` 로 capsLock / numericPad
        // 같은 noise flag 제거. Shift 는 통과.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) || mods.contains(.option) || mods.contains(.control) {
                return event
            }
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let ch = chars.first else {
                return event
            }
            let movementKeys: Set<Character> = ["w", "a", "s", "d", "q", "e"]
            guard movementKeys.contains(ch) else { return event }
            if event.type == .keyUp {
                self.state?.removeHeldKey(ch)
            }
            return event   // keyDown 은 통과 — keyboardShortcut 가 처리.
        }
    }

    public func stop() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        // 화면 떠날 때 stuck key 방지 — 모든 held 키 release.
        let keys = state?.heldKeys ?? []
        for k in keys {
            state?.removeHeldKey(k)
        }
    }
}
