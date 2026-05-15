import ForgeCore
import SwiftUI

/// IMU raw 값 진단 + scale 검증 시트 — Sprint 18 Phase E (Codex 잔여 2).
///
/// **목적**:
///   - raw i16 register 값과 변환된 °/s / g 값을 함께 표시 — 사용자가 ROBOTIS legacy 와 비교 가능.
///   - **정지 자세 calibration**: 로봇을 평평한 곳에 정지 시 5초간 측정 → gyro bias + accel scale 진단.
///   - 결과로 "scale OK" 또는 "scale 의심" 을 사용자에게 솔직 보고.
///
/// **Codex 가 지적한 scale 불확실성**:
///   - 우리 변환: raw × 2000.0 / 32767 dps (MPU-6050 ±2000dps 가정)
///   - ROBOTIS legacy 가 raw word (~512 center) 인지 i16 인지 미검증
///   - 검증 방법: 정지 시 accel Z ≈ 1.0g (raw 16384) 가 되는지
public struct PilotImuRawDiagnosticsSheet: View {
    @ObservedObject var store: ConnectionStore
    let onClose: () -> Void

    @State private var calibration: CalibrationResult?
    @State private var calibrationInProgress: Bool = false

    public init(store: ConnectionStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    healthBlock
                    rawValuesBlock
                    Divider()
                    calibrationBlock
                    if let cal = calibration {
                        calibrationResultBlock(cal)
                    }
                    Divider()
                    scaleAnalysisBlock
                }
                .padding(.bottom, DFSpace.md)
            }
            Divider()
            HStack {
                Spacer()
                DFButton(.primary, size: .medium) { onClose() } label: { Text("닫기") }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DFSpace.lg)
        .frame(width: 620, height: 720)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "gyroscope")
                .font(.system(size: DFFontSize.s22))
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("IMU 진단 + scale 검증")
                    .font(DFFont.title)
                Text("정지 자세로 5초 측정해서 변환식이 정확한지 확인")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    // MARK: - Health

    private var healthBlock: some View {
        HStack(spacing: DFSpace.md) {
            healthCell(label: "상태",
                       value: store.isImuUnavailable ? "사용 불가" :
                              (store.isImuStale ? "오래됨" : "정상"),
                       color: store.isImuUnavailable ? DFColor.danger :
                              (store.isImuStale ? DFColor.warning : DFColor.success))
            healthCell(label: "연속 실패",
                       value: "\(store.imuConsecutiveFailures)",
                       color: store.imuConsecutiveFailures > 0 ? DFColor.warning : DFColor.textSecondary)
            healthCell(label: "마지막 통신",
                       value: lastImuText,
                       color: DFColor.info)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var rawValuesBlock: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            Text("IMU 12 byte raw + 변환")
                .font(DFFont.bodyEmph)
            if let imu = store.lastTelemetry?.imu {
                Grid(alignment: .leading, horizontalSpacing: DFSpace.md, verticalSpacing: DFSpace.xs) {
                    GridRow {
                        Text("축").bold()
                        Text("raw (i16)").bold()
                        Text("변환").bold()
                    }
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    Divider()

                    rawRow("Gyro X", raw: imu.gyroX, converted: String(format: "%+.1f °/s", imu.gyroXDps))
                    rawRow("Gyro Y", raw: imu.gyroY, converted: String(format: "%+.1f °/s", imu.gyroYDps))
                    rawRow("Gyro Z", raw: imu.gyroZ, converted: String(format: "%+.1f °/s", imu.gyroZDps))
                    rawRow("Accel X", raw: imu.accelX, converted: String(format: "%+.3f g", Double(imu.accelX) * 2.0 / 32767.0))
                    rawRow("Accel Y", raw: imu.accelY, converted: String(format: "%+.3f g", Double(imu.accelY) * 2.0 / 32767.0))
                    rawRow("Accel Z", raw: imu.accelZ, converted: String(format: "%+.3f g", Double(imu.accelZ) * 2.0 / 32767.0))
                    Divider()
                    GridRow {
                        Text("Roll (accel)").italic().foregroundStyle(DFColor.textSecondary)
                        Text("—").foregroundStyle(DFColor.textSecondary)
                        Text(String(format: "%+.1f °", imu.rollDeg))
                            .font(DFFont.bodyEmph.monospaced())
                            .foregroundStyle(DFColor.accent)
                    }
                    GridRow {
                        Text("Pitch (accel)").italic().foregroundStyle(DFColor.textSecondary)
                        Text("—").foregroundStyle(DFColor.textSecondary)
                        Text(String(format: "%+.1f °", imu.pitchDeg))
                            .font(DFFont.bodyEmph.monospaced())
                            .foregroundStyle(DFColor.accent)
                    }
                }
            } else {
                Text("IMU 데이터 없음 — bus 연결 + IMU register 응답 필요")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.warning)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func rawRow(_ axis: String, raw: Int16, converted: String) -> some View {
        GridRow {
            Text(axis).font(DFFont.bodyEmph)
            Text("\(raw)").font(DFFont.bodyEmph.monospaced()).foregroundStyle(DFColor.textSecondary)
            Text(converted).font(DFFont.bodyEmph.monospaced()).foregroundStyle(DFColor.accent)
        }
    }

    // MARK: - Calibration

    private var calibrationBlock: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("정지 자세 calibration").font(DFFont.bodyEmph)
            Text("로봇을 평평한 곳에 똑바로 세우고 누르세요. 5초간 측정 → bias / scale 진단.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            HStack {
                DFButton(.primary, size: .medium) {
                    Task { await runCalibration() }
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        if calibrationInProgress {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "timer")
                        }
                        Text(calibrationInProgress ? "측정 중…" : "정지 측정 시작 (5초)")
                    }
                }
                .disabled(calibrationInProgress || store.lastTelemetry?.imu == nil)
                Spacer()
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.accent.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func calibrationResultBlock(_ cal: CalibrationResult) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: cal.scaleVerdict.icon)
                    .foregroundStyle(cal.scaleVerdict.color)
                Text("측정 결과 (\(cal.sampleCount) sample 평균)")
                    .font(DFFont.bodyEmph)
            }
            Grid(alignment: .leading, horizontalSpacing: DFSpace.md, verticalSpacing: DFSpace.xs) {
                GridRow {
                    Text("Gyro X bias")
                    Text(String(format: "%+.2f °/s", cal.gyroBiasDps.0))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(abs(cal.gyroBiasDps.0) > 1 ? DFColor.warning : DFColor.success)
                }
                GridRow {
                    Text("Gyro Y bias")
                    Text(String(format: "%+.2f °/s", cal.gyroBiasDps.1))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(abs(cal.gyroBiasDps.1) > 1 ? DFColor.warning : DFColor.success)
                }
                GridRow {
                    Text("Gyro Z bias")
                    Text(String(format: "%+.2f °/s", cal.gyroBiasDps.2))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(abs(cal.gyroBiasDps.2) > 1 ? DFColor.warning : DFColor.success)
                }
                Divider()
                GridRow {
                    Text("Accel Z (g)")
                    Text(String(format: "%.3f g", cal.accelZG))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(cal.accelZGScaleColor)
                }
                GridRow {
                    Text("정지 tilt")
                    Text(String(format: "R%+.1f° P%+.1f°", cal.rollDeg, cal.pitchDeg))
                        .font(.system(.body, design: .monospaced))
                }
            }
            Divider()
            Text(cal.scaleVerdict.message)
                .font(DFFont.caption)
                .foregroundStyle(cal.scaleVerdict.color)
            if let advice = cal.advice {
                Text(advice)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.sm)
        .background(cal.scaleVerdict.color.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Scale analysis (정직성)

    private var scaleAnalysisBlock: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(DFColor.textSecondary)
                Text("scale 분석 (Codex 권고)")
                    .font(DFFont.bodyEmph)
            }
            Text("""
                현재 Mac 측 변환: gyro_raw × 2000.0 / 32767 = °/s, accel_raw × 2.0 / 32767 = g.
                MPU-6050 의 ±2000dps / ±2g full scale 가정.

                ROBOTIS legacy (LinuxCM730 + MotionStatus) 는 raw word (~512 center) 로 사용 — 우리와 다를 가능성.

                정지 측정 결과 accel Z 가 ~1.0g (raw ~16384) 이면 우리 변환 OK.
                accel Z 가 비정상이면 ROBOTIS legacy 방식 (10-bit ADC) 일 가능성 — Rust cm.rs 변환 정정 필요.
                """)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .padding(DFSpace.xs2)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        }
        .padding(DFSpace.sm)
        .background(DFColor.warning.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Helpers

    private func healthCell(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            Text(value).font(DFFont.bodyEmph.monospaced()).foregroundStyle(color)
        }
    }

    private var lastImuText: String {
        guard let at = store.lastImuSuccessAt else { return "—" }
        let elapsed = Date().timeIntervalSince(at)
        if elapsed < 2 { return "방금" }
        if elapsed < 60 { return String(format: "%.0f초", elapsed) }
        return String(format: "%.0f분", elapsed / 60)
    }

    // MARK: - Calibration runner

    /// 5초간 1Hz polling × 5 sample 평균 (실제 telemetry tick 에서 들어옴).
    @MainActor
    private func runCalibration() async {
        calibrationInProgress = true
        defer { calibrationInProgress = false }

        var samples: [ImuRaw] = []
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let cur = store.lastTelemetry?.imu, !samples.contains(where: { $0 == cur }) {
                samples.append(cur)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        guard !samples.isEmpty else {
            calibration = CalibrationResult.failure(reason: "IMU 데이터 못 받음")
            return
        }

        let n = Double(samples.count)
        let gx = samples.reduce(0.0) { $0 + $1.gyroXDps } / n
        let gy = samples.reduce(0.0) { $0 + $1.gyroYDps } / n
        let gz = samples.reduce(0.0) { $0 + $1.gyroZDps } / n
        let azG = samples.reduce(0.0) { $0 + Double($1.accelZ) * 2.0 / 32767.0 } / n
        let avgRoll = samples.reduce(0.0) { $0 + $1.rollDeg } / n
        let avgPitch = samples.reduce(0.0) { $0 + $1.pitchDeg } / n

        let verdict: ScaleVerdict
        let advice: String?
        let absDelta = abs(azG - 1.0)
        if absDelta < 0.15 {
            verdict = .ok
            advice = "Accel Z 가 ~1.0g 에 일치 — scale 변환 OK."
        } else if absDelta < 0.5 {
            verdict = .suspicious
            advice = "Accel Z 가 1.0g 와 \(String(format: "%.2f", absDelta))g 차이. 가능: (1) 로봇이 완전 수평 아님 (2) scale 약간 다름. 평평한 곳 재측정 권장."
        } else {
            verdict = .wrong
            advice = "Accel Z = \(String(format: "%.2fg", azG)). 1.0g 와 큰 차이 — Codex 가 지적한 ROBOTIS legacy raw word 방식일 가능성. Rust cm.rs 의 변환식 정정 필요 (gyro × 2000/32767 → raw 그대로 또는 ÷ 512)."
        }

        calibration = CalibrationResult(
            sampleCount: samples.count,
            gyroBiasDps: (gx, gy, gz),
            accelZG: azG,
            rollDeg: avgRoll,
            pitchDeg: avgPitch,
            scaleVerdict: verdict,
            advice: advice
        )
    }
}

