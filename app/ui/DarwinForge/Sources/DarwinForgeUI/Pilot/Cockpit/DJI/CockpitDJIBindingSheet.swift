import SwiftUI
import Combine

#if canImport(IOKit)

/// **방법론 (Logitech G HUB + Razer Synapse 3 + DJI Fly + Apple Settings 합성)**:
///
/// 본 sheet 의 핵심 UX 목표는 "3 클릭 안에 매핑 완료". 그래서 **3-column information
/// architecture** 를 채택:
///
/// 1. **왼쪽 — 동작 할당 (Action list)**: 각 cockpit action 이 card. icon + 이름 +
///    현재 매핑 badge + 상태 dot. 선택된 card 는 accent 강조.
/// 2. **가운데 — DJI 조종기 (Controller visual)**: 사실적 controller illustration.
///    실시간 입력 시각화 + 클릭으로 매핑.
/// 3. **오른쪽 — 선택된 컨트롤 (Inspector)**: 사용자가 선택한 control 의 detail —
///    매핑된 동작 (변경 가능 dropdown), 입력 유형, 감도 slider, 반응 곡선, 모드.
///
/// # 인터랙션 모델
///
/// **Workflow A (action-first, Steam Input Configurator)**:
/// 1. 왼쪽에서 action card 클릭 → selectedAction 설정 + 현재 매핑된 control 자동
///    inspector 표시.
/// 2. 가운데 controller 의 element 클릭 → element 가 selectedAction 에 매핑됨.
/// 3. swap notice banner 가 충돌 결과 알림.
///
/// **Workflow B (element-first, Razer Synapse)**:
/// 1. 가운데 controller 의 element 클릭 → selectedBinding 설정 + inspector 에 detail.
/// 2. 오른쪽 inspector 의 "매핑된 동작" dropdown 변경 → 그 action 에 binding 적용.
///
/// 두 workflow 는 동등한 결과 (단지 mental model 의 차이) — 사용자가 편한 방식 선택.
///
/// # macOS HIG 정합
///
/// - **Sheet width/height**: 1100 × 760 (HIG Preferences large size — System Settings
///   Mouse / Keyboard panel 과 동일 범주).
/// - **Segmented picker (장치/목록)**: HIG 의 segmented control 표준.
/// - **Dark mode native**: 모든 색상 system semantic (Color.accentColor / .secondary)
///   사용. NSColor.controlBackgroundColor 로 macOS material 추종.
/// - **ESC = 취소, Return = 저장**: keyboardShortcut 표준.
@MainActor
public struct CockpitDJIBindingSheet: View {

    @Binding var isPresented: Bool
    @Binding var profile: DJIBindingProfile
    @ObservedObject var watcher: DJIVirtualJoystickWatcher

    @State private var editingProfile: DJIBindingProfile
    @State private var listeningAction: CockpitAction?
    @State private var swapNotice: String?
    @State private var swapNoticeTask: Task<Void, Never>?

    @State private var viewMode: ViewMode = .device
    /// 현재 매핑 대상 action (action-first flow 의 active 동작).
    @State private var selectedAction: CockpitAction = .moveForward
    /// Inspector 에서 표시중인 control 의 binding. action card / element 클릭 시 갱신.
    @State private var selectedBinding: DJIInputBinding?

    /// Inspector 의 sensitivity slider — 추후 per-binding deadzone modifier 로 연결
    /// 가능한 UI placeholder. 0..100. 50 = 기본 deadzone.
    @State private var sensitivity: Double = 50
    @State private var responseCurve: ResponseCurve = .linear
    @State private var inputMode: InputMode = .default

    public enum ViewMode: String, CaseIterable, Identifiable {
        case device = "장치"
        case list = "목록"
        public var id: String { rawValue }
    }

    public enum ResponseCurve: String, CaseIterable, Identifiable {
        case linear = "선형"
        case smooth = "부드러움"
        case aggressive = "민감"
        public var id: String { rawValue }
    }

    public enum InputMode: String, CaseIterable, Identifiable {
        case `default` = "기본"
        case custom = "사용자 정의"
        public var id: String { rawValue }
    }

