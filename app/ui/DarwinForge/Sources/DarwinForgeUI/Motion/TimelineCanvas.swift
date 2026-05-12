import ForgeCore
import SwiftUI

/// 페이지의 step 시퀀스를 가로 시간축으로 시각화. step 클릭 = 선택.
public struct TimelineCanvas: View {
    public let page: MotionPage
    @Binding public var selectedStep: Int
    public let elapsedMs: Double
    public let onSeek: (Double) -> Void

    public init(page: MotionPage,
                selectedStep: Binding<Int>,
                elapsedMs: Double,
                onSeek: @escaping (Double) -> Void) {
        self.page = page
        self._selectedStep = selectedStep
        self.elapsedMs = elapsedMs
        self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geo in
            let totalMs = max(1, page.totalDurationMs)
            let scale = geo.size.width / CGFloat(totalMs)
            ZStack(alignment: .leading) {
                // 배경 + 눈금
                gridBackground(width: geo.size.width, height: geo.size.height, totalMs: totalMs)

                // step 막대
                ForEach(stepFrames, id: \.index) { f in
                    stepBar(frame: f, scale: scale, height: geo.size.height)
                }

                // 현재 재생 위치 표시기
                Rectangle()
                    .fill(DFColor.forge)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: CGFloat(elapsedMs) * scale)
                    .shadow(color: DFColor.forge, radius: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let ms = Double(location.x) / Double(scale)
                onSeek(ms.clamped(to: 0...Double(totalMs)))
            }
        }
        .frame(height: 64)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous))
    }

    // MARK: - frames

    private struct StepFrame: Equatable {
        let index: Int
        let startMs: Int
        let playMs: Int
        let pauseMs: Int
    }

    private var stepFrames: [StepFrame] {
        var out: [StepFrame] = []
        var t = 0
        for (i, s) in page.steps.enumerated() {
            out.append(StepFrame(index: i, startMs: t,
                                 playMs: s.playMs, pauseMs: s.pauseMs))
            t += s.playMs + s.pauseMs
        }
        return out
    }

    private func stepBar(frame f: StepFrame, scale: CGFloat, height: CGFloat) -> some View {
        let x = CGFloat(f.startMs) * scale
        let playW = CGFloat(f.playMs) * scale
        let pauseW = CGFloat(f.pauseMs) * scale
        let isSel = selectedStep == f.index
        return ZStack(alignment: .topLeading) {
            // play 부분
            RoundedRectangle(cornerRadius: 4)
                .fill(isSel ? DFColor.accent.opacity(0.85) : DFColor.accent.opacity(0.55))
                .frame(width: max(playW - 1, 1), height: height - 14)
                .offset(y: 8)
                .overlay(alignment: .topLeading) {
                    Text("\(f.index + 1)")
                        .font(DFFont.caption.bold())
                        .foregroundStyle(.white)
                        .padding(2)
                }
                .offset(x: x)
                .onTapGesture { selectedStep = f.index }

            // pause 부분 (있을 때만)
            if pauseW > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(DFColor.textSecondary.opacity(0.30))
                    .frame(width: pauseW, height: height - 24)
                    .offset(x: x + playW, y: 13)
            }
        }
    }

    // MARK: - grid

    private func gridBackground(width: CGFloat, height: CGFloat, totalMs: Int) -> some View {
        Path { p in
            // 100 ms 단위 그리드.
            let step = max(100, totalMs / 12)
            var t = 0
            while t <= totalMs {
                let x = CGFloat(t) * (width / CGFloat(totalMs))
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: height))
                t += step
            }
        }
        .stroke(DFColor.textSecondary.opacity(0.18), lineWidth: 0.5)
    }
}
