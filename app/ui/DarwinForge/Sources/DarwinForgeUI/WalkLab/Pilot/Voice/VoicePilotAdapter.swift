import Foundation
import Observation
#if canImport(Speech)
import Speech
import AVFoundation
#endif

/// **v1.22.0 (2026-05-22) Phase 5 — 음성 인식 입력 source**.
///
/// Apple `Speech.framework` (`SFSpeechRecognizer`) 로 마이크 입력을 텍스트로 전사한 뒤
/// 한국어/영어 키워드를 spotting 해서 `WalkLabRCBridge` 에 정규화된 호출을 발화한다.
///
/// # 비유
///
/// 비행기 조종실의 voice activation 시스템 — 조종사가 "gear up" 외치면 동일하게 토글
/// 스위치를 누른 효과. 본 adapter 도 같은 원리 — 키보드 단축키 W / Space 와 동일한
/// bridge 메소드를 음성으로 호출.
///
/// # 의존 그래프
///
/// ```
///  마이크 → SFSpeechAudioBufferRecognitionRequest
///         ↓ (interim + final 결과)
///   VoiceRecognizing (protocol, 실 SF 또는 MockVoiceRecognizer)
///         ↓ onResult(text)
///   VoicePilotAdapter.handleRecognition (keyword match)
///         ↓
///   bridge.handleMotion(id:from:) / handleEmergency / handleRecovery
/// ```
///
/// # 키워드 매핑 (한/영 혼용)
///
/// | 키워드 (한) | 키워드 (영)         | bridge 호출                                  |
/// | ----------- | ------------------- | --------------------------------------------- |
/// | "걸어"      | "walk", "march"     | `handleMotion(id: "preset.march")`            |
/// | "정지"      | "stop", "idle"      | `handleMotion(id: "preset.idle")`             |
/// | "조깅"      | "jog"               | `handleMotion(id: "preset.jog")`              |
/// | "비상"      | "emergency"         | `handleEmergency`                             |
/// | "복구"      | "recover"           | `handleRecovery`                              |
///
/// # 안전 / 정책
///
/// - **마이크 권한**: `start()` 시 `SFSpeechRecognizer.requestAuthorization` + `AVAudioSession`
///   permission. 거부되면 `lastError` 에 사유 기록 후 silent fail.
/// - **Info.plist 필수**: `NSSpeechRecognitionUsageDescription` 키 등록. 미등록 시 OS 가
///   첫 권한 요청에서 crash.
/// - 알 수 없는 키워드는 silent — bridge 미호출 + `lastRecognized` 만 업데이트해서 UI 가
///   "들리긴 하나 매칭 없음" 시각화 가능.
/// - 키워드 매칭은 case-insensitive substring (자연어에서 "걸어줘" / "please walk now" 등
///   조사·문장 포함 대응).
///
/// # 테스트 가능성
///
/// `VoiceRecognizing` protocol 로 실 `SFSpeechRecognizer` 의존을 추상화 — `MockVoiceRecognizer`
/// 가 `simulate(_:)` 로 결과를 임의 enqueue 해 결정론적 단위 테스트 가능. CI / Mac 없는
/// 환경에서도 통과.
@MainActor
@Observable
public final class VoicePilotAdapter {

    // MARK: - 외부 의존성

    /// 약한 참조 — bridge 가 owner. adapter 가 bridge lifecycle 좌우 안 함.
    public weak var bridge: WalkLabRCBridge?

    /// 음성 인식 source 추상화 — 실 `SpeechFrameworkRecognizer` 또는 `MockVoiceRecognizer`.
    private let recognizer: VoiceRecognizing

    // MARK: - 관찰 가능 상태

    /// 가장 최근에 인식된 raw text (한/영 어느 쪽이든). nil = 아직 인식 없음.
    /// UI 가 "들린 말: ..." 표시 가능. 알 수 없는 키워드도 본 값엔 기록.
    public private(set) var lastRecognized: String?

    /// adapter 가 listen 중인가 (`start` 호출 후 `stop` 전).
    public private(set) var isListening: Bool = false

    /// 가장 최근 매칭된 키워드 라벨 (디버그 / 검증 용). 미매칭 = nil.
    public private(set) var lastMatchedKeyword: String?

    /// 권한 / 인식 엔진 에러 메시지. nil = 정상.
    public private(set) var lastError: String?

    // MARK: - Init

