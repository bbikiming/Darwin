import XCTest
@testable import DarwinForgeUI

/// 실제로 디스크에 저장된 21개 v1 세션을 통과시켜본다. CI 에서는 디렉토리가 없으면 skip.
final class WalkSessionRealLogsTests: XCTestCase {

    func testAll21LegacyLogsDecodeWithoutCrash() throws {
        let dir = WalkSessionLogger.Configuration.defaultUserDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("실제 로그 디렉토리가 없음 — CI 에서는 skip")
        }
        let jsonls = items.filter { $0.pathExtension == "jsonl" }
        guard !jsonls.isEmpty else {
            throw XCTSkip("로그 파일이 없음 — skip")
        }
        var decodedCount = 0
        for url in jsonls {
            do {
                let decoded = try WalkSessionDecoder.decode(file: url)
                XCTAssertGreaterThan(decoded.samples.count, 0, "\(url.lastPathComponent) sample 없음")
                XCTAssertFalse(decoded.header.preset.isEmpty)
                decodedCount += 1
            } catch {
                XCTFail("\(url.lastPathComponent) decode 실패: \(error)")
            }
        }
        XCTAssertGreaterThanOrEqual(decodedCount, 1)
    }

    /// 실제 로그가 prompt 의 예상대로 대부분 C/D/F 등급으로 분류되는지 확인.
    func testAll21LegacyLogsAreClassifiedAsLowQuality() throws {
        let dir = WalkSessionLogger.Configuration.defaultUserDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("실제 로그 디렉토리가 없음 — CI 에서는 skip")
        }
        let jsonls = items.filter { $0.pathExtension == "jsonl" }
        guard !jsonls.isEmpty else {
            throw XCTSkip("로그 파일이 없음 — skip")
        }
        var comparisonCount = 0
        var nonComparisonCount = 0
        for url in jsonls {
            guard let decoded = try? WalkSessionDecoder.decode(file: url) else { continue }
            let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
            if quality.useClass == .usableForComparison {
                comparisonCount += 1
            } else {
                nonComparisonCount += 1
            }
        }
        // 핵심: duplicate 90%+ 인 21개 로그가 algorithm 비교 그룹으로 들어가면 안 됨.
        XCTAssertEqual(comparisonCount, 0,
                       "v1 logs 중 \(comparisonCount)개가 잘못 comparison 으로 분류됨")
        XCTAssertGreaterThan(nonComparisonCount, 0)
    }
}
