import SwiftUI

// MARK: - HarnessShortcuts (V289-5, 2026-05-25)
//
// 비유: 키보드는 비행기의 throttle quadrant — 손이 가장 빨리 닿는 곳에
// critical action 을 배치한다. 마우스를 찾을 시간이 없을 때 비상 정지(⌘.)가
// 즉각 발동되어야 한다.
//
// 기술: 4가지 macOS dashboard 표준 키보드 단축키를 단일 열거형으로 정의.
//       각 단축키는 `.keyboardShortcut(_:modifiers:)` modifier 로 Button 에 바인딩.
//       화면 어디서나 활성화하려면 HarnessInspectorView 레벨의 hidden Button 사용.
//
// 정의된 단축키:
//   ⌘.   — E-Stop 비상 정지 (IntentDispatcher.fireEmergencyStop() SSoT 경유)
//   Space — Live tail pause/resume (telemetry 수신 유지, UI 갱신 freeze)
//   ⌘B   — 사용자 북마크 추가
//   ⌘F   — 검색창 포커스

/// Harness 화면의 키보드 단축키 명세 (단일 SSoT).
/// 새 단축키 추가 시 여기에만 추가하고 각 뷰의 binding site 를 업데이트.
enum HarnessShortcuts {
    /// E-Stop 비상 정지 — 화면 어디서나 발동.
    static let eStop = KeyboardShortcut(".", modifiers: .command)

    /// Live tail pause / resume.
    static let pauseResume = KeyboardShortcut(.space, modifiers: [])

    /// 사용자 북마크 삽입.
    static let bookmark = KeyboardShortcut("b", modifiers: .command)

    /// 검색창 포커스.
    static let focusSearch = KeyboardShortcut("f", modifiers: .command)
}
