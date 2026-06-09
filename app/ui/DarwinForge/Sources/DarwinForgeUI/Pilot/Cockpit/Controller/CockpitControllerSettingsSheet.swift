import SwiftUI

/// 범용 컨트롤러 세팅 시트 — DJI 매핑 시트의 3-컬럼 레이아웃/사용성을 그대로 따른
/// 메인 UI. M1 프로파일(바인딩·튜닝·activator) + M2 추상화(리졸버·드라이버) +
/// 가상 컨트롤러를 통합한다.
///
/// 좌: 동작 할당 · 중앙: 게임패드 다이어그램(라이브 하이라이트·클릭-투-바인드) + 가상 입력 ·
/// 우: Inspector(감도/반응곡선/Invert/모드 — 실제 `ControllerAxisTuning`·`ActivatorType` 에 반영).
/// 가상 패드 입력은 드라이버 경유로 cockpit 에 30Hz 주입되어 로봇이 실시간 반응한다.
@MainActor
public struct CockpitControllerSettingsSheet: View {
    @ObservedObject var cockpit: CockpitState
    @Binding var isPresented: Bool

    /// 통합 「컨트롤러 연결」 시트에 박혀 렌더될 때 true — 외곽 frame/타이틀/닫기는
    /// 컨테이너가 제공하므로 본 시트는 슬림 pane 툴바(viewMode·preset)만 그린다.
    private let embedded: Bool

    /// 통합 시트가 미저장 편집 여부를 감지하도록 보고하는 binding (없으면 무시).
    private let dirtyBinding: Binding<Bool>?

    @StateObject private var source = VirtualControllerSource()
    @State private var driver: CockpitControllerDriver?

    @State private var editingProfile: ControllerBindingProfile
    /// 마지막으로 저장(또는 로드)된 프로파일 — editingProfile 과 다르면 dirty.
    @State private var savedBaseline: ControllerBindingProfile
    @State private var viewMode: ViewMode = .device
    @State private var selectedAction: CockpitAction = .moveForward
    @State private var selectedBinding: ControllerBinding?
    @State private var listening: Bool = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    /// 좌측 액션 목록 검색어 + 필터 (PRD §7.6).
    @State private var searchText: String = ""
    @State private var actionFilter: ActionFilter = .all