    /// Production init — 기본 `SpeechFrameworkRecognizer` 사용.
    public convenience init(bridge: WalkLabRCBridge?, locale: Locale = Locale(identifier: "ko-KR")) {
        self.init(bridge: bridge, recognizer: SpeechFrameworkRecognizer(locale: locale))
    }

    /// 테스트 init — `MockVoiceRecognizer` 등 임의 source 주입.
    public init(bridge: WalkLabRCBridge?, recognizer: VoiceRecognizing) {
        self.bridge = bridge
        self.recognizer = recognizer
    }

    // MARK: - Lifecycle

    /// 음성 인식 시작 — 마이크 권한 요청 + audio buffer 라이브 인식 start.
    /// 이미 listen 중이면 no-op.
    public func start() {
        guard !isListening else { return }
        isListening = true
        lastError = nil
        // callback 은 이미 @MainActor 격리 — recognizer 가 main 에서 호출 보장.
        // 실 SF impl 은 SFSpeechRecognizer.recognitionTask 콜백을 MainActor hop 후 발화.
        recognizer.setOnResult { [weak self] text in
            self?.handleRecognition(text)
        }
        recognizer.setOnError { [weak self] message in
            self?.handleError(message)
        }
        do {
            try recognizer.start()
        } catch {
            isListening = false
            lastError = "음성 인식 시작 실패: \(error.localizedDescription)"
        }
    }

    /// 음성 인식 중단 — audio engine stop + recognition task cancel. idempotent.
    public func stop() {
        guard isListening else { return }
        isListening = false
        recognizer.stop()
    }

    /// recognizer 에러 콜백 — listening flag 해제 + 메시지 기록.
    private func handleError(_ message: String) {
        lastError = message
        isListening = false
    }

    // **주의**: deinit 미정의 — `@MainActor` 클래스의 deinit 는 nonisolated 라
    // MainActor-isolated property 접근 불가. 정리는 stop() 에서 수행 — 호출자 책임.

    // MARK: - Keyword spotting

    /// recognizer 가 전사된 text 를 전달하면 본 메소드가 키워드 spotting + bridge 호출.
    /// 테스트 entry point — mock 이 simulate(_:) 호출 시 동일 경로.
    public func handleRecognition(_ text: String) {
        guard let bridge = bridge else { return }
        lastRecognized = text
        let lower = text.lowercased()
        // 우선순위: 비상 > 복구 > motion 명령. 같은 발화에 여러 키워드 포함 시 안전 우선.
        if Self.matchAny(lower, keywords: Self.emergencyKeywords) {
            bridge.handleEmergency(from: .voice)
            lastMatchedKeyword = "emergency"
            return
        }
        if Self.matchAny(lower, keywords: Self.recoveryKeywords) {
            bridge.handleRecovery(from: .voice)
            lastMatchedKeyword = "recovery"
            return
        }
        if Self.matchAny(lower, keywords: Self.marchKeywords) {
            bridge.handleMotion(id: "preset.march", from: .voice)
            lastMatchedKeyword = "preset.march"
            return
        }
        if Self.matchAny(lower, keywords: Self.idleKeywords) {
            bridge.handleMotion(id: "preset.idle", from: .voice)
            lastMatchedKeyword = "preset.idle"
            return
        }
        if Self.matchAny(lower, keywords: Self.jogKeywords) {
            bridge.handleMotion(id: "preset.jog", from: .voice)
            lastMatchedKeyword = "preset.jog"
            return
        }
        // unknown keyword — silent. lastMatchedKeyword nil 처리해서 "들리긴 했으나 매칭 X" 시각화.
        lastMatchedKeyword = nil
    }

    // MARK: - Keyword tables (immutable)

    /// 키워드 매칭: case-insensitive substring (text 가 키워드 포함하면 매칭).
    /// e.g. "지금 걸어줘" 안의 "걸어" 매칭. "please march now" 안의 "march" 매칭.
    private static func matchAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    static let marchKeywords: [String]     = ["걸어", "walk", "march"]
    static let idleKeywords: [String]      = ["정지", "stop", "idle"]
    static let jogKeywords: [String]       = ["조깅", "jog"]
    static let emergencyKeywords: [String] = ["비상", "emergency"]
    static let recoveryKeywords: [String]  = ["복구", "recover"]
}

// MARK: - VoiceRecognizing protocol (테스트 추상화)

