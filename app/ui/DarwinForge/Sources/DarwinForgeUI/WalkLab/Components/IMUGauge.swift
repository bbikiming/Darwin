import SwiftUI

/// 반원 게이지 — 단일 축 (Roll 또는 Pitch). 음수 = 좌측, 양수 = 우측.
///
/// 임계값: |°| < 15 녹색 / < 25 노랑 / < 30 주황 / ≥ 30 빨강 (자동 emergency).
///
/// 2026-05-17 a11y audit HIGH fix (WCAG 1.4.3 + 4.1.2):
///   - 시스템 색 (.yellow / .orange / .red) → 디자인 토큰 (DFColor.warning/.severe/.danger)
///     로 교체. 토큰은 highContrastLight/Dark variant 보장 → 4.5:1 대비 확보.
///   - `accessibilityElement(.combine)` + accessibilityLabel/Value 추가 — VoiceOver
///     사용자가 "Roll 기울기 -3도, 안전" 식 한 번에 인지.
struct IMUGauge: View {
    let axis: String           // "Roll" / "Pitch"
    let degrees: Double
    let dangerThreshold: Double

    var body: some View {
        VStack(spacing: DFSpace.xs2) {
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
                .stroke(Color.gray.opacity(DFOpacity.o25), lineWidth: 6)

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

                VStack(spacing: DFSpace.micro2) {
                    Text(String(format: "%+.0f°", degrees))
                        .font(.system(size: DFFontSize.s22, weight: .semibold, design: .rounded).monospacedDigit())
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(axis) 기울기 \(Int(degrees.rounded()))도, \(safetyLevelLabel)")
    }

    private var currentColor: Color {
        let abs = Swift.abs(degrees)
        if abs >= dangerThreshold        { return DFColor.danger }
        if abs >= dangerThreshold * 0.85 { return DFColor.severe }
        if abs >= dangerThreshold * 0.5  { return DFColor.warning }
        return DFColor.success
    }

    /// VoiceOver 안전 상태 라벨 — 색 dependency 제거 (WCAG 1.4.1).
    private var safetyLevelLabel: String {
        let abs = Swift.abs(degrees)
        if abs >= dangerThreshold        { return "위험 — 자동 정지 임계 도달" }
        if abs >= dangerThreshold * 0.85 { return "심각" }
        if abs >= dangerThreshold * 0.5  { return "주의" }
        return "안전"
    }
}
