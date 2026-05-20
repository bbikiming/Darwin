import Foundation

// MARK: - SessionAnalysis (v1.13.0, 2026-05-20)
//
// Pure 분석 계층 — events.jsonl 을 입력받아 (1) 요약 통계 (2) namespace 타임라인 버킷
// (3) 에러 envelopes 를 한 번에 계산. UI / Markdown export / 비교 (diff) 등이 모두
// 동일한 모델을 소비.
//
// **왜 분리?**
// - UI 와 export 가 동일 데이터로 동작 → drift 없음.
// - Pure 함수 → XCTest 에서 fixture 이벤트로 단위 검증.
// - HarnessFileReader 가 디스크에서 events 를 가져오면 그 다음은 메모리 연산만.

/// Namespace 별 카운트 — Equatable 가능한 explicit struct.
public struct NamespaceCount: Sendable, Equatable, Identifiable {
    public let namespace: String
    public let count: Int
    public var id: String { namespace }
}

/// 세션의 통계 요약. Inspector summary 카드 + Markdown 리포트 헤더에 모두 사용.
public struct SessionSummary: Sendable, Equatable {
    /// 전체 이벤트 수.
    public let totalEvents: Int
    /// `app.launch`, `app.terminate` ISO 시각 — nil 가능 (비정상 종료).
    public let firstEventAt: String?
    public let lastEventAt: String?
    public let durationSeconds: Double?

    /// 연결 라이프사이클 카운터.
    public let connectAttempts: Int
    public let connectSuccesses: Int
    public let connectFailures: Int
    public let disconnects: Int

    /// 에러 / 경고 카운터.
    public let errorCount: Int          // level == .error
    public let warnCount: Int           // level == .warn
    public let busReadFailures: Int
    public let busWriteFailures: Int
    public let eStops: Int

    /// 워크랩 / 모션 / 자세 라이프사이클.
    public let walkLabStarts: Int
    public let walkLabStops: Int
    public let walkLabEmergencyStops: Int
    public let walkLabStartBlocks: Int
    public let motionPlays: Int
    public let motionCompletes: Int
    public let poseApplies: Int

    /// 사용자 자세 캡쳐 / 라이브러리.
    public let teachSnapshots: Int
    public let poseLibrarySaves: Int

    /// Heartbeat 기반 metric 트렌드 — 평균 / 최솟값 / 최댓값.
    public let rttMs: Stats?            // RTT (heartbeat / connect_success)
    public let batteryV: Stats?         // battery voltage
    public let imuStaleRatio: Double?   // heartbeat 중 imu_stale=true 비율 (0~1)

    /// Namespace 별 카운트 — UI strip + Markdown 분포.
    public let namespaceCounts: [NamespaceCount]

    public struct Stats: Sendable, Equatable {
        public let count: Int
        public let mean: Double
        public let min: Double
        public let max: Double
        public let p95: Double
    }
}

/// 단일 시간 구간 — 타임라인 strip 의 한 칸.
public struct TimelineBin: Sendable, Equatable, Identifiable {
    /// `[start, end)` UNIX seconds.
    public let start: Double
    public let end: Double
    /// 이 칸에 속한 이벤트의 namespace 별 count.
    public let counts: [String: Int]
    /// 가장 심각한 level — UI 색상 결정.
    public let peakLevel: TelemetryLevel

    public var id: Double { start }
    public var totalCount: Int { counts.values.reduce(0, +) }
}

/// 에러 / 경고 이벤트 + 직전/직후 ±N초 컨텍스트.
public struct ErrorEnvelope: Sendable, Equatable, Identifiable {
    /// 본 에러 / 경고 이벤트.
    public let trigger: TelemetryEvent
    /// 직전 N 개 이벤트 (시간 오름차순).
    public let preceding: [TelemetryEvent]
    /// 직후 N 개 이벤트 (시간 오름차순).
    public let following: [TelemetryEvent]
    /// envelope 의 시간 폭 (초).
    public let windowSeconds: Double

