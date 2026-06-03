import SwiftUI

/// **헤딩 + 보행 자세 indicator** — 항공기 attitude indicator 스타일 컴퍼스.
///
/// # 표시
///
/// - 외곽: 360° 컴퍼스 (N/E/S/W) — heading 으로 회전
/// - 중앙: 실 robot IMU 인공 수평선(roll/pitch) — `rollDeg`/`pitchDeg` 가 있을 때.
///   없으면 보행 상태 아이콘만(graceful degradation).
/// - 하단: heading 숫자 + walking/기울기 상태 라벨
///
/// # 실 IMU 연동 (cockpit.telemetry)
///
/// `rollDeg`/`pitchDeg` 는 Mac 의 `cockpit.telemetry` 이벤트(`RobotAttitudePayload`)에서
/// 온다. Mac 이 아직 안 보내면 둘 다 nil — 종전처럼 heading + 보행 상태만 표시한다.
/// Mac 이 보내기 시작하면 자동으로 인공 수평선이 살아난다(코드 변경 불요).
public struct CockpitAttitudeIndicator: View {

    public let headingDeg: Double
    public let isWalking: Bool
    public let isArmed: Bool
    public let stickMagnitude: Double
    /// 실 robot IMU roll(deg, +우측 기울임). nil = Mac 미전송.
    public let rollDeg: Double?
    /// 실 robot IMU pitch(deg, +전방 숙임). nil = Mac 미전송.
    public let pitchDeg: Double?

    public init(headingDeg: Double,
                isWalking: Bool,
                isArmed: Bool,
                stickMagnitude: Double,
                rollDeg: Double? = nil,
                pitchDeg: Double? = nil) {
        self.headingDeg = headingDeg
        self.isWalking = isWalking
        self.isArmed = isArmed
        self.stickMagnitude = stickMagnitude
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
    }

    /// IMU 데이터 보유 여부.
    private var hasIMU: Bool { rollDeg != nil || pitchDeg != nil }

    /// |roll| 또는 |pitch| 가 임계를 넘으면 기울기 경고(넘어짐 위험).
    private var tiltWarning: Bool {
        let r = abs(rollDeg ?? 0)
        let p = abs(pitchDeg ?? 0)
        return r > 25 || p > 25
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
                    if hasIMU {
                        Text(String(format: "R %+.0f°  P %+.0f°", rollDeg ?? 0, pitchDeg ?? 0))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tiltWarning ? DS.Color.danger : DS.Color.secondaryText)
                            .accessibilityLabel("기울기 좌우 \(Int(rollDeg ?? 0))도, 앞뒤 \(Int(pitchDeg ?? 0))도")
                    }
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

        // 실 IMU 인공 수평선 — heading ring 안쪽에 그려 컴퍼스와 겹치지 않게.
        if hasIMU {
            drawArtificialHorizon(ctx: ctx, center: center, radius: radius - 18)
        }

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

    /// 항공기 인공 수평선 — roll 로 수평선이 기울고, pitch 로 위아래 이동.
    /// 원형 클립 안에 하늘(위)/땅(아래)를 그려 한눈에 기체 자세 파악.
    private func drawArtificialHorizon(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let roll = (rollDeg ?? 0) * .pi / 180.0
        // pitch 1° 당 픽셀 이동(원 안에 ±30° 정도 보이도록 스케일).
        let pixelsPerDeg = radius / 35.0
        let pitchOffset = CGFloat(pitchDeg ?? 0) * pixelsPerDeg

        // 원형 클립.
        var clip = Path()
        clip.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))

        ctx.drawLayer { layer in
            layer.clip(to: clip)
            // roll: 수평선이 기울도록 컨텍스트 회전(중심 기준).
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(-roll))
            // pitch: 수평선을 위/아래로 이동(전방 숙임이면 수평선이 위로).
            layer.translateBy(x: 0, y: pitchOffset)

            let big = radius * 3   // 회전/이동해도 화면을 덮도록 크게.
            // 하늘(위).
            let sky = Path(CGRect(x: -big, y: -big, width: big * 2, height: big))
            layer.fill(sky, with: .color(DS.Color.info.opacity(tiltWarning ? 0.30 : 0.45)))
            // 땅(아래).
            let ground = Path(CGRect(x: -big, y: 0, width: big * 2, height: big))
            layer.fill(ground, with: .color(DS.Color.warning.opacity(tiltWarning ? 0.30 : 0.22)))
            // 수평선.
            var horizon = Path()
            horizon.move(to: CGPoint(x: -big, y: 0))
            horizon.addLine(to: CGPoint(x: big, y: 0))
            layer.stroke(horizon,
                         with: .color(tiltWarning ? DS.Color.danger : .white.opacity(0.9)),
                         lineWidth: 1.5)
            // pitch 눈금(±10°, ±20°).
            for deg in [-20, -10, 10, 20] {
                let y = -CGFloat(deg) * pixelsPerDeg
                let w = radius * 0.35
                var tick = Path()
                tick.move(to: CGPoint(x: -w, y: y))
                tick.addLine(to: CGPoint(x: w, y: y))
                layer.stroke(tick, with: .color(.white.opacity(0.45)), lineWidth: 0.6)
            }
        }

        // 고정 중앙 기체 마커(roll/pitch 와 무관하게 화면 고정 — 항공 HUD 표준).
        var wing = Path()
        wing.move(to: CGPoint(x: center.x - radius * 0.4, y: center.y))
        wing.addLine(to: CGPoint(x: center.x - radius * 0.12, y: center.y))
        wing.move(to: CGPoint(x: center.x + radius * 0.12, y: center.y))
        wing.addLine(to: CGPoint(x: center.x + radius * 0.4, y: center.y))
        ctx.stroke(wing, with: .color(tiltWarning ? DS.Color.danger : DS.Color.success), lineWidth: 2)
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
        if tiltWarning { return "기울기 경고" }
        if !isArmed { return "잠금" }
        if isWalking || stickMagnitude > 0.1 { return "보행 중" }
        return "정지"
    }

    private var stateTint: Color {
        if tiltWarning { return DS.Color.danger }
        if !isArmed { return DS.Color.tertiaryText }
        if isWalking || stickMagnitude > 0.1 { return DS.Color.success }
        return DS.Color.warning
    }
}
