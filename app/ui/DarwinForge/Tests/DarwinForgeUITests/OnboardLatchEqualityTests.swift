import XCTest
@testable import DarwinForgeUI

// MARK: - OnboardLatchEqualityTests (A4)
//
// **A4 — 텔레메트리 @Published 변경 게이팅의 핵심 불변식**
//
// `OnboardLatchSnapshot` 은 매 TEL2 샘플마다 `at: Date` 가 항상 새로워진다. 합성(synthesized)
// Equatable 을 쓰면 값이 동일해도 매번 != → @Published `onboardLatch` 가 끝없이 churn → SwiftUI
// onChange / overlay 가 불필요하게 재발화(레이턴시 낭비). 그래서 `==` 를 손으로 작성해 `at` 을
// **제외**하고 나머지 값 필드 전부를 비교한다.
//
// 두 가지를 동시에 못박는다:
//   1) **Date 제외**: 값이 같고 시각만 다른 두 스냅샷은 == (게이트가 발화 안 함).
//   2) **과소-붕괴 금지(no over-collapse)**: 값 필드 중 *어느 하나라도* 다르면 != (게이트가
//      반드시 발화 — 실제 래치 변화를 삼키면 화면이 옛 값에 고착).
//
// `at` 을 제외하려고 손으로 `==` 를 쓰되, 저장 프로퍼티 `at` 과 그 initializer 는 그대로 둔다
// (staleness 시계는 ConnectionStore 의 lastOnboardFreshAt 가 별도로 관리 — snapshot identity 와
// 무관). 이 테스트가 그 계약을 강제한다.

final class OnboardLatchEqualityTests: XCTestCase {

    // 모든 값 필드가 채워진 기준 스냅샷. 각 테스트가 한 필드씩 비틀어 != 를 확인한다.
    private func base(at date: Date) -> OnboardLatchSnapshot {
        OnboardLatchSnapshot(
            phase: 2,
            seqApplied: 4242,
            strideMm: 30.0,
            sideMm: -5.0,
            turnDeg: 12.5,
            periodMs: 600.0,
            activeSource: "udp",
            at: date)
    }

    // MARK: - 1. Date 제외 (gate 발화 X)

