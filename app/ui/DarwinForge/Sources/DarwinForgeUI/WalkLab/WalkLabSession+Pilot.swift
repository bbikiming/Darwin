import Foundation

/// **v1.20.45 (2026-05-22) — Pilot facade extension**.
///
/// `WalkLabRCBridge` 가 종전 11+ session property/method 를 직접 touch 하던 god-object
/// surface 를 **facade pattern** 으로 좁힘. 본체 `WalkLabSession.swift` 는 0줄 수정 —
/// 본 extension 만 추가.
///
/// # 동기
///
/// architect agent 분석: "CRITICAL god object, 800 line 5배 초과 (4396 line).
/// WalkLabRCBridge 가 `balanceState` / `store?.bus` / `riskAcknowledged` / `advanced` /
/// `strideMm` / `sideMm` / `turnDeg` / `emergencyStopActive` / `current` /
/// `startBlockedReason` / `lastPreflightFailure` / `lastRobotEvent` /
/// `syncCommandToEngine()` / `start(_:)` / `stop()` / `exitEmergencyMode()` 직접 의존."
///
/// 분할이 아닌 surface 좁힘 — bridge 가 보는 session 의 표면적을 4-5 메서드로 축소.
/// 향후 god object 분할 sprint 의 안정적 진입점.
///
/// # 의도
///
/// - 본체 `WalkLabSession.swift` 수정 0 (extension only)
/// - 기존 1049 tests 회귀 0 — facade 가 동일 semantics 보장
/// - bridge 의 internal property touch → facade method 로만 교체
///
/// # 호출 site (단 한 곳)
///
/// - `WalkLabRCBridge` — process / handlePreset / handleRecovery / handleMotion 등
extension WalkLabSession {

    // MARK: - 결과 타입

    /// `pilotStart(preset:)` 결과 — bridge 가 telemetry / safetyMessage 결정에 사용.
    public enum PilotStartResult: Equatable, Sendable {
        /// preset transition 성공 (current 가 실제로 바뀜).
        case success
        /// preflight 차단 — `userMessage` 는 사용자 표시 용.
        case blocked(userMessage: String)
        /// 동일 preset 재입력 — silent no-op (사용자 의도: 변경 없음).
        case sameAsCurrent
    }

    // MARK: - SafetyContext 합성

    /// MotionBlender 가 요구하는 `SafetyContext` 합성 — balanceState / bus 연결 / risk 동의.
    ///
    /// 종전 bridge.handleMotion 이 `session.balanceState` / `session.store?.bus` /
    /// `session.riskAcknowledged` 3개 property 를 직접 read → SafetyContext 구성.
    /// 본 facade 가 합성을 흡수 — bridge 는 한 호출로 끝.
    public func pilotSafetyContext() -> SafetyContext {
        SafetyContext(
            balanceState: balanceState,
            robotConnected: store?.bus != nil,
            riskAcknowledged: riskAcknowledged
        )
    }

    // MARK: - Amplitude apply

    /// 현재 walking amplitude — bridge 의 EMA blend 가 이전 값을 read 할 때 사용.
    /// 종전 bridge 가 `session.strideMm / sideMm / turnDeg` 3개 property 를 직접 read →
    /// facade method 한 호출로 축소. write 는 `pilotApplyAmplitude` 로 분리.
    public var pilotCurrentAmplitude: WalkingCommand {
        WalkingCommand(strideMm: strideMm, sideMm: sideMm, turnDeg: turnDeg)
    }

    /// stick → walking amplitude (strideMm / sideMm / turnDeg) write **without** engine sync.
    ///
    /// 종전 bridge.applyAmplitude 의 로직 흡수 (write 부분만):
    /// - emergency 상태에서 amplitude write 차단 (race invariant)
    /// - `advanced=true` 자동 활성 (사이클 20-fix CRITICAL 순서: advanced before write)
    /// - slider 3개 (strideMm / sideMm / turnDeg) write
    ///
    /// **설계 노트**: smoothing factor 는 bridge 의 책임 (사용자 sensitivity 설정).
    /// EMA blend 는 bridge 가 `pilotCurrentAmplitude` read → blend → 본 method 호출.
    /// engine sync 는 별도 method (`pilotSyncEngine`) — bridge 의 latency marker 사이에 호출.
    ///
    /// - Parameter cmd: 적용할 amplitude (이미 smoothing 적용 끝난 final 값).
    /// - Returns: emergency 차단으로 write skip 시 `false`, 정상 write 시 `true`.
    @discardableResult
    public func pilotApplyAmplitude(_ cmd: WalkingCommand) -> Bool {
        // emergency 가드 — race 로 process() 우회 시 invariant 보장.
        if emergencyStopActive {
            return false
        }
        // advanced=true 자동 활성 (write BEFORE).
        if !advanced {
            advanced = true
        }
        strideMm = cmd.strideMm
        sideMm = cmd.sideMm
        turnDeg = cmd.turnDeg
        return true
    }

