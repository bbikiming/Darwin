import ForgeCore
import SwiftUI

/// HSV 튜닝 시트 — Sprint 18 Phase E (Codex 잔여 3 v1.5 minimal viable).
///
/// 4 색 × 4 파라미터 슬라이더 + robot ini read/write 단축 + source badge.
public struct PilotHsvTuningSheet: View {
    @Binding var preset: VisionHsvPreset
    @ObservedObject var remoteShell: RemoteShell
    let onClose: () -> Void

    @State private var selectedTag: MultiColorVision.Tag = .orange
    @State private var pendingAction: PendingAction?
    @State private var lastOperationMessage: String?

    enum PendingAction: Identifiable {
        case writeRobot
        var id: String { "writeRobot" }
    }

    public init(preset: Binding<VisionHsvPreset>,
                remoteShell: RemoteShell,
                onClose: @escaping () -> Void) {
        self._preset = preset
        self.remoteShell = remoteShell
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            header
            Divider()
            sourceBadge
            Picker("색", selection: $selectedTag) {
                ForEach(MultiColorVision.Tag.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            slidersBlock
            if let msg = lastOperationMessage {
                Text(msg)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.info)
                    .padding(DFSpace.xs)
                    .background(DFColor.info.opacity(DFOpacity.o10))
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            }
            Divider()
            actionsBar
        }
        .padding(DFSpace.lg)
        .frame(width: 600, height: 620)
        .background(.regularMaterial)
        .alert(item: $pendingAction) { _ in
            Alert(
                title: Text("로봇 config.ini 에 저장"),
                message: Text("**경고**: ROBOTIS demo 의 색 검출도 변경됩니다. demo 가 실행 중이면 재시작 필요. 정말 저장?"),
                primaryButton: .destructive(Text("로봇에 저장")) {
                    Task { await writeToRobot() }
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
    }

    // MARK: - Header / source badge

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "eyedropper.halffull")
                .font(.system(size: DFFontSize.s22))
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("HSV 튜닝").font(DFFont.title)
                Text("ROBOTIS-derived 기본값 — 로봇 ini 와 동기 가능")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            Button("닫기") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: sourceIcon)
                .foregroundStyle(sourceColor)
            Text(sourceLabel)
                .font(DFFont.bodyEmph)
                .foregroundStyle(sourceColor)
            if let at = preset.lastRobotSyncAt {
                Text("(\(elapsedText(at)) 전)")
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
        .padding(DFSpace.xs2)
        .background(sourceColor.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private var sourceIcon: String {
        switch preset.source {
        case .macDefault:      return "circle.dotted"
        case .robotSynced:     return "checkmark.icloud.fill"
        case .modifiedLocally: return "pencil.line"
        case .robotMismatch:   return "exclamationmark.triangle.fill"
        }
    }

    private var sourceColor: Color {
        switch preset.source {
        case .macDefault:      return DFColor.info
        case .robotSynced:     return DFColor.success
        case .modifiedLocally: return DFColor.warning
        case .robotMismatch:   return DFColor.danger
        }
    }

    private var sourceLabel: String {
        switch preset.source {
        case .macDefault:      return "Mac default (ROBOTIS main.cpp 인자)"
        case .robotSynced:     return "로봇과 동기화됨"
        case .modifiedLocally: return "로컬 수정됨 (로봇 미반영)"
        case .robotMismatch:   return "로봇과 다름"
        }
    }

    // MARK: - Sliders

    private var slidersBlock: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            let c = preset.range(for: selectedTag)
            // 6 슬라이더 — ROBOTIS ColorFinder.h:106-111 의 모든 파라미터.
            hsvSlider(title: "Hue (°)", value: c.hueCenterDeg, range: 0 ... 360, step: 1, format: "%.0f°") { newValue in
                replace { MultiColorVision.HSVRange(hueCenterDeg: newValue,
                                                     hueToleranceDeg: c.hueToleranceDeg,
                                                     minSaturationPct: c.minSaturationPct,
                                                     minValuePct: c.minValuePct,
                                                     minPercent: c.minPercent,
                                                     maxPercent: c.maxPercent) }
            }
            hsvSlider(title: "Hue tolerance (°)", value: c.hueToleranceDeg, range: 1 ... 90, step: 1, format: "±%.0f°") { newValue in
                replace { MultiColorVision.HSVRange(hueCenterDeg: c.hueCenterDeg,
                                                     hueToleranceDeg: newValue,
                                                     minSaturationPct: c.minSaturationPct,
                                                     minValuePct: c.minValuePct,
                                                     minPercent: c.minPercent,
                                                     maxPercent: c.maxPercent) }
            }
            hsvSlider(title: "Min saturation (0-100)", value: c.minSaturationPct, range: 0 ... 100, step: 1, format: "%.0f") { newValue in
                replace { MultiColorVision.HSVRange(hueCenterDeg: c.hueCenterDeg,
                                                     hueToleranceDeg: c.hueToleranceDeg,
                                                     minSaturationPct: newValue,
                                                     minValuePct: c.minValuePct,
                                                     minPercent: c.minPercent,
                                                     maxPercent: c.maxPercent) }
            }
            hsvSlider(title: "Min value / brightness (0-100)", value: c.minValuePct, range: 0 ... 100, step: 1, format: "%.0f") { newValue in
                replace { MultiColorVision.HSVRange(hueCenterDeg: c.hueCenterDeg,
                                                     hueToleranceDeg: c.hueToleranceDeg,
                                                     minSaturationPct: c.minSaturationPct,
                                                     minValuePct: newValue,
                                                     minPercent: c.minPercent,
                                                     maxPercent: c.maxPercent) }
            }
            // ROBOTIS percent gate — 검출 픽셀 비율 lower / upper.
            hsvSlider(title: "Min percent (검출 비율 하한)", value: c.minPercent, range: 0.01 ... 5.0, step: 0.01, format: "%.2f %%") { newValue in
                replace { MultiColorVision.HSVRange(hueCenterDeg: c.hueCenterDeg,
                                                     hueToleranceDeg: c.hueToleranceDeg,
                                                     minSaturationPct: c.minSaturationPct,
                                                     minValuePct: c.minValuePct,
                                                     minPercent: newValue,
                                                     maxPercent: c.maxPercent) }
            }
            hsvSlider(title: "Max percent (큰 blob 차단)", value: c.maxPercent, range: 1.0 ... 100.0, step: 1.0, format: "%.0f %%") { newValue in
                replace { MultiColorVision.HSVRange(hueCenterDeg: c.hueCenterDeg,
                                                     hueToleranceDeg: c.hueToleranceDeg,
                                                     minSaturationPct: c.minSaturationPct,
                                                     minValuePct: c.minValuePct,
                                                     minPercent: c.minPercent,
                                                     maxPercent: newValue) }
            }
        }
    }

    private func hsvSlider(title: String, value: Double,
                           range: ClosedRange<Double>, step: Double,
                           format: String,
                           setter: @escaping (Double) -> Void) -> some View {
        let binding = Binding<Double>(get: { value }, set: setter)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(DFFont.bodyEmph)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(DFColor.accent)
            }
            Slider(value: binding, in: range, step: step)
        }
        .padding(DFSpace.xs2)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    /// 새 HSVRange 로 교체 — 부분 update 보다 단순 (Swift let 필드 라 mutation 불가).
    private func replace(_ make: () -> MultiColorVision.HSVRange) {
        preset.setRange(make(), for: selectedTag)
    }

