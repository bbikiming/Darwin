import AppKit
import Combine
import Foundation
import UserNotifications

// MARK: - HarnessLiveAlerts (v1.14.0, 2026-05-20)
//
// 진행 중 세션 실시간 임계 모니터. Inspector 의 LiveTail 패널이 1Hz tick 으로 호출.
// 최근 60초 윈도우 안의 이벤트만 분석 → 임계 초과 시 ActiveAlert 발행.
// 사용자 옵션 ON 시 NSUserNotification 토스트.
//
// 자세한 설계: docs/harness/log-utilization-system.md

public struct ActiveAlert: Sendable, Equatable, Identifiable {
    public let id: String                // ruleID — 동시 1개만 active
    public let severity: Severity
    public let title: String
    public let detail: String
    public let firstObservedAt: Date

    public enum Severity: String, Sendable {
        case info, notice, warn, critical
    }
}

@MainActor
public final class HarnessLiveAlerts: ObservableObject {
    public static let shared = HarnessLiveAlerts()

    // MARK: - 설정

    /// UserDefaults 키 — 토스트 토글.
    public static let toastEnabledKey = "harness.live_alerts_toast_enabled"

    public var toastEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.toastEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.toastEnabledKey) }
    }

    /// 윈도우 크기.
    public static let defaultWindowSeconds: Double = 60

    /// 임계 — 사용자가 향후 조정 가능하도록 추후 UserDefaults 노출.
    public struct Thresholds: Sendable {
        public var rttMeanMs: Double = 80
        public var imuStaleRatio: Double = 0.5
        public var connectFailures: Int = 2
        public var busWriteFails: Int = 3
        public init() {}
    }
    public private(set) var thresholds = Thresholds()

    // MARK: - 상태

    @Published public private(set) var active: [ActiveAlert] = []
    private var firstObservedAt: [String: Date] = [:]
    private var lastNotifiedAt: [String: Date] = [:]
    private static let renotifyInterval: TimeInterval = 60     // 같은 룰 토스트 재발화 간격

    private init() {}

    // MARK: - 평가

    /// `events` 는 시간 오름차순. tick 마다 호출.
    /// 가장 최근 `windowSeconds` 안의 이벤트만 분석. UI 가 1Hz 호출 권장.
    public func evaluate(events: [TelemetryEvent],
                          windowSeconds: Double = HarnessLiveAlerts.defaultWindowSeconds) {
        guard !events.isEmpty else { active = []; return }
        let nowTs = Date()
        let cutoff = nowTs.addingTimeInterval(-windowSeconds)
        let windowed = events.filter {
            guard let t = SessionAnalyzer.parseIso($0.tw) else { return false }
            return t >= cutoff
        }
        guard !windowed.isEmpty else { active = []; return }

        var newAlerts: [ActiveAlert] = []

        // 1) RTT 평균 윈도우.
        let rttSamples: [Double] = windowed.compactMap { $0.c?.rt }
        if !rttSamples.isEmpty {
            let mean = rttSamples.reduce(0, +) / Double(rttSamples.count)
            if mean > thresholds.rttMeanMs {
                newAlerts.append(makeAlert(
                    id: "rtt.window_mean",
                    severity: mean > thresholds.rttMeanMs * 1.5 ? .critical : .warn,
                    title: "RTT 평균 \(fmt(mean))ms — 임계 \(fmt(thresholds.rttMeanMs))ms 초과",
                    detail: "최근 \(Int(windowSeconds))초 동안 \(rttSamples.count) 샘플."
                ))
            }
        }

        // 2) IMU stale 비율.
        let heartbeats = windowed.filter { $0.k.rawValue == "heartbeat.tick" }
        if heartbeats.count >= 5 {
            let staleCount = heartbeats.filter { $0.c?.im == true }.count
            let ratio = Double(staleCount) / Double(heartbeats.count)
            if ratio >= thresholds.imuStaleRatio {
                newAlerts.append(makeAlert(
                    id: "imu.window_stale",
                    severity: .warn,
                    title: "IMU stale 비율 \(percent(ratio))",
                    detail: "최근 \(Int(windowSeconds))초 heartbeat \(heartbeats.count) 중 \(staleCount) stale."
                ))
            }
        }

        // 3) 연결 실패 누적.
        let failures = windowed.filter { $0.k.rawValue == "connection.failure" }.count
        if failures >= thresholds.connectFailures {
            newAlerts.append(makeAlert(
                id: "connection.window_failures",
                severity: .warn,
                title: "연결 실패 \(failures) 회",
                detail: "최근 \(Int(windowSeconds))초 동안. USB / 드라이버 / 케이블 확인."
            ))
        }

        // 4) Bus write fail 누적.
        let busWrites = windowed.filter { $0.k.rawValue == "bus.write_fail" }.count
        if busWrites >= thresholds.busWriteFails {
            newAlerts.append(makeAlert(
                id: "bus.window_write_fail",
                severity: .warn,
                title: "Bus 쓰기 실패 \(busWrites) 회",
                detail: "최근 \(Int(windowSeconds))초. 모터 / power / cable."
            ))
        }

        // 5) E-stop / WalkLab emergency — 즉시 critical.
        let estops = windowed.filter {
            $0.k.rawValue == "bus.e_stop" || $0.k.rawValue == "walklab.emergency_stop"
        }
        if !estops.isEmpty {
            newAlerts.append(makeAlert(
                id: "estop.window",
                severity: .critical,
                title: "비상 정지 \(estops.count) 회",
                detail: "최근 \(Int(windowSeconds))초. 안전 점검 우선."
            ))
        }

        // 변화 diff — 토스트 발화.
        let oldIds = Set(active.map(\.id))
        let newIds = Set(newAlerts.map(\.id))
        let appeared = newAlerts.filter { !oldIds.contains($0.id) }

        // 토스트 발화.
        for alert in appeared {
            maybeFireToast(alert)
        }
        active = newAlerts

        // Cleanup firstObserved cache for alerts that disappeared.
        for id in oldIds where !newIds.contains(id) {
            firstObservedAt[id] = nil
        }
    }

    /// 모든 alert 강제 클리어 — 세션 종료 시 호출.
    public func reset() {
        active = []
        firstObservedAt = [:]
        lastNotifiedAt = [:]
    }

    // MARK: - helpers

    private func makeAlert(id: String, severity: ActiveAlert.Severity,
                            title: String, detail: String) -> ActiveAlert {
        // **v1.14.1 (Code-reviewer P1-1 fix)** — force unwrap 제거.
        // MainActor 격리라 race 없지만, 미래 refactor 안전성 위해 ?? Date() 폴백.
        let observed = firstObservedAt[id] ?? Date()
        firstObservedAt[id] = observed
        return ActiveAlert(id: id, severity: severity, title: title,
                            detail: detail, firstObservedAt: observed)
    }

    private func maybeFireToast(_ alert: ActiveAlert) {
        guard toastEnabled else { return }
        // Re-notify rate limit.
        if let last = lastNotifiedAt[alert.id],
           Date().timeIntervalSince(last) < Self.renotifyInterval { return }
        lastNotifiedAt[alert.id] = Date()
        // UserNotifications — 기존 코드 base 의 entitlement / permission 가정. 실패해도 silently skip.
        let content = UNMutableNotificationContent()
        content.title = "DarwinForge — \(alert.severity.rawValue.uppercased())"
        content.body = "\(alert.title)\n\(alert.detail)"
        content.sound = alert.severity == .critical ? .defaultCritical : .default
        let req = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in /* silent */ }
    }

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
    private func percent(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
}
