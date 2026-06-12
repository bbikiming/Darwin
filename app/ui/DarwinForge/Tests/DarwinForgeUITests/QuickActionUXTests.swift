import XCTest
@testable import DarwinForgeUI

/// UX 리디자인(2026-06-13) 계약 가드 — 라이팅 규약·안전 위계·위험 감지.
final class QuickActionUXTests: XCTestCase {

    // MARK: - 라이팅 규약 (기획 4.1)

    /// detail 은 결과 중심 — 명령 원문 토큰이 새면 안 된다(전문은 툴팁·명령 보기 담당).
    func testDetailContainsNoRawCommandTokens() {
        let forbidden = ["sudo ", "free -m", "lsb_release", "killall ", "head -", "tail -",
                         "init.d", "/dev/tty", "| grep", "2>/dev/null"]
        for action in QuickActionCatalog.all {
            for token in forbidden {
                XCTAssertFalse(action.detail.contains(token),
                               "\(action.id): detail 에 명령 토큰 '\(token)' 포함 — 결과 중심으로")
            }
        }
    }

    /// confirm 액션은 전용 동사 버튼 — "확인"/"실행" 단독 금지(무엇이 실행되는지 가리지 않기).
    func testConfirmActionsHaveMeaningfulVerb() {
        for action in QuickActionCatalog.all where action.requiresConfirm {
            guard let verb = action.confirmVerb else {
                XCTFail("\(action.id): confirm 액션은 confirmVerb 지정"); continue
            }
            XCTAssertFalse(verb.isEmpty, "\(action.id): 빈 동사")
            XCTAssertFalse(["확인", "실행", "OK"].contains(verb),
                           "\(action.id): 무의미 동사 '\(verb)' — 전용 동사로")
        }
    }

    /// confirm 액션은 질문형 제목을 갖는다.
    func testConfirmActionsHaveQuestionTitle() {
        for action in QuickActionCatalog.all where action.requiresConfirm {
            guard let title = action.confirmTitle else {
                XCTFail("\(action.id): confirm 액션은 confirmTitle 지정"); continue
            }
            XCTAssertTrue(title.hasSuffix("?"), "\(action.id): 제목은 질문형 — '\(title)'")
        }
    }

    // MARK: - 안전 위계 (기획 5장)

    /// danger ↔ 홀드(T3) 1:1 — danger 는 전부 홀드, 홀드는 danger 뿐.
    func testDangerTierBijection() {
        for action in QuickActionCatalog.all {
            if action.category == .danger {
                XCTAssertEqual(action.confirmTier, .hold, "\(action.id): danger 는 홀드 확인")
            } else {
                XCTAssertNotEqual(action.confirmTier, .hold, "\(action.id): 홀드는 danger 전용")
            }
        }
    }

    /// 정지·중지 계열은 T1(즉시) 불변식 — "멈추는 일은 쉽게"(E-STOP 즉시발화와 동일 축).
    func testStopActionsAreImmediate() {
        for id in ["demo-stop", "camera-stop"] {
            guard let action = QuickActionCatalog.action(id: id) else {
                XCTFail("\(id) 카탈로그에 없음"); continue
            }
            XCTAssertEqual(action.confirmTier, .none, "\(id): 정지 계열에 확인 마찰 금지")
        }
    }

    /// octagon 심볼은 danger 카테고리 아이콘 외 일반 액션 아이콘으로 사용 금지(전용화).
    func testOctagonIconReservedForDanger() {
        for action in QuickActionCatalog.all where action.category != .danger {
            XCTAssertFalse(action.icon.contains("octagon"),
                           "\(action.id): octagon 은 위험 전용 심볼")
        }
    }

    /// bus(읽기 전용 진단)는 warning 색 금지 — 색 불변식(노랑=주의 전용).
    func testBusTintIsNotWarning() {
        XCTAssertNotEqual(QuickActionCategory.bus.tint, DFColor.warning,
                          "읽기 전용 진단이 주의색이면 색 의미론 붕괴")
    }

    // MARK: - 모델 (시트)

    /// 제목/동사 폴백 산식.
    func testConfirmModelFallbacks() {
        let bare = QuickAction(id: "t", category: .system, label: "테스트",
                               detail: "d", icon: "gear", command: "x",
                               requiresConfirm: true)
        let model = QuickActionConfirmModel(action: bare)
        XCTAssertEqual(model.title, "테스트 — 실행할까요?")
        XCTAssertEqual(model.runVerb, "실행")
        XCTAssertFalse(model.requiresHold)
    }

    /// 컨텍스트 행은 본문 계약(dialogBodyText)에 불포함 — 길이 가드 유지.
    func testContextLineNotInDialogBody() {
        guard let action = QuickActionCatalog.action(id: "reboot") else {
            return XCTFail("reboot 없음")
        }
        let model = QuickActionConfirmModel(action: action, contextLine: "현재: SSH 연결됨 · 보행 모드")
        XCTAssertFalse(model.dialogBodyText.contains("현재:"))
        XCTAssertLessThan(model.dialogBodyText.count, 300)
        XCTAssertTrue(model.requiresHold, "reboot 는 T3 홀드")
    }

    // MARK: - 직접 입력 위험 감지 (기획 3.5)

    func testDangerDetectorPositives() {
        let dangerous = [
            "sudo reboot",
            "reboot",
            "sudo poweroff",
            "shutdown -h now",
            "sudo killall -9 socat",
            "killall socat",
            "rm -rf /",
            "sudo dd if=/dev/zero of=/dev/sda",
            "echo hi && sudo reboot",
        ]
        for cmd in dangerous {
            XCTAssertTrue(DangerCommandDetector.isDangerous(cmd), "미탐: \(cmd)")
        }
    }

    func testDangerDetectorNegatives() {
        let safe = [
            "uptime",
            "ls -la /dev/ttyUSB*",
            "cat /var/log/reboot-history.log",   // 단어 경계 — 파일명 오탐 금지
            "echo reboot-needed",
            "rm -rf /tmp/df-cache",              // 루트 아닌 경로
            "sudo /etc/init.d/forge-bridge restart",
            "grep poweroff-policy config.txt",
        ]
        for cmd in safe {
            XCTAssertFalse(DangerCommandDetector.isDangerous(cmd), "오탐: \(cmd)")
        }
    }

    // MARK: - Exchange exitCode (additive 계약)

    func testExchangeExitCodeDefaultsNil() {
        let ex = RemoteShell.Exchange(command: "x", sentAt: Date())
        XCTAssertNil(ex.exitCode, "exitCode 는 additive — 기본 nil")
        XCTAssertNil(ex.elapsedMs)
    }
}
