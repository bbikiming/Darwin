import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.19.0 (2026-05-21) 사이클 3 — auto-generation 단위 테스트**.
@MainActor
final class WalkTrialAutoGeneratorTests: XCTestCase {

    func testProgressInitiallyNil() {
        let gen = WalkTrialAutoGenerator()
        XCTAssertNil(gen.progress)
    }

    func testProgressPercentZero() {
        let p = WalkTrialAutoGenerator.Progress(current: 0, total: 10, lastTrial: nil)
        XCTAssertEqual(p.percentComplete, 0)
    }

    func testProgressPercentHalf() {
        let p = WalkTrialAutoGenerator.Progress(current: 5, total: 10, lastTrial: "test")
        XCTAssertEqual(p.percentComplete, 0.5, accuracy: 1e-9)
    }

    func testProgressPercentFull() {
        let p = WalkTrialAutoGenerator.Progress(current: 10, total: 10, lastTrial: "done")
        XCTAssertEqual(p.percentComplete, 1.0)
    }

    func testProgressDivisionByZero() {
        let p = WalkTrialAutoGenerator.Progress(current: 0, total: 0, lastTrial: nil)
        XCTAssertEqual(p.percentComplete, 0)
    }

    func testGenerateSingleSimMode() async {
        let session = WalkLabSession()
        let gen = WalkTrialAutoGenerator()
        XCTAssertNil(session.store)

        await gen.generateSingle(
            session: session,
            preset: .slowWalk,
            intensity: 2,
            durationSec: 0.2
        )
        XCTAssertEqual(session.current, .idle)
        XCTAssertEqual(session.correctorIntensityLevel, 2)
    }

    func testGenerateBatchProgresses() async {
        let session = WalkLabSession()
        let gen = WalkTrialAutoGenerator()
        await gen.generateBatch(
            session: session,
            presetSet: [.slowWalk],
            intensityRange: 2...2,
            trialsPerCombo: 1,
            durationSec: 0.1
        )
        XCTAssertNotNil(gen.progress)
        XCTAssertEqual(gen.progress?.total, 1)
        XCTAssertEqual(gen.progress?.current, 1)
    }
}
