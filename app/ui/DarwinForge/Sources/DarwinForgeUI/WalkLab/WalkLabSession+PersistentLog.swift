import Foundation
import ForgeCore

/// **v1.22.1 (2026-05-22) — 사이클 90: god object Phase 1B 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` 의 PersistentEvent 영구 로그 코드 (~43 line) 를 본 extension
/// 으로 이동. 본체는 stored property 가 없으므로 nested type / static method / static
/// constant 전부 이동 가능 — 순수 추출.
///
/// # 비유
///
/// 도서관의 "장기 보관 서고" 를 별관으로 완전 분리. 본관 직원 (logSafetyEvent) 은 별관
/// 데스크 (persistEvent) 에 책 (event) 만 넘기면 끝. 보관 책장 (UserDefaults key) /
/// 보관 한도 (maxCount) / 보관 양식 (PersistentEvent struct) 전부 별관 자체 관리.
///
/// # 분할 정책
///
/// - **nested type 이동**: `PersistentEvent` struct (Codable / Equatable / Sendable).
///   `WalkLabSession.PersistentEvent` 외부 식별자는 그대로 유지 (extension 의 nested
///   type 도 동일 형태 노출).
/// - **static constant 이동**: `persistentEventsKey` / `persistentEventsMaxCount`.
///   본 cycle 에서 `private static` → `internal static` 으로 access 격상 — 본체
///   `logSafetyEvent` (다른 file) 의 호출 허용. 외부 module 에서는 여전히 비공개.
/// - **static method 이동**: `persistEvent(kind:message:)` / `loadPersistentEvents()` /
///   `clearPersistentEvents()`. `persistEvent` 도 `private` → `internal` 격상 (본체
///   호출 site 가 다른 file 이라 file-level private 으로는 안 보임).
/// - 외부 API: `loadPersistentEvents` / `clearPersistentEvents` 는 `public static`
///   유지 — Tests 및 외부 caller signature 변경 없음.
///
/// # 회귀
///
/// 1233 tests 회귀 0 — public API 변경 0. internal 격상은 module 내부만 노출 확장.
extension WalkLabSession {

    // MARK: - 영구 이벤트 로그 (2026-05-17 안전 강화)

    /// UserDefaults 키 — 안전 이벤트 영구 저장 (최근 100건).
    /// 앱 재시작 후에도 유지. 실 robot 사고 시 재현 가능한 trace 제공.
    /// **v1.22.1**: `private static` → `internal static` (extension 분할; 본체
    /// 다른 file 의 caller 접근 위해 격상. 외부 module 은 비노출).
    internal static let persistentEventsKey = "df.walklab.persistentSafetyEvents"
    internal static let persistentEventsMaxCount = 100

    /// 영구 저장된 이벤트 1건 — JSON serializable.
    public struct PersistentEvent: Codable, Equatable, Sendable {
        public let timestamp: Date
        public let kindRaw: String  // SafetyEvent.Kind.rawValue
        public let message: String
    }

    /// 이벤트 영구 저장 — UserDefaults 에 최근 100건 ring buffer.
    /// **v1.22.1**: `private static` → `internal static` (본체 `logSafetyEvent`
    /// 가 다른 file 이므로 file-level private 격상 필요. module 외부 비노출).
    internal static func persistEvent(kind: SafetyEvent.Kind, message: String) {
        var existing = loadPersistentEvents()
        existing.append(PersistentEvent(
            timestamp: Date(),
            kindRaw: kind.rawValue,
            message: message
        ))
        if existing.count > persistentEventsMaxCount {
            existing.removeFirst(existing.count - persistentEventsMaxCount)
        }
        if let data = try? JSONEncoder().encode(existing) {
            UserDefaults.standard.set(data, forKey: persistentEventsKey)
        }
    }

    /// 영구 저장된 이벤트 로드 — 앱 시작 시 / postmortem UI 표시.
    /// JSON decode 실패 시 빈 배열 반환 (storage 오염 안전 처리).
    public static func loadPersistentEvents() -> [PersistentEvent] {
        guard let data = UserDefaults.standard.data(forKey: persistentEventsKey),
              let events = try? JSONDecoder().decode([PersistentEvent].self, from: data)
        else { return [] }
        return events
    }

    /// 영구 로그 전체 비우기 — 사용자 명시 액션 (privacy / disk 관리).
    public static func clearPersistentEvents() {
        UserDefaults.standard.removeObject(forKey: persistentEventsKey)
    }
}
