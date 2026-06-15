import SwiftUI

/// Anbernic **RG G01** 게임패드 벡터 일러스트 — 평면 다이어그램을 대체하는 고품질 시각화.
/// (PRD 8절 / 실기기 조사 반영. DJI 비주얼과 동일 품질 바.)
///
/// # 실기기 정합 (조사 결과, 2026-06)
/// - **중앙 IPS 스마트 스크린** — RG G01 의 시그니처 (PS5식 터치패드 아님!).
/// - **비대칭 Xbox 배치**: 좌 스틱 상단-좌, 우 스틱 하단-우, D-Pad 하단-좌, ABXY 상단-우.
/// - 상단 엣지 LB/RB + LT/RT(아날로그), 중앙-하단 Start/Select, **후면 매크로 M1~M4**(힌트).
/// - 매핑 인덱스: axis0/1=좌스틱, 2/3=우스틱, 4/5=LT/RT, button0~3=ABXY, 4/5=LB/RB …
///
/// 데이터 인터페이스: `ControllerSnapshot`(라이브) + `ControllerBindingProfile`(매핑) +
/// `selectedBinding` + `onTap`. element 색: 매핑됨=초록, 선택=accent 링, 활성=글로우.
@MainActor
struct RGG01ControllerVisual: View {
    let snapshot: ControllerSnapshot
    let profile: ControllerBindingProfile
    let selectedBinding: ControllerBinding?
    let onTap: (ControllerBinding) -> Void

    private let canvas = CGSize(width: 560, height: 330)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(LinearGradient(colors: [Color.white.opacity(0.05), .clear],
                                        startPoint: .top, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))

