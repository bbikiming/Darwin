/// **V287-1 — ADR-002 P99 < 5ms gate 실측 측정 harness**.
///
/// # 결론 (한 줄)
///
/// `WalkLabSession.tick()` 의 wall-clock latency 분포를 30초 (300 sample @ 10Hz)
/// 동안 측정 → `docs/architecture/baselines/walk_tick_<date>.json` 산출.
///
/// # 비유
///
/// 자동차 시속 100km 정속 30초 주행으로 평균 연비뿐 아니라 가속 spike, 최악 RPM
/// 까지 기록하는 OBD-II 로거와 같다. ADR-002 의 "P99 < 5ms" gate 는 평균이 아닌
/// tail percentile gate — 평균만 보면 outlier 가 숨는다.
///
/// # 측정 정책 (Google SRE Four Golden Signals — Latency SLI)
///
/// - **샘플 단위**: `tick()` 1회 = 1 sample (simTimer 의 10Hz fire 와 동일).
/// - **샘플 수**: 300 = 30초 × 10Hz (ADR-002 timing gate 의 1 trial 길이).
/// - **워밍업**: JIT/cache warm-up 으로 첫 50 sample discard (Swift release-mode
///   기준 macOS arm64 에서 첫 호출의 dyld lazy bind / metadata fault 영향 회피).
/// - **측정 함수**: `DispatchTime.now()` (mach_absolute_time wrapper, ns 정밀).
/// - **분포 통계**: P50/P95/P99/max + mean + stddev. tail 강조 (ADR gate=P99).
///
/// # XCTest 통합 vs CI smoke
///
/// 본 harness 는 **opt-in** — `DARWIN_BASELINE_RECORD=1` env var 가 set 된 경우에만
/// 실행. 일반 `swift test` 실행 시 `XCTSkipIf` 로 즉시 skip → 1,962 test suite 의
/// 100ms 정도 추가 비용도 부담 안 함.
///
/// 측정 실행:
/// ```bash
/// cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
/// DARWIN_BASELINE_RECORD=1 swift test -c release \
///   --filter WalkTickBaselineHarness/testRecordWalkTickP99Baseline 2>&1 | tail -30
/// ```
///
/// 산출 JSON 위치:
/// `docs/architecture/baselines/walk_tick_<YYYYMMDD-HHMMSS>.json`
///
/// # 한계 (반드시 명시)
///
/// 1. **release vs debug**: 본 harness 는 release build 권장 (`swift test -c release`).
///    debug build 는 ARC/Optional unwrap overhead 로 absolute number 가 2-3 배 부풀려진다.
/// 2. **CI vs dev machine**: GitHub Actions / Xcode Cloud 의 thermal/throttling 으로
///    absolute number ± 50% 변동. baseline 은 항상 **same machine** 에서 비교.
/// 3. **xctrace signpost vs direct call**: 본 harness 는 `tick()` 직접 호출 — 실제
///    simTimer 의 RunLoop dispatch 비용은 포함 안 됨. simTimer dispatch overhead 는
///    별도 < 50µs (Foundation Timer 의 typical jitter) — 5ms budget 의 1% 이하.
/// 3. **store=nil 환경**: bus polling phase 가 early-return → 실제 hardware 연결 시
///    `tickPollSensorsAndBalanceState` 가 +bus.readImu (50ms IMU budget) 가산. 본
///    baseline 은 **sim-only floor** — 실제 hardware 측정은 별도 trial 필요.
/// 4. **measurement overhead 자체**: `DispatchTime.now()` 호출 ~30ns × 600 = 18µs
///    — 5ms budget 의 0.4% 이하. 무시 가능.
///
/// # 비교 reference (V286-2 권고)
///
/// - Apple OSLog signposter (`com.yuseokkim.darwinforge` subsystem) 는 이미 emit 중.
///   xctrace 로 GUI 시작 → Walk Lab "보통 속도" preset 시작 후 30초 capture 가능.
///   본 harness 는 GUI 자동화 불가능 환경 대응 floor measurement.
/// - Google SRE Book — SLI 은 user-facing latency. `walk_tick` 은 robot 안전 loop
///   의 latency proxy. P99 5ms gate = error budget 1% 의 hard ceiling.
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

@MainActor
final class WalkTickBaselineHarness: XCTestCase {

    // MARK: - Configuration

    /// 30초 × 10Hz simTimer = 300 samples (ADR-002 timing gate 정의).
    private static let sampleCount: Int = 300

