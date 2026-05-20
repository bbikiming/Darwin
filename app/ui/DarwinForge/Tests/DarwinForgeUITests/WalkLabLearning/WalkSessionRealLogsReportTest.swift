import XCTest
@testable import DarwinForgeUI

/// 실제 21개 로그를 새 분류로 다시 평가해서 report 를 콘솔에 출력한다.
/// CI 에서 디렉토리가 없으면 skip — local 개발자가 결과를 확인하는 용도.
final class WalkSessionRealLogsReportTest: XCTestCase {

    func testPrintReclassificationReport() throws {
        let dir = WalkSessionLogger.Configuration.defaultUserDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            throw XCTSkip("실제 로그 디렉토리가 없음 — skip")
        }
        let jsonls = items.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        guard !jsonls.isEmpty else { throw XCTSkip("로그 없음") }

        var counts: [WalkSessionUseClass: Int] = [:]
        var gradeCounts: [WalkSessionGrade: Int] = [:]
        var actionCounts: [RecommendationAction: Int] = [:]
        var lines: [String] = []
        for url in jsonls {
            guard let decoded = try? WalkSessionDecoder.decode(file: url) else { continue }
            let summary = WalkSessionAnalyzer.summarize(session: decoded)
            counts[summary.dataQuality.useClass, default: 0] += 1
            gradeCounts[summary.dataQuality.grade, default: 0] += 1
            actionCounts[summary.recommendation.action, default: 0] += 1
            lines.append(String(format: "  %@  grade=%@  useClass=%@  duplicate=%.0f%%  indepIMU=%d  action=%@",
                                 url.lastPathComponent,
                                 summary.dataQuality.grade.rawValue,
                                 summary.dataQuality.useClass.rawValue,
                                 summary.dataQuality.imuDuplicateRatio * 100,
                                 summary.dataQuality.independentImuSampleCount,
                                 summary.recommendation.action.rawValue))
        }
        print("\n=== 21개 기존 로그 재판정 결과 ===")
        for line in lines { print(line) }
        print("\nUse class counts:")
        for (k, v) in counts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("  \(k.rawValue): \(v)")
        }
        print("\nGrade counts:")
        for (k, v) in gradeCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("  \(k.rawValue): \(v)")
        }
        print("\nRecommendation action counts:")
        for (k, v) in actionCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("  \(k.rawValue): \(v)")
        }

        // 핵심 invariant: comparison 으로 잘못 분류된 게 없어야 함.
        XCTAssertEqual(counts[.usableForComparison] ?? 0, 0)
        XCTAssertGreaterThan(counts.values.reduce(0, +), 0)
    }
}
