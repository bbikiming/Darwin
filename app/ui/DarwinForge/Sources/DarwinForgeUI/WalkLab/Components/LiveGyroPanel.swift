import SwiftUI
import Charts
// `import Accessibility` 는 file-scoped — 같은 file 의 `GyroSparklineChart` struct (line 311~) 가
// `AXChartDescriptor` / `AXNumericDataAxisDescriptor` / `AXDataPoint` / `AXDataSeriesDescriptor` /
// `AXChartDescriptorRepresentable` 사용. 부모 `LiveGyroPanel` struct 는 SwiftUI 의
// `.accessibilityLabel` / `.accessibilityElement` 만 사용 (SwiftUI 내장 — Accessibility import 불필요).
//
// **V275-3 critic 5차 MINOR-4 검토**: import 를 struct 단위로 분리 권고 받았으나 Swift import 는
// file 단위 — 두 struct (`LiveGyroPanel`, `GyroSparklineChart`) 가 같은 file 에 있는 한 file 최상단에
// 둘 수밖에 없다. 별도 file 분리는 chart 가 부모 view 의 `@State rollHistory` 를 init 으로 받는
// 단순 prop drilling 관계라 분리 비용 대비 이득 미미 → 현 구조 유지.
import Accessibility
import ForgeCore

/// **V272-1 (2026-05-24) WCAG 1.4.1 fix — Gyro 자세/각속도 severity dual encoding**.
///
/// Color-only 인디케이터 (`angleColor` 의 25/35/45/50° tier + gyroAxisCell 의
/// 50dps 단일 임계) 가 WCAG 1.4.1 위반. systemImage 아이콘 + 색상 dual encoding
/// 으로 color-blind 사용자도 tier 전환 인식 가능.
///
/// **Domain 분리**: SceneViewportOverlays 의 `SceneSeverity` 와 동일 임계지만
/// 도메인별 helper 로 분리 (LiveGyroPanel 은 5-tier attitude + 2-tier gyro 두 종류).
enum GyroSeverity {
    /// 자세 (roll/pitch) 5-tier 아이콘 — 25/35/45/50° (danger 비례).
    static func attitudeIcon(deg value: Double, danger: Double = 50) -> String {
        let absV = abs(value)
        if absV >= danger        { return "octagon.fill" }                  // critical
        if absV >= danger * 0.90 { return "exclamationmark.triangle.fill" } // severe
        if absV >= danger * 0.70 { return "exclamationmark.circle.fill" }   // warning
        if absV >= danger * 0.50 { return "circle.fill" }                   // caution
        return "circle"                                                     // normal
    }

    /// 각속도 (gyro) 2-tier 아이콘 — 단일 임계 (기본 50dps).
    static func gyroIcon(dps value: Double, danger: Double = 50) -> String {
        abs(value) > danger ? "exclamationmark.triangle.fill" : "circle"
    }
}

