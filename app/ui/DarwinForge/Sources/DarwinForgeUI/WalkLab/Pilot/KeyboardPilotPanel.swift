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
    @State private var pressedKeys: Set<PilotKey> = []
    @FocusState private var isFocused: Bool

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            keyMap
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
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isFocused ? "keyboard.fill" : "keyboard")
                .foregroundStyle(isFocused ? DFColor.accent : DFColor.textSecondary)
            Text("Keyboard Pilot")
                .font(.callout.weight(.semibold))
            Spacer()
            if isFocused {
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
        guard let pilotKey = KeyboardPilotMapper.resolve(press.key) else {
            return .ignored
        }
        // emergency 는 down 즉시 발화 (up 은 무시 — 한 번 발화하면 끝).
        if pilotKey == .emergency && press.phase == .down {
            session.pilotBridge?.handleEmergency(from: .keyboard)
            pressedKeys.remove(.emergency)  // emergency 는 toggle 아님 — 즉시 release.
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
        let cmd = KeyboardPilotMapper.mapToCommand(pressedKeys: pressedKeys)
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
