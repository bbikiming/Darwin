import Foundation

// MARK: - SSHConnectionDiagnostics (2026-06-02)
//
// SSH 연결 + 제어 명령 전용 진단 분석기. `SessionAnalysis`(범용)와 별개로, "무선 SSH
// 조종이 안정적이었나 / 왜 느렸나 / 왜 끊겼나"에 답하는 **집중 리포트**.
//
// 입력: events.jsonl 한 묶음(Inspector 가 이미 디스크에서 로드하는 그 배열).
// 출력: 성공률 · 지연 분포(p50/p95/max) · 실패 원인별 분해 · 카테고리별("무엇을
//       조종했나") · 최악(가장 느리거나 실패한) 명령 목록.
//
// **순수 함수** — 실 로봇/디스크 없이 XCTest 로 검증(SSHConnectionDiagnosticsTests).
//
// 비유: 콜센터 일일 리포트. 총 통화 수, 평균/최장 대기시간, 끊긴 전화의 사유별 집계,
// 가장 오래 걸린 통화 Top N. 어디를 개선할지 한눈에.

/// SSH 연결/제어 진단 리포트. Equatable — 테스트 + 세션 간 비교.
public struct SSHConnectionDiagnosticsReport: Sendable, Equatable {

    /// 지연(ms) 분포 — responded 명령의 왕복 시간.
    public struct Latency: Sendable, Equatable {
        public let count: Int
        public let p50: Double
        public let p95: Double
        public let max: Double
        public let mean: Double
    }

    /// key→count 집계 한 줄(내림차순 정렬용).
    public struct Tally: Sendable, Equatable, Identifiable {
        public let key: String
        public let count: Int
        public var id: String { key }
    }

    /// 최악(느리거나 실패한) 명령 한 건 — drill-down 용.
    public struct SlowCommand: Sendable, Equatable, Identifiable {
        public let seq: UInt64
        public let at: String           // ISO-8601 wall clock
        public let category: String
        public let elapsedMs: Int
        public let outcome: String      // "ok" / "nonzero(N)" / error_case
        public let cmdHash: String
        public var id: String { "\(seq)" }
    }

    // 명령 카운트.
    public let commandsSent: Int
    public let commandsResponded: Int
    public let commandsErrored: Int
    /// responded 인데 exit_code != 0 — 로봇이 명령을 거부/실패 처리한 수.
    public let nonzeroExits: Int
    /// ok 응답 / (responded + errored). denom 0 → nil.
    public let successRate: Double?

    // 지연 + 분해.
    public let latency: Latency?
    public let errorBreakdown: [Tally]      // error_case 별(내림차순)
    public let categoryBreakdown: [Tally]   // "무엇을 조종했나"(내림차순)
    public let channelTransitions: Int

    // 연결 라이프사이클.
    public let connectAttempts: Int
    public let connectSuccesses: Int
    public let connectFailures: Int
    public let reconnectAttempts: Int

    // drill-down.
    public let slowest: [SlowCommand]

    /// 의미 있는 SSH/연결 이벤트가 전혀 없는가(리포트 표시 생략 판단용).
    public var isEmpty: Bool {
        commandsSent == 0 && commandsResponded == 0 && commandsErrored == 0 &&
        connectAttempts == 0 && channelTransitions == 0
    }
}

// MARK: - 분석기

public enum SSHConnectionDiagnostics {

    /// events → 리포트. 이벤트 배열은 시간순(oldest→newest) 가정.
    public static func analyze(events: [TelemetryEvent],
                               slowestCount: Int = 8) -> SSHConnectionDiagnosticsReport {
        var sent = 0, responded = 0, errored = 0, nonzero = 0
        var okCount = 0
        var channelTransitions = 0
        var connectAttempts = 0, connectSuccesses = 0, connectFailures = 0, reconnects = 0

        var latencies: [Double] = []
        var errorCases: [String: Int] = [:]
        var categories: [String: Int] = [:]
        var slow: [SSHConnectionDiagnosticsReport.SlowCommand] = []

        for ev in events {
            switch ev.k.rawValue {
            case TelemetryKind.remoteCommandSent.rawValue:
                sent += 1
                let cat = stringField(ev, "category") ?? "other"
                categories[cat, default: 0] += 1

            case TelemetryKind.remoteCommandResponded.rawValue:
                responded += 1
                let elapsed = intField(ev, "elapsed_ms") ?? 0
                latencies.append(Double(elapsed))
                let ok = boolField(ev, "ok") ?? true
                if ok { okCount += 1 } else { nonzero += 1 }
                let exitCode = intField(ev, "exit_code") ?? 0
                slow.append(.init(
                    seq: ev.i, at: ev.tw,
                    category: stringField(ev, "category") ?? "other",
                    elapsedMs: elapsed,
                    outcome: ok ? "ok" : "nonzero(\(exitCode))",
                    cmdHash: stringField(ev, "cmd_hash") ?? ""))

            case TelemetryKind.remoteCommandError.rawValue:
                errored += 1
                let code = stringField(ev, "error_case") ?? "generic"
                errorCases[code, default: 0] += 1
                let elapsed = intField(ev, "elapsed_ms") ?? 0
                slow.append(.init(
                    seq: ev.i, at: ev.tw,
                    category: stringField(ev, "category") ?? "other",
                    elapsedMs: elapsed,
                    outcome: code,
                    cmdHash: stringField(ev, "cmd_hash") ?? ""))

            case TelemetryKind.remoteChannelChanged.rawValue:
                channelTransitions += 1

            case TelemetryKind.connectAttempt.rawValue:        connectAttempts += 1
            case TelemetryKind.connectSuccess.rawValue:        connectSuccesses += 1
            case TelemetryKind.connectFailure.rawValue:        connectFailures += 1
            case TelemetryKind.connectReconnectAttempt.rawValue: reconnects += 1
            default: break
            }
        }

        let denom = responded + errored
        let successRate: Double? = denom > 0 ? Double(okCount) / Double(denom) : nil

        let latency: SSHConnectionDiagnosticsReport.Latency? = {
            guard !latencies.isEmpty else { return nil }
            let sorted = latencies.sorted()
            return .init(
                count: sorted.count,
                p50: percentile(sorted, 0.50),
                p95: percentile(sorted, 0.95),
                max: sorted.last ?? 0,
                mean: sorted.reduce(0, +) / Double(sorted.count))
        }()

        let slowest = slow.sorted { $0.elapsedMs > $1.elapsedMs }
            .prefix(slowestCount)
            .map { $0 }

        return SSHConnectionDiagnosticsReport(
            commandsSent: sent,
            commandsResponded: responded,
            commandsErrored: errored,
            nonzeroExits: nonzero,
            successRate: successRate,
            latency: latency,
            errorBreakdown: tally(errorCases),
            categoryBreakdown: tally(categories),
            channelTransitions: channelTransitions,
            connectAttempts: connectAttempts,
            connectSuccesses: connectSuccesses,
            connectFailures: connectFailures,
            reconnectAttempts: reconnects,
            slowest: Array(slowest))
    }

