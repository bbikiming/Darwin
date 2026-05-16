import SwiftUI

/// `DFSlider` — DarwinForge 디자인 시스템 표준 슬라이더.
///
/// macOS native `SwiftUI.Slider` 를 기반으로 디자인 토큰 (DFColor / DFFont / DFSpace /
/// DFRadius / DFOpacity) 을 적용한 일관된 슬라이더. Apple HIG (macOS Sonoma+) 정합.
///
/// ## 설계 원칙
///
/// - **네이티브 우선**: thumb/track 은 SwiftUI native — Sonoma 의 매끄러운 spring,
///   accessibility, dark mode, dynamic type 자동 지원.
/// - **시각 일관성**: title (좌) + value badge (우) + 옵션 caption / range 라벨.
///   모든 슬라이더가 같은 layout / typography / spacing.
/// - **데이터 시각화**: optional discrete `ticks` (권장 stop 점) → 작은 marker
///   overlay. ⌘+클릭 으로 스냅.
/// - **인터랙션 표준**:
///   - `onEditingChanged` 가 drag start/end 보고 — 실 robot 에 commit 분리 가능.
///   - editing 중 value badge 가 accent 색으로 강조 (사용자 인지).
///   - keyboard ↑↓ = step 미세 조정, ⇧+↑↓ = 10×step (SwiftUI native 동작).
/// - **접근성**: VoiceOver 라벨/값/단위 자동 합성. focus ring DFColor.focusRing.
///
/// ## 사용 예
///
/// ```swift
/// // 기본 — 정수 step
/// DFSlider("보폭", value: $stride, in: 0...100, step: 1, unit: "mm")
///
/// // 소수 — formatter 자동
/// DFSlider("Kp", value: $kp, in: 0...10, step: 0.1)
///
/// // 권장 stop 점 (tick marker)
/// DFSlider("Time Scale", value: $scale, in: 0.25...4.0, step: 0.05,
///          unit: "×", ticks: [0.5, 1.0, 2.0])
///
/// // 실 robot commit 분리
/// DFSlider("Goal Position", value: $pos, in: 0...4095, step: 1, unit: "raw") {
///     editing in
///     if !editing { try? bus.setPosition(joint, raw: UInt16(pos)) }
///   }
///
/// // 커스텀 포맷터
/// DFSlider("Angle", value: $deg, in: -180...180,
///          unitFormatter: { String(format: "%+.1f°", $0) })
///
/// // 위험도 accent (안전 critical)
/// DFSlider("토크 한계", value: $cap, in: 0...100, accent: DFColor.danger)
/// ```
///
/// - SeeAlso: `SafetyBandedSlider` — safe/caution/danger 3-구역 트랙이 필요한
///   walklab 등 안전 critical 영역에서 사용. `DFSlider` 의 상위 호환 변종.
public struct DFSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let unit: String?
    private let unitFormatter: ((Double) -> String)?
    private let accent: Color
    private let ticks: [Double]
    private let showRangeLabels: Bool
    private let showValueBadge: Bool
    private let caption: String?
    private let onEditingChanged: (Bool) -> Void

    @State private var isEditing: Bool = false

    /// 표준 이니셜라이저.
    ///
    /// - Parameters:
    ///   - title: 좌측 라벨 (예: "보폭", "Kp").
    ///   - value: 바인딩.
    ///   - range: 허용 범위.
    ///   - step: 스냅 단위. 0 이면 연속 값.
    ///   - unit: 단위 suffix (예: "mm", "°"). nil 이면 표시 안 함.
    ///   - unitFormatter: 커스텀 포맷터. 지정 시 `unit` 무시.
    ///   - accent: thumb/track tint. 기본 DFColor.accent (#0A84FF).
    ///   - ticks: 권장 stop 점 marker.
    ///   - showRangeLabels: 하단에 min/max 라벨 표시. 기본 false.
    ///   - showValueBadge: 우상단 value badge 표시. 기본 true.
    ///   - caption: title 옆 작은 부연 설명.
    ///   - onEditingChanged: drag start (`true`) / end (`false`) 콜백. 실 robot
    ///     commit 분리 시 사용.
    public init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 0,
        unit: String? = nil,
        unitFormatter: ((Double) -> String)? = nil,
        accent: Color = DFColor.accent,
        ticks: [Double] = [],
        showRangeLabels: Bool = false,
        showValueBadge: Bool = true,
        caption: String? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.unitFormatter = unitFormatter
        self.accent = accent
        self.ticks = ticks
        self.showRangeLabels = showRangeLabels
        self.showValueBadge = showValueBadge
        self.caption = caption
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            titleRow
            sliderRow
            if showRangeLabels {
                rangeRow
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(formattedValue)
    }

    // MARK: - Subviews

    private var titleRow: some View {
        HStack(spacing: DFSpace.sm) {
            Text(title)
                .font(DFFont.bodySmallEmph)
                .foregroundStyle(DFColor.textPrimary)
            if let caption = caption {
                Text(caption)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer(minLength: DFSpace.sm)
            if showValueBadge {
                valueBadge
            }
        }
    }

    private var valueBadge: some View {
        // editing 중에는 accent 색 강조 → 사용자가 변경 중임을 인지.
        let active = isEditing
        let textColor = active ? accent : DFColor.textPrimary
        let bgColor = (active ? accent : DFColor.textSecondary)
            .opacity(active ? DFOpacity.o15 : DFOpacity.ghost)
        return Text(formattedValue)
            .font(DFFont.dataSmall)
            .foregroundStyle(textColor)
            .monospacedDigit()
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.xs, style: .continuous)
                    .fill(bgColor)
            )
            .animation(DFAnimation.fast, value: active)
    }

    private var sliderRow: some View {
        ZStack(alignment: .center) {
            // tick markers 먼저 (overlay 의 GeometryReader 가 Slider 보다 아래)
            if !ticks.isEmpty {
                tickLayer
            }
            // macOS native Slider — Sonoma+ 의 모든 인터랙션/접근성 자동 적용.
            sliderControl
        }
    }

    @ViewBuilder
    private var sliderControl: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step) { editing in
                isEditing = editing
                onEditingChanged(editing)
            }
            .tint(accent)
        } else {
            Slider(value: $value, in: range) { editing in
                isEditing = editing
                onEditingChanged(editing)
            }
            .tint(accent)
        }
    }

    private var tickLayer: some View {
        GeometryReader { geo in
            // SwiftUI Slider 의 thumb 가 양 끝에서 일정 inset 위치에 있음 — 8pt 가
            // 시각적으로 thumb 중심선과 정합 (macOS Sonoma 기준).
            let inset: CGFloat = DFSpace.sm
            let usable = max(1, geo.size.width - inset * 2)
            let span = max(0.000_001, range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                ForEach(ticks, id: \.self) { tick in
                    let pct = (tick - range.lowerBound) / span
                    if (0.0...1.0).contains(pct) {
                        Circle()
                            .fill(DFColor.textSecondary.opacity(DFOpacity.dim))
                            .frame(width: 3, height: 3)
                            .offset(x: inset + CGFloat(pct) * usable - 1.5)
                            .help("권장 \(formatValue(tick))")
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 4)
        .allowsHitTesting(false)
    }

    private var rangeRow: some View {
        HStack {
            Text(formatValue(range.lowerBound))
            Spacer()
            Text(formatValue(range.upperBound))
        }
        .font(DFFont.micro)
        .foregroundStyle(DFColor.textSecondary)
        .monospacedDigit()
        .accessibilityHidden(true)
    }

    // MARK: - Formatting

    /// 현재 value 의 표시 문자열.
    private var formattedValue: String { formatValue(value) }

    private func formatValue(_ v: Double) -> String {
        if let formatter = unitFormatter {
            return formatter(v)
        }
        let formatted = defaultNumberString(v)
        if let unit = unit, !unit.isEmpty {
            // % / × 등 narrow 단위는 공백 없이, 일반 단위는 공백 한 칸.
            let tight: Set<String> = ["%", "×", "x", "°"]
            return tight.contains(unit) ? "\(formatted)\(unit)" : "\(formatted) \(unit)"
        }
        return formatted
    }

    /// step 자릿수에 맞춰 자동 포맷.
    private func defaultNumberString(_ v: Double) -> String {
        if step >= 1 || step == 0 && abs(v) >= 100 {
            return String(format: "%.0f", v)
        } else if step >= 0.1 || abs(v) >= 10 {
            return String(format: "%.1f", v)
        } else if step >= 0.01 {
            return String(format: "%.2f", v)
        } else {
            return String(format: "%.3f", v)
        }
    }
}

#if DEBUG
struct DFSlider_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            // 기본 — 정수 step
            DFSlider("보폭", value: .constant(45), in: 0...100, step: 1, unit: "mm")

            // 소수 — formatter 자동
            DFSlider("Kp", value: .constant(2.5), in: 0...10, step: 0.1)

            // 권장 stop 점 marker
            DFSlider(
                "Time Scale", value: .constant(1.0),
                in: 0.25...4.0, step: 0.05, unit: "×",
                ticks: [0.5, 1.0, 2.0],
                showRangeLabels: true
            )

            // caption + 위험도 accent
            DFSlider(
                "토크 한계", value: .constant(75),
                in: 0...100, step: 1, unit: "%",
                accent: DFColor.danger,
                caption: "안전 한계 초과 시 위험"
            )

            // 커스텀 formatter — 각도
            DFSlider(
                "Angle", value: .constant(-30),
                in: -180...180, step: 1,
                unitFormatter: { String(format: "%+.0f°", $0) }
            )
        }
        .padding(DFSpace.lg)
        .background(DFColor.canvas)
        .frame(width: 420)
    }
}
#endif
