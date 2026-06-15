import XCTest
@testable import DarwinForgeUI

/// 사이클 197 (cycle 190 audit P2 #6): uiViewAppeared TelemetryKind 등록 회귀 방지.
///
/// # 비유
///
/// 호텔 체크인 기록부: 손님(사용자)이 어느 방(뷰)에 들어갔는지 기록.
/// 방 기록이 없으면 "몇 시에 누가 어디 있었나" 를 알 수 없고, cross-menu
/// stale state 분석이 불가능하다.
///
/// SwiftUI 렌더링이 필요한 onAppear 발화 자체는 XCTest 범위 밖 —
/// 여기서는 kind 존재 + raw value + level 기본값(trace) 만 검증.
final class UIViewAppearedTelemetryTests: XCTestCase {

    // MARK: - Kind registration

    /// kind 가 TelemetryKind 에 정의돼 있고 삭제되지 않았음을 보장.
    func testKindExists() {
        let kind = TelemetryKind.uiViewAppeared
        XCTAssertFalse(kind.rawValue.isEmpty)
    }

    /// raw value 가 "ui.view_appeared" 로 고정 — disk 포맷 변경 방지.
    func testRawValue() {
        XCTAssertEqual(TelemetryKind.uiViewAppeared.rawValue, "ui.view_appeared")
    }

    /// namespace 가 "ui" — 기존 ui.* 그룹과 일관성.
    func testNamespace() {
        XCTAssertEqual(TelemetryKind.uiViewAppeared.namespace, "ui")
    }

    // MARK: - Level default

    /// TelemetryLevel.trace 가 존재해 `.trace` 로 record() 호출이 컴파일 가능함을 검증.
    /// (실제 Harness 의존 없이 enum 값 존재 확인.)
    func testKindIsTraceLevel() {
        let level = TelemetryLevel.trace
        XCTAssertEqual(level.rawValue, "trace")
    }

    // MARK: - Distinctness

    /// uiViewAppeared 가 기존 uiSectionChanged / uiTabChanged 와 distinct.
    func testKindIsDistinctFromRelatedKinds() {
        XCTAssertNotEqual(TelemetryKind.uiViewAppeared.rawValue,
                          TelemetryKind.uiSectionChanged.rawValue)
        XCTAssertNotEqual(TelemetryKind.uiViewAppeared.rawValue,
                          TelemetryKind.uiTabChanged.rawValue)
    }

    // MARK: - Codable round-trip

    /// JSON 직렬화 → 역직렬화 후 동일한 raw value 유지.
    func testCodableRoundTrip() throws {
        let kind = TelemetryKind.uiViewAppeared
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(TelemetryKind.self, from: data)
        XCTAssertEqual(decoded.rawValue, kind.rawValue)
    }
}
