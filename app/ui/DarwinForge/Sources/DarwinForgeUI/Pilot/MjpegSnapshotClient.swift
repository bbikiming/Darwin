import AppKit
import ForgeCore
import Foundation

/// ROBOTIS official camera tutorial / demo compatible endpoint.
///
/// Official source pattern:
/// - server: `mjpg_streamer` on TCP 8080
/// - frame: `GET /?action=snapshot&n=<sequence>`
/// - browser demo: repeatedly inserts a new image layer after each `onload`
public struct PilotCameraEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 8080) {
        self.host = Self.normalizeHost(host)
        self.port = port
    }

    public var pageURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        return components.url
    }

    public func snapshotURL(sequence: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "action", value: "snapshot"),
            URLQueryItem(name: "n", value: String(sequence))
        ]
        return components.url
    }

    /// mjpg-streamer 표준 stream endpoint — multipart/x-mixed-replace 실시간 MJPEG.
    /// 종전 snapshot 폴링 (4 fps) 대비 30 fps 급 실시간 재생.
    public var streamURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "action", value: "stream")
        ]
        return components.url
    }

    public var displayName: String {
        "\(host):\(port)"
    }

    private static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "192.168.123.1" }

        if let url = URL(string: value),
           let host = url.host,
           url.scheme == "http" || url.scheme == "https" {
            return host
        }

        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if value.filter({ $0 == ":" }).count == 1,
           let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        return value.isEmpty ? "192.168.123.1" : value
    }
}

/// 카메라 endpoint 실패 사유 — Sprint 17 UX 권고 (2026-05-13).
///
/// `Phase.failed(String)` 의 raw localizedDescription 은 사용자에게 의미 없음
/// ("Could not connect to the server.", "The request timed out." 등). 본 enum
/// 으로 URLError 코드 / HTTP status / 디코딩 실패를 카테고리화하여 PilotCameraView
/// 가 "8080 닫힘", "응답 없음", "포트 다름" 같이 행동 가능한 라벨을 보여준다.
public enum CameraFailureReason: Equatable, Sendable {
    /// 포트 8080 이 닫혀 있음 (ECONNREFUSED). camera_tutorial 미실행이 거의 확실.
    case portClosed
    /// 호스트 자체 응답 없음 (timeout / unreachable). 네트워크/IP 문제 가능.
    case hostUnreachable
    /// 응답 시간 초과 (서버 busy / 카메라 응답 지연).
    case timeout
    /// HTTP 응답이 200..<300 이 아닌 경우.
    case httpStatus(Int)
    /// JPEG 디코딩 실패 — endpoint 가 mjpg-streamer 가 아닐 가능성.
    case decodeFailed
    /// URL 생성 실패 (호스트 형식 오류 등).
    case invalidURL
    /// 그 외 (기타 URLError / 시스템 오류). localizedDescription 보존.
    case other(String)

    /// 사용자에게 보여줄 짧은 라벨 — chip / subtitle 용 (8자 이내 권장).
    public var shortLabel: String {
        switch self {
        case .portClosed:        return "포트 닫힘"
        case .hostUnreachable:   return "응답 없음"
        case .timeout:           return "타임아웃"
        case .httpStatus(let c): return "HTTP \(c)"
        case .decodeFailed:      return "디코딩 실패"
        case .invalidURL:        return "URL 오류"
        case .other:             return "오류"
        }
    }

    /// 사용자에게 보여줄 상세 설명 — placeholder / panel subtitle 용.
    public var detailMessage: String {
        switch self {
        case .portClosed:
            return "8080 포트가 닫혀 있어요. 로봇에서 카메라 데모를 시작해 주세요."
        case .hostUnreachable:
            return "로봇 호스트에서 응답이 없어요. 네트워크 또는 IP를 확인해 주세요."
        case .timeout:
            return "카메라 응답이 너무 느려요. 카메라 데모를 재시작해 주세요."
        case .httpStatus(let c):
            return "예상 못한 HTTP 응답 (\(c)). 다른 서비스가 8080을 잡고 있는지 확인해 주세요."
        case .decodeFailed:
            return "JPEG 디코딩 실패. mjpg_streamer 또는 camera_tutorial 가 맞는지 확인해 주세요."
        case .invalidURL:
            return "카메라 주소 형식이 잘못됐어요. 연결 호스트를 확인해 주세요."
        case .other(let raw):
            return "카메라 통신 오류: \(raw)"
        }
    }

    /// 사용자가 다음 어디로 가야 해결되는지 — 단축 버튼 라벨.
    public var suggestedActionLabel: String? {
        switch self {
        case .portClosed, .timeout, .decodeFailed: return "원격 명령으로 가기"
        case .hostUnreachable:                     return "연결 마법사로 가기"
        case .httpStatus, .invalidURL, .other:     return nil
        }
    }

    /// URLError / HTTPURLResponse → 본 카테고리로 분류.
    public static func from(error: any Error) -> CameraFailureReason {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost:
                return .portClosed
            case .timedOut:
                return .timeout
            case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                 .networkConnectionLost, .resourceUnavailable:
                return .hostUnreachable
            default:
                return .other(urlError.localizedDescription)
            }
        }
        return .other(error.localizedDescription)
    }
}

@MainActor
public final class MjpegSnapshotClient: ObservableObject {
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
    /// 마지막 frame 의 ball detection 결과 — Phase C2 (Sprint 18).
    /// `BallVision.detect` 가 매 frame 마다 호출. 검출 없거나 비활성이면 nil.
    @Published public private(set) var lastDetection: BallVision.Detection?
    /// 마지막 frame 의 multi-color blob 결과 — Phase D2 (Sprint 18).
    /// 주황/빨강/노랑/파랑 4색 동시 검출. 색깔별 검출 안 되면 배열에 누락.
    @Published public private(set) var multiColorDetections: [MultiColorVision.Detection] = []
    /// detection 실행 여부 — false 면 lastDetection 항상 nil. PilotCameraView 가 제어.
    public var detectionEnabled: Bool = true
    /// Multi-color HSV preset — Phase E. nil 이면 ROBOTIS default 사용.
    public var hsvPreset: VisionHsvPreset?

    private let session: URLSession
    private var task: Task<Void, Never>?
    private var endpoint: PilotCameraEndpoint?

    public convenience init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        config.waitsForConnectivity = false
        self.init(session: URLSession(configuration: config))
    }

    public init(session: URLSession) {
        self.session = session
    }

    deinit {
        task?.cancel()
    }

    public func start(endpoint: PilotCameraEndpoint) {
        if self.endpoint == endpoint, task != nil { return }

        stop(resetImage: false)
        self.endpoint = endpoint
        phase = .connecting

        task = Task { [weak self] in
            guard let self else { return }
            var sequence = 0
            while !Task.isCancelled {
                sequence += 1
                await self.fetchFrame(endpoint: endpoint, sequence: sequence)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
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

    private func fetchFrame(endpoint: PilotCameraEndpoint, sequence: Int) async {
        guard let url = endpoint.snapshotURL(sequence: sequence) else {
            phase = .failed(.invalidURL)
            return
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                phase = .failed(.httpStatus(code))
                return
            }
            guard let frame = NSImage(data: data) else {
                phase = .failed(.decodeFailed)
                return
            }

            image = frame
            framesReceived += 1
            lastFrameAt = Date()
            phase = .live
            // Phase C2 + D2: 새 frame 마다 ball + multi-color detection.
            // CGImage 변환 + FFI / HSV mask 비용 ~10-30ms (256px) — 250ms polling 안에서 OK.
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
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(.from(error: error))
        }
    }
}