    /// engine sync — `syncCommandToEngine()` wrap. bridge 의 latency marker 사이에 호출.
    /// 종전 bridge 가 `session.syncCommandToEngine()` 직접 호출 → facade method 로 대체.
    public func pilotSyncEngine() {
        syncCommandToEngine()
    }

    // MARK: - Preset start

    /// preset transition 시도 + 결과 분류. bridge.handlePreset 의 핵심 진단 로직 흡수.
    ///
    /// 종전 bridge.handlePreset 는 `current` / `lastPreflightFailure` /
    /// `startBlockedReason` 3개 property 를 read + `start(_:)` 호출 → 결과 분류.
    /// 본 facade 가 분류 책임 흡수 — bridge 는 `PilotStartResult` 만 보고 safetyMessage 결정.
    ///
    /// 판정 규칙 (handlePreset 의 종전 로직과 동일):
    /// - `current == preset` (호출 전): `.sameAsCurrent` — silent no-op.
    /// - `start(preset)` 후 `current == preset && current != before`: `.success`.
    /// - `lastPreflightFailure` 변경: `.blocked(failure.userMessage)`.
    /// - 기타: `.blocked("Preset X 시작 차단 — \(startBlockedReason ?? \"알 수 없음\")")`.
    ///
    /// **주의**: 본 facade 는 `start(_:)` 만 호출 — emergency / disabled gate 는
    /// bridge 의 책임 (facade 는 semantics 보존, gate 확장 안 함).
    public func pilotStart(preset: WalkLabPreset) -> PilotStartResult {
        if current == preset {
            return .sameAsCurrent
        }
        let currentBefore = current
        let preflightBefore = lastPreflightFailure
        start(preset)

        if current == preset && current != currentBefore {
            return .success
        }
        if let failure = lastPreflightFailure, failure != preflightBefore {
            return .blocked(userMessage: failure.userMessage)
        }
        return .blocked(
            userMessage: "Preset \(preset.rawValue) 시작 차단 — \(startBlockedReason ?? "알 수 없음")"
        )
    }

    // MARK: - Emergency

    /// emergency 상태 (read-only) — bridge 의 `emergencyStopActive` 직접 read 대체.
    public var pilotIsEmergency: Bool {
        emergencyStopActive
    }

    /// 사용자 명시 emergency recovery — `exitEmergencyMode()` wrap.
    ///
    /// 종전 bridge.handleRecovery 가 `session.exitEmergencyMode()` 직접 호출 + 별도로
    /// `session.lastRobotEvent` 도 set. 본 facade 는 단순 wrap — 메시지는 bridge 책임
    /// (source label 이 bridge 의 컨텍스트).
    public func pilotEmergencyExit() {
        exitEmergencyMode()
    }

    // MARK: - Robot event channel

    /// pilotPostEvent facade 의 단일 메시지 길이 한계 (character count).
    /// 초과 시 절단 후 `pilotEventTruncationMarker` 부착.
    public static let pilotEventMaxLength: Int = 120

    /// length cap 적용 시 절단 표식. caller 가 detect 가능.
    public static let pilotEventTruncationMarker: String = "..."

    /// dedup window — 직전 stamped 메시지와 동일 시 silent drop.
    /// 1.0초: 사용자가 시각적으로 인지 가능한 최소 단위.
    public static let pilotEventDedupWindow: TimeInterval = 1.0

