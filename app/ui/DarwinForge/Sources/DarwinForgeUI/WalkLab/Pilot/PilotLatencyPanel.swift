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
            // **사이클 75 + 사이클 80 + 사이클 82 — 코덱스 CRITICAL-1 후속 UI + MEDIUM-2 강화**:
            // rejectedCount 시각화 + 비율 기반 임계 (capacity-blind 절대 임계 해소).
            //
            // 사이클 82 (MEDIUM-2 fix): rejected > 10 절대 임계 → reject 비율 (rejected / (rejected + accepted))
            // 사용. capacity 변경 / 장시간 trial 에도 의미 보존.
            // - reject ratio < 30%: warning (정상 emergency 사용 시 자연 발생).
            // - reject ratio ≥ 30% AND stats.count ≥ 5: danger ("race storm" 진단 hint).
            //
            // **주의**: rejectedCount 는 monotonic counter — reset 호출 전까지 누적.
            // 장시간 trial 시 자연스럽게 10 초과. 비율 기반은 capacity 변경 영향 X.
            if rejected > 0 {
                let total = rejected + stats.count
                let ratio = total > 0 ? Double(rejected) / Double(total) : 0
                let isAnomalous = stats.count >= 5 && ratio > 0.3
                let color: Color = isAnomalous ? DFColor.danger : DFColor.warning
                HStack(spacing: 4) {
                    Image(systemName: isAnomalous ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(color)
                    Text("\(rejected) 거부\(isAnomalous ? " (\(Int(ratio * 100))% — race storm 의심)" : "")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(color)
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
