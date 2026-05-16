import AppKit
import Foundation
import ForgeCore

/// 실시간 MJPEG 스트림 client — `multipart/x-mixed-replace` 디코더.
///
/// # 표준
///
/// mjpg-streamer 패턴 (ROBOTIS camera_tutorial / Darwin demo 호환):
/// ```
/// GET /?action=stream HTTP/1.1
///
/// HTTP/1.1 200 OK
/// Content-Type: multipart/x-mixed-replace; boundary=boundarydonotcross
///
/// --boundarydonotcross
/// Content-Type: image/jpeg
/// Content-Length: <N>
///
/// <N bytes JPEG>
/// --boundarydonotcross
/// Content-Type: image/jpeg
/// Content-Length: <N>
///
/// <N bytes JPEG>
/// ...
/// ```
///
/// # 종전 snapshot 폴링 (`MjpegSnapshotClient`) 와의 차이
///
/// | 항목 | snapshot client | stream client (본 클래스) |
/// |---|---|---|
/// | endpoint | `?action=snapshot` | `?action=stream` |
/// | 동작 | 250ms 간격 GET | 단일 GET, 서버가 boundary 로 frame push |
/// | fps | ~4 | ~30 (서버 의존) |
/// | latency | 250ms + RTT | RTT 만 |
/// | 데이터 효율 | 매 요청마다 HTTP 헤더 | 단일 connection — 헤더 비용 0 |
///
/// # AsyncSequence 기반 byte parser
///
/// `URLSession.bytes(for:)` 가 반환하는 `AsyncBytes` (AsyncSequence<UInt8>) 를
/// 사용해 boundary / headers / JPEG payload 를 순차 파싱.
/// - 상태 머신: `seekingBoundary` → `readingHeaders` → `readingJPEG` → ...
/// - sliding window 로 boundary 검색 (마지막 boundary.length bytes 만 비교)
/// - Content-Length header 로 정확한 JPEG byte 수 읽기 (boundary 다시 검색 불필요)
///
/// # Detection 통합
///
/// 각 frame decode 직후 `BallVision` + `MultiColorVision` 호출 — 종전
/// snapshot client 와 동일 API. detection 비용 (~10-30ms / 256px frame) 이
/// stream throughput 의 ceiling 이지만, 30fps 입력에 대해 충분히 따라잡음.
///
/// # Cancellation
///
/// `stop()` 또는 `Task.cancel()` 시 byte iterator 중단. URLSession 자동
/// connection close.
@MainActor
public final class MjpegStreamingClient: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case connecting
        case live
        case failed(CameraFailureReason)
    }

    @Published public private(set) var image: NSImage?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var framesReceived: Int = 0
    @Published public private(set) var lastFrameAt: Date?
    /// 마지막 frame 의 ball detection (snapshot client API 와 동일).
    @Published public private(set) var lastDetection: BallVision.Detection?
    /// 마지막 frame 의 multi-color detection (Phase D2).
    @Published public private(set) var multiColorDetections: [MultiColorVision.Detection] = []
    /// detection 실행 여부 — false 면 lastDetection 항상 nil.
    public var detectionEnabled: Bool = true
    /// Multi-color HSV preset — Phase E. nil 이면 ROBOTIS default 사용.
    public var hsvPreset: VisionHsvPreset?

    private let session: URLSession
    private var task: Task<Void, Never>?
    private var endpoint: PilotCameraEndpoint?

    public convenience init() {
        let config = URLSessionConfiguration.ephemeral
        // 스트리밍은 connection 유지 — request timeout 길게, resource timeout 무제한.
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        self.init(session: URLSession(configuration: config))
    }

    public init(session: URLSession) {
        self.session = session
    }

    deinit {
        task?.cancel()
    }

    /// 스트림 시작. 이미 같은 endpoint 면 no-op.
    public func start(endpoint: PilotCameraEndpoint) {
        if self.endpoint == endpoint, task != nil { return }

        stop(resetImage: false)
        self.endpoint = endpoint
        phase = .connecting

        task = Task { [weak self] in
            guard let self else { return }
            await self.runStream(endpoint: endpoint)
        }
    }

    public func stop(resetImage: Bool = true) {
        task?.cancel()
        task = nil
        endpoint = nil
        phase = .idle
        framesReceived = 0
        lastFrameAt = nil
        lastDetection = nil
        multiColorDetections = []
        if resetImage { image = nil }
    }

    // MARK: - Stream loop

    private func runStream(endpoint: PilotCameraEndpoint) async {
        guard let url = endpoint.streamURL else {
            phase = .failed(.invalidURL)
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Apple URLSession 이 자동 Keep-alive — 추가 헤더 불필요.

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                phase = .failed(.other("응답 형식 오류"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                phase = .failed(.httpStatus(http.statusCode))
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard let boundary = Self.boundary(fromContentType: contentType) else {
                // stream endpoint 미지원 (ROBOTIS demo 가 snapshot 만 노출하는 경우 등).
                // 호출자가 snapshot client 로 fallback.
                phase = .failed(.decodeFailed)
                return
            }

            phase = .live
            await parseFrames(bytes: bytes, boundary: boundary)
            // stream 자연 종료 (서버 close 또는 cancel).
            if !Task.isCancelled {
                phase = .idle
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(.from(error: error))
        }
    }

    // MARK: - Multipart parser

    private enum ParseState {
        case seekingBoundary
        case readingHeaders
        case readingJPEG
    }

    private func parseFrames(bytes: URLSession.AsyncBytes, boundary: String) async {
        let boundaryDelim = Array("--\(boundary)".utf8)
        let crlf2: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

        var state: ParseState = .seekingBoundary
        // sliding window — boundary / CRLFCRLF 검색용.
        var window: [UInt8] = []
        window.reserveCapacity(8192)
        // 헤더 누적 — Content-Length 파싱용.
        var headerBytes: [UInt8] = []
        headerBytes.reserveCapacity(512)
        // JPEG payload 누적.
        var jpegBytes: [UInt8] = []
        // 남은 JPEG payload byte 수 (Content-Length 기반).
        var jpegRemaining: Int = 0

        do {
            for try await byte in bytes {
                if Task.isCancelled { return }

                switch state {
                case .seekingBoundary:
                    window.append(byte)
                    // window 크기 cap (8 KB) — 안 끝나는 stream 의 메모리 폭주 방지.
                    if window.count > 8192 {
                        window.removeFirst(window.count - 4096)
                    }
                    if Self.windowEndsWith(window, suffix: boundaryDelim) {
                        // boundary 발견 — 다음 라인까지 (CRLF 스킵 후) 헤더 시작.
                        // 헤더 시작 직전 byte (CRLF) 는 다음 state 에서 자연스럽게 처리.
                        window.removeAll(keepingCapacity: true)
                        headerBytes.removeAll(keepingCapacity: true)
                        state = .readingHeaders
                    }

                case .readingHeaders:
                    headerBytes.append(byte)
                    if headerBytes.count > 4096 {
                        // 비정상적으로 긴 헤더 → 스트림 손상 → boundary 다시 검색.
                        state = .seekingBoundary
                        window.removeAll(keepingCapacity: true)
                        headerBytes.removeAll(keepingCapacity: true)
                        continue
                    }
                    if headerBytes.count >= 4,
                       Array(headerBytes.suffix(4)) == crlf2 {
                        // 헤더 종료 — Content-Length 파싱.
                        let headerStr = String(decoding: headerBytes, as: UTF8.self)
                        if let n = Self.contentLength(fromHeaders: headerStr) {
                            jpegBytes.removeAll(keepingCapacity: true)
                            jpegBytes.reserveCapacity(n)
                            jpegRemaining = n
                            state = .readingJPEG
                        } else {
                            // Content-Length 없음 — 일반적 mjpg-streamer 아님. 안전한
                            // fallback: boundary 다시 검색 (frame 1개 skip).
                            state = .seekingBoundary
                            window.removeAll(keepingCapacity: true)
                        }
                        headerBytes.removeAll(keepingCapacity: true)
                    }

                case .readingJPEG:
                    jpegBytes.append(byte)
                    jpegRemaining -= 1
                    if jpegRemaining <= 0 {
                        // 한 frame 완성.
                        let frameData = Data(jpegBytes)
                        await deliverFrame(data: frameData)
                        jpegBytes.removeAll(keepingCapacity: true)
                        state = .seekingBoundary
                        window.removeAll(keepingCapacity: true)
                    }
                }
            }
        } catch is CancellationError {
            // ok — 호출자가 stop 또는 task cancel.
        } catch {
            phase = .failed(.from(error: error))
        }
    }

    // MARK: - Frame delivery

    private func deliverFrame(data: Data) async {
        guard let frame = NSImage(data: data) else {
            // 디코딩 실패 1 frame 은 skip — stream 자체는 계속.
            return
        }
        image = frame
        framesReceived += 1
        lastFrameAt = Date()

        if detectionEnabled {
            lastDetection = BallVision.detect(in: frame)
            if let preset = hsvPreset {
                multiColorDetections = MultiColorVision.detectAll(in: frame, preset: preset)
            } else {
                multiColorDetections = MultiColorVision.detectAll(in: frame)
            }
        } else {
            if lastDetection != nil { lastDetection = nil }
            if !multiColorDetections.isEmpty { multiColorDetections = [] }
        }
    }

    // MARK: - Header parsing helpers

    /// Content-Type 값에서 boundary 토큰 추출.
    ///
    /// 예: `"multipart/x-mixed-replace; boundary=boundarydonotcross"` → `"boundarydonotcross"`
    /// 또는 `"multipart/x-mixed-replace;boundary=\"frame\""` → `"frame"`
    static func boundary(fromContentType ct: String) -> String? {
        let lower = ct.lowercased()
        guard lower.contains("multipart/x-mixed-replace") else { return nil }
        guard let r = ct.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var raw = String(ct[r.upperBound...])
        // params 분리 (다음 `;` 까지).
        if let semi = raw.firstIndex(of: ";") {
            raw = String(raw[..<semi])
        }
        // 양 끝 quote / whitespace 제거.
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"\t \r\n"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 헤더 블록에서 `Content-Length` 값 추출.
    static func contentLength(fromHeaders headers: String) -> Int? {
        for line in headers.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let n = Int(value), n > 0, n < 50_000_000 {
                return n
            }
        }
        return nil
    }

    /// `window` 의 마지막 N byte 가 `suffix` 와 일치하는지.
    /// boundary 검색용 — O(suffix.count).
    static func windowEndsWith(_ window: [UInt8], suffix: [UInt8]) -> Bool {
        if window.count < suffix.count { return false }
        let start = window.count - suffix.count
        for i in 0..<suffix.count {
            if window[start + i] != suffix[i] { return false }
        }
        return true
    }
}
