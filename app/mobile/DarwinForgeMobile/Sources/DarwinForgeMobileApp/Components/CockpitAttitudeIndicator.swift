import SwiftUI

/// **헤딩 + 보행 자세 indicator** — 항공기 attitude indicator 스타일 컴퍼스.
///
/// # 표시
///
/// - 외곽: 360° 컴퍼스 (N/E/S/W) — heading 으로 회전
/// - 중앙: walking/standing/halt 상태 아이콘
/// - 하단: heading 숫자 + walking 상태 라벨
///
/// Mac 의 CockpitAttitudeIndicator 는 roll/pitch (실 robot IMU) 도 표시하지만, iOS 는
/// IMU 데이터를 받지 않으므로 (TelemetryStatePayload 에 미포함) heading + walking 상태만.
public struct CockpitAttitudeIndicator: View {

    public let headingDeg: Double
    public let isWalking: Bool
    public let isArmed: Bool
    public let stickMagnitude: Double

    public init(headingDeg: Double,
                isWalking: Bool,
                isArmed: Bool,
                stickMagnitude: Double) {
        self.headingDeg = headingDeg
        self.isWalking = isWalking
        self.isArmed = isArmed
        self.stickMagnitude = stickMagnitude
    }

    public var body: some View {
        DSCard(padding: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                compassDial
                VStack(alignment: .leading, spacing: 6) {
                    Label("헤딩", systemImage: "location.north.line.fill")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Color.tertiaryText)
                    Text(String(format: "%.0f°", normalizedHeading))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.Color.primaryText)
                        .accessibilityLabel("헤딩 \(Int(normalizedHeading))도")
                    Divider().frame(width: 60)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(stateTint)
                            .frame(width: 8, height: 8)
                            .shadow(color: stateTint.opacity(0.6), radius: 2)
                        Text(stateLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("자세 인디케이터, 헤딩 \(Int(normalizedHeading))도, \(stateLabel)")
    }

    // MARK: - Compass dial

    private var compassDial: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 6
            drawCompass(ctx: ctx, center: center, radius: radius)
        }
        .frame(width: 100, height: 100)
    }

    private func drawCompass(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        // Outer ring.
        var ring = Path()
        ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.stroke(ring, with: .color(DS.Color.divider), lineWidth: 1)

        // Tick marks every 30°, with N/E/S/W labels.
        let heading = headingDeg * .pi / 180.0
        for deg in stride(from: 0, to: 360, by: 30) {
            let angle = (Double(deg) - 90.0) * .pi / 180.0 - heading
            let isCardinal = (deg % 90 == 0)
            let outR = radius
            let inR = radius - (isCardinal ? 10 : 5)
            let x0 = center.x + CGFloat(cos(angle)) * outR
            let y0 = center.y + CGFloat(sin(angle)) * outR
            let x1 = center.x + CGFloat(cos(angle)) * inR
            let y1 = center.y + CGFloat(sin(angle)) * inR

            var tick = Path()
            tick.move(to: CGPoint(x: x0, y: y0))
            tick.addLine(to: CGPoint(x: x1, y: y1))
            ctx.stroke(tick, with: .color(DS.Color.secondaryText), lineWidth: isCardinal ? 1.5 : 0.8)

            if isCardinal {
                let labelR = radius - 16
                let lx = center.x + CGFloat(cos(angle)) * labelR
                let ly = center.y + CGFloat(sin(angle)) * labelR
                let label = cardinalLabel(deg: deg)
                let color: Color = (deg == 0) ? DS.Color.danger : DS.Color.secondaryText
                ctx.draw(Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(color),
                         at: CGPoint(x: lx, y: ly), anchor: .center)
            }
        }

        // Center crosshair + heading needle (fixed pointing up since the dial rotates).
        var needle = Path()
        needle.move(to: CGPoint(x: center.x, y: center.y))
        needle.addLine(to: CGPoint(x: center.x, y: center.y - radius + 12))
        ctx.stroke(needle, with: .color(DS.Color.brand), lineWidth: 2)

        // Tip arrow.
        var arrow = Path()
        let tip = CGPoint(x: center.x, y: center.y - radius + 12)
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: center.x - 5, y: center.y - radius + 18))
        arrow.addLine(to: CGPoint(x: center.x + 5, y: center.y - radius + 18))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(DS.Color.brand))

        // Center dot.
        var dot = Path()
        dot.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        ctx.fill(dot, with: .color(DS.Color.brand))
    }

    private func cardinalLabel(deg: Int) -> String {
        switch deg {
        case 0: return "N"
        case 90: return "E"
        case 180: return "S"
        case 270: return "W"
        default: return ""
        }
    }

    // MARK: - Derived

    private var normalizedHeading: Double {
        let h = headingDeg.truncatingRemainder(dividingBy: 360.0)
        return h < 0 ? h + 360 : h
    }

    private var stateLabel: String {
        if !isArmed { return "잠금" }
        if isWalking || stickMagnitude > 0.1 { return "보행 중" }
        return "정지"
    }

    private var stateTint: Color {
        if !isArmed { return DS.Color.tertiaryText }
        if isWalking || stickMagnitude > 0.1 { return DS.Color.success }
        return DS.Color.warning
    }
}