    /// JIT / cache warm-up — 첫 50 호출 discard.
    /// macOS arm64 release build 의 첫 호출은 dyld lazy bind / objc metadata fault
    /// 로 평균의 5-10 배 outlier. ADR gate 측정에서는 이 outlier 가 skew 발생.
    private static let warmupCount: Int = 50

    /// simTimer 의 `tickDtSec` 와 일치 — 10Hz = 100ms.
    private static let tickRateHz: Double = 10.0

    /// ADR-002 5ms P99 ceiling.
    private static let adrP99TargetMs: Double = 5.0

    // MARK: - Test (opt-in via env var)

    /// **opt-in harness** — `DARWIN_BASELINE_RECORD=1` 일 때만 실행.
    ///
    /// 정책: 일반 CI / dev `swift test` 실행 시 skip → 1962 test 영향 0. release
    /// baseline 측정 의도 명시한 trial 만 invoke.
    func testRecordWalkTickP99Baseline() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DARWIN_BASELINE_RECORD"] == "1",
            "Opt-in baseline harness — set DARWIN_BASELINE_RECORD=1 to record."
        )

        // 1. session 준비 — cradle confirmed (cradle-disconnect early return 회피).
        let session = WalkLabSession()
        session.cradleConfirmed = true

        // 2. 워밍업 (timing 미기록).
        for _ in 0..<Self.warmupCount {
            session.tick()
        }

        // 3. 본 측정 — DispatchTime.now() 의 ns 정밀 사용.
        var samplesNs: [UInt64] = []
        samplesNs.reserveCapacity(Self.sampleCount)

        for _ in 0..<Self.sampleCount {
            let t0 = DispatchTime.now().uptimeNanoseconds
            session.tick()
            let t1 = DispatchTime.now().uptimeNanoseconds
            // monotonic clock — 음수 불가능. underflow 방어 차원에서 max() guard.
            samplesNs.append(t1 > t0 ? (t1 - t0) : 0)
        }

        // 4. 분포 통계.
        let stats = WalkTickBaselineStats(samplesNs: samplesNs)

        // 5. JSON 저장.
        let isoDate = WalkTickBaselineHarness.isoTimestamp()
        let fileSlug = WalkTickBaselineHarness.fileSlug()
        let baselineDir = WalkTickBaselineHarness.repoRoot()
            .appendingPathComponent("docs/architecture/baselines", isDirectory: true)
        try FileManager.default.createDirectory(
            at: baselineDir, withIntermediateDirectories: true, attributes: nil
        )
        let outputURL = baselineDir
            .appendingPathComponent("walk_tick_\(fileSlug).json")

        #if DEBUG
        let buildConfig = "debug"
        #else
        let buildConfig = "release"
        #endif
        let json = WalkTickBaselineHarness.buildBaselineJSON(
            measuredAt: isoDate,
            sampleCount: Self.sampleCount,
            warmupCount: Self.warmupCount,
            tickRateHz: Self.tickRateHz,
            adrP99TargetMs: Self.adrP99TargetMs,
            buildConfig: buildConfig,
            stats: stats
        )
        try json.write(to: outputURL, atomically: true, encoding: .utf8)

        // 6. assert ADR gate — P99 < 5ms.
        XCTAssertLessThan(
            stats.p99Ms, Self.adrP99TargetMs,
            "ADR-002 P99 < 5ms gate 위반 — measured P99=\(stats.p99Ms)ms"
        )

        // 7. 콘솔 요약 — CI log 에서도 즉시 가시.
        // OSLog 분리: 본 lazy print 는 ADR-002 baseline record 의 evidence — 운영
        // 코드 아님. Console.app 노이즈 없음.
        FileHandle.standardOutput.write(Data(
            "[V287-1] walk_tick baseline saved → \(outputURL.path)\n".utf8
        ))
        FileHandle.standardOutput.write(Data(
            "[V287-1] P50=\(stats.p50Ms)ms P95=\(stats.p95Ms)ms P99=\(stats.p99Ms)ms max=\(stats.maxMs)ms\n".utf8
        ))
    }

    // MARK: - Helpers (pure functions, easy to unit-test if needed)

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func fileSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// repo root = Package.swift 가 있는 디렉토리.
    /// 본 file: `Tests/DarwinForgeUITests/WalkTickBaselineHarness.swift`
    /// → 3 단계 위로 올라가면 repo root.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/DarwinForgeUITests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <root>
    }

    private static func buildBaselineJSON(
        measuredAt: String,
        sampleCount: Int,
        warmupCount: Int,
        tickRateHz: Double,
        adrP99TargetMs: Double,
        buildConfig: String,
        stats: WalkTickBaselineStats
    ) -> String {
        let satisfied = stats.p99Ms < adrP99TargetMs
        let headroomPct = ((adrP99TargetMs - stats.p99Ms) / adrP99TargetMs) * 100.0
        // 6 decimal precision — sub-µs visible.
        let p50 = String(format: "%.6f", stats.p50Ms)
        let p95 = String(format: "%.6f", stats.p95Ms)
        let p99 = String(format: "%.6f", stats.p99Ms)
        let maxV = String(format: "%.6f", stats.maxMs)
        let mean = String(format: "%.6f", stats.meanMs)
        let std = String(format: "%.6f", stats.stddevMs)
        let head = String(format: "%.2f", headroomPct)
        // hand-rolled JSON — JSONEncoder dependency / order 변경 회피.
        return """
        {
          "schema_version": 1,
          "subsystem": "com.yuseokkim.darwinforge",
          "interval": "walk_tick",
          "measured_at": "\(measuredAt)",
          "tool": "WalkTickBaselineHarness (DispatchTime.now, direct call)",
          "build_config": "\(buildConfig)",
          "build_config_note": "release 권장 — debug 는 ARC/Optional unwrap overhead 로 2-3x 부풀려짐. swift test -c release 시 일부 #if DEBUG 기반 unrelated test 가 빌드 실패하면 그 test 들 fix 후 재측정.",
          "machine": {
            "platform": "darwin-arm64",
            "note": "absolute number 는 measurement machine 의존 — baseline 비교는 항상 동일 머신에서 trial"
          },
          "duration_sec": \(Double(sampleCount) / tickRateHz),
          "sample_count": \(sampleCount),
          "warmup_count": \(warmupCount),
          "tick_rate_hz": \(tickRateHz),
          "mean_ms": \(mean),
          "stddev_ms": \(std),
          "p50_ms": \(p50),
          "p95_ms": \(p95),
          "p99_ms": \(p99),
          "max_ms": \(maxV),
          "adr_gate": {
            "spec": "docs/architecture/adr-002-wave-4-decomposition.md (line 40, 48)",
            "metric": "walk_tick P99",
            "target_ms": \(adrP99TargetMs),
            "satisfied": \(satisfied),
            "headroom_pct": \(head)
          },
          "notes": [
            "V287-1 (cycle 287) — ADR-002 P99 5ms gate 실측 baseline",
            "direct tick() 호출 — simTimer RunLoop dispatch overhead 미포함 (< 50µs estimated)",
            "store=nil 환경 — bus polling phase early-return; hardware 연결 시 + IMU read 50ms"
          ]
        }
        """
    }
}

