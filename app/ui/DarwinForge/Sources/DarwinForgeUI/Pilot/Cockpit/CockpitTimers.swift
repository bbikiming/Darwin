import Foundation

/// **L3 (2026-06-11)**: `.common` 런루프 모드 반복 타이머 유틸.
///
/// `Timer.scheduledTimer(...)` 는 현재 런루프의 `.default` 모드에만 등록된다. macOS 에서
/// 메뉴 추적·라이브 리사이즈·슬라이더 드래그 등 **이벤트 트래킹** 중에는 런루프가
/// `.eventTracking` 모드로 전환돼 `.default` 타이머가 전부 멈춘다. 콕핏의 30Hz 시뮬
/// 적분·입력 폴링·게임패드 E-STOP 에지 감지가 이 순간 동결되면, 보행 중이라면 stale
/// 보행 명령이 트래킹이 끝날 때까지(수 초) 지속되는 안전 위험이 된다.
///
/// `.common` 모드로 등록하면 `.default` + `.eventTracking` 양쪽에서 발화한다.
@MainActor
enum CockpitTimers {
    /// `.common` 모드 등록 반복 타이머 — 메뉴/리사이즈 트래킹 중에도 발화한다.
    ///
    /// 콜백은 main 런루프에 등록된 `Timer` 가 main thread 에서 호출하므로
    /// `MainActor.assumeIsolated` 로 추가 Task 홉·할당 없이 `@MainActor` 격리에 진입한다.
    @discardableResult
    static func repeating(_ interval: TimeInterval,
                          _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
