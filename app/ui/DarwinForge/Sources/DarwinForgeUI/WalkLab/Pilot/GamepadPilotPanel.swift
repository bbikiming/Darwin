import SwiftUI

/// **v1.21.1 (2026-05-22) — GamepadPilotAdapter 의 SwiftUI panel (wire-up)**.
///
/// PS4 / Xbox / Nimbus 컨트롤러 입력을 시각화 + 사용자가 adapter 의 lifecycle
/// 을 토글 가능. KeyboardPilotPanel 과 동일 design language (DFColor / DFSpace /
/// DFFont) — 같은 overlay 안에서 자연스러운 UX 일관성.
///
/// # 비유
///
/// 음악 콘솔의 MIDI 입력 모니터 — 외부 컨트롤러가 어떤 물리 장치든 (USB / BT)
/// 한 화면에 "어떤 입력이 들어오고 있는가" 가 즉시 보임.
///
/// # 표시 요소
///
/// 1. 컨트롤러 이름 (예: "Wireless Controller") 또는 "미연결"
/// 2. isRunning 상태 점 (녹색 = polling 중 / 회색 = 정지)
/// 3. 최근 액션 라벨 (adapter.lastActionLabel — "stick move", "preset 1: march" 등)
/// 4. 시작/정지 토글 버튼
/// 5. 매핑 안내 (☰=recovery / △=emergency / D-pad=presets)
///
/// # Lifecycle
///
/// - `.onAppear`: adapter.start() 자동 — overlay 열림 즉시 폴링 시작.
/// - `.onDisappear`: adapter.stop() — overlay 닫힘 시 timer / observer 정리.
/// - 사용자가 토글 버튼으로 수동 start/stop 가능 (재시작 idempotent).
///
/// # 테스트 가능성
///
/// `init(bridge:source:)` overload 가 `GamepadInputSource` 추상화 주입 허용 —
/// `MockGamepad` 로 결정론적 테스트. 기본 `init(bridge:)` 는 실 GCController 사용.
@MainActor
public struct GamepadPilotPanel: View {

    /// `@State` 미사용 의도: adapter 자체가 `@Observable` 라 변경 시 view 자동 갱신.
    /// `let` 으로 외부 노출 — 테스트가 adapter 의 mock state 검증 가능.
    public let adapter: GamepadPilotAdapter

    /// Production init — 실 `GCController` source 사용.
    public init(bridge: WalkLabRCBridge) {
        self.adapter = GamepadPilotAdapter(bridge: bridge)
    }

    /// Test / DI init — `MockGamepad` 등 임의 source 주입.
    public init(bridge: WalkLabRCBridge, source: GamepadInputSource) {
        self.adapter = GamepadPilotAdapter(bridge: bridge, source: source)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            header
            statusRow
            mappingGuide
            controlsRow
            lastActionLine
        }
        .padding(DFSpace.sm3)
        .frame(width: 280)
        .background(DFColor.canvas.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(borderColor, lineWidth: 1)
        )
        .onAppear {
            adapter.start()
        }
        .onDisappear {
            adapter.stop()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: adapter.isRunning ? "gamecontroller.fill" : "gamecontroller")
                .foregroundStyle(adapter.isRunning ? DFColor.accent : DFColor.textSecondary)
            Text("Gamepad Pilot")
                .font(.callout.weight(.semibold))
            Spacer()
            runningDot
        }
    }

    private var runningDot: some View {
        HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(adapter.isRunning ? DFColor.success : DFColor.textSecondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(adapter.isRunning ? "ON" : "OFF")
                .font(DFFont.captionEmph)
                .foregroundStyle(adapter.isRunning ? DFColor.success : DFColor.textSecondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(adapter.connectedControllerName != nil
                                 ? DFColor.accent
                                 : DFColor.textSecondary)
            Text(controllerLabel)
                .font(DFFont.caption)
                .foregroundStyle(adapter.connectedControllerName != nil
                                 ? DFColor.textPrimary
                                 : DFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DFSpace.xs2)
        .padding(.vertical, DFSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.textSecondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
    }

    private var controllerLabel: String {
        adapter.connectedControllerName ?? "컨트롤러 미연결"
    }

    private var mappingGuide: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("매핑")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
            mappingChip(icon: "triangle.fill", label: "△ / Y", desc: "긴급 정지", tint: DFColor.danger)
            mappingChip(icon: "line.3.horizontal", label: "☰ / START", desc: "Recovery", tint: DFColor.warning)
            mappingChip(icon: "dpad", label: "D-pad", desc: "preset 1-4", tint: DFColor.accent)
            mappingChip(icon: "circle.grid.cross", label: "스틱", desc: "이동 / 회전", tint: DFColor.info)
        }
    }

    private func mappingChip(icon: String, label: String, desc: String, tint: Color) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
            Text(label)
                .font(DFFont.monoCaption)
                .foregroundStyle(DFColor.textPrimary)
                .frame(width: 72, alignment: .leading)
            Text(desc)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Spacer()
        }
    }

    private var controlsRow: some View {
        HStack(spacing: DFSpace.sm) {
            Button(action: toggleRunning) {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: adapter.isRunning ? "stop.fill" : "play.fill")
                    Text(adapter.isRunning ? "정지" : "시작")
                }
                .font(DFFont.captionEmph)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(adapter.isRunning ? DFColor.warning : DFColor.accent)
        }
    }

    @ViewBuilder
    private var lastActionLine: some View {
        if let action = adapter.lastActionLabel {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "waveform.path")
                    .font(.caption2)
                    .foregroundStyle(DFColor.accent)
                Text(action)
                    .font(DFFont.monoCaption)
                    .foregroundStyle(DFColor.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if adapter.isRunning {
            Text("입력 대기 중 — 스틱 / 버튼 조작")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
        } else {
            Text("시작 버튼 또는 패널이 열리면 자동 시작")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    // MARK: - Style helpers

    private var borderColor: Color {
        adapter.isRunning
            ? DFColor.accent.opacity(0.4)
            : DFColor.textSecondary.opacity(0.3)
    }

    // MARK: - Actions

    private func toggleRunning() {
        if adapter.isRunning {
            adapter.stop()
        } else {
            adapter.start()
        }
    }
}
