import SwiftUI

/// 보행 속도 게이지 — v1.0 sim 만 (PRD §3 좌측 패널 3).
///
/// HIG: 네이티브 Slider + segment bar 비주얼. 색상은 KS S ISO 7010.
public struct PilotSpeedGauge: View {
    @Binding var speedFraction: Double  // 0..1

    public init(speedFraction: Binding<Double>) {
        self._speedFraction = speedFraction
    }

    public var body: some View {
        DFPanel(
            "보행 속도",
            subtitle: "sim 미리보기 — v2 에서 실 모터 송출",
            icon: "speedometer",
            tint: PilotColor.speedSafe,
            trailing: {
                Text("\(Int(speedFraction * 100))%")
                    .font(DFFont.bodyEmph.monospaced())
                    .foregroundStyle(currentTint)
                    .frame(minWidth: 38, alignment: .trailing)
            }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                gaugeBar
                Slider(value: $speedFraction, in: 0...1) {
                    Text("속도")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                } maximumValueLabel: {
                    Image(systemName: "hare.fill")
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                }
                .controlSize(.small)
                .tint(currentTint)
                // 2026-05-17 a11y: accessibilityValue 한국어 zone 정보 추가.
                // 종전엔 "0.45" raw decimal 만 → 사용자는 안전/주의/위험 인지 못 함.
                .accessibilityLabel("보행 속도")
                .accessibilityValue("\(Int(speedFraction * 100))퍼센트, \(currentTintLabel)")
            }
        }
    }

    private var currentTintLabel: String {
        if speedFraction < 0.40 { return "안전" }
        if speedFraction < 0.70 { return "주의" }
        return "위험"
    }

    private var gaugeBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DFColor.elev2)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [PilotColor.speedSafe, PilotColor.speedCaution, PilotColor.speedDanger],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(2, geo.size.width * speedFraction))
                    .animation(PilotAnim.gauge, value: speedFraction)
            }
        }
        .frame(height: 10)
    }

    private var currentTint: Color {
        if speedFraction < 0.40 { return PilotColor.speedSafe }
        if speedFraction < 0.70 { return PilotColor.speedCaution }
        return PilotColor.speedDanger
    }
}