/// **v1.11.17 (2026-05-19)** — 워크랩 진입 즉시 IMU 자세/IMU 패널.
///
/// 보행 시작 전부터 표시 — `session.attach(store:)` 호출 후 polling tick 이 시작
/// 되어 imuRollDeg/imuPitchDeg 가 즉시 갱신. 사용자가 robot 거치 상태에서 IMU
/// 동작 확인 가능 (cradle / tether 의 자세 점검).
///
/// 표시 항목:
/// - Roll / Pitch 각도 (큰 텍스트 + 작은 horizon bar)
/// - gyro 각속도 X / Y / Z (dps) — `store.lastImuRaw` 에서 직접 read
/// - 최근 5초 sparkline (roll + pitch 추세)
/// - 데이터 소스 chip (sim / real / stale) — color-coded
/// - 펼침/접힘 토글 (compact 기본)
///
/// 위치: WalkLabView 의 detail 영역 상단 — preset 선택 전에도 항상 보임.
public struct LiveGyroPanel: View {
    @Environment(WalkLabSession.self) private var session
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dfTheme) private var theme: DFTheme

    @AppStorage("df.walklab.gyroPanelExpanded") private var expanded: Bool = false

    /// 최근 5초 sparkline 용 sample buffer (Mac local — published trigger 별도).
    @State private var rollHistory: [(Date, Double)] = []
    @State private var pitchHistory: [(Date, Double)] = []

    public init() {}

    public var body: some View {
        // **v1.14.8 (2026-05-21) perf #3**: TimelineView(.periodic, by: 0.2) 제거.
        // 종전: 5Hz 독립 redraw → 전체 view tree (header, angle, gyro, sparkline)
        //       재평가가 IMU 값 변화와 무관하게 발화.
        // 신규: session.imuRollDeg/imuPitchDeg 가 @Published 라 IMU update 발생 시
        //       body 자동 재평가 + appendSample 도 onChange 로 trigger. IMU 값이
        //       바뀔 때만 sparkline 에 sample 추가 — 정체 구간엔 chart 갱신 X.
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            headerRow
            if expanded {
                Divider()
                angleRow
                if let imu = store.lastImuRaw {
                    Divider()
                    gyroRow(imu: imu)
                }
                Divider()
                sparklineChart
            } else {
                compactRow
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.adaptiveCard(theme))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(sourceColor.opacity(DFOpacity.o30),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("IMU 자세: roll \(Int(session.displayImuRollDeg))도, pitch \(Int(session.displayImuPitchDeg))도")
        // **v1.14.8.1 (2026-05-21) — code-reviewer HIGH fix**: 단일 onChange.
        // 종전: roll + pitch 각각 onChange → IMU tick 마다 보통 두 값 모두 변경 →
        //       appendSample 2회 호출 → 동일 timestamp 쌍 2개 (sparkline 점 밀도 2배 + memory 2배).
        // 신규: roll 만 trigger. 실 IMU 노이즈 (수치 precision) 로 매 update 마다 roll 변경 ⇒
        //       sparkline 정상 갱신. pitch-only 변화는 매우 드물고 다음 roll 변화 시 catch.
        .onChange(of: session.imuRollDeg) { _, _ in
            appendSample(at: Date())
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "gyroscope")
                .foregroundStyle(sourceColor)
            Text("IMU 자세")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textPrimary)
            sourceChip
            Spacer()
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expanded ? "패널 접기" : "패널 펼치기")
        }
    }

    private var sourceChip: some View {
        Text(sourceLabel)
            .font(DFFont.micro)
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(sourceColor.opacity(DFOpacity.ghost))
            .clipShape(Capsule())
    }

    // MARK: - Compact row (접힘 상태)

    private var compactRow: some View {
        HStack(spacing: DFSpace.sm) {
            compactAngleCell(label: "R", value: session.displayImuRollDeg)
            compactAngleCell(label: "P", value: session.displayImuPitchDeg)
            Spacer()
            if let imu = store.lastImuRaw {
                Text("ω \(Int(abs(imu.gyroXDps) + abs(imu.gyroYDps)))°/s")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    private func compactAngleCell(label: String, value: Double) -> some View {
        // **V272-1 WCAG 1.4.1 fix**: 색상-only → 아이콘 + 색상 dual encoding.
        HStack(spacing: 2) {
            Image(systemName: GyroSeverity.attitudeIcon(deg: value, danger: 50))
                .font(DFIcon.micro)
                .foregroundStyle(angleColor(value))
            Text(label)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
            Text(String(format: "%+.1f°", value))
                .font(DFFont.monoLabel)
                .foregroundStyle(angleColor(value))
        }
    }

    // MARK: - Expanded: angle row

    private var angleRow: some View {
        HStack(spacing: DFSpace.md) {
            angleCell(label: "Roll", value: session.displayImuRollDeg, dangerThreshold: 50)
            angleCell(label: "Pitch", value: session.displayImuPitchDeg, dangerThreshold: 50)
        }
    }

    private func angleCell(label: String, value: Double, dangerThreshold: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // **V272-1 WCAG 1.4.1 fix**: 색상-only → label 옆 severity 아이콘 추가.
            HStack(spacing: 4) {
                Image(systemName: GyroSeverity.attitudeIcon(deg: value, danger: dangerThreshold))
                    .font(DFIcon.label)
                    .foregroundStyle(angleColor(value, danger: dangerThreshold))
                Text(label)
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Text(String(format: "%+.1f°", value))
                .font(DFFont.sectionLarge.monospacedDigit())
                .foregroundStyle(angleColor(value, danger: dangerThreshold))
            // Horizon-style bar — 중앙 0, +/- 의 작은 indicator.
            GeometryReader { geo in
                let w = geo.size.width
                let normalized = max(-1.0, min(1.0, value / dangerThreshold))
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(DFOpacity.subtle))
                        .frame(height: 4)
                    Rectangle()
                        .fill(angleColor(value, danger: dangerThreshold))
                        .frame(width: 3, height: 12)
                        .offset(x: (w / 2) + (CGFloat(normalized) * w / 2) - 1.5,
                                y: -4)
                }
            }
            .frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Gyro X/Y/Z

    private func gyroRow(imu: ImuRaw) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("각속도 (°/s)")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: DFSpace.sm2) {
                gyroAxisCell("X", value: imu.gyroXDps)
                gyroAxisCell("Y", value: imu.gyroYDps)
                gyroAxisCell("Z", value: imu.gyroZDps)
            }
        }
    }

    private func gyroAxisCell(_ axis: String, value: Double) -> some View {
        // **V272-1 WCAG 1.4.1 fix**: 색상-only (> 50dps 노란색) → 아이콘 + 색상.
        let exceeds = abs(value) > 50
        let color: Color = exceeds ? DFColor.warning : DFColor.textPrimary
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: GyroSeverity.gyroIcon(dps: value, danger: 50))
                    .font(DFIcon.micro)
                    .foregroundStyle(color)
                Text(axis)
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Text(String(format: "%+.0f", value))
                .font(DFFont.monoLabel)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sparkline (5초)

    private var sparklineChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DFSpace.xs2) {
                Text("최근 5초")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Circle().fill(DFColor.accent).frame(width: 5, height: 5)
                Text("Roll").font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
                Circle().fill(DFColor.forge).frame(width: 5, height: 5)
                Text("Pitch").font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            }
            GyroSparklineChart(
                rollHistory: rollHistory,
                pitchHistory: pitchHistory
            )
        }
    }

    // MARK: - Source / color

    private var sourceColor: Color {
        switch session.imuSource {
        case .real:  return DFColor.success
        case .sim:   return DFColor.textSecondary
        case .stale: return DFColor.danger
        }
    }

    private var sourceLabel: String {
        switch session.imuSource {
        case .real:  return "REAL"
        case .sim:   return "SIM"
        case .stale: return "STALE"
        }
    }

    /// BalanceState 5-tier (25/35/45/50°) 정합.
    private func angleColor(_ value: Double, danger: Double = 50) -> Color {
        let abs = abs(value)
        if abs >= danger        { return DFColor.danger }                    // 50°
        if abs >= danger * 0.90 { return DFColor.severe }                    // 45°
        if abs >= danger * 0.70 { return DFColor.warning }                   // 35°
        if abs >= danger * 0.50 { return DFColor.warning.opacity(0.7) }      // 25°
        return DFColor.textPrimary
    }

    // MARK: - Sparkline buffer

    /// 0.2s 마다 호출 — 5초 = 25 sample window.
    private func appendSample(at now: Date) {
        rollHistory.append((now, session.displayImuRollDeg))
        pitchHistory.append((now, session.displayImuPitchDeg))
        let cutoff = now.addingTimeInterval(-5.0)
        rollHistory.removeAll { $0.0 < cutoff }
        pitchHistory.removeAll { $0.0 < cutoff }
    }
}

