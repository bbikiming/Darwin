import Foundation

// MARK: - Harness DI Protocols (Wave 3 Phase 3.1, 사이클 241)
//
// `Harness.shared` 을 직접 호출하는 49 파일 257 사이트의 테스트 가능성을 높이기 위한
// DI 추상화 기초. ISP (Interface Segregation Principle) 에 따라 책임별로 3-way split:
//
//   HarnessRecording  — 90% caller 의 유일 dependency. record / bookmark / flush.
//   HarnessHeartbeat  — ConnectionStore 전용. start/stopHeartbeat.
//   HarnessContext    — ConnectionStore 전용. registerContextProvider.
//   HarnessLifecycle  — DarwinForgeApp 전용. start / stop(reason:).
//
// 모든 protocol 메서드는 @MainActor — 기존 Harness 와 동일한 isolation. 호출 사이트 무손상.
//
// **Additive only** — 기존 `Harness.shared` 직접 호출은 그대로 작동. 본 protocol 은
// 새 코드/테스트에서 점진적으로 채택. Phase 3.2+ 에서 호출 사이트를 본 추상화로 마이그레이션.

/// 텔레메트리 기록 — 90% caller 의 유일 dependency.
///
/// **default arg trick** — protocol 메서드는 모든 파라미터를 명시. extension method 가
/// 호출 사이트 편의 default 를 제공 (Swift protocol 의 default arg 제한 우회).
@MainActor
public protocol HarnessRecording {
    func record(_ kind: TelemetryKind,
                level: TelemetryLevel,
                actor: TelemetryActor,
                data: [String: AnyCodable],
                context: TelemetryContext?)
    func bookmark(_ note: String)
    func flush() async
}

/// 주기적 heartbeat — ConnectionStore 전용.
@MainActor
public protocol HarnessHeartbeat {
    func startHeartbeat(intervalSeconds: TimeInterval)
    func stopHeartbeat()
}

/// Context provider 등록 — ConnectionStore 전용.
@MainActor
public protocol HarnessContext {
    func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?)
}

/// 세션 lifecycle — DarwinForgeApp 전용. start / stop 은 @MainActor 호출이지만 protocol
/// 자체는 nonisolated — Live/Noop/Recording 모두 @MainActor 클래스이므로 구현체에서
/// 자동 isolation 부여.
public protocol HarnessLifecycle {
    @MainActor func start()
    @MainActor func stop(reason: String)
}

/// Inspector 전용 introspection — telemetry 내부 상태 읽기 (sessionId, sessionDir, 활성화 여부).
///
/// **일반 caller 는 본 protocol 을 사용하지 말 것** — `HarnessInspectorView`, `CurrentSessionPanel`
/// 같이 진행 중 세션의 metadata 를 표시하는 화면 전용. 일반 record/bookmark/flush 호출은
/// `HarnessRecording` 사용.
///
/// Wave 3 Phase 3.4 (사이클 115, 2026-05-23) — 5 인프라 예외 사이트의 introspection
/// 접근을 protocol 으로 형식화. 이를 통해 `Harness.shared.sessionId` 직접 호출을
/// `(harness as? any HarnessIntrospection)?.sessionId` 으로 migrate 가능.
@MainActor
public protocol HarnessIntrospection {
    /// 텔레메트리 활성 여부. UserDefaults backed — 사용자 토글 가능.
    var isEnabled: Bool { get set }
    /// 현재 진행 중 세션의 UUID (미시동 시 빈 문자열).
    var sessionId: String { get }
    /// 현재 세션 시작 시각.
    var sessionStarted: Date { get }
    /// 현재 세션 디스크 디렉토리 (미시동 시 nil).
    var sessionDir: URL? { get }
    /// 현재 세션의 recorder 활성 여부 (true = 기록 중, false = 미시동/종료됨).
    var isRecorderActive: Bool { get }
}

/// 모든 책임 통합 — 전역 DI 주입용 (Environment, ViewModel init 파라미터 등).
public typealias HarnessFacade = HarnessRecording & HarnessHeartbeat & HarnessContext & HarnessLifecycle

// MARK: - Default-argument 편의 (호출 사이트 무손상)
//
// Swift protocol 의 메서드는 default argument 를 가질 수 없음 (witness table 제약).
// 대신 extension 에서 default 값을 가진 overload 를 제공 — caller 가
// `harness.record(.connectAttempt)` 처럼 짧게 호출 가능.

public extension HarnessRecording {
    /// 편의 overload — level/.info, actor/.system, data/[:], context/nil 기본.
    /// 기존 `Harness.shared.record(.kind)` 호출 사이트와 시그니처 호환.
    func record(_ kind: TelemetryKind,
                level: TelemetryLevel = .info,
                actor: TelemetryActor = .system,
                data: [String: AnyCodable] = [:],
                context: TelemetryContext? = nil) {
        record(kind, level: level, actor: actor, data: data, context: context)
    }
}

public extension HarnessHeartbeat {
    /// 편의 overload — interval/1.0 기본 (기존 Harness API 와 동일).
    func startHeartbeat(intervalSeconds: TimeInterval = 1.0) {
        startHeartbeat(intervalSeconds: intervalSeconds)
    }
}

public extension HarnessLifecycle {
    /// 편의 overload — reason/"terminate" 기본.
    @MainActor
    func stop(reason: String = "terminate") {
        stop(reason: reason)
    }
}
