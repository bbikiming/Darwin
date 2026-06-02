import SwiftUI

/// SwiftUI panel that renders a virtual joystick (mouse drag) + turn slider
/// + speed selector + emergency / recovery buttons, and pumps the resulting
/// `WalkingCommand` through the existing `WalkLabRCBridge`.
///
/// # 비유
///
/// 항공 시뮬레이터의 sidestick 패널 — 키보드/외부 컨트롤러가 없어도 마우스
/// 하나로 조종이 가능한 fallback. 입력 흐름은 게임패드/Tello 와 동일한
/// `WalkLabRCBridge` → `WalkLabSession` 경로를 따라가므로 안전 게이트 (cradle
/// / preflight / emergency / latency) 가 그대로 적용된다.
///
/// # 출력
///
/// 1. XY 조이스틱 → `bridge.handleMove(cmd, from: .virtualJoystick)`
/// 2. 회전 슬라이더 → 조이스틱의 `turn` 축으로 합쳐서 같이 전송
/// 3. 속도 슬라이더 → `VirtualJoystickMapper.speedScale` 로 amplitude 조정
/// 4. E-Stop 버튼 → `bridge.handleEmergency(from: .virtualJoystick)`
/// 5. 복구 버튼 → `bridge.handleRecovery(from: .virtualJoystick)`
@MainActor
public struct VirtualJoystickPilotPanel: View {

    private let bridge: WalkLabRCBridge

    /// 가장 최근 stick 좌표 (UI 표시 + telemetry용).
    @State private var stick: MacJoystickPad.Vector = .zero
    /// 회전 슬라이더 값 — [-1, +1]. +1 = 좌회전 (WalkLabPreset.turnLeft 부호와 일치).
    @State private var turn: Double = 0
    /// 속도 multiplier — [0.5, 1.5]. amplitude × speedScale 로 전송.
    @State private var speedScale: Double = 1.0
    /// 직전 명령이 stop 이었는지 — 0-vector 연속 호출 시 중복 dispatch 차단.
    @State private var lastWasStop: Bool = true

    public init(bridge: WalkLabRCBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            header
            HStack(alignment: .top, spacing: DFSpace.md) {
                MacJoystickPad(size: 156,
                               disabled: false,
                               onChange: handleStickChange,
                               onRelease: handleStickRelease)
                    .accessibilityIdentifier("pilot.virtualJoystick.pad")
                controls
            }
            actionRow
            statusLine
        }
        .padding(DFSpace.sm3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pilot.virtualJoystick.panel")
    }

    // MARK: - Sub views

    private var header: some View {
        HStack {
            Image(systemName: "dot.circle.and.cursorarrow")
                .foregroundStyle(Color.accentColor)
            Text("가상 조이스틱")
                .font(.headline)
            Spacer()
            Text("\(InputSource.virtualJoystick.label) · 마우스 드래그")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("회전").font(.caption.weight(.semibold))
                    Spacer()
                    Text(turnLabel).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $turn, in: -1.0...1.0,
                       onEditingChanged: { editing in
                           if !editing { turn = 0; dispatch() }
                       })
                    .accessibilityIdentifier("pilot.virtualJoystick.turn")
                    .onChange(of: turn) { _, _ in dispatch() }
                HStack {
                    Image(systemName: "arrow.turn.up.left").imageScale(.small)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.turn.up.right").imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("속도").font(.caption.weight(.semibold))
                    Spacer()
                    Text(String(format: "×%.2f", speedScale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speedScale, in: 0.5...1.5)
                    .accessibilityIdentifier("pilot.virtualJoystick.speed")
                    .onChange(of: speedScale) { _, _ in dispatch() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: DFSpace.sm) {
            Button {
                bridge.handleEmergency(from: .virtualJoystick)
            } label: {
                Label("긴급 정지", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pilot.virtualJoystick.estop")

            Button {
                bridge.handleRecovery(from: .virtualJoystick)
            } label: {
                Label("복구", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pilot.virtualJoystick.recover")
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: stickActiveIcon)
                .imageScale(.small)
                .foregroundStyle(stickActiveColor)
            Text(stickActiveLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Stick handling

    private func handleStickChange(_ v: MacJoystickPad.Vector) {
        stick = v
        dispatch()
    }

    private func handleStickRelease() {
        stick = .zero
        // Keep the turn slider value but stop the linear motion. If the turn
        // slider is also centred, dispatch a single stop frame and remember it.
        dispatch()
    }

    /// Build a `WalkingCommand` from the current stick + turn + speedScale and
    /// route it through the bridge. Skips no-op stop dispatches to avoid
    /// hammering the bridge / latency tracker.
    private func dispatch() {
        let cmd = VirtualJoystickMapper.map(
            x: stick.x, y: stick.y, turn: turn, speedScale: speedScale)
        if cmd.isStop {
            if lastWasStop { return }       // already at rest — single stop sent already
            lastWasStop = true
            bridge.handleMove(cmd, from: .virtualJoystick)
        } else {
            lastWasStop = false
            bridge.handleMove(cmd, from: .virtualJoystick)
        }
    }

    // MARK: - Derived UI

    private var turnLabel: String {
        let deg = Int((turn * 10).rounded())
        if deg == 0 { return "정지" }
        return deg > 0 ? "좌 \(deg)°" : "우 \(-deg)°"
    }

    private var stickActiveLabel: String {
        if stick.magnitude < 0.05 && abs(turn) < 0.05 { return "정지" }
        var parts: [String] = []
        if stick.y < -0.15 { parts.append("전진") }
        if stick.y > 0.15 { parts.append("후진") }
        if stick.x > 0.15 { parts.append("우") }
        if stick.x < -0.15 { parts.append("좌") }
        if turn > 0.15 { parts.append("좌회전") }
        if turn < -0.15 { parts.append("우회전") }
        return parts.isEmpty ? "정지" : parts.joined(separator: "·")
    }

    private var stickActiveIcon: String {
        stick.magnitude < 0.05 && abs(turn) < 0.05
            ? "circle.dashed"
            : "dot.radiowaves.left.and.right"
    }

    private var stickActiveColor: Color {
        stick.magnitude < 0.05 && abs(turn) < 0.05 ? .secondary : .accentColor
    }
}
