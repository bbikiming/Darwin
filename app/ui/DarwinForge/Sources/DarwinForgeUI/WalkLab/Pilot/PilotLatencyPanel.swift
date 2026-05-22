import SwiftUI

/// **v1.20.45 (2026-05-22) 사이클 59-ui — input → engine latency 시각화 panel**.
///
/// `PilotLatencyTracker` 의 통계 (median / p95 / max) 를 사용자가 보고 즉시 "게임 캐릭터"
/// 수준의 응답성인지 판단하도록 한다. critic 지적 응답 — 측정만 있고 시각화 없으면
/// 정량 기준의 사용자 가치 0.
///
/// # 비유
///
/// 자동차 RPM 게이지 — 엔진이 얼마나 빠르게 도는지 한눈에. 색상 바로 정상/경고/위험
/// 즉시 인지. 본 panel 도 < 50ms 녹색, 50-150ms 노랑, > 150ms 빨강.
///
/// # 활성
///
/// `bridge.latencyTracker` 가 nil 일 경우 본 panel 이 자동으로 활성화 (lazy init).
/// 사용자가 사이드바 토글로 overlay 열면 측정 시작 — 항상 측정 시 overhead 가 부담스러우면
/// 추후 별도 토글 추가 검토.
@MainActor
public struct PilotLatencyPanel: View {

    @Bindable public var bridge: WalkLabRCBridge

    public init(bridge: WalkLabRCBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statsGrid
            sampleCountRow
            resetButton
        }
        .padding(12)
        .frame(width: 280)
        .background(DFColor.canvas.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DFColor.accent.opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            // lazy init — overlay 열린 동안만 측정.
            if bridge.latencyTracker == nil {
                bridge.latencyTracker = PilotLatencyTracker()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "speedometer")
                .foregroundStyle(DFColor.accent)
            Text("입력 지연 (Latency)")
                .font(.callout.weight(.semibold))
            Spacer()
            statusDot
        }
    }

    /// 현재 median 기반 status dot — 녹/황/적 한눈 시각.
    private var statusDot: some View {
        let color = Self.tint(forMillis: medianMillis)
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help("최근 30 cycle median 응답 시간 기준")
    }

    // MARK: - Stats grid

    private var statsGrid: some View {
        HStack(spacing: 8) {
            statTile(label: "p50", millis: medianMillis)
            statTile(label: "p95", millis: p95Millis)
            statTile(label: "max", millis: maxMillis)
        }
    }

    private func statTile(label: String, millis: Double) -> some View {
        let color = Self.tint(forMillis: millis)
        return VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(DFColor.textSecondary)
            Text(stats.count == 0 ? "—" : String(format: "%.1f", millis))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text("ms")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Sample count

    private var sampleCountRow: some View {
        let capacity = bridge.latencyTracker?.capacity ?? 30
        let rejected = bridge.latencyTracker?.rejectedCount ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                    .font(.caption2)
                    .foregroundStyle(DFColor.textSecondary)
                Text("\(stats.count)/\(capacity) samples")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text(legend)
                    .font(.caption2)
                    .foregroundStyle(DFColor.textSecondary.opacity(0.7))
            }
            // **사이클 75 — 코덱스 CRITICAL-1 후속 UI**: rejectedCount 시각화.
            // emergency / blocked / disabled path 의 거부 입력 수 — 사용자가 stats 신뢰도 평가.
            if rejected > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(DFColor.warning)
                    Text("\(rejected) 거부 (emergency/blocked)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DFColor.warning)
                }
            }
        }
    }

    /// 색상 범례 — 사용자가 임계값을 한 줄로 알 수 있게.
    private var legend: String {
        "< 50 · < 150 · ≥ 150"
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button {
            bridge.latencyTracker?.reset()
        } label: {
            Label("측정 초기화", systemImage: "arrow.counterclockwise")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(stats.count == 0)
    }

    // MARK: - Computed stats (ms 단위)

    private var stats: PilotLatencyTracker.Statistics {
        bridge.latencyTracker?.statistics(for: .endToEnd) ?? .zero
    }

    private var medianMillis: Double { stats.median * 1000 }
    private var p95Millis: Double { stats.p95 * 1000 }
    private var maxMillis: Double { stats.max * 1000 }

    // MARK: - Color helpers

    /// < 50ms 녹색 / 50-150ms 노랑 / >= 150ms 빨강.
    /// 표본 없으면 회색 (중립).
    private static func tint(forMillis ms: Double) -> Color {
        if ms <= 0 { return DFColor.textSecondary }
        if ms < 50 { return DFColor.success }
        if ms < 150 { return DFColor.warning }
        return DFColor.danger
    }
}
