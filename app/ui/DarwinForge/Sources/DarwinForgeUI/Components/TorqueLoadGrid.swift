import ForgeCore
import SwiftUI

/// 모터 부하 신호등 그리드 — 5×4 (20 관절) 한눈 표시.
///
/// 색상 코딩 (ROBOTIS Dynamixel 표준 + 일반 산업 안전 색상):
///   - 초록  (< 30%):  정상
///   - 노랑  (30-60%): 적당 부하 (주의 시작)
///   - 주황  (60-80%): 높은 부하 (경고)
///   - 빨강  (≥ 80%): 위험 (즉시 점검)
///   - 회색  (데이터 없음)
///
/// critical 부하 감지 시 깜빡임 + 알림 영역 노출.
public struct TorqueLoadGrid: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var pulse: Bool = false
    private let pulseTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            header
            grid
            if let danger = dangerJoint {
                alertBanner(danger: danger)
            }
        }
        .padding(10)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(borderColor, lineWidth: dangerJoint != nil ? 1.0 : 0.5)
        )
        .onReceive(pulseTimer) { _ in pulse.toggle() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.heart.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(headerTint)
            Text("모터 부하 신호등")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DFColor.textSecondary)
                .textCase(.uppercase)
            Spacer()
            // 4단계 범례 — 작은 4 dots + 라벨.
            legendItem(color: .green, label: "정상")
            legendItem(color: .yellow, label: "적당")
            legendItem(color: .orange, label: "높음")
            legendItem(color: .red, label: "위험")
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    private var headerTint: Color {
        if dangerJoint != nil { return DFColor.danger }
        return DFColor.torque
    }
    private var borderColor: Color {
        if dangerJoint != nil {
            return DFColor.danger.opacity(pulse ? 0.8 : 0.3)
        }
        return DFColor.textSecondary.opacity(0.15)
    }

    // MARK: - Grid 5×4

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5),
                  spacing: 4) {
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

        return VStack(spacing: 1) {
            HStack(spacing: 3) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(isCritical && pulse ? 0.4 : 1.0)
                Text("ID\(j.rawValue)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DFColor.textPrimary)
            }
            Text(shortName(j))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
            if hasData {
                Text("\(Int(pct))%")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
            } else {
                Text("—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(tint.opacity(isCritical ? 0.18 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(tint.opacity(isCritical ? 0.7 : 0.25),
                        lineWidth: isCritical ? 1.0 : 0.4)
        )
        .help("\(j.koreanLabel) — ID \(j.rawValue) — 부하 \(Int(pct))%")
    }

    // MARK: - Alert banner

    private func alertBanner(danger: JointID) -> some View {
        let pct: Double = {
            guard let s = store.lastTelemetry?.joints[danger] else { return 0 }
            return SafeMotion.loadPercent(Int(s.presentLoad))
        }()
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DFColor.danger)
                .opacity(pulse ? 0.5 : 1.0)
            VStack(alignment: .leading, spacing: 1) {
                Text("⚠ \(danger.koreanLabel) (ID \(danger.rawValue)) 부하 위험")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.danger)
                Text("\(Int(pct))% — 즉시 점검 권장. 자세 변경 자동 중단됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            Button {
                store.emergencyStop()
            } label: {
                Text("토크 해제")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, DFSpace.sm).padding(.vertical, DFSpace.xs)
                    .background(DFColor.danger)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(DFColor.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
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
        case .unknown:   return DFColor.textSecondary.opacity(0.4)
        }
    }

    private func shortName(_ j: JointID) -> String {
        switch j {
        case .rShoulderPitch: return "RSh.P"
        case .lShoulderPitch: return "LSh.P"
        case .rShoulderRoll:  return "RSh.R"
        case .lShoulderRoll:  return "LSh.R"
        case .rElbow:         return "RElb"
        case .lElbow:         return "LElb"
        case .rHipYaw:        return "RH.Y"
        case .lHipYaw:        return "LH.Y"
        case .rHipRoll:       return "RH.R"
        case .lHipRoll:       return "LH.R"
        case .rHipPitch:      return "RH.P"
        case .lHipPitch:      return "LH.P"
        case .rKnee:          return "RKnee"
        case .lKnee:          return "LKnee"
        case .rAnklePitch:    return "RA.P"
        case .lAnklePitch:    return "LA.P"
        case .rAnkleRoll:     return "RA.R"
        case .lAnkleRoll:     return "LA.R"
        case .headPan:        return "HPan"
        case .headTilt:       return "HTilt"
        }
    }
}
