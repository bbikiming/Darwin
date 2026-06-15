import SwiftUI

/// **위치 미니맵** — sim 평면 좌표·heading·trail·총거리 표시.
///
/// # 시각 요소
///
/// - 중앙 robot 마커 (▲) — 현재 heading 으로 회전
/// - Path trail — 최근 60 포인트 fade 선
/// - 외곽 ring + 십자 격자
/// - 총 거리 readout (m)
/// - 좌표 readout (X, Z, mm)
/// - SIM 라벨 (정직성)
///
/// 직경 200pt 기준 안에서 자동 zoom — 가장 먼 trail 점이 화면에 들어오도록 scale 계산.
public struct CockpitMinimap: View {

    public let positionMM: SIMD2<Double>
    public let headingDeg: Double
    public let trail: [SIMD2<Double>]
    public let totalDistanceMm: Double
    public let isSim: Bool

    public init(positionMM: SIMD2<Double>,
                headingDeg: Double,
                trail: [SIMD2<Double>],
                totalDistanceMm: Double,
                isSim: Bool = true) {
        self.positionMM = positionMM
        self.headingDeg = headingDeg
        self.trail = trail
        self.totalDistanceMm = totalDistanceMm
        self.isSim = isSim
    }

    public var body: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                header
                Canvas { ctx, size in
                    drawMinimap(ctx: ctx, size: size)
                }
                .frame(height: 180)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s)
                        .fill(DS.Color.padBase.opacity(0.6))
                )
                footer
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Label("위치", systemImage: "map.fill")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            if isSim {
                Text("SIM")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.Color.warning.opacity(0.18), in: Capsule())
                    .foregroundStyle(DS.Color.warning)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            metric(label: "거리", value: String(format: "%.2f m", totalDistanceMm / 1000.0))
            Divider().frame(height: 24)
            metric(label: "X", value: String(format: "%.0f mm", positionMM.x))
            Divider().frame(height: 24)
            metric(label: "Z", value: String(format: "%.0f mm", positionMM.y))
            Spacer()
            metric(label: "Hdg", value: String(format: "%.0f°", normalizedHeading))
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DS.Color.tertiaryText)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.Color.primaryText)
        }
    }

    private var normalizedHeading: Double {
        // -180..180 → 0..360 normalize.
        let h = headingDeg.truncatingRemainder(dividingBy: 360.0)
        return h < 0 ? h + 360 : h
    }

    // MARK: - Canvas drawing

    private func drawMinimap(ctx: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 8

        // Background grid.
        drawGrid(ctx: ctx, center: center, radius: radius)

        // Trail.
        let scale = computeScale(viewRadius: radius)
        drawTrail(ctx: ctx, center: center, scale: scale)

        // Robot marker (center, heading rotated).
        drawRobotMarker(ctx: ctx, center: center)
    }

    private func drawGrid(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let gridColor = GraphicsContext.Shading.color(DS.Color.divider.opacity(0.5))

        // Outer ring.
        var ringPath = Path()
        ringPath.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
        ctx.stroke(ringPath, with: gridColor, lineWidth: 1)

        // Mid ring.
        let midR = radius * 0.5
        var midPath = Path()
        midPath.addEllipse(in: CGRect(x: center.x - midR, y: center.y - midR,
                                      width: midR * 2, height: midR * 2))
        ctx.stroke(midPath, with: gridColor, lineWidth: 0.5)

        // Cross hairs.
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        ctx.stroke(cross, with: gridColor, lineWidth: 0.5)

        // Compass labels.
        let labelColor = GraphicsContext.Shading.color(DS.Color.tertiaryText)
        let labelFont = Font.system(size: 9, weight: .semibold, design: .monospaced)
        ctx.draw(Text("N").font(labelFont).foregroundStyle(.secondary),
                 at: CGPoint(x: center.x, y: center.y - radius - 2),
                 anchor: .bottom)
        _ = labelColor
    }

    /// Trail 의 max 거리 기반으로 scale 결정 (자동 zoom).
    private func computeScale(viewRadius: CGFloat) -> CGFloat {
        guard !trail.isEmpty else {
            // 빈 trail → 기본 1m = viewRadius (실용적 zoom).
            return viewRadius / 1000.0
        }
        let maxDist = trail.map { hypot($0.x - positionMM.x, $0.y - positionMM.y) }.max() ?? 0
        let safeMax = max(maxDist, 500.0)   // 최소 50cm 영역 표시
        return viewRadius / CGFloat(safeMax * 1.15)   // 15% margin
    }

    private func drawTrail(ctx: GraphicsContext, center: CGPoint, scale: CGFloat) {
        guard trail.count >= 2 else { return }

        let trailColor = DS.Color.accent
        for i in 1..<trail.count {
            let prev = trail[i - 1]
            let curr = trail[i]
            let fade = Double(i) / Double(trail.count)   // 0 = old, 1 = new

            // Position 기준 상대 좌표 → 화면 좌표.
            let p0 = mapToView(point: prev, center: center, scale: scale)
            let p1 = mapToView(point: curr, center: center, scale: scale)

            var seg = Path()
            seg.move(to: p0)
            seg.addLine(to: p1)
            ctx.stroke(seg,
                       with: .color(trailColor.opacity(fade * 0.7 + 0.1)),
                       lineWidth: 1.5 * fade + 0.5)
        }
    }

    private func mapToView(point: SIMD2<Double>, center: CGPoint, scale: CGFloat) -> CGPoint {
        // World (x, z) → view (x, y). World z 가 forward (위쪽) 이라 -y 로 매핑.
        let dx = CGFloat(point.x - positionMM.x) * scale
        let dz = CGFloat(point.y - positionMM.y) * scale
        return CGPoint(x: center.x + dx, y: center.y - dz)
    }

    /// 중앙에 robot 마커 — heading 방향 화살표.
    private func drawRobotMarker(ctx: GraphicsContext, center: CGPoint) {
        let size: CGFloat = 12
        let heading = headingDeg * .pi / 180.0

        // Triangle pointing forward (up), rotated by heading.
        var tri = Path()
        let tip = CGPoint(x: 0, y: -size)
        let leftBase = CGPoint(x: -size * 0.6, y: size * 0.5)
        let rightBase = CGPoint(x: size * 0.6, y: size * 0.5)
        tri.move(to: tip)
        tri.addLine(to: leftBase)
        tri.addLine(to: rightBase)
        tri.closeSubpath()

        let transform = CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: heading)
        let rotated = tri.applying(transform)

        ctx.fill(rotated, with: .color(DS.Color.brand))
        ctx.stroke(rotated, with: .color(.white.opacity(0.85)), lineWidth: 1.5)

        // Center dot (anchor).
        var dot = Path()
        dot.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        ctx.fill(dot, with: .color(.white))
    }

    private var accessibilityDescription: String {
        String(format: "미니맵, 거리 %.2f 미터, 헤딩 %.0f 도",
               totalDistanceMm / 1000.0, normalizedHeading)
    }
}
