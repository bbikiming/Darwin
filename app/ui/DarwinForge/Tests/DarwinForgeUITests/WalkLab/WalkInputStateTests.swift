import XCTest
@testable import DarwinForgeUI

/// 사이클 261 (Wave 4.1.1) — `WalkInputState` value struct 회귀 가드.
///
/// 책임:
/// - WalkLabSession 의 UI slider 12개 default 가 안전 자세 (0/40/1.0/2/13.0/...) 보존.
/// - Equatable / Codable / Sendable + value semantics (mutation = 새 struct 할당).
/// - WalkLabSession 의 backward-compat computed property delegate 정상 작동.
///
/// 회귀 위험 LOW — pure data, hardware 무관. ADR-002 Phase 4.1.1 첫 단계.
@MainActor
final class WalkInputStateTests: XCTestCase {

    // MARK: - 1. Default 값 — 안전 자세 보존

    /// 신규 WalkInputState() 가 보행 0 (안전 정지) + 표준 footHeight/balanceGain
    /// + ROBOTIS 기본 (correctorLevel 2, hipPitchOffset 13°) 로 초기화 되어야 한다.
    /// 이 default 들은 13개 slider 의 안전 baseline — preset 미선택 시 robot 이
    /// 정지/안정 자세로 머무는 invariant.
    func testInitialDefaultsAreSafe() {
        let s = WalkInputState()

        // 보행 명령 — 0/0/0 (안전 정지).
        XCTAssertEqual(s.strideMm, 0, "default strideMm=0 (안전)")
        XCTAssertEqual(s.sideMm, 0, "default sideMm=0 (안전)")
        XCTAssertEqual(s.turnDeg, 0, "default turnDeg=0 (안전)")

        // 주기 / 발 들기 / 균형 — 표준 ROBOTIS.
        XCTAssertEqual(s.customPeriodMs, 600, "default customPeriodMs=600")
        XCTAssertEqual(s.footHeightMm, 40, "default footHeightMm=40")
        XCTAssertEqual(s.balanceGain, 1.0, "default balanceGain=1.0")

        // 자이로 보정 — level 2 (×1.0 ROBOTIS 표준).
        XCTAssertEqual(s.correctorIntensityLevel, 2, "default correctorIntensityLevel=2")

        // Hip pitch trim — ROBOTIS 원본 13°.
        XCTAssertEqual(s.hipPitchOffsetTrimDeg, 13.0, "default hipPitchOffsetTrimDeg=13.0")

        // Custom gain — robotisOriginal fallback 값.
        XCTAssertEqual(s.customHipRollGain, 0.5, "default customHipRollGain=0.5")
        XCTAssertEqual(s.customKneeGain, 0.3, "default customKneeGain=0.3")
        XCTAssertEqual(s.customAnklePitchGain, 0.9, "default customAnklePitchGain=0.9")
        XCTAssertEqual(s.customAnkleRollGain, 1.0, "default customAnkleRollGain=1.0")
    }

    // MARK: - 2. Equatable — 같은 값 = 같은 struct

    func testEquatableSameValues() {
        let a = WalkInputState()
        let b = WalkInputState()
        XCTAssertEqual(a, b, "동일 default 인 두 인스턴스는 Equatable=true")

        var c = WalkInputState()
        c.strideMm = 25
        XCTAssertNotEqual(a, c, "한 필드만 달라도 Equatable=false")

        var d = WalkInputState()
        d.strideMm = 25
        XCTAssertEqual(c, d, "같은 mutation 후 동일 = Equatable=true")
    }

    // MARK: - 3. Codable — preset save/load round-trip

    func testCodableRoundTrip() throws {
        var original = WalkInputState()
        original.strideMm = 25
        original.sideMm = -10
        original.turnDeg = 7.5
        original.customPeriodMs = 550
        original.footHeightMm = 45
        original.balanceGain = 1.5
        original.correctorIntensityLevel = 3
        original.hipPitchOffsetTrimDeg = 5.0
        original.customHipRollGain = 0.8
        original.customKneeGain = 0.4
        original.customAnklePitchGain = 1.1
        original.customAnkleRollGain = 1.2

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WalkInputState.self, from: data)

        XCTAssertEqual(original, decoded, "Codable round-trip 가 모든 필드 보존")
    }

    // MARK: - 4. Value semantics — mutation 시 새 struct 할당

    /// struct (value type) 의 핵심 invariant: 한 인스턴스 변경이 다른 인스턴스에
    /// 영향 없음. Sendable + 불변성 보장.
    func testMutationCreatesNewStruct() {
        let original = WalkInputState()
        var mutated = original
        mutated.strideMm = 30

        XCTAssertEqual(original.strideMm, 0, "원본은 변경 안 됨 (value semantics)")
        XCTAssertEqual(mutated.strideMm, 30, "복사본만 변경됨")
    }

    // MARK: - 5. Backward-compat delegate — session.strideMm = X → inputs.strideMm == X

    /// WalkLabSession 의 13개 slider property 는 backward-compat 을 위해 computed
    /// delegate (get/set) 으로 transparent forwarding. 외부 caller (View / Test /
    /// preset apply) 가 `session.strideMm = 30` 했을 때 내부 `inputs.strideMm`
    /// 가 30 으로 갱신되는지 검증.
    func testBackwardCompatDelegate() {
        let session = WalkLabSession()

        // 모든 13개 slider 를 통해 set → inputs 에 반영 확인.
        session.strideMm = 30
        session.sideMm = -12
        session.turnDeg = 8
        session.customPeriodMs = 500
        session.footHeightMm = 50
        session.balanceGain = 1.8
        session.correctorIntensityLevel = 1
        session.hipPitchOffsetTrimDeg = 5.0
        session.customHipRollGain = 0.7
        session.customKneeGain = 0.45
        session.customAnklePitchGain = 1.05
        session.customAnkleRollGain = 1.15

        // get 측: session 의 property 도 inputs 값과 동일.
        XCTAssertEqual(session.inputs.strideMm, 30)
        XCTAssertEqual(session.inputs.sideMm, -12)
        XCTAssertEqual(session.inputs.turnDeg, 8)
        XCTAssertEqual(session.inputs.customPeriodMs, 500)
        XCTAssertEqual(session.inputs.footHeightMm, 50)
        XCTAssertEqual(session.inputs.balanceGain, 1.8)
        XCTAssertEqual(session.inputs.correctorIntensityLevel, 1)
        XCTAssertEqual(session.inputs.hipPitchOffsetTrimDeg, 5.0)
        XCTAssertEqual(session.inputs.customHipRollGain, 0.7)
        XCTAssertEqual(session.inputs.customKneeGain, 0.45)
        XCTAssertEqual(session.inputs.customAnklePitchGain, 1.05)
        XCTAssertEqual(session.inputs.customAnkleRollGain, 1.15)

        // 역방향: inputs 직접 mutate → session.strideMm get 도 같이 갱신.
        session.inputs.strideMm = 42
        XCTAssertEqual(session.strideMm, 42, "inputs mutation → session getter 반영")
    }
}
