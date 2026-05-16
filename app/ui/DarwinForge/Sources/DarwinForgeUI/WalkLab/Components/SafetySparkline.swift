import SwiftUI

/// 안전 모니터링용 sparkline — 시간축 (x) + 값 (y) 라인 차트.
///
/// # UX 레퍼런스 근거
///
/// - **Edward Tufte — *The Visual Display of Quantitative Information* (1983)**:
///   sparkline = "small, intense, simple, word-sized graphics". 데이터-잉크 비율
///   극대화 — 축 label / grid / legend 최소화, 트렌드 형태가 핵심.
/// - **ISA-101 *Human Machine Interfaces for Process Automation Systems* (2015)**:
///   §6.4.2 — process trend 표시는 임계 zone 을 배경 음영으로. 본 sparkline 의
///   `thresholds` 가 동일 패턴 — 임계 영역을 음영, 데이터 라인은 단색.
/// - **NASA Ames *Primary Flight Display Design Guidelines* (1993)**:
///   §3.2 — pitch ladder 에 attitude 한계를 색 zone 으로 표시 (sky blue / amber /
///   red). 본 sparkline 도 안전/주의/위험 zone 을 가로 stripe 로 시각화.
/// - **NN/g *Data Visualization for Human Perception* (2024)**: 트렌드 차트는
///   최근값을 강조 (current value dot) — 본 차트가 마지막 sample 을 큰 원으로 표시.
///
/// # 데이터 입력
///
/// `samples` 는 `[(timestamp, value)]`. 시간순 정렬 가정 (caller 책임).
/// `thresholds` = 임계값 + 색 (예: `[(15, .yellow), (22, .orange), (30, .red)]`).
/// `valueRange` = y 축 범위 (자동 fitting 안 함 — 일관 비교 위해 caller 가 명시).
struct SafetySparkline: View {
    public struct Threshold: Equatable {
        public let value: Double
        public let color: Color
        public init(value: Double, color: Color) {
            self.value = value
            self.color = color
        }
    }

    /// (timestamp, value) 시계열. 시간 순 정렬 가정.
    let samples: [(Date, Double)]
    /// y 축 범위. 자동 X — 일관 비교용.
    let valueRange: ClosedRange<Double>
    /// 임계 line + 영역 음영. 음수 값이면 좌우 대칭 zone.
    let thresholds: [Threshold]
    /// 라인 색.
    let lineColor: Color
    /// 마지막 sample 의 origin (예: "-3.2°") — caller 가 fmt.
    let currentValueLabel: String?
    /// 차트 제목.
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            HStack(spacing: DFSpace.xs) {
                Text(title)
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if let l = currentValueLabel {
                    Text(l)
                        .font(DFFont.dataSmall)
                        .foregroundStyle(lineColor)
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                Canvas { ctx, size in
                    drawChart(ctx: ctx, size: size)
                }
                .background(DFColor.textSecondary.opacity(DFOpacity.o06).opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                                lineWidth: DFSize.borderHairline)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) 시계열 — 현재 \(currentValueLabel ?? "값 없음")")
    }

    /// Sparkline 내부 padding — 라인이 border 에 닿지 않도록.
    private static let chartPad: CGFloat = DFSpace.micro2  // 2pt
    /// Current value dot 반경.
    private static let currentDotR: CGFloat = DFSize.dot / 2  // 2.5pt
    /// 라인 두께 — Tufte data-ink minimalism.
    private static let lineW: CGFloat = 1.5
    /// 0 baseline dashed line 두께.
    private static let baselineW: CGFloat = DFSize.borderHairline  // 0.5pt