// MARK: - Gyro sparkline chart (V274-4 a11y)
//
// **V274-4 (2026-05-24) WCAG 1.1.1 + 1.3.1 fix — chart 구조 VoiceOver 노출**.
// SwiftUI Charts framework 의 Chart 만으로는 VoiceOver 가 "chart" 만 announce 하고
// 데이터 구조 (axis / series / data point) 를 navigate 불가. AXChartDescriptor 로
// title / summary / x/y axis / series 를 노출해 VoiceOver 사용자가 데이터 탐색 가능.
//
// 추출 이유: AXChartDescriptorRepresentable 은 struct 단위 conformance — body 안의
// inline Chart 에는 적용 불가. 작은 dedicated struct 로 분리.
struct GyroSparklineChart: View {
    let rollHistory: [(Date, Double)]
    let pitchHistory: [(Date, Double)]

    var body: some View {
        Chart {
            ForEach(Array(rollHistory.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("t", sample.0),
                    y: .value("roll", sample.1),
                    series: .value("axis", "Roll")
                )
                .foregroundStyle(DFColor.accent)
            }
            ForEach(Array(pitchHistory.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("t", sample.0),
                    y: .value("pitch", sample.1),
                    series: .value("axis", "Pitch")
                )
                .foregroundStyle(DFColor.forge)
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.subtle))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        }
        .chartYScale(domain: -45...45)
        .chartYAxis {
            AxisMarks(values: [-30, 0, 30]) { _ in
                AxisGridLine().foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.subtle))
                AxisValueLabel().font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            }
        }
        .chartXAxis(.hidden)
        .frame(height: 60)
        .accessibilityChartDescriptor(self)
    }
}

