import SwiftUI
import MobilePilotKit

/// **명령 readout** — 현재 robot 으로 송출되는 walk 명령의 raw 값.
///
/// # 표시
///
/// - 보폭 (stride mm/step) — 전후
/// - 측면 (side mm/step) — 좌우
/// - 회전 (turn deg/step) — 좌우
/// - Period (ms) — 보행 cadence
/// - SpeedScale — throttle
/// - 입력 source 라벨 (조이스틱/외부컨트롤러)
///
/// Mac CockpitCommandReadout 와 동일한 정직성 — 사용자가 "내 입력이 어떤 명령으로 변환됐나"
/// 정확히 확인할 수 있다. 게이트 (잠금/지연/disarm) 로 차단되어 robot 에 *송출되지 않은*
/// 경우 dim 처리로 표시한다.
public struct CockpitCommandReadout: View {

    public let strideMm: Double
    public let sideMm: Double
    public let turnDeg: Double
    public let periodMs: Double
    public let speedScale: Double
    public let isActiveDispatch: Bool
    public let source: String

    public init(strideMm: Double,
                sideMm: Double,
                turnDeg: Double,
                periodMs: Double,
                speedScale: Double,
                isActiveDispatch: Bool,
                source: String) {
        self.strideMm = strideMm
        self.sideMm = sideMm
        self.turnDeg = turnDeg
        self.periodMs = periodMs
        self.speedScale = speedScale
        self.isActiveDispatch = isActiveDispatch
        self.source = source
    }

    public var body: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                header
                HStack(spacing: DS.Space.m) {
                    metricCell(label: "보폭",
                               value: String(format: "%+.0f", strideMm),
                               unit: "mm/step",
                               isActive: abs(strideMm) > 1)
                    Divider().frame(height: 32)
                    metricCell(label: "측면",
                               value: String(format: "%+.0f", sideMm),
                               unit: "mm/step",
                               isActive: abs(sideMm) > 1)
                    Divider().frame(height: 32)
                    metricCell(label: "회전",
                               value: String(format: "%+.0f", turnDeg),
                               unit: "°/step",
                               isActive: abs(turnDeg) > 0.5)
                }
                HStack(spacing: DS.Space.m) {
                    metricCell(label: "Period",
                               value: String(format: "%.0f", periodMs),
                               unit: "ms",
                               isActive: true)
                    Divider().frame(height: 32)
                    metricCell(label: "×Scale",
                               value: String(format: "%.2f", speedScale),
                               unit: "throttle",
                               isActive: true)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var header: some View {
        HStack {
            Label("명령", systemImage: "waveform.path.ecg")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(isActiveDispatch ? DS.Color.success : DS.Color.tertiaryText)
                    .frame(width: 6, height: 6)
                    .shadow(color: isActiveDispatch ? DS.Color.success.opacity(0.7) : .clear, radius: 2)
                Text(isActiveDispatch ? "송출 중" : "대기")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActiveDispatch ? DS.Color.success : DS.Color.tertiaryText)
                Text("•")
                    .foregroundStyle(DS.Color.tertiaryText)
                Text(source)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Color.tertiaryText)
            }
        }
    }

    private func metricCell(label: String, value: String, unit: String, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Color.tertiaryText)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(isActive ? DS.Color.primaryText : DS.Color.tertiaryText)
            Text(unit)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(DS.Color.tertiaryText)
        }
    }

    private var accessibilityDescription: String {
        String(format: "명령, 보폭 %.0f, 측면 %.0f, 회전 %.0f, 주기 %.0f ms, 스케일 %.2f",
               strideMm, sideMm, turnDeg, periodMs, speedScale)
    }
}
