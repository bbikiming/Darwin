import Foundation

/// 맥 마이크 체크 — 라이브 레벨 미터 + 실시간 음성 전사.
///
/// # 비유
///
/// 노래방 마이크에 대고 말하면 화면의 막대가 출렁이고(레벨), 자막이 따라 뜨는 것(전사)과 같다.
/// 두 가지를 동시에 보여줘 "소리가 잡히는가 + 맥이 이해하는가"를 한눈에 확인한다.
///
/// 로봇 마이크가 없을 때의 대안 경로. `MacMicCapturing` 을 주입받아 단위 테스트가 가능하다.
@MainActor
public final class MacMicCheckStore: ObservableObject {

    /// 현재 캡처 중인가.
    @Published public private(set) var isRecording = false
    /// 캡처가 한 번이라도 끝났는가(결과 표시용).
    @Published public private(set) var hasFinished = false
    /// 현재 버퍼 RMS 레벨 0...1.
    @Published public private(set) var level: Double = 0
    /// 현재 버퍼 피크 0...1.
    @Published public private(set) var peak: Double = 0
    /// 세션 중 관측된 최대 RMS(소리 인지 판정용).
    @Published public private(set) var maxLevel: Double = 0
    /// 세션 중 관측된 최대 피크.
    @Published public private(set) var peakObserved: Double = 0
    /// 인식된 텍스트(interim+final).
    @Published public private(set) var transcript: String = ""
    /// 권한/엔진 에러 메시지. nil = 정상.
    @Published public private(set) var errorMessage: String?

    private let capture: MacMicCapturing

    /// 프로덕션 init — 실 맥 마이크 캡처 사용.
    // [build-unblock 2026-05-31] @MainActor 명시 — AVMacMicCapture(@MainActor) 호출이
    // nonisolated convenience init 컨텍스트로 추론되어 빌드 실패하던 것을 해소(로직 불변).
    @MainActor
    public convenience init() {
        self.init(capture: AVMacMicCapture())
    }

    /// 테스트 init — mock 캡처 주입.
    public init(capture: MacMicCapturing) {
        self.capture = capture
    }

    /// 실제로 소리가 잡혔는지 — 관측 피크가 잡음 바닥을 넘는가.
    public var signalDetected: Bool { peakObserved > Self.signalThreshold }

    /// 전사 텍스트가 있는가.
    public var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let signalThreshold = 0.02

    // MARK: - Lifecycle

    public func start() {
        guard !isRecording else { return }
        reset()
        isRecording = true
        capture.setOnLevel { [weak self] rms, peak in self?.handleLevel(rms, peak) }
        capture.setOnTranscript { [weak self] text in self?.transcript = text }
        capture.setOnError { [weak self] message in self?.handleError(message) }
        do {
            try capture.start()
        } catch {
            handleError("마이크 시작 실패: \(error.localizedDescription)")
        }
    }

    public func stop() {
        guard isRecording else { return }
        isRecording = false
        hasFinished = true
        capture.stop()
    }

    /// 토글 — 녹음 중이면 정지, 아니면 시작.
    public func toggle() {
        if isRecording { stop() } else { start() }
    }

    // MARK: - 콜백 처리

    private func handleLevel(_ rms: Double, _ peak: Double) {
        let clampedRMS = min(max(rms, 0), 1)
        let clampedPeak = min(max(peak, 0), 1)
        level = clampedRMS
        self.peak = clampedPeak
        maxLevel = max(maxLevel, clampedRMS)
        peakObserved = max(peakObserved, clampedPeak)
    }

    private func handleError(_ message: String) {
        errorMessage = message
        isRecording = false
        hasFinished = true
    }

    private func reset() {
        level = 0
        peak = 0
        maxLevel = 0
        peakObserved = 0
        transcript = ""
        errorMessage = nil
        hasFinished = false
    }
}
