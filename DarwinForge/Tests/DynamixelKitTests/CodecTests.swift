import XCTest
@testable import DynamixelKit

final class CodecTests: XCTestCase {
    func testEncodePingPacketMatchesProtocolFixture() {
        // PING to ID 1 → 0xFF 0xFF 0x01 0x02 0x01 0xFB
        let packet = InstructionPacket(id: 1, instruction: .ping)
        XCTAssertEqual(Codec.encode(packet),
                       [0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB])
    }

    func testEncodeWritePacketChecksumIsCorrect() {
        // WRITE_DATA to ID 1, address 0x03, value 0x01 → known fixture
        let packet = InstructionPacket(id: 1,
                                       instruction: .writeData,
                                       parameters: [0x03, 0x01])
        let encoded = Codec.encode(packet)
        XCTAssertEqual(encoded.first, 0xFF)
        XCTAssertEqual(encoded[1], 0xFF)
        XCTAssertEqual(encoded[2], 0x01)
        XCTAssertEqual(encoded[3], 0x04) // length = N + 2 = 4
        XCTAssertEqual(encoded[4], 0x03) // instruction WRITE_DATA
        XCTAssertEqual(encoded[5], 0x03) // address
        XCTAssertEqual(encoded[6], 0x01) // value
        XCTAssertEqual(encoded.last,
                       Codec.checksum(id: 1, length: 4, opcode: 0x03, parameters: [0x03, 0x01]))
    }

    func testDecodeStatusPacketRoundTrip() throws {
        // Status packet for ID 1 with no error and no params: FF FF 01 02 00 FC
        let bytes: [UInt8] = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC]
        let status = try Codec.decodeStatus(bytes)
        XCTAssertEqual(status.id, 1)
        XCTAssertTrue(status.error.isEmpty)
        XCTAssertEqual(status.parameters, [])
    }

    func testDecodeStatusRejectsBadChecksum() {
        let bytes: [UInt8] = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0x00]
        XCTAssertThrowsError(try Codec.decodeStatus(bytes)) { error in
            guard case CodecError.checksumMismatch = error else {
                XCTFail("expected checksumMismatch, got \(error)")
                return
            }
        }
    }

    func testDecodeStatusRejectsTruncated() {
        XCTAssertThrowsError(try Codec.decodeStatus([0xFF, 0xFF, 0x01]))
    }
}
