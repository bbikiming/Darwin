import SwiftUI

/// **v1.11.4 (2026-05-18)** — 정적 IMU 캘리브레이션 패널 UI.
///
/// 사용자가 robot 을 손으로 다섯 자세 (직립 / 앞·뒤·오·왼 30°) 에 두고 각 5초 IMU
/// 평균을 캡처 → 부호 컨벤션 진단 결과 표시.
///
/// **사용 시나리오**:
/// 1. 사용자가 robot 거치대 위에 직립 자세로 둠 → "직립 (0°)" 버튼 클릭 → 5초 캡처
/// 2. 손으로 앞으로 30° 숙임 → "앞 30°" 버튼 → 5초 캡처
/// 3. 뒤/오/왼 동일
/// 4. 5축 모두 캡처되면 진단 결과 (양수=앞기울 일치/반대) 표시
/// 5. 진단 결과 반대일 경우 → `pitchInputConvention = .negateForwardIsNegative` opt-in 권고
struct StaticTiltCalibrationPanel: View {
    var session: WalkLabSession
    @State private var activeAxis: StaticTiltCalibration.Axis? = nil
    @State private var captureProgress: Double = 0
    @State private var captureTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            // 헤더
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "ruler.fill")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.info)
                Text("정적 IMU 캘리브레이션 (P1.0)")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textPrimary)
                Spacer()
                Text("\(session.calibrationCaptures.count)/5 캡처됨")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }

            Text("로봇을 거치대 위에 두고, 5가지 자세를 각 5초씩 캡처. 결과는 pitch/roll 부호가 코드 가정과 일치하는지 진단합니다.")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // 5축 버튼 grid
            VStack(spacing: DFSpace.xs2) {
                ForEach(StaticTiltCalibration.Axis.allCases) { axis in
                    axisCaptureRow(axis: axis)
                }
            }

            // 진단 결과
            diagnosisSection

            // 리셋 버튼
            if !session.calibrationCaptures.isEmpty {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        captureTask?.cancel()
                        activeAxis = nil
                        captureProgress = 0
                        session.resetCalibrationCaptures()
                    } label: {
                        Label("초기화", systemImage: "arrow.counterclockwise")
                            .font(DFFont.micro)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.info.opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Components

    @ViewBuilder
    private func axisCaptureRow(axis: StaticTiltCalibration.Axis) -> some View {
        let existing = session.calibrationCaptures.first { $0.axis == axis }
        let isActive = activeAxis == axis
        HStack(spacing: DFSpace.xs2) {
            // 라벨 + 상태 아이콘
            Image(systemName: existing != nil ? "checkmark.circle.fill" : (isActive ? "circle.dotted" : "circle"))
                .font(DFFont.label)
                .foregroundStyle(existing != nil ? DFColor.success : (isActive ? DFColor.warning : DFColor.textSecondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(axis.label)
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textPrimary)
                if let cap = existing {
                    Text("pitch \(String(format: "%+.1f", cap.summary.meanPitch))°, roll \(String(format: "%+.1f", cap.summary.meanRoll))° (\(cap.samples.count) samples)")
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(axis.instruction)
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // 캡처 진행률 또는 버튼
            if isActive {
                ProgressView(value: captureProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
            } else {
                Button {
                    startCapture(axis: axis)
                } label: {
                    Text(existing == nil ? "캡처" : "재캡처")
                        .font(DFFont.micro)
                        .frame(minWidth: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(activeAxis != nil)
            }
        }
    }

    @ViewBuilder
    private var diagnosisSection: some View {
        let captures = session.calibrationCaptures
        if captures.count >= 2 {
            let d = session.currentCalibrationDiagnosis()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: diagnosisIcon(d))
                        .font(DFFont.label)
                        .foregroundStyle(diagnosisColor(d))
                    Text("진단 결과 (신뢰도 \(String(format: "%.0f", d.confidence * 100))%)")
                        .font(DFFont.sectionLabel)
                        .foregroundStyle(DFColor.textPrimary)
                }
                ForEach(d.notes, id: \.self) { note in
                    Text(note)
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 권고 — pitch 부호 반전 시 toggle 버튼 노출
                if d.pitchPositiveMeansForward == false {
                    HStack {
                        Spacer()
                        Button {
                            applyNegateConvention()
                        } label: {
                            Label("pitchInputConvention = .negate 적용",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(DFFont.micro)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(session.balanceExperimentConfig.pitchInputConvention == .negateForwardIsNegative)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, DFSpace.xs2)
        }
    }

    private func diagnosisIcon(_ d: StaticTiltCalibration.Diagnosis) -> String {
        switch (d.pitchPositiveMeansForward, d.rollPositiveMeansRight) {
        case (true?, true?):   return "checkmark.shield.fill"
        case (false?, _), (_, false?): return "exclamationmark.triangle.fill"
        case (nil, nil):       return "questionmark.circle"
        default:               return "info.circle"
        }
    }

    private func diagnosisColor(_ d: StaticTiltCalibration.Diagnosis) -> Color {
        switch (d.pitchPositiveMeansForward, d.rollPositiveMeansRight) {
        case (true?, true?):   return DFColor.success
        case (false?, _), (_, false?): return DFColor.warning
        case (nil, nil):       return DFColor.textSecondary
        default:               return DFColor.info
        }
    }

    // MARK: - Actions

    private func startCapture(axis: StaticTiltCalibration.Axis) {
        captureTask?.cancel()
        activeAxis = axis
        captureProgress = 0

        captureTask = Task { @MainActor in
            // UI progress (5초 동안 0→1).
            let progressTask = Task { @MainActor in
                let steps = 50
                let stepNs: UInt64 = 5_000_000_000 / UInt64(steps)
                for i in 0...steps {
                    if Task.isCancelled { return }
                    captureProgress = Double(i) / Double(steps)
                    try? await Task.sleep(nanoseconds: stepNs)
                }
            }
            _ = await session.runStaticTiltCalibration(axis: axis, durationSec: 5.0)
            progressTask.cancel()
            activeAxis = nil
            captureProgress = 0
        }
    }

    private func applyNegateConvention() {
        let cur = session.balanceExperimentConfig
        session.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: cur.algorithmMode,
            signConvention: cur.signConvention,
            gainProfile: cur.gainProfile,
            applyToRobot: cur.applyToRobot,
            pitchInputConvention: .negateForwardIsNegative
        )
    }
}
