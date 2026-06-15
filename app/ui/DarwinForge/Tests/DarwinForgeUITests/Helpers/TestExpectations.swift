import Foundation
import XCTest

// MARK: - Polling wait helper

/// 조건이 true 가 될 때까지 polling 대기. timeout 초과 시 XCTFail.
///
/// 비유: 신호등이 초록불이 될 때까지 짧은 간격으로 확인 — 붉은 불일 때 무한 대기하지 않고
/// 정해진 시간 안에 포기. 조건 달성 즉시 통과 → 실제 소요 시간 최소화.
///
/// - Parameters:
///   - timeout: 최대 대기 시간 (초). 기본 2.0s.
///   - interval: polling 간격 (초). 기본 0.02s (20ms).
///   - condition: 충족 여부 반환 closure.
///   - file: 실패 위치 자동 기록.
///   - line: 실패 위치 자동 기록.
func waitUntil(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.05,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    // 먼저 run loop 에 양보 — deferred Task 가 실행될 기회 제공.
    await Task.yield()
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("waitUntil timeout (\(timeout)s) — condition not met", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
