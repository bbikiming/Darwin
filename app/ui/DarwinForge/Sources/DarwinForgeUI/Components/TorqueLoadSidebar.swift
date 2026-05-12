import ForgeCore
import SwiftUI

/// 우측 끝 세로 부하 신호등 패널 — 열기/닫기 가능.
///
/// 구성:
///   - 열림: 폭 ~160px, 20관절 2×10 세로 grid + 헤더 + 알림 영역
///   - 닫힘: 폭 28px, 세로 토글 버튼만 (펄스 빨강 알림 인디케이터)
///
/// 모든 메뉴 공통 사용: Studio / 티칭 / 워크랩 / 모션 스튜디오.
public struct TorqueLoadSidebar: View {
    @EnvironmentObject var store: ConnectionStore
    @Binding public var isOpen: Bool
    @State private var pulse: Bool = false
    private let pulseTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    public init(isOpen: Binding<Bool>) {
        self._isOpen = isOpen
    }

    public var body: some View {
        HStack(spacing: DFSpace.none) {
            // 좌측 toggle 핸들 — 항상 보임.
            toggleHandle
            if isOpen {
                Divider()
                contentPanel
                    .frame(width: 172)   // 158→172 — 두 자리수 ID 라벨 (ID11~ID19) 잘림 회피.
            }
        }
        .background(DFColor.canvas)
        .onReceive(pulseTimer) { _ in pulse.toggle() }
    }

    // MARK: - Toggle handle

    private var toggleHandle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isOpen.toggle() }
        } label: {
            VStack(spacing: DFSpace.sm) {
                Image(systemName: isOpen ? "chevron.right" : "chevron.left")
                    .font(.system(size: DFFontSize.s11, weight: .bold))
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: DFFontSize.s13, weight: .semibold))
                    .foregroundStyle(headerTint)
                if !isOpen {
                    VStack(spacing: DFSpace.micro2) {
                        ForEach("부하".map { String($0) }, id: \.self) { c in
                            Text(c)
                                .font(.system(size: DFFontSize.s9, weight: .semibold))
                                .foregroundStyle(DFColor.textSecondary)
                        }
                    }
                }
                Spacer()
                if dangerJoint != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.danger)
                        .opacity(pulse ? 0.4 : 1.0)
                }
            }
            .padding(.vertical, DFSpace.sm)
            .padding(.horizontal, DFSpace.xs)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .background(DFColor.elev2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "부하 신호등 닫기" : "부하 신호등 열기")
    }

    private var headerTint: Color {
        if dangerJoint != nil { return DFColor.danger }
        return DFColor.torque
    }

    // MARK: - Content panel (open)

    private var contentPanel: some View {
        ScrollView {
            VStack(spacing: DFSpace.sm) {
                header
                Divider()
                legend
                grid
                if let danger = dangerJoint {
                    alertBanner(danger: danger)
                }
            }
            .padding(8)
        }
        .glassScroll(accent: DFColor.torque, fadeHeight: 12)
        .frame(maxHeight: .infinity)
        .glass(radius: DFRadius.md, intensity: 0.9)
    }

    private var header: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "bolt.heart.fill")
                .font(.system(size: DFFontSize.s10, weight: .semibold))
                .foregroundStyle(headerTint)
            Text("부하 신호등")
                .font(.system(size: DFFontSize.s10, weight: .semibold))
                .foregroundStyle(DFColor.textSecondary)
                .textCase(.uppercase)
            Spacer()
        }
    }

    private var legend: some View {
        HStack(spacing: DFSpace.xs) {
            legendDot(color: DFColor.success, label: "정상")
            legendDot(color: Color.yellow, label: "주의")
            legendDot(color: Color.orange, label: "높음")
            legendDot(color: DFColor.danger, label: "위험")
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: DFSpace.micro2) {
            Circle().fill(color).frame(width: DFSize.indicatorXs, height: DFSize.indicatorXs)
            Text(label)
                .font(.system(size: DFFontSize.s8))
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    // 2×10 grid — 좁은 세로 공간 활용.
    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 2),
                  spacing: 3) {
            ForEach(JointID.allCases, id: \.self) { j in
                tile(j)
            }
        }
    }

    private func tile(_ j: JointID) -> some View {
        let state = store.lastTelemetry?.joints[j]
        let loadRaw = Int(state?.presentLoad ?? 0)
        let hasData = state != nil
        let pct = hasData ? SafeMotion.loadPercent(loadRaw) : 0
        let level = hasData ? SafeMotion.loadColor(loadPct: pct) : .unknown
        let tint = colorFor(level)
        let isCritical = level == .critical

        return VStack(spacing: DFSpace.micro) {
            HStack(spacing: 3) {
                Circle()
                    .fill(tint)
                    .frame(width: DFSize.indicatorXs, height: DFSize.indicatorXs)
                    .opacity(isCritical && pulse ? 0.4 : 1.0)
                Text("ID\(j.rawValue)")
                    .font(.system(size: DFFontSize.s8, weight: .bold, design: .monospaced))
                    .foregroundStyle(DFColor.textPrimary)
            }
            if hasData {
                Text("\(Int(pct))%")
                    .font(.system(size: DFFontSize.s8, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
            } else {
                Text("—")
                    .font(.system(size: DFFontSize.s8, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.disabled))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(tint.opacity(isCritical ? 0.18 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs)
                .stroke(tint.opacity(isCritical ? 0.7 : 0.25),
                        lineWidth: isCritical ? 1.0 : 0.4)
        )
        .help("\(j.koreanLabel) — ID \(j.rawValue) — 부하 \(Int(pct))%")
    }

    private func alertBanner(danger: JointID) -> some View {
        let pct: Double = {
            guard let s = store.lastTelemetry?.joints[danger] else { return 0 }
            return SafeMotion.loadPercent(Int(s.presentLoad))
        }()
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.danger)
                    .opacity(pulse ? 0.5 : 1.0)
                Text("⚠ ID \(danger.rawValue)")
                    .font(.system(size: DFFontSize.s10, weight: .bold))
                    .foregroundStyle(DFColor.danger)
            }
            Text("\(Int(pct))% — \(danger.koreanLabel)")
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(2)
            Button {
                store.emergencyStop()
            } label: {
                Text("토크 해제")
                    .font(.system(size: DFFontSize.s9, weight: .semibold))
                    .padding(.horizontal, DFSpace.xs2).padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(DFColor.danger)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(DFColor.danger.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Helpers

    private var dangerJoint: JointID? {
        guard let joints = store.lastTelemetry?.joints else { return nil }
        for (j, s) in joints {
            let pct = SafeMotion.loadPercent(Int(s.presentLoad))
            if pct >= SafeMotion.LoadLevel.critical { return j }
        }
        return nil
    }

    private func colorFor(_ level: SafeMotion.LoadColor) -> Color {
        switch level {
        case .normal:    return DFColor.success
        case .moderate:  return Color.yellow
        case .high:      return Color.orange
        case .critical:  return DFColor.danger
        case .unknown:   return DFColor.textSecondary.opacity(DFOpacity.disabled)
        }
    }
}
