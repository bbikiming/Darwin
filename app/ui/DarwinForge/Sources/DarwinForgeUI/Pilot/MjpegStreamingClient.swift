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
// v1.11.2 (2026-05-18): CI Swift toolchain (5.9 추정) 호환 — `@preconcurrency`
// conformance attribute 가 5.10+ 에서만 지원되며 로컬에서도 "has no effect" warning
// 만 발생. URLSessionDataDelegate 의 nonisolated 호출은 이미 Swift 5 부터 호환.
@MainActor
public final class MjpegStreamingClient: NSObject, ObservableObject, URLSessionDataDelegate {
    public enum Phase: Equatable {
        case idle
        case connecting
        case live
        case failed(CameraFailureReason)
    }

    @Published public private(set) var image: NSImage?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var framesReceived: Int = 0
    /// **J9 (2026-06-11)** — 디코드/표시가 밀려 스킵된 frame 수(stale-view 방지 관측).
    /// 추출 seq 와 표시 seq 의 간격으로 집계. 0 이면 코얼레싱 드롭 없음.
    @Published public private(set) var droppedFrameCount: Int = 0
    /// J9 — 마지막으로 표시한 frame 의 추출 seq. 간격 = 코얼레싱으로 버린 frame.
    private var lastDeliveredSeq: UInt64?
    @Published public private(set) var lastFrameAt: Date?
    /// 마지막 frame 의 ball detection (snapshot client API 와 동일).
    @Published public private(set) var lastDetection: BallVision.Detection?
    /// 마지막 frame 의 multi-color detection (Phase D2).
    @Published public private(set) var multiColorDetections: [MultiColorVision.Detection] = []
    /// detection 실행 여부 — false 면 lastDetection 항상 nil.
    public var detectionEnabled: Bool = true
    /// Multi-color HSV preset — Phase E. nil 이면 ROBOTIS default 사용.
    public var hsvPreset: VisionHsvPreset?

    /// 2026-05-17 T3.4 chunk parser: URLSession 은 delegate 기반으로 생성.
    /// session 자체는 init 후 immutable, URLSession 은 thread-safe → nonisolated
    /// 접근 안전 (runStream 이 background task 에서 호출).
    private nonisolated(unsafe) var session: URLSession!
    private var task: Task<Void, Never>?
    private var endpoint: PilotCameraEndpoint?
    /// dataTask 보관 — `stop()` 시 즉시 cancel (Swift Task + URLSessionDataTask 둘 다).
    private var dataTask: URLSessionDataTask?

    // MARK: - URLSessionDataDelegate plumbing (T3.4 — 2026-05-17)
    //
    // 종전 byte-by-byte AsyncBytes (30fps × 50KB = 1.5M await/sec, 추정 15-20% CPU)
    // → URLSessionDataDelegate 가 Data chunk 단위 전달 → AsyncStream<Data> → chunk
    // parser. await 횟수 1.5M/sec → ~30/sec (chunk 빈도) 로 절감.
    //
    // delegate methods 는 `nonisolated` (URLSession 이 background queue 에서 호출).
    // continuation 은 main actor 격리 우회 위해 `nonisolated(unsafe)`. 단일 stream
    // 인스턴스만 활성 (start() 가 stop() 호출 후 새 stream 시작) — race 없음.

    /// Chunk producer — delegate didReceive 가 yield, runStream 이 소비.
    private nonisolated(unsafe) var chunkContinuation: AsyncStream<Data>.Continuation?
    /// Response producer — delegate didReceive response 가 resume, runStream 이 await.
    private nonisolated(unsafe) var responseContinuation: CheckedContinuation<HTTPURLResponse?, Never>?

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = false
        // delegate queue — serial (maxConcurrentOperationCount = 1) → didReceive
        // callback 순서 보장 (response 먼저, data 그 후, completion 마지막).
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// 테스트용 — 외부 session 주입.
    public init(session: URLSession) {
        super.init()
        self.session = session
    }

