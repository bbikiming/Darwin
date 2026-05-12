import SwiftUI

/// 7-zone D-pad (PRD §3 좌측 패널 4) — ↑↓←→ + ↶↷ + ◉ 정지.
///
/// v1.0: **sim 만**. 누름 시 시뮬 walk command 시각 표시.
/// v2: 실 모터 송출 — flags.dpadRealMotor 활성 후.
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
}

public struct PilotDpad: View {
    let flags: PilotFeatureFlags
    @State private var activeZone: DpadZone? = nil

    private let cellSize: CGFloat = 56  // Apple HIG min 44pt + visual padding.

    public init(flags: PilotFeatureFlags) {
        self.flags = flags
    }

    public var body: some View {
        DFPanel(
            "방향 조작 (D-pad)",
            subtitle: flags.dpadRealMotor ? "실 송출 활성" : "v1.0: sim 미리보기 (실 송출은 v2)",
            icon: "dpad",
            tint: PilotColor.dpadActive,
            trailing: {
                if !flags.dpadRealMotor {
                    DFChip("v2 활성 예정", icon: "lock.fill", style: .warning)
                }
            }
        ) {
            HStack(spacing: DFSpace.md) {
                dpadGrid
                    .frame(width: cellSize * 3 + 12)
                Spacer(minLength: 0)
                legend
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
        VStack(alignment: .leading, spacing: 4) {
            legendRow("W / A / S / D", "전·좌·후·우")
            legendRow("Q / E",         "좌회전·우회전")
            legendRow("Space",         "정지")
        }
        .font(DFFont.caption.monospaced())
        .foregroundStyle(DFColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(DFColor.elev2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(DFColor.textSecondary.opacity(0.25), lineWidth: 0.5)
                        )
                )
            Text(label)
        }
    }

    private func zoneButton(_ zone: DpadZone, dim: Bool = false) -> some View {
        let isActive = activeZone == zone
        let tint = zone == .stop ? PilotColor.safetyHighRisk : PilotColor.dpadActive
        return Button {
            withAnimation(PilotAnim.dpadPress) { activeZone = zone }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                if activeZone == zone {
                    withAnimation(PilotAnim.stateChange) { activeZone = nil }
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .fill(isActive ? tint.opacity(0.55) : tint.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .stroke(tint.opacity(isActive ? 0.9 : 0.35), lineWidth: 0.5)
                    )
                VStack(spacing: 2) {
                    Image(systemName: zone.icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(isActive ? .white : tint)
                    if let k = zone.keyChar {
                        Text(k)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle((isActive ? Color.white : tint).opacity(0.75))
                    }
                }
            }
            .frame(width: cellSize, height: cellSize)
            .opacity(dim ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
        .help("\(zone.koreanLabel) — 키 \(zone.keyChar ?? "")")
        .accessibilityLabel(zone.koreanLabel)
    }
}
