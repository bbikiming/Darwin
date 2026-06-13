import XCTest
@testable import DarwinForgeUI

/// **실기 F6 (2026-06-12)** — LAN(5530) 연결의 robot 측 버스 선점 계약 테스트.
///
/// 근거: demo 가 ttyUSB0 를 8ms 벌크리드로 점유하면 Mac boardSnapshot 응답이 탈취돼
/// LAN 연결이 "연결 중"에 무한 대기했다(실기 재현). DarwinForge 연결 시도가 최상위
/// 소유자가 되도록 robot 측 사용자를 먼저 정지 + forge-bridge 를 보장한다.
final class BusPreemptTests: XCTestCase {

    // MARK: - busPreemptTakeover 명령 계약

    func testTakeoverKillsAllKnownBusUsers() {
        let cmd = RobotSetupCommand.busPreemptTakeover
        // demo 계열 전부 — 하나라도 빠지면 그 프로세스가 bus 를 계속 점유한다.
        for proc in ["demo", "demo-pilot", "walk_demo", "walk_tuner",
                     "action_editor", "ball_follower", "vision_demo"] {
            XCTAssertTrue(cmd.contains(proc), "killall 목록에 \(proc) 누락")
        }
        // NOPASSWD 화이트리스트 경유 — 대화형 비번 프롬프트 금지(-n).
        XCTAssertTrue(cmd.contains("sudo -n killall"))
    }

    func testTakeoverEnsuresForgeBridgeViaServiceWhitelist() {
        let cmd = RobotSetupCommand.busPreemptTakeover
        // socat 은 /etc/init.d/forge-bridge — service 는 sudoers NOPASSWD 화이트리스트.
        XCTAssertTrue(cmd.contains("service forge-bridge start"))
        XCTAssertTrue(cmd.contains("socat.*5530"))
    }

    func testTakeoverEmitsAllVerdictMarkers() {
        let cmd = RobotSetupCommand.busPreemptTakeover
        XCTAssertTrue(cmd.contains("DF_BUS_PREEMPT=ok"))
        XCTAssertTrue(cmd.contains("DF_BUS_PREEMPT=busy_process_alive"))
        XCTAssertTrue(cmd.contains("DF_BUS_PREEMPT=bridge_down"))
    }

    // MARK: - parseBusPreempt

    func testParseOk() {
        let out = "▶ DarwinForge bus 선점 — 로봇측 버스 사용자 정지\nDF_BUS_PREEMPT=ok\n"
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt(out), .ok)
    }

    func testParseBusyProcessAlive() {
        let out = "▶ ...\nDF_BUS_PREEMPT=busy_process_alive\n"
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt(out), .busyProcessAlive)
    }

    func testParseBridgeDown() {
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt("DF_BUS_PREEMPT=bridge_down"),
                       .bridgeDown)
    }

    func testParseLastMarkerWins() {
        // 재시도 스크립트가 마커를 두 번 찍어도 마지막 상태가 정답.
        let out = "DF_BUS_PREEMPT=bridge_down\nDF_BUS_PREEMPT=ok\n"
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt(out), .ok)
    }

    func testParseUnknownOnGarbage() {
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt(""), .unknown)
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt("no markers here"), .unknown)
        XCTAssertEqual(RobotSetupCommand.parseBusPreempt("DF_BUS_PREEMPT=???"), .unknown)
    }

    // MARK: - walkLabClearEstop (실기 F1 — 거짓 CLEARED 차단)

    func testClearEstopOnlyReportsClearedWhenFlagActuallyGone() {
        let cmd = RobotSetupCommand.walkLabClearEstop
        // rm 후 존재 확인이 있어야 한다 — 무조건 CLEARED 는 F1 재발.
        XCTAssertTrue(cmd.contains("[ ! -f /tmp/df-walklab-estop ]"))
        XCTAssertTrue(cmd.contains("CLEAR_FAIL"))
    }
}
