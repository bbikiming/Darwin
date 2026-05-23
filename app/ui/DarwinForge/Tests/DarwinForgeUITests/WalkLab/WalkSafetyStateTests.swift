import XCTest
@testable import DarwinForgeUI

/// 사이클 V262-1 (Wave 4.1.2) — `WalkSafetyState` value struct 회귀 가드.
///
/// 책임:
/// - WalkLabSession 의 safety state 5개 default 가 안전 baseline (balanceState=.normal,
///   timeline/events=[], failure/reason=nil) 보존.
/// - Equatable / Codable / Sendable + value semantics (mutation = 새 struct 할당).
/// - WalkLabSession 의 backward-compat computed property delegate 정상 작동.
///
/// 회귀 위험 LOW — pure data, hardware 무관. ADR-002 Phase 4.1.2.
@MainActor
final class WalkSafetyStateTests: XCTestCase {

    // MARK: - 1. Initial state — 안전 baseline 보존

    /// `WalkSafetyState.initial` 이 안전 baseline 으로 초기화 되어야 한다:
    /// - balanceState = .normal (안정 자세)
    /// - safetyTimeline / safetyEvents = [] (빈 상태)
    /// - lastPreflightFailure / startBlockedReason = nil (preflight 미시도)
    /// 이 default 들은 5개 safety property 의 안전 baseline — preset 미선택 시
    /// dashboard 가 "정상" 으로 보이는 invariant.
    func testInitialIsHealthy() {
        let s = WalkSafetyState.initial

        // 자세 안정성 — .normal (안전 baseline).
        XCTAssertEqual(s.balanceState, .normal, "initial balanceState=.normal (안전)")

        // 시계열 + 이벤트 — 빈 상태.
        XCTAssertTrue(s.safetyTimeline.isEmpty, "initial safetyTimeline=[] (수집 전)")
        XCTAssertTrue(s.safetyEvents.isEmpty, "initial safetyEvents=[] (이벤트 없음)")

        // preflight — 미시도 / 통과.
        XCTAssertNil(s.lastPreflightFailure, "initial lastPreflightFailure=nil")
        XCTAssertNil(s.startBlockedReason, "initial startBlockedReason=nil")

        // Default init 도 동일.
        XCTAssertEqual(WalkSafetyState(), WalkSafetyState.initial,
                       "WalkSafetyState() 와 .initial 동등")
    }

    // MARK: - 2. Equatable — 같은 값 = 같은 struct

    func testEquatableSameValues() {
        let a = WalkSafetyState()
        let b = WalkSafetyState()
        XCTAssertEqual(a, b, "동일 default 인 두 인스턴스는 Equatable=true")

        var c = WalkSafetyState()
        c.balanceState = .danger
        XCTAssertNotEqual(a, c, "한 필드만 달라도 Equatable=false")

        var d = WalkSafetyState()
        d.balanceState = .danger
        XCTAssertEqual(c, d, "같은 mutation 후 동일 = Equatable=true")
    }

    // MARK: - 3. Codable — preset save/load round-trip

    /// 모든 5개 필드 — BalanceState (Int rawValue), SafetySample (Date/Double),
    /// SafetyEvent (UUID/Date/Kind/String), WalkPreflightFailure (Cause enum),
    /// String? — 가 Codable round-trip 보존.
    func testCodableRoundTrip() throws {
        var original = WalkSafetyState()
        original.balanceState = .warning
        original.safetyTimeline = [
            WalkLabSession.SafetySample(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                rollDeg: 3.5,
                pitchDeg: -2.1,
                predictionScore: 0.42,
                balanceState: .warning,
                correctorMaxDelta: 1.2
            )
        ]
        original.safetyEvents = [
            WalkLabSession.SafetyEvent(
                timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                kind: .stateChange,
                message: "normal→warning"
            )
        ]
        original.lastPreflightFailure = WalkLabSession.WalkPreflightFailure(
            cause: .cradleNotConfirmed
        )
        original.startBlockedReason = "cradleNotConfirmed"

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WalkSafetyState.self, from: data)