    public var id: String { trigger.id }
}

/// 분석 결과 컨테이너.
public struct SessionAnalysis: Sendable {
    public let summary: SessionSummary
    public let timeline: [TimelineBin]
    public let errors: [ErrorEnvelope]
    public let bookmarks: [TelemetryEvent]
    public let dropped: UInt64
}

// MARK: - Public API

public enum SessionAnalyzer {

    /// **고도화 1**: events 한 묶음 → SessionAnalysis.
    /// 이벤트 배열은 시간순 (oldest → newest) 이라 가정. HarnessFileReader 가 그렇게 반환.
    public static func analyze(events: [TelemetryEvent],
                                timelineBins: Int = 60,
                                envelopeWindowSeconds: Double = 10,
                                envelopeContextCount: Int = 5) -> SessionAnalysis {
        guard !events.isEmpty else {
            return SessionAnalysis(
                summary: emptySummary(),
                timeline: [],
                errors: [],
                bookmarks: [],
                dropped: 0
            )
        }

        let summary = computeSummary(events: events)
        let timeline = computeTimeline(events: events, binCount: timelineBins)
        let envelopes = computeEnvelopes(
            events: events,
            windowSeconds: envelopeWindowSeconds,
            contextCount: envelopeContextCount
        )
        let bookmarks = events.filter { $0.k.rawValue == TelemetryKind.uiBookmark.rawValue }
        let drops = events.reduce(UInt64(0)) { acc, ev in
            guard ev.k.rawValue == TelemetryKind.harnessDropped.rawValue else { return acc }
            if let n = (ev.d.raw["count"]?.value as? Int) { return acc &+ UInt64(n) }
            if let u = (ev.d.raw["count"]?.value as? UInt64) { return acc &+ u }
            return acc
        }

        return SessionAnalysis(
            summary: summary,
            timeline: timeline,
            errors: envelopes,
            bookmarks: bookmarks,
            dropped: drops
        )
    }

    // MARK: Summary

