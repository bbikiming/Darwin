import Foundation

/// **2026-05-31 — 조종기(게임패드) 버튼 매핑 스냅샷 (영속 + 명확 저장)**.
///
/// # 목적
///
/// 버튼→동작 매핑은 `GamepadPilotAdapter.processButtons` 에 코드로 고정돼 있어 launch 간
/// "유지" 되지만, 사용자가 **무엇으로 저장돼 있는지 명확히 확인**할 길이 없었다. 본 타입은
/// 그 매핑을 단일 출처(canonical)로 문서화하고, UserDefaults 에 JSON 으로 영속 + harness 에
/// 1회 로깅한다. (감도 `PilotPreferences` 와 함께 한 번에 기록.)
///
/// # 주의
///
/// 본 스냅샷은 `processButtons` 의 실제 동작을 **거울처럼 반영**한다. 매핑 코드를 바꾸면 이
/// 표도 함께 갱신해야 한다(테스트 `GamepadButtonMappingTests` 가 불일치를 잡는다).
public struct GamepadButtonMapping: Codable, Equatable, Sendable {
    /// 버튼 식별자 → 동작 설명. 순서 보존 위해 배열 of pair.
    public struct Binding: Codable, Equatable, Sendable {
        public let button: String
        public let action: String
        public init(button: String, action: String) {
            self.button = button
            self.action = action
        }
    }

    public let bindings: [Binding]
    public let scaleLR: Double
    public let scaleFB: Double
    public let scaleYaw: Double
    public let smoothingFactor: Double
    public let capturedAtISO: String

    public init(bindings: [Binding],
                scaleLR: Double, scaleFB: Double, scaleYaw: Double,
                smoothingFactor: Double, capturedAtISO: String) {
        self.bindings = bindings
        self.scaleLR = scaleLR
        self.scaleFB = scaleFB
        self.scaleYaw = scaleYaw
        self.smoothingFactor = smoothingFactor
        self.capturedAtISO = capturedAtISO
    }

    /// `GamepadPilotAdapter.processButtons` 의 고정 매핑을 그대로 반영한 canonical 바인딩.
    public static let canonicalBindings: [Binding] = [
        .init(button: "faceTop (△ / Y)",   action: "비상정지 (emergency)"),
        .init(button: "faceLeft (□ / X)",  action: "정지 자세 (preset idle)"),
        .init(button: "dpad ↑",            action: "preset 1: 제자리걸음 (march)"),
        .init(button: "dpad →",            action: "preset 2: 천천히 걷기 (slowWalk)"),
        .init(button: "dpad ↓",            action: "preset 3: 보통 걷기 (normalWalk)"),
        .init(button: "dpad ←",            action: "preset 4: 빠르게 걷기 (fastWalk)"),
        .init(button: "menu (START / ☰)",  action: "자동 일어나기 (recovery)"),
        .init(button: "왼쪽 스틱",          action: "이동 (전후/좌우 stride)"),
        .init(button: "오른쪽 스틱 X",       action: "회전 (yaw)")
    ]

    /// 현재 매핑 + 감도(PilotPreferences) 로 스냅샷 생성.
    public static func current(prefs: PilotPreferences,
                               nowISO: String) -> GamepadButtonMapping {
        GamepadButtonMapping(
            bindings: canonicalBindings,
            scaleLR: prefs.scaleLR,
            scaleFB: prefs.scaleFB,
            scaleYaw: prefs.scaleYaw,
            smoothingFactor: prefs.smoothingFactor,
            capturedAtISO: nowISO
        )
    }
}

/// 조종기 매핑 영속 store — UserDefaults 에 JSON 단일 blob 으로 저장(명확 확인 가능).
public final class GamepadMappingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "pilot.gamepadMapping.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> GamepadButtonMapping? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(GamepadButtonMapping.self, from: data)
    }

    public func save(_ mapping: GamepadButtonMapping) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