            shell
            usbcNotch
            ipsScreen
            // 후면 매크로 힌트 (셸 뒤로, 흐리게)
            rearMacroHint("M1·M2 (후면)", at: CGPoint(x: 150, y: 256))
            rearMacroHint("M3·M4 (후면)", at: CGPoint(x: 410, y: 256))
            // 비대칭 Xbox 배치
            stickCluster(center: CGPoint(x: 200, y: 150), xIndex: 0, yIndex: 1, glow: .accentColor)
            dpad(center: CGPoint(x: 236, y: 210))
            faceButtons(center: CGPoint(x: 382, y: 142))
            stickCluster(center: CGPoint(x: 350, y: 218), xIndex: 2, yIndex: 3, glow: .blue)
            // 상단 엣지 — 트리거(위) / 범퍼(아래)
            triggerButton("LT", index: 4, at: CGPoint(x: 160, y: 58))
            triggerButton("RT", index: 5, at: CGPoint(x: 400, y: 58))
            shoulder("LB", .button(index: 4), at: CGPoint(x: 212, y: 80))
            shoulder("RB", .button(index: 5), at: CGPoint(x: 348, y: 80))
            // 중앙-하단 시스템 버튼
            centerButton("⊟", .button(index: 6), at: CGPoint(x: 262, y: 166))
            centerButton("≡", .button(index: 7), at: CGPoint(x: 298, y: 166))
        }
        .frame(width: canvas.width, height: canvas.height)
        .accessibilityIdentifier("cockpit.rgg01.controller.visual")
    }

    // MARK: - Shell / screen / ports

    private var shell: some View {
        ControllerShell()
            .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.18)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(ControllerShell().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .frame(width: 366, height: 212)
            .position(x: canvas.width / 2, y: 150)
    }

    /// RG G01 시그니처 — 중앙 IPS 스마트 스크린 (2.5D 글래스).
    private var ipsScreen: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.12), .black], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.14), .clear],
                                     startPoint: .top, endPoint: .center)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1))
            .overlay(
                VStack(spacing: 2) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 13)).foregroundStyle(Color.green.opacity(0.7))
                    Text("RG G01").font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                })
            .frame(width: 96, height: 56)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            .position(x: canvas.width / 2, y: 110)
    }

    private var usbcNotch: some View {
        Capsule().fill(Color.black.opacity(0.5))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .frame(width: 24, height: 6)
            .position(x: canvas.width / 2, y: 50)
    }

    /// 후면 매크로 M1~M4 — 전면 컨트롤 아님. 흐린 힌트만 (정보용).
    private func rearMacroHint(_ label: String, at point: CGPoint) -> some View {
        Text(label)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.white.opacity(0.30))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().stroke(Color.white.opacity(0.18),
                                         style: StrokeStyle(lineWidth: 1, dash: [3])))
            .position(point)
    }

    // MARK: - Sticks

    private func stickCluster(center: CGPoint, xIndex: Int, yIndex: Int, glow: Color) -> some View {
        let dx = snapshot.axis(xIndex), dy = snapshot.axis(yIndex)
        let live = abs(dx) > 0.2 || abs(dy) > 0.2
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0.25)],
                                     center: .center, startRadius: 2, endRadius: 30))
                .frame(width: 60, height: 60)
            Circle().stroke(glow.opacity(live ? 0.75 : 0), lineWidth: 3)
                .frame(width: 60, height: 60).blur(radius: 2)
            // 메탈 링
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5).frame(width: 60, height: 60)
            petal(.axis(index: yIndex, polarity: .negative), at: CGPoint(x: 0, y: -38), active: dy < -0.2)
            petal(.axis(index: yIndex, polarity: .positive), at: CGPoint(x: 0, y: 38), active: dy > 0.2)
            petal(.axis(index: xIndex, polarity: .negative), at: CGPoint(x: -38, y: 0), active: dx < -0.2)
            petal(.axis(index: xIndex, polarity: .positive), at: CGPoint(x: 38, y: 0), active: dx > 0.2)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .offset(x: CGFloat(dx) * 12, y: CGFloat(dy) * 12)
        }
        .position(center)
    }

    private func petal(_ binding: ControllerBinding, at offset: CGPoint, active: Bool) -> some View {
        Circle()
            .fill(fillColor(for: binding, active: active))
            .frame(width: 15, height: 15)
            .overlay(Circle().stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
            .offset(x: offset.x, y: offset.y)
            .contentShape(Circle())
            .onTapGesture { onTap(binding) }
    }

    // MARK: - Face buttons / D-pad

    private func faceButtons(center: CGPoint) -> some View {
        ZStack {
            faceButton("A", .button(index: 0), at: CGPoint(x: 0, y: 26), tint: .green)
            faceButton("B", .button(index: 1), at: CGPoint(x: 26, y: 0), tint: .red)
            faceButton("X", .button(index: 2), at: CGPoint(x: -26, y: 0), tint: .blue)
            faceButton("Y", .button(index: 3), at: CGPoint(x: 0, y: -26), tint: .yellow)
        }
        .position(center)
    }

    private func faceButton(_ label: String, _ binding: ControllerBinding,
                            at offset: CGPoint, tint: Color) -> some View {
        let active = isActive(binding)
        return Text(label)
            .font(.system(size: 12, weight: .bold))
            .frame(width: 30, height: 30)
            .background(Circle().fill(fillColor(for: binding, active: active, base: tint)))
            .overlay(Circle().stroke(strokeColor(for: binding, base: tint),
                                     lineWidth: isSelected(binding) ? 2.5 : 1))
            .shadow(color: active ? tint.opacity(0.7) : .black.opacity(0.35),
                    radius: active ? 7 : 2.5, y: active ? 0 : 1)
            .foregroundStyle(.white)
            .offset(x: offset.x, y: offset.y)
            .contentShape(Circle())
            .onTapGesture { onTap(binding) }
    }

    private func dpad(center: CGPoint) -> some View {
        ZStack {
            dpadArm("▲", .button(index: 10), at: CGPoint(x: 0, y: -20))
            dpadArm("▼", .button(index: 11), at: CGPoint(x: 0, y: 20))
            dpadArm("◀", .button(index: 12), at: CGPoint(x: -20, y: 0))
            dpadArm("▶", .button(index: 13), at: CGPoint(x: 20, y: 0))
        }
        .position(center)
    }

    private func dpadArm(_ label: String, _ binding: ControllerBinding, at offset: CGPoint) -> some View {
        let active = isActive(binding)
        return Text(label)
            .font(.system(size: 8, weight: .bold))
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(fillColor(for: binding, active: active)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(strokeColor(for: binding),
                                                              lineWidth: isSelected(binding) ? 2.5 : 1))
            .foregroundStyle(.white.opacity(0.85))
            .offset(x: offset.x, y: offset.y)
            .contentShape(Rectangle())
            .onTapGesture { onTap(binding) }
    }

    // MARK: - Shoulders / triggers / system

    private func shoulder(_ label: String, _ binding: ControllerBinding, at point: CGPoint) -> some View {
        let active = isActive(binding)
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 52, height: 17)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fillColor(for: binding, active: active)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
            .shadow(color: active ? Color.accentColor.opacity(0.6) : .black.opacity(0.3), radius: active ? 6 : 2, y: 1)
            .foregroundStyle(.white)
            .position(point)
            .contentShape(Rectangle())
            .onTapGesture { onTap(binding) }
    }

    /// LT/RT — 아날로그 트리거. 작은 버튼 + 하단에서 차오르는 라이브 fill.
    private func triggerButton(_ label: String, index: Int, at point: CGPoint) -> some View {
        let binding = ControllerBinding.axis(index: index, polarity: .positive)
        let v = max(0, snapshot.axis(index))
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fillColor(for: binding, active: v > 0.2))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color.cyan, Color.teal.opacity(0.85)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: CGFloat(v) * 18)
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 46, height: 18)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .position(point)
        .contentShape(Rectangle())
        .onTapGesture { onTap(binding) }
    }

    private func centerButton(_ label: String, _ binding: ControllerBinding, at point: CGPoint) -> some View {
        let active = isActive(binding)
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .frame(width: 26, height: 20)
            .background(Capsule().fill(fillColor(for: binding, active: active)))
            .overlay(Capsule().stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
            .foregroundStyle(.white.opacity(0.8))
            .position(point)
            .contentShape(Capsule())
            .onTapGesture { onTap(binding) }
    }

    // MARK: - Color logic

    private func isMapped(_ b: ControllerBinding) -> Bool { !profile.actions(boundTo: b).isEmpty }
    private func isSelected(_ b: ControllerBinding) -> Bool { selectedBinding == b }
    private func isActive(_ b: ControllerBinding) -> Bool {
        switch b {
        case .button(let i): return snapshot.button(i)
        case .axis(let i, let p):
            let v = snapshot.axis(i)
            return p == .positive ? v > 0.2 : v < -0.2
        case .unbound: return false
        }
    }

    private func fillColor(for b: ControllerBinding, active: Bool, base: Color = .secondary) -> Color {
        if active { return base == .secondary ? .accentColor.opacity(0.9) : base.opacity(0.9) }
        if isMapped(b) { return base == .secondary ? .green.opacity(0.5) : base.opacity(0.55) }
        return base == .secondary ? base.opacity(0.22) : base.opacity(0.32)
    }
    private func strokeColor(for b: ControllerBinding, base: Color = .secondary) -> Color {
        if isSelected(b) { return .accentColor }
        if isMapped(b) { return base == .secondary ? .green.opacity(0.7) : base.opacity(0.8) }
        return .white.opacity(0.25)
    }
}

