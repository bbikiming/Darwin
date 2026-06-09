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

    // NOTE: 파일 분리(+Support/+Chrome)에서 접근해야 하는 상태는 internal —
    //       모듈 밖으로는 노출되지 않는다 (struct 멤버 기본 접근 수준).

    /// 통합 「컨트롤러 연결」 시트에 박혀 렌더될 때 true — 외곽 frame/타이틀/닫기는
    /// 컨테이너가 제공하므로 본 시트는 슬림 pane 툴바(viewMode·preset)만 그린다.
    let embedded: Bool

    /// 통합 시트가 미저장 편집 여부를 감지하도록 보고하는 binding (없으면 무시).
    let dirtyBinding: Binding<Bool>?

    @StateObject private var source = VirtualControllerSource()
    @State private var driver: CockpitControllerDriver?

    @State var editingProfile: ControllerBindingProfile
    /// 프로파일 슬롯 모음 (설계 §E) — 활성 슬롯의 편집 버퍼가 editingProfile.
    /// 슬롯 전환 시 편집 내용은 메모리에 유지되고, 「저장」 때만 영속화된다.
    @State var slots: ControllerProfileSlots
    /// 마지막으로 저장(또는 로드)된 슬롯 모음 — 작업본과 다르면 dirty.
    @State var savedSlots: ControllerProfileSlots
    @State var viewMode: ViewMode = .device
    @State var selectedAction: CockpitAction = .moveForward
    @State var selectedBinding: ControllerBinding?
    @State private var listening: Bool = false
    @State var notice: String?
    @State var noticeTask: Task<Void, Never>?
    /// 실패드 입력 → 컨트롤 선택 (Steam Input 패턴) — 엣지 추적.
    @State private var pressTracker = PressToSelectTracker()
    /// 직전 바인딩 변경의 실행취소 스냅샷 — 토스트의 「실행취소」가 복원.
    @State var undoProfile: ControllerBindingProfile?
    /// 좌측 액션 목록 검색어 + 필터 (PRD §7.6).
    @State private var searchText: String = ""
    @State var actionFilter: ActionFilter = .all

    public init(cockpit: CockpitState,
                isPresented: Binding<Bool>,
                embedded: Bool = false,
                dirty: Binding<Bool>? = nil) {
        self.cockpit = cockpit
        self._isPresented = isPresented
        self.embedded = embedded
        self.dirtyBinding = dirty
        let loaded = ControllerBindingProfileStore.loadSlots()
        self._slots = State(initialValue: loaded)
        self._savedSlots = State(initialValue: loaded)
        self._editingProfile = State(initialValue: loaded.active)
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if let notice { banner(notice) }
            Divider()
            switch viewMode {
            case .device: deviceColumns
            case .list: listMode
            case .tester:
                ControllerTesterPane(source: source, cockpit: cockpit,
                                     profile: editingProfile, selectedBinding: $selectedBinding)
            }
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
            updateDirty()
        }
        .onChange(of: slots) { _, _ in updateDirty() }
        .onChange(of: source.snapshot) { _, snap in
            if listening { handleListen(snap) } else { handlePressToSelect(snap) }
        }
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
                    ZStack {
                        RGG01ControllerVisual(
                            snapshot: source.snapshot, profile: editingProfile,
                            selectedBinding: selectedBinding,
                            onTap: { onElementTap($0) })
                        ControllerCalloutOverlay(
                            snapshot: source.snapshot, profile: editingProfile,
                            selectedBinding: selectedBinding,
                            onSelect: { selectedBinding = $0 })
                    }
                    Text("입력을 누르면 해당 컨트롤이 선택 · 다이어그램 클릭 = 선택 동작에 매핑 · 라벨 탭 = 선택만")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    VirtualControllerPad(source: source)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                    CockpitInjectionReadout(cockpit: cockpit)
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
                    AxisResponseCurveView(
                        tuning: tuningForSelected() ?? ControllerAxisTuning(),
                        rawValue: selectedAxisIndex.map { source.snapshot.axis($0) } ?? 0)
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
            } label: { dropdownLabel(activatorPreset.rawValue, disabled: activatorLocked) }
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .disabled(activatorLocked)
            if actionForBinding == .emergencyStop {
                Text("E-STOP 은 안전상 누름 즉시 발화 — 모드 변경 불가")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    /// E-STOP 은 드라이버가 activator 를 무시하고 rising-edge 즉시 발화하므로
    /// 설정 자체를 잠가 거짓 UI 를 막는다.
    private var activatorLocked: Bool {
        actionForBinding == nil || actionForBinding == .emergencyStop
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

    private var curvePresetForExpo: CurvePreset {
        let e = tuningForSelected()?.expo ?? 0
        if e < 0.25 { return .linear }
        if e < 0.7 { return .smooth }
        return .precise
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
        let previous = editingProfile
        let (next, result) = editingProfile.setting(binding, for: action)
        if BindingChangeFeedback.isUndoable(result) { editingProfile = next }
        showNotice(BindingChangeFeedback.message(action: action, binding: binding, result: result),
                   undo: BindingChangeFeedback.isUndoable(result) ? previous : nil)
        selectedBinding = binding
    }

    private func handlePressToSelect(_ snapshot: ControllerSnapshot) {
        let (next, selection) = pressTracker.updated(with: snapshot)
        pressTracker = next
        if let selection { selectedBinding = selection }
    }

    private func handleListen(_ snapshot: ControllerSnapshot) {
        guard listening, let captured = ControllerBindingCapture.detect(snapshot) else { return }
        listening = false
        // apply() 가 "{입력} ← {동작}" 토스트 + 실행취소를 띄운다.
        apply(captured, to: selectedAction)
    }

    func syncInspector(_ action: CockpitAction) {
        selectedBinding = editingProfile.bindings[action]
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
    // MARK: - 드라이버 lifecycle

    private func startDriver() {
        let d = CockpitControllerDriver(state: cockpit, source: source, profile: editingProfile)
        d.start(); driver = d
    }
    private func stopDriver() {
        driver?.stop(); driver = nil; source.resetAll(); cockpit.release()
    }
}
