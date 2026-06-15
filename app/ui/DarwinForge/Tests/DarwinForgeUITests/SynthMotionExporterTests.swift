import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 사이클 180 (P0 #3.2 fix, cycle 177 audit): Synth 합성 결과 → Motion Studio 적용
/// path 의 pure logic 검증.
///
/// # 비유
///
/// 음식 조리실 (Synth) → 진열대 (Motion Studio) 의 conveyor belt 검사. 음식 (JSON) 이
/// 정상이면 진열대 에 잘 옮겨지고, 비어있거나 깨지면 표시 가능한 한국어 에러.
final class SynthMotionExporterTests: XCTestCase {

    // MARK: - Pure logic

    /// **검증 #1**: nil / 공백 resultJSON → `.emptyJSON`.
    func testEmptyJSONFails() {
        XCTAssertEqual(
            SynthMotionExporter.pages(from: nil),
            .failure(.emptyJSON)
        )
        XCTAssertEqual(
            SynthMotionExporter.pages(from: ""),
            .failure(.emptyJSON)
        )
        XCTAssertEqual(
            SynthMotionExporter.pages(from: "   \n  "),
            .failure(.emptyJSON),
            "공백 trimmed 후 empty"
        )
    }

    /// **검증 #2**: 디코딩 불가 JSON → `.decodeFailed`.
    func testGarbageJSONFails() {
        let result = SynthMotionExporter.pages(from: "{ not motion doc }")
        guard case .failure(.decodeFailed) = result else {
            XCTFail("decode 실패 expected, got \(result)")
            return
        }
    }

    /// **검증 #3**: 유효 MotionDoc 이지만 pages 가 비어있음 → `.noPages`.
    func testValidDocButNoPagesFails() throws {
        let emptyDoc = MotionDoc(version: 1, robotGeneration: "op2", pages: [])
        let json = try emptyDoc.toJSON()
        XCTAssertEqual(
            SynthMotionExporter.pages(from: json),
            .failure(.noPages)
        )
    }

    /// **검증 #4**: 정상 MotionDoc → pages 추출.
    func testValidDocReturnsPages() throws {
        let doc = MotionDoc(
            version: 1, robotGeneration: "op2",
            pages: [
                MotionPage(id: 100, name: "synth_walk", steps: [.center]),
                MotionPage(id: 101, name: "synth_bow", steps: [.center, .center])
            ]
        )
        let json = try doc.toJSON()
        let result = SynthMotionExporter.pages(from: json)
        guard case .success(let pages) = result else {
            XCTFail("success expected, got \(result)")
            return
        }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].id, 100)
        XCTAssertEqual(pages[0].name, "synth_walk")
        XCTAssertEqual(pages[1].id, 101)
        XCTAssertEqual(pages[1].steps.count, 2)
    }

    /// **검증 #5**: 한국어 에러 메시지 의 사용자 명확성 — 모든 case 에 의미 있는 안내.
    func testKoreanErrorMessages() {
        let emptyMsg = SynthMotionExporter.koreanMessage(for: .emptyJSON)
        XCTAssertTrue(emptyMsg.contains("Synthesize") || emptyMsg.contains("결과"),
                      "empty 메시지: \(emptyMsg)")

        let decodeMsg = SynthMotionExporter.koreanMessage(for: .decodeFailed("test detail"))
        XCTAssertTrue(decodeMsg.contains("디코딩") && decodeMsg.contains("test detail"),
                      "decode 메시지에 원본 detail 포함: \(decodeMsg)")

        let noPagesMsg = SynthMotionExporter.koreanMessage(for: .noPages)
        XCTAssertTrue(noPagesMsg.contains("페이지") || noPagesMsg.contains("적용"),
                      "no pages 메시지: \(noPagesMsg)")
    }

    /// **유기 검증 #6**: SynthBridge 의 motionJSON 출력 schema 와 일치 확인 round-trip.
    /// 본 exporter 는 SynthResult.motionJSON → MotionDoc.from(json:) → pages 의 chain 가정.
    /// MotionDoc encode + decode round-trip 이 보존되는지 확인.
    func testRoundTripPreservesPagesIdentity() throws {
        let originalPages = [
            MotionPage(id: 200, name: "Synth Result A",
                       compliance: Array(repeating: 5, count: 31),
                       nextPage: 0, exitPage: 0,
                       repeat: 1, speed: 32, accel: 0,
                       steps: [MotionStep(), MotionStep()]),
            MotionPage(id: 201, name: "Synth Result B",
                       compliance: Array(repeating: 5, count: 31),
                       nextPage: 200, exitPage: 0,
                       repeat: 1, speed: 32, accel: 0,
                       steps: [MotionStep()])
        ]
        let doc = MotionDoc(version: 1, robotGeneration: "op2", pages: originalPages)
        let json = try doc.toJSON()
        let result = SynthMotionExporter.pages(from: json)
        guard case .success(let pages) = result else {
            XCTFail("round-trip success expected")
            return
        }
        XCTAssertEqual(pages, originalPages,
                       "Codable round-trip 이 id/name/steps/compliance 정확 보존")
    }

    /// **유기 검증 #7**: 사용자가 빈 string 시 .emptyJSON, garbage 시 .decodeFailed 구분 →
    /// 가이드 메시지 가 적절히 분기 가능 (사용자 액션 다름).
    func testErrorBranchesGuideUserActionDifferently() {
        let emptyResult = SynthMotionExporter.pages(from: nil)
        let garbageResult = SynthMotionExporter.pages(from: "garbage")
        // 두 메시지가 서로 다름 — emptyJSON 은 "Synthesize 먼저" 안내,
        // decodeFailed 는 "스키마 문제" 안내.
        switch (emptyResult, garbageResult) {
        case (.failure(let e1), .failure(let e2)):
            let m1 = SynthMotionExporter.koreanMessage(for: e1)
            let m2 = SynthMotionExporter.koreanMessage(for: e2)
            XCTAssertNotEqual(m1, m2,
                              "에러 case 별로 다른 사용자 안내. m1=\(m1) m2=\(m2)")
        default:
            XCTFail("두 경우 모두 .failure expected")
        }
    }
}
