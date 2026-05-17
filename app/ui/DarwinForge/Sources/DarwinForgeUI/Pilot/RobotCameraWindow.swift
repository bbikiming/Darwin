import AppKit
import SwiftUI

/// 로봇 카메라 floating window — 어떤 메뉴 / 모드에서든 동시 표시 가능한 별도 윈도우.
///
/// # 사용 시나리오
///
/// - 모션 스튜디오 / WalkLab / Studio 등 다른 메뉴 작업 도중 카메라 실시간 stream
///   동시 확인.
/// - `forge-core::motion::player` 가 Dynamixel bus 점유 (모션 송출) 와 별개 채널 —
///   카메라 stream 은 robot 측 ROBOTIS demo 의 8080 HTTP 서버 (mjpg-streamer)
///   가 제공. demo 가 살아있는 한 stream 은 motion 과 동시 호환.
/// - "한 번에 중복 demo 불가" 제약: ROBOTIS demo binary 는 단일 instance — Mac
///   측이 motion_play 보내도 demo 는 계속 동작 (Dynamixel write 만 받음). 사용자가
///   ⌘6 으로 demo 토글한 상태에서 본 window 는 stream 호출만 → motion 송출 호환.
///
/// # 단축키
///
/// ⌘⌥C — 카메라 윈도우 열기 / 활성화 (`DarwinForgeApp.commands` 의
/// `OpenCameraWindowButton`). ⌘⇧C 는 "자동 USB 연결" 단축키 점유로 회피.
///
/// # UX
///
/// - 진입 시 자동 연결 X — 사용자가 "카메라 연결" 버튼 명시 클릭 시만 stream 시작.
/// - host 입력 필드 (기본 192.168.123.1) + 시작 / 정지 / 재연결 버튼.
/// - 실시간 frames / fps / 마지막 frame 시각 메타데이터 표시.
/// - 에러 시 명확한 한글 안내 (`CameraFailureReason.shortLabel`).
public struct RobotCameraWindow: View {
    @StateObject private var client = MjpegStreamingClient()
    @AppStorage("df.pilot.camera.window.host") private var host: String = "192.168.123.1"
    @AppStorage("df.pilot.camera.window.port") private var port: Int = 8080
    /// 부드러운 fps 평균 — 0.5초 sliding.
    @State private var fps: Double = 0
    @State private var fpsTimer: Task<Void, Never>?
    /// 직전 frames count — fps 계산용.
    @State private var lastFramesCount: Int = 0
    @State private var lastFpsSampleAt: Date = Date()

    public init() {}

