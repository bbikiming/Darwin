import SwiftUI

/// 라이브 입력 모니터(TEST-01) — 현재 스냅샷의 스틱 2D·트리거·버튼 +
/// 프로파일로 리졸브된 의미 출력(이동/머리)을 실시간 표시.
@MainActor
struct ControllerLiveTestPanel: View {
    @ObservedObject var source: VirtualControllerSource
    let profile: ControllerBindingProfile

    private var resolved: ResolvedControllerInput {
        ControllerInputResolver.resolve(source.snapshot, profile: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("라이브 테스트")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 14) {
                stickPlot(label: "L", x: source.axes[0], y: source.axes[1])
                stickPlot(label: "R", x: source.axes[2], y: source.axes[3])
            }

            triggerBars
            resolvedReadout
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(CockpitColors.panelSolid))
    }

    // MARK: - 스틱 2D 플롯

    private func stickPlot(label: String, x: Double, y: Double) -> some View {
        VStack(spacing: 4) {
            ZStack {
                let s: CGFloat = 84
                let r = s / 2
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
                // 데드존 원 (기본 0.10)
                Circle().stroke(CockpitColors.warn.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: s * 0.10, height: s * 0.10)
                Circle().fill(CockpitColors.live)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(x) * (r - 8), y: CGFloat(y) * (r - 8))
            }
            .frame(width: 84, height: 84)
            Text("\(label)  \(fmt(x)), \(fmt(y))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - 트리거 바

    private var triggerBars: some View {
        HStack(spacing: 10) {
            triggerBar("LT", source.axes[4])
            triggerBar("RT", source.axes[5])
        }
    }

    private func triggerBar(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(CockpitColors.cyan.opacity(0.7))
                        .frame(width: max(0, CGFloat(v) * geo.size.width))
                }
            }
            .frame(height: 8)
            Text(fmt(v)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: - 리졸브 출력

    private var resolvedReadout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Color.white.opacity(0.1))
            Text("리졸브 출력 (cockpit 주입값)")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            readoutRow("이동 X (좌−/우+)", resolved.leftX)
            readoutRow("이동 Y (전진−/후진+)", resolved.leftY)
            readoutRow("회전 (좌−/우+)", resolved.turn)
            readoutRow("머리 Pan (좌−/우+)", resolved.headPan)
            readoutRow("머리 Tilt (아래−/위+)", resolved.headTilt)
            HStack(spacing: 8) {
                flag("E-STOP", resolved.emergencyStop, CockpitColors.danger)
                flag("복구", resolved.recover, CockpitColors.warn)
                flag("볼트랙", resolved.ballTracking, CockpitColors.cyan)
            }
            .padding(.top, 2)
        }
    }

    private func readoutRow(_ label: String, _ v: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(fmt(v)).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(abs(v) > 0.001 ? CockpitColors.live : .white.opacity(0.4))
        }
    }

    private func flag(_ label: String, _ on: Bool, _ tint: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(on ? tint.opacity(0.85) : Color.white.opacity(0.08)))
            .foregroundStyle(on ? .white : .white.opacity(0.4))
    }

    private func fmt(_ v: Double) -> String { String(format: "%+.2f", v) }
}
