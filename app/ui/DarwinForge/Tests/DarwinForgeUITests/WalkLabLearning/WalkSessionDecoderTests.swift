import XCTest
@testable import DarwinForgeUI

final class WalkSessionDecoderTests: XCTestCase {

    // 1) v1 로그 호환 — 21개 기존 로그가 깨지지 않고 읽힌다.
    func testV1SessionLogStillDecodes() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 8, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        XCTAssertEqual(decoded.schemaVersion, .v1)
        XCTAssertEqual(decoded.header.preset, "march")
        XCTAssertEqual(decoded.header.appVersion, "1.0.0-20ff37a")
        XCTAssertFalse(decoded.samples.isEmpty)
        XCTAssertEqual(decoded.parseErrors, 0)
    }

    // 2) v2 로그에 schemaVersion + line type 이 들어간다.
    func testV2SessionLogIncludesSchemaAndLineTypes() throws {
        let file = WalkSessionFixtures.v2CleanFile(durationSec: 5)
        XCTAssertTrue(file.contains("\"type\":\"header\""))
        XCTAssertTrue(file.contains("\"type\":\"sample\""))
        XCTAssertTrue(file.contains("\"schemaVersion\":2"))

        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        XCTAssertEqual(decoded.schemaVersion, .v2)
        XCTAssertEqual(decoded.header.balanceAlgorithmMode, "hybridBA")
        XCTAssertEqual(decoded.header.balanceSignConvention, "robotisWalkingCpp")
    }

    func testV2DecoderTracksDuplicateFlag() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 5)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        // v1 fixture 는 매 10 sample 마다만 IMU 변화 → 다수 sample 이 duplicate.
        let dupCount = decoded.samples.filter { $0.imuDuplicate }.count
        XCTAssertGreaterThan(dupCount, decoded.samples.count / 3)
    }

    func testCorruptedLineSkippedNotFatal() throws {
        let valid = WalkSessionFixtures.v1HeaderLine()
        let garbage = "{this is not json"
        let sample = WalkSessionFixtures.v1SampleLine(tMs: 100)
        let combined = [valid, garbage, sample].joined(separator: "\n")
        let decoded = try WalkSessionDecoder.decode(lines: combined.split(separator: "\n").map(String.init))
        XCTAssertEqual(decoded.parseErrors, 1)
        XCTAssertEqual(decoded.samples.count, 1)
    }

    func testEmptyFileThrows() {
        XCTAssertThrowsError(try WalkSessionDecoder.decode(lines: []))
    }

    func testMissingHeaderThrows() {
        let lines = [WalkSessionFixtures.v1SampleLine(tMs: 100)]
        XCTAssertThrowsError(try WalkSessionDecoder.decode(lines: lines)) { error in
            XCTAssertEqual(error as? WalkSessionDecoderError, .missingHeader)
        }
    }
}
