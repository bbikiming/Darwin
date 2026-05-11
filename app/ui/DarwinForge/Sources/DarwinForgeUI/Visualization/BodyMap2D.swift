import ForgeCore
import SwiftUI

/// 16개 관절의 위치를 사람 실루엣 위에 점으로 표시.
/// 클릭으로 관절 선택, 색상으로 한계 근접 / 온도 / 토크 시각화.
public struct BodyMap2D: View {
    public let pose: RobotPose
    public let states: [JointID: JointState]      // 비어있으면 강조 비활성
    @Binding public var selected: JointID?

    public init(pose: RobotPose,
                states: [JointID: JointState] = [:],
                selected: Binding<JointID?>) {
        self.pose = pose
        self.states = states
        self._selected = selected
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                silhouette
                    .stroke(DFColor.textSecondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: geo.size.width, height: geo.size.height)

                ForEach(JointID.allCases, id: \.self) { j in
                    let p = position(for: j, in: geo.size)
                    JointDot(joint: j,
                             pose: pose,
                             state: states[j],
                             isSelected: selected == j)
                        .position(p)
                        .onTapGesture { selected = j }
                }
            }
        }
        .frame(minWidth: 180, minHeight: 320)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous))
    }

    /// 16관절의 정규화 위치 (0..1 단위) — 상의 정면도 기준.
    private static let layout: [JointID: CGPoint] = [
        .headPan:        CGPoint(x: 0.50, y: 0.07),
        .headTilt:       CGPoint(x: 0.50, y: 0.13),
        .rShoulderPitch: CGPoint(x: 0.66, y: 0.22),
        .lShoulderPitch: CGPoint(x: 0.34, y: 0.22),
        .rShoulderRoll:  CGPoint(x: 0.74, y: 0.27),
        .lShoulderRoll:  CGPoint(x: 0.26, y: 0.27),
        .rElbow:         CGPoint(x: 0.78, y: 0.41),
        .lElbow:         CGPoint(x: 0.22, y: 0.41),
        .rHipYaw:        CGPoint(x: 0.58, y: 0.54),
        .lHipYaw:        CGPoint(x: 0.42, y: 0.54),
        .rHipRoll:       CGPoint(x: 0.58, y: 0.58),
        .lHipRoll:       CGPoint(x: 0.42, y: 0.58),
        .rHipPitch:      CGPoint(x: 0.58, y: 0.62),
        .lHipPitch:      CGPoint(x: 0.42, y: 0.62),
        .rKnee:          CGPoint(x: 0.58, y: 0.78),
        .lKnee:          CGPoint(x: 0.42, y: 0.78)
    ]

    private func position(for j: JointID, in size: CGSize) -> CGPoint {
        let p = Self.layout[j] ?? CGPoint(x: 0.5, y: 0.5)
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    /// 매우 단순화한 사람 실루엣 (정면도).
    private var silhouette: Path {
        Path { p in
            // (좌표는 0..1 정규화 기준 — frame에 맞춰 scale)
            let scale: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: x, y: y)
            }
            // 실제 그리기는 PathBuilder 안에서 GeometryReader 안의 size로 해야 하지만
            // SwiftUI Path는 자체 좌표계라 별도 컨테이너에서 transform.
            // → 여기서는 정규화 좌표로 그리고 .scaleEffect로 맞춤.
            _ = scale
        }
    }
}

extension BodyMap2D {
    /// 정규화 path를 frame size에 맞춰 그리는 헬퍼 (별도 reader).
    fileprivate var silhouettePath: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                // 머리 (원).
                p.addEllipse(in: CGRect(x: 0.42 * w, y: 0.02 * h, width: 0.16 * w, height: 0.13 * h))
                // 목.
                p.move(to: CGPoint(x: 0.50 * w, y: 0.15 * h))
                p.addLine(to: CGPoint(x: 0.50 * w, y: 0.18 * h))
                // 어깨 라인.
                p.move(to: CGPoint(x: 0.34 * w, y: 0.22 * h))
                p.addLine(to: CGPoint(x: 0.66 * w, y: 0.22 * h))
                // 몸통.
                p.move(to: CGPoint(x: 0.36 * w, y: 0.22 * h))
                p.addLine(to: CGPoint(x: 0.40 * w, y: 0.55 * h))
                p.move(to: CGPoint(x: 0.64 * w, y: 0.22 * h))
                p.addLine(to: CGPoint(x: 0.60 * w, y: 0.55 * h))
                p.move(to: CGPoint(x: 0.40 * w, y: 0.55 * h))
                p.addLine(to: CGPoint(x: 0.60 * w, y: 0.55 * h))
                // 좌측 팔.
                p.move(to: CGPoint(x: 0.34 * w, y: 0.22 * h))
                p.addLine(to: CGPoint(x: 0.22 * w, y: 0.41 * h))
                p.addLine(to: CGPoint(x: 0.18 * w, y: 0.55 * h))
                // 우측 팔.
                p.move(to: CGPoint(x: 0.66 * w, y: 0.22 * h))
                p.addLine(to: CGPoint(x: 0.78 * w, y: 0.41 * h))
                p.addLine(to: CGPoint(x: 0.82 * w, y: 0.55 * h))
                // 좌측 다리.
                p.move(to: CGPoint(x: 0.42 * w, y: 0.55 * h))
                p.addLine(to: CGPoint(x: 0.42 * w, y: 0.78 * h))
                p.addLine(to: CGPoint(x: 0.40 * w, y: 0.95 * h))
                p.addLine(to: CGPoint(x: 0.46 * w, y: 0.95 * h))
                // 우측 다리.
                p.move(to: CGPoint(x: 0.58 * w, y: 0.55 * h))
                p.addLine(to: CGPoint(x: 0.58 * w, y: 0.78 * h))
                p.addLine(to: CGPoint(x: 0.60 * w, y: 0.95 * h))
                p.addLine(to: CGPoint(x: 0.54 * w, y: 0.95 * h))
            }
            .stroke(DFColor.textSecondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    public func withSilhouette() -> some View {
        ZStack {
            silhouettePath
            self
        }
    }
}

// MARK: - JointDot

private struct JointDot: View {
    let joint: JointID
    let pose: RobotPose
    let state: JointState?
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: isSelected ? 16 : 12, height: isSelected ? 16 : 12)
                .overlay(
                    Circle().stroke(stroke, lineWidth: isSelected ? 2.5 : 1.2)
                )
                .shadow(color: fill.opacity(0.6), radius: isSelected ? 6 : 0)
        }
        .help("\(joint.koreanLabel) — \(Int(pose.degrees(joint)))°")
        .accessibilityLabel(joint.koreanLabel)
    }

    private var fill: Color {
        if let s = state {
            if s.presentTemperature >= 60 { return DFColor.danger }
            if abs(Int(s.goalPosition) - Int(s.presentPosition)) > 60 { return DFColor.warning }
            if s.torqueEnabled { return DFColor.success }
            return DFColor.textSecondary.opacity(0.5)
        }
        // 상태 없음 — 자세 단독 시: 한계 근접도로 색상.
        let raw = pose.raw(joint)
        let limits = joint.rawLimits
        let span = Double(limits.upperBound - limits.lowerBound)
        let dist = min(Double(raw - limits.lowerBound),
                       Double(limits.upperBound - raw)) / max(span / 2, 1)
        if dist < 0.08 { return DFColor.warning }
        return DFColor.accent
    }

    private var stroke: Color {
        isSelected ? DFColor.forge : .black.opacity(0.4)
    }
}
