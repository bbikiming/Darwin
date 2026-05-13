import ForgeCore
import SwiftUI

/// 7-zone D-pad (PRD §3 좌측 패널 4) — ↑↓←→ + ↶↷ + ◉ 정지.
///
/// v1.0 동작 모델:
///   - **정지(◉)**: 항상 실 송출 — walk_ready 자세로 복귀 (안전).
///   - 방향(↑↓←→ / ↶↷): `dpadRealMotor` (v2) 활성 시만 실 송출. 그 외 sim 시각만.
///
/// 방향 버튼이 실 송출 시 보내는 자세:
///   - 전진/후진: hip_pitch ±10° step → 1초 후 walk_ready 복귀 (한 발 흉내).
///   - 좌/우 이동: hip_roll ±5° step → walk_ready 복귀.
///   - 좌/우 회전: hip_yaw ±10° step → walk_ready 복귀.
///   - 실 walking IK 가 v1.5 에서 완성되면 raw step 송출로 교체.
public enum DpadZone: String, CaseIterable, Sendable {
    case up, down, left, right
    case rotateLeft = "rotate_left", rotateRight = "rotate_right"
    case stop

    public var icon: String {
        switch self {
        case .up:          return "arrow.up"
        case .down:        return "arrow.down"
        case .left:        return "arrow.left"
        case .right:       return "arrow.right"
        case .rotateLeft:  return "arrow.uturn.left"
        case .rotateRight: return "arrow.uturn.right"
        case .stop:        return "stop.fill"
        }
    }
    public var keyChar: String? {
        switch self {
        case .up: return "W"; case .down: return "S"
        case .left: return "A"; case .right: return "D"
        case .rotateLeft: return "Q"; case .rotateRight: return "E"
        case .stop: return "Space"
        }
    }
    public var koreanLabel: String {
        switch self {
        case .up:          return "전진"
        case .down:        return "후진"
        case .left:        return "좌이동"
        case .right:       return "우이동"
        case .rotateLeft:  return "좌회전"
        case .rotateRight: return "우회전"
        case .stop:        return "정지"
        }
    }

    /// walkReady 베이스에 zone 별로 덮어쓸 관절 각도 (°).
    /// stop 은 walkReady 그대로 (override 없음).
    fileprivate var poseOverrideDegrees: [JointID: Double] {
        switch self {
        case .stop:        return [:]
        case .up:          return [.rHipPitch: -45, .lHipPitch: +35]    // 전진 = R 다리 살짝 앞으로
        case .down:        return [.rHipPitch: -25, .lHipPitch: +45]    // 후진 = L 다리 살짝 앞으로
        case .left:        return [.rHipRoll: +5, .lHipRoll: -5]        // CoM 왼쪽으로
        case .right:       return [.rHipRoll: -5, .lHipRoll: +5]        // CoM 오른쪽으로
        case .rotateLeft:  return [.rHipYaw: -10, .lHipYaw: -10]        // 양 hip yaw 좌
        case .rotateRight: return [.rHipYaw: +10, .lHipYaw: +10]        // 양 hip yaw 우
        }
    }

    /// 이 zone 의 자세를 walkReady 베이스에 적용해 새 RobotPose 반환.
    fileprivate func makePose() -> RobotPose {
        let overrides = poseOverrideDegrees
        if overrides.isEmpty { return .walkReady }
        var dict = RobotPose.walkReady.positions
        for (j, d) in overrides {
            dict[j] = Kinematics.raw(fromDegrees: d)
        }
        return RobotPose(positions: dict)
    }
}

public struct PilotDpad: View {
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate
    @EnvironmentObject private var store: ConnectionStore
    let flags: PilotFeatureFlags
    @State private var activeZone: DpadZone? = nil
    @State private var unavailableToast: String? = nil
    @State private var unavailableToastVisible: Bool = false

    private let cellSize: CGFloat = 56  // Apple HIG min 44pt + visual padding.

    public init(channel: TeleopChannel, gate: PilotSafetyGate, flags: PilotFeatureFlags) {
        self.channel = channel
        self.gate = gate
        self.flags = flags
    }

    /// 방향 zone (stop 제외) 가 현재 실 송출 가능한지.
    /// Codex P1 fix (2026-05-13 3차): 이전엔 false 시 silently return → 사용자
    /// 무반응 으로 인지. v1.5 부터는 disabled visual + 명확한 toast.
    private var dpadDirectionsActive: Bool {
        flags.dpadRealMotor && store.bus != nil && gate.armed
    }

    /// 방향 zone 이 비활성된 이유 — 사용자 toast/tooltip 용.
    private func directionUnavailableReason() -> String {
        if !flags.dpadRealMotor {
            return "v1.5 에서 D-pad 실 송출 비활성 — 실 IK (BLOCKER C3) 해결 후 v2 활성"
        }
        if store.bus == nil {
            return "실 로봇 미연결 — D-pad 방향 송출 불가 (sim 미리보기는 ARM 후)"
        }
        if !gate.armed {
            return "먼저 ARM 슬라이더 잠금 해제 필요"
        }
        return "D-pad 직접 송출 불가"
    }

