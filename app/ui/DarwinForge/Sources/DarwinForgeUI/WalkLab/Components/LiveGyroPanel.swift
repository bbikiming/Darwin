import SwiftUI
import Charts
import ForgeCore

/// **v1.11.17 (2026-05-19)** — 워크랩 진입 즉시 실시간 자이로/IMU 패널.
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
    @EnvironmentObject private var session: WalkLabSession
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dfTheme) private var theme: DFTheme

    @AppStorage("df.walklab.gyroPanelExpanded") private var expanded: Bool = false

    /// 최근 5초 sparkline 용 sample buffer (Mac local — published trigger 별도).
    @State private var rollHistory: [(Date, Double)] = []
    @State private var pitchHistory: [(Date, Double)] = []

    public init() {}

    public var body: some View {
        // 1Hz timeline 으로 sparkline 갱신 + stale 판정 timer.
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
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
            .accessibilityLabel("실시간 자이로: roll \(Int(session.imuRollDeg))도, pitch \(Int(session.imuPitchDeg))도")
            .onChange(of: context.date) { _, now in
                appendSample(at: now)
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "gyroscope")
                .foregroundStyle(sourceColor)
            Text("실시간 자이로")
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
            compactAngleCell(label: "R", value: session.imuRollDeg)
            compactAngleCell(label: "P", value: session.imuPitchDeg)
            Spacer()
            if let imu = store.lastImuRaw {
                Text("ω \(Int(abs(imu.gyroXDps) + abs(imu.gyroYDps)))°/s")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    private func compactAngleCell(label: String, value: Double) -> some View {
        HStack(spacing: 2) {
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
            angleCell(label: "Roll", value: session.imuRollDeg, dangerThreshold: 30)
            angleCell(label: "Pitch", value: session.imuPitchDeg, dangerThreshold: 30)
        }
    }

    private func angleCell(label: String, value: Double, dangerThreshold: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(axis)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
            Text(String(format: "%+.0f", value))
                .font(DFFont.monoLabel)
                .foregroundStyle(abs(value) > 50 ? DFColor.warning : DFColor.textPrimary)
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

    private func angleColor(_ value: Double, danger: Double = 30) -> Color {
        let abs = abs(value)
        if abs >= danger { return DFColor.danger }
        if abs >= danger * 0.66 { return DFColor.warning }
        return DFColor.textPrimary
    }

    // MARK: - Sparkline buffer

    /// 0.2s 마다 호출 — 5초 = 25 sample window.
    private func appendSample(at now: Date) {
        rollHistory.append((now, session.imuRollDeg))
        pitchHistory.append((now, session.imuPitchDeg))
        let cutoff = now.addingTimeInterval(-5.0)
        rollHistory.removeAll { $0.0 < cutoff }
        pitchHistory.removeAll { $0.0 < cutoff }
    }
}