/// 음성 인식 source 의 추상화. 실 `SFSpeechRecognizer` 또는 `MockVoiceRecognizer`.
///
/// callback 등록 + start/stop lifecycle 만 노출. interim/final 결과 구분 없이 모든 partial
/// 결과를 `onResult` 로 발화 — adapter 가 자체 dedup 정책 결정.
@MainActor
public protocol VoiceRecognizing: AnyObject {
    /// 인식 결과 (text) 수신 시 호출. interim + final 모두 발화.
    func setOnResult(_ handler: @escaping @MainActor (String) -> Void)
    /// 권한 거부 / 엔진 에러 시 호출. 메시지는 사용자 표시 가능.
    func setOnError(_ handler: @escaping @MainActor (String) -> Void)
    /// 마이크 권한 요청 + audio engine start. 실패 시 throw.
    func start() throws
    /// audio engine stop + task cancel. idempotent.
    func stop()
}

// MARK: - SpeechFrameworkRecognizer 구현

#if canImport(Speech)
/// 실 Apple Speech.framework 기반 구현 — macOS 14+ / iOS 17+.
///
/// # 동시성
///
/// `@MainActor` — Speech.framework 의 audio engine / recognition task 가 main thread 친화.
/// SFSpeechRecognizer 자체는 thread-safe 하나 본 wrapper 는 main 격리로 단순화.
///
/// # Info.plist 필수
///
/// `NSSpeechRecognitionUsageDescription` 키 등록. 미등록 시 `requestAuthorization` 호출
/// 즉시 crash. 본 wrapper 는 권한 거부도 정상 흐름으로 처리 — onError 에 메시지 발화.
///
/// # Sandbox
///
/// macOS sandbox 활성 환경에서 마이크 사용 시 `com.apple.security.device.audio-input`
/// entitlement 필요. SwiftPM executable target 은 sandbox 기본 비활성이라 무관.
@MainActor
public final class SpeechFrameworkRecognizer: VoiceRecognizing {

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onResult: (@MainActor (String) -> Void)?
    private var onError: (@MainActor (String) -> Void)?

    public init(locale: Locale = Locale(identifier: "ko-KR")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func setOnResult(_ handler: @escaping @MainActor (String) -> Void) {
        self.onResult = handler
    }

    public func setOnError(_ handler: @escaping @MainActor (String) -> Void) {
        self.onError = handler
    }

    public func start() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            let message = "Speech recognizer 가 현재 지역에서 사용 불가"
            onError?(message)
            throw VoiceRecognizerError.unavailable(message)
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self = self else { return }
                switch status {
                case .authorized:
                    do {
                        try self.beginLiveRecognition()
                    } catch {
                        self.onError?("음성 엔진 시작 실패: \(error.localizedDescription)")
                    }
                case .denied:
                    self.onError?("마이크 권한 거부됨 — 시스템 설정 > 개인정보 > 음성 인식")
                case .restricted:
                    self.onError?("음성 인식 제한 (parental control 등)")
                case .notDetermined:
                    self.onError?("음성 인식 권한 미결정")
                @unknown default:
                    self.onError?("알 수 없는 권한 상태")
                }
            }
        }
    }

    public func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func beginLiveRecognition() throws {
        // 이전 세션 정리.
        stop()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        // audio buffer tap.
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        // recognition task.
        guard let recognizer = recognizer else {
            throw VoiceRecognizerError.unavailable("recognizer nil")
        }
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // SF callback 은 background thread — MainActor hop 후 wrapper 콜백 발화.
            // adapter 의 @MainActor 격리 보장.
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor [weak self] in self?.onResult?(text) }
            }
            if let error = error {
                Task { @MainActor [weak self] in
                    self?.onError?("인식 에러: \(error.localizedDescription)")
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }
}

public enum VoiceRecognizerError: Error, LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}
#else
// Speech.framework 가 없는 환경 (예: Linux CI) — stub.
@MainActor
public final class SpeechFrameworkRecognizer: VoiceRecognizing {
    public init(locale: Locale = Locale(identifier: "ko-KR")) {}
    public func setOnResult(_ handler: @escaping @MainActor (String) -> Void) {}
    public func setOnError(_ handler: @escaping @MainActor (String) -> Void) {}
    public func start() throws {
        throw VoiceRecognizerError.unavailable("Speech.framework 미지원 플랫폼")
    }
    public func stop() {}
}

public enum VoiceRecognizerError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}
#endif
