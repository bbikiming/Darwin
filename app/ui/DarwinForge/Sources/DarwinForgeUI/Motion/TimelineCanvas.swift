import ForgeCore
import SwiftUI

/// After Effects / Final Cut Pro / Premiere 스타일의 키프레임 타임라인.
///
/// 레이아웃 (top → bottom):
///   1. Ruler (시간 tick + 라벨, 250ms / 500ms / 1s 자동 단위)
///   2. 키프레임 트랙 (보간 막대 + pause 회색 막대 + 키프레임 다이아몬드 ◆)
///   3. Playhead (빨간 세로 선 + 위쪽 ▼ handle, 드래그 가능)
///
/// 인터랙션:
///   - Click anywhere → seek to time
///   - Drag playhead handle → scrub
///   - Click 키프레임 diamond → select step
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

    private let rulerHeight: CGFloat = 22
    private let trackHeight: CGFloat = 56
    private var totalHeight: CGFloat { rulerHeight + trackHeight }

    public var body: some View {
        GeometryReader { geo in
            let totalMs = max(1, page.totalDurationMs)
            let scale = geo.size.width / CGFloat(totalMs)
            ZStack(alignment: .topLeading) {
                // Background
                Rectangle()
                    .fill(timelineBackground)

                // 1. Ruler (시간 tick + 라벨)
                rulerView(totalMs: totalMs, scale: scale, width: geo.size.width)

                // 2. 트랙 — 보간 막대 + pause 막대.
                trackBars(scale: scale, fullHeight: geo.size.height)

                // 3. 키프레임 다이아몬드 — 각 step 시작 지점.
                keyframeDiamonds(scale: scale)

                // 4. Playhead (재생 헤드) — 빨간 세로 선 + 위 handle.
                playhead(scale: scale, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(scale: scale, totalMs: totalMs))
        }
        .frame(height: totalHeight)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline)
        )
    }

    // MARK: - Background

    private var timelineBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                DFColor.elev2.opacity(DFOpacity.o70),
                DFColor.elev2.opacity(DFOpacity.dim)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: - 1. Ruler

    /// 상단 시간 ruler — Premiere/FCP 스타일 tick + 라벨.
    /// 자동 단위: 0–1.5s 는 250ms tick, 1.5–6s 는 500ms, 6s+ 는 1s.
    private func rulerView(totalMs: Int, scale: CGFloat, width: CGFloat) -> some View {
        let tickMs = autoTickMs(totalMs: totalMs)
        var ticks: [(ms: Int, label: String, major: Bool)] = []
        var t = 0
        var i = 0
        while t <= totalMs {
            let major = i % 2 == 0
            ticks.append((ms: t, label: formatRulerLabel(ms: t), major: major))
            t += tickMs
            i += 1
        }
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(DFColor.elev2.opacity(DFOpacity.dim))
                .frame(height: rulerHeight)
            ForEach(ticks, id: \.ms) { tick in
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(tick.major ? DFOpacity.dim : DFOpacity.o30))
                        .frame(width: DFSize.borderHairline,
                               height: tick.major ? rulerHeight - 4 : rulerHeight - 12)
                    if tick.major {
                        Text(tick.label)
                            .font(.system(size: DFFontSize.s9, design: .monospaced))
                            .foregroundStyle(DFColor.textSecondary)
                            .padding(.top, 2)
                            .padding(.leading, 3)
                    }
                }
                .offset(x: CGFloat(tick.ms) * scale)
            }
            // Ruler 하단 separator.
            Rectangle()
                .fill(DFColor.textSecondary.opacity(DFOpacity.subtle))
                .frame(height: DFSize.borderHairline)
                .offset(y: rulerHeight - DFSize.borderHairline)
        }
    }

    private func autoTickMs(totalMs: Int) -> Int {
        if totalMs <= 1500 { return 250 }
        if totalMs <= 6000 { return 500 }
        if totalMs <= 12000 { return 1000 }
        return 2000
    }

    private func formatRulerLabel(ms: Int) -> String {
        let s = Double(ms) / 1000.0
        if s == floor(s) { return String(format: "%.0fs", s) }
        return String(format: "%.2fs", s)
    }

    // MARK: - 2. Track bars (play interpolation + pause)

    /// 각 step 의 play 구간 (보간) + pause 구간 (정지) 시각화.
    @ViewBuilder
    private func trackBars(scale: CGFloat, fullHeight: CGFloat) -> some View {
        let trackTop = rulerHeight + 6
        let barHeight = trackHeight - 12
        ForEach(stepFrames, id: \.index) { f in
            let isSel = f.index == selectedStep
            let x = CGFloat(f.startMs) * scale
            let playW = max(1, CGFloat(f.playMs) * scale)
            let pauseW = CGFloat(f.pauseMs) * scale

            // Play interpolation 구간 — gradient bar.
            RoundedRectangle(cornerRadius: DFRadius.xs)
                .fill(
                    LinearGradient(
                        colors: isSel
                            ? [DFColor.accent, DFColor.accent.opacity(DFOpacity.o70)]
                            : [DFColor.accent.opacity(DFOpacity.dim), DFColor.accent.opacity(DFOpacity.o45)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: max(playW - 1, 1), height: barHeight)
                .offset(x: x, y: trackTop)
                .onTapGesture {
                    selectedStep = f.index
                    onSeek(Double(f.startMs))
                }

            // Pause (정지) 구간 — 회색 hatching.
            if pauseW > 1 {
                RoundedRectangle(cornerRadius: DFRadius.xs)
                    .fill(DFColor.textSecondary.opacity(DFOpacity.o30))
                    .frame(width: pauseW - 1, height: barHeight * 0.5)
                    .offset(x: x + playW, y: trackTop + barHeight * 0.25)
            }
        }
    }

    // MARK: - 3. Keyframe diamonds

    /// 각 step 의 시작 지점에 다이아몬드 ◆ — After Effects 키프레임 마커.
    @ViewBuilder
    private func keyframeDiamonds(scale: CGFloat) -> some View {
        let diamondY = rulerHeight + 6 + (trackHeight - 12) * 0.5
        ForEach(stepFrames, id: \.index) { f in
            let isSel = f.index == selectedStep
            let x = CGFloat(f.startMs) * scale
            KeyframeDiamond(selected: isSel)
                .offset(x: x - 6, y: diamondY - 6)
                .onTapGesture { selectedStep = f.index; onSeek(Double(f.startMs)) }
                .help("키프레임 \(f.index + 1) — \(f.startMs)ms")
        }
    }

    // MARK: - 4. Playhead (재생 헤드)

    /// 빨간 세로 선 + 위쪽 ▼ handle — Premiere/FCP playhead.
    private func playhead(scale: CGFloat, height: CGFloat) -> some View {
        let x = CGFloat(elapsedMs) * scale
        return ZStack(alignment: .topLeading) {
            // 세로 선
            Rectangle()
                .fill(DFColor.forge)
                .frame(width: DFSpace.micro2, height: height)
                .shadow(color: DFColor.forge.opacity(DFOpacity.dim), radius: 3)
            // 위쪽 handle (▼ 캐럿)
            PlayheadHandle()
                .fill(DFColor.forge)
                .frame(width: 14, height: rulerHeight)
                .offset(x: -6, y: 0)
        }
        .offset(x: x)
        .allowsHitTesting(false)   // 스크럽은 전체 영역 gesture 에서 처리.
    }

    // MARK: - Scrub gesture

    private func scrubGesture(scale: CGFloat, totalMs: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let ms = Double(value.location.x) / Double(scale)
                onSeek(ms.clamped(to: 0...Double(totalMs)))
            }
    }

    // MARK: - Step frame model

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
}

// MARK: - Keyframe diamond shape

/// After Effects 의 키프레임 다이아몬드 — 흰 fill + tint stroke + 선택 시 강조.
private struct KeyframeDiamond: View {
    let selected: Bool
    var body: some View {
        let tint = selected ? DFColor.forge : DFColor.accent
        return ZStack {
            Diamond()
                .fill(tint)
                .frame(width: 12, height: 12)
            Diamond()
                .stroke(.white, lineWidth: DFSize.borderHairline)
                .frame(width: 12, height: 12)
            // 선택 시 outer halo.
            if selected {
                Diamond()
                    .stroke(tint.opacity(DFOpacity.o45), lineWidth: DFSpace.micro2)
                    .frame(width: 18, height: 18)
            }
        }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Playhead handle (▼)

private struct PlayheadHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // 위 사다리꼴 + 아래 캐럿 (▼) — Premiere/FCP playhead handle.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.6))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.6))
        p.closeSubpath()
        return p
    }
}
