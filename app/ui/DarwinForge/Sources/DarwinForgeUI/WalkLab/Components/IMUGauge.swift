import SwiftUI

/// 반원 게이지 — 단일 축 (Roll 또는 Pitch). 음수 = 좌측, 양수 = 우측.
///
/// 임계값: |°| < 15 녹색 / < 25 노랑 / < 30 주황 / ≥ 30 빨강 (자동 emergency).
struct IMUGauge: View {
    let axis: String           // "Roll" / "Pitch"
    let degrees: Double
    let dangerThreshold: Double

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // 외곽
                Path { p in
                    let r: CGFloat = 60
                    p.addArc(center: CGPoint(x: 70, y: 60),
                             radius: r,
                             startAngle: .degrees(180),
                             endAngle: .degrees(0),
                             clockwise: false)
                }
                .stroke(Color.gray.opacity(0.25), lineWidth: 6)

                // 채워진 호
                Path { p in
                    let r: CGFloat = 60
                    let fraction = min(abs(degrees) / 45, 1.0)
                    let start = degrees >= 0 ? 270.0 : 270.0 - (180 * fraction)
                    let end = degrees >= 0 ? 270.0 + (180 * fraction) : 270.0
                    p.addArc(center: CGPoint(x: 70, y: 60),
                             radius: r,
                             startAngle: .degrees(start),
                             endAngle: .degrees(end),
                             clockwise: false)
                }
                .stroke(currentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))

                VStack(spacing: 2) {
                    Text(String(format: "%+.0f°", degrees))
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(currentColor)
                    Text(axis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .offset(y: 5)
            }
            .frame(width: 140, height: 80)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var currentColor: Color {
        let abs = Swift.abs(degrees)
        if abs >= dangerThreshold       { return .red }
        if abs >= dangerThreshold * 0.85 { return .orange }
        if abs >= dangerThreshold * 0.5  { return .yellow }
        return .green
    }
}
