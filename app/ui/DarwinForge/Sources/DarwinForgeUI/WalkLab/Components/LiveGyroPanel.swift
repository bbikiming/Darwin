import SwiftUI
import Charts
import ForgeCore

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
            angleCell(label: "Roll", value: session.displayImuRollDeg, dangerThreshold: 50)
            angleCell(label: "Pitch", value: session.displayImuPitchDeg, dangerThreshold: 50)
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
