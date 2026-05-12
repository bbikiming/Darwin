import ForgeCore
import SwiftUI

/// 보행 위상(phase0..3) 타임라인 리본 — Bloomberg-style 색 코딩.
///
///   PHASE0 (idle, gray)
///   PHASE1 (lift left, orange) — right foot supports
///   PHASE2 (DSP — double support, blue)
///   PHASE3 (lift right, magenta) — left foot supports
///
/// 가로 = 시간(좌→우), 세로 = phase 색 띠. 우측 끝이 "현재".
public struct PhaseRibbon: View {
    public struct Mark: Identifiable {
        public let id: Int
        public let t: Double       // 초.
        public let phase: WalkPhase
    }

    public let marks: [Mark]
    public let height: CGFloat

    public init(marks: [Mark], height: CGFloat = 28) {
        self.marks = marks
        self.height = height
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Text("PHASE")
                    .font(.system(size: DFFontSize.s10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                Spacer(minLength: 4)
                legend
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DFColor.canvas.opacity(DFOpacity.o45))

                    if !marks.isEmpty {
                        Canvas { ctx, size in
                            draw(ctx: &ctx, size: size, marks: marks)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text("no data")
                            .font(.system(size: DFFontSize.s10, design: .monospaced))
                            .foregroundStyle(DFColor.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: 0.5)
                )
            }
            .frame(height: height)
        }
    }

    private var legend: some View {
        HStack(spacing: DFSpace.sm) {
            ForEach(WalkPhase.allCases, id: \.self) { p in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: p))
                        .frame(width: 10, height: 6)
                    Text(legendLabel(p))
                        .font(.system(size: DFFontSize.s9, weight: .medium, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, marks: [Mark]) {
        guard let first = marks.first, let last = marks.last, last.t > first.t else {
            return
        }
        let tSpan = last.t - first.t
        let w = size.width
        let h = size.height

        var i = 0
        while i < marks.count {
            let m = marks[i]
            var j = i + 1
            while j < marks.count && marks[j].phase == m.phase {
                j += 1
            }
            let segEnd = (j < marks.count) ? marks[j].t : last.t + (last.t - marks[max(0, j - 2)].t)
            let xStart = CGFloat((m.t - first.t) / tSpan) * w
            let xEnd   = CGFloat((segEnd - first.t) / tSpan) * w
            let rect = CGRect(x: xStart, y: 0, width: max(1, xEnd - xStart), height: h)
            ctx.fill(Path(rect), with: .color(color(for: m.phase)))
            i = j
        }
    }

    private func color(for p: WalkPhase) -> Color {
        switch p {
        case .phase0: return DFColor.textSecondary.opacity(DFOpacity.o45)
        case .phase1: return DFColor.warning
        case .phase2: return DFColor.info
        case .phase3: return DFColor.torque
        }
    }

    private func legendLabel(_ p: WalkPhase) -> String {
        switch p {
        case .phase0: return "0 IDLE"
        case .phase1: return "1 LIFT-L"
        case .phase2: return "2 DSP"
        case .phase3: return "3 LIFT-R"
        }
    }
}

extension WalkPhase: @retroactive CaseIterable {
    public static var allCases: [WalkPhase] {
        [.phase0, .phase1, .phase2, .phase3]
    }
}
