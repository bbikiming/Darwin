import Foundation

/// A1 — PilotLatencyTracer JSON session sink (cockpit-latency-hardening §6).
///
/// 비유: 경기가 끝나면 스코어보드를 사진 한 장으로 찍어 파일함에 넣는 일.
/// 경기(보행 세션) 중에는 손대지 않고, 끝날 때 tracer 의 6개 채널 요약을 그대로
/// 베껴 디스크에 atomic 으로 떨군다. 측정값(ms) 의 정확성은 로봇 실측 단계로
/// 미뤄졌고(robot-deferred), 이 sink 는 "구조가 충실한가"만 보장한다.
///
/// cold-path·read-only: tracer 의 PUBLIC `*Stats()` 접근자만 호출하고 상태를 절대
/// 변경하지 않는다. 호출은 세션 종료 시 1회.

/// 한 채널의 분포 요약(JSON 직렬화용). `PilotLatencyTracer.Stats` 의 거울.
public struct LatencyChannelStat: Codable, Equatable, Sendable {
    public let count: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let maxAbsMs: Double

    public init(_ stats: PilotLatencyTracer.Stats) {
        count = stats.count
        p50Ms = stats.p50Ms
        p95Ms = stats.p95Ms
        maxAbsMs = stats.maxAbsMs
    }
}

/// 한 세션의 레이턴시 리포트. 6개 채널 + 시작/종료 epoch-ms.
public struct LatencySessionReport: Codable, Equatable, Sendable {
    /// 채널명 → 요약. 키: jitter / write / imuRead / inputToSent / inputToAck / estopToSent.
    public let channels: [String: LatencyChannelStat]
    public let startedAtEpochMs: Int64
    public let endedAtEpochMs: Int64

    public init(channels: [String: LatencyChannelStat],
                startedAtEpochMs: Int64,
                endedAtEpochMs: Int64) {
        self.channels = channels
        self.startedAtEpochMs = startedAtEpochMs
        self.endedAtEpochMs = endedAtEpochMs
    }
}

/// 세션 종료 시 tracer 요약을 JSON 으로 떨구는 sink.
public struct PilotLatencyJSONSink: Sendable {

    /// epoch-ms 를 반환하는 시계(테스트 주입 가능).
    private let now: @Sendable () -> Int64

    public init(now: @escaping @Sendable () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1000)
    }) {
        self.now = now
    }

    /// 기본 저장 디렉터리: Application Support/DarwinForge/latency.
    /// 항상 주입 가능(테스트는 temp/UUID 사용). 도메인 조회 실패 시 nil.
    public static func defaultDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false) else { return nil }
        return base
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("latency", isDirectory: true)
    }

    /// tracer 의 6개 채널 요약을 **읽기 전용**으로 베껴 리포트를 만든다.
    /// `*Stats()` 접근자만 호출 — tracer 상태 불변.
    public func report(from tracer: PilotLatencyTracer) -> LatencySessionReport {
        let channels: [String: LatencyChannelStat] = [
            "jitter": LatencyChannelStat(tracer.jitterStats()),
            "write": LatencyChannelStat(tracer.writeStats()),
            "imuRead": LatencyChannelStat(tracer.imuReadStats()),
            "inputToSent": LatencyChannelStat(tracer.inputToSentStats()),
            "inputToAck": LatencyChannelStat(tracer.inputToAckStats()),
            "estopToSent": LatencyChannelStat(tracer.estopToSentStats())
        ]
        let ts = now()
        return LatencySessionReport(channels: channels,
                                    startedAtEpochMs: ts,
                                    endedAtEpochMs: ts)
    }

    /// 리포트를 `<dir>/<epochMs>.json` 으로 atomic 하게 떨군다. 생성된 URL 반환.
    /// 디렉터리는 중간 경로 포함해 생성.
    @discardableResult
    public func persist(_ report: LatencySessionReport, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let url = dir.appendingPathComponent("\(report.endedAtEpochMs).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// **A1 게이트(테스트 가능 단일 결정점)** — tracer 가 활성일 때만 요약을 떨군다.
    ///
    /// 비활성(`!tracer.isEnabled`)이면 **아무 파일도 쓰지 않고** `nil` 을 반환한다.
    /// robot-deferred 측정값이라 비활성 세션은 기록 가치가 없고, 게이트가 sink
    /// 내부에 있으므로 호출처(패널 onDisappear)는 이 한 줄만 호출하면 된다. read-only:
    /// `report(from:)` 가 `*Stats()` 접근자만 호출하므로 tracer 상태는 불변.
    ///
    /// - Returns: 기록된 파일 URL, 또는 tracer 비활성 시 `nil`.
    @discardableResult
    public func persistIfEnabled(tracer: PilotLatencyTracer, into dir: URL) throws -> URL? {
        guard tracer.isEnabled else { return nil }
        let report = report(from: tracer)
        return try persist(report, into: dir)
    }
}
