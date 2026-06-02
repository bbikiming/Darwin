import SwiftUI

/// **속도 게이지** — 전진/측면/회전 mm/sec, deg/sec + peak forward.
///
/// # 게이지 종류
///
/// - **전진 (forward)**: 중앙 큰 게이지 — ROBOTIS 공식 mm/sec. peak hold marker.
/// - **측면 (lateral)**: 좌측 작은 게이지.
/// - **회전 (turn)**: 우측 작은 게이지 — deg/sec.
///
/// 사용자가 "조이스틱 끝까지 밀면 robot 이 몇 mm/s 로 움직이나" 즉시 확인할 수 있어,
/// Mac Cockpit 의 CockpitSpeedGauge 와 동일한 시각 경험을 iOS 에서 제공한다.
public struct CockpitSpeedGauge: View {

    public let forwardMmPerSec: Double
    public let lateralMmPerSec: Double
    public let turnDegPerSec: Double
    public let peakForwardMmPerSec: Double
    public let forwardNorm: Double
    public let lateralNorm: Double
    public let turnNorm: Double

    public init(forwardMmPerSec: Double,
                lateralMmPerSec: Double,
                turnDegPerSec: Double,
                peakForwardMmPerSec: Double,
                forwardNorm: Double,
                lateralNorm: Double,
                turnNorm: Double) {
        self.forwardMmPerSec = forwardMmPerSec
        self.lateralMmPerSec = lateralMmPerSec
        self.turnDegPerSec = turnDegPerSec
        self.peakForwardMmPerSec = peakForwardMmPerSec
        self.forwardNorm = forwardNorm
        self.lateralNorm = lateralNorm
        self.turnNorm = turnNorm
    }

    public var body: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Label("속도", systemImage: "speedometer")
                        .font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Color.secondaryText)
                    Spacer()
                    Text("ROBOTIS Walking")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.Color.tertiaryText)
                }

                forwardGauge

                HStack(spacing: DS.Space.m) {
                    sideGauge(label: "측면",
                              valueText: String(format: "%+.0f mm/s", lateralMmPerSec),
                              norm: lateralNorm,
                              direction: lateralMmPerSec >= 0 ? "→" : "←",
                              tint: DS.Color.info)
                    sideGauge(label: "회전",
                              valueText: String(format: "%+.0f°/s", turnDegPerSec),
                              norm: turnNorm,
                              direction: turnDegPerSec >= 0 ? "↶" : "↷",
                              tint: DS.Color.warning)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Forward gauge

    private var forwardGauge: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(forwardLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Color.tertiaryText)
                Spacer()
                Text(String(format: "%+.0f", forwardMmPerSec))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(forwardTint)
                Text("mm/s")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Color.tertiaryText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track.
                    Capsule()
                        .fill(DS.Color.padBase)

                    // Forward fill (center-out for bidirectional).
                    Capsule()
                        .fill(forwardTint)
                        .frame(width: max(2, geo.size.width * CGFloat(forwardNorm)))

                    // Peak marker.
                    if peakForwardMmPerSec > 5 {
                        let maxMmps = 127.0   // strideMm 38 × 2000 / 600
                        let peakPosition = min(peakForwardMmPerSec / maxMmps, 1.0)
                        Rectangle()
                            .fill(DS.Color.warning)
                            .frame(width: 2, height: 16)
                            .offset(x: geo.size.width * CGFloat(peakPosition) - 1)
                    }
                }
            }
            .frame(height: 14)
        }
    }

    private var forwardLabel: String {
        if forwardMmPerSec > 1 { return "전진" }
        if forwardMmPerSec < -1 { return "후진" }
        return "정지"
    }

    private var forwardTint: Color {
        if abs(forwardMmPerSec) < 1 { return DS.Color.tertiaryText }
        return forwardMmPerSec >= 0 ? DS.Color.success : DS.Color.danger
    }

    // MARK: - Side gauge (lateral / turn)

    private func sideGauge(label: String,
                           valueText: String,
                           norm: Double,
                           direction: String,
                           tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Color.tertiaryText)
                Spacer()
                Text(direction)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(norm > 0.05 ? tint : DS.Color.tertiaryText)
            }
            Text(valueText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(norm > 0.05 ? DS.Color.primaryText : DS.Color.tertiaryText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.padBase)
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(norm)))
                }
            }
            .frame(height: 6)
        }
    }

    private var accessibilityDescription: String {
        String(format: "속도 전진 %.0f, 측면 %.0f mm/s, 회전 %.0f 도/s, 피크 %.0f",
               forwardMmPerSec, lateralMmPerSec, turnDegPerSec, peakForwardMmPerSec)
    }
}
