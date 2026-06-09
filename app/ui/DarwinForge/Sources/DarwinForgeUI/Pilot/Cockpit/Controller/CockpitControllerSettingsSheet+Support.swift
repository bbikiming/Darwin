import SwiftUI

/// `CockpitControllerSettingsSheet` 의 상태 없는 지원 타입/헬퍼 모음 — 파일 크기 분리.
extension CockpitControllerSettingsSheet {

    // MARK: - 지원 enum

    enum ActionFilter: String, CaseIterable, Identifiable {
        case all = "전체", mapped = "매핑됨", unmapped = "미설정", conflict = "충돌", safety = "안전"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .mapped: return "checkmark.circle"
            case .unmapped: return "circle.dashed"
            case .conflict: return "exclamationmark.triangle"
            case .safety: return "exclamationmark.octagon"
            }
        }
    }

    public enum ViewMode: String, CaseIterable, Identifiable {
        case device = "장치", list = "목록", tester = "테스트"
        public var id: String { rawValue }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case xbox = "Xbox / RG G01", dualSense = "DualSense", empty = "비어 있음"
        var id: String { rawValue }
        var profile: ControllerBindingProfile {
            switch self {
            case .xbox: return .xbox
            case .dualSense: return .dualSense
            case .empty: return .empty
            }
        }
    }

    enum CurvePreset: String, CaseIterable, Identifiable {
        case linear = "선형", smooth = "부드러움", precise = "정밀"
        var id: String { rawValue }
        var expo: Double { self == .linear ? 0.0 : (self == .smooth ? 0.5 : 0.85) }
    }

    enum ActivatorPreset: String, CaseIterable, Identifiable {
        case hold = "홀드", start = "누름", toggle = "토글", longPress = "길게"
        var id: String { rawValue }
        var type: ActivatorType {
            switch self {
            case .hold: return .hold
            case .start: return .start
            case .toggle: return .toggle
            case .longPress: return .longPress(thresholdMs: 500)
            }
        }
    }

    // MARK: - 표시 헬퍼 (상태 없음)

    func groupTitle(_ g: CockpitAction.Group) -> String {
        switch g {
        case .movement: return "이동 제어"
        case .rotation: return "회전 제어"
        case .head: return "머리 제어"
        case .safety: return "안전 제어"
        }
    }

    func actions(in group: CockpitAction.Group) -> [CockpitAction] {
        CockpitAction.allCases.filter { $0.group == group }
    }

    func actionIcon(_ a: CockpitAction) -> String {
        switch a {
        case .moveForward: return "arrow.up"
        case .moveBackward: return "arrow.down"
        case .strafeLeft: return "arrow.left"
        case .strafeRight: return "arrow.right"
        case .turnLeft: return "arrow.counterclockwise"
        case .turnRight: return "arrow.clockwise"
        case .headPanLeft: return "arrowshape.left"
        case .headPanRight: return "arrowshape.right"
        case .headTiltUp: return "arrowshape.up"
        case .headTiltDown: return "arrowshape.down"
        case .ballTracking: return "scope"
        case .emergencyStop: return "exclamationmark.octagon.fill"
        case .recover: return "arrow.uturn.up"
        }
    }

    func conflictSummary(_ conflicts: [ControllerBindingConflict]) -> String {
        conflicts.map { c in
            switch c {
            case .duplicateInput(let b, let acts):
                return "중복 \(b.displayLabel): \(acts.map(\.label).joined(separator: ", "))"
            case .safetyCriticalUnbound(let a):
                return "안전 미할당: \(a.label)"
            }
        }.joined(separator: "\n")
    }
}