    public var body: some View {
        DFPanel(
            "방향 조작 (D-pad)",
            subtitle: dpadDirectionsActive
                ? "방향 실 송출 활성 — Stop 은 항상 walkReady 송출"
                : "방향 비활성 — \(directionUnavailableReason())",
            icon: "dpad",
            tint: PilotColor.dpadActive,
            trailing: {
                if !dpadDirectionsActive {
                    DFChip("방향 비활성", icon: "lock.fill", style: .warning)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                HStack(spacing: DFSpace.md) {
                    dpadGrid
                        .frame(width: cellSize * 3 + 12)
                    Spacer(minLength: 0)
                    legend
                }
                if unavailableToastVisible, let msg = unavailableToast {
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(DFColor.warning)
                        Text(msg)
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.warning)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, DFSpace.sm)
                    .padding(.vertical, DFSpace.xs2)
                    .background(DFColor.warning.opacity(DFOpacity.o10))
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
                    .transition(.opacity)
                    .accessibilityIdentifier("pilot.dpad.toast")
                }
            }
        }
    }

    private var dpadGrid: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                zoneButton(.rotateLeft, dim: true)
                zoneButton(.up)
                zoneButton(.rotateRight, dim: true)
            }
            GridRow {
                zoneButton(.left)
                zoneButton(.stop)
                zoneButton(.right)
            }
            GridRow {
                Color.clear.frame(width: cellSize, height: cellSize)
                zoneButton(.down)
                Color.clear.frame(width: cellSize, height: cellSize)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            legendRow("W / A / S / D", "전·좌·후·우")
            legendRow("Q / E",         "좌회전·우회전")
            legendRow("Space",         "정지")
        }
        .font(DFFont.caption.monospaced())
        .foregroundStyle(DFColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Text(key)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DFRadius.xs).fill(DFColor.elev2)
                        .overlay(
                            RoundedRectangle(cornerRadius: DFRadius.xs)
                                .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: DFSize.borderHairline)
                        )
                )
            Text(label)
        }
    }

    private func zoneButton(_ zone: DpadZone, dim: Bool = false) -> some View {
        let isActive = activeZone == zone
        let tint = zone == .stop ? PilotColor.safetyHighRisk : PilotColor.dpadActive
        // Codex P1 fix: 방향 zone (stop 제외) 가 비활성이면 시각적으로 disabled.
        let isDirectionDisabled = (zone != .stop) && !dpadDirectionsActive
        return Button {
            withAnimation(PilotAnim.dpadPress) { activeZone = zone }
            handlePress(zone)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                if activeZone == zone {
                    withAnimation(PilotAnim.stateChange) { activeZone = nil }
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .fill(isActive ? tint.opacity(0.55) : tint.opacity(DFOpacity.o15))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .stroke(tint.opacity(isActive ? 0.9 : 0.35), lineWidth: DFSize.borderHairline)
                    )
                VStack(spacing: DFSpace.micro2) {
                    Image(systemName: zone.icon)
                        .font(.system(size: DFFontSize.s16, weight: .bold))
                        .foregroundStyle(isActive ? .white : tint)
                    if let k = zone.keyChar {
                        Text(k)
                            .font(.system(size: DFFontSize.s8, weight: .semibold, design: .monospaced))
                            .foregroundStyle((isActive ? Color.white : tint).opacity(0.75))
                    }
                }
                // 비활성 방향엔 작은 lock overlay.
                if isDirectionDisabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: DFFontSize.s10, weight: .bold))
                        .foregroundStyle(DFColor.textSecondary)
                        .padding(2)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .offset(x: cellSize/2 - 8, y: -cellSize/2 + 8)
                }
            }
            .frame(width: cellSize, height: cellSize)
            .opacity(dim ? 0.85 : (isDirectionDisabled ? DFOpacity.disabled : 1.0))
        }
        .buttonStyle(.plain)
        .help(isDirectionDisabled
              ? "\(zone.koreanLabel) — 현재 비활성 (\(directionUnavailableReason()))"
              : "\(zone.koreanLabel) — 키 \(zone.keyChar ?? "")")
        .accessibilityLabel(zone.koreanLabel)
    }

    /// 한 zone 누름 처리. 안전 + 단계별 활성화 규칙:
    ///   - stop → 항상 walkReady 시도 (bus 미연결이면 .notConnected toast).
    ///   - 방향 zone → `dpadDirectionsActive` 일 때만 실 송출.
    ///   - 그 외 → 명확한 toast 표시 (Codex P1 fix — 이전엔 silent return).
    private func handlePress(_ zone: DpadZone) {
        if zone == .stop {
            // Stop 은 ARM 무관 항상 walkReady 시도. bus 미연결 시 결과로 surface.
            Task { @MainActor in
                let r = await store.applyPoseSmoothly(.walkReady)
                if case .notConnected = r {
                    showUnavailableToast("Stop 시뮬 — 실 로봇 미연결 (walkReady 시각만)")
                }
            }
            return
        }

        guard dpadDirectionsActive else {
            // 방향 zone 비활성 — 명확한 피드백 (이전 silent return).
            showUnavailableToast(directionUnavailableReason())
            return
        }

        let target = zone.makePose()
        Task { @MainActor in
            await store.applyPoseSmoothly(target)
            try? await Task.sleep(nanoseconds: 700_000_000)
            await store.applyPoseSmoothly(.walkReady)
        }
    }

    /// 비활성 사유 toast — 3초 후 자동 dismiss.
    private func showUnavailableToast(_ msg: String) {
        unavailableToast = msg
        withAnimation(.easeIn(duration: 0.2)) { unavailableToastVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) { unavailableToastVisible = false }
        }
    }
}
