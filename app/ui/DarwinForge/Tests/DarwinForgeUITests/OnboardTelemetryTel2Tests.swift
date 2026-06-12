import XCTest
@testable import DarwinForgeUI

/// **O4 (2026-06-12, walklab-onboard-teleop-upgrade Wave O4)** — TEL2(v2) 파서 분기 +
/// J6 적응형 폴러 단위 테스트. 펌웨어 FormatTel2 가 내보내는 정확한 바이트열을 라운드트립으로
/// 검증한다(계약 §A.2 TEL2). v1 라인은 기존 경로 그대로(prefix 분기) — 회귀 가드.
final class OnboardTelemetryTel2Tests: XCTestCase {

    // 펌웨어 test_format_tel2_full 과 동일 바이트열(계약 동기).
    private let tel2Full =
        "TEL2 1748736000123 42 2 28.00 10.00 5.00 600.00 " +
        "511 530 498 512 489 760 100 110 120 130 140 150 160 170 20 -5 0 - 122 udp 18"

    func testParse_tel2_full_allFields() {
        let s = OnboardTelemetry.parse(tel2Full)
        XCTAssertNotNil(s)
        XCTAssertTrue(s?.isTel2 == true)
        XCTAssertEqual(s?.tsMs, 1748736000123)
        XCTAssertEqual(s?.seqApplied, 42)
        XCTAssertEqual(s?.phase, 2)
        XCTAssertEqual(s?.latStrideMm, 28.0)
        XCTAssertEqual(s?.latSideMm, 10.0)
        XCTAssertEqual(s?.latTurnDeg, 5.0)
        XCTAssertEqual(s?.latPeriodMs, 600.0)
        XCTAssertEqual(s?.gyroX, 511)
        XCTAssertEqual(s?.accelZ, 760)
        XCTAssertEqual(s?.fsrLeftCells, [100, 110, 120, 130])
        XCTAssertEqual(s?.fsrRightCells, [140, 150, 160, 170])
        XCTAssertEqual(s?.copX, 20)
        XCTAssertEqual(s?.copY, -5)
        XCTAssertEqual(s?.fallen, 0)
        XCTAssertNil(s?.riskDeg)                 // "-" → nil (O3 미구현).
        XCTAssertEqual(s?.voltageDeciVolts, 122)
        XCTAssertEqual(s?.activeSource, "udp")
        XCTAssertEqual(s?.loopMs, 18)
    }

    func testParse_tel2_fsrAndCopMissing_dashFallback() {
        // 펌웨어 test_format_tel2_fsr_missing 과 동일.
        let line = "TEL2 1000 7 0 0.00 0.00 0.00 600.00 512 512 512 512 512 700 - - -1 - 0 file 5"
        let s = OnboardTelemetry.parse(line)
        XCTAssertNotNil(s)
        XCTAssertTrue(s?.isTel2 == true)
        XCTAssertNil(s?.fsrLeftCells)            // FSR "-" → nil.
        XCTAssertNil(s?.fsrRightCells)
        XCTAssertNil(s?.copX)                    // CoP "-" → nil.
        XCTAssertNil(s?.copY)
        XCTAssertEqual(s?.fallen, -1)
        XCTAssertEqual(s?.voltageDeciVolts, 0)
        XCTAssertEqual(s?.activeSource, "file")
        XCTAssertEqual(s?.loopMs, 5)
        XCTAssertEqual(s?.phase, 0)
    }

    func testParse_tel2_copPresentFsrMissing() {
        // FSR "-" 이지만 CoP 토큰이 있는 변형(가드: 그룹 독립 파싱).
        let line = "TEL2 2000 9 1 12.00 0.00 0.00 500.00 500 500 500 500 500 700 - 3 -7 0 - 118 udp 20"
        let s = OnboardTelemetry.parse(line)
        XCTAssertNotNil(s)
        XCTAssertNil(s?.fsrLeftCells)
        XCTAssertEqual(s?.copX, 3)
        XCTAssertEqual(s?.copY, -7)
        XCTAssertEqual(s?.activeSource, "udp")
    }

    func testParse_tel2_truncated_returnsNil() {
        // 후행 토큰 결손(fallen 이후 부족) → 드롭(crash 없이 nil).
        let line = "TEL2 1000 7 0 0 0 0 600 512 512 512 512 512 700 - -"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParse_tel2_badFsrCell_returnsNil() {
        // FSR 그룹이 "-" 아닌데 8셀 미만/비정수 → nil.
        let line = "TEL2 1000 7 0 0 0 0 600 512 512 512 512 512 700 100 110 xx 130 140 150 160 170 0 0 0 - 0 udp 5"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParse_v1_stillWorks_notTel2() {
        // prefix 분기 — v1 "TEL" 라인은 기존 경로 그대로(회귀 가드).
        let v1 = "TEL 1748736000123 511 530 498 512 489 760 122 1 0 c123_ab12cd34 18"
        let s = OnboardTelemetry.parse(v1)
        XCTAssertNotNil(s)
        XCTAssertFalse(s?.isTel2 == true)        // v1 → isTel2 false.
        XCTAssertNil(s?.phase)                   // TEL2 필드는 전부 nil.
        XCTAssertNil(s?.fsrLeftCells)
        XCTAssertEqual(s?.lastCmdId, "c123_ab12cd34")
        XCTAssertEqual(s?.loopMs, 18)
        XCTAssertTrue(s?.walking == true)
    }

    func testLatchSnapshot_phaseFraction() {
        let mk: (Int?) -> OnboardLatchSnapshot = { p in
            OnboardLatchSnapshot(phase: p, seqApplied: 1, strideMm: 0, sideMm: 0,
                                 turnDeg: 0, periodMs: 600, activeSource: "udp", at: Date())
        }
        XCTAssertEqual(mk(0).phaseFraction01, 0.0)
        XCTAssertEqual(mk(1).phaseFraction01, 0.25)
        XCTAssertEqual(mk(2).phaseFraction01, 0.5)
        XCTAssertEqual(mk(3).phaseFraction01, 0.75)
        XCTAssertNil(mk(nil).phaseFraction01)
        XCTAssertNil(mk(-1).phaseFraction01)
    }

    // **J6** — UDP 신선 시 SSH 폴 1Hz 강등, 두절 시 5Hz 복귀.
    @MainActor
    func testJ6_adaptivePollInterval() {
        let poller = OnboardTelemetryPoller(remoteShell: RemoteShell(),
                                            intervalMs: 200, relaxedIntervalMs: 1000)
        XCTAssertEqual(poller.nextIntervalMs(), 200, "provider 없음 → 5Hz(base)")
        var fresh = false
        poller.udpFreshProvider = { fresh }
        XCTAssertEqual(poller.nextIntervalMs(), 200, "UDP 두절 → 5Hz 복귀")
        fresh = true
        XCTAssertEqual(poller.nextIntervalMs(), 1000, "UDP 신선 → 1Hz 강등")
    }
}
