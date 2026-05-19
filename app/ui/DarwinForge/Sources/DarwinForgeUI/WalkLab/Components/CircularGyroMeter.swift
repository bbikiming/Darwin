import SwiftUI

/// **자동차 g-meter 스타일** 원형 자이로 시각화 — v1.7 (2026-05-17 사용자 요청).
///
/// Roll/Pitch 를 한 평면 위 좌표로 표시. 중심 = 직립 (0°, 0°). dot 위치 = 현재 기울기.
///
/// **시각 디자인** (ISA-101 EICAS 색 정책 + 차량 g-meter 직관):
///   - 동심원 = 안전 등급 임계 (15°/22°/28°/30°)
///   - 십자선 = roll(x)/pitch(y) 축
///   - dot = 현재 기울기, 색 = state-based
///   - 하단 라벨 = 수치 + 안전 등급
///
/// **데이터 흐름**: `WalkLabSession.imuRollDeg` / `imuPitchDeg` (5Hz polling, complementary
/// filter 적용). 또는 raw `ConnectionStore.imuFilter.rollDeg/pitchDeg`.
///
/// **a11y (WCAG 1.4.1 색 단독 정보 금지)**: 색상 + 텍스트 라벨 + accessibilityValue
/// 모두 안전 상태를 명시.
public struct CircularGyroMeter: View {
    /// Roll (degrees) — 좌우 기울기. -30..+30 expected.
    public let rollDeg: Double
    /// Pitch (degrees) — 앞뒤 기울기. -30..+30 expected.
    public let pitchDeg: Double
    /// Auto E-stop 임계 (기본 30°). dot 가 이 거리에 도달하면 위험 표시.
    public let dangerThreshold: Double
    /// 데이터 source 표시 (실 / sim / stale). nil 이면 라벨 없음.
    public let sourceLabel: String?
    /// 데이터 source 색 (실=success, sim=textSecondary, stale=warning).
    public let sourceColor: Color?
    /// 미터 외경 (pt). 기본 160.
    public let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(rollDeg: Double,
                pitchDeg: Double,
                dangerThreshold: Double = 50.0,
                sourceLabel: String? = nil,
                sourceColor: Color? = nil,
                diameter: CGFloat = 160) {
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
        self.dangerThreshold = dangerThreshold
        self.sourceLabel = sourceLabel
        self.sourceColor = sourceColor
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            // 배경 원
            Circle()
                .fill(DFColor.elev2)
                .strokeBorder(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 1)

            // 동심 격자 — 안전 등급 임계 (15°/22°/28°/30°)
            ForEach(thresholdRings, id: \.deg) { ring in
                Circle()
                    .strokeBorder(
                        ring.color.opacity(DFOpacity.o35),
                        style: StrokeStyle(lineWidth: ring.deg == 30 ? 1.0 : 0.5,
                                           dash: ring.deg == 30 ? [] : [2, 2])
                    )
                    .frame(width: diameter * CGFloat(ring.deg / dangerThreshold) * 0.92,
                           height: diameter * CGFloat(ring.deg / dangerThreshold) * 0.92)
            }

            // 십자선 (roll=0, pitch=0 중심)
            crosshair

            // 현재 tilt 위치 dot (roll, pitch → x, y 좌표 변환)
            let maxR: CGFloat = diameter * 0.46  // 반경의 92% = 30°
            let rollPx = (clampedRoll / dangerThreshold) * maxR
            // pitch positive (앞으로 기울임) = 위쪽 (음수 y offset in SwiftUI)
            let pitchPx = -(clampedPitch / dangerThreshold) * maxR

            // dot trail (이전 위치 잔상 — 동적 느낌 강화)
            if !reduceMotion {
                Circle()
                    .fill(currentColor.opacity(DFOpacity.o25))
                    .frame(width: 18, height: 18)
                    .offset(x: rollPx, y: pitchPx)
                    .blur(radius: 6)
            }

            Circle()
                .fill(currentColor)
                .shadow(color: currentColor.opacity(0.6), radius: 4, y: 1)
                .frame(width: 12, height: 12)
                .offset(x: rollPx, y: pitchPx)
                .animation(.easeOut(duration: 0.15), value: rollDeg)
                .animation(.easeOut(duration: 0.15), value: pitchDeg)

            // 수치 + 라벨 (하단 중앙)
            VStack(spacing: DFSpace.micro2) {
                Text(String(format: "R%+.0f° P%+.0f°", rollDeg, pitchDeg))
                    .font(DFFont.dataMedium)
                    .foregroundStyle(currentColor)
                if let src = sourceLabel {
                    Text(src)
                        .font(DFFont.label)
                        .foregroundStyle(sourceColor ?? DFColor.textSecondary)
                } else {
                    Text(safetyLabel)
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            .padding(.top, diameter * 0.55)

            // 축 라벨 (R/F/L/B) — pilot orientation
            axisLabels
        }
        .frame(width: diameter, height: diameter)
        // v1.11.15 cycle 3 (2026-05-19): 자이로 시각화 외곽에 forge blue 강조 ring +
        // 무채색 GUI 에서도 색 보존. 자동차 g-meter 처럼 차트 자체가 시각 hero 요소.
        .overlay(
            Circle()
                .stroke(DFColor.forge.opacity(DFOpacity.o30), lineWidth: 1.5)
        )
        .dfThemedShadow(color: DFColor.forge.opacity(0.15), radius: 8, y: 2)
        .dfChartAccent()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("자이로 기울기")
        .accessibilityValue("Roll \(Int(rollDeg.rounded()))도, Pitch \(Int(pitchDeg.rounded()))도, \(safetyLabel)")
    }

    // MARK: - Subviews

    @ViewBuilder
    private var crosshair: some View {
        // 가로선
        RoundedRectangle(cornerRadius: 0.5)
            .fill(DFColor.textSecondary.opacity(DFOpacity.o25))
            .frame(width: diameter * 0.92, height: 0.5)
        // 세로선
        RoundedRectangle(cornerRadius: 0.5)
            .fill(DFColor.textSecondary.opacity(DFOpacity.o25))
            .frame(width: 0.5, height: diameter * 0.92)
    }

    @ViewBuilder
    private var axisLabels: some View {
        // F (Forward / pitch +) — top
        Text("F")
            .font(DFFont.monoMicro)
            .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o35))
            .offset(y: -diameter * 0.42)
        // B (Back / pitch -) — bottom
        Text("B")
            .font(DFFont.monoMicro)
            .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o35))
            .offset(y: diameter * 0.42)
        // L (Left / roll -) — left
        Text("L")
            .font(DFFont.monoMicro)
            .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o35))
            .offset(x: -diameter * 0.42)
        // R (Right / roll +) — right
        Text("R")
            .font(DFFont.monoMicro)
            .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o35))
            .offset(x: diameter * 0.42)
    }

    // MARK: - Helpers

    private var clampedRoll: Double {
        max(-dangerThreshold, min(dangerThreshold, rollDeg.isFinite ? rollDeg : 0))
    }
    private var clampedPitch: Double {
        max(-dangerThreshold, min(dangerThreshold, pitchDeg.isFinite ? pitchDeg : 0))
    }

    /// 현재 가장 큰 기울기 기반 안전 색.
    private var currentColor: Color {
        let m = max(abs(clampedRoll), abs(clampedPitch))
        if m >= dangerThreshold       { return DFColor.danger }
        if m >= dangerThreshold * 0.93 { return DFColor.severe }   // 28°
        if m >= dangerThreshold * 0.73 { return DFColor.warning }  // 22°
        if m >= dangerThreshold * 0.50 { return DFColor.warning.opacity(0.7) }  // 15°
        return DFColor.success
    }

    private var safetyLabel: String {
        let m = max(abs(clampedRoll), abs(clampedPitch))
        if m >= dangerThreshold        { return "위험 — 자동 정지 임계" }
        if m >= dangerThreshold * 0.93 { return "심각" }
        if m >= dangerThreshold * 0.73 { return "경고" }
        if m >= dangerThreshold * 0.50 { return "주의" }
        return "안전"
    }

    private struct ThresholdRing {
        let deg: Double
        let color: Color
    }

    private var thresholdRings: [ThresholdRing] {
        // v1.8 (2026-05-17): 새 BalanceState 임계와 일치 (25/35/45/50°).
        [
            ThresholdRing(deg: 25.0, color: DFColor.warning),
            ThresholdRing(deg: 35.0, color: DFColor.warning),
            ThresholdRing(deg: 45.0, color: DFColor.severe),
            ThresholdRing(deg: 50.0, color: DFColor.danger),
        ]
    }
}

#if DEBUG
#Preview("Upright") {
    CircularGyroMeter(rollDeg: 0, pitchDeg: 0, sourceLabel: "실 IMU", sourceColor: .green)
        .padding()
        .background(Color.black)
}

#Preview("Tilted") {
    HStack(spacing: 20) {
        CircularGyroMeter(rollDeg: 18, pitchDeg: -5, sourceLabel: "주의")
        CircularGyroMeter(rollDeg: -28, pitchDeg: 24, sourceLabel: "심각")
    }
    .padding()
    .background(Color.black)
}
#endif