    /// bridge 가 사용자 안내 (preset 시작 / stop / amplitude 변경 등) 를 발행하는 채널.
    ///
    /// 종전 bridge 의 18+ `session.lastRobotEvent = "..."` 직접 write 를 facade method
    /// 한 곳으로 모음. bridge → facade 의존 명확화 (write 위치 추적 가능).
    ///
    /// # 강화 (사이클 69 — 코덱스 LOW-2)
    ///
    /// 종전 facade 는 단순 `lastRobotEvent = message` setter alias 에 불과 (코덱스 verbatim:
    /// "진짜 facade 라면 source 자동 prefix, length cap, duplicate suppression 추가 가능").
    /// 본 강화는 3개의 책임을 facade 로 흡수:
    ///
    /// 1. **source prefix 자동화**: `source` 가 non-nil 이면 `"[label] "` prefix 자동 부착.
    ///    bridge call site 들이 종전 `"\(source.label) →"` 직접 합성하던 ad-hoc 패턴 일관화.
    /// 2. **length cap**: stamped 메시지가 `pilotEventMaxLength` (120 char) 초과 시 절단 +
    ///    `pilotEventTruncationMarker` ("...") 부착. lastRobotEvent 가 UI badge 용 — 매우 긴
    ///    diagnostic 가 layout 깨뜨림 차단.
    /// 3. **중복 suppression**: 직전 stamped 메시지와 정확히 동일하면서 1초
    ///    (`pilotEventDedupWindow`) 이내 발화 시 silent drop. 사용자가 같은 stick 을 빠르게
    ///    흔들면 동일 amplitude 메시지가 초당 10회 이상 발화 → HUD flicker. dedup 으로 1회로 압축.
    ///
    /// # 호출 호환성 (CRITICAL)
    ///
    /// `source: InputSource? = nil` default — 기존 callers (`session.pilotPostEvent("...")`)
    /// 그대로 동작. 신규 callers 는 `session.pilotPostEvent("...", source: .ui)` 로 prefix
    /// 위임 가능.
    ///
    /// - Parameter message: 사용자 안내 raw 텍스트.
    /// - Parameter source: 발화 source (옵션). non-nil 이면 `"[label] "` prefix 자동 부착.
    public func pilotPostEvent(_ message: String, source: InputSource? = nil) {
        // 1. source prefix — non-nil 시 "[label] " 부착 (bridge 의 ad-hoc 패턴 통일).
        let prefixed: String
        if let source {
            prefixed = "[\(source.label)] \(message)"
        } else {
            prefixed = message
        }

        // 2. length cap — pilotEventMaxLength 초과 시 절단 + "..." 부착.
        // count 는 grapheme cluster 기준 (한글/이모지 1 unit) — 사용자 인지 단위와 일치.
        let stamped: String
        if prefixed.count > Self.pilotEventMaxLength {
            let keep = Self.pilotEventMaxLength - Self.pilotEventTruncationMarker.count
            // marker 자체가 cap 보다 길면 edge case 방어 — clamp 0.
            let safeKeep = max(0, keep)
            let head = String(prefixed.prefix(safeKeep))
            stamped = head + Self.pilotEventTruncationMarker
        } else {
            stamped = prefixed
        }

        // 3. duplicate suppression — 직전 stamped 와 동일 + 1초 이내면 silent drop.
        let now = Date()
        if let lastMsg = _lastPilotEventMessage,
           let lastAt = _lastPilotEventTime,
           lastMsg == stamped,
           now.timeIntervalSince(lastAt) < Self.pilotEventDedupWindow {
            return
        }

        // 4. publish — lastRobotEvent + dedup state 동시 갱신.
        _lastPilotEventMessage = stamped
        _lastPilotEventTime = now
        lastRobotEvent = stamped
    }

    // MARK: - Preflight failure facade (사이클 71 — 코덱스 CRITICAL-2)

    /// **사이클 71 — 코덱스 CRITICAL-2 fix**: external caller (예: WalkTrialAutoGenerator)
    /// 가 preflight failure 상태를 facade 경유로 일관성 있게 set.
    ///
    /// 종전: caller 가 `session.lastPreflightFailure = failure` + `startBlockedReason =
    /// failure.diagnosticCode` 직접 write 필요 → `public private(set)` 이라 module 안에서도
    /// 외부 접근 불가능. 신규 facade: 본 method 한 호출로 두 property 통일.
    ///
    /// **호출 사례**: WalkTrialAutoGenerator 의 emergency 가드 (root guard 우회 path).
    /// 일반 caller 는 `session.start(_:)` 의 root guard 가 자동 처리 — 본 method 불요.
    public func pilotMarkPreflightFailure(_ failure: WalkPreflightFailure) {
        // 본체 helper 위임 (private(set) → extension 도 직접 접근 불가).
        _internalSetPreflightFailure(failure)
    }

    // MARK: - Walking lifecycle

    /// 현재 보행 중인지 — bridge 의 `session.current != .idle` 체크 대체.
    ///
    /// **사이클 61 (codex HIGH-3 fix)**: 종전 `current != .idle` 단순 술어가 본체 line
    /// 2064 / 2179 / 2232 의 복합 invariant (`current != .idle || walkCycleTask != nil ||
    /// onboardWalkingActive`) 와 어긋남 → preflight 통과 후 walkCycleTask 시작 직전 frame
    /// 에서 false negative → bridge auto-start 의 stop 액션 silent drop.
    /// 본 facade 는 본체의 `isActuallyWalking` single source of truth 에 위임.
    public var pilotIsWalking: Bool {
        isActuallyWalking
    }

    /// `stop()` wrap — bridge 의 `session.stop()` 직접 호출 대체.
    public func pilotStop() {
        stop()
    }
}
