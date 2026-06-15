import SwiftUI

/// 축 응답 곡선 그래프 — 데드존 음영 + 성형 곡선 + 라이브 입력 점 (설계 §C).
///
/// 8BitDo Ultimate Software 패턴: 슬라이더로 튜닝을 바꾸면 곡선이 즉시 변하고,
/// 실제 입력이 곡선 위 점으로 움직여 "내 입력이 어떻게 변환되는지" 를 보여준다.
/// 데이터는 `AxisResponseCurveModel` (순수 함수) 가 공급한다.
@MainActor
struct AxisResponseCurveView: View {
    let tuning: ControllerAxisTuning
    /// 현재 원시 축값 [-1, 1] — 라이브 점 위치.
    let rawValue: Double

    private let height: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let inset: CGFloat = 6
                let plot = CGRect(x: inset, y: inset,
                                  width: size.width - inset * 2, height: size.height - inset * 2)
                func place(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: plot.minX + p.x * plot.width,
                            y: plot.maxY - p.y * plot.height)
                }

                // 데드존 음영
                let deadzoneWidth = plot.width * CGFloat(min(1, max(0, tuning.innerDeadzone)))
                if deadzoneWidth > 0 {
                    context.fill(Path(CGRect(x: plot.minX, y: plot.minY,
                                             width: deadzoneWidth, height: plot.height)),
                                 with: .color(.secondary.opacity(0.15)))
                }

                // 플롯 테두리 + 선형 기준선
                context.stroke(Path(roundedRect: plot, cornerRadius: 4),
                               with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                var reference = Path()
                reference.move(to: place(CGPoint(x: 0, y: 0)))
                reference.addLine(to: place(CGPoint(x: 1, y: 1)))
                context.stroke(reference, with: .color(.secondary.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // 성형 곡선
                let samples = AxisResponseCurveModel.points(tuning: tuning)
                if let first = samples.first {
                    var curve = Path()
                    curve.move(to: place(first))
                    for point in samples.dropFirst() { curve.addLine(to: place(point)) }
                    context.stroke(curve, with: .color(.teal), lineWidth: 2)
                }

                // 라이브 점
                let live = place(AxisResponseCurveModel.livePoint(tuning: tuning, raw: rawValue))
                context.fill(Path(ellipseIn: CGRect(x: live.x - 4, y: live.y - 4, width: 8, height: 8)),
                             with: .color(.teal))
                context.stroke(Path(ellipseIn: CGRect(x: live.x - 6, y: live.y - 6, width: 12, height: 12)),
                               with: .color(.teal.opacity(0.5)), lineWidth: 1.5)
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))

            HStack {
                Text(String(format: "입력 %.2f → 출력 %.2f",
                            abs(rawValue), abs(tuning.shaped(rawValue))))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.teal)
                Spacer()
                Text(String(format: "데드존 %.0f%% · expo %.2f · 감도 %.1f%@",
                            tuning.innerDeadzone * 100, tuning.expo, tuning.sensitivity,
                            tuning.invert ? " · 반전" : ""))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("cockpit.controller.response.curve")
    }
}
