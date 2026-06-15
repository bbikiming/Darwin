import Foundation

/// Wi-Fi 비밀번호처럼 라우터 재시작해도 유지되는 pairing code 저장소.
/// 기술적으로는 UserDefaults 에 6자리 문자열을 키-값으로 저장하며,
/// 앱 재시작 후에도 동일한 코드를 반환한다. 사용자가 명시적으로 회전할
/// 때만 새 코드로 덮어쓴다. 만료 정책 없음.
///
/// - Thread-safety: `NSLock` 으로 보호되므로 any-thread 호출 안전.
/// - Security: UserDefaults 평문 저장. LAN-only 환경 가정이므로 acceptable.
///   Keychain 마이그레이션은 V292 후속.
public final class PersistedPairingStore: @unchecked Sendable {

    public static let defaultsKey = "mobileRelay.pairingCode"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = PersistedPairingStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// 저장된 code 반환. 없거나 비어 있으면 nil.
    public func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = defaults.string(forKey: key)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 새 code 를 저장 (덮어쓰기).
    public func write(_ code: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(code, forKey: key)
    }

    /// 저장된 code 를 삭제. 다음 read() 는 nil 반환.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