    /// Canvas 기반 직접 draw — `Path` 보다 perf 우위 (Tufte minimalism + 라이브 업데이트).
    private func drawChart(ctx: GraphicsContext, size: CGSize) {
        let pad = Self.chartPad
        let w = size.width - pad * 2
        let h = size.height - pad * 2
        let yMin = valueRange.lowerBound
        let yMax = valueRange.upperBound
        let ySpan = yMax - yMin
        guard ySpan > 0, w > 0, h > 0 else { return }

        // 1. 임계 zone 음영 — ISA-101 §6.4.2 패턴. yMin 부터 sorted threshold 까지.
        let sortedThresholds = thresholds.sorted { abs($0.value) < abs($1.value) }
        for thr in sortedThresholds {
            // 음수 / 양수 mirror 가능: yMin 이 음수면 -thr 도 영역.
            if yMin < 0 && thr.value > 0 {
                drawThresholdZone(ctx: ctx, size: size, pad: pad,
                                  yLowAbs: thr.value, color: thr.color)
            } else {
                drawThresholdZone(ctx: ctx, size: size, pad: pad,
                                  yLow: thr.value, color: thr.color)
            }
        }

        // 2. 0 base line (음수 / 양수 둘 다 있을 때).
        if yMin < 0 && yMax > 0 {
            let zeroY = pad + h * CGFloat((yMax - 0) / ySpan)
            var p = Path()
            p.move(to: CGPoint(x: pad, y: zeroY))
            p.addLine(to: CGPoint(x: pad + w, y: zeroY))
            ctx.stroke(p, with: .color(DFColor.textSecondary.opacity(DFOpacity.o25)),
                       style: StrokeStyle(lineWidth: Self.baselineW,
                                          dash: [DFSpace.micro2, DFSpace.micro2]))
        }

        // 3. 데이터 line.
        guard samples.count >= 2 else {
            // 단일 sample — 점 하나만.
            if let last = samples.last {
                drawCurrentDot(ctx: ctx, x: pad + w,
                               y: pad + h * CGFloat((yMax - last.1) / ySpan))
            }
            return
        }

        let tFirst = samples.first!.0.timeIntervalSinceReferenceDate
        let tLast = samples.last!.0.timeIntervalSinceReferenceDate
        let tSpan = tLast - tFirst
        // tSpan < 0.05s — 모든 점이 거의 같은 시각. 첫·마지막만 그림.
        guard tSpan > 0.05 else {
            if let last = samples.last {
                drawCurrentDot(ctx: ctx, x: pad + w,
                               y: pad + h * CGFloat((yMax - last.1) / ySpan))
            }
            return
        }

        var path = Path()
        for (i, s) in samples.enumerated() {
            let tNorm = (s.0.timeIntervalSinceReferenceDate - tFirst) / tSpan
            let x = pad + w * CGFloat(tNorm)
            let yNorm = (yMax - s.1) / ySpan
            let y = pad + h * CGFloat(max(0, min(1, yNorm)))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        ctx.stroke(path, with: .color(lineColor),
                   style: StrokeStyle(lineWidth: Self.lineW,
                                      lineCap: .round, lineJoin: .round))

        // 4. 마지막 sample dot — NN/g 권장 (현재 값 강조).
        if let last = samples.last {
            let yNorm = (yMax - last.1) / ySpan
            drawCurrentDot(ctx: ctx, x: pad + w,
                           y: pad + h * CGFloat(max(0, min(1, yNorm))))
        }
    }

    /// Current value dot — NN/g 권장 (현재 값 강조).
    /// 모든 dot draw 호출을 통일 — magic 2.5 / 5 제거.
    private func drawCurrentDot(ctx: GraphicsContext, x: CGFloat, y: CGFloat) {
        let r = Self.currentDotR
        ctx.fill(
            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
            with: .color(lineColor)
        )
    }

    /// 양수 임계 zone — value > yLow 영역 (위쪽).
    private func drawThresholdZone(ctx: GraphicsContext, size: CGSize, pad: CGFloat,
                                   yLow: Double, color: Color) {
        let yMin = valueRange.lowerBound
        let yMax = valueRange.upperBound
        let ySpan = yMax - yMin
        guard yLow >= yMin, yLow <= yMax else { return }
        let h = size.height - pad * 2
        let yTop = pad
        let yBottom = pad + h * CGFloat((yMax - yLow) / ySpan)
        let rect = CGRect(x: pad, y: yTop, width: size.width - pad * 2,
                          height: max(0, yBottom - yTop))
        ctx.fill(Path(rect), with: .color(color.opacity(DFOpacity.o12)))
    }

    /// 음수/양수 대칭 zone — `|value| > yLowAbs`.
    private func drawThresholdZone(ctx: GraphicsContext, size: CGSize, pad: CGFloat,
                                   yLowAbs: Double, color: Color) {
        let yMin = valueRange.lowerBound
        let yMax = valueRange.upperBound
        let ySpan = yMax - yMin
        let h = size.height - pad * 2
        // 양수 영역 — yMax 부터 +yLowAbs 까지.
        if yMax >= yLowAbs {
            let yTop = pad
            let yBottom = pad + h * CGFloat((yMax - yLowAbs) / ySpan)
            let rect = CGRect(x: pad, y: yTop, width: size.width - pad * 2,
                              height: max(0, yBottom - yTop))
            ctx.fill(Path(rect), with: .color(color.opacity(DFOpacity.o12)))
        }
        // 음수 영역 — -yLowAbs 부터 yMin 까지.
        if yMin <= -yLowAbs {
            let yTop = pad + h * CGFloat((yMax - (-yLowAbs)) / ySpan)
            let yBottom = pad + h
            let rect = CGRect(x: pad, y: yTop, width: size.width - pad * 2,
                              height: max(0, yBottom - yTop))
            ctx.fill(Path(rect), with: .color(color.opacity(DFOpacity.o12)))
        }
    }
}
