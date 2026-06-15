import SwiftUI

/// 다이어그램 위에 항상 표시되는 콜아웃 라벨 레이어 — reWASD 패턴 (설계 §A).
///
/// `RGG01ControllerVisual` 과 동일한 560×330 좌표계에 ZStack 으로 겹쳐 그린다.
/// 캔버스 좌우 여백(셸 바깥 ~96px)에 라벨을 세로 분배하고, 각 라벨에서 해당
/// 컨트롤 앵커까지 리더라인을 잇는다. 라벨 탭 = **선택만** (클릭-투-바인드와 구분).
///
/// 색 코딩: 이동·회전=청록, 머리=보라, 안전=빨강(잠금), 보조=황색, 미설정=회색 점선.
/// 라이브 입력 시 라벨도 함께 밝아져 다이어그램↔라벨 1:1 대응을 학습시킨다.
@MainActor
struct ControllerCalloutOverlay: View {
    let snapshot: ControllerSnapshot
    let profile: ControllerBindingProfile
    let selectedBinding: ControllerBinding?
    let onSelect: (ControllerBinding) -> Void

    private let canvas = CGSize(width: 560, height: 330)
    private let labelWidth: CGFloat = 92
    private let verticalInset: CGFloat = 26

    private enum Side { case left, right }

    private struct PlacedCallout: Identifiable {
        let item: ControllerCalloutItem
        let center: CGPoint
        let edgeX: CGFloat
        var id: String { item.id }
    }

    var body: some View {
        let columns = ControllerCalloutModel.columns(for: profile)
        let placed = place(columns.left, side: .left) + place(columns.right, side: .right)
        return ZStack {
            leaderLines(placed)
            ForEach(placed) { calloutLabel($0) }
        }
        .frame(width: canvas.width, height: canvas.height)
        .accessibilityIdentifier("cockpit.controller.callout.overlay")
    }

    // MARK: - 배치

    private func place(_ items: [ControllerCalloutItem], side: Side) -> [PlacedCallout] {
        guard !items.isEmpty else { return [] }
        let usable = canvas.height - verticalInset * 2
        let step = usable / CGFloat(items.count)
        let centerX: CGFloat = side == .left ? 6 + labelWidth / 2 : canvas.width - 6 - labelWidth / 2
        let edgeX: CGFloat = side == .left ? 6 + labelWidth : canvas.width - 6 - labelWidth
        return items.enumerated().map { index, item in
            let y = verticalInset + step * (CGFloat(index) + 0.5)
            return PlacedCallout(item: item, center: CGPoint(x: centerX, y: y), edgeX: edgeX)
        }
    }

    // MARK: - 리더라인 (Canvas — 히트테스트 없음)

    private func leaderLines(_ placed: [PlacedCallout]) -> some View {
        Canvas { context, _ in
            for callout in placed {
                var path = Path()
                let from = CGPoint(x: callout.edgeX, y: callout.center.y)
                let mid = CGPoint(x: (from.x + callout.item.anchor.x) / 2, y: callout.center.y)
                path.move(to: from)
                path.addLine(to: mid)
                path.addLine(to: callout.item.anchor)
                context.stroke(path, with: .color(lineColor(callout.item)),
                               style: StrokeStyle(lineWidth: 1, dash: dash(callout.item)))
                context.fill(Path(ellipseIn: CGRect(x: callout.item.anchor.x - 1.5,
                                                    y: callout.item.anchor.y - 1.5,
                                                    width: 3, height: 3)),
                             with: .color(lineColor(callout.item)))
            }
        }
        .allowsHitTesting(false)
    }

    private func lineColor(_ item: ControllerCalloutItem) -> Color {
        if isSelected(item) { return .accentColor }
        return categoryColor(item.category).opacity(item.category == .unbound ? 0.35 : 0.55)
    }

    private func dash(_ item: ControllerCalloutItem) -> [CGFloat] {
        item.category == .unbound ? [3, 3] : []
    }

    // MARK: - 라벨

    private func calloutLabel(_ placed: PlacedCallout) -> some View {
        let item = placed.item
        let color = categoryColor(item.category)
        let active = isActive(item)
        let selected = isSelected(item)
        return VStack(spacing: 1) {
            HStack(spacing: 3) {
                Text(item.controlLabel)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                if item.locked {
                    Image(systemName: "lock.fill").font(.system(size: 6))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let glyph = item.modeGlyph {
                    Text(glyph).font(.system(size: 8)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Text(item.actionLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(item.category == .unbound ? .white.opacity(0.5) : .white)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: labelWidth)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(active ? 0.55 : (item.category == .unbound ? 0.10 : 0.22))))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Color.accentColor : color.opacity(0.6),
                        style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: dash(item))))
        .position(placed.center)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { onSelect(item.selectionBinding) }
        .help("\(item.controlLabel) — \(item.actionLabel). 탭하면 선택됩니다.")
        .accessibilityIdentifier("cockpit.controller.callout.\(item.id)")
    }

    // MARK: - 상태 판정

    private func isSelected(_ item: ControllerCalloutItem) -> Bool {
        guard let selectedBinding else { return false }
        return item.memberBindings.contains(selectedBinding)
    }

    private func isActive(_ item: ControllerCalloutItem) -> Bool {
        item.memberBindings.contains { binding in
            switch binding {
            case .button(let index): return snapshot.button(index)
            case .axis(let index, let polarity):
                let value = snapshot.axis(index)
                return polarity == .positive ? value > 0.2 : value < -0.2
            case .unbound: return false
            }
        }
    }

    private func categoryColor(_ category: ControllerCalloutCategory) -> Color {
        switch category {
        case .movement: return .teal
        case .head: return .purple
        case .safety: return .red
        case .assist: return .orange
        case .unbound: return .secondary
        }
    }
}