    public init(isPresented: Binding<Bool>,
                profile: Binding<DJIBindingProfile>,
                watcher: DJIVirtualJoystickWatcher) {
        self._isPresented = isPresented
        self._profile = profile
        self._editingProfile = State(initialValue: profile.wrappedValue)
        self.watcher = watcher
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if let notice = swapNotice {
                swapBanner(text: notice)
            }
            Divider()
            mainContent
            Divider()
            footer
        }
        .frame(width: 1100, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(watcher.$lastReport) { report in
            guard let report, let action = listeningAction else { return }
            if let binding = DJIBindingCapture.detect(report) {
                applyBinding(binding, for: action)
                listeningAction = nil
            }
        }
        .onAppear {
            watcher.pauseStreaming()
            // 시작 시 selectedAction 의 현재 binding 으로 inspector 동기화.
            syncInspectorWithAction(selectedAction)
        }
        .onDisappear {
            watcher.resumeStreaming()
            swapNoticeTask?.cancel()
        }
        .accessibilityIdentifier("cockpit.dji.bindings.sheet")
    }

    // MARK: - Top bar (title + picker + profile selector + close)

    private var topBar: some View {
        HStack(spacing: 16) {
            // Left: icon + title
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DJI 조종기 매핑")
                        .font(.system(size: 14, weight: .semibold))
                    Text("각 동작에 매핑할 컨트롤러 입력을 선택하세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Center: view mode picker (장치/목록)
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .accessibilityIdentifier("cockpit.dji.bindings.viewmode")

            Spacer()

            // Right: profile dropdown + close
            HStack(spacing: 10) {
                profileMenu
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("닫기 (ESC)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// 프로파일 선택 dropdown — 현재는 단일 프로파일이라 표시만. multi-profile 도입
    /// 시 향후 확장.
    private var profileMenu: some View {
        Menu {
            Button {
                editingProfile = .djiMode2
                showSwapNotice("DJI Mode 2 기본 매핑으로 재설정됐어요.")
            } label: {
                Label("DJI Mode 2 (기본)", systemImage: "gamecontroller")
            }
            Divider()
            Text("멀티 프로파일 곧 지원 예정")
                .font(.caption)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                Text(editingProfile.name.isEmpty
                     ? "프로파일" : editingProfile.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25),
                                    lineWidth: 0.5)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("프로파일 선택 (현재 단일 프로파일 모드)")
    }

    // MARK: - Main content (device 3-column or list)

    @ViewBuilder
    private var mainContent: some View {
        if viewMode == .device {
            deviceModeColumns
        } else {
            listModeContent
        }
    }

    private var deviceModeColumns: some View {
        HStack(spacing: 0) {
            actionAssignmentColumn
                .frame(width: 280)
            Divider()
            controllerColumn
                .frame(maxWidth: .infinity)
            Divider()
            inspectorColumn
                .frame(width: 300)
        }
    }

    // MARK: - Left column: 동작 할당 (Action assignment)

    private var actionAssignmentColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Text("동작 할당")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("동작을 클릭하면 그 동작에 컨트롤러 입력을 할당할 수 있어요. 가운데 조종기에서 element 를 클릭하면 매핑이 적용됩니다.")
                Spacer()
            }
            // Action groups
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(CockpitAction.Group.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(groupTitle(group))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .textCase(.none)
                            VStack(spacing: 4) {
                                ForEach(actions(in: group), id: \.self) { action in
                                    actionCard(action)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            // Add action button (placeholder for future custom actions)
            Button {
                showSwapNotice("커스텀 동작은 곧 지원 예정입니다.")
            } label: {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("동작 추가")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.3),
                                     style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func groupTitle(_ group: CockpitAction.Group) -> String {
        switch group {
        case .movement: return "이동 제어"
        case .rotation: return "회전 제어"
        case .head:     return "머리 제어"
        case .safety:   return "안전 제어"
        }
    }

    /// 개별 동작 card.
    private func actionCard(_ action: CockpitAction) -> some View {
        let isSelected = selectedAction == action
        let binding = editingProfile.bindings[action] ?? .unbound
        let isBound = !binding.isUnbound

        return Button {
            selectedAction = action
            syncInspectorWithAction(action)
        } label: {
            HStack(spacing: 10) {
                // Action icon
                ZStack {
                    Circle()
                        .fill(isSelected
                              ? Color.accentColor.opacity(0.25)
                              : Color.secondary.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: actionIcon(action))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor
                                                    : Color.secondary)
                }
                // Action name
                Text(action.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                // Binding badge
                bindingBadge(binding: binding)
                // Status dot
                Circle()
                    .fill(isBound ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .shadow(color: isBound ? Color.green.opacity(0.6) : .clear,
                            radius: isBound ? 3 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected
                            ? Color.accentColor
                            : Color.secondary.opacity(0.15),
                            lineWidth: isSelected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .help(action.isSafetyCritical
              ? "안전 동작 — 매핑은 가능하지만 매핑 해제는 차단됩니다."
              : "이 동작을 매핑하려면 클릭하세요. 그런 다음 가운데 조종기에서 element 를 클릭합니다.")
    }

    private func actionIcon(_ action: CockpitAction) -> String {
        switch action {
        case .moveForward:   return "arrow.up"
        case .moveBackward:  return "arrow.down"
        case .strafeLeft:    return "arrow.left"
        case .strafeRight:   return "arrow.right"
        case .turnLeft:      return "arrow.turn.up.left"
        case .turnRight:     return "arrow.turn.up.right"
        case .headPanLeft:   return "arrow.left.circle"
        case .headPanRight:  return "arrow.right.circle"
        case .headTiltUp:    return "arrow.up.circle"
        case .headTiltDown:  return "arrow.down.circle"
        case .ballTracking:  return "eye"
        case .emergencyStop: return "exclamationmark.triangle"
        case .recover:       return "shield"
        }
    }

    /// 현재 binding 의 chip badge (예: "X +", "Button 1", "—").
    private func bindingBadge(binding: DJIInputBinding) -> some View {
        Text(binding.displayLabel)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(binding.isUnbound
                             ? Color.secondary.opacity(0.7)
                             : Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(binding.isUnbound
                          ? Color.secondary.opacity(0.10)
                          : Color.green.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(binding.isUnbound
                                    ? Color.secondary.opacity(0.3)
                                    : Color.green.opacity(0.5),
                                    lineWidth: 0.5)))
    }

    // MARK: - Center column: 조종기 시각화

    /// **퍼포먼스 최적화**: 부모 sheet body 에서 `watcher.lastReport` 를 직접 접근하면
    /// HID 가 publish 할 때마다 sheet 전체 body 가 recompute 된다. 그래서 controller
    /// column 을 별도 View struct (`CockpitDJIControllerColumn`) 로 분리 — 그쪽에서
    /// Combine throttle 로 60 FPS 로 cap 된 report 만 시각화에 전달.
    private var controllerColumn: some View {
        CockpitDJIControllerColumn(
            watcher: watcher,
            profile: editingProfile,
            selectedAction: selectedAction,
            selectedBinding: selectedBinding,
            onTap: { binding in
                onControllerElementTap(binding)
            })
    }

    // MARK: - Right column: Inspector

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("선택된 컨트롤")
                    .font(.system(size: 13, weight: .semibold))
                inspectorControlSection
                inspectorActionSection
                inspectorInputTypeSection
                inspectorSensitivitySection
                inspectorResponseCurveSection
                inspectorModeSection
                inspectorActionButtons
            }
            .padding(16)
        }
    }

    /// 선택된 control 의 요약 — 큰 라벨 + subtitle.
    private var inspectorControlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("컨트롤")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: selectedBindingIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedBindingPrimary)
                        .font(.system(size: 12, weight: .semibold))
                    Text(selectedBindingSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2),
                                    lineWidth: 0.5)))
        }
    }

    /// 매핑된 동작 dropdown.
    private var inspectorActionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("매핑된 동작")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(CockpitAction.Group.allCases, id: \.self) { group in
                    Section(groupTitle(group)) {
                        ForEach(actions(in: group), id: \.self) { a in
                            Button {
                                if let binding = selectedBinding {
                                    applyBinding(binding, for: a)
                                    selectedAction = a
                                }
                            } label: {
                                HStack {
                                    Image(systemName: actionIcon(a))
                                    Text(a.label)
                                    if currentActionForSelectedBinding == a {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                inspectorDropdownLabel(
                    text: currentActionForSelectedBinding?.label ?? "매핑 없음",
                    disabled: selectedBinding == nil)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(selectedBinding == nil)
        }
    }

    private var inspectorInputTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("입력 유형")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            inspectorDropdownLabel(text: inputTypeLabel, disabled: true)
        }
    }

    private var inspectorSensitivitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("감도")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("입력 deadzone 의 민감도. 50 = 기본값. (실시간 적용은 곧 지원)")
            }
            HStack(spacing: 8) {
                Text("0")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Slider(value: $sensitivity, in: 0...100)
                Text("100")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(Int(sensitivity))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.25),
                                            lineWidth: 0.5)))
            }
        }
    }

    private var inspectorResponseCurveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("반응 곡선")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(ResponseCurve.allCases) { curve in
                    Button {
                        responseCurve = curve
                    } label: {
                        HStack {
                            Text(curve.rawValue)
                            if responseCurve == curve {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                inspectorDropdownLabel(text: responseCurve.rawValue, disabled: false)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inspectorModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("모드")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(InputMode.allCases) { mode in
                    Button {
                        inputMode = mode
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if inputMode == mode {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                inspectorDropdownLabel(text: inputMode.rawValue, disabled: false)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inspectorActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                // 매핑 해제 — 단, 안전 action 은 차단.
                guard selectedBinding != nil,
                      let action = currentActionForSelectedBinding else { return }
                applyBinding(.unbound, for: action)
            } label: {
                Text("매핑 해제")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(selectedBinding == nil
                      || currentActionForSelectedBinding == nil
                      || currentActionForSelectedBinding?.isSafetyCritical == true)

            Button(role: .destructive) {
                editingProfile = .djiMode2
                showSwapNotice("DJI Mode 2 기본 매핑으로 재설정됐어요.")
            } label: {
                Text("기본값 복원")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private func inspectorDropdownLabel(text: String, disabled: Bool) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(disabled ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(disabled ? 0.05 : 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25),
                                lineWidth: 0.5)))
    }

    // MARK: - Inspector binding display helpers

    private var selectedBindingIcon: String {
        guard let b = selectedBinding else { return "questionmark.square.dashed" }
        switch b {
        case .axis(.x, _), .axis(.y, _):  return "circle.lefthalf.filled"
        case .axis(.rx, _), .axis(.ry, _): return "circle.righthalf.filled"
        case .axis(.z, _):                 return "dial.medium"
        case .button:                       return "rectangle.fill"
        case .unbound:                      return "questionmark.square.dashed"
        }
    }

    private var selectedBindingPrimary: String {
        guard let b = selectedBinding else { return "선택되지 않음" }
        switch b {
        case .axis(.x, let pol):  return "좌 스틱 X \(pol.rawValue)"
        case .axis(.y, let pol):  return "좌 스틱 Y \(pol.rawValue)"
        case .axis(.rx, let pol): return "우 스틱 Rx \(pol.rawValue)"
        case .axis(.ry, let pol): return "우 스틱 Ry \(pol.rawValue)"
        case .axis(.z, let pol):  return "Z 휠 \(pol.rawValue)"
        case .button(let idx):
            switch idx {
            case 0: return "Button 1 (긴급)"
            case 1: return "Button 2 (복구)"
            case 2: return "C1 버튼"
            case 3: return "전원 버튼"
            default: return "Button \(idx + 1)"
            }
        case .unbound: return "—"
        }
    }

    private var selectedBindingSubtitle: String {
        guard let b = selectedBinding else {
            return "왼쪽 동작이나 가운데 조종기의 element 를 클릭하세요."
        }
        switch b {
        case .axis(.x, _), .axis(.y, _):  return "Yaw / Throttle"
        case .axis(.rx, _), .axis(.ry, _): return "Roll / Pitch"
        case .axis(.z, _):                 return "카메라 휠"
        case .button:                       return "디지털 입력"
        case .unbound:                      return "—"
        }
    }

    private var inputTypeLabel: String {
        guard let b = selectedBinding else { return "—" }
        switch b {
        case .axis:    return "축 입력 (Axis)"
        case .button:  return "버튼 (Button)"
        case .unbound: return "—"
        }
    }

    private var currentActionForSelectedBinding: CockpitAction? {
        guard let b = selectedBinding else { return nil }
        return editingProfile.bindings.first { $0.value == b }?.key
    }

    // MARK: - List mode (advanced)

    private var listModeContent: some View {
        Form {
            ForEach(CockpitAction.Group.allCases, id: \.self) { group in
                Section(groupTitle(group)) {
                    ForEach(actions(in: group), id: \.self) { action in
                        bindingRow(for: action)
                    }
                }
            }
            Section("프로파일") {
                LabeledContent("프로파일 이름") {
                    TextField("", text: $editingProfile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                HStack {
                    Button("DJI Mode 2 (기본)") {
                        editingProfile = .djiMode2
                        showSwapNotice("DJI Mode 2 기본 매핑으로 재설정됐어요.")
                    }
                    .buttonStyle(.bordered)
                    Button("이동/회전 비우기") {
                        var empty = DJIBindingProfile.empty
                        empty.name = profile.name
                        empty.bindings[.emergencyStop] = DJIBindingProfile.djiMode2.bindings[.emergencyStop]
                        empty.bindings[.recover] = DJIBindingProfile.djiMode2.bindings[.recover]
                        editingProfile = empty
                        showSwapNotice("이동/회전 매핑이 비워졌어요. 안전 동작은 기본값 유지.")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                editingProfile = .djiMode2
                showSwapNotice("기본값으로 복원됐어요.")
            } label: {
                Label("기본값으로 재설정", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("취소") {
                isPresented = false
            }
            .keyboardShortcut("w", modifiers: [.command])
            .buttonStyle(.bordered)
            Button("저장") {
                profile = editingProfile
                DJIBindingProfileStore.save(editingProfile)
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Swap notice banner

    private func swapBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: - List-mode row + manual picker (TG-1 fix preserved)

    @ViewBuilder
    private func bindingRow(for action: CockpitAction) -> some View {
        let binding = editingProfile.bindings[action] ?? .unbound
        let isListening = listeningAction == action
        let canListen = watcher.isStreaming
        LabeledContent(action.label) {
            HStack(spacing: 8) {
                bindingValueLabel(binding: binding, isListening: isListening)
                    .frame(minWidth: 110, alignment: .trailing)
                if canListen {
                    Button(isListening ? "취소" : "Listen") {
                        listeningAction = isListening ? nil : action
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("다음 DJI 입력을 누르면 매핑됩니다.")
                } else {
                    manualPicker(action: action)
                }
                Button {
                    applyBinding(.unbound, for: action)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(action.isSafetyCritical
                      ? "안전 동작은 매핑 해제할 수 없습니다."
                      : "매핑 해제")
                .disabled(binding.isUnbound || action.isSafetyCritical)
            }
        }
    }

    @ViewBuilder
    private func manualPicker(action: CockpitAction) -> some View {
        Menu {
            Section("Axis (스틱 / 휠)") {
                ForEach(DJIInputBinding.Axis.allCases, id: \.self) { axis in
                    ForEach(DJIInputBinding.Polarity.allCases, id: \.self) { pol in
                        Button {
                            applyBinding(.axis(axis, polarity: pol), for: action)
                        } label: {
                            Text("\(axis.label) \(pol.rawValue) · \(axis.humanDescription)")
                        }
                    }
                }
            }
            Section("Button") {
                ForEach(0..<8, id: \.self) { idx in
                    Button("Button \(idx + 1)") {
                        applyBinding(.button(idx), for: action)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("선택")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("HID 미연결 — axis 또는 button 을 직접 선택.")
    }

    @ViewBuilder
    private func bindingValueLabel(binding: DJIInputBinding, isListening: Bool) -> some View {
        if isListening {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("입력 대기 중…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        } else {
            Text(binding.displayLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(binding.isUnbound
                                 ? Color.secondary
                                 : Color.primary)
        }
    }

    // MARK: - Tap handling

    private func onControllerElementTap(_ binding: DJIInputBinding) {
        // 선택된 action 에 binding 적용.
        applyBinding(binding, for: selectedAction)
        // Inspector 동기화.
        selectedBinding = binding
    }

    /// action 선택 시 inspector 가 자동으로 그 action 의 현재 매핑된 binding 표시.
    private func syncInspectorWithAction(_ action: CockpitAction) {
        if let binding = editingProfile.bindings[action], !binding.isUnbound {
            selectedBinding = binding
        } else {
            selectedBinding = nil
        }
    }

    private func applyBinding(_ binding: DJIInputBinding,
                              for action: CockpitAction) {
        let result = editingProfile.setBinding(binding, for: action)
        switch result {
        case .applied:
            break
        case .appliedWithSwap(let actions):
            let names = actions.map { $0.label }.joined(separator: ", ")
            showSwapNotice("'\(names)' 의 매핑이 해제됐어요 (동일 binding).")
        case .rejectedSafetyUnbound(let a):
            showSwapNotice("안전 동작 '\(a.label)' 은 매핑 해제할 수 없습니다.")
        case .rejectedSafetyStolen(let a):
            showSwapNotice("안전 동작 '\(a.label)' 의 binding 은 다른 동작이 빼앗을 수 없습니다. 안전 동작을 먼저 다른 binding 으로 옮기세요.")
        }
    }

    private func showSwapNotice(_ text: String) {
        swapNotice = text
        swapNoticeTask?.cancel()
        swapNoticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            swapNotice = nil
        }
    }

    private func actions(in group: CockpitAction.Group) -> [CockpitAction] {
        CockpitAction.allCases.filter { $0.group == group }
    }
}

// MARK: - Performance-isolated controller column

/// **방법론 (Apple SwiftUI Performance Guide + Combine throttle pattern + @StateObject
/// lifetime stability pattern)**:
///
/// HID stream 은 60–100Hz 로 push 하지만 macOS 디스플레이는 최대 60Hz (또는 120Hz
/// ProMotion). 그래서 본 column 은:
///
/// 1. **Combine throttle (60 FPS cap)** — `watcher.$lastReport.throttle(for: 1/60,
///    latest: true)` 로 디스플레이 refresh rate 에 맞춤. 60 FPS 초과 update 는 그냥
///    drop. 100Hz HID → 60Hz visual 로 40 % 절감.
/// 2. **관찰 격리** — `let watcher` (NOT `@ObservedObject`). 부모 sheet 의
///    `@ObservedObject` 가 `isStreaming` 등으로 publish 해도 본 column 의 visual
///    sub-view 는 `state.report` Equatable 비교로 동일 값에는 body skip.
/// 3. **@StateObject ControllerColumnState** — throttle subscription 의 lifetime
///    안정. struct view 의 closure prop (`onTap`) 때문에 SwiftUI 가 column body 를
///    매번 reeval 해도 state 객체는 view identity 와 묶여 유지됨. subscription 은
///    onAppear 에서 1 회 설정, throttle state 보존.
///
/// 결과: visual body 계산 횟수 ≤ 60 / 초. HID 가 100Hz 여도 디스플레이가 표현 불가
/// 능한 추가 40Hz 는 드롭. sheet 의 action list / inspector column 은 visual 의
/// report change 와 무관하게 사용자 인터랙션 시에만 update.
@MainActor
private final class ControllerColumnState: ObservableObject {

    @Published var report: DJIVirtualJoystickReport?
    private var cancellable: AnyCancellable?

    /// throttle subscription 을 한 번만 설정. SwiftUI 가 view body 를 재계산해도
    /// `subscribe` 는 한 번만 활성화 — throttle 의 내부 timer state 가 reset 되지
    /// 않음.
    func subscribeIfNeeded(to publisher: Published<DJIVirtualJoystickReport?>.Publisher,
                            initialValue: DJIVirtualJoystickReport?) {
        if cancellable != nil { return }
        report = initialValue
        cancellable = publisher
            .throttle(for: .seconds(1.0 / 60.0),
                      scheduler: DispatchQueue.main,
                      latest: true)
            .sink { [weak self] in
                self?.report = $0
            }
    }

    func unsubscribe() {
        cancellable?.cancel()
        cancellable = nil
    }
}

@MainActor
private struct CockpitDJIControllerColumn: View {

    let watcher: DJIVirtualJoystickWatcher
    let profile: DJIBindingProfile
    let selectedAction: CockpitAction
    let selectedBinding: DJIInputBinding?
    let onTap: (DJIInputBinding) -> Void

    @StateObject private var state = ControllerColumnState()

    var body: some View {
        ScrollView {
            // `.equatable()` — visual struct 의 manual Equatable 로 동일 prop 일 때
            // body skip. 부모 column body 가 자주 reeval 되어도 throttled report 가
            // 같으면 visual body 는 skip — 최종 60 FPS 로 cap.
            CockpitDJIControllerVisual(
                report: state.report,
                profile: profile,
                onTap: onTap,
                selectedAction: selectedAction,
                selectedBinding: selectedBinding)
                .equatable()
                .padding(16)
        }
        .onAppear {
            state.subscribeIfNeeded(to: watcher.$lastReport,
                                     initialValue: watcher.lastReport)
        }
        .onDisappear {
            state.unsubscribe()
        }
    }
}

#endif