// MARK: - Statistics helper (Sendable struct, easy to reuse)

/// 단순 percentile 통계 — Apple Accelerate 미사용 (zero dependency).
///
/// **알고리즘**: nearest-rank percentile (Hyndman & Fan 1996 의 Type 1).
/// - sorted samples 의 index `ceil(p × n) - 1` 위치.
/// - quick-select 대신 sort 사용 — 300 sample 의 sort 비용 ~10µs (무시 가능).
struct WalkTickBaselineStats {
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double
    let meanMs: Double
    let stddevMs: Double

    init(samplesNs: [UInt64]) {
        precondition(!samplesNs.isEmpty, "samples 비어있음")
        let sorted = samplesNs.sorted()
        self.p50Ms = Self.percentileMs(sorted: sorted, p: 0.50)
        self.p95Ms = Self.percentileMs(sorted: sorted, p: 0.95)
        self.p99Ms = Self.percentileMs(sorted: sorted, p: 0.99)
        self.maxMs = Self.nsToMs(sorted.last!)
        let meanNs = sorted.reduce(0.0) { $0 + Double($1) } / Double(sorted.count)
        self.meanMs = meanNs / 1_000_000.0
        // population stddev — 300 sample 의 전체 분포.
        let variance = sorted.reduce(0.0) { acc, v in
            let d = Double(v) - meanNs
            return acc + d * d
        } / Double(sorted.count)
        self.stddevMs = variance.squareRoot() / 1_000_000.0
    }

    // MARK: pure helpers

    private static func percentileMs(sorted: [UInt64], p: Double) -> Double {
        precondition(p >= 0.0 && p <= 1.0, "percentile must be in [0, 1]")
        let n = sorted.count
        // nearest-rank: index = ceil(p × n) - 1, clamped to [0, n-1].
        let idx = min(n - 1, max(0, Int((p * Double(n)).rounded(.up)) - 1))
        return nsToMs(sorted[idx])
    }

    private static func nsToMs(_ ns: UInt64) -> Double {
        Double(ns) / 1_000_000.0
    }
}