    public var body: some View {
        VStack(spacing: DFSpace.none) {
            controlBar
            Divider()
            cameraStage
            Divider()
            statusBar
        }
        .frame(minWidth: 480, idealWidth: 720, maxWidth: .infinity,
               minHeight: 360, idealHeight: 540, maxHeight: .infinity)
        .background(DFColor.canvas)
        .onAppear {
            // Codex 권고 (2026-05-16): RobotCameraWindow 는 detection overlay 사용 안
            // 함 — `BallVision` / `MultiColorVision` 계산 비용 (~10-30ms/frame) 절약.
            // PilotCameraView 는 detection 활성 유지 (HUD overlay).
            client.detectionEnabled = false
            startFpsTimer()
        }
        .onDisappear {
            cleanupOnHide()
        }
        // 2026-05-17 A6 fix: macOS `Window` scene 의 close 가 view onDisappear 만으로
        // 항상 trigger 되지 않을 수 있음 (SwiftUI scene state 보존 패턴). NSWindow
        // willCloseNotification 직접 observe 로 이중 안전망 — TCP stream / fpsTimer
        // background leak 차단.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            cleanupOnHide()
        }
    }

    // MARK: - Control bar (host + start/stop)

    private var controlBar: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "video.fill")
                .font(DFFont.sectionBody)
                .foregroundStyle(connectionTint)

            VStack(alignment: .leading, spacing: DFSpace.micro) {
                Text("로봇 카메라")
                    .font(DFFont.sectionBody)
                    .foregroundStyle(DFColor.textPrimary)
                Text(subtitleText)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }

            Spacer()

            // host:port 입력.
            HStack(spacing: DFSpace.xs) {
                TextField("호스트", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .font(DFFont.monoCaption)
                    .disabled(isLive)
                    .accessibilityLabel("카메라 호스트 주소")
                    .accessibilityHint("IPv4 또는 호스트명 — 기본 192.168.123.1")
                Text(":")
                    .foregroundStyle(DFColor.textSecondary)
                    .accessibilityHidden(true)
                TextField("포트", value: $port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(DFFont.monoCaption)
                    .disabled(isLive)
                    .accessibilityLabel("카메라 포트")
                    .accessibilityHint("mjpg-streamer 표준 8080. 1024–65535 범위.")
            }

            // 연결 / 정지 / 재연결 버튼.
            if isLive {
                Button {
                    client.stop()
                } label: {
                    Label("정지", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(DFColor.danger)
                .accessibilityLabel("카메라 스트림 정지")
                .accessibilityHint("진행 중인 실시간 MJPEG 스트림 종료")
                .help("실시간 스트림 정지")
            } else {
                Button {
                    startStream()
                } label: {
                    Label(connectButtonLabel, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(DFColor.accent)
                .accessibilityLabel(connectButtonLabel == "재연결" ? "카메라 재연결" : "카메라 연결")
                .accessibilityHint("\(host):\(port) 에 multipart/x-mixed-replace MJPEG 스트림 시작")
                .help("\(host):\(port) 카메라 스트림 시작")
            }
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
        .background(DFColor.elev2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("카메라 컨트롤 바")
    }

    // MARK: - Camera stage (image / overlay)

    private var cameraStage: some View {
        ZStack {
            Color.black

            if let image = client.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .accessibilityLabel("실시간 카메라 frame — \(client.framesReceived) frame 수신")
            } else {
                waitingPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var waitingPlaceholder: some View {
        VStack(spacing: DFSpace.sm) {
            switch client.phase {
            case .idle:
                Image(systemName: "video.fill")
                    .font(.system(size: DFFontSize.s32))
                    .foregroundStyle(DFColor.textSecondary)
                Text("카메라 연결 대기")
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                Text("호스트: \(host):\(port)")
                    .font(DFFont.monoCaption)
                    .foregroundStyle(DFColor.textSecondary)
                Text("상단의 “연결” 버튼을 누르면 실시간 스트리밍을 시도합니다")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DFSpace.lg)
            case .connecting:
                ProgressView()
                    .controlSize(.regular)
                    .tint(DFColor.accent)
                Text("\(host):\(port) 에 연결 중…")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            case .live:
                // image 가 아직 도착 안 함 (첫 frame 대기).
                ProgressView()
                    .controlSize(.regular)
                    .tint(DFColor.success)
                Text("첫 frame 대기 중…")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DFFontSize.s32))
                    .foregroundStyle(DFColor.warning)
                Text(failureTitle(for: reason))
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                Text(reason.detailMessage)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DFSpace.lg)
                Button {
                    startStream()
                } label: {
                    Label("재연결 시도", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(DFColor.accent)
            }
        }
        .padding(DFSpace.lg)
    }

    // MARK: - Status bar (fps / frames / endpoint)

    private var statusBar: some View {
        HStack(spacing: DFSpace.md) {
            statusItem(label: "상태", value: phaseLabel, tint: connectionTint)
            statusItem(label: "수신 frame", value: "\(client.framesReceived)")
            statusItem(label: "실시간 fps", value: String(format: "%.1f", fps))
            if let last = client.lastFrameAt {
                statusItem(label: "마지막 frame",
                           value: Self.timeFormatter.string(from: last))
            }
            Spacer()
            Text("실시간 스트리밍 — multipart/x-mixed-replace")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
        .background(DFColor.elev2)
    }

    private func statusItem(label: String, value: String, tint: Color = DFColor.textPrimary) -> some View {
        HStack(spacing: DFSpace.xs) {
            Text(label)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Text(value)
                .font(DFFont.captionEmph.monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    // MARK: - Actions

    /// onDisappear / willClose 공통 정리 — idempotent.
    private func cleanupOnHide() {
        fpsTimer?.cancel()
        fpsTimer = nil
        client.stop(resetImage: false)
    }

    private func startStream() {
        // Codex MEDIUM fix (2026-05-16): fps 계산 변수 reset — 빠른 재시작 시 잔상값
        // 으로 fps 가 몇 초간 0 또는 옛 평균 잘못 표시되는 회귀 차단.
        fps = 0
        lastFramesCount = 0
        lastFpsSampleAt = Date()

        let endpoint = PilotCameraEndpoint(host: host, port: UInt16(clamping: port))
        client.start(endpoint: endpoint)
    }

    private func startFpsTimer() {
        fpsTimer?.cancel()
        lastFramesCount = client.framesReceived
        lastFpsSampleAt = Date()
        fpsTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                let now = Date()
                let dt = now.timeIntervalSince(lastFpsSampleAt)
                let frames = client.framesReceived
                let delta = max(0, frames - lastFramesCount)
                let instantFps = dt > 0 ? Double(delta) / dt : 0
                // exponential smoothing — 빠른 반응 + 흔들림 안정.
                fps = 0.5 * fps + 0.5 * instantFps
                lastFramesCount = frames
                lastFpsSampleAt = now
            }
        }
    }

    // MARK: - Helpers

    private var isLive: Bool {
        if case .live = client.phase { return true }
        if case .connecting = client.phase { return true }
        return false
    }

    private var connectButtonLabel: String {
        if case .failed = client.phase { return "재연결" }
        return "연결"
    }

    private var subtitleText: String {
        switch client.phase {
        case .idle:               return "연결 대기 — 사용자 명시 시작"
        case .connecting:         return "\(host):\(port) 연결 중"
        case .live:               return "\(host):\(port) · LIVE"
        case .failed(let reason): return "\(host):\(port) · \(reason.shortLabel)"
        }
    }

    private var phaseLabel: String {
        switch client.phase {
        case .idle:        return "대기"
        case .connecting:  return "연결 중"
        case .live:        return "수신 중 (LIVE)"
        case .failed:      return "오류"
        }
    }

    private var connectionTint: Color {
        switch client.phase {
        case .idle:        return DFColor.textSecondary
        case .connecting:  return DFColor.accent
        case .live:        return DFColor.success
        case .failed:      return DFColor.warning
        }
    }

    private func failureTitle(for reason: CameraFailureReason) -> String {
        switch reason {
        case .portClosed:      return "포트 8080 닫힘"
        case .hostUnreachable: return "호스트 응답 없음"
        case .timeout:         return "응답 시간 초과"
        case .httpStatus:      return "HTTP 오류"
        case .decodeFailed:    return "스트림 디코딩 실패"
        case .invalidURL:      return "URL 형식 오류"
        case .other:           return "연결 오류"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}
