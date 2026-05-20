import SwiftUI
import Charts
import ForgeCore

/// **v1.11.18 (2026-05-19)** — RobotScene3D 위에 떠 있는 두 overlay.
///
/// 사용자 요청: 3D 모델링 뷰포트의 좌측 하단 + 우측 하단에 자이로 + 걸음 그래프
/// overlay 표시. WalkLabView 가 RobotScene3D 의 .overlay 로 사용.
///
/// 좌측 하단 (`SceneGyroMiniOverlay`):
/// - 큰 attitude indicator (artificial horizon style)
/// - Roll/Pitch 숫자 + 소스 chip
/// - 작고 반투명 background — 3D 뷰 가리지 않음.
///
/// 우측 하단 (`SceneWalkGraphOverlay`):
/// - 보행 phase 표시 (PHASE0~5)
/// - 보폭/주기 sparkline (최근 10초)
/// - 발자국 카운트
/// - foot trace 길이

/// **v1.11.18**: 좌측 하단 attitude indicator overlay.
public struct SceneGyroMiniOverlay: View {
    @EnvironmentObject private var session: WalkLabSession
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dfTheme) private var theme: DFTheme

    public init() {}

    public var body: some View {
        // v1.11.23 (2026-05-21, Codex MED fix): tick 0.1s 유지 — WalkLab tick (50ms=20Hz)
        // 와 IMU polling 정합. 0.2s 로 늘리면 4 sample/redraw 로 attitude indicator
        // 부드러움 저하. 시각 hero 인 attitude indicator 는 데이터 갱신 따라 10Hz 유지.
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                attitudeIndicator
                HStack(spacing: DFSpace.xs) {
                    label("R", session.displayImuRollDeg, danger: 50)
                    label("P", session.displayImuPitchDeg, danger: 50)
                    Spacer(minLength: 0)
                    sourceChip
                }
                if let imu = store.lastImuRaw {
                    HStack(spacing: 6) {
                        Text("ω")
                            .font(DFFont.micro)
                            .foregroundStyle(DFColor.textSecondary)
                        Text(String(format: "%d°/s", Int(abs(imu.gyroXDps) + abs(imu.gyroYDps))))
                            .font(DFFont.micro.monospacedDigit())
                            .foregroundStyle(DFColor.textPrimary)
                    }
                }
            }
            .padding(DFSpace.xs2)
            .frame(width: 120)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(sourceColor.opacity(DFOpacity.o30),
                            lineWidth: DFSize.borderHairline)
            )
            .accessibilityLabel("IMU 자세 인디케이터 — roll \(Int(session.displayImuRollDeg))도, pitch \(Int(session.displayImuPitchDeg))도")
        }
    }

    /// Artificial horizon style — roll 로 회전, pitch 로 horizon line 위/아래.
    private var attitudeIndicator: some View {
        ZStack {
            // 배경 — 하늘 (위) / 땅 (아래).
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.4, green: 0.6, blue: 0.85),
                             Color(red: 0.55, green: 0.4, blue: 0.25)],
                    startPoint: .top, endPoint: .bottom
                )
                // pitch indicator line (horizon offset).
                let pitchOffset = CGFloat(session.displayImuPitchDeg / 90.0) * 30
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(height: 1)
                    .offset(y: pitchOffset)
            }
            .rotationEffect(.degrees(session.displayImuRollDeg), anchor: .center)
            .frame(width: 60, height: 60)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
            // 중앙 십자 fixed reference (회전 X).
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .shadow(radius: 1)
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity)
    }

    /// BalanceState 5-tier (25/35/45/50°) 정합 — 다른 컴포넌트와 색 일관성.
    private func label(_ axis: String, _ value: Double, danger: Double) -> some View {
        let absV = abs(value)
        let color: Color = {
            if absV >= danger        { return DFColor.danger }                    // 50°
            if absV >= danger * 0.90 { return DFColor.severe }                    // 45°
            if absV >= danger * 0.70 { return DFColor.warning }                   // 35°
            if absV >= danger * 0.50 { return DFColor.warning.opacity(0.7) }      // 25°
            return DFColor.textPrimary
        }()
        return HStack(spacing: 2) {
            Text(axis)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
            Text(String(format: "%+.0f°", value))
                .font(DFFont.micro.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var sourceChip: some View {
        Text(sourceLabel)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(sourceColor.opacity(DFOpacity.ghost))
            .clipShape(Capsule())
    }

    private var sourceColor: Color {
        switch session.imuSource {
        case .real:  return DFColor.success
        case .sim:   return DFColor.textSecondary
        case .stale: return DFColor.danger
        }
    }

    private var sourceLabel: String {
        switch session.imuSource {
        case .real:  return "R"
        case .sim:   return "S"
        case .stale: return "X"
        }
    }
}

/// **v1.11.18**: 우측 하단 walking 그래프 overlay.
public struct SceneWalkGraphOverlay: View {
    @EnvironmentObject private var session: WalkLabSession
    @Environment(\.dfTheme) private var theme: DFTheme

    /// 10초 sparkline 용 sample buffer.
    @State private var phaseHistory: [(Date, Double)] = []
    @State private var rollHistory: [(Date, Double)] = []

    public init() {}

    public var body: some View {
        // v1.11.23 (Codex MED fix): tick 0.1s 유지. WalkLab 50ms tick 의 4 sample/redraw
        // 대신 2 sample/redraw 으로 sparkline 부드러움 보존.
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                headerRow
                if !phaseHistory.isEmpty {
                    sparkline
                }
                statsRow
            }
            .padding(DFSpace.xs2)
            .frame(width: 180)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(DFColor.accent.opacity(DFOpacity.o30),
                            lineWidth: DFSize.borderHairline)
            )
            .accessibilityLabel("보행 그래프 — phase \(session.phaseLabel)")
            .onChange(of: context.date) { _, now in
                appendSample(at: now)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "figure.walk")
                .foregroundStyle(walking ? DFColor.success : DFColor.textSecondary)
                .font(.system(size: 12))
            Text(session.phaseLabel)
                .font(DFFont.monoLabel)
                .foregroundStyle(DFColor.textPrimary)
            Spacer()
            // elapsed time.
            Text(formatElapsed(ms: Int(session.elapsedMs)))
                .font(DFFont.micro.monospacedDigit())
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    private var sparkline: some View {
        // Roll 진동 + walking phase line 합성.
        Chart {
            ForEach(Array(rollHistory.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("t", sample.0),
                    y: .value("roll", sample.1)
                )
                .foregroundStyle(DFColor.accent)
                .interpolationMethod(.catmullRom)
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.subtle))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        }
        .chartYScale(domain: -20...20)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 32)
    }

    private var statsRow: some View {
        HStack(spacing: DFSpace.xs) {
            statCell("보폭", String(format: "%.0f mm", session.strideMm))
            statCell("주기", String(format: "%.0f ms", session.customPeriodMs))
            Spacer()
            // 발 trace 길이.
            statCell("trace", "\(session.footTrail.count)")
        }
        .font(DFFont.micro)
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .foregroundStyle(DFColor.textSecondary)
                .font(.system(size: 8))
            Text(value)
                .foregroundStyle(DFColor.textPrimary)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
    }

    private var walking: Bool {
        session.current != .idle
    }

    private func formatElapsed(ms: Int) -> String {
        let totalSec = ms / 1000
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    /// 0.1s tick 마다 phase + roll 누적. 10초 cutoff.
    private func appendSample(at now: Date) {
        // session.elapsedMs 를 phase 추세로 사용 (0~1 normalized).
        let phaseFraction = Double(Int(session.elapsedMs) % Int(session.customPeriodMs)) / session.customPeriodMs
        phaseHistory.append((now, phaseFraction))
        rollHistory.append((now, session.displayImuRollDeg))
        let cutoff = now.addingTimeInterval(-10.0)
        phaseHistory.removeAll { $0.0 < cutoff }
        rollHistory.removeAll { $0.0 < cutoff }
    }
}
