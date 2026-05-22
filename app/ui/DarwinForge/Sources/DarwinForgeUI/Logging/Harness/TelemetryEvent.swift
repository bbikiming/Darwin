import Foundation

// MARK: - Telemetry Harness Event Schema (v1, 2026-05-20)
//
// Disk format: JSON Lines. 각 이벤트가 한 줄 (개행으로 구분).
// 짧은 키 — 100K event/session 도 디스크 부담 적게.
// 자세한 설계: docs/harness/telemetry-harness.md

/// Telemetry event level.
///
/// **v1.12.2 (Codex P2 fix)** — forward-compat: 미지원 level 값 (미래 schema 가 새
/// 케이스 추가) 디코드 시 `.info` 폴백. 종전 strict raw 디코드는 enum 추가만으로도
/// 과거 reader 가 이벤트 전체를 drop 했음.
public enum TelemetryLevel: String, Codable, Sendable, CaseIterable {
    case trace
    case info
    case notice
    case warn
    case error

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TelemetryLevel(rawValue: raw) ?? .info
    }
}

/// 이벤트 발생 actor — 누가 일으켰나.
///
/// **v1.12.2 (Codex P2 fix)** — forward-compat: 미지원 actor 값 디코드 시 `.system`.
public enum TelemetryActor: String, Codable, Sendable, CaseIterable {
    case user      // 사용자 입력 (클릭/단축키/명령)
    case system    // 앱 내부 (타이머, watchdog)
    case robot     // 로봇으로부터 (IMU, motor 응답)
    case claude    // LLM

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TelemetryActor(rawValue: raw) ?? .system
    }
}