    // MARK: - Actions

    private var actionsBar: some View {
        HStack(spacing: DFSpace.sm) {
            DFButton(.secondary, size: .medium) {
                preset = .macDefault
                lastOperationMessage = "Mac default 로 초기화"
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Mac default")
                }
            }
            DFButton(.secondary, size: .medium) {
                Task { await loadFromRobot() }
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("로봇에서 불러오기")
                }
            }
            .disabled(remoteShell.isSending)
            Spacer()
            DFButton(.danger, size: .medium) {
                pendingAction = .writeRobot
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "icloud.and.arrow.up")
                    Text("로봇에 저장")
                }
            }
            .disabled(remoteShell.isSending)
        }
    }

    // MARK: - Robot sync

    @MainActor
    private func loadFromRobot() async {
        lastOperationMessage = "로봇에서 config.ini read 중…"
        let priorCount = remoteShell.history.count
        await remoteShell.send(RobotSetupCommand.readVisionConfig)
        let lastEx = remoteShell.history.indices.contains(priorCount)
            ? remoteShell.history[priorCount]
            : remoteShell.history.last
        guard let result = lastEx?.result else {
            lastOperationMessage = "로봇 응답 없음"
            return
        }
        // 한 줄씩 파싱: DF_HSV_ORANGE=hue=355,tolerance=15,min_saturation=60,min_value=15,min_percent=0.1,max_percent=50.0
        // ROBOTIS ini 의 raw 값을 그대로 받음 — sat/val 은 0-100 정수.
        var parsed: [MultiColorVision.Tag: MultiColorVision.HSVRange] = [:]
        for line in result.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DF_HSV_") else { continue }
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let tagName = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<eqIdx])
            let kvString = String(trimmed[trimmed.index(after: eqIdx)...])
            let tag: MultiColorVision.Tag? = {
                switch tagName {
                case "ORANGE": return .orange
                case "RED":    return .red
                case "YELLOW": return .yellow
                case "BLUE":   return .blue
                default:       return nil
                }
            }()
            guard let tag else { continue }
            let curr = preset.range(for: tag)
            var hue = curr.hueCenterDeg
            var tol = curr.hueToleranceDeg
            var sat = curr.minSaturationPct
            var val = curr.minValuePct
            var minPct = curr.minPercent
            var maxPct = curr.maxPercent
            for kv in kvString.split(separator: ",") {
                let parts = kv.split(separator: "=")
                guard parts.count == 2 else { continue }
                let v = Double(parts[1]) ?? -1
                if v < 0 { continue }
                switch parts[0] {
                case "hue":             hue = v
                case "tolerance":       tol = v
                case "min_saturation":  sat = v    // ROBOTIS ini 가 0-100 → 그대로
                case "min_value":       val = v
                case "min_percent":     minPct = v
                case "max_percent":     maxPct = v
                default: break
                }
            }
            parsed[tag] = MultiColorVision.HSVRange(
                hueCenterDeg: hue, hueToleranceDeg: tol,
                minSaturationPct: sat, minValuePct: val,
                minPercent: minPct, maxPercent: maxPct
            )
        }
        guard parsed.count == 4 else {
            lastOperationMessage = "로봇 ini 파싱 실패 — \(parsed.count)/4 색만 읽음"
            return
        }
        preset = VisionHsvPreset(
            orange: parsed[.orange]!, red: parsed[.red]!,
            yellow: parsed[.yellow]!, blue: parsed[.blue]!,
            source: .robotSynced, lastRobotSyncAt: Date()
        )
        lastOperationMessage = "✅ 로봇에서 4 색 모두 불러옴"
    }

    @MainActor
    private func writeToRobot() async {
        lastOperationMessage = "로봇에 write 중…"
        // DF_ARGS — 4색 × 7토큰 (tag h t sat val min_pct max_pct).
        // ROBOTIS ini 가 sat/val 은 0-100 정수, min/max_pct 는 float — 그대로 전달.
        var args: [String] = []
        for tag in MultiColorVision.Tag.allCases {
            let upper = tag.rawValue.uppercased()
            let r = preset.range(for: tag)
            args.append(upper)
            args.append(String(Int(r.hueCenterDeg)))
            args.append(String(Int(r.hueToleranceDeg)))
            args.append(String(Int(r.minSaturationPct)))
            args.append(String(Int(r.minValuePct)))
            args.append(String(format: "%.2f", r.minPercent))
            args.append(String(format: "%.2f", r.maxPercent))
        }
        let argsStr = args.joined(separator: " ")
        let fullCommand = "DF_ARGS=\"\(argsStr)\"\n" + RobotSetupCommand.writeVisionConfig
        await remoteShell.send(fullCommand)
        let last = remoteShell.history.last
        if let r = last?.result, r.contains("✅") {
            preset = VisionHsvPreset(
                orange: preset.orange, red: preset.red,
                yellow: preset.yellow, blue: preset.blue,
                source: .robotSynced, lastRobotSyncAt: Date()
            )
            lastOperationMessage = "✅ 로봇 ini 저장 완료. demo 가 실행 중이면 재시작 필요."
        } else {
            lastOperationMessage = "쓰기 실패: \(last?.result?.prefix(80) ?? "응답 없음")"
        }
    }

    private func elapsedText(_ at: Date) -> String {
        let s = Date().timeIntervalSince(at)
        if s < 60 { return "\(Int(s))초" }
        return "\(Int(s/60))분"
    }
}