    enum ActionFilter: String, CaseIterable, Identifiable {
        case all = "전체", mapped = "매핑됨", unmapped = "미설정", conflict = "충돌", safety = "안전"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .mapped: return "checkmark.circle"
            case .unmapped: return "circle.dashed"
            case .conflict: return "exclamationmark.triangle"
            case .safety: return "exclamationmark.octagon"
            }
        }
    }

    public enum ViewMode: String, CaseIterable, Identifiable {
        case device = "장치", list = "목록"
        public var id: String { rawValue }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case xbox = "Xbox / RG G01", dualSense = "DualSense", empty = "비어 있음"
        var id: String { rawValue }
        var profile: ControllerBindingProfile {
            switch self {
            case .xbox: return .xbox
            case .dualSense: return .dualSense
            case .empty: return .empty
            }
        }
    }

    public init(cockpit: CockpitState,
                isPresented: Binding<Bool>,
                embedded: Bool = false,
                dirty: Binding<Bool>? = nil) {
        self.cockpit = cockpit
        self._isPresented = isPresented
        self.embedded = embedded
        self.dirtyBinding = dirty
        let loaded = ControllerBindingProfileStore.load()
        self._editingProfile = State(initialValue: loaded)
        self._savedBaseline = State(initialValue: loaded)
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if let notice { banner(notice) }
            Divider()
            if viewMode == .device { deviceColumns } else { listMode }
            Divider()
            footer
        }
        // embedded: 컨테이너가 준 공간을 채움 · standalone: HIG Preferences large 고정 크기.
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .frame(width: embedded ? nil : 1100, height: embedded ? nil : 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { startDriver(); syncInspector(selectedAction) }
        .onDisappear { stopDriver(); noticeTask?.cancel() }
        .onChange(of: editingProfile) { _, p in
            driver?.profile = p
            dirtyBinding?.wrappedValue = (p != savedBaseline)
        }
        .onChange(of: source.snapshot) { _, snap in handleListen(snap) }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            if embedded {
                Spacer()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 14)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("컨트롤러 매핑").font(.system(size: 14, weight: .semibold))
                        Text("각 동작에 매핑할 컨트롤러 입력을 선택하세요.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 140)
            Spacer()
            HStack(spacing: 10) {
                presetMenu
                if !embedded {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 22, height: 22)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("닫기 (ESC)")
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, embedded ? 8 : 12)
    }

    private var presetMenu: some View {
        Menu {
            ForEach(Preset.allCases) { preset in
                Button {
                    editingProfile = preset.profile
                    syncInspector(selectedAction)
                    showNotice("\(preset.rawValue) 프리셋을 적용했어요.")
                } label: { Label(preset.rawValue, systemImage: "gamecontroller") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 10))
                Text(editingProfile.name).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: - Device 3-column

    private var deviceColumns: some View {
        HStack(spacing: 0) {
            actionColumn.frame(width: 280)
            Divider()
            centerColumn.frame(maxWidth: .infinity)
            Divider()
            inspectorColumn.frame(width: 300)
        }
    }

    // MARK: - Left: 동작 할당

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("동작 할당").font(.system(size: 13, weight: .semibold))
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("동작을 선택한 뒤 가운데 다이어그램의 입력을 클릭하면 매핑됩니다.")
                Spacer()
                conflictBadge
            }
            searchFilterBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let groups = CockpitAction.Group.allCases.filter { !filteredActions(in: $0).isEmpty }
                    if groups.isEmpty {
                        Text("결과 없음").font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        ForEach(groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(groupTitle(group)).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                VStack(spacing: 4) {
                                    ForEach(filteredActions(in: group), id: \.self) { actionCard($0) }
                                }
                            }
                        }
                    }
                }.padding(.bottom, 8)
            }
        }
        .padding(16)
    }

    private var searchFilterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("동작 검색", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            HStack(spacing: 5) {
                ForEach(ActionFilter.allCases) { f in
                    Button { actionFilter = f } label: {
                        Text(f.rawValue).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(actionFilter == f
                                ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10)))
                            .foregroundStyle(actionFilter == f ? Color.accentColor : Color.secondary)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var conflictBadge: some View {
        let conflicts = editingProfile.conflicts()
        return Group {
            if conflicts.isEmpty {
                Label("충돌 없음", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Label("\(conflicts.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).help(conflictSummary(conflicts))
            }
        }.font(.system(size: 10, weight: .medium))
    }

    private func actionCard(_ action: CockpitAction) -> some View {
        let isSelected = selectedAction == action
        let binding = editingProfile.bindings[action] ?? .unbound
        return Button {
            selectedAction = action; syncInspector(action)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: actionIcon(action)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                Text(action.label).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 4)
                bindingBadge(binding)
                Circle().fill(binding.isUnbound ? Color.secondary.opacity(0.35) : Color.green)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private func bindingBadge(_ binding: ControllerBinding) -> some View {
        Text(binding.displayLabel)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(binding.isUnbound ? Color.secondary.opacity(0.7) : .green)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(binding.isUnbound ? Color.secondary.opacity(0.10) : Color.green.opacity(0.12)))
    }

    // MARK: - Center: 다이어그램 + 가상 입력

    private var centerColumn: some View {
        VStack(spacing: 14) {
            HStack {
                Text("컨트롤러").font(.system(size: 13, weight: .semibold))
                Spacer()
                listenButton
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("가상 패드").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // 다이어그램+가상패드는 세로로 길어 작은 화면에선 내부 스크롤 — 어떤 창
            // 높이에서도 콘텐츠가 잘리는 대신 스크롤된다 (헤더 행은 고정).
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    RGG01ControllerVisual(
                        snapshot: source.snapshot, profile: editingProfile,
                        selectedBinding: selectedBinding,
                        onTap: { onElementTap($0) })
                    Text("아래 가상 패드로 입력 → 로봇 실시간 반응 · 다이어그램 클릭 = 선택 동작에 매핑")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    VirtualControllerPad(source: source)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                    injectionReadout
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
        }
        .padding(16)
    }

    private var listenButton: some View {
        Button {
            listening.toggle()
            if listening { showNotice("Listen 중 — 가상 패드의 입력을 움직이면 ‘\(selectedAction.label)’ 에 매핑돼요.") }
        } label: {
            Label(listening ? "입력 대기중…" : "Listen", systemImage: listening ? "dot.radiowaves.left.and.right" : "scope")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(listening ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("선택한 동작에 press-to-bind")
    }

    private var injectionReadout: some View {
        HStack(spacing: 16) {
            metric("주입 L-스틱", String(format: "%+.2f, %+.2f", cockpit.leftStick.x, cockpit.leftStick.y))
            metric("회전", String(format: "%+.2f", cockpit.rightStick.x))
            metric("명령", commandText)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.green)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commandText: String {
        let c = cockpit.lastCommand
        return c.isStop ? "정지" : String(format: "보행 %.0f/%.0f/%.0f", c.strideMm, c.sideMm, c.turnDeg)
    }

    // MARK: - Right: Inspector

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("선택된 컨트롤").font(.system(size: 13, weight: .semibold))
                controlSummary
                mappedActionSection
                inputTypeSection
                if isAxisSelected {
                    sensitivitySection
                    deadzoneSection
                    responseCurveSection
                    invertSection
                } else if isButtonSelected {
                    modeSection
                }
                actionButtons
            }
            .padding(16)
        }
    }

    private var controlSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("컨트롤").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: bindingIcon).font(.system(size: 12)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bindingPrimary).font(.system(size: 12, weight: .semibold))
                    Text(bindingSubtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)))
        }
    }

    private var mappedActionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("매핑된 동작").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Menu {
                ForEach(CockpitAction.Group.allCases, id: \.self) { group in
                    Section(groupTitle(group)) {
                        ForEach(actions(in: group), id: \.self) { a in
                            Button {
                                if let b = selectedBinding { apply(b, to: a); selectedAction = a }
                            } label: {
                                HStack { Image(systemName: actionIcon(a)); Text(a.label)
                                    if actionForBinding == a { Spacer(); Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
            } label: { dropdownLabel(actionForBinding?.label ?? "매핑 없음", disabled: selectedBinding == nil) }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .disabled(selectedBinding == nil)
        }
    }

    private var inputTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("입력 유형").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            dropdownLabel(inputTypeLabel, disabled: true)
        }
    }

    private var sensitivitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("감도").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("0").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: sensitivityBinding, in: 0...100)
                Text("100").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Text("\(Int(sensitivityBinding.wrappedValue))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private var deadzoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("데드존 (Deadzone)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("0%").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: deadzoneBinding, in: 0...40)
                Text("\(Int(deadzoneBinding.wrappedValue))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private var responseCurveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("반응 곡선").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Menu {
                ForEach(CurvePreset.allCases) { c in
                    Button { setExpo(c.expo) } label: {
                        HStack { Text(c.rawValue); if curvePresetForExpo == c { Spacer(); Image(systemName: "checkmark") } }
                    }
                }
            } label: { dropdownLabel(curvePresetForExpo.rawValue, disabled: false) }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var invertSection: some View {
        Toggle(isOn: invertBinding) { Text("축 반전 (Invert)").font(.system(size: 11)) }
            .toggleStyle(.switch)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("모드 (Activator)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Menu {
                ForEach(ActivatorPreset.allCases) { m in
                    Button { setActivator(m.type) } label: {
                        HStack { Text(m.rawValue); if activatorPreset == m { Spacer(); Image(systemName: "checkmark") } }
                    }
                }
            } label: { dropdownLabel(activatorPreset.rawValue, disabled: actionForBinding == nil) }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .disabled(actionForBinding == nil)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                if let a = actionForBinding { apply(.unbound, to: a) }
            } label: { Text("매핑 해제").font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.bordered)
            .disabled(actionForBinding == nil || actionForBinding?.isSafetyCritical == true)

            Button(role: .destructive) {
                editingProfile = .xbox; syncInspector(selectedAction); showNotice("기본값(Xbox)으로 복원했어요.")
            } label: { Text("기본값 복원").font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.bordered).tint(.red)
        }
    }

    private func dropdownLabel(_ text: String, disabled: Bool) -> some View {
        HStack {
            Text(text).font(.system(size: 12)).foregroundStyle(disabled ? .secondary : .primary).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(disabled ? 0.05 : 0.10))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)))
    }

    // MARK: - List mode

    private var listMode: some View {
        Form {
            ForEach(CockpitAction.Group.allCases, id: \.self) { group in
                Section(groupTitle(group)) {
                    ForEach(actions(in: group), id: \.self) { action in
                        LabeledContent(action.label) {
                            Text((editingProfile.bindings[action] ?? .unbound).displayLabel)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                editingProfile = .xbox; syncInspector(selectedAction); showNotice("기본값으로 재설정했어요.")
            } label: { Label("기본값으로 재설정", systemImage: "arrow.counterclockwise").font(.system(size: 12)) }
            .buttonStyle(.bordered)
            Spacer()
            Button("취소") { isPresented = false }.buttonStyle(.bordered)
            Button("저장") { attemptSave() }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.tint)
            Text(text).font(.system(size: 11)); Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Inspector 표시 헬퍼

    private var isAxisSelected: Bool { if case .axis = selectedBinding { return true }; return false }
    private var isButtonSelected: Bool { if case .button = selectedBinding { return true }; return false }
    private var selectedAxisIndex: Int? { if case .axis(let i, _) = selectedBinding { return i }; return nil }
    private var actionForBinding: CockpitAction? {
        guard let b = selectedBinding else { return nil }
        return editingProfile.bindings.first { $0.value == b }?.key
    }

    private var bindingIcon: String {
        switch selectedBinding {
        case .axis: return "circle.lefthalf.filled"
        case .button: return "rectangle.fill"
        default: return "questionmark.square.dashed"
        }
    }
    private var bindingPrimary: String { selectedBinding?.displayLabel ?? "선택되지 않음" }
    private var bindingSubtitle: String {
        switch selectedBinding {
        case .axis: return "아날로그 축"
        case .button: return "디지털 버튼"
        default: return "다이어그램에서 입력을 클릭하세요."
        }
    }
    private var inputTypeLabel: String {
        switch selectedBinding {
        case .axis: return "축 입력 (Axis)"
        case .button: return "버튼 (Button)"
        default: return "—"
        }
    }

    // 감도 ↔ sensitivity(0.1…3.0), 50 = 1.0
    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { (tuningForSelected()?.sensitivity ?? 1.0) * 50.0 },
            set: { newVal in updateTuning { $0.sensitivity = max(0.1, min(3.0, newVal / 50.0)) } })
    }

    private var invertBinding: Binding<Bool> {
        Binding(get: { tuningForSelected()?.invert ?? false },
                set: { newVal in updateTuning { $0.invert = newVal } })
    }

    /// 데드존 ↔ innerDeadzone(0…0.4). % 표기. `shaped()` 가 실제로 사용 → 입력에 반영됨.
    private var deadzoneBinding: Binding<Double> {
        Binding(
            get: { (tuningForSelected()?.innerDeadzone ?? ControllerAxisTuning.defaultInnerDeadzone) * 100.0 },
            set: { newVal in updateTuning { $0.innerDeadzone = max(0, min(0.4, newVal / 100.0)) } })
    }

    enum CurvePreset: String, CaseIterable, Identifiable {
        case linear = "선형", smooth = "부드러움", precise = "정밀"
        var id: String { rawValue }
        var expo: Double { self == .linear ? 0.0 : (self == .smooth ? 0.5 : 0.85) }
    }
    private var curvePresetForExpo: CurvePreset {
        let e = tuningForSelected()?.expo ?? 0
        if e < 0.25 { return .linear }
        if e < 0.7 { return .smooth }
        return .precise
    }

    enum ActivatorPreset: String, CaseIterable, Identifiable {
        case hold = "홀드", start = "누름", toggle = "토글", longPress = "길게"
        var id: String { rawValue }
        var type: ActivatorType {
            switch self {
            case .hold: return .hold
            case .start: return .start
            case .toggle: return .toggle
            case .longPress: return .longPress(thresholdMs: 500)
            }
        }
    }
    private var activatorPreset: ActivatorPreset {
        guard let a = actionForBinding, let t = editingProfile.activators[a] else { return .hold }
        switch t {
        case .hold: return .hold
        case .start: return .start
        case .toggle: return .toggle
        case .longPress: return .longPress
        default: return .hold
        }
    }

    // MARK: - 편집 동작

    private func tuningForSelected() -> ControllerAxisTuning? {
        guard let i = selectedAxisIndex else { return nil }
        return editingProfile.axisTuning[i] ?? ControllerAxisTuning()
    }

    private func updateTuning(_ mutate: (inout ControllerAxisTuning) -> Void) {
        guard let i = selectedAxisIndex else { return }
        var t = editingProfile.axisTuning[i] ?? ControllerAxisTuning()
        mutate(&t)
        var p = editingProfile
        p.axisTuning[i] = t
        editingProfile = p
    }

    private func setExpo(_ expo: Double) { updateTuning { $0.expo = expo } }

    private func setActivator(_ type: ActivatorType) {
        guard let a = actionForBinding else { return }
        var p = editingProfile
        p.activators[a] = type
        editingProfile = p
    }

    private func onElementTap(_ binding: ControllerBinding) {
        selectedBinding = binding
        // action-first: 현재 선택 동작에 즉시 매핑.
        apply(binding, to: selectedAction)
    }

    private func apply(_ binding: ControllerBinding, to action: CockpitAction) {
        let (next, result) = editingProfile.setting(binding, for: action)
        switch result {
        case .applied:
            editingProfile = next
        case .appliedWithSwap(let swapped):
            editingProfile = next
            showNotice("\(swapped.map(\.label).joined(separator: ", ")) 의 매핑을 해제하고 옮겼어요.")
        case .rejectedSafetyUnbound(let a):
            showNotice("‘\(a.label)’ 은 안전 동작이라 해제할 수 없어요.")
        case .rejectedSafetyStolen(let a):
            showNotice("‘\(a.label)’(안전)에 할당된 입력이라 가져올 수 없어요.")
        }
        selectedBinding = binding
    }

    private func handleListen(_ snapshot: ControllerSnapshot) {
        guard listening, let captured = ControllerBindingCapture.detect(snapshot) else { return }
        listening = false
        apply(captured, to: selectedAction)
        showNotice("‘\(selectedAction.label)’ 에 \(captured.displayLabel) 매핑됨.")
    }

    private func syncInspector(_ action: CockpitAction) {
        selectedBinding = editingProfile.bindings[action]
    }

    /// 저장 시도 — 안전 검증(E-STOP 필수) + 충돌 없음 통과해야 저장 (PRD §12.2/§19.1).
    /// 실제 게이트: 미통과 시 저장하지 않고 사유를 안내한다 (보여주기용 아님).
    private func attemptSave() {
        if (editingProfile.bindings[.emergencyStop] ?? .unbound).isUnbound {
            actionFilter = .safety
            showNotice("⚠️ 긴급 정지(E-STOP)가 비어 있어 저장할 수 없습니다. 안전 동작을 먼저 매핑하세요.")
            return
        }
        let conflicts = editingProfile.conflicts()
        if !conflicts.isEmpty {
            actionFilter = .conflict
            showNotice("⚠️ 입력 충돌 \(conflicts.count)건을 해결해야 저장됩니다.")
            return
        }
        ControllerBindingProfileStore.save(editingProfile)
        savedBaseline = editingProfile
        dirtyBinding?.wrappedValue = false
        showNotice("프로파일을 저장했어요.")
        isPresented = false
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            notice = nil
        }
    }

    private func groupTitle(_ g: CockpitAction.Group) -> String {
        switch g {
        case .movement: return "이동 제어"
        case .rotation: return "회전 제어"
        case .head: return "머리 제어"
        case .safety: return "안전 제어"
        }
    }
    private func actions(in group: CockpitAction.Group) -> [CockpitAction] {
        CockpitAction.allCases.filter { $0.group == group }
    }

    /// 검색어 + 필터 적용 (PRD §7.6). 그룹·동작명·매핑값·안전여부·충돌여부로 거른다.
    private func filteredActions(in group: CockpitAction.Group) -> [CockpitAction] {
        let conflictSet = Set(editingProfile.conflicts().flatMap { c -> [CockpitAction] in
            switch c {
            case .duplicateInput(_, let acts): return acts
            case .safetyCriticalUnbound(let a): return [a]
            }
        })
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CockpitAction.allCases.filter { a in
            guard a.group == group else { return false }
            let binding = editingProfile.bindings[a] ?? .unbound
            switch actionFilter {
            case .all: break
            case .mapped:   if binding.isUnbound { return false }
            case .unmapped: if !binding.isUnbound { return false }
            case .conflict: if !conflictSet.contains(a) { return false }
            case .safety:   if !a.isSafetyCritical { return false }
            }
            if !q.isEmpty {
                let hay = "\(a.label) \(groupTitle(group)) \(binding.displayLabel)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }
    private func conflictSummary(_ conflicts: [ControllerBindingConflict]) -> String {
        conflicts.map { c in
            switch c {
            case .duplicateInput(let b, let acts): return "중복 \(b.displayLabel): \(acts.map(\.label).joined(separator: ", "))"
            case .safetyCriticalUnbound(let a): return "안전 미할당: \(a.label)"
            }
        }.joined(separator: "\n")
    }
    private func actionIcon(_ a: CockpitAction) -> String {
        switch a {
        case .moveForward: return "arrow.up"
        case .moveBackward: return "arrow.down"
        case .strafeLeft: return "arrow.left"
        case .strafeRight: return "arrow.right"
        case .turnLeft: return "arrow.counterclockwise"
        case .turnRight: return "arrow.clockwise"
        case .headPanLeft: return "arrowshape.left"
        case .headPanRight: return "arrowshape.right"
        case .headTiltUp: return "arrowshape.up"
        case .headTiltDown: return "arrowshape.down"
        case .ballTracking: return "scope"
        case .emergencyStop: return "exclamationmark.octagon.fill"
        case .recover: return "arrow.uturn.up"
        }
    }

    // MARK: - 드라이버 lifecycle

    private func startDriver() {
        let d = CockpitControllerDriver(state: cockpit, source: source, profile: editingProfile)
        d.start(); driver = d
    }
    private func stopDriver() {
        driver?.stop(); driver = nil; source.resetAll(); cockpit.release()
    }
}