/// 이벤트 type — namespace.event 형식. unknown 은 forward-compat.
public struct TelemetryKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var namespace: String {
        if let dot = rawValue.firstIndex(of: ".") {
            return String(rawValue[..<dot])
        }
        return rawValue
    }

    // App lifecycle
    public static let appLaunch: TelemetryKind = "app.launch"
    public static let appTerminate: TelemetryKind = "app.terminate"
    public static let appForeground: TelemetryKind = "app.foreground"
    public static let appBackground: TelemetryKind = "app.background"
    public static let appVersionInfo: TelemetryKind = "app.version_info"

    // Connection
    public static let connectAttempt: TelemetryKind = "connection.attempt"
    public static let connectSuccess: TelemetryKind = "connection.success"
    public static let connectFailure: TelemetryKind = "connection.failure"
    public static let connectDisconnect: TelemetryKind = "connection.disconnect"
    public static let connectReconnectStart: TelemetryKind = "connection.reconnect_start"
    public static let connectReconnectAttempt: TelemetryKind = "connection.reconnect_attempt"
    public static let connectEndpointSwitch: TelemetryKind = "connection.endpoint_switch"

    // Bus & robot
    public static let busReadFail: TelemetryKind = "bus.read_fail"
    public static let busWriteFail: TelemetryKind = "bus.write_fail"
    public static let busRecovered: TelemetryKind = "bus.recovered"
    public static let busEStop: TelemetryKind = "bus.e_stop"
    public static let busEStopRecover: TelemetryKind = "bus.e_stop_recover"

    // IMU
    public static let imuStale: TelemetryKind = "imu.stale"
    public static let imuUnavailable: TelemetryKind = "imu.unavailable"
    public static let imuRecovered: TelemetryKind = "imu.recovered"
    public static let imuScaleChanged: TelemetryKind = "imu.scale_changed"
    /// 사이클 159 (P0-1 fix): walk 활성 시 IMU polling 5Hz ↔ 20Hz 전환.
    public static let imuPollRateChanged: TelemetryKind = "imu.poll_rate_changed"

    // UI
    public static let uiSectionChanged: TelemetryKind = "ui.section_changed"
    public static let uiTabChanged: TelemetryKind = "ui.tab_changed"
    public static let uiPaletteOpened: TelemetryKind = "ui.palette_opened"
    public static let uiPaletteCommand: TelemetryKind = "ui.palette_command"
    public static let uiWizardOpened: TelemetryKind = "ui.wizard_opened"
    public static let uiDashboardOpened: TelemetryKind = "ui.dashboard_opened"
    public static let uiButtonTapped: TelemetryKind = "ui.button_tapped"
    public static let uiBookmark: TelemetryKind = "user.bookmark"

    // Motion
    public static let motionLoad: TelemetryKind = "motion.load"
    public static let motionPlayStart: TelemetryKind = "motion.play_start"
    public static let motionPlayComplete: TelemetryKind = "motion.play_complete"
    public static let motionPlayAbort: TelemetryKind = "motion.play_abort"
    public static let motionPageCreated: TelemetryKind = "motion.page_created"
    public static let motionPageRenamed: TelemetryKind = "motion.page_renamed"
    public static let motionPageDeleted: TelemetryKind = "motion.page_deleted"
    public static let motionPageSaved: TelemetryKind = "motion.page_saved"
    public static let motionStepAdded: TelemetryKind = "motion.step_added"
    public static let motionStepRemoved: TelemetryKind = "motion.step_removed"

    // Teach mode
    public static let teachCaptureStart: TelemetryKind = "teach.capture_start"
    public static let teachCaptureStop: TelemetryKind = "teach.capture_stop"
    public static let teachSnapshotCaptured: TelemetryKind = "teach.snapshot_captured"
    public static let teachSnapshotApplied: TelemetryKind = "teach.snapshot_applied"
    public static let teachSnapshotDeleted: TelemetryKind = "teach.snapshot_deleted"
    public static let teachSnapshotsCleared: TelemetryKind = "teach.snapshots_cleared"
    public static let teachTorqueChanged: TelemetryKind = "teach.torque_changed"

    // User Pose Library
    public static let poseLibrarySaved: TelemetryKind = "pose.library_saved"
    public static let poseLibraryDeleted: TelemetryKind = "pose.library_deleted"

    // WalkLab
    public static let walkLabStart: TelemetryKind = "walklab.start"
    public static let walkLabStop: TelemetryKind = "walklab.stop"
    public static let walkLabEmergencyStop: TelemetryKind = "walklab.emergency_stop"
    public static let walkLabPresetApplied: TelemetryKind = "walklab.preset_applied"
    public static let walkLabConfigChange: TelemetryKind = "walklab.config_change"
    /// v1.11.24 audit P0-1 — start(_:) 가 preflight 단계에서 거부한 시도.
    /// data: requested_preset, reason (diagnosticCode), active_preset.
    public static let walkLabStartBlocked: TelemetryKind = "walklab.start_blocked"
    /// v1.11.24 audit P1-3 — ROBOTIS Onboard ACK 결과 (성공/실패).
    /// data: status, latency_ms, cmd_id.
    public static let walkLabOnboardAck: TelemetryKind = "walklab.onboard_ack"

    // Pose
    public static let poseApplyStart: TelemetryKind = "pose.apply_start"
    public static let poseApplyComplete: TelemetryKind = "pose.apply_complete"
    public static let poseApplyFailed: TelemetryKind = "pose.apply_failed"
    public static let poseApplyCancel: TelemetryKind = "pose.apply_cancel"

    // Pilot
    public static let pilotModeChanged: TelemetryKind = "pilot.mode_changed"
    public static let pilotEStop: TelemetryKind = "pilot.e_stop"

    // Claude
    public static let claudePromptSent: TelemetryKind = "claude.prompt_sent"
    public static let claudeResponseReceived: TelemetryKind = "claude.response_received"
    public static let claudeError: TelemetryKind = "claude.error"

    // System
    public static let heartbeat: TelemetryKind = "heartbeat.tick"
    public static let harnessDropped: TelemetryKind = "harness.dropped"
    public static let errorException: TelemetryKind = "error.exception"
    /// v1.11.25 audit P0 robot-D — telemetry sub-loop auto-skipped (예: FSR 미장착).
    /// data: reason ("fsr_board_missing"), consecutive_failures.
    public static let telemetrySkip: TelemetryKind = "telemetry.skip"
}

/// Compact context snapshot — 모든 event 에 (선택적으로) 첨부.
public struct TelemetryContext: Codable, Sendable, Equatable {
    public enum ConnectionState: String, Codable, Sendable {
        case disconnected, connecting, connected, error

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ConnectionState(rawValue: raw) ?? .disconnected
        }
    }
    public let cn: ConnectionState?       // connection state
    public let ep: String?                // endpoint (redacted)
    public let sc: String?                // section
    public let bv: Double?                // battery V
    public let rt: Double?                // RTT ms
    public let im: Bool?                  // imu_stale (im = imu, `is` is reserved)

    public init(connection: ConnectionState? = nil,
                endpoint: String? = nil,
                section: String? = nil,
                batteryV: Double? = nil,
                rttMs: Double? = nil,
                imuStale: Bool? = nil) {
        self.cn = connection
        self.ep = endpoint
        self.sc = section
        self.bv = batteryV
        self.rt = rttMs
        self.im = imuStale
    }
}

