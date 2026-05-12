import ForgeCore
import SwiftUI

/// Walk Lab 슬라이더 — 안전 색대역 + tick 스냅 + 미세 조정(⌥) + 실시간 값/단위 표시.
///
/// 시각화:
///   - 트랙 배경: safe(녹색) / caution(노랑) / highRisk(빨강) 3-구역 그라데이션.
///   - thumb 색은 현재 위치의 위험도와 매칭. critical 영역(>cap)은 빨간 패턴.
///   - tick: preset 권장값 (예: 보폭 15/25/35 mm) 작은 다이아몬드.
///   - vernier: Option 키를 누른 채 드래그하면 5배 더 미세하게 움직임.
///
/// 사용자 인터랙션:
///   - 드래그 → 즉시 value 갱신, `onChange` 호출.
///   - 더블 클릭 thumb → 가장 가까운 tick 으로 스냅.
///   - "cap" 을 넘으면 시각적으로 빨간 패턴, value 는 cap 으로 자동 클램프 (force-override
///     플래그 없으면).
public struct SafetyBandedSlider: View {
    @Binding var value: Double
    public let range: ClosedRange<Double>
    /// 안전/주의/위험 경계. [safeUpper, cautionUpper] — 두 값. 단방향 슬라이더 가정.
    /// 양방향(예: 측면 -20..20) 은 절대값 기준으로 해석 (`bidirectional=true`).
    public let bands: SafetyBands
    /// Smart-clamp 상한. nil 이면 range.upperBound 사용. 사용자가 force-override 한 경우 무시.
    public let cap: Double?
    /// 권장 tick 위치 (사용자 친화 stop 점). 더블 클릭으로 스냅.
    public let ticks: [Double]
    /// 라벨 (예: "보폭").
    public let label: String
    /// 단위 표시용 포맷 클로저.
    public let unitLabel: (Double) -> String
    /// 양방향 슬라이더? (측면/회전은 ±)
    public let bidirectional: Bool
    /// force override — 사용자가 명시적으로 cap 무시 토글.
    public let forceOverride: Bool

    @State private var dragStartValue: Double?
    @State private var isHovering: Bool = false
    /// modifier flag — Option 누른 상태에서 시작했는지.
    @State private var verniering: Bool = false

