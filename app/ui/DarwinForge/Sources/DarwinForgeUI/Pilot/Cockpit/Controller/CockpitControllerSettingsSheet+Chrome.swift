import SwiftUI

/// `CockpitControllerSettingsSheet` 의 크롬(툴바·푸터·배너) + 슬롯/저장 동작 —
/// 본 파일 800줄 규칙에 따른 분리. 상태는 본 struct 의 internal @State 를 공유한다.
extension CockpitControllerSettingsSheet {

    // MARK: - Top bar

    var topBar: some View {
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
            .pickerStyle(.segmented).frame(width: 210)
            Spacer()
            HStack(spacing: 10) {
                slotMenu
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

    /// 프로파일 슬롯 메뉴 (설계 §E) — 전환·복제·삭제. 영속화는 「저장」 시점.
    var slotMenu: some View {
        Menu {
            ForEach(Array(slots.profiles.enumerated()), id: \.offset) { index, profile in
                Button { switchSlot(index) } label: {
                    HStack {
                        Text(profile.name)
                        if index == slots.activeIndex { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button { duplicateSlot() } label: {
                Label("현재 프로파일 복제", systemImage: "plus.square.on.square")
            }
            .disabled(slots.profiles.count >= ControllerProfileSlots.maxSlots)
            Button(role: .destructive) { deleteSlot() } label: {
                Label("이 슬롯 삭제", systemImage: "trash")
            }
            .disabled(slots.profiles.count <= 1)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack").font(.system(size: 10))
                Text("슬롯 \(slots.activeIndex + 1)/\(slots.profiles.count)")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("프로파일 슬롯 — 여러 매핑 세트를 전환합니다.")
        .accessibilityIdentifier("cockpit.controller.profile.slots")
    }

    var presetMenu: some View {
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

    // MARK: - Footer

    var footer: some View {
        HStack {
            Button(role: .destructive) {
                editingProfile = .xbox; syncInspector(selectedAction); showNotice("기본값으로 재설정했어요.")
            } label: { Label("기본값으로 재설정", systemImage: "arrow.counterclockwise").font(.system(size: 12)) }
            .buttonStyle(.bordered)
            validationRail
            Spacer()
            Button("취소") { isPresented = false }.buttonStyle(.bordered)
            Button("저장") { attemptSave() }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// 검증 레일 (설계 §D) — 저장 게이트 상태를 항상 표시. 충돌 시 클릭하면
    /// 해당 충돌 지점으로 이동(필터 전환 + 컨트롤 선택).
    var validationRail: some View {
        let summary = BindingValidationSummary.from(editingProfile)
        return Button {
            guard !summary.isValid else { return }
            viewMode = .device
            actionFilter = summary.focusBinding == nil ? .safety : .conflict
            if let binding = summary.focusBinding { selectedBinding = binding }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: summary.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(summary.headline).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if !summary.isValid {
                    Text("클릭해 이동").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(summary.isValid
                ? Color.green.opacity(0.12) : Color.orange.opacity(0.16)))
            .foregroundStyle(summary.isValid ? Color.green : Color.orange)
        }
        .buttonStyle(.plain)
        .help(summary.isValid ? "저장 가능 상태입니다." : "이 문제를 해결해야 저장됩니다.")
        .accessibilityIdentifier("cockpit.controller.validation.rail")
    }

    func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.tint)
            Text(text).font(.system(size: 11))
            Spacer()
            if undoProfile != nil {
                Button("실행취소") { performUndo() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("cockpit.controller.binding.undo")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - 저장/토스트/슬롯 동작

    /// 저장 시도 — 안전 검증(E-STOP 필수) + 충돌 없음 통과해야 저장 (PRD §12.2/§19.1).
    /// 실제 게이트: 미통과 시 저장하지 않고 사유를 안내한다 (보여주기용 아님).
    func attemptSave() {
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
        let working = slots.updatingActive(editingProfile)
        ControllerBindingProfileStore.saveSlots(working)
        slots = working
        savedSlots = working
        dirtyBinding?.wrappedValue = false
        showNotice("프로파일을 저장했어요.")
        isPresented = false
    }

    func showNotice(_ text: String, undo: ControllerBindingProfile? = nil) {
        notice = text
        undoProfile = undo
        noticeTask?.cancel()
        // undo 가 걸린 토스트는 누를 시간을 더 준다.
        let duration: UInt64 = undo == nil ? 2_600_000_000 : 5_000_000_000
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: duration)
            notice = nil
            undoProfile = nil
        }
    }

    func performUndo() {
        guard let previous = undoProfile else { return }
        editingProfile = previous
        undoProfile = nil
        syncInspector(selectedAction)
        showNotice("직전 매핑 변경을 되돌렸어요.")
    }

    func updateDirty() {
        dirtyBinding?.wrappedValue = (slots.updatingActive(editingProfile) != savedSlots)
    }

    func switchSlot(_ index: Int) {
        guard index != slots.activeIndex else { return }
        slots = slots.updatingActive(editingProfile).selecting(index)
        editingProfile = slots.active
        syncInspector(selectedAction)
        showNotice("‘\(slots.active.name)’ 슬롯으로 전환했어요.")
    }

    func duplicateSlot() {
        slots = slots.updatingActive(editingProfile).addingDuplicateOfActive()
        editingProfile = slots.active
        syncInspector(selectedAction)
        showNotice("‘\(slots.active.name)’ 을 만들었어요 — 저장해야 유지됩니다.")
    }

    func deleteSlot() {
        let removedName = editingProfile.name
        slots = slots.removingActive()
        editingProfile = slots.active
        syncInspector(selectedAction)
        showNotice("‘\(removedName)’ 슬롯을 삭제했어요 — 저장해야 반영됩니다.")
    }
}
