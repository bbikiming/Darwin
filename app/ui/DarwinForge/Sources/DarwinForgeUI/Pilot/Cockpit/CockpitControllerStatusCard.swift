import SwiftUI

/// 조종 시뮬 좌측 HUD 카드 — 컨트롤러 **연결 상태 + 라이브 입력**을 한눈에 보여준다.
///
/// 종전 `CockpitDJIPanel`(좌측 DJI 카드)을 통합 「컨트롤러 연결」 모달로 합치면서
/// 좌측의 at-a-glance 상태 표시가 사라졌다. 본 카드가 그 자리를 대신하되, DJI 전용이
/// 아니라 **게임패드·DJI 공통**으로 현재 연결/소스/스틱/명령을 시각화한다.
/// 카드(또는 우상단 ⚙)를 누르면 통합 매핑 모달이 열린다.
@MainActor
struct CockpitControllerStatusCard: View {
    @ObservedObject var cockpit: CockpitState
    /// DJI HID 라이브 스트리밍 여부(IOKit 경로). 게임패드는 `connectedController` 로 판단.
    var djiStreaming: Bool = false
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statusRow
            liveRow
        }
        .cockpitPanel(tint: tone, strokeOpacity: 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpenSettings() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("컨트롤러 \(statusText)")
        .accessibilityHint("탭하면 컨트롤러 연결·매핑을 엽니다")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 12)).foregroundStyle(tone)
            Text("컨트롤러")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CockpitColors.cyan)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("컨트롤러 연결·매핑 열기")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: - Live visualization

    private var liveRow: some View {
        HStack(spacing: 12) {
            miniStick(cockpit.leftStick, label: "이동")
            miniStick(cockpit.rightStick, label: "회전/머리")
            VStack(alignment: .leading, spacing: 2) {
                Text("명령")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(commandText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(commandTone)
            }
            Spacer(minLength: 0)
        }
    }

    private func miniStick(_ v: SIMD2<Double>, label: String) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(Color.black.opacity(0.4)).frame(width: 36, height: 36)
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 1).frame(width: 36, height: 36)
                // 십자 가이드
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 36, height: 1)
                Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 36)
                // 라이브 위치 점
                Circle().fill(tone)
                    .frame(width: 9, height: 9)
                    .shadow(color: tone.opacity(0.6), radius: live(v) ? 4 : 0)
                    .offset(x: CGFloat(clamp(v.x)) * 12, y: CGFloat(clamp(v.y)) * 12)
            }
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    // MARK: - Derived state

    private var connected: Bool { cockpit.connectedController != nil || djiStreaming }
    private var tone: Color { connected ? CockpitColors.live : CockpitColors.warn }

    private var statusText: String {
        if let name = cockpit.connectedController {
            return "\(name) · \(cockpit.lastSource.label)"
        }
        if djiStreaming { return "DJI RC · 연결됨" }
        return "미연결 — 탭하여 연결·매핑"
    }

    private var commandText: String { cockpit.lastCommand.isStop ? "정지" : "보행" }
    private var commandTone: Color { cockpit.lastCommand.isStop ? CockpitColors.cyan : CockpitColors.live }

    private func live(_ v: SIMD2<Double>) -> Bool { abs(v.x) > 0.05 || abs(v.y) > 0.05 }
    private func clamp(_ x: Double) -> Double { min(1, max(-1, x)) }
}
