import Foundation

/// 통합 「컨트롤러 연결」 시트가 다루는 입력 장치 종류.
///
/// 기존 두 매핑 시트 — 게임패드(`CockpitControllerSettingsSheet`,
/// `ControllerBindingProfile`) 와 DJI RC(`CockpitDJIBindingSheet`,
/// `DJIBindingProfile`) — 를 **하나의 시트에서 세그먼트로 전환**하기 위한 식별자다.
///
/// 데이터 모델·저장값은 장치별로 분리 유지하고(둘을 합치지 않는다), 본 enum 은
/// 두 가지만 결정한다:
/// 1. 어떤 매핑 pane 을 보여줄지 (게임패드 다이어그램 ↔ DJI 조종기 비주얼)
/// 2. 헤더의 연결 상태를 어느 소스에서 읽을지 (GCController ↔ DJI HID watcher)
///
/// 비유: 멀티탭 콘센트의 "어느 코드를 꽂을지" 선택 스위치. 코드(프로파일)는 각자
/// 그대로 있고, 스위치만 어느 쪽을 화면에 비출지 고른다.
public enum ControllerDeviceKind: String, CaseIterable, Identifiable, Sendable {
    case gamepad
    case djiRC

    public var id: String { rawValue }

    /// 세그먼트 라벨 (한국어).
    public var label: String {
        switch self {
        case .gamepad: return "게임패드"
        case .djiRC:   return "DJI RC"
        }
    }

    /// 세그먼트/헤더 아이콘 (SF Symbol).
    public var systemImage: String {
        switch self {
        case .gamepad: return "gamecontroller.fill"
        case .djiRC:   return "antenna.radiowaves.left.and.right"
        }
    }

    /// 시트 진입 시 처음 보여줄 장치를 연결 상태로부터 고른다.
    ///
    /// DJI RC 가 연결돼 있으면 그쪽을 — 실 RC 를 꽂아 둔 건 명시적 의도라고 본다 —
    /// 아니면 게임패드를 기본으로 한다. 게임패드 pane 은 가상 패드 폴백이 있어
    /// 아무것도 연결되지 않은 상태에서도 의미 있는 기본값이다.
    public static func autoSelect(djiConnected: Bool,
                                  gamepadConnected: Bool) -> ControllerDeviceKind {
        if djiConnected { return .djiRC }
        if gamepadConnected { return .gamepad }
        return .gamepad
    }
}