extension GyroSparklineChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        // Axis 0 = 시간 (초 단위, 0 = now, 음수 = 과거).
        // pinned reference = 가장 오래된 sample (보통 -5.0s) ~ 0.
        let rollPts = WalkLabChartA11y.timeOffsetPoints(rollHistory)
        let pitchPts = WalkLabChartA11y.timeOffsetPoints(pitchHistory)
        // **V275-3 build-fix (2026-05-24)** — `\.x` keypath 가 tuple labeled element
        // 추론 실패 → closure form 으로 root 명시. 동시에 `gridlinePositions` 의
        // `(xMin + xMax) / 2` 가 Int 로 추론되던 cascade 도 `2.0` literal 로 해결.
        let allOffsets: [Double] = rollPts.map { $0.x } + pitchPts.map { $0.x }
        let xMin: Double = allOffsets.min() ?? -5.0
        let xMax: Double = allOffsets.max() ?? 0.0
        let xMid: Double = (xMin + xMax) / 2.0
        let xAxis = AXNumericDataAxisDescriptor(
            title: "시간 (초)",
            range: xMin...xMax,
            gridlinePositions: [xMin, xMid, xMax]
        ) { value in
            String(format: "%.1f초 전", -value)
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "각도 (도)",
            range: -45.0...45.0,
            gridlinePositions: [-30, 0, 30]
        ) { value in
            "\(Int(value))도"
        }
        let rollSeries = AXDataSeriesDescriptor(
            name: "Roll (좌우 기울기)",
            isContinuous: true,
            dataPoints: rollPts.map { AXDataPoint(x: $0.x, y: $0.y) }
        )
        let pitchSeries = AXDataSeriesDescriptor(
            name: "Pitch (앞뒤 기울기)",
            isContinuous: true,
            dataPoints: pitchPts.map { AXDataPoint(x: $0.x, y: $0.y) }
        )
        let summary = WalkLabChartA11y.gyroSparklineSummary(
            rollHistory: rollHistory,
            pitchHistory: pitchHistory
        )
        return AXChartDescriptor(
            title: "IMU 자세 sparkline (최근 5초)",
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [rollSeries, pitchSeries]
        )
    }
}
