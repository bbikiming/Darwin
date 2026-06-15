import SwiftUI

/// 헤드 무빙 컨트롤 — pan/tilt 슬라이더 + on/off + 자동 추적 (다음 사이클).
///
/// pan: -45 ~ 45 deg
/// tilt: -30 ~ 20 deg
public struct DSHeadControl: View {
    @Binding var enabled: Bool
    @Binding var panDeg: Double
    @Binding var tiltDeg: Double
    let trackingAvailable: Bool
    @Binding var trackingEnabled: Bool
    let disabled: Bool
    let onChange: (Bool, Double, Double, Bool) -> Void

    public init(enabled: Binding<Bool>,
                panDeg: Binding<Double>,
                tiltDeg: Binding<Double>,
                trackingAvailable: Bool = false,
                trackingEnabled: Binding<Bool>,
                disabled: Bool = false,
                onChange: @escaping (Bool, Double, Double, Bool) -> Void) {
        _enabled = enabled
        _panDeg = panDeg
        _tiltDeg = tiltDeg
        self.trackingAvailable = trackingAvailable
        _trackingEnabled = trackingEnabled
        self.disabled = disabled
        self.onChange = onChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Label("헤드", systemImage: "person.crop.circle")
                    .font(DS.Font.sectionTitle)
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .disabled(disabled)
                    .accessibilityIdentifier("pilot.head.toggle")
            }

            // Pan
            sliderRow(title: "좌우 (Pan)",
                      value: $panDeg, range: -45...45, step: 1,
                      systemImage: "arrow.left.and.right",
                      unit: "°")
                .accessibilityIdentifier("pilot.head.pan")

            // Tilt
            sliderRow(title: "위/아래 (Tilt)",
                      value: $tiltDeg, range: -30...20, step: 1,
                      systemImage: "arrow.up.and.down",
                      unit: "°")
                .accessibilityIdentifier("pilot.head.tilt")

            HStack {
                Image(systemName: trackingAvailable ? "scope" : "scope")
                    .foregroundStyle(trackingAvailable ? DS.Color.brand : DS.Color.disabled)
                Toggle("자동 추적", isOn: $trackingEnabled)
                    .disabled(disabled || !trackingAvailable)
                Spacer()
                if !trackingAvailable {
                    DSChip("준비 중", tone: .neutral)
                }
            }
            .font(DS.Font.body)
            .accessibilityIdentifier("pilot.head.tracking")

            DSButton("중앙 정렬",
                     systemImage: "scope",
                     style: .secondary,
                     size: .small,
                     fullWidth: true,
                     disabled: disabled || !enabled) {
                panDeg = 0
                tiltDeg = 0
                onChange(enabled, 0, 0, trackingEnabled)
            }
        }
        .opacity(disabled ? 0.45 : 1)
        .onChange(of: enabled) { _, new in onChange(new, panDeg, tiltDeg, trackingEnabled) }
        .onChange(of: panDeg) { _, new in onChange(enabled, new, tiltDeg, trackingEnabled) }
        .onChange(of: tiltDeg) { _, new in onChange(enabled, panDeg, new, trackingEnabled) }
        .onChange(of: trackingEnabled) { _, new in onChange(enabled, panDeg, tiltDeg, new) }
    }

    private func sliderRow(title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           systemImage: String,
                           unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(DS.Font.captionEmphasis.monospacedDigit())
                    .foregroundStyle(DS.Color.primaryText)
            }
            Slider(value: value, in: range, step: step)
                .disabled(disabled || !enabled)
                .tint(DS.Color.accent)
        }
    }
}
