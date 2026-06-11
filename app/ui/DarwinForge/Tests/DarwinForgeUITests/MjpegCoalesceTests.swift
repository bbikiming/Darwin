import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import DarwinForgeUI

/// **Wave 3 — J9 MJPEG 프레임 코얼레싱 (2026-06-11)** 배선 가드.
///
/// 추출→deliver→publish 경로(bufferingNewest(1) 코얼레싱 스트림 경유)가 frame 을
/// 실제로 표시까지 전달하고, 단일 frame 에선 드롭 회계가 false-positive 를 내지 않음을
/// 검증. (코얼레싱 드롭 자체는 소비자 지연에 의존 — 타이밍 비결정적이라 단언하지 않음.)
@MainActor
final class MjpegCoalesceTests: XCTestCase {

    /// headless-safe 한 최소 JPEG 생성(window server 불요 — CGContext + ImageIO).
    private func tinyJpeg() -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func multipartFrame(_ jpeg: Data, boundary: String) -> Data {
        var d = Data("--\(boundary)\r\n".utf8)
        d.append(Data("Content-Type: image/jpeg\r\n".utf8))
        d.append(Data("Content-Length: \(jpeg.count)\r\n\r\n".utf8))
        d.append(jpeg)
        d.append(Data("\r\n".utf8))
        return d
    }

    // MARK: - contentLength CRLF 파싱 (버그 회귀 가드)

    /// 표준 CRLF 헤더에서 Content-Length 를 파싱해야 한다. 종전 grapheme-split 은
    /// "\r\n" 을 단일 Character 로 봐 한 줄로 처리 → nil → 모든 frame skip(영상 미표시).
    func testContentLength_ParsesCRLFHeaders() {
        let crlf = "\r\nContent-Type: image/jpeg\r\nContent-Length: 706\r\n\r\n"
        XCTAssertEqual(MjpegStreamingClient.contentLength(fromHeaders: crlf), 706,
                       "CRLF 헤더에서 Content-Length 파싱")
    }

    func testContentLength_ParsesLFHeaders() {
        let lf = "\nContent-Type: image/jpeg\nContent-Length: 1234\n\n"
        XCTAssertEqual(MjpegStreamingClient.contentLength(fromHeaders: lf), 1234,
                       "LF 헤더도 동일 파싱(하위 호환)")
    }

    func testSingleFrame_DeliveredThroughCoalesceStream_NoFalseDrop() async {
        let client = MjpegStreamingClient()
        let boundary = "frame"
        let jpeg = tinyJpeg()
        // 전제: 생성한 JPEG 가 실제로 디코드 가능해야 파이프라인 검증이 유효.
        XCTAssertFalse(jpeg.isEmpty, "JPEG 생성됨")
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil),
            "생성 JPEG 가 디코드 가능")
        // detection 비활성 — 4x4 더미에 vision 불필요(파이프라인 배선만 검증).
        client.detectionEnabled = false
        let body = multipartFrame(jpeg, boundary: boundary)

        await client._testFeedMultipart(body, boundary: boundary)

        XCTAssertEqual(client.framesReceived, 1, "단일 frame 은 코얼레싱 경로로 표시까지 전달")
        XCTAssertEqual(client.droppedFrameCount, 0, "단일 frame 에선 드롭 회계 false-positive 없음")
        XCTAssertNotNil(client.image, "표시 image 갱신됨")
    }
}