    private static func computeSummary(events: [TelemetryEvent]) -> SessionSummary {
        let first = events.first?.tw
        let last = events.last?.tw
        let durationSec: Double? = {
            guard let f = first, let l = last,
                  let fd = parseIso(f), let ld = parseIso(l) else { return nil }
            return max(0, ld.timeIntervalSince(fd))
        }()

        // 카운터들 — single pass.
        var connectAttempts = 0
        var connectSuccesses = 0
        var connectFailures = 0
        var disconnects = 0
        var errorCount = 0
        var warnCount = 0
        var busReadFailures = 0
        var busWriteFailures = 0
        var eStops = 0
        var walkLabStarts = 0
        var walkLabStops = 0
        var walkLabEmergencyStops = 0
        var walkLabStartBlocks = 0
        var motionPlays = 0
        var motionCompletes = 0
        var poseApplies = 0
        var teachSnapshots = 0
        var poseLibrarySaves = 0
        var namespaceCount: [String: Int] = [:]

        var rtts: [Double] = []
        var voltages: [Double] = []
        var heartbeatCount = 0
        var imuStaleCount = 0

        for ev in events {
            switch ev.lv {
            case .error: errorCount += 1
            case .warn: warnCount += 1
            default: break
            }
            namespaceCount[ev.k.namespace, default: 0] += 1

            switch ev.k.rawValue {
            case TelemetryKind.connectAttempt.rawValue: connectAttempts += 1
            case TelemetryKind.connectSuccess.rawValue: connectSuccesses += 1
            case TelemetryKind.connectFailure.rawValue: connectFailures += 1
            case TelemetryKind.connectDisconnect.rawValue: disconnects += 1
            case TelemetryKind.busReadFail.rawValue: busReadFailures += 1
            case TelemetryKind.busWriteFail.rawValue: busWriteFailures += 1
            case TelemetryKind.busEStop.rawValue: eStops += 1
            case TelemetryKind.walkLabStart.rawValue: walkLabStarts += 1
            case TelemetryKind.walkLabStop.rawValue: walkLabStops += 1
            case TelemetryKind.walkLabEmergencyStop.rawValue: walkLabEmergencyStops += 1
            case TelemetryKind.walkLabStartBlocked.rawValue: walkLabStartBlocks += 1
            case TelemetryKind.motionPlayStart.rawValue: motionPlays += 1
            case TelemetryKind.motionPlayComplete.rawValue: motionCompletes += 1
            case TelemetryKind.poseApplyStart.rawValue: poseApplies += 1
            case TelemetryKind.teachSnapshotCaptured.rawValue: teachSnapshots += 1
            case TelemetryKind.poseLibrarySaved.rawValue: poseLibrarySaves += 1
            default: break
            }

            // Context 의 RTT / battery / IMU stale.
            if let ctx = ev.c {
                if let r = ctx.rt { rtts.append(r) }
                if let v = ctx.bv { voltages.append(v) }
                if ev.k.rawValue == TelemetryKind.heartbeat.rawValue {
                    heartbeatCount += 1
                    if ctx.im == true { imuStaleCount += 1 }
                }
            }
            // connect_success 의 data.rtt_ms 도 RTT sample.
            if ev.k.rawValue == TelemetryKind.connectSuccess.rawValue,
               let r = (ev.d.raw["rtt_ms"]?.value as? Double) {
                rtts.append(r)
            }
        }

        let rttStats = Stats.from(rtts)
        let battStats = Stats.from(voltages)
        let imuStaleRatio: Double? = heartbeatCount > 0
            ? Double(imuStaleCount) / Double(heartbeatCount)
            : nil
        let nsCounts = namespaceCount
            .map { NamespaceCount(namespace: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        return SessionSummary(
            totalEvents: events.count,
            firstEventAt: first, lastEventAt: last,
            durationSeconds: durationSec,
            connectAttempts: connectAttempts,
            connectSuccesses: connectSuccesses,
            connectFailures: connectFailures,
            disconnects: disconnects,
            errorCount: errorCount, warnCount: warnCount,
            busReadFailures: busReadFailures,
            busWriteFailures: busWriteFailures,
            eStops: eStops,
            walkLabStarts: walkLabStarts,
            walkLabStops: walkLabStops,
            walkLabEmergencyStops: walkLabEmergencyStops,
            walkLabStartBlocks: walkLabStartBlocks,
            motionPlays: motionPlays,
            motionCompletes: motionCompletes,
            poseApplies: poseApplies,
            teachSnapshots: teachSnapshots,
            poseLibrarySaves: poseLibrarySaves,
            rttMs: rttStats,
            batteryV: battStats,
            imuStaleRatio: imuStaleRatio,
            namespaceCounts: nsCounts
        )
    }

    // MARK: Timeline

    private static func computeTimeline(events: [TelemetryEvent], binCount: Int) -> [TimelineBin] {
        guard binCount > 0,
              let firstStr = events.first?.tw, let lastStr = events.last?.tw,
              let first = parseIso(firstStr), let last = parseIso(lastStr),
              last > first else { return [] }
        let span = last.timeIntervalSince(first)
        let binSize = max(0.001, span / Double(binCount))

        // bin index → counts + peak level.
        var bins: [(start: Double, counts: [String: Int], peak: TelemetryLevel)] =
            (0..<binCount).map { i in
                let s = first.timeIntervalSince1970 + Double(i) * binSize
                return (start: s, counts: [:], peak: .trace)
            }

        for ev in events {
            guard let dt = parseIso(ev.tw) else { continue }
            let offset = dt.timeIntervalSince(first)
            var idx = Int(offset / binSize)
            if idx < 0 { idx = 0 }
            if idx >= binCount { idx = binCount - 1 }
            bins[idx].counts[ev.k.namespace, default: 0] += 1
            if levelRank(ev.lv) > levelRank(bins[idx].peak) {
                bins[idx].peak = ev.lv
            }
        }

        return bins.map { b in
            TimelineBin(
                start: b.start,
                end: b.start + binSize,
                counts: b.counts,
                peakLevel: b.peak
            )
        }
    }

    private static func levelRank(_ l: TelemetryLevel) -> Int {
        switch l {
        case .trace: return 0
        case .info: return 1
        case .notice: return 2
        case .warn: return 3
        case .error: return 4
        }
    }

    // MARK: Envelopes

    private static func computeEnvelopes(events: [TelemetryEvent],
                                          windowSeconds: Double,
                                          contextCount: Int) -> [ErrorEnvelope] {
        // Trigger = level == .error || .warn.
        // 동일 envelope 안에 trigger 가 여러 개 들어가면 묶음.
        var result: [ErrorEnvelope] = []
        var i = 0
        while i < events.count {
            let ev = events[i]
            guard ev.lv == .error || ev.lv == .warn else { i += 1; continue }

            // 직전 N 개.
            let preceding: [TelemetryEvent] = {
                let lo = max(0, i - contextCount)
                return Array(events[lo..<i])
            }()
            // 직후 N 개.
            let following: [TelemetryEvent] = {
                let hi = min(events.count, i + 1 + contextCount)
                return Array(events[(i + 1)..<hi])
            }()
            result.append(ErrorEnvelope(
                trigger: ev,
                preceding: preceding,
                following: following,
                windowSeconds: windowSeconds
            ))
            i += 1
        }
        return result
    }

    // MARK: Helpers

    private static func emptySummary() -> SessionSummary {
        SessionSummary(
            totalEvents: 0,
            firstEventAt: nil, lastEventAt: nil, durationSeconds: nil,
            connectAttempts: 0, connectSuccesses: 0,
            connectFailures: 0, disconnects: 0,
            errorCount: 0, warnCount: 0,
            busReadFailures: 0, busWriteFailures: 0, eStops: 0,
            walkLabStarts: 0, walkLabStops: 0,
            walkLabEmergencyStops: 0, walkLabStartBlocks: 0,
            motionPlays: 0, motionCompletes: 0, poseApplies: 0,
            teachSnapshots: 0, poseLibrarySaves: 0,
            rttMs: nil, batteryV: nil, imuStaleRatio: nil,
            namespaceCounts: []
        )
    }

    /// **v1.14.1 (Critic P3-1 / Code-reviewer P2-1 fix, 2026-05-21)** — ISO8601DateFormatter
    /// 가 매 호출마다 새로 생성되던 비용 제거. `HarnessInsights.countFlappingCycles` 의
    /// O(N²) 루프 안에서 호출되므로 5000 event 세션에서 수백만 alloc 발생했음.
    /// 단일 static instance 재사용 (Foundation 의 ISO8601DateFormatter 는 thread-safe).
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO 8601 with fractional seconds 파서. 모듈 안 공용. **캐시된 인스턴스 사용**.
    static func parseIso(_ s: String) -> Date? {
        return isoParser.date(from: s)
    }
}

// MARK: - Stats helper (private)

private enum Stats {
    static func from(_ values: [Double]) -> SessionSummary.Stats? {
        guard !values.isEmpty else { return nil }
        let count = values.count
        let mean = values.reduce(0, +) / Double(count)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 0
        let sorted = values.sorted()
        let p95Index = max(0, min(sorted.count - 1, Int(Double(sorted.count) * 0.95)))
        let p95 = sorted[p95Index]
        return SessionSummary.Stats(count: count, mean: mean, min: lo, max: hi, p95: p95)
    }
}

// MARK: - Free helper used by tests + extension.

extension SessionSummary {
    /// 사람이 읽기 쉬운 short form 시간.
    public func durationLabel() -> String? {
        guard let s = durationSeconds else { return nil }
        if s < 60 { return String(format: "%.0f초", s) }
        if s < 3600 { return String(format: "%d분 %d초", Int(s) / 60, Int(s) % 60) }
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        return String(format: "%d시간 %d분", h, m)
    }
}
