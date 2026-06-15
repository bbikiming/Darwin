import Foundation
#if canImport(Speech)
import Speech
#endif

/// 파일 기반 음성 전사 결과 — 전사 텍스트 + on-device 여부.
public struct TranscriptionResult: Equatable {
    public let text: String
    /// 네트워크 없이 기기 내부에서 인식했는지(로봇 LAN 은 인터넷이 없어 중요).
    public let onDevice: Bool

    public init(text: String, onDevice: Bool) {
        self.text = text
        self.onDevice = onDevice
    }

    /// 전사 텍스트가 비어 있지 않은가(무음/미인식 구분).
    public var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum TranscriptionError: Error, LocalizedError, Equatable {
    case unauthorized(String)
    case unavailable(String)
    case recognitionFailed(String)
    case timedOut
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m):     return "음성 인식 권한 거부됨 — \(m)"
        case .unavailable(let m):      return "음성 인식 사용 불가 — \(m)"
        case .recognitionFailed(let m): return "전사 실패 — \(m)"
        case .timedOut:                return "전사 시간 초과"
        case .unsupportedPlatform:     return "이 플랫폼은 음성 인식을 지원하지 않음"
        }
    }
}

/// 맥에 저장된 WAV 파일을 텍스트로 전사하는 추상화.
///
/// 라이브 마이크용 `VoiceRecognizing`(SFSpeechAudioBufferRecognitionRequest)과 달리,
/// 여기선 **로봇에서 받아온 파일** 을 `SFSpeechURLRecognitionRequest` 로 인식한다.
public protocol MicCheckTranscribing {
    func transcribe(fileURL: URL, locale: Locale) async throws -> TranscriptionResult
}

#if canImport(Speech)

/// Apple `Speech.framework` 파일 인식 기반 구현 — macOS 14+.
///
/// # 정책
/// - `NSSpeechRecognitionUsageDescription`(Info.plist) 필수 — 미등록 시 권한 요청에서 crash.
/// - 로봇 LAN 은 인터넷이 없으므로 기기가 지원하면 `requiresOnDeviceRecognition=true`.
/// - 무음/미인식이면 빈 텍스트를 정상 반환(throw 아님) — UI 가 "인식 결과 없음" 표시.
/// - 워치독 timeout 으로 영구 대기 방지.
public final class SpeechFileTranscriber: MicCheckTranscribing {

    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 20) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func transcribe(fileURL: URL, locale: Locale) async throws -> TranscriptionResult {
        try await requestAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.unavailable("해당 언어(\(locale.identifier)) 미지원")
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.unavailable("recognizer 현재 사용 불가")
        }

        let onDevice = recognizer.supportsOnDeviceRecognition
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false

        let guardBox = ResumeGuard()
        return try await withCheckedThrowingContinuation { cont in
            var task: SFSpeechRecognitionTask?
            // 워치독 — 미인식으로 final 이 안 와도 timeout 후 정리.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if guardBox.tryResume() {
                    task?.cancel()
                    cont.resume(throwing: TranscriptionError.timedOut)
                }
            }
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    if guardBox.tryResume() {
                        cont.resume(throwing:
                            TranscriptionError.recognitionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let result = result, result.isFinal else { return }
                if guardBox.tryResume() {
                    cont.resume(returning: TranscriptionResult(
                        text: result.bestTranscription.formattedString, onDevice: onDevice))
                }
            }
        }
    }

    /// 음성 인식 권한 요청 — 거부 시 throw.
    private func requestAuthorization() async throws {
        let status: SFSpeechRecognizerAuthorizationStatus =
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        switch status {
        case .authorized: return
        case .denied:        throw TranscriptionError.unauthorized("시스템 설정 > 개인정보 > 음성 인식")
        case .restricted:    throw TranscriptionError.unauthorized("제한됨(parental control 등)")
        case .notDetermined: throw TranscriptionError.unauthorized("권한 미결정")
        @unknown default:    throw TranscriptionError.unauthorized("알 수 없는 권한 상태")
        }
    }
}

/// continuation 을 정확히 한 번만 resume 하도록 보장하는 thread-safe 가드.
private final class ResumeGuard {
    private let lock = NSLock()
    private var resumed = false

    /// 아직 resume 안 됐으면 true 반환 + 표시. 이미 됐으면 false.
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

#else

/// Speech.framework 미지원 플랫폼(예: Linux CI) — 항상 throw.
public final class SpeechFileTranscriber: MicCheckTranscribing {
    public init(timeoutSeconds: TimeInterval = 20) {}
    public func transcribe(fileURL: URL, locale: Locale) async throws -> TranscriptionResult {
        throw TranscriptionError.unsupportedPlatform
    }
}

#endif
