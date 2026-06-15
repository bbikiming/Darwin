import XCTest
@testable import DarwinForgeUI

/// 사이클 182 (P1 #3.6 fix, cycle 177 audit): Remote SSH/SMB telemetry kind
/// regression guard.
///
/// # 비유
///
/// 우체국 의 배송 추적 — 발송 / 도착 / 분실 의 단계 마다 고유한 status 코드 가 필요.
/// 본 테스트 는 RemoteShell 의 모든 단계 가 (1) 정의 + (2) 의미 있는 `remote.` prefix
/// + (3) distinct 인지 확인.
final class RemoteTelemetryKindsTests: XCTestCase {

    /// **분류 검증 #1**: 모든 cycle 182 신규 kind 가 `remote.` prefix.
    func testNewKindsHaveRemotePrefix() {
        let kinds: [TelemetryKind] = [
            .remoteCommandSent,
            .remoteCommandResponded,
            .remoteCommandError,
            .remoteChannelChanged
        ]
        for k in kinds {
            XCTAssertTrue(k.rawValue.hasPrefix("remote."),
                          "kind=\(k.rawValue) 가 remote. prefix 없음")
        }
    }

    /// **분류 검증 #2**: 4 case 모두 distinct.
    func testAllRemoteKindsAreUnique() {
        let kinds: [TelemetryKind] = [
            .remoteCommandSent,
            .remoteCommandResponded,
            .remoteCommandError,
            .remoteChannelChanged
        ]
        let raws = Set(kinds.map { $0.rawValue })
        XCTAssertEqual(raws.count, kinds.count)
    }

    /// **분류 검증 #3**: 정확한 raw value 매칭.
    func testNewKindRawValuesMatchExpectedNames() {
        XCTAssertEqual(TelemetryKind.remoteCommandSent.rawValue, "remote.command_sent")
        XCTAssertEqual(TelemetryKind.remoteCommandResponded.rawValue, "remote.command_responded")
        XCTAssertEqual(TelemetryKind.remoteCommandError.rawValue, "remote.command_error")
        XCTAssertEqual(TelemetryKind.remoteChannelChanged.rawValue, "remote.channel_changed")
    }

    /// **유기 검증 #4**: 4 kind 가 사용 시점 별 의미 분기.
    /// sent / responded / error / channel_changed — 각각 다른 lifecycle stage.
    func testKindsCoverFullLifecycle() {
        let lifecycle: Set<String> = [
            "remote.command_sent",          // 1) 사용자 액션
            "remote.command_responded",     // 2) 성공
            "remote.command_error",         // 3) 실패
            "remote.channel_changed"        // 4) infra 전환
        ]
        let actual = Set([
            TelemetryKind.remoteCommandSent.rawValue,
            TelemetryKind.remoteCommandResponded.rawValue,
            TelemetryKind.remoteCommandError.rawValue,
            TelemetryKind.remoteChannelChanged.rawValue
        ])
        XCTAssertEqual(actual, lifecycle,
                       "4 lifecycle stage 정확 매핑")
    }

    /// **유기 검증 #5**: snake_case 일관성 — period 후 underscore.
    func testKindsUseSnakeCaseAfterPeriod() {
        for kind in [TelemetryKind.remoteCommandSent,
                     .remoteCommandResponded,
                     .remoteCommandError,
                     .remoteChannelChanged] {
            XCTAssertTrue(kind.rawValue.contains("_"),
                          "kind=\(kind.rawValue) 가 snake_case 아님")
            XCTAssertFalse(kind.rawValue.contains("-"),
                           "kebab-case 금지: \(kind.rawValue)")
        }
    }
}
