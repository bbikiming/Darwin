import Foundation

// MARK: - SessionJSONReport (v1.14.0, 2026-05-20)
//
// Claude / 외부 도구가 받아 분석할 수 있는 구조화 JSON. SessionMarkdownReport 와
// 짝 — 사람용 (markdown) / AI 용 (JSON) 두 채널.
//
// 자세한 설계: docs/harness/log-utilization-system.md

/// 외부 도구 / Claude 가 의존할 안정 schema.
/// 필드 이름은 명시 (event schema 와 분리, 외부 호환성 우선).
public struct SessionJSONReport: Codable, Sendable {
    public let schema: String              // "darwinforge-harness/1.0"
    public let session: SessionBlock
    public let summary: SummaryBlock
    public let timeline: [TimelineBlock]
    public let errors: [ErrorBlock]
    public let insights: [InsightBlock]
    public let bookmarks: [BookmarkBlock]
    public let diff: DiffBlock?

    // MARK: blocks

    public struct SessionBlock: Codable, Sendable {
        public let id: String
        public let shortId: String
        public let started: String
        public let ended: String?
        public let durationSeconds: Double?
        public let appVersion: String
        public let appBuild: String
        public let os: String
        public let device: String
        public let pinned: Bool
        public let isBaseline: Bool
    }

    public struct SummaryBlock: Codable, Sendable {
        public let totalEvents: Int
        public let dropped: UInt64
        public let connection: ConnectionStats
        public let bus: BusStats
        public let imu: ImuStats?
        public let walklab: WalkLabStats
        public let motion: MotionStats
        public let teach: TeachStats
        public let rttMs: NumericStats?
        public let batteryV: NumericStats?
        public let namespaceCounts: [NamespaceCountBlock]
    }
    public struct ConnectionStats: Codable, Sendable {
        public let attempts: Int
        public let successes: Int
        public let failures: Int
        public let disconnects: Int
        public let successRate: Double?
    }
    public struct BusStats: Codable, Sendable {
        public let readFailures: Int
        public let writeFailures: Int
        public let eStops: Int
    }
    public struct ImuStats: Codable, Sendable {
        public let staleRatio: Double
    }
    public struct WalkLabStats: Codable, Sendable {
        public let starts: Int
        public let stops: Int
        public let emergencyStops: Int
        public let startBlocks: Int
    }
    public struct MotionStats: Codable, Sendable {
        public let plays: Int
        public let completes: Int
        public let poseApplies: Int
    }
    public struct TeachStats: Codable, Sendable {
        public let snapshots: Int
        public let librarySaves: Int
    }
    public struct NumericStats: Codable, Sendable {
        public let count: Int
        public let mean: Double
        public let min: Double
        public let max: Double
        public let p95: Double
    }
    public struct NamespaceCountBlock: Codable, Sendable {
        public let namespace: String
        public let count: Int
    }
    public struct TimelineBlock: Codable, Sendable {
        public let startEpoch: Double
        public let endEpoch: Double
        public let total: Int
        public let peakLevel: String
        public let counts: [String: Int]
    }
    public struct ErrorBlock: Codable, Sendable {
        public let triggerSeq: UInt64
        public let triggerKind: String
        public let triggerLevel: String
        public let wall: String
        public let payload: [String: AnyCodable]
        public let precedingKinds: [String]
        public let followingKinds: [String]
    }
    public struct InsightBlock: Codable, Sendable {
        public let ruleID: String
        public let severity: String
        public let kind: String
        public let title: String
        public let evidence: String
        public let recommendation: String
        public let eventRefs: [UInt64]
        public let confidence: Double
    }
    public struct BookmarkBlock: Codable, Sendable {
        public let seq: UInt64
        public let wall: String
        public let lenHash: String?
    }
    public struct DiffBlock: Codable, Sendable {
        public let baselineId: String
        public let weightedScorePercent: Double
        public let verdict: String       // "improvement" | "regression" | "similar"
        public let verdictReason: String?
        public let metrics: [MetricBlock]
        public let counts: [CountBlock]
    }
    public struct MetricBlock: Codable, Sendable {
        public let label: String
        public let baseline: Double?
        public let current: Double?
        public let deltaPercent: Double?
        public let lowerIsBetter: Bool
    }
    public struct CountBlock: Codable, Sendable {
        public let label: String
        public let baseline: Int
        public let current: Int
        public let delta: Int
        public let lowerIsBetter: Bool
    }
}

public enum SessionJSONRenderer {

