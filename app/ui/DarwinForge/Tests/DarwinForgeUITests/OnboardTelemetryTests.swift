/// W2 — SSH 온보드 텔레메트리 수신(ingest) 단위 테스트.
///
/// 커버: 정상/깨진/부분/범위초과 줄 파싱, voltage unknown 처리, ForgeCore 매핑
/// (`toImuRaw`/`toBoardSnapshot`), 폴러 staleness + start/stop idempotency.
/// contract docs/ssh-parity-contract.md §A.2/§A.3/§D.1/§D.2 기준.
import ForgeCore
import XCTest

@testable import DarwinForgeUI

/// 회귀 — poller 는 SSHShell.combined 출력(TEL 라인 + "--- exit 0 ---" suffix)을 넘긴다.
/// parse 가 여러 줄 중 TEL 라인을 찾아야 한다 (종전 전체 토큰화 → count≠11 → nil →
/// telemetryMode 영원히 offline → 콕핏 "경로 없음"/SIM).
final class OnboardTelemetryCombinedOutputTests: XCTestCase {
    func testParsesTELLineFromSSHCombinedOutput() {
        let combined = "TEL 1780323015286 512 512 0 510 470 512 74 1 0\n--- exit 0 ---"
        let s = OnboardTelemetry.parse(combined)
        XCTAssertNotNil(s, "combined 출력에서 TEL 라인을 파싱해야 함")
        XCTAssertEqual(s?.gyroX, 512)
        XCTAssertEqual(s?.voltageDeciVolts, 74)
        XCTAssertTrue(s?.walking == true)
    }
    func testParsesTELLineWithLeadingStderrLines() {
        let out = "Warning: x\nTEL 1780323015286 500 500 500 500 500 500 0 0 0\n--- exit 0 ---"
        XCTAssertNotNil(OnboardTelemetry.parse(out))
    }
    func testNoTELLineReturnsNil() {
        XCTAssertNil(OnboardTelemetry.parse("no telemetry here\n--- exit 1 ---"))
    }
}

/// frozen-demo false-positive 회귀 — staleness 가 robot ts_ms 전진 기반인지.
/// 죽은 demo 가 같은 파일을 남겨 SSH cat 이 매번 성공해도, ts_ms 가 안 변하면 stale 이어야 한다.
@MainActor
final class OnboardTelemetryFreshnessTests: XCTestCase {
    private func tel(_ ts: Int64) -> OnboardTelemetry {
        OnboardTelemetry(tsMs: ts, gyroX: 512, gyroY: 512, gyroZ: 512,
                         accelX: 512, accelY: 512, accelZ: 512,
                         voltageDeciVolts: 0, walking: false, fallen: 0)
    }

    func testFrozenFromStartNeverGoesLive() {
        // 죽은 demo 가 남긴 파일 — cat 은 매번 성공하지만 ts 가 한 번도 전진 안 함 → 절대 live X.
        let p = OnboardTelemetryPoller(remoteShell: RemoteShell())
        let t0 = Date()
        p.applySample(tel(1000), at: t0)                            // 첫 샘플 = 기준점만
        p.applySample(tel(1000), at: t0.addingTimeInterval(0.5))    // 같은 ts
        p.applySample(tel(1000), at: t0.addingTimeInterval(1.0))    // 같은 ts
        XCTAssertTrue(p.isStale(now: t0), "ts 전진 0 → 항상 stale")
        XCTAssertTrue(p.isStale(now: t0.addingTimeInterval(2.0)))
        XCTAssertNil(p.lastReceivedAt, "live 확정 전 anchor 미설정")
    }

    func testLiveThenFrozenGoesStale() {
        let p = OnboardTelemetryPoller(remoteShell: RemoteShell())
        let t0 = Date()
        p.applySample(tel(1000), at: t0)                            // 기준점
        p.applySample(tel(1200), at: t0.addingTimeInterval(0.5))    // ts 전진 → live (anchor=t0+0.5)
        XCTAssertFalse(p.isStale(now: t0.addingTimeInterval(1.0)), "전진 직후 — live")
        p.applySample(tel(1200), at: t0.addingTimeInterval(1.5))    // 이후 frozen (같은 ts)
        XCTAssertTrue(p.isStale(now: t0.addingTimeInterval(2.1)),
                      "anchor t0+0.5 → +2.1 은 1.5s 초과 → stale")
    }

