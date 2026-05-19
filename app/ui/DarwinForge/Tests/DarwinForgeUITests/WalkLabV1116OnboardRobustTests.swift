import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.16 (2026-05-19)** — ROBOTIS Onboard 통합 robust 회귀 가드.
///
/// 검증:
/// 1. RemoteShell.send 가 Exchange? 반환 (silent failure 차단).
/// 2. WalkLabSession.setLastRobotEvent / logSafetyEvent 외부 호출 가능.
/// 3. Exchange.error / .result 분기 분명.
@MainActor
final class WalkLabV1116OnboardRobustTests: XCTestCase {

    /// **v1.11.16 fix 1**: RemoteShell.send 가 빈 명령 시 nil 반환.
    func testRemoteShellSendEmptyCommandReturnsNil() async {
        let shell = RemoteShell()
        let result = await shell.send("")
        XCTAssertNil(result, "빈 명령 — nil 반환 (no-op)")
        let result2 = await shell.send("   ")
        XCTAssertNil(result2, "whitespace only — nil 반환")
    }

    /// **v1.11.16 fix 2**: WalkLabSession 의 setLastRobotEvent 외부 호출 가능.
    func testSetLastRobotEventExternalSetter() {
        let session = WalkLabSession()
        XCTAssertNil(session.lastRobotEvent, "초기 nil")
        session.setLastRobotEvent("test event")
        XCTAssertEqual(session.lastRobotEvent, "test event")
        session.setLastRobotEvent(nil)
        XCTAssertNil(session.lastRobotEvent)
    }

    /// **v1.11.16 fix 3**: logSafetyEvent 외부 호출 가능 (private → internal).
    /// safetyEvents 에 entry 가 append 되는지 검증.
    func testLogSafetyEventExternalCall() {
        let session = WalkLabSession()
        let beforeCount = session.safetyEvents.count
        session.logSafetyEvent(kind: .correctorOff, message: "test from external")
        let afterCount = session.safetyEvents.count
        XCTAssertEqual(afterCount, beforeCount + 1, "safetyEvents += 1")
        XCTAssertEqual(session.safetyEvents.last?.message, "test from external")
    }

    /// **v1.11.16 fix 4**: Exchange 의 error 와 result 분기 검증.
    /// host="" + SMB 미사용 → SSH 시도 실패 → SMB fallback → 결국 error 채워짐.
    func testExchangeErrorBranchOnFailedHost() async throws {
        let shell = RemoteShell()
        shell.host = ""  // 빈 host — SSH 실패 + SMB mount 실패 예상.
        shell.username = "nobody"
        // 짧은 timeout 위해 일반 명령 사용. 실 환경에선 SSH 실패 → SMB 실패.
        // 본 테스트는 SSH 실패 시 SMB 도 mount 못 함 → error 채워짐 검증.
        // 다만 host="" 면 SSHShell.run 이 즉시 throw 할 가능성 — 결과 확인.
        let exchange = await shell.send("echo test")
        XCTAssertNotNil(exchange, "non-empty 명령 — exchange 반환")
        // result 가 nil 이면 error 가 채워져야 함 (성공/실패 분기 명확).
        if let ex = exchange {
            XCTAssertTrue(ex.result != nil || ex.error != nil,
                          "result 또는 error 중 하나는 set")
        }
    }

    // MARK: - v1.11.16.1 — ACK + health state + fallback

    /// **v1.11.16.1 fix**: walkLabRobotisSendCommand 가 ACK 검증 sequence 포함.
    /// 종전: 단순 write. 현재: write + sleep + ACK cat.
    func testWalkLabSendCommandIncludesAckRead() {
        let line = "1 28.00 0.00 0.00 600 40 13.00"
        let cmd = RobotSetupCommand.walkLabRobotisSendCommand(line: line)
        XCTAssertTrue(cmd.contains("/tmp/df-walklab-cmd"), "기본 write 경로")
        XCTAssertTrue(cmd.contains("sleep"), "daemon polling 대기")
        XCTAssertTrue(cmd.contains("/tmp/df-walklab-ack"), "ACK 파일 read")
        XCTAssertTrue(cmd.contains("NO_ACK"), "fallback echo (firmware 미패치 시)")
    }

    /// **v1.11.16.1 fix**: WalkLabSession 의 onboard health state 초기값.
    func testOnboardHealthStateInitial() {
        let session = WalkLabSession()
        XCTAssertNil(session.onboardLastAckAt)
        XCTAssertNil(session.onboardLastError)
        XCTAssertEqual(session.onboardConsecutiveFailures, 0)
        XCTAssertFalse(session.onboardDaemonMissing)
    }

    /// **v1.11.16.1 fix**: health state 외부 set 가능 (Bridge 가 internal 접근).
    func testOnboardHealthStateMutable() {
        let session = WalkLabSession()
        session.onboardConsecutiveFailures = 3
        session.onboardLastError = "test error"
        session.onboardDaemonMissing = true
        session.onboardLastAckAt = Date()
        XCTAssertEqual(session.onboardConsecutiveFailures, 3)
        XCTAssertEqual(session.onboardLastError, "test error")
        XCTAssertTrue(session.onboardDaemonMissing)
        XCTAssertNotNil(session.onboardLastAckAt)
    }

    /// **v1.11.16.1 fix**: UserDefaults 의 autoOnboardFallback toggle.
    func testAutoOnboardFallbackUserDefault() {
        let key = "df.walklab.autoOnboardFallback"
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key),
                       "default false — 사용자 명시 ON 만 자동 전환")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        UserDefaults.standard.removeObject(forKey: key)
    }
}
