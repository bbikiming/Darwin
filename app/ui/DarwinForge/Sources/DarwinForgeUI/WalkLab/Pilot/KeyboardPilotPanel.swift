import SwiftUI

/// **v1.20.2 (2026-05-22) 사이클 8 — Keyboard pilot panel**.
///
/// 사용자가 macOS 키보드만으로 robot 을 게임 캐릭터처럼 조종하는 SwiftUI panel.
/// Tello / DJI 조종기 없이 즉시 작동 — PilotIntent 파이프라인의 첫 진입점.
///
/// # UX
///
/// 1. 패널이 focus 잡으면 WASD/QE/Space 입력 활성화 (테두리 변경으로 시각)
/// 2. 키 누름 → 가상 stick value (100) → WalkingCommand → bridge.handleMove
/// 3. 키 떼면 해당 채널 0 → 다른 키 누름 상태 유지 시 그 방향
/// 4. Space → bridge.handleEmergency (모든 모터 차단)
/// 5. 모든 키 떼면 자동 stop (전 채널 0)
///
/// # 키 표시
///
/// 패널 안 키 chip 들 — 현재 눌린 키는 강조 색.
///
/// # 안전
///
/// - 본 패널은 입력만 — 안전 검증은 `WalkLabRCBridge.process` 가 담당
/// - `session.current == .idle` 또는 `enabled == false` 시 stick 무시 (bridge 가 거부)
/// - Space 는 disabled 라도 emergency 발화 (bridge 가 무조건 통과)
@MainActor
public struct KeyboardPilotPanel: View {

    @Environment(WalkLabSession.self) private var session
    /// **v1.20.2.1 사이클 8-fix HIGH (코덱스)** — alt-tab / overlay 닫기 등 .up 누락 경로 안전망.
    /// scenePhase 가 .active 아닐 때 자동 release.
    @Environment(\.scenePhase) private var scenePhase
    @State private var pressedKeys: Set<PilotKey> = []
    @FocusState private var isFocused: Bool
    /// **v1.20.6 사이클 12** — overlay 열자마자 키 입력 활성. 게임 UX: 즉시 응답.
    private let autoFocusOnAppear: Bool

