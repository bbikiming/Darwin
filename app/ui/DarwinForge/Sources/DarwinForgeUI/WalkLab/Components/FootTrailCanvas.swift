import SwiftUI

/// 2D top-down 발 자취 (Webots Foot Trail 스타일).
///
/// x = 전후 (m), y = 좌우 (m). 골반 좌표계 기준 → 카메라 시점은 위에서 내려다본 모습.
struct FootTrailCanvas: View {
    let trail: [FootTrailPoint]
    let leftFoot: SIMD3<Double>
    let rightFoot: SIMD3<Double>

    /// 그리드 한 칸 = 0.01 m (1 cm). 시각화 스케일.
    private let mPerCell: Double = 0.01

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // 보폭 한계 가정 ±10 cm → 화면의 70% 사용.
            let scale = min(size.width, size.height) * 0.7 / 0.20

            // 그리드
            ctx.stroke(gridPath(in: size, center: center, scale: scale),
                       with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
            // 중심 십자
            var cross = Path()
            cross.move(to: CGPoint(x: 0, y: center.y))
            cross.addLine(to: CGPoint(x: size.width, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: 0))
            cross.addLine(to: CGPoint(x: center.x, y: size.height))
            ctx.stroke(cross, with: .color(.gray.opacity(0.35)), lineWidth: 1)

            // Trail (좌측 발 — 파랑, 우측 — 주황)
            for (idx, p) in trail.enumerated() {
                let alpha = Double(idx) / Double(max(trail.count, 1))
                let lPos = project(p.left, center: center, scale: scale)
                let rPos = project(p.right, center: center, scale: scale)
                ctx.fill(Path(ellipseIn: CGRect(x: lPos.x - 2, y: lPos.y - 2, width: 4, height: 4)),
                         with: .color(.blue.opacity(0.15 + 0.85 * alpha)))
                ctx.fill(Path(ellipseIn: CGRect(x: rPos.x - 2, y: rPos.y - 2, width: 4, height: 4)),
                         with: .color(.orange.opacity(0.15 + 0.85 * alpha)))
            }

            // 현재 위치 (큰 점)
            let lNow = project(leftFoot, center: center, scale: scale)
            let rNow = project(rightFoot, center: center, scale: scale)
            ctx.fill(Path(ellipseIn: CGRect(x: lNow.x - 6, y: lNow.y - 6, width: 12, height: 12)),
                     with: .color(.blue))
            ctx.fill(Path(ellipseIn: CGRect(x: rNow.x - 6, y: rNow.y - 6, width: 12, height: 12)),
                     with: .color(.orange))
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                legend(color: .blue, label: "L")
                legend(color: .orange, label: "R")
                Text("1 cm 그리드")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func project(_ v: SIMD3<Double>, center: CGPoint, scale: Double) -> CGPoint {
        // x (전후) → +y (위로) / y (좌우) → +x (오른쪽)
        CGPoint(
            x: center.x + CGFloat(v.y * scale),
            y: center.y - CGFloat(v.x * scale)
        )
    }

    private func gridPath(in size: CGSize, center: CGPoint, scale: Double) -> Path {
        var path = Path()
        let step = CGFloat(mPerCell * scale)
        var x = center.x.truncatingRemainder(dividingBy: step)
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y = center.y.truncatingRemainder(dividingBy: step)
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        return path
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2.monospacedDigit())
        }
    }
}