    /// `meta + analysis + events + insights + (optional) diff` → 구조화 JSON.
    public static func render(meta: TelemetrySessionMeta,
                                analysis: SessionAnalysis,
                                events: [TelemetryEvent],
                                insights: [Insight],
                                diff: SessionDiff? = nil) -> SessionJSONReport {
        let session = SessionJSONReport.SessionBlock(
            id: meta.id,
            shortId: String(meta.id.prefix(8)),
            started: meta.started,
            ended: meta.ended,
            durationSeconds: analysis.summary.durationSeconds,
            appVersion: meta.appVersion,
            appBuild: meta.appBuild,
            os: meta.os,
            device: meta.device,
            pinned: meta.pinned,
            isBaseline: meta.isBaseline
        )

        let s = analysis.summary
        let summary = SessionJSONReport.SummaryBlock(
            totalEvents: s.totalEvents,
            dropped: analysis.dropped,
            connection: .init(
                attempts: s.connectAttempts,
                successes: s.connectSuccesses,
                failures: s.connectFailures,
                disconnects: s.disconnects,
                successRate: s.connectAttempts > 0
                    ? Double(s.connectSuccesses) / Double(s.connectAttempts) : nil
            ),
            bus: .init(readFailures: s.busReadFailures,
                       writeFailures: s.busWriteFailures,
                       eStops: s.eStops),
            imu: s.imuStaleRatio.map { .init(staleRatio: $0) },
            walklab: .init(starts: s.walkLabStarts,
                           stops: s.walkLabStops,
                           emergencyStops: s.walkLabEmergencyStops,
                           startBlocks: s.walkLabStartBlocks),
            motion: .init(plays: s.motionPlays,
                          completes: s.motionCompletes,
                          poseApplies: s.poseApplies),
            teach: .init(snapshots: s.teachSnapshots,
                         librarySaves: s.poseLibrarySaves),
            rttMs: s.rttMs.map { .init(count: $0.count, mean: $0.mean, min: $0.min, max: $0.max, p95: $0.p95) },
            batteryV: s.batteryV.map { .init(count: $0.count, mean: $0.mean, min: $0.min, max: $0.max, p95: $0.p95) },
            namespaceCounts: s.namespaceCounts.map { .init(namespace: $0.namespace, count: $0.count) }
        )

        let timeline = analysis.timeline.map {
            SessionJSONReport.TimelineBlock(
                startEpoch: $0.start, endEpoch: $0.end,
                total: $0.totalCount, peakLevel: $0.peakLevel.rawValue,
                counts: $0.counts
            )
        }

        // **v1.14.1 (Security P1-1 fix, 2026-05-21)** — JSON export 가 외부로 갈 때
        // 임의 hook site 의 raw 문자열이 누출될 수 있어 allow-list 기반 scrubPayload 통과.
        let errors = analysis.errors.map { env -> SessionJSONReport.ErrorBlock in
            SessionJSONReport.ErrorBlock(
                triggerSeq: env.trigger.i,
                triggerKind: env.trigger.k.rawValue,
                triggerLevel: env.trigger.lv.rawValue,
                wall: env.trigger.tw,
                payload: HarnessRedaction.scrubPayload(env.trigger.d.raw),
                precedingKinds: env.preceding.map { $0.k.rawValue },
                followingKinds: env.following.map { $0.k.rawValue }
            )
        }

        let insightBlocks = insights.map { ins in
            SessionJSONReport.InsightBlock(
                ruleID: ins.ruleID, severity: ins.severity.rawValue,
                kind: ins.kind.rawValue, title: ins.title,
                evidence: ins.evidence, recommendation: ins.recommendation,
                eventRefs: ins.eventRefs, confidence: ins.confidence
            )
        }

        let bookmarks = analysis.bookmarks.map { ev in
            let lenHash: String? = {
                let len = (ev.d.raw["len"]?.value as? Int) ?? 0
                let hash = (ev.d.raw["hash"]?.value as? String) ?? "—"
                return "len=\(len) hash=\(hash)"
            }()
            return SessionJSONReport.BookmarkBlock(seq: ev.i, wall: ev.tw, lenHash: lenHash)
        }

        let diffBlock: SessionJSONReport.DiffBlock? = diff.map { d in
            let (verdict, reason): (String, String?) = {
                switch d.verdict {
                case .improvement(let r): return ("improvement", r)
                case .regression(let r): return ("regression", r)
                case .similar: return ("similar", nil)
                }
            }()
            return SessionJSONReport.DiffBlock(
                baselineId: d.baselineId,
                weightedScorePercent: d.weightedScorePercent,
                verdict: verdict, verdictReason: reason,
                metrics: d.metrics.map {
                    SessionJSONReport.MetricBlock(
                        label: $0.label, baseline: $0.baseline,
                        current: $0.current, deltaPercent: $0.deltaPercent,
                        lowerIsBetter: $0.lowerIsBetter
                    )
                },
                counts: d.counts.map {
                    SessionJSONReport.CountBlock(
                        label: $0.label, baseline: $0.baseline,
                        current: $0.current, delta: $0.delta,
                        lowerIsBetter: $0.lowerIsBetter
                    )
                }
            )
        }

        return SessionJSONReport(
            schema: "darwinforge-harness/1.0",
            session: session,
            summary: summary,
            timeline: timeline,
            errors: errors,
            insights: insightBlocks,
            bookmarks: bookmarks,
            diff: diffBlock
        )
    }

    /// 위 모델 → pretty JSON 문자열.
    public static func renderString(meta: TelemetrySessionMeta,
                                      analysis: SessionAnalysis,
                                      events: [TelemetryEvent],
                                      insights: [Insight],
                                      diff: SessionDiff? = nil) -> String {
        let report = render(meta: meta, analysis: analysis,
                             events: events, insights: insights, diff: diff)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(report),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
