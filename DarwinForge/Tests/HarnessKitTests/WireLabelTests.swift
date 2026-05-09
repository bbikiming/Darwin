import XCTest
@testable import HarnessKit

final class WireLabelTests: XCTestCase {
    func testParseExampleFromDataModelDoc() throws {
        let label = try XCTUnwrap(WireLabel(parsing: "W042 LL.KNEE.SIG"))
        XCTAssertEqual(label.id, 42)
        XCTAssertEqual(label.body, "LL")
        XCTAssertEqual(label.joint, "KNEE")
        XCTAssertEqual(label.function, "SIG")
    }

    func testFormattedRoundTrip() throws {
        let label = WireLabel(id: 7, body: "RA", joint: "ELB", function: "PWR")
        XCTAssertEqual(label.formatted, "W007 RA.ELB.PWR")
        XCTAssertEqual(WireLabel(parsing: label.formatted), label)
    }

    func testRejectsMalformed() {
        XCTAssertNil(WireLabel(parsing: "not a label"))
        XCTAssertNil(WireLabel(parsing: "W042 LL.KNEE")) // too few segments
        XCTAssertNil(WireLabel(parsing: "W LL.KNEE.SIG")) // no number
    }
}
