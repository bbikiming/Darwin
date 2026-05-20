import SwiftUI

/// **DFStatusTile** — 안전 layer / 모니터링 상태 tile (icon + name + value + threshold).
///
/// NASA EICAS 패턴 — 시스템 상태 tile grid 의 한 셀.
/// LazyVGrid `GridItem(.adaptive(minimum: 110))` 안에서 자동 wrap.
///
/// # UX 레퍼런스
///
/// - **NASA Ames** *PFD Design Guidelines* §4.1: EICAS 6-tile grid pattern.
/// - **ISA-101** §6.3: gray + semantic color HMI (배경 흐림 + 상태색만 강조).
/// - **NN/g** *Color + shape + label*: icon + 라벨 + 색 3중 (WCAG §1.4.1).
///
/// # 사용
///
/// ```swift
/// DFStatusTile(
///     name: "L3 IMU Tilt",
///     icon: "gyroscope",
///     valueLabel: "5.2",
///     unit: "°",
///     thresholdLabel: "25/35/45/50° 5단계",
///     tint: DFColor.success,
///     sourcePill: DFSourcePill(label: "실 IMU", tint: DFColor.success)
/// )
/// ```
public struct DFStatusTile<SourcePill: View>: View {
    public let name: String
    public let icon: String
    public let valueLabel: String
    public let unit: String?
    public let thresholdLabel: String
    public let tint: Color
    @ViewBuilder public let sourcePill: () -> SourcePill

    public init(name: String, icon: String, valueLabel: String,
                unit: String?, thresholdLabel: String, tint: Color,
                @ViewBuilder sourcePill: @escaping () -> SourcePill = { EmptyView() }) {
        self.name = name
        self.icon = icon
        self.valueLabel = valueLabel
        self.unit = unit
        self.thresholdLabel = thresholdLabel
        self.tint = tint
        self.sourcePill = sourcePill
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: icon)
                    .font(DFFont.label)
                    .foregroundStyle(tint)
                Text(name)
                    .font(DFFont.sectionLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                sourcePill()
                    .layoutPriority(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: DFSpace.micro2) {
                Text(valueLabel)
                    .font(DFFont.dataMedium)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(thresholdLabel)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(thresholdLabel)  // 잘림 시 hover 로 전체 확인
        }
        .padding(DFSpace.xs2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(DFOpacity.o06))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.statusTile)
                .stroke(tint.opacity(DFOpacity.o25),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.statusTile))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) \(valueLabel)\(unit ?? "")")
        .accessibilityValue(thresholdLabel)
    }
}

#if DEBUG
struct DFStatusTile_Previews: PreviewProvider {
    static var previews: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: 4)],
            spacing: 4
        ) {
            DFStatusTile(
                name: "L3 IMU Tilt",
                icon: "gyroscope",
                valueLabel: "5.2",
                unit: "°",
                thresholdLabel: "25/35/45/50° 5단계",
                tint: DFColor.success,
                sourcePill: { DFSourcePill(label: "실 IMU", tint: DFColor.success) }
            )
            DFStatusTile(
                name: "L6 Thermal",
                icon: "thermometer.medium",
                valueLabel: "42.3",
                unit: "°C",
                thresholdLabel: "≥ 60°C = 자동 정지",
                tint: DFColor.warning,
                sourcePill: { DFSourcePill(label: "실 모터", tint: DFColor.success) }
            )
        }
        .padding()
        .background(DFColor.canvas)
        .frame(width: 400)
    }
}
#endif