        // SafetyEvent 의 id (UUID) 는 매번 새로 생성되므로 strict 비교 대신
        // 핵심 field 비교.
        XCTAssertEqual(decoded.balanceState, original.balanceState)
        XCTAssertEqual(decoded.safetyTimeline, original.safetyTimeline)
        XCTAssertEqual(decoded.safetyEvents.count, original.safetyEvents.count)
        XCTAssertEqual(decoded.safetyEvents.first?.kind, original.safetyEvents.first?.kind)
        XCTAssertEqual(decoded.safetyEvents.first?.message, original.safetyEvents.first?.message)
        XCTAssertEqual(decoded.lastPreflightFailure, original.lastPreflightFailure)
        XCTAssertEqual(decoded.startBlockedReason, original.startBlockedReason)
    }

    // MARK: - 4. Value semantics — mutation 시 새 struct 할당

    /// struct (value type) 의 핵심 invariant: 한 인스턴스 변경이 다른 인스턴스에
    /// 영향 없음. Sendable + 불변성 보장.
    func testMutationCreatesNewStruct() {
        let original = WalkSafetyState()
        var mutated = original
        mutated.balanceState = .danger
        mutated.startBlockedReason = "imuUnavailable"

        XCTAssertEqual(original.balanceState, .normal, "원본은 변경 안 됨 (value semantics)")
        XCTAssertNil(original.startBlockedReason, "원본은 변경 안 됨")
        XCTAssertEqual(mutated.balanceState, .danger, "복사본만 변경됨")
        XCTAssertEqual(mutated.startBlockedReason, "imuUnavailable", "복사본만 변경됨")
    }

    // MARK: - 5. Backward-compat delegate — session.balanceState = X → safetyState.balanceState == X

    /// WalkLabSession 의 4개 setter 가 backward-compat 을 위해 computed delegate
    /// (get/set) 으로 transparent forwarding. 외부 caller (View / Test / extension)
    /// 가 `session.balanceState = .danger` 했을 때 내부 `safetyState.balanceState`
    /// 가 .danger 로 갱신되는지 검증.
    ///
    /// (safetyEvents 는 `public private(set)` 의미 보존 — get-only computed,
    /// `WalkLabSession.swift` body 내부의 `logSafetyEvent` 가 `safetyState.safetyEvents`
    /// 에 직접 mutate. 외부 set 자체가 컴파일 안 되므로 본 test 에서 제외.)
    func testBackwardCompatDelegate() {
        let session = WalkLabSession()

        // 4개 settable property 를 통해 set → safetyState 에 반영 확인.
        session.balanceState = .danger
        session.safetyTimeline = [
            WalkLabSession.SafetySample(
                timestamp: Date(),
                rollDeg: 10, pitchDeg: 5,
                predictionScore: 0.5,
                balanceState: .danger,
                correctorMaxDelta: 0
            )
        ]
        session.lastPreflightFailure = WalkLabSession.WalkPreflightFailure(
            cause: .cradleNotConfirmed
        )
        session.startBlockedReason = "cradleNotConfirmed"

        // get 측: session 의 property 도 safetyState 값과 동일.
        XCTAssertEqual(session.safetyState.balanceState, .danger)
        XCTAssertEqual(session.safetyState.safetyTimeline.count, 1)
        XCTAssertEqual(session.safetyState.lastPreflightFailure?.cause,
                       .cradleNotConfirmed)
        XCTAssertEqual(session.safetyState.startBlockedReason, "cradleNotConfirmed")

        // 역방향: safetyState 직접 mutate → session.balanceState get 도 같이 갱신.
        session.safetyState.balanceState = .emergency
        XCTAssertEqual(session.balanceState, .emergency,
                       "safetyState mutation → session getter 반영")
        session.safetyState.startBlockedReason = nil
        XCTAssertNil(session.startBlockedReason,
                     "safetyState mutation → session getter 반영")

        // safetyEvents 는 get-only — internal mutation 만 (logSafetyEvent 통해).
        // 본 test 는 read-only 검증.
        XCTAssertEqual(session.safetyEvents.count, session.safetyState.safetyEvents.count,
                       "safetyEvents getter 가 safetyState 위임")
    }
}