    public init(autoFocusOnAppear: Bool = true) {
        self.autoFocusOnAppear = autoFocusOnAppear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            keyMap
            presetShortcuts  // **v1.20.4 사이클 10** — 숫자 키 단축키 가이드.
            statusLine
        }
        .padding(12)
        .frame(width: 280)
        .background(DFColor.canvas.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? DFColor.accent : DFColor.textSecondary.opacity(0.3),
                        lineWidth: isFocused ? 2 : 1)
        )
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: Set(KeyboardPilotMapper.allHandledKeys),
                    phases: [.down, .up]) { press in
            handleKey(press)
        }
        .onChange(of: isFocused) { _, newValue in
            // focus 잃으면 모든 키 release — 멈춤.
            if !newValue {
                releaseAll()
            }
        }
        // **v1.20.6 사이클 12** — overlay 열림 직후 자동 focus → 게임 UX 즉시 응답.
        .onAppear {
            if autoFocusOnAppear {
                // 짧은 지연 후 focus — SwiftUI view lifecycle 안정화 대기.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    isFocused = true
                }
            }
        }
        // **v1.20.2.1 사이클 8-fix HIGH (코덱스)** — overlay 제거 / 뷰 dismount 시 release.
        // WalkLabView 가 `showingPilotOverlay = false` 처리할 때 view 가 즉시 사라짐 →
        // 그 시점에 .up 이 발화 안 했다면 마지막 amplitude 가 남음. onDisappear 가 보장.
        .onDisappear {
            releaseAll()
        }
        // **v1.20.2.1 사이클 8-fix HIGH (코덱스)** — alt-tab / 백그라운드 진입 시 자동 release.
        // scenePhase: .active → .inactive / .background 변화 = 사용자가 다른 앱으로 이동.
        // 그대로 두면 robot 이 계속 걸어감. release 가 panic switch.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                releaseAll()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isFocused ? "keyboard.fill" : "keyboard")
                .foregroundStyle(isFocused ? DFColor.accent : DFColor.textSecondary)
            Text("Keyboard Pilot")
                .font(.callout.weight(.semibold))
            Spacer()
            // **v1.20.5 사이클 11** — bridge.enabled=false 시 명시 "비활성" 배지.
            // 사용자가 키 입력 거부 사유 (TelloPilotHud 의 "활성" 토글 OFF) 를 사전 인지.
            if let bridge = session.pilotBridge, !bridge.enabled {
                Text("⚠️ Bridge 비활성")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DFColor.warning)
            } else if isFocused {
                Text("● 활성")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DFColor.accent)
            } else {
                Text("클릭으로 활성")
                    .font(.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    private var keyMap: some View {
        VStack(spacing: 4) {
            // 첫 행: Q W E  → 좌회전 / 전진 / 우회전
            HStack(spacing: 6) {
                keyChip(.turnLeft)
                keyChip(.forward)
                keyChip(.turnRight)
            }
            // 두 번째 행: A S D → 좌측 / 후진 / 우측
            HStack(spacing: 6) {
                keyChip(.left)
                keyChip(.backward)
                keyChip(.right)
            }
            // 세 번째 행: Space (전체 너비)
            keyChip(.emergency, fullWidth: true)
        }
    }

    private func keyChip(_ key: PilotKey, fullWidth: Bool = false) -> some View {
        let pressed = pressedKeys.contains(key)
        let isDangerous = key == .emergency
        let activeColor: Color = isDangerous ? DFColor.danger : DFColor.accent
        return VStack(spacing: 2) {
            Text(key.label)
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(pressed ? .white : DFColor.textPrimary)
            Text(key.koreanDescription)
                .font(.caption2)
                .foregroundStyle(pressed ? .white.opacity(0.9) : DFColor.textSecondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, fullWidth ? 12 : 8)
        .frame(maxWidth: fullWidth ? .infinity : 72)
        .background(pressed ? activeColor : DFColor.textSecondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(pressed ? activeColor : DFColor.textSecondary.opacity(0.2),
                        lineWidth: pressed ? 1.5 : 0.5)
        )
    }

    // MARK: - Preset shortcuts (Cycle 10)

    /// **v1.20.4 사이클 10** — 숫자 키 0-7 preset 매핑 가이드.
    /// 게임 컨트롤러 D-pad 처럼 동작: 1번 키 = march, 2번 = slowWalk, 등.
    private var presetShortcuts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preset 단축키 (0=정지)")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    presetShortcutChip(digit: i)
                }
            }
        }
    }

    private func presetShortcutChip(digit: Int) -> some View {
        let key = KeyEquivalent(Character(String(digit)))
        let preset = KeyboardPilotMapper.resolvePreset(key)
        let isActive = preset.map { session.current == $0 } ?? false
        return VStack(spacing: 1) {
            Text("\(digit)")
                .font(.caption2.monospaced().weight(.bold))
            Text(preset?.label.prefix(3).uppercased() ?? "—")
                .font(.system(size: 8))
                .foregroundStyle(DFColor.textSecondary)
        }
        .frame(width: 32, height: 30)
        .background(isActive ? DFColor.accent.opacity(0.25) : DFColor.textSecondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isActive ? DFColor.accent : DFColor.textSecondary.opacity(0.2),
                        lineWidth: isActive ? 1.0 : 0.5)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if let msg = session.pilotBridge?.safetyMessage {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(DFColor.warning)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(DFColor.warning)
                    .lineLimit(2)
            }
        } else if isFocused && !pressedKeys.isEmpty {
            Text(activeKeysSummary)
                .font(.caption.monospaced())
                .foregroundStyle(DFColor.accent)
        } else if !isFocused {
            Text("패널 클릭 후 WASD/QE 키로 조종, Space 긴급정지")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
        } else {
            Text("키를 눌러 조종")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    private var activeKeysSummary: String {
        let labels = pressedKeys
            .sorted { $0.label < $1.label }
            .map(\.label)
        return "활성: " + labels.joined(separator: " + ")
    }

    // MARK: - Key handling

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // **v1.20.4 사이클 10** — 숫자 키 (0-7) → preset 단축키. down 만 처리 (toggle 아님).
        // direction 키보다 먼저 검사 — resolve(0) 는 nil 이지만 명시적으로 ordering.
        if press.phase == .down, let preset = KeyboardPilotMapper.resolvePreset(press.key) {
            session.pilotBridge?.handlePreset(preset, from: .keyboard)
            return .handled
        }
        guard let pilotKey = KeyboardPilotMapper.resolve(press.key) else {
            return .ignored
        }
        // emergency 는 down 즉시 발화 (up 은 무시 — 한 번 발화하면 끝).
        if pilotKey == .emergency && press.phase == .down {
            session.pilotBridge?.handleEmergency(from: .keyboard)
            // **v1.20.2.1 사이클 8-fix MEDIUM (코덱스)** — emergency 시 전체 pressedKeys clear.
            // 종전: `.emergency` 만 제거 → W 누른 채 Space 시 W 가 stale 한 상태로 UI 에 남음.
            // recovery 후 다음 키 이벤트와 섞이는 race 차단.
            pressedKeys.removeAll()
            return .handled
        }
        if press.phase == .down {
            pressedKeys.insert(pilotKey)
        } else {
            pressedKeys.remove(pilotKey)
        }
        sendIntent()
        return .handled
    }

    private func sendIntent() {
        guard let bridge = session.pilotBridge else { return }
        // **v1.20.2.1 사이클 8-fix MEDIUM (코덱스)** — Tello path 와 동일하게 bridge.scale 적용.
        // 종전: default scale → 사용자가 settings 에서 sensitivity 조정해도 keyboard 만 무시됨.
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: pressedKeys, scale: bridge.scale)
        bridge.handleMove(cmd, from: .keyboard)
    }

    private func releaseAll() {
        if !pressedKeys.isEmpty {
            pressedKeys.removeAll()
            // focus 잃었으므로 강제 stop.
            session.pilotBridge?.handleStop(from: .keyboard)
        }
    }
}