    public init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        bands: SafetyBands,
        cap: Double? = nil,
        ticks: [Double] = [],
        label: String,
        bidirectional: Bool = false,
        forceOverride: Bool = false,
        unitLabel: @escaping (Double) -> String
    ) {
        self._value = value
        self.range = range
        self.bands = bands
        self.cap = cap
        self.ticks = ticks
        self.label = label
        self.bidirectional = bidirectional
        self.forceOverride = forceOverride
        self.unitLabel = unitLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.sm) {
                Text(label)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text(unitLabel(value))
                    .font(DFFont.mono)
                    .foregroundStyle(currentZoneColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(currentZoneColor.opacity(DFOpacity.o15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if verniering {
                    Text("⌥ 미세")
                        .font(.system(size: DFFontSize.s9, weight: .semibold))
                        .foregroundStyle(DFColor.accent)
                }
            }
            GeometryReader { geo in
                let trackHeight: CGFloat = 8
                let thumbSize: CGFloat = 16
                let usable = max(1, geo.size.width - thumbSize)
                let pct = self.percentile
                let thumbX = CGFloat(pct) * usable

                ZStack(alignment: .leading) {
                    // 색대역 트랙
                    bandsTrack(width: geo.size.width, height: trackHeight)
                        .frame(height: trackHeight)
                        .clipShape(Capsule())
                        .padding(.vertical, (thumbSize - trackHeight) / 2)

                    // cap 초과 영역 빨간 패턴
                    if let cap = effectiveCap, !forceOverride {
                        let capPct = percentile(for: cap)
                        let capX = CGFloat(capPct) * usable + thumbSize / 2
                        let overWidth = max(0, geo.size.width - capX)
                        if overWidth > 0 {
                            Rectangle()
                                .fill(DFColor.danger.opacity(DFOpacity.disabled))
                                .frame(width: overWidth, height: trackHeight)
                                .padding(.leading, capX)
                                .padding(.vertical, (thumbSize - trackHeight) / 2)
                        }
                    }

                    // tick 다이아몬드
                    ForEach(ticks, id: \.self) { t in
                        let tx = CGFloat(percentile(for: t)) * usable + thumbSize / 2
                        Diamond()
                            .fill(DFColor.textSecondary.opacity(DFOpacity.dim))
                            .frame(width: DFSize.indicatorXxs, height: DFSize.indicatorXxs)
                            .position(x: tx, y: geo.size.height / 2)
                            .help("권장 \(unitLabel(t))")
                    }

                    // thumb
                    Circle()
                        .fill(currentZoneColor)
                        .frame(width: thumbSize, height: thumbSize)
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(DFOpacity.o30), radius: 2, y: 1)
                        .offset(x: thumbX, y: 0)
                        .gesture(dragGesture(usable: usable, thumbSize: thumbSize))
                        .onHover { isHovering = $0 }
                }
                .frame(height: thumbSize)
            }
            .frame(height: 16)
        }
    }

    // MARK: - Drag

    private func dragGesture(usable: CGFloat, thumbSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStartValue == nil {
                    dragStartValue = value
                }
                let option = NSEvent.modifierFlags.contains(.option)
                verniering = option
                let raw = v.translation.width
                let scale = option ? 0.2 : 1.0    // ⌥ → 5배 미세
                let deltaPct = Double(raw * CGFloat(scale)) / Double(usable)
                let deltaVal = deltaPct * (range.upperBound - range.lowerBound)
                let newVal = (dragStartValue ?? value) + deltaVal
                value = clampWithCap(newVal)
            }
            .onEnded { _ in
                dragStartValue = nil
                verniering = false
            }
    }

    private func clampWithCap(_ raw: Double) -> Double {
        var v = max(range.lowerBound, min(range.upperBound, raw))
        if !forceOverride, let cap = effectiveCap {
            // bidirectional 의 경우 ±cap 으로 해석
            if bidirectional {
                v = max(-cap, min(cap, v))
            } else {
                v = min(cap, v)
            }
        }
        return v
    }

    private var effectiveCap: Double? {
        cap.map { $0 }
    }

    // MARK: - Visualization helpers

    private var percentile: Double {
        percentile(for: value)
    }

    private func percentile(for v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (v - range.lowerBound) / span
    }

    /// 현재 thumb 색 — 위치가 어느 band 에 있는지.
    private var currentZoneColor: Color {
        let v = bidirectional ? abs(value) : value
        if bands.safeRange.contains(v) { return DFColor.success }
        if bands.cautionRange.contains(v) { return DFColor.warning }
        return DFColor.danger
    }

    /// 색대역 트랙 — 임의 범위/방향 모두 지원. 각 픽셀을 sample 해서 해당 위치 값이
    /// 어느 band 에 속하는지 결정. range 의 양 끝까지 모두 칠해진다.
    ///
    /// 단방향: 좌(min) → 우(max). bidirectional: range 가 ±인 경우 0 이 중앙.
    @ViewBuilder
    private func bandsTrack(width: CGFloat, height: CGFloat) -> some View {
        let steps = 20
        let stepWidth = width / CGFloat(steps)
        HStack(spacing: DFSpace.none) {
            ForEach(0..<steps, id: \.self) { i in
                Rectangle()
                    .fill(bandColor(forStep: i, of: steps))
                    .frame(width: stepWidth, height: height)
            }
        }
        .frame(height: height)
    }

    /// 한 픽셀(=step) 의 중심값이 어느 band 에 속하는지 결정. 본 helper 는
    /// `bandsTrack` 의 ViewBuilder 표현식을 단순화해 SwiftUI 타입 체커가
    /// 폭주하지 않도록 분리. (단일 표현 내 ForEach + Range.contains + 다중
    /// 분기 + Color 결합 시 type-check 타임아웃 발생.)
    private func bandColor(forStep i: Int, of steps: Int) -> Color {
        let span = range.upperBound - range.lowerBound
        let valAtPixel = range.lowerBound + (Double(i) + 0.5) / Double(steps) * span
        let testVal = bidirectional ? abs(valAtPixel) : valAtPixel
        if bands.safeRange.contains(testVal) {
            return DFColor.success.opacity(0.55)
        } else if bands.cautionRange.contains(testVal) {
            return DFColor.warning.opacity(0.65)
        } else {
            return DFColor.danger.opacity(0.65)
        }
    }
}

/// 안전 경계 임계값. **명시적 범위** 모델 — inverted 슬라이더 (주기) 와
/// sweet-spot 슬라이더 (균형 게인 / 발 들기) 모두 자연스럽게 표현.
///
/// 우선순위: `safeRange` 안에 있으면 safe, 아니면 `cautionRange` 안에 있으면 caution,
/// 그 외는 highRisk. safeRange ⊆ cautionRange 일 필요 없음 (별도 평가).
public struct SafetyBands: Sendable, Equatable {
    public let safeRange: ClosedRange<Double>
    public let cautionRange: ClosedRange<Double>

    public init(safeRange: ClosedRange<Double>, cautionRange: ClosedRange<Double>) {
        self.safeRange = safeRange
        self.cautionRange = cautionRange
    }

    /// 단방향 편의 — value ≤ safeUpper 는 safe, value ≤ cautionUpper 는 caution.
    public static func unidirectional(safeUpper: Double, cautionUpper: Double,
                                      range: ClosedRange<Double>) -> SafetyBands {
        SafetyBands(
            safeRange:    range.lowerBound...safeUpper,
            cautionRange: range.lowerBound...cautionUpper
        )
    }

    /// 역방향 편의 — value ≥ safeLower 는 safe (예: 주기는 클수록 안전).
    public static func inverted(safeLower: Double, cautionLower: Double,
                                range: ClosedRange<Double>) -> SafetyBands {
        SafetyBands(
            safeRange:    safeLower...range.upperBound,
            cautionRange: cautionLower...range.upperBound
        )
    }

    /// Sweet-spot — safeRange 중심, 양쪽으로 caution.
    public static func sweetSpot(safeMin: Double, safeMax: Double,
                                 cautionMin: Double, cautionMax: Double) -> SafetyBands {
        SafetyBands(
            safeRange:    safeMin...safeMax,
            cautionRange: cautionMin...cautionMax
        )
    }
}

/// 작은 마커용 다이아몬드 모양.
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
