import Foundation
import Combine

/// 화면 위 가상 컨트롤러 — 하드웨어 없이 키매핑/주입을 체감하기 위한 `CockpitControllerSource`.
///
/// 온스크린 패드(`VirtualControllerPad`)가 `axes`/`buttons` 를 갱신하면 드라이버가
/// 30Hz 로 `capture()` 해 cockpit 에 주입한다. 게임패드 배송 전 데모/튜닝용.
///
/// deviceKey 를 `gc.xbox` 로 두어 Xbox/RG G01 기본 프리셋이 그대로 매칭된다.
@MainActor
public final class VirtualControllerSource: ObservableObject, CockpitControllerSource {

    /// 표준 6축 (LS X/Y, RS X/Y, LT, RT).
    @Published public var axes: [Double]
    /// 표준 14버튼.
    @Published public var buttons: [Bool]

    public var deviceKey:   String? = "gc.xbox"
    public var displayName: String? = "가상 컨트롤러"
    public private(set) var isConnected: Bool = true
    public var onConnectionChange: (@MainActor (Bool) -> Void)?

    public init() {
        axes    = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        buttons = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
    }

    /// 현재 패드 상태의 정규화 스냅샷.
    public var snapshot: ControllerSnapshot {
        ControllerSnapshot(axes: axes, buttons: buttons)
    }

    // MARK: - 패드 갱신 (불변 배열 교체)

    /// `index` 축값 설정 — 범위 밖이면 무시.
    public func setAxis(_ index: Int, _ value: Double) {
        guard index >= 0, index < axes.count else { return }
        var next = axes
        next[index] = max(-1.0, min(1.0, value))
        axes = next
    }

    /// `index` 버튼 눌림 설정 — 범위 밖이면 무시.
    public func setButton(_ index: Int, _ pressed: Bool) {
        guard index >= 0, index < buttons.count else { return }
        var next = buttons
        next[index] = pressed
        buttons = next
    }

    /// 모든 입력 중립화 — 시트 닫힘/리셋 시.
    public func resetAll() {
        axes    = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        buttons = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
    }

    /// 연결 토글 — 끊김 failsafe(M3) 데모용.
    public func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onConnectionChange?(connected)
    }

    // MARK: - CockpitControllerSource

    public func start() {}
    public func stop() { resetAll() }
    public func capture() -> ControllerSnapshot? { isConnected ? snapshot : nil }
}