/// 정지 측정 결과.
public struct CalibrationResult: Equatable, Sendable {
    public let sampleCount: Int
    public let gyroBiasDps: (Double, Double, Double)
    public let accelZG: Double
    public let rollDeg: Double
    public let pitchDeg: Double
    public let scaleVerdict: ScaleVerdict
    public let advice: String?

    static func failure(reason: String) -> CalibrationResult {
        CalibrationResult(
            sampleCount: 0,
            gyroBiasDps: (0, 0, 0),
            accelZG: 0,
            rollDeg: 0,
            pitchDeg: 0,
            scaleVerdict: .failure,
            advice: reason
        )
    }

    public var accelZGScaleColor: Color {
        switch scaleVerdict {
        case .ok:         return DFColor.success
        case .suspicious: return DFColor.warning
        case .wrong, .failure: return DFColor.danger
        }
    }

    public static func == (lhs: CalibrationResult, rhs: CalibrationResult) -> Bool {
        lhs.sampleCount == rhs.sampleCount &&
        lhs.accelZG == rhs.accelZG &&
        lhs.rollDeg == rhs.rollDeg &&
        lhs.pitchDeg == rhs.pitchDeg &&
        lhs.scaleVerdict == rhs.scaleVerdict
    }
}

public enum ScaleVerdict: String, Sendable {
    case ok, suspicious, wrong, failure

    public var icon: String {
        switch self {
        case .ok:         return "checkmark.seal.fill"
        case .suspicious: return "questionmark.diamond.fill"
        case .wrong:      return "xmark.octagon.fill"
        case .failure:    return "exclamationmark.triangle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .ok:         return DFColor.success
        case .suspicious: return DFColor.warning
        case .wrong:      return DFColor.danger
        case .failure:    return DFColor.danger
        }
    }

    public var message: String {
        switch self {
        case .ok:         return "✅ Scale OK — 변환식 적정. 사용 가능."
        case .suspicious: return "⚠️ Scale 약간 의심 — 평평한 곳 재측정 권장."
        case .wrong:      return "❌ Scale 잘못 — Rust 변환식 정정 필요."
        case .failure:    return "❌ 측정 실패 — IMU 데이터 못 받음."
        }
    }
}