    func testAdvancingTsStaysFresh() {
        let p = OnboardTelemetryPoller(remoteShell: RemoteShell())
        let t0 = Date()
        p.applySample(tel(1000), at: t0)                            // 기준점
        p.applySample(tel(1200), at: t0.addingTimeInterval(1.0))    // 전진 → anchor=t0+1.0
        XCTAssertFalse(p.isStale(now: t0.addingTimeInterval(1.4)), "전진 중 — live 유지")
    }
}

final class OnboardTelemetryTests: XCTestCase {

    // contract §A.2 예시 줄.
    private let validLine = "TEL 1748736000123 511 530 498 512 489 760 122 1 0"

    // MARK: - 1. Parse — 정상 줄

    func testParseValidLine() {
        guard let t = OnboardTelemetry.parse(validLine) else {
            return XCTFail("정상 줄 파싱 실패")
        }
        XCTAssertEqual(t.tsMs, 1_748_736_000_123)
        XCTAssertEqual(t.gyroX, 511)
        XCTAssertEqual(t.gyroY, 530)
        XCTAssertEqual(t.gyroZ, 498)
        XCTAssertEqual(t.accelX, 512)
        XCTAssertEqual(t.accelY, 489)
        XCTAssertEqual(t.accelZ, 760)
        XCTAssertEqual(t.voltageDeciVolts, 122)
        XCTAssertTrue(t.walking)
        XCTAssertEqual(t.fallen, 0)
    }

    func testParseTrailingNewlineAndSpaces() {
        // 줄 끝 newline + 양끝 공백 + 토큰 사이 여러 공백 → 모두 견뎌야 함.
        let line = "  TEL  1748736000123  511 530 498 512 489 760 122 1 0  \n"
        XCTAssertNotNil(OnboardTelemetry.parse(line))
    }

    func testParseFallenNegativeAndWalkingFalse() {
        let line = "TEL 1748736000123 511 530 498 512 489 760 0 0 -1"
        guard let t = OnboardTelemetry.parse(line) else {
            return XCTFail("뒤로 넘어짐 줄 파싱 실패")
        }
        XCTAssertFalse(t.walking)
        XCTAssertEqual(t.fallen, -1)
        XCTAssertEqual(t.voltageDeciVolts, 0)
    }

    func testParseAdcBoundaryValues() {
        // 0과 1023은 유효 경계.
        let line = "TEL 1 0 1023 0 1023 0 1023 100 1 1"
        guard let t = OnboardTelemetry.parse(line) else {
            return XCTFail("경계 ADC 값 파싱 실패")
        }
        XCTAssertEqual(t.gyroX, 0)
        XCTAssertEqual(t.gyroY, 1023)
        XCTAssertEqual(t.fallen, 1)
    }

    // MARK: - 2. Parse — 거부(nil) 케이스

    func testParseGarbledReturnsNil() {
        XCTAssertNil(OnboardTelemetry.parse("garbage not telemetry at all"))
        XCTAssertNil(OnboardTelemetry.parse(""))
        XCTAssertNil(OnboardTelemetry.parse("   \n"))
    }