/// 게임패드 실루엣 — 둥근 본체 + 양쪽 그립 horn.
private struct ControllerShell: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.18))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.06),
                   control1: CGPoint(x: rect.minX + w * 0.24, y: rect.minY),
                   control2: CGPoint(x: rect.minX + w * 0.38, y: rect.minY + h * 0.02))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.18),
                   control1: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + h * 0.02),
                   control2: CGPoint(x: rect.minX + w * 0.76, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.99, y: rect.minY + h * 0.62),
                   control1: CGPoint(x: rect.minX + w * 0.98, y: rect.minY + h * 0.30),
                   control2: CGPoint(x: rect.minX + w * 1.0, y: rect.minY + h * 0.48))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.74, y: rect.minY + h * 0.96),
                   control1: CGPoint(x: rect.minX + w * 0.97, y: rect.minY + h * 0.86),
                   control2: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.98))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.56, y: rect.minY + h * 0.66),
                   control1: CGPoint(x: rect.minX + w * 0.66, y: rect.minY + h * 0.94),
                   control2: CGPoint(x: rect.minX + w * 0.60, y: rect.minY + h * 0.78))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.44, y: rect.minY + h * 0.66),
                   control1: CGPoint(x: rect.minX + w * 0.52, y: rect.minY + h * 0.60),
                   control2: CGPoint(x: rect.minX + w * 0.48, y: rect.minY + h * 0.60))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.26, y: rect.minY + h * 0.96),
                   control1: CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.78),
                   control2: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.94))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.01, y: rect.minY + h * 0.62),
                   control1: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.98),
                   control2: CGPoint(x: rect.minX + w * 0.03, y: rect.minY + h * 0.86))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.18),
                   control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.48),
                   control2: CGPoint(x: rect.minX + w * 0.02, y: rect.minY + h * 0.30))
        p.closeSubpath()
        return p
    }
}
