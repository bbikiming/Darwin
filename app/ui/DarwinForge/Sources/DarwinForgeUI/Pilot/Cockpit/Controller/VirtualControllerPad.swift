import SwiftUI

/// 화면 위 가상 게임패드 — 두 스틱 + 두 트리거 + 면 버튼/숄더.
/// 드래그/홀드 입력을 `VirtualControllerSource` 의 표준 축/버튼 인덱스로 흘려보낸다.
///
/// 스틱은 손을 떼면 자동 중앙 복귀(실물 스프링과 동일). 트리거는 0…1 수직 슬라이더.
/// 버튼은 누르는 동안만 pressed(momentary).
@MainActor
struct VirtualControllerPad: View {
    @ObservedObject var source: VirtualControllerSource

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                triggerSlider(label: "LT", index: 4)
                stickColumn(label: "L-스틱", xIndex: 0, yIndex: 1,
                            hint: "이동(전후/좌우)")
                stickColumn(label: "R-스틱", xIndex: 2, yIndex: 3,
                            hint: "회전 / 머리")
                triggerSlider(label: "RT", index: 5)
            }
            buttonRow
        }
        .padding(14)
    }

    // MARK: - 스틱

    private func stickColumn(label: String, xIndex: Int, yIndex: Int, hint: String) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            VirtualThumbstick(
                x: Binding(get: { source.axes[xIndex] },
                           set: { source.setAxis(xIndex, $0) }),
                y: Binding(get: { source.axes[yIndex] },
                           set: { source.setAxis(yIndex, $0) })
            )
            Text(hint).font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - 트리거

    private func triggerSlider(label: String, index: Int) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CockpitColors.cyan.opacity(0.7))
                        .frame(height: max(0, CGFloat(source.axes[index]) * h))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let frac = 1.0 - Double(v.location.y / h)
                            source.setAxis(index, max(0, min(1, frac)))
                        }
                        .onEnded { _ in source.setAxis(index, 0) }
                )
            }
            .frame(width: 34, height: 120)
            Text(String(format: "%.2f", source.axes[index]))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - 버튼

    private var buttonRow: some View {
        HStack(spacing: 10) {
            padButton("LB\n데드맨", index: 4, tint: CockpitColors.live)
            padButton("X\n볼트랙", index: 2, tint: CockpitColors.cyan)
            padButton("Y\n복구", index: 3, tint: CockpitColors.warn)
            padButton("B\nE-STOP", index: 1, tint: CockpitColors.danger)
            padButton("RB\n터보", index: 5, tint: .white.opacity(0.6))
        }
    }

    private func padButton(_ label: String, index: Int, tint: Color) -> some View {
        let pressed = source.buttons[index]
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .multilineTextAlignment(.center)
            .frame(width: 60, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(pressed ? 0.85 : 0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tint.opacity(pressed ? 1 : 0.5), lineWidth: pressed ? 2.5 : 1)
            )
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !source.buttons[index] { source.setButton(index, true) } }
                    .onEnded { _ in source.setButton(index, false) }
            )
    }
}

/// 2축 가상 스틱 — 드래그로 위치, 손 떼면 자동 중앙 복귀.
///
/// y 는 **화면 관례(−위/+아래)** 로 출력해 스냅샷·프리셋과 정합.
@MainActor
struct VirtualThumbstick: View {
    @Binding var x: Double
    @Binding var y: Double

    private let size: CGFloat = 120
    private var radius: CGFloat { size / 2 }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.06))
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
            // 십자 가이드
            Path { p in
                p.move(to: CGPoint(x: radius, y: 8)); p.addLine(to: CGPoint(x: radius, y: size - 8))
                p.move(to: CGPoint(x: 8, y: radius)); p.addLine(to: CGPoint(x: size - 8, y: radius))
            }.stroke(Color.white.opacity(0.10), lineWidth: 1)

            Circle()
                .fill(CockpitColors.live.opacity(0.8))
                .frame(width: 34, height: 34)
                .offset(x: CGFloat(x) * (radius - 18),
                        y: CGFloat(y) * (radius - 18))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = Double((v.location.x - radius) / (radius - 18))
                    let dy = Double((v.location.y - radius) / (radius - 18))
                    let clampedX = max(-1, min(1, dx))
                    let clampedY = max(-1, min(1, dy))
                    x = clampedX
                    y = clampedY
                }
                .onEnded { _ in
                    // 실물 스틱 스프링 — 손 떼면 중앙.
                    x = 0; y = 0
                }
        )
    }
}