    deinit {
        task?.cancel()
        chunkContinuation?.finish()
        responseContinuation?.resume(returning: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - URLSessionDataDelegate

    nonisolated public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                       didReceive response: URLResponse,
                                       completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseContinuation?.resume(returning: response as? HTTPURLResponse)
        responseContinuation = nil
        completionHandler(.allow)
    }

    nonisolated public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                       didReceive data: Data) {
        chunkContinuation?.yield(data)
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                       didCompleteWithError error: Error?) {
        chunkContinuation?.finish()
        chunkContinuation = nil
        // response 가 안 왔는데 task 완료 (예: connection refused) → nil 로 resume.
        responseContinuation?.resume(returning: nil)
        responseContinuation = nil
    }

    /// 스트림 시작.
    ///
    /// **Codex HIGH fix (2026-05-16)**: 종전 `self.endpoint == endpoint && task != nil`
    /// no-op 조건이 `runStream` 종료 후에도 `task` 가 nil 안 됐을 때 재연결 버튼을
    /// 막아버림 (failed phase 에서도 같은 endpoint 재시도 무력화). 새 guard:
    /// **`.connecting` / `.live` 일 때만 no-op**. idle / failed 는 새 task 생성.
    public func start(endpoint: PilotCameraEndpoint) {
        // 활성 stream 중복 시도만 차단. failed / idle 상태는 명시 재시도 허용.
        if self.endpoint == endpoint, task != nil {
            switch phase {
            case .connecting, .live: return
            case .idle, .failed: break
            }
        }

        stop(resetImage: false)
        self.endpoint = endpoint
        phase = .connecting

        task = Task { [weak self] in
            guard let self else { return }
            await self.runStream(endpoint: endpoint)
            // Codex HIGH fix: 자연 종료 (정상/에러/cancel) 시 task 변수 정리 — 다음
            // start() 가 새 task 생성 가능. 미정리 시 같은 endpoint 재연결 막힘.
            self.task = nil
        }
    }

    public func stop(resetImage: Bool = true) {
        // 2026-05-17 T3.4 강화: Swift Task + URLSessionDataTask + chunk continuation
        // 모두 정리.
        // - task.cancel(): chunk for-await 가 Task.isCancelled 감지 후 break
        // - dataTask.cancel(): TCP connection 즉시 drop → delegate didCompleteWithError 호출
        // - chunkContinuation.finish(): for-await chunks 자연 종료 (race 가드)
        task?.cancel()
        task = nil
        dataTask?.cancel()
        dataTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        endpoint = nil
        phase = .idle
        framesReceived = 0
        droppedFrameCount = 0
        lastDeliveredSeq = nil
        lastFrameAt = nil
        lastDetection = nil
        multiColorDetections = []
        if resetImage { image = nil }
    }

    // MARK: - Stream loop (background)