/// Type-erased Codable payload — Decoder 가 모르는 schema 도 통과.
public struct TelemetryPayload: Codable, Sendable, Equatable {
    public let raw: [String: AnyCodable]
    public init(_ raw: [String: AnyCodable] = [:]) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = (try? container.decode([String: AnyCodable].self)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Convenience builders so call sites stay readable.
public extension TelemetryPayload {
    static func empty() -> TelemetryPayload { TelemetryPayload([:]) }

    static func dict(_ pairs: [String: AnyCodable]) -> TelemetryPayload {
        TelemetryPayload(pairs)
    }
}

/// **The** telemetry event. Encode/Decode 만 신경 쓰면 됨.
public struct TelemetryEvent: Codable, Sendable, Equatable, Identifiable {
    /// `Identifiable` — Table/List 표시용. session+seq 가 globally unique.
    public var id: String { "\(s)#\(i)" }
    public let v: Int                     // schema version
    public let s: String                  // session UUID
    public let i: UInt64                  // monotonic seq
    public let tw: String                 // ISO-8601 wall clock
    public let tm: UInt64                 // monotonic clock ns
    public let k: TelemetryKind           // kind
    public let lv: TelemetryLevel         // level
    public let a: TelemetryActor          // actor
    public let d: TelemetryPayload        // payload
    public let c: TelemetryContext?       // context snapshot

    public init(schema: Int = 1,
                session: String,
                seq: UInt64,
                wall: String,
                mono: UInt64,
                kind: TelemetryKind,
                level: TelemetryLevel,
                actor: TelemetryActor,
                data: TelemetryPayload = .empty(),
                context: TelemetryContext? = nil) {
        self.v = schema
        self.s = session
        self.i = seq
        self.tw = wall
        self.tm = mono
        self.k = kind
        self.lv = level
        self.a = actor
        self.d = data
        self.c = context
    }
}

// MARK: - AnyCodable
//
// JSON 안에 무엇이 들어올지 모르는 payload 를 Codable 답게 다루기 위한 wrapper.
// 외부 의존성 (Foundation 만 사용) — Swift Package 의존성 늘리지 않음.

public struct AnyCodable: Codable, @unchecked Sendable, Equatable, ExpressibleByStringLiteral,
                          ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                          ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
                          ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public let value: Any?

    public init(_ value: Any?) { self.value = value }

    // Literals
    public init(stringLiteral value: String) { self.value = value }
    public init(integerLiteral value: Int) { self.value = value }
    public init(floatLiteral value: Double) { self.value = value }
    public init(booleanLiteral value: Bool) { self.value = value }
    public init(nilLiteral: ()) { self.value = nil }
    public init(arrayLiteral elements: AnyCodable...) { self.value = elements }
    public init(dictionaryLiteral elements: (String, AnyCodable)...) {
        var d: [String: AnyCodable] = [:]
        for (k, v) in elements { d[k] = v }
        self.value = d
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = nil }
        else if let b = try? c.decode(Bool.self) { self.value = b }
        else if let i = try? c.decode(Int.self) { self.value = i }
        else if let d = try? c.decode(Double.self) { self.value = d }
        else if let s = try? c.decode(String.self) { self.value = s }
        else if let a = try? c.decode([AnyCodable].self) { self.value = a }
        else if let m = try? c.decode([String: AnyCodable].self) { self.value = m }
        else { self.value = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case nil: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let u as UInt64: try c.encode(u)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [AnyCodable]: try c.encode(a)
        case let m as [String: AnyCodable]: try c.encode(m)
        case let arr as [Any?]: try c.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any?]:
            var out: [String: AnyCodable] = [:]
            for (k, v) in dict { out[k] = AnyCodable(v) }
            try c.encode(out)
        default: try c.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // 디스크 round-trip 결과의 동치성 검증용 — JSON 인코딩 후 비교.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let l = try? encoder.encode(lhs), let r = try? encoder.encode(rhs) else {
            return false
        }
        return l == r
    }
}
