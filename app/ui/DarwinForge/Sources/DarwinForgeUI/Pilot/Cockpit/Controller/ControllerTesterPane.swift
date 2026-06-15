import SwiftUI

/// 라이브 테스터 모드 (설계 §C, Xbox 액세서리 패턴) — 바인딩 편집 잠금 상태로
/// 다이어그램·가상패드를 입력 모니터로 쓰고, 우측 파이프라인 패널이
/// 원시 → 성형(`ControllerAxisTuning.shaped`) → 최종 주입값(`resolve`) 변환을
/// 실시간 표시한다.
@MainActor
struct ControllerTesterPane: View {
    @ObservedObject var source: VirtualControllerSource
    @ObservedObject var cockpit: CockpitState
    let profile: ControllerBindingProfile
    @Binding var selectedBinding: ControllerBinding?

    var body: some View {
        HStack(spacing: 0) {
            monitorColumn
            Divider()
            pipelinePanel.frame(width: 300)
        }
    }

    // MARK: - 좌: 입력 모니터

    private var monitorColumn: some View {
        VStack(spacing: 14) {
            HStack {
                Text("라이브 테스트").font(.system(size: 13, weight: .semibold))
                Text("매핑 편집 잠금").font(.system(size: 10))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("가상 패드").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    ZStack {
                        RGG01ControllerVisual(
                            snapshot: source.snapshot, profile: profile,
                            selectedBinding: selectedBinding,
                            onTap: { selectedBinding = $0 })
                        ControllerCalloutOverlay(
                            snapshot: source.snapshot, profile: profile,
                            selectedBinding: selectedBinding,
                            onSelect: { selectedBinding = $0 })
                    }
                    Text("테스트 모드 — 클릭/입력은 선택만 하고 매핑을 바꾸지 않아요.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    VirtualControllerPad(source: source)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                    CockpitInjectionReadout(cockpit: cockpit)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 우: 입력 파이프라인

    private var pipelinePanel: some View {
        let resolved = ControllerInputResolver.resolve(source.snapshot, profile: profile)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("입력 파이프라인").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    Text("축 — 원시 → 성형").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(0..<6, id: \.self) { axisPipelineRow($0) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("최종 주입값").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    resolvedRow("이동 좌우", resolved.leftX)
                    resolvedRow("이동 전후", resolved.leftY)
                    resolvedRow("회전", resolved.turn)
                    resolvedRow("머리 팬", resolved.headPan)
                    resolvedRow("머리 틸트", resolved.headTilt)
                }
                HStack(spacing: 6) {
                    pressedBadge("E-STOP", resolved.emergencyStop, tint: .red)
                    pressedBadge("복구", resolved.recover, tint: .orange)
                    pressedBadge("볼 트래킹", resolved.ballTracking, tint: .purple)
                }
            }
            .padding(16)
        }
    }

    private func axisPipelineRow(_ index: Int) -> some View {
        let raw = source.snapshot.axis(index)
        let tuning = profile.axisTuning[index] ?? ControllerAxisTuning()
        let shaped = tuning.shaped(raw)
        return HStack(spacing: 8) {
            Text(Self.axisName(index)).font(.system(size: 10, weight: .medium))
                .frame(width: 64, alignment: .leading)
            Text(String(format: "%+.2f", raw))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Image(systemName: "arrow.right").font(.system(size: 7)).foregroundStyle(.secondary)
            Text(String(format: "%+.2f", shaped))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(abs(shaped) > 0.01 ? .teal : .secondary)
                .frame(width: 44, alignment: .trailing)
            signedBar(shaped)
        }
    }

    private func resolvedRow(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, weight: .medium)).frame(width: 64, alignment: .leading)
            Text(String(format: "%+.2f", value))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(abs(value) > 0.01 ? .green : .secondary)
                .frame(width: 44, alignment: .trailing)
            signedBar(value, tint: .green)
        }
    }

    /// 부호 있는 [-1,1] 미니 바 — 중앙 기준 좌(−)/우(+) 채움.
    private func signedBar(_ value: Double, tint: Color = .teal) -> some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let magnitude = min(1, abs(value))
            ZStack(alignment: value >= 0 ? .leading : .trailing) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Rectangle().fill(tint.opacity(0.7))
                    .frame(width: half * CGFloat(magnitude))
                    .offset(x: value >= 0 ? half : -half)
            }
            .clipShape(Capsule())
            .overlay(Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1))
        }
        .frame(height: 6)
    }

    private func pressedBadge(_ label: String, _ pressed: Bool, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(pressed ? tint.opacity(0.85) : Color.secondary.opacity(0.10)))
            .foregroundStyle(pressed ? .white : .secondary)
    }

    static func axisName(_ index: Int) -> String {
        switch index {
        case 0: return "L스틱 X"
        case 1: return "L스틱 Y"
        case 2: return "R스틱 X"
        case 3: return "R스틱 Y"
        case 4: return "LT"
        case 5: return "RT"
        default: return "축 \(index)"
        }
    }
}

/// 주입 readout — cockpit 에 실제로 들어간 값 (매핑 시트·테스터 공용).
@MainActor
struct CockpitInjectionReadout: View {
    @ObservedObject var cockpit: CockpitState

    var body: some View {
        HStack(spacing: 16) {
            metric("주입 L-스틱", String(format: "%+.2f, %+.2f", cockpit.leftStick.x, cockpit.leftStick.y))
            metric("회전", String(format: "%+.2f", cockpit.rightStick.x))
            metric("명령", commandText)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.green)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commandText: String {
        let c = cockpit.lastCommand
        return c.isStop ? "정지" : String(format: "보행 %.0f/%.0f/%.0f", c.strideMm, c.sideMm, c.turnDeg)
    }
}