    /// **2026-05-17 T3.4 chunk parser refactor**: byte-by-byte AsyncBytes →
    /// URLSessionDataDelegate + AsyncStream<Data>. 30fps × 50KB 스트림에서 1.5M
    /// await/sec → ~30/sec 으로 절감 (chunk 빈도).
    ///
    /// 흐름:
    ///   1. AsyncStream<Data> + responseContinuation 셋업 (delegate callback 대상)
    ///   2. dataTask 생성 + resume → delegate 가 response/chunks/error 전달
    ///   3. response await → header 검증 (200..<300, multipart boundary)
    ///   4. chunks 소비 → parseFramesChunked 가 chunk 누적 + boundary 검색
    ///   5. 정상 종료 / cancel 시 chunkContinuation.finish() 자동 호출 (delegate
    ///      didCompleteWithError 안)
    nonisolated private func runStream(endpoint: PilotCameraEndpoint) async {
        guard let url = endpoint.streamURL else {
            await reportPhase(.failed(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // AsyncStream<Data> 셋업 — delegate didReceive 가 yield.
        let (chunks, chunkCont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.chunkContinuation = chunkCont

        // Response continuation 셋업 — delegate didReceive response 가 resume.
        let response: HTTPURLResponse? = await withCheckedContinuation { cont in
            self.responseContinuation = cont
            let task = session.dataTask(with: request)
            Task { @MainActor [weak self] in self?.storeDataTask(task) }
            task.resume()
        }

        defer {
            // runStream 종료 시 dataTask 정리.
            Task { @MainActor [weak self] in self?.dataTask = nil }
            chunkCont.finish()
            self.chunkContinuation = nil
        }

        // task 가 response 받기 전 cancel / fail 한 경우 — nil response.
        guard let http = response else {
            if !Task.isCancelled {
                await reportPhase(.failed(.other("응답 받기 실패 — 연결 끊김")))
            } else {
                await reportPhase(.idle)
            }
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            await reportPhase(.failed(.httpStatus(http.statusCode)))
            return
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let boundary = Self.boundary(fromContentType: contentType) else {
            await reportPhase(.failed(.decodeFailed))
            return
        }

        await reportPhase(.live)
        await parseFramesChunked(chunks: chunks, boundary: boundary)
        if !Task.isCancelled {
            await reportPhase(.idle)
        }
    }

    /// MainActor hop helper — nonisolated background 가 `@Published phase` 갱신용.
    /// 2026-05-17 Major#1: `@MainActor` 명시 — Swift 6 strict concurrency 대비.
    @MainActor
    private func reportPhase(_ newValue: Phase) {
        self.phase = newValue
    }

    /// MainActor hop helper — nonisolated background 가 `dataTask` 보관용.
    /// 2026-05-17 Major#1: `@MainActor` 명시.
    @MainActor
    private func storeDataTask(_ t: URLSessionDataTask) {
        self.dataTask = t
    }

    // MARK: - Multipart parser (background)

    private enum ParseState {
        case seekingBoundary
        case readingHeaders
        case readingJPEG
    }

    /// 2026-05-17 T3.4 chunk parser — byte-by-byte → chunk-based.
    ///
    /// 입력: `AsyncStream<Data>` (delegate 가 보내는 raw byte chunks).
    /// 알고리즘:
    ///   - rollingBuffer: chunk 들 누적 (state 진행 중 처리 안 된 잔여).
    ///   - state machine: seekingBoundary → readingHeaders → readingJPEG.
    ///   - boundary 검색: chunk 경계 넘어서도 동작 — buffer 안에서 찾기.
    ///   - jpegRemaining 만큼 bulk drain (한 chunk 안에 전체 또는 여러 chunk).
    ///
    /// 안전:
    ///   - rollingBuffer 크기 cap = 8 MB (5 MB jpeg + 보호 마진). 초과 시 reset.
    ///   - chunk 안에 boundary / headers / jpegPayload 모두 가능 — 한 chunk 처리
    ///     중 multiple frame 완성 가능.
    ///   - cancel: chunkContinuation.finish() → for await 자연 종료.
    nonisolated private func parseFramesChunked(chunks: AsyncStream<Data>, boundary: String) async {
        let boundaryDelim = Data("--\(boundary)".utf8)
        let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let maxBufferSize = 8 * 1024 * 1024  // 8 MB hard cap

        // **J9 (2026-06-11) 프레임 코얼레싱**: 추출(빠름)과 디코드/표시(느림)를 분리.
        // 추출된 frame 을 bufferingNewest(1) 스트림에 yield → 디코드가 밀리면 중간
        // frame 이 자동 drop 되고 최신 1장만 디코드된다("낮은 fps 의 현재 영상 > 높은
        // fps 의 과거 영상" — 텔레옵 stale-view 제거). seq 태그로 표시측에서 드롭 수 집계.
        let (frames, framesCont) =
            AsyncStream<(seq: UInt64, data: Data)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let deliverTask = Task { [weak self] in
            for await frame in frames {
                if Task.isCancelled { break }
                await self?.deliverFrame(seq: frame.seq, data: frame.data)
            }
        }
        var frameSeq: UInt64 = 0

        var state: ParseState = .seekingBoundary
        var buffer = Data()
        var jpegRemaining: Int = 0

        parseLoop: for await chunk in chunks {
            if Task.isCancelled { break parseLoop }
            buffer.append(chunk)

            // 한 chunk 안에 여러 frame 완성 가능 → 종료 조건까지 inner loop.
            innerLoop: while !buffer.isEmpty {
                if Task.isCancelled { break parseLoop }

                switch state {
                case .seekingBoundary:
                    // buffer 안에서 boundary 검색.
                    if let range = buffer.range(of: boundaryDelim) {
                        // boundary 직후부터 다음 단계로. 이전 byte 모두 폐기 (이전 frame
                        // tail 또는 stream prelude).
                        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        state = .readingHeaders
                    } else {
                        // boundary 미발견 — buffer 끝까지 keep, 다음 chunk 대기.
                        // 단 buffer 크기 cap 초과 시 앞쪽 폐기 (boundary 가 마지막 N byte
                        // 안에 있을 가능성 유지).
                        if buffer.count > maxBufferSize {
                            let dropCount = buffer.count - boundaryDelim.count * 2
                            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: dropCount))
                        }
                        break innerLoop  // 다음 chunk 받기.
                    }

                case .readingHeaders:
                    // CRLFCRLF 검색 — 헤더 종료.
                    if let range = buffer.range(of: crlf2) {
                        // 헤더 영역 추출 + Content-Length 파싱.
                        let headerData = buffer.subdata(in: buffer.startIndex..<range.upperBound)
                        let headerStr = String(decoding: headerData, as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        if let n = Self.contentLength(fromHeaders: headerStr) {
                            jpegRemaining = n
                            state = .readingJPEG
                        } else {
                            // Content-Length 없음 → frame 1개 skip + boundary 재검색.
                            state = .seekingBoundary
                        }
                    } else if buffer.count > 4096 {
                        // 헤더가 비정상적으로 김 — boundary 재검색.
                        state = .seekingBoundary
                    } else {
                        break innerLoop  // 더 받기.
                    }

                case .readingJPEG:
                    // jpegRemaining 만큼 bulk drain. 한 chunk 안에 전체 또는 분할.
                    if buffer.count >= jpegRemaining {
                        let frameData = buffer.subdata(in: buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: jpegRemaining))
                        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: jpegRemaining))
                        jpegRemaining = 0
                        // J9: 한 frame 완성 — 코얼레싱 스트림에 yield(밀리면 자동 drop).
                        // await deliverFrame 직접 호출이 아니므로 디코드가 파싱을 막지 않음.
                        frameSeq += 1
                        framesCont.yield((seq: frameSeq, data: frameData))
                        state = .seekingBoundary
                    } else {
                        // buffer 가 jpegRemaining 보다 작음 — 다음 chunk 대기.
                        break innerLoop
                    }
                }
            }
        }

        // J9: 스트림 종료(또는 취소) — frame 스트림을 닫고 deliver 를 마무리한다.
        // 정상 종료면 버퍼에 남은 최신 frame 까지 표시되도록 deliverTask 를 await(배수).
        // 취소면 즉시 cancel — late publish 방지.
        framesCont.finish()
        if Task.isCancelled {
            deliverTask.cancel()
        } else {
            await deliverTask.value
        }
    }

    #if DEBUG
    /// **테스트용 hook (J9)** — multipart body 1개를 단일 chunk 로 parseFramesChunked 에
    /// 주입. frame 추출→deliver→publish 배선과 droppedFrameCount 회계를 검증.
    nonisolated func _testFeedMultipart(_ body: Data, boundary: String) async {
        let (chunks, cont) = AsyncStream<Data>.makeStream()
        cont.yield(body)
        cont.finish()
        await parseFramesChunked(chunks: chunks, boundary: boundary)
    }
    #endif

    // MARK: - Frame delivery (background decode + detection, MainActor publish)

    /// JPEG → CGImage 디코딩 + vision detection 모두 background. main hop 은
    /// publish 1 회 (NSImage 래핑 + `@Published` 갱신).
    ///
    /// **CGImage 경로**: `NSImage(data:)` / `BallVision.detect(in: NSImage)` 등 NSImage
    /// 버전 API 는 `@MainActor` 격리됨 (Apple Cocoa Drawing thread-safety 보장 위해).
    /// CGImage / CFData / CGImageSource 는 nonisolated thread-safe — background 사용 가능.
    /// background 에서 CGImage 디코딩 + detection → main 에서 NSImage 래핑 후 binding.
    nonisolated private func deliverFrame(seq: UInt64, data: Data) async {
        // 2026-05-17 H1 fix: CGImage decode 를 helper 로 분리.
        // 종전엔 `CGImageSource` (line 320) 가 await 2 번 사이 stack 에 보관 됨 →
        // 30fps × 2 client 시 ImageIO 내부 buffer 충돌 / ARC pressure 가능. helper
        // return 시점에 source ARC release → 다음 await 전 정리.
        guard let cgImage = Self.decodeCGImage(from: data) else {
            // 디코딩 실패 1 frame 은 skip — stream 자체는 계속.
            return
        }

        // detection 설정 main 에서 snapshot — stream 중 toggle / preset 변경 반영.
        let snapshot = await readDetectionSnapshot()

        let lastDet: BallVision.Detection?
        let multiDets: [MultiColorVision.Detection]
        if snapshot.enabled {
            lastDet = BallVision.detect(in: cgImage)
            if let preset = snapshot.preset {
                multiDets = MultiColorVision.detectAll(in: cgImage, preset: preset)
            } else {
                multiDets = MultiColorVision.detectAll(in: cgImage)
            }
        } else {
            lastDet = nil
            multiDets = []
        }

        await publishFrame(seq: seq, cgImage: cgImage, detection: lastDet, multi: multiDets)
    }

    /// MainActor hop — `detectionEnabled` / `hsvPreset` snapshot 읽기.
    /// 2026-05-17 Major#1: `@MainActor` 명시.
    @MainActor
    private func readDetectionSnapshot() -> (enabled: Bool, preset: VisionHsvPreset?) {
        (detectionEnabled, hsvPreset)
    }

    /// MainActor hop — CGImage → NSImage 래핑 + `@Published` frame state 갱신.
    /// 2026-05-17 Major#1: `@MainActor` 명시.
    @MainActor
    private func publishFrame(
        seq: UInt64,
        cgImage: CGImage,
        detection: BallVision.Detection?,
        multi: [MultiColorVision.Detection]
    ) {
        // J9: 추출 seq 간격 = 코얼레싱으로 버린(stale) frame 수.
        if let last = lastDeliveredSeq, seq > last + 1 {
            droppedFrameCount += Int(seq - last - 1)
        }
        lastDeliveredSeq = seq
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        self.image = NSImage(cgImage: cgImage, size: size)
        framesReceived += 1
        lastFrameAt = Date()
        lastDetection = detection
        multiColorDetections = multi
    }

    // MARK: - Header parsing helpers

    /// Content-Type 값에서 boundary 토큰 추출.
    ///
    /// 예: `"multipart/x-mixed-replace; boundary=boundarydonotcross"` → `"boundarydonotcross"`
    /// 또는 `"multipart/x-mixed-replace;boundary=\"frame\""` → `"frame"`
    nonisolated static func boundary(fromContentType ct: String) -> String? {
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
    nonisolated static func contentLength(fromHeaders headers: String) -> Int? {
        // **버그 수정 (2026-06-11)**: 종전 `split(whereSeparator: { $0=="\n"||$0=="\r" })`
        // 은 Swift 가 CRLF("\r\n")를 단일 grapheme Character 로 취급해 "\r" 도 "\n" 도
        // 아니므로 표준 CRLF 헤더를 한 줄로 보고 Content-Length 를 못 찾았다(→ 모든
        // frame skip → 텔레옵 영상 미표시). scalar 단위로 분리하는 CharacterSet.newlines
        // 로 교체해 CRLF/LF 모두 정상 파싱.
        for line in headers.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            // Codex LOW fix (2026-05-16): 50MB → 5MB.
            // ROBOTIS 카메라 320×240 quality 80 ≈ 수십~수백 KB. 5MB 면 1280×720
            // quality 100 까지도 안전 + 악의 server / 손상 stream OOM 방어.
            if let n = Int(value), n > 0, n < 5_000_000 {
                return n
            }
        }
        return nil
    }

    /// JPEG `Data` → `CGImage` 동기 decode helper.
    /// 2026-05-17 H1 fix: `CGImageSource` 가 await 사이 stack 보관 안 되게 분리.
    /// 함수 return 시점에 source ARC release → 30fps × multi-client GC pressure 차단.
    nonisolated private static func decodeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
        // `source` ARC release at function return — caller holds only CGImage ref.
    }

    // 2026-05-17 T3.4: windowEndsWith helper 제거 — chunk parser 는 Data.range(of:)
    // 로 boundary/CRLFCRLF 검색 (Swift 표준 라이브러리, KMP-like). byte-by-byte
    // suffix 비교 helper 불필요.
}