    func testParseWrongPrefixReturnsNil() {
        // 11 토큰이지만 prefix가 TEL이 아님.
        let line = "ACK 1748736000123 511 530 498 512 489 760 122 1 0"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParsePartialTooFewTokensReturnsNil() {
        // 10 토큰 (fallen 누락).
        let line = "TEL 1748736000123 511 530 498 512 489 760 122 1"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParseTooManyTokensReturnsNil() {
        // 12 토큰.
        let line = "TEL 1748736000123 511 530 498 512 489 760 122 1 0 999"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParseNonNumericReturnsNil() {
        let line = "TEL 1748736000123 511 NaN 498 512 489 760 122 1 0"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParseAdcOutOfRangeReturnsNil() {
        // gyroZ = 1024 > 1023.
        let high = "TEL 1748736000123 511 530 1024 512 489 760 122 1 0"
        XCTAssertNil(OnboardTelemetry.parse(high))
        // accelX = -1 < 0.
        let low = "TEL 1748736000123 511 530 498 -1 489 760 122 1 0"
        XCTAssertNil(OnboardTelemetry.parse(low))
    }

    func testParseNegativeVoltageReturnsNil() {
        let line = "TEL 1748736000123 511 530 498 512 489 760 -5 1 0"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParseInvalidWalkingFlagReturnsNil() {
        // walking01 must be 0 or 1.
        let line = "TEL 1748736000123 511 530 498 512 489 760 122 2 0"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    func testParseInvalidFallenReturnsNil() {
        // fallen must be -1/0/1.
        let line = "TEL 1748736000123 511 530 498 512 489 760 122 1 2"
        XCTAssertNil(OnboardTelemetry.parse(line))
    }

    // MARK: - 3. voltageVolts

    func testVoltageVoltsKnown() {
        let t = OnboardTelemetry.parse(validLine)!
        XCTAssertEqual(t.voltageVolts ?? -1, 12.2, accuracy: 0.001)
    }

    func testVoltageVoltsUnknownIsNil() {
        let line = "TEL 1748736000123 511 530 498 512 489 760 0 1 0"
        let t = OnboardTelemetry.parse(line)!
        XCTAssertNil(t.voltageVolts)
    }

    // MARK: - 4. ForgeCore 매핑

    func testToImuRawMapsRawAdcAndZeroAngles() {
        let t = OnboardTelemetry.parse(validLine)!
        let imu = t.toImuRaw()
        XCTAssertEqual(imu.gyroX, 511)
        XCTAssertEqual(imu.gyroY, 530)
        XCTAssertEqual(imu.gyroZ, 498)
        XCTAssertEqual(imu.accelX, 512)
        XCTAssertEqual(imu.accelY, 489)
        XCTAssertEqual(imu.accelZ, 760)
        // 온보드 보드는 자세각을 안 보냄 → 0.
        XCTAssertEqual(imu.rollDeg, 0, accuracy: 0.0001)
        XCTAssertEqual(imu.pitchDeg, 0, accuracy: 0.0001)
    }

    func testToBoardSnapshotKnownVoltage() {
        let t = OnboardTelemetry.parse(validLine)!
        guard let board = t.toBoardSnapshot() else {
            return XCTFail("전압 known 인데 board nil")
        }
        XCTAssertEqual(board.modelNumber, 740)
        XCTAssertEqual(board.version, 0)
        XCTAssertEqual(board.voltageRaw, 122)
        XCTAssertEqual(board.button, 0)
        XCTAssertEqual(board.voltageVolts, 12.2, accuracy: 0.001)
    }

    func testToBoardSnapshotUnknownVoltageIsNil() {
        // contract §D.3: 전압 unknown → nil (마지막 board 유지하라는 신호).
        let line = "TEL 1748736000123 511 530 498 512 489 760 0 1 0"
        let t = OnboardTelemetry.parse(line)!
        XCTAssertNil(t.toBoardSnapshot())
    }

    func testToBoardSnapshotClampsHighVoltage() {
        // deci-volts 300 (>255) → UInt8 clamp 255. (비정상이지만 crash 금지.)
        let line = "TEL 1748736000123 511 530 498 512 489 760 300 1 0"
        let t = OnboardTelemetry.parse(line)!
        XCTAssertEqual(t.toBoardSnapshot()?.voltageRaw, 255)
    }

    // MARK: - 5. Equatable

    func testEquatable() {
        let a = OnboardTelemetry.parse(validLine)
        let b = OnboardTelemetry.parse(validLine)
        XCTAssertEqual(a, b)
    }

    // MARK: - 6. Poller — staleness + 수명주기

    @MainActor
    func testFreshPollerIsStaleWithNoSample() {
        let poller = OnboardTelemetryPoller(remoteShell: RemoteShell())
        // 한 번도 못 받았으면 stale.
        XCTAssertTrue(poller.isStale)
        XCTAssertNil(poller.latest)
        XCTAssertNil(poller.lastReceivedAt)
        XCTAssertEqual(poller.consecutiveFailures, 0)
    }

    @MainActor
    func testStaleThresholdMath() {
        let poller = OnboardTelemetryPoller(remoteShell: RemoteShell())
        // lastReceivedAt 없음 → 어떤 기준시각이든 stale.
        let now = Date()
        XCTAssertTrue(poller.isStale(now: now))
        XCTAssertTrue(poller.isStale(now: now.addingTimeInterval(10)))
    }

    @MainActor
    func testStartStopIdempotent() {
        let poller = OnboardTelemetryPoller(remoteShell: RemoteShell())
        // start 두 번 — crash/중복 task 없이 no-op 이어야 함.
        poller.start { _ in }
        poller.start { _ in }
        poller.stop()
        // stop 두 번도 안전.
        poller.stop()
        XCTAssertTrue(poller.isStale)
    }
}
