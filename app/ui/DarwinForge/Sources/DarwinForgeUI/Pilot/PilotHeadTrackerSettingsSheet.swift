import ForgeCore
import SwiftUI

/// head 추적 PD 조정 시트 — Sprint 18 Phase E (Codex 잔여 1).
///
/// 사용자가 PilotCameraView 의 head tracking 토글 옆 "조정" 버튼 누르면 표시.
/// `PilotHeadTracker` 의 `@Published` 게인들 (kp / kd / deadband / maxStep / lostTargetHold)
/// 을 슬라이더로 직접 bind — 사용자가 움직이면 다음 detection 부터 즉시 반영.
///
/// **안전**:
///   - Kp 가 0.5 이상이면 황색 경고 ("진동 위험").
///   - Kp × maxStep > 4 면 황색 경고 (한 frame 변화 너무 큼).
///   - "기본값으로 초기화" 버튼 — Codex-derived 보수적 seed 복원.
public struct PilotHeadTrackerSettingsSheet: View {
    @ObservedObject var tracker: PilotHeadTracker
    let onClose: () -> Void

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init(tracker: PilotHeadTracker, onClose: @escaping () -> Void) {
        self.tracker = tracker
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    introBlock
                    kpSlider
                    kdSlider
                    deadbandSlider
                    maxStepSlider
                    lostHoldSlider
                    Divider()
                    liveDebug
                }
                .padding(.bottom, DFSpace.md)
            }
            Divider()
            footer
        }
        .padding(DFSpace.lg)
        .frame(width: 560, height: 640)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: DFFontSize.s22))
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("head 추적 PD 조정")
                    .font(DFFont.title)
                Text("ROBOTIS-derived seed — Camera.h FOV 58°/46° + PD 제어")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer(minLength: 0)
            // 사이클 138 (audit #24 codex sweep)
            Button("닫기", role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var introBlock: some View {
        HStack(alignment: .top, spacing: DFSpace.xs2) {
            Image(systemName: "info.circle")
                .foregroundStyle(DFColor.info)
            Text("게인을 너무 크게 설정하면 head 가 진동합니다. 슬라이더는 즉시 반영됩니다 — 다음 카메라 frame 부터.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.sm)
        .background(DFColor.info.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Sliders

    private var kpSlider: some View {
        gainBlock(
            title: "Kp (Proportional)",
            currentValue: tracker.kp,
            defaultValue: 0.32,
            range: 0.05 ... 0.80,
            step: 0.01,
            format: "%.2f",
            warning: tracker.kp >= 0.5
                ? "진동 위험 — 보수적 권장 (0.30 ± 0.05)"
                : nil,
            help: "오차에 비례한 head 이동량. 클수록 빠른 응답, 작을수록 안정."
        ) { $0 } setter: { newVal in
            harness.record(.pilotHeadTrackerGainChanged, level: .info, actor: .user,
                                  data: ["param": "kp", "value": AnyCodable(newVal)])
            tracker.kp = newVal
        }
    }

    private var kdSlider: some View {
        gainBlock(
            title: "Kd (Derivative)",
            currentValue: tracker.kd,
            defaultValue: 0.18,
            range: 0.00 ... 0.50,
            step: 0.01,
            format: "%.2f",
            warning: tracker.kd > tracker.kp * 0.8
                ? "Kd 가 Kp 비율 80% 초과 — 진동 회피용으로만 사용"
                : nil,
            help: "오차 변화율로 진동 억제. Kp 의 50% 정도가 일반적."
        ) { $0 } setter: { newVal in
            harness.record(.pilotHeadTrackerGainChanged, level: .info, actor: .user,
                                  data: ["param": "kd", "value": AnyCodable(newVal)])
            tracker.kd = newVal
        }
    }

    private var deadbandSlider: some View {
        gainBlock(
            title: "Deadband (정규화)",
            currentValue: tracker.deadbandNormalized,
            defaultValue: 0.04,
            range: 0.00 ... 0.15,
            step: 0.01,
            format: "%.2f",
            warning: tracker.deadbandNormalized < 0.02
                ? "너무 작으면 화면 중앙에서 head 떨림"
                : nil,
            help: "공이 화면 중앙 근처일 때 head 송출 skip. 0.04 = ±2.3° (FOV 58°)."
        ) { $0 } setter: { newVal in
            harness.record(.pilotHeadTrackerGainChanged, level: .info, actor: .user,
                                  data: ["param": "deadband", "value": AnyCodable(newVal)])
            tracker.deadbandNormalized = newVal
        }
    }

    private var maxStepSlider: some View {
        let multStepWarn = (tracker.kp * tracker.maxStepDeg) > 4.0
        return gainBlock(
            title: "최대 step (도/tick)",
            currentValue: tracker.maxStepDeg,
            defaultValue: 5.0,
            range: 1.0 ... 15.0,
            step: 0.5,
            format: "%.1f°",
            warning: multStepWarn
                ? "Kp × maxStep = \(String(format: "%.1f", tracker.kp * tracker.maxStepDeg)) — 한 frame 변화 큼"
                : nil,
            help: "한 카메라 frame 당 허용된 최대 head 변화. 너무 작으면 따라잡기 못 함."
        ) { $0 } setter: { newVal in
            harness.record(.pilotHeadTrackerGainChanged, level: .info, actor: .user,
                                  data: ["param": "maxStepDeg", "value": AnyCodable(newVal)])
            tracker.maxStepDeg = newVal
        }
    }

    private var lostHoldSlider: some View {
        gainBlock(
            title: "공 사라짐 hold (frames)",
            currentValue: Double(tracker.lostTargetHoldFrames),
            defaultValue: 3.0,
            range: 1.0 ... 10.0,
            step: 1.0,
            format: "%.0f frame",
            warning: nil,
            help: "공 검출 안 된 frame 이 이 수보다 적으면 head 위치 유지. 카메라 깜빡임 대응."
        ) { Double($0) } setter: { newVal in
            harness.record(.pilotHeadTrackerGainChanged, level: .info, actor: .user,
                                  data: ["param": "lostTargetHoldFrames", "value": AnyCodable(Int(newVal))])
            tracker.lostTargetHoldFrames = Int(newVal)
        }
    }

    /// 게인 한 개의 슬라이더 + 라벨 + 경고 + 기본값.
    private func gainBlock(
        title: String,
        currentValue: Double,
        defaultValue: Double,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        warning: String?,
        help: String,
        getter: @escaping (Double) -> Double,
        setter: @escaping (Double) -> Void
    ) -> some View {
        let binding = Binding<Double>(
            get: { getter(currentValue) },
            set: { setter($0) }
        )
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack {
                Text(title).font(DFFont.bodyEmph)
                Spacer()
                Text(String(format: format, currentValue))
                    .font(DFFont.bodyEmph.monospaced())
                    .foregroundStyle(currentValue == defaultValue ? DFColor.textSecondary : DFColor.accent)
                if currentValue != defaultValue {
                    Button {
                        setter(defaultValue)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(DFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("기본값 \(String(format: format, defaultValue)) 로 복원")
                }
            }
            Slider(value: binding, in: range, step: step)
                .tint(DFColor.accent)
            Text(help)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            if let warning {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DFColor.warning)
                    Text(warning)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.warning)
                }
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Live debug

    private var liveDebug: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("현재 PD 상태").font(DFFont.bodyEmph)
            HStack(spacing: DFSpace.md) {
                metricLine(label: "Pan", value: String(format: "%+.1f°", tracker.currentPanDeg))
                metricLine(label: "Tilt", value: String(format: "%+.1f°", tracker.currentTiltDeg))
                Spacer()
            }
            if let skip = tracker.lastSkipReason {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DFColor.warning)
                    Text("최근 skip: \(skip)")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.warning)
                        .lineLimit(2)
                }
            }
            if let at = tracker.lastProcessedAt {
                let elapsed = Date().timeIntervalSince(at)
                Text("마지막 처리: \(elapsed < 1 ? "방금" : String(format: "%.1f초 전", elapsed))")
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.accent.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func metricLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            Text(value).font(DFFont.bodyEmph.monospaced()).foregroundStyle(DFColor.accent)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DFSpace.sm) {
            DFButton(.secondary, size: .medium) {
                resetToDefaults()
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("모두 기본값으로 초기화")
                }
            }
            Spacer()
            DFButton(.primary, size: .medium) { onClose() } label: {
                Text("완료")
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func resetToDefaults() {
        harness.record(.pilotHeadTrackerResetDefaults, level: .info, actor: .user)
        tracker.kp = 0.32
        tracker.kd = 0.18
        tracker.deadbandNormalized = 0.04
        tracker.maxStepDeg = 5.0
        tracker.lostTargetHoldFrames = 3
    }
}
