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

    // MARK: - 외부 의존성 (parent 가 주입)

    /// adapter 가 입력을 라우팅할 bridge. struct re-init 에도 동일 ref.
    private let bridge: WalkLabRCBridge

    /// **테스트 / 시뮬레이션 용** — `MockGamepad` 등 별도 source 주입.
    /// nil 이면 production 실 `GCController` 사용.
    private let injectedSource: GamepadInputSource?

    // MARK: - 내부 상태

    /// adapter 인스턴스 — view lifecycle 과 동기화. `@State` 가 SwiftUI re-render
    /// 에서 보존하므로 parent 가 panel 을 재인스턴스화해도 동일 ref 유지.
    /// **leak 차단 핵심**: `let` 으로 두면 SwiftUI struct 재생성 시마다 새 adapter
    /// 가 생성되고 이전 adapter 가 stop() 없이 drop → NotificationCenter observer 잔존.
    /// `@State + ensureAdapter` 가 1회만 alloc 보장 → onDisappear 의 stop() 이 cleanup.
    /// **사이클 72 — test accessibility**: `@State internal` (default access) — production UI
    /// 외부 set 차단 (struct private 와 동일 효과), test `@testable import` 만 read 가능.
    @State var adapter: GamepadPilotAdapter?

    // MARK: - Init

    /// Production init — 실 `GCController` source 사용.
    public init(bridge: WalkLabRCBridge) {
        self.bridge = bridge
        self.injectedSource = nil
    }

    /// Test / DI init — `MockGamepad` 등 임의 source 주입.
    public init(bridge: WalkLabRCBridge, source: GamepadInputSource) {
        self.bridge = bridge
        self.injectedSource = source
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
            ensureAdapter()
            adapter?.start()
        }
        .onDisappear {
            adapter?.stop()
        }
    }

    // MARK: - Adapter lifecycle

    /// `@State` adapter 가 nil 일 때 (첫 onAppear) 인스턴스 생성. View 재구성에서도
    /// `@State` storage 가 보존되므로 1회만 alloc. **테스트 가시성** 위해 internal —
    /// SwiftUI host 없는 XCTest 에서 `panel.ensureAdapter()` 직접 호출 후
    /// `panel.adapter` 검증 가능.
    func ensureAdapter() {
        guard adapter == nil else { return }
        if let injected = injectedSource {
            adapter = GamepadPilotAdapter(bridge: bridge, source: injected)
        } else {
            adapter = GamepadPilotAdapter(bridge: bridge)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: isRunning ? "gamecontroller.fill" : "gamecontroller")
                .foregroundStyle(isRunning ? DFColor.accent : DFColor.textSecondary)
            Text("Gamepad Pilot")
                .font(.callout.weight(.semibold))
            Spacer()
            runningDot
        }
    }

    private var runningDot: some View {
        HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(isRunning ? DFColor.success : DFColor.textSecondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(isRunning ? "ON" : "OFF")
                .font(DFFont.captionEmph)
                .foregroundStyle(isRunning ? DFColor.success : DFColor.textSecondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(adapter?.connectedControllerName != nil
                                 ? DFColor.accent
                                 : DFColor.textSecondary)
            Text(controllerLabel)
                .font(DFFont.caption)
                .foregroundStyle(adapter?.connectedControllerName != nil
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
        adapter?.connectedControllerName ?? "컨트롤러 미연결"
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
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    Text(isRunning ? "정지" : "시작")
                }
                .font(DFFont.captionEmph)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(isRunning ? DFColor.warning : DFColor.accent)
        }
    }

    @ViewBuilder
    private var lastActionLine: some View {
        if let action = adapter?.lastActionLabel {
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
        } else if isRunning {
            Text("입력 대기 중 — 스틱 / 버튼 조작")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
        } else {
            Text("시작 버튼 또는 패널이 열리면 자동 시작")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    // MARK: - Derived state

    /// `adapter?.isRunning` shortcut — nil (ensureAdapter 전) 이면 false.
    private var isRunning: Bool { adapter?.isRunning ?? false }

    // MARK: - Style helpers

    private var borderColor: Color {
        isRunning
            ? DFColor.accent.opacity(0.4)
            : DFColor.textSecondary.opacity(0.3)
    }

    // MARK: - Actions

    private func toggleRunning() {
        guard let adapter else { return }
        if adapter.isRunning {
            adapter.stop()
        } else {
            adapter.start()
        }
    }
}