    // MARK: Markdown

    /// 리포트 → markdown 섹션. SessionMarkdownReport / Claude 공유용.
    public static func markdown(_ r: SSHConnectionDiagnosticsReport) -> String {
        var out: [String] = []
        out.append("## SSH 연결·조종 진단")
        out.append("")
        if r.isEmpty {
            out.append("_이 세션엔 SSH 제어/연결 이벤트가 없습니다._")
            return out.joined(separator: "\n")
        }

        out.append("| 항목 | 값 |")
        out.append("|------|----|")
        out.append("| 연결 시도 / 성공 / 실패 | \(r.connectAttempts) / \(r.connectSuccesses) / \(r.connectFailures) |")
        out.append("| 재연결 시도 | \(r.reconnectAttempts) |")
        out.append("| 채널 전환(ssh ↔ unavailable) | \(r.channelTransitions) |")
        out.append("| 명령 송신 / 응답 / 실패 | \(r.commandsSent) / \(r.commandsResponded) / \(r.commandsErrored) |")
        out.append("| 로봇 거부(비-0 exit) | \(r.nonzeroExits) |")
        if let sr = r.successRate {
            out.append("| 명령 성공률 | \(pct(sr)) |")
        }
        out.append("")

        if let l = r.latency {
            out.append("### 명령 왕복 지연 (ms)")
            out.append("")
            out.append("| count | p50 | p95 | max | mean |")
            out.append("|------:|----:|----:|----:|-----:|")
            out.append("| \(l.count) | \(ms(l.p50)) | \(ms(l.p95)) | \(ms(l.max)) | \(ms(l.mean)) |")
            out.append("")
        }

        if !r.categoryBreakdown.isEmpty {
            out.append("### 무엇을 조종했나 (카테고리별 송신)")
            out.append("")
            out.append("| 카테고리 | 횟수 |")
            out.append("|----------|-----:|")
            for t in r.categoryBreakdown { out.append("| `\(t.key)` | \(t.count) |") }
            out.append("")
        }

        if !r.errorBreakdown.isEmpty {
            out.append("### 실패 원인별 분해")
            out.append("")
            out.append("| 원인 | 횟수 |")
            out.append("|------|-----:|")
            for t in r.errorBreakdown { out.append("| `\(t.key)` | \(t.count) |") }
            out.append("")
        }

        if !r.slowest.isEmpty {
            out.append("### 가장 느리거나 실패한 명령 (Top \(r.slowest.count))")
            out.append("")
            out.append("| seq | 시각 | 카테고리 | 지연(ms) | 결과 | cmd_hash |")
            out.append("|----:|------|----------|--------:|------|----------|")
            for s in r.slowest {
                out.append("| `#\(s.seq)` | \(briefIso(s.at)) | `\(s.category)` | \(s.elapsedMs) | `\(s.outcome)` | `\(s.cmdHash)` |")
            }
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    // MARK: - 내부 helpers

    /// 최근접 순위(nearest-rank) 백분위. sorted 는 오름차순.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1))
        return sorted[idx]
    }

    private static func tally(_ dict: [String: Int]) -> [SSHConnectionDiagnosticsReport.Tally] {
        dict.map { .init(key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    // AnyCodable 필드 안전 추출 — 디스크 round-trip(Int/Double/String) 모두 수용.
    private static func stringField(_ ev: TelemetryEvent, _ key: String) -> String? {
        ev.d.raw[key]?.value as? String
    }
    private static func boolField(_ ev: TelemetryEvent, _ key: String) -> Bool? {
        ev.d.raw[key]?.value as? Bool
    }
    private static func intField(_ ev: TelemetryEvent, _ key: String) -> Int? {
        if let i = ev.d.raw[key]?.value as? Int { return i }
        if let d = ev.d.raw[key]?.value as? Double { return Int(d) }
        if let s = ev.d.raw[key]?.value as? String { return Int(s) }
        return nil
    }

    private static func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }
    private static func ms(_ d: Double) -> String { String(format: "%.0f", d) }

    private static func briefIso(_ s: String) -> String {
        guard let d = SessionAnalyzer.parseIso(s) else { return s }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
