import XCTest
import CoreImage
@testable import DarwinForgeUI

/// QRCodeImage — CIQRCodeGenerator 출력 검증.
///
/// "편지 봉투에 주소가 제대로 찍혔는지 확인하는 것처럼":
/// payload 를 넣으면 실제 CIImage 가 나오고, 크기가 0 이 아님을 검증.
@available(macOS 11.0, *)
final class QRCodeImageTests: XCTestCase {

    // MARK: - CIImage 생성 검증

    func testMakeCIImageNonNilForValidPayload() {
        let ciImage = QRCodeImage.makeCIImage(from: #"{"type":"darwinforge.mobileRelay"}"#)
        XCTAssertNotNil(ciImage, "유효한 JSON payload 는 CIImage 를 반환해야 함")
    }

    func testMakeCIImageNonNilForSimpleString() {
        let ciImage = QRCodeImage.makeCIImage(from: "hello")
        XCTAssertNotNil(ciImage, "단순 문자열도 CIImage 를 반환해야 함")
    }

    func testCIImageExtentPositive() {
        let ciImage = QRCodeImage.makeCIImage(from: "test-payload")
        XCTAssertNotNil(ciImage)
        let extent = ciImage!.extent
        XCTAssertGreaterThan(extent.width, 0, "CIImage width 는 양수여야 함")
        XCTAssertGreaterThan(extent.height, 0, "CIImage height 는 양수여야 함")
    }

    // MARK: - 페어링 QR 페이로드 전체 경로 검증

    func testFullPairingPayloadProducesImage() throws {
        let payload = PairingQRPayload(host: "192.168.1.100", port: 17370, pairingCode: "555000")
        let encoded = try payload.encode()
        let image = QRCodeImage.makeQRImage(from: encoded, size: 160)
        XCTAssertNotNil(image, "PairingQRPayload JSON → Image 변환 실패")
    }

    // MARK: - 빈 문자열 처리

    func testEmptyPayloadFallsGracefully() {
        // 빈 문자열은 QR 이 생성될 수도, 안 될 수도 있음 — crash 없음이 목표
        let image = QRCodeImage.makeQRImage(from: "", size: 160)
        // nil 이어도 crash 없으면 통과 (fallback UI 가 처리)
        _ = image
    }

    // MARK: - 재현성 (동일 payload → 동일 픽셀 구조)

    func testSamePayloadProducesConsistentCIImages() {
        let payload = #"{"host":"10.0.0.1","port":17370}"#
        let img1 = QRCodeImage.makeCIImage(from: payload)
        let img2 = QRCodeImage.makeCIImage(from: payload)
        XCTAssertNotNil(img1)
        XCTAssertNotNil(img2)
        // extent 가 동일 → 동일 QR matrix 크기
        XCTAssertEqual(img1!.extent.width, img2!.extent.width,
                       "동일 payload 는 동일 extent width 를 가져야 함")
    }
}
