import SwiftUI

/// 범용 게임패드 다이어그램 (Xbox / RG G01 레이아웃) — DJI 매핑 시트의 시각화에 대응.
///
/// 각 입력 요소를 탭하면 `onTap(binding)` 으로 해당 `ControllerBinding` 을 알린다
/// (action-first flow: 좌측에서 동작 선택 → 다이어그램 element 클릭 → 매핑).
/// 라이브 하이라이트는 `snapshot` 기반 — 매핑됨=초록, 선택=파랑, 활성(입력중)=밝은 파랑.
@MainActor
struct ControllerDiagramView: View {
    let snapshot: ControllerSnapshot
    let profile: ControllerBindingProfile
    let selectedBinding: ControllerBinding?
    let onTap: (ControllerBinding) -> Void

    // 다이어그램 캔버스 기준 크기.
    private let canvas = CGSize(width: 540, height: 320)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.secondary.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.secondary.opacity(0.25), lineWidth: 1))

            Text("GAMEPAD").font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .position(x: canvas.width/2, y: 60)

            // 숄더 (LB/RB)
            shoulder("LB", .button(index: 4), at: CGPoint(x: 120, y: 30))
            shoulder("RB", .button(index: 5), at: CGPoint(x: 420, y: 30))

            // 트리거 (LT/RT) — 축 4/5
            trigger("LT", index: 4, at: CGPoint(x: 70, y: 95))
            trigger("RT", index: 5, at: CGPoint(x: 470, y: 95))

            // 좌 스틱 (axis 0/1) + 4 petal
            stickCluster(center: CGPoint(x: 150, y: 175), xIndex: 0, yIndex: 1)
            // 우 스틱 (axis 2/3) + 4 petal
            stickCluster(center: CGPoint(x: 390, y: 175), xIndex: 2, yIndex: 3)

            // 면 버튼 ABXY (우측 다이아몬드) — button 0/1/2/3
            faceButton("A", .button(index: 0), at: CGPoint(x: 480, y: 215), tint: .green)
            faceButton("B", .button(index: 1), at: CGPoint(x: 510, y: 185), tint: .red)
            faceButton("X", .button(index: 2), at: CGPoint(x: 450, y: 185), tint: .blue)
            faceButton("Y", .button(index: 3), at: CGPoint(x: 480, y: 155), tint: .yellow)

            // D-pad (좌측 십자) — button 10/11/12/13
            faceButton("▲", .button(index: 10), at: CGPoint(x: 60, y: 215), tint: .secondary)
            faceButton("▼", .button(index: 11), at: CGPoint(x: 60, y: 265), tint: .secondary)
            faceButton("◀", .button(index: 12), at: CGPoint(x: 35, y: 240), tint: .secondary)
            faceButton("▶", .button(index: 13), at: CGPoint(x: 85, y: 240), tint: .secondary)

            // View / Menu — button 6/7
            faceButton("⊟", .button(index: 6), at: CGPoint(x: 245, y: 175), tint: .secondary)
            faceButton("≡", .button(index: 7), at: CGPoint(x: 295, y: 175), tint: .secondary)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    // MARK: - 스틱 클러스터 (중앙 스틱 + 4방향 petal)

    private func stickCluster(center: CGPoint, xIndex: Int, yIndex: Int) -> some View {
        let dx = snapshot.axis(xIndex), dy = snapshot.axis(yIndex)
        return ZStack {
            // 베이스 + 라이브 위치 점
            Circle().fill(Color.black.opacity(0.35))
                .frame(width: 66, height: 66)
            Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: 66, height: 66)
            Circle().fill(Color.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .offset(x: CGFloat(dx) * 22, y: CGFloat(dy) * 22)
            // 4 petal
            petal(.axis(index: yIndex, polarity: .negative), at: CGPoint(x: 0, y: -42), active: dy < -0.2)
            petal(.axis(index: yIndex, polarity: .positive), at: CGPoint(x: 0, y: 42), active: dy > 0.2)
            petal(.axis(index: xIndex, polarity: .negative), at: CGPoint(x: -42, y: 0), active: dx < -0.2)
            petal(.axis(index: xIndex, polarity: .positive), at: CGPoint(x: 42, y: 0), active: dx > 0.2)
        }
        .position(center)
    }

    private func petal(_ binding: ControllerBinding, at offset: CGPoint, active: Bool) -> some View {
        Circle()
            .fill(fillColor(for: binding, active: active))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
            .offset(x: offset.x, y: offset.y)
            .contentShape(Circle())
            .onTapGesture { onTap(binding) }
    }

    // MARK: - 버튼 / 숄더 / 트리거

    private func faceButton(_ label: String, _ binding: ControllerBinding, at point: CGPoint, tint: Color) -> some View {
        let active = isActive(binding)
        return Text(label)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 30, height: 30)
            .background(Circle().fill(fillColor(for: binding, active: active, base: tint)))
            .overlay(Circle().stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
            .foregroundStyle(.primary)
            .position(point)
            .contentShape(Circle())
            .onTapGesture { onTap(binding) }
    }

    private func shoulder(_ label: String, _ binding: ControllerBinding, at point: CGPoint) -> some View {
        let active = isActive(binding)
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 60, height: 22)
            .background(RoundedRectangle(cornerRadius: 8).fill(fillColor(for: binding, active: active)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
            .foregroundStyle(.primary)
            .position(point)
            .contentShape(Rectangle())
            .onTapGesture { onTap(binding) }
    }

    private func trigger(_ label: String, index: Int, at point: CGPoint) -> some View {
        let binding = ControllerBinding.axis(index: index, polarity: .positive)
        let v = snapshot.axis(index)
        return VStack(spacing: 3) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.3)).frame(width: 26, height: 50)
                RoundedRectangle(cornerRadius: 5).fill(Color.cyan.opacity(0.7))
                    .frame(width: 26, height: max(0, CGFloat(v) * 50))
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(strokeColor(for: binding), lineWidth: isSelected(binding) ? 2.5 : 1))
        }
        .position(point)
        .contentShape(Rectangle())
        .onTapGesture { onTap(binding) }
    }

    // MARK: - 색 결정 (매핑/선택/활성)

    private func isMapped(_ binding: ControllerBinding) -> Bool {
        !profile.actions(boundTo: binding).isEmpty
    }
    private func isSelected(_ binding: ControllerBinding) -> Bool {
        selectedBinding == binding
    }
    private func isActive(_ binding: ControllerBinding) -> Bool {
        switch binding {
        case .button(let i):       return snapshot.button(i)
        case .axis(let i, let p):
            let v = snapshot.axis(i)
            return p == .positive ? v > 0.2 : v < -0.2
        case .unbound:             return false
        }
    }

    private func fillColor(for binding: ControllerBinding, active: Bool, base: Color = .secondary) -> Color {
        if active { return .accentColor.opacity(0.9) }
        if isMapped(binding) { return .green.opacity(0.5) }
        return base.opacity(0.18)
    }
    private func strokeColor(for binding: ControllerBinding) -> Color {
        if isSelected(binding) { return .accentColor }
        if isMapped(binding) { return .green.opacity(0.7) }
        return .secondary.opacity(0.35)
    }
}
