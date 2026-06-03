import Foundation

/// 하드웨어 무관 컨트롤러 입력 소스.
///
/// GCController(`GCControllerSource`) / IOKit HID 폴백 / 테스트용 `MockControllerSource`
/// 모두 이 프로토콜을 만족 → 드라이버는 구현체를 모른 채 `capture()` 만 호출한다(INPUT-01).
///
/// `@MainActor` — GCController 가 main-actor 의존이고 드라이버도 30Hz main poll 이라
/// 전 구현을 main 으로 통일한다.
@MainActor
public protocol CockpitControllerSource: AnyObject {

    /// 장치 식별 키 (프로파일 `deviceKey` 와 매칭, 예: "gc.xbox", "mock"). 미연결 시 nil.
    var deviceKey: String? { get }

    /// 사용자 표시 모델명 (예: "Xbox Wireless Controller"). 미연결 시 nil.
    var displayName: String? { get }

    /// 현재 연결 상태.
    var isConnected: Bool { get }

    /// 연결/해제 변화 콜백 — 드라이버가 HUD 갱신·failsafe(M3) 트리거에 사용.
    var onConnectionChange: (@MainActor (Bool) -> Void)? { get set }

    /// lifecycle 시작 — 연결 감시 구독 등.
    func start()

    /// lifecycle 종료 — 구독 해제·리소스 정리.
    func stop()

    /// 현재 프레임의 정규화 스냅샷. 미연결이면 nil.
    func capture() -> ControllerSnapshot?
}