    func testTwoEqualValueSnapshotsAtDifferentTimesAreEqual() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)   // 1000초 차이 — 값은 동일.
        let a = base(at: t0)
        let b = base(at: t1)
        XCTAssertEqual(a, b,
            "값이 같고 at(Date)만 다른 두 스냅샷은 == 이어야 함 (게이트가 churn 안 함).")
    }

    // MARK: - 2. 과소-붕괴 금지 — 각 값 필드를 하나씩 비틀어 != 확인

    private let fixedDate = Date(timeIntervalSince1970: 5_000)

    func testDifferingPhaseIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 3, seqApplied: 4242, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 600.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "phase 변화는 != 여야 함.")
    }

    func testDifferingPhaseNilVsValueIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: nil, seqApplied: 4242, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 600.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "phase nil vs 값 차이는 != 여야 함.")
    }

    func testDifferingSeqAppliedIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 9999, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 600.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "seqApplied 변화는 != 여야 함.")
    }

    func testDifferingStrideMmIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 4242, strideMm: 31.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 600.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "strideMm 변화는 != 여야 함.")
    }

    func testDifferingSideMmIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 4242, strideMm: 30.0,
            sideMm: -6.0, turnDeg: 12.5, periodMs: 600.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "sideMm 변화는 != 여야 함.")
    }

    func testDifferingTurnDegIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 4242, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 13.5, periodMs: 600.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "turnDeg 변화는 != 여야 함.")
    }

    func testDifferingPeriodMsIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 4242, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 700.0, activeSource: "udp", at: fixedDate)
        XCTAssertNotEqual(a, b, "periodMs 변화는 != 여야 함.")
    }

    func testDifferingActiveSourceIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 4242, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 600.0, activeSource: "file", at: fixedDate)
        XCTAssertNotEqual(a, b, "activeSource 변화는 != 여야 함.")
    }

    func testDifferingActiveSourceNilVsValueIsNotEqual() {
        let a = base(at: fixedDate)
        let b = OnboardLatchSnapshot(phase: 2, seqApplied: 4242, strideMm: 30.0,
            sideMm: -5.0, turnDeg: 12.5, periodMs: 600.0, activeSource: nil, at: fixedDate)
        XCTAssertNotEqual(a, b, "activeSource nil vs 값 차이는 != 여야 함.")
    }

    // MARK: - 3. 동일 값 + 동일 시각 == (자기 일관성 sanity)

    func testIdenticalSnapshotsAreEqual() {
        let a = base(at: fixedDate)
        let b = base(at: fixedDate)
        XCTAssertEqual(a, b)
    }

    // MARK: - 4. ConnectionStore 레벨 — 동일 래치값 + 다른 ts → onboardLatch identity 미churn
    //
    // 두 TEL2 샘플을 ingest: ts 만 전진하고 래치값은 동일. 게이트가 동작하면 두 번째 ingest 후에도
    // `onboardLatch` 가 첫 샘플과 == (값 동일이므로). 게이트가 없으면 at 갱신으로 != 가 되어
    // SwiftUI 가 churn 했을 것 — 그 churn 을 코드 차원에서 방지함을 증명한다.
    // (UserDefaults 미기록 테스트 — ConnectionStore() 직접 사용, suite 불필요.)

    @MainActor
    func testIngestTwoIdenticalLatchSamplesDoesNotChurnOnboardLatchIdentity() {
        let store = ConnectionStore()

        // TEL2 라인 두 줄 — ts(2번째 토큰)만 다르고 래치(seq/phase/x/y/a/period)는 동일.
        // 형식: TEL2 ts seq phase x y a period gx gy gz ax ay az - - fallen risk vdV src loop
        let line1 = "TEL2 1000 7 2 30.0 -5.0 12.5 600.0 512 512 512 512 512 512 - - 0 - 122 udp 18"
        let line2 = "TEL2 2000 7 2 30.0 -5.0 12.5 600.0 512 512 512 512 512 512 - - 0 - 122 udp 18"

        guard let s1 = OnboardTelemetry.parse(line1),
              let s2 = OnboardTelemetry.parse(line2) else {
            return XCTFail("TEL2 fixture 파싱 실패 — 테스트 입력 형식 확인.")
        }
        XCTAssertTrue(s1.isTel2 && s2.isTel2, "두 샘플 모두 TEL2 여야 함.")

        // 첫 샘플은 anchor (live 아님) — ingest 한 번 더 필요. 세 번 ingest 로 두 live 샘플.
        store.ingestOnboardTelemetry(s1)   // anchor only (lastOnboardFreshTsMs nil → 기준점).
        let anchorLatch = store.onboardLatch  // anchor 단계에선 latch 미설정(early return).

        store.ingestOnboardTelemetry(s2)   // ts 전진 → live, onboardLatch 설정됨.
        let firstLive = store.onboardLatch
        XCTAssertNotNil(firstLive, "live 샘플 ingest 후 onboardLatch 가 설정돼야 함.")

        // 동일 래치값의 또 다른 live 샘플 (ts 만 더 전진).
        let line3 = "TEL2 3000 7 2 30.0 -5.0 12.5 600.0 512 512 512 512 512 512 - - 0 - 122 udp 18"
        guard let s3 = OnboardTelemetry.parse(line3) else {
            return XCTFail("TEL2 line3 파싱 실패.")
        }
        store.ingestOnboardTelemetry(s3)
        let secondLive = store.onboardLatch

        XCTAssertEqual(firstLive, secondLive,
            "래치값 동일·ts만 전진한 두 live 샘플 후 onboardLatch 는 == (Date 제외 게이트). " +
            "anchor=\(String(describing: anchorLatch))")
    }
}
