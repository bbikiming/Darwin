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
    // 2026-05-16 정정: 부모 struct 가 internal 이라 nested `public` 는 의미 없음.
    // (Swift 컴파일러 경고 회피 — internal 로 일관)
    struct Threshold: Equatable {
        let value: Double
        let color: Color
        init(value: Double, color: Color) {
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
        // 2026-05-17 시스템 경계 가드: caller 가 NaN/Inf range 보내도 차트 무너지지 않게.
        // ZStack/.offset y 좌표 = NaN 시 SwiftUI 런타임 경고 발생.
        let ySpan = valueRange.upperBound - valueRange.lowerBound
        let isValueRangeValid = valueRange.lowerBound.isFinite
            && valueRange.upperBound.isFinite
            && ySpan > 0 && ySpan.isFinite
        let hasData = samples.count >= 2
        return VStack(alignment: .leading, spacing: DFSpace.micro2) {
            HStack(spacing: DFSpace.xs) {
                Text(title)
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                // **2026-05-16 시인성**: 트렌드 화살표 — 최근 3 sample slope.
                trendArrow
                Spacer()
                // 2026-05-17 a11y/empty: 데이터 수신 전까지 currentValueLabel 숨김.
                // sample 0~1 시 stale value 노출 방지 — 종전엔 empty overlay 만 차트
                // 가렸지만 header 의 +0.0° 가 그대로 노출.
                if hasData, let l = currentValueLabel {
                    Text(l)
                        .font(DFFont.dataSmall)
                        .foregroundStyle(lineColor)
                        .lineLimit(1)
                }
            }
            // 2026-05-17 구조 재설계: chart canvas + axis column 분리 HStack.
            // 종전 ZStack(.trailing) + thresholdLabels.offset(x: -2pt) 이 차트
            // 캔버스 안쪽에 라벨 박혀 데이터 라인과 겹쳤음 (사용자 보고 결함).
            HStack(spacing: DFSpace.micro2) {
                GeometryReader { geo in
                    ZStack {
                        Canvas { ctx, size in
                            drawChart(ctx: ctx, size: size)
                        }
                        .background(DFColor.textSecondary.opacity(DFOpacity.o06).opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.statusTile))
                        .overlay(
                            RoundedRectangle(cornerRadius: DFRadius.statusTile)
                                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                                        lineWidth: DFSize.borderHairline)
                        )
                        .frame(width: geo.size.width, height: geo.size.height)

                        if !hasData {
                            emptyStateOverlay
                        }
                    }
                }
                // y 축 라벨 컬럼 — 차트와 동일 높이 자동 매칭 (HStack vertical fill).
                GeometryReader { geo in
                    axisColumn(height: geo.size.height, isValid: isValueRangeValid)
                }
                .frame(width: Self.axisColumnW)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedAccessibilityLabel)
        // v1.11.15 cycle 2: 무채색 GUI 에서 safety sparkline 색 보존 — 임계 zone 시인성.
        .dfChartAccent()
    }

    // MARK: - 시인성 helpers (2026-05-16)

    /// 최근 3 sample 의 slope 기반 트렌드 — ↑ / → / ↓ Image.
    /// Apple Health 패턴 — 트렌드 즉시 인지.
    /// 2026-05-17 layout fix: .unknown 시 EmptyView 가 Spacer 폭을 흔들어 header
    /// 가 sample 수신 초기 (0→3개) 에 깜빡임. invisible placeholder 로 고정 폭 유지.
    @ViewBuilder
    private var trendArrow: some View {
        Group {
            switch computeTrend() {
            case .rising:
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(DFColor.severe)
            case .falling:
                Image(systemName: "arrow.down.right")
                    .foregroundStyle(DFColor.success)
            case .flat:
                Image(systemName: "arrow.right")
                    .foregroundStyle(DFColor.textSecondary)
            case .unknown:
                Image(systemName: "arrow.right")
                    .foregroundStyle(.clear)
            }
        }
        .font(DFFont.micro)
        .accessibilityHidden(true)
    }

    /// 2026-05-17 a11y: VoiceOver 통합 라벨 — 종전엔 `currentValueLabel` + 트렌드만,
    /// 임계값 자체 (15/22/30°) 가 빠져 시각 외 사용자는 "위험 구간 여부" 판단 불가.
    /// 안전 모니터링 컨텍스트에서 critical — WCAG 1.3.1 / 1.4.1 정합.
    private var combinedAccessibilityLabel: String {
        var parts: [String] = ["\(title) 시계열"]
        if samples.count >= 2, let l = currentValueLabel {
            parts.append("현재 \(l)")
        } else {
            parts.append("데이터 수집 중")
        }
        if !thresholds.isEmpty {
            let summary = thresholds
                .map { String(format: "%.0f", $0.value) }
                .joined(separator: ", ")
            parts.append("임계값 \(summary)")
        }
        switch computeTrend() {
        case .rising: parts.append("트렌드 상승")
        case .falling: parts.append("트렌드 하강")
        case .flat: parts.append("트렌드 평탄")
        case .unknown: break
        }
        return parts.joined(separator: ", ")
    }

    private enum Trend { case rising, falling, flat, unknown }

    /// 최근 3 sample 의 first→last delta. |delta| < 0.5 = flat.
    /// **2026-05-16 방어**: NaN sample 시 .unknown.
    private func computeTrend() -> Trend {
        guard samples.count >= 3 else { return .unknown }
        let recent = samples.suffix(3)
        guard let first = recent.first, let last = recent.last,
              first.1.isFinite, last.1.isFinite else { return .unknown }
        let delta = last.1 - first.1
        let threshold = max(0.5, (valueRange.upperBound - valueRange.lowerBound) * 0.02)
        if abs(delta) < threshold { return .flat }
        return delta > 0 ? .rising : .falling
    }

    /// 2026-05-17 구조: y 축 라벨 컬럼 — 차트 우측 분리 lane.
    /// ZStack(.topLeading) + .offset(y:) 으로 정확한 y 좌표 정렬.
    /// 종전 thresholdLabels 의 `.offset(x: -chartPad)` 차트 안쪽 cheat 제거.
    @ViewBuilder
    private func axisColumn(height: CGFloat, isValid: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if isValid {
                ForEach(Array(thresholds.enumerated()), id: \.offset) { _, thr in
                    axisLabelPair(threshold: thr, height: height,
                                  yMin: valueRange.lowerBound,
                                  yMax: valueRange.upperBound)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func axisLabelPair(threshold thr: Threshold,
                               height: CGFloat,
                               yMin: Double, yMax: Double) -> some View {
        let ySpan = yMax - yMin
        // 양수 라벨.
        if thr.value <= yMax, thr.value >= yMin, ySpan > 0 {
            let y = CGFloat((yMax - thr.value) / ySpan) * height
            axisLabel(thr.value, color: thr.color)
                .offset(y: y - Self.axisLabelVCenter)
        }
        // 음수 대칭 라벨.
        if yMin < 0, thr.value > 0, -thr.value >= yMin, ySpan > 0 {
            let y = CGFloat((yMax - (-thr.value)) / ySpan) * height
            axisLabel(-thr.value, color: thr.color)
                .offset(y: y - Self.axisLabelVCenter)
        }
    }

    /// 2026-05-17 시인성 fix: 7pt × opacity(0.6) Capsule → 9pt × full opacity.
    /// WCAG 2.2 AA 4.5:1 대비 확보 + safety-critical 정보 가독성.
    @ViewBuilder
    private func axisLabel(_ value: Double, color: Color) -> some View {
        Text(value >= 0 ? String(format: "%+.0f", value) : String(format: "%.0f", value))
            .font(DFFont.micro)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    /// Axis 라벨 컬럼 폭 — `+30` 9pt monospaced (~22pt 폭) + 좌우 여유 8pt.
    /// 3자리 (`+100` / `-100`) 도 `lineLimit(1)` + `fixedSize` 로 안전.
    private static let axisColumnW: CGFloat = 30
    /// Axis 라벨 vertical center offset — 9pt 폰트 lineHeight (~11pt) 절반.
    private static let axisLabelVCenter: CGFloat = 5

    /// Empty state — sample 미충분 시 안내.
    /// NN/g *Empty States* 가이드 — "no data" 상태도 명시.
    private var emptyStateOverlay: some View {
        VStack(spacing: DFSpace.micro2) {
            Image(systemName: "waveform")
                .font(DFIcon.label)
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
            Text("데이터 수집 중…")
                .font(DFFont.pill)
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("데이터 수집 중")
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
    /// **2026-05-16 방어**: NaN/Inf sample → 차트 깨짐 방지. drawChart 입구에서
    /// 필터링 + 각 좌표 변환에서 isFinite 가드.
    private func drawChart(ctx: GraphicsContext, size: CGSize) {
        let pad = Self.chartPad
        let w = size.width - pad * 2
        let h = size.height - pad * 2
        let yMin = valueRange.lowerBound
        let yMax = valueRange.upperBound
        let ySpan = yMax - yMin
        guard ySpan > 0, w > 0, h > 0,
              ySpan.isFinite, yMin.isFinite, yMax.isFinite else { return }

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

        // 1b. **2026-05-16 시인성**: 임계 라인 그리기 — NASA PFD 패턴.
        // zone stripe 위에 명확한 threshold line — 사용자가 정확한 임계 위치 인지.
        for thr in sortedThresholds {
            drawThresholdLine(ctx: ctx, size: size, pad: pad,
                              value: thr.value, color: thr.color, mirror: yMin < 0)
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

        // 3. 데이터 line + area fill.
        // **2026-05-16 방어**: NaN/Inf sample 사전 필터 — Canvas Path.move 가
        // NaN 받으면 그래프 깨짐. 잘못된 sensor 데이터에서도 안전.
        let validSamples = samples.filter { $0.1.isFinite }
        guard validSamples.count >= 2 else {
            // 단일 sample — 점 하나만.
            if let last = validSamples.last {
                drawCurrentDot(ctx: ctx, x: pad + w,
                               y: pad + h * CGFloat((yMax - last.1) / ySpan))
            }
            return
        }

        let tFirst = validSamples.first!.0.timeIntervalSinceReferenceDate
        let tLast = validSamples.last!.0.timeIntervalSinceReferenceDate
        let tSpan = tLast - tFirst
        // tSpan < 0.05s — 모든 점이 거의 같은 시각. 첫·마지막만 그림.
        guard tSpan > 0.05, tSpan.isFinite else {
            if let last = validSamples.last {
                drawCurrentDot(ctx: ctx, x: pad + w,
                               y: pad + h * CGFloat((yMax - last.1) / ySpan))
            }
            return
        }

        // **2026-05-16 시인성**: area fill — Apple Stocks 패턴.
        // line 아래 영역을 lineColor opacity gradient 로 채움 — 트렌드 강조.
        // 0 baseline 이 있으면 baseline 까지, 없으면 차트 하단까지.
        let baselineY: CGFloat = {
            if yMin < 0 && yMax > 0 {
                return pad + h * CGFloat((yMax - 0) / ySpan)
            }
            return pad + h
        }()

        // **2026-05-16 최적화**: 이전엔 area + line 을 separate iteration (validSamples × 2).
        // 정정: 단일 pass 로 두 path 동시 build — sample N 개일 때 2N → N point 계산.
        var areaPath = Path()
        var linePath = Path()
        for (i, s) in validSamples.enumerated() {
            let tNorm = (s.0.timeIntervalSinceReferenceDate - tFirst) / tSpan
            let x = pad + w * CGFloat(tNorm)
            let yNorm = (yMax - s.1) / ySpan
            let y = pad + h * CGFloat(max(0, min(1, yNorm)))
            if i == 0 {
                areaPath.move(to: CGPoint(x: x, y: baselineY))
                areaPath.addLine(to: CGPoint(x: x, y: y))
                linePath.move(to: CGPoint(x: x, y: y))
            } else {
                areaPath.addLine(to: CGPoint(x: x, y: y))
                linePath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        // 마지막 sample 의 x 에서 baseline 으로 내림.
        let lastX = pad + w
        areaPath.addLine(to: CGPoint(x: lastX, y: baselineY))
        areaPath.closeSubpath()
        ctx.fill(areaPath, with: .color(lineColor.opacity(DFOpacity.o20)))

        // 데이터 line (area 위에 그림 — 강조).
        ctx.stroke(linePath, with: .color(lineColor),
                   style: StrokeStyle(lineWidth: Self.lineW,
                                      lineCap: .round, lineJoin: .round))

        // 4. 마지막 sample dot — NN/g 권장 (현재 값 강조).
        if let last = validSamples.last {
            let yNorm = (yMax - last.1) / ySpan
            drawCurrentDot(ctx: ctx, x: pad + w,
                           y: pad + h * CGFloat(max(0, min(1, yNorm))))
        }
    }

    /// **2026-05-16 시인성**: 임계 라인 — zone stripe 위에 명확한 dashed line.
    /// 음수/양수 대칭 지원 (mirror=true 시).
    /// **2026-05-16 최적화**: 양수/음수 분기 → 공통 line draw helper 추출.
    private func drawThresholdLine(ctx: GraphicsContext, size: CGSize, pad: CGFloat,
                                   value: Double, color: Color, mirror: Bool) {
        let yMin = valueRange.lowerBound
        let yMax = valueRange.upperBound
        let ySpan = yMax - yMin
        guard ySpan > 0 else { return }
        let h = size.height - pad * 2
        let w = size.width - pad * 2
        let strokeStyle = StrokeStyle(lineWidth: Self.thresholdLineW,
                                      dash: Self.thresholdDash)
        let strokeColor = GraphicsContext.Shading.color(color.opacity(DFOpacity.o40))

        // 양수 영역.
        if value <= yMax, value >= yMin {
            let y = pad + h * CGFloat((yMax - value) / ySpan)
            ctx.stroke(Self.horizontalLine(at: y, fromX: pad, toX: pad + w),
                       with: strokeColor, style: strokeStyle)
        }
        // 음수 영역 (mirror).
        if mirror, value > 0, -value >= yMin, -value <= yMax {
            let y = pad + h * CGFloat((yMax - (-value)) / ySpan)
            ctx.stroke(Self.horizontalLine(at: y, fromX: pad, toX: pad + w),
                       with: strokeColor, style: strokeStyle)
        }
    }

    /// Threshold dashed line stroke 두께 — NASA PFD attitude indicator hairline.
    private static let thresholdLineW: CGFloat = DFSize.borderHairline
    /// Threshold dashed pattern — [dash, gap].
    private static let thresholdDash: [CGFloat] = [DFRadius.tiny + 1, DFSpace.micro2]

    /// 가로 라인 path 생성 — 반복 코드 제거 helper.
    private static func horizontalLine(at y: CGFloat, fromX: CGFloat, toX: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: fromX, y: y))
        p.addLine(to: CGPoint(x: toX, y: y))
        return p
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
