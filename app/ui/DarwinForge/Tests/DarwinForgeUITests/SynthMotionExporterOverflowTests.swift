import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 사이클 187 (codex MAJOR fix cycle 180): UInt8 overflow guard 검증.
///
/// # 비유
///
/// 빌딩 의 우편함 — 255개 칸 이 최대. 추가 입주자 가 256번째 칸 요청 시 silent 로 마지막
/// 칸 에 덮어쓰면 우편물 분실 (duplicate ID = 모션 데이터 손실).
///
/// 본 테스트 는 cycle 180 의 UInt8(clamping:) silent failure 회귀 차단.
final class SynthMotionExporterOverflowTests: XCTestCase {

    /// **검증 #1**: existingMaxId=0 + 100 pages → success (모두 1..100).
    func testEmptyExistingHundredPagesSuccess() {
        let imports = makePages(count: 100)
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 0,
            importPages: imports
        )
        guard case .success(let reassigned) = result else {
            XCTFail("100 page success expected, got \(result)")
            return
        }
        XCTAssertEqual(reassigned.count, 100)
        XCTAssertEqual(reassigned.first?.id, 1)
        XCTAssertEqual(reassigned.last?.id, 100)
    }

    /// **검증 #2 (regression)**: existingMaxId=250 + 5 pages → success (251..255).
    func testMaxBoundaryFiveSuccess() {
        let imports = makePages(count: 5)
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 250,
            importPages: imports
        )
        guard case .success(let reassigned) = result else {
            XCTFail("boundary success expected, got \(result)")
            return
        }
        XCTAssertEqual(reassigned.map { Int($0.id) }, [251, 252, 253, 254, 255])
    }

    /// **검증 #3 (regression guard)**: existingMaxId=250 + 6 pages → `.idOverflow`.
    /// 종전 cycle 180 silently clamped 256→255 → duplicate IDs.
    func testOverflowJustBeyondBoundaryFails() {
        let imports = makePages(count: 6)
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 250,
            importPages: imports
        )
        guard case .failure(.idOverflow(let max, let count)) = result else {
            XCTFail(".idOverflow expected, got \(result)")
            return
        }
        XCTAssertEqual(max, 250)
        XCTAssertEqual(count, 6)
    }

    /// **검증 #4**: existingMaxId=255 + 1 page → `.idOverflow`.
    func testAtMaxOneMoreFails() {
        let imports = makePages(count: 1)
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 255,
            importPages: imports
        )
        guard case .failure(.idOverflow) = result else {
            XCTFail(".idOverflow expected")
            return
        }
    }

    /// **검증 #5**: import 의 metadata 보존 (steps / compliance / nextPage / 등).
    func testReassignPreservesMetadata() {
        let imports = [
            MotionPage(
                id: 99, name: "Original",
                compliance: Array(repeating: 7, count: 31),
                nextPage: 50, exitPage: 60,
                repeat: 3, speed: 64, accel: 2,
                steps: [MotionStep(), MotionStep(), MotionStep()]
            )
        ]
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 10,
            importPages: imports
        )
        guard case .success(let reassigned) = result, let p = reassigned.first else {
            XCTFail("success expected")
            return
        }
        XCTAssertEqual(p.id, 11, "신규 ID")
        XCTAssertTrue(p.name.contains("Synth · Original"), "name prefix")
        XCTAssertEqual(p.compliance, Array(repeating: 7, count: 31))
        XCTAssertEqual(p.nextPage, 50)
        XCTAssertEqual(p.exitPage, 60)
        XCTAssertEqual(p.repeat, 3)
        XCTAssertEqual(p.speed, 64)
        XCTAssertEqual(p.accel, 2)
        XCTAssertEqual(p.steps.count, 3)
    }

    /// **검증 #6**: 한국어 메시지 의 정보성 — 사용자가 "어디까지 차 있고 얼마나 시도 했는지"
    /// 명시 → 정확한 액션 결정 가능.
    func testOverflowKoreanMessageIsActionable() {
        let msg = SynthMotionExporter.koreanMessage(
            for: .idOverflow(existingMaxId: 200, importCount: 60)
        )
        XCTAssertTrue(msg.contains("255"), "max=255 명시: \(msg)")
        XCTAssertTrue(msg.contains("200"), "현 max 표시")
        XCTAssertTrue(msg.contains("60"), "import count 표시")
        XCTAssertTrue(msg.contains("삭제"),
                      "사용자 액션 안내 (삭제 후 재시도): \(msg)")
    }

    /// **검증 #7**: 빈 import → success (empty array). 의미 없는 edge case 회피.
    func testEmptyImportSucceedsWithEmpty() {
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 100,
            importPages: []
        )
        guard case .success(let r) = result else {
            XCTFail("empty success expected")
            return
        }
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - Helpers

    private func makePages(count: Int) -> [MotionPage] {
        (0..<count).map { i in
            MotionPage(id: UInt8(clamping: i + 1), name: "p\(i)", steps: [.center])
        }
    }
}
