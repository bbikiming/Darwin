import AppKit
import SceneKit
import SwiftUI

/// 3ds Max / Maya 스타일 ViewCube — 메인 카메라와 분리된 자체 회전 위젯.
///
/// **인터랙션**
/// - 큐브 위에서 드래그: 큐브 자유 회전 (메인 view에 영향 없음)
/// - 큐브 면 클릭(드래그 없이): 메인 카메라가 그 face view로 부드럽게 전환
/// - hover: 면이 파란색으로 glow + 회전 가능 cursor
///
/// **스타일**
/// - 큐브 6면에 한국어 라벨 (앞·뒤·왼쪽·오른쪽·위·아래)
/// - 면별 색상 테마 (위=하늘색, 아래=흙색, 측면=회색)
/// - 60Hz lerp smoothing + inertia (드래그 끝나도 부드럽게 감속)
public final class ViewCube3D: NSView {

    // MARK: - Public API

    public weak var controller: CameraController?

    // MARK: - Cube own rotation state (메인 카메라와 독립)

    private var desiredRy: CGFloat = -.pi / 4   // 초기 isometric — 우측 face 보임
    private var desiredRx: CGFloat =  .pi / 8   // 살짝 위에서 — 위 face 보임
    private var ry: CGFloat = -.pi / 4
    private var rx: CGFloat =  .pi / 8

    private var ryVelocity: CGFloat = 0
    private var rxVelocity: CGFloat = 0

    // Tunables
    private let dragSensitivity: CGFloat = 0.012
    private let smoothing: CGFloat = 0.40
    private let inertiaDecay: CGFloat = 0.86
    private let velocityCutoff: CGFloat = 0.0005
    private let clickDragThreshold: CGFloat = 4.0   // px

    // MARK: - SCNView state

    private let scnView: SCNView
    private let cubeNode: SCNNode
    private let labelMaterials: [SCNMaterial]
    private var tickTimer: Timer?

    private var dragLastPos: NSPoint?
    private var dragStartPos: NSPoint?
    private var dragTotalDistance: CGFloat = 0
    private var hoveredFaceIndex: Int = -1

    // SCNBox material 인덱스 → CameraFace.
    // [+X, -X, +Y, -Y, +Z, -Z]
    // axis-angle 매핑(120°): ROS X+(robot 정면) → SceneKit Z-, ROS Y-(robot 우측) → SceneKit X+.
    // 큐브는 자체 좌표계(SceneKit) 기준 face 라벨링.
    // 메인 카메라가 큐브 +Z(앞) 쪽에 있으면 robot 정면을 본다 (main_az=π).
    private static let faceForMaterialIndex: [CameraFace] = [
        .right,    // +X (큐브 오른쪽 라벨)
        .left,     // -X
        .top,      // +Y
        .bottom,   // -Y
        .front,    // +Z (앞)
        .back      // -Z
    ]

    // MARK: - Init

    public init(controller: CameraController?) {
        self.scnView = SCNView(frame: .zero)
        self.cubeNode = SCNNode()
        self.labelMaterials = Self.makeFaceMaterials()
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        addSubview(scnView)
        scnView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scnView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scnView.topAnchor.constraint(equalTo: topAnchor),
            scnView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        buildScene()
        startTickLoop()
        applyCubeRotation()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: - Scene

    private func buildScene() {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // 큐브 (살짝 라운드된 모서리).
        let box = SCNBox(width: 1.0, height: 1.0, length: 1.0, chamferRadius: 0.06)
        box.materials = labelMaterials
        cubeNode.geometry = box
        scene.rootNode.addChildNode(cubeNode)

        // 라이팅 (소프트, burn-out 방지).
        let key = SCNLight()
        key.type = .directional
        key.intensity = 480
        key.color = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.95, alpha: 1.0)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(2, 3, 4)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 220
        fill.color = NSColor(calibratedRed: 0.85, green: 0.92, blue: 1.00, alpha: 1.0)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(-2, 1, 1)
        fillNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillNode)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 320
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        // 카메라 (고정).
        let cam = SCNCamera()
        cam.fieldOfView = 28
        cam.zNear = 0.1
        cam.zFar = 20
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, 4.0)
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)

        scnView.scene = scene
        scnView.backgroundColor = .clear
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 60
        scnView.pointOfView = camNode
    }

    // MARK: - 60Hz tick (smoothing + inertia)

    private func startTickLoop() {
        tickTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        // Inertia (드래그 중이 아니면).
        if dragLastPos == nil {
            desiredRy += ryVelocity
            desiredRx = clampRx(desiredRx + rxVelocity)
            ryVelocity *= inertiaDecay
            rxVelocity *= inertiaDecay
            if abs(ryVelocity) < velocityCutoff { ryVelocity = 0 }
            if abs(rxVelocity) < velocityCutoff { rxVelocity = 0 }
        }
        // Smoothing — applied → desired. Cutoff로 정확 도달 보장.
        ry += (desiredRy - ry) * smoothing
        if abs(desiredRy - ry) < 0.0008 { ry = desiredRy }
        rx += (desiredRx - rx) * smoothing
        if abs(desiredRx - rx) < 0.0008 { rx = desiredRx }
        applyCubeRotation()
    }

    private func applyCubeRotation() {
        cubeNode.eulerAngles = SCNVector3(Float(rx), Float(ry), 0)
    }

    @inline(__always)
    private func clampRx(_ v: CGFloat) -> CGFloat {
        let limit: CGFloat = .pi / 2 - 0.05
        return max(-limit, min(limit, v))
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStartPos = p
        dragLastPos = p
        dragTotalDistance = 0
        // inertia 차단.
        ryVelocity = 0
        rxVelocity = 0
        NSCursor.closedHand.push()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let last = dragLastPos else { return }
        let now = convert(event.locationInWindow, from: nil)
        let dx = now.x - last.x
        let dy = now.y - last.y
        dragLastPos = now
        dragTotalDistance += hypot(dx, dy)

        // 큐브 자체 회전.
        let azDelta = dx * dragSensitivity
        let elDelta = dy * dragSensitivity
        desiredRy -= azDelta
        desiredRx = clampRx(desiredRx - elDelta)
        ryVelocity = -azDelta
        rxVelocity = -elDelta
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            NSCursor.pop()
            dragStartPos = nil
            dragLastPos = nil
        }
        // 드래그 거리가 작으면 클릭으로 처리 — face select.
        guard dragTotalDistance < clickDragThreshold else { return }

        let p = scnView.convert(event.locationInWindow, from: nil)
        let hits = scnView.hitTest(p, options: [
            .boundingBoxOnly: false,
            .firstFoundOnly: true
        ])
        guard let hit = hits.first else { return }
        let idx = hit.geometryIndex
        if idx >= 0, idx < Self.faceForMaterialIndex.count {
            let face = Self.faceForMaterialIndex[idx]
            controller?.goToFace(face)
            // 큐브를 그 face로도 부드럽게 회전 (시각 피드백).
            rotateToFace(face)
        }
    }

    /// 클릭한 face의 라벨이 카메라 쪽을 향하도록 큐브를 회전 (최단 경로, 점프 없음).
    private func rotateToFace(_ face: CameraFace) {
        let targetRy: CGFloat
        let targetRx: CGFloat
        switch face {
        case .front:    targetRy = 0;            targetRx = 0
        case .back:     targetRy = .pi;          targetRx = 0
        case .right:    targetRy = -.pi / 2;     targetRx = 0
        case .left:     targetRy =  .pi / 2;     targetRx = 0
        case .top:      targetRy = 0;            targetRx =  .pi / 2 - 0.05
        case .bottom:   targetRy = 0;            targetRx = -.pi / 2 + 0.05
        case .isometric: targetRy = -.pi / 4;    targetRx = .pi / 8
        }
        // applied(ry)는 그대로, desired만 applied 근방의 등가값(±π)으로 set.
        let twoPi: CGFloat = 2 * .pi
        var diff = (targetRy - ry).truncatingRemainder(dividingBy: twoPi)
        if diff >  .pi { diff -= twoPi }
        if diff < -.pi { diff += twoPi }
        desiredRy = ry + diff
        desiredRx = clampRx(targetRx)
        ryVelocity = 0
        rxVelocity = 0
    }

    // MARK: - Hover

    private var trackingArea: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push()
    }

    public override func mouseExited(with event: NSEvent) {
        if hoveredFaceIndex != -1 {
            hoveredFaceIndex = -1
            updateHoverHighlight()
        }
        NSCursor.pop()
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = scnView.convert(event.locationInWindow, from: nil)
        let hits = scnView.hitTest(p, options: [.firstFoundOnly: true])
        let newIdx = hits.first?.geometryIndex ?? -1
        if newIdx != hoveredFaceIndex {
            hoveredFaceIndex = newIdx
            updateHoverHighlight()
        }
    }

    private func updateHoverHighlight() {
        for (i, mat) in labelMaterials.enumerated() {
            if i == hoveredFaceIndex {
                mat.emission.contents = NSColor(calibratedRed: 0.10, green: 0.55, blue: 1.00, alpha: 0.55)
            } else {
                mat.emission.contents = NSColor.black
            }
        }
        cubeNode.geometry?.materials = labelMaterials
    }

    // MARK: - Face textures

    /// 6 면용 라벨 텍스처 — `[+X, -X, +Y, -Y, +Z, -Z]` 순서.
    private static func makeFaceMaterials() -> [SCNMaterial] {
        let labels: [(text: String, color: NSColor, accent: NSColor)] = [
            ("오른쪽", NSColor(calibratedWhite: 0.86, alpha: 1.0),
                       NSColor(calibratedRed: 0.93, green: 0.30, blue: 0.30, alpha: 1.0)), // +X (R 빨강 액센트)
            ("왼쪽",   NSColor(calibratedWhite: 0.78, alpha: 1.0),
                       NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.95, alpha: 1.0)), // -X (L 파랑)
            ("위",     NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.95, alpha: 1.0),
                       NSColor(calibratedWhite: 0.95, alpha: 1.0)),                       // +Y (sky)
            ("아래",   NSColor(calibratedRed: 0.62, green: 0.50, blue: 0.40, alpha: 1.0),
                       NSColor(calibratedWhite: 0.90, alpha: 1.0)),                       // -Y (ground)
            ("앞",     NSColor(calibratedWhite: 0.92, alpha: 1.0),
                       NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.45, alpha: 1.0)), // +Z (Front 초록)
            ("뒤",     NSColor(calibratedWhite: 0.72, alpha: 1.0),
                       NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.55, alpha: 1.0))  // -Z
        ]
        return labels.map { makeFaceMaterial(text: $0.text, base: $0.color, accent: $0.accent) }
    }

    private static func makeFaceMaterial(text: String, base: NSColor, accent: NSColor) -> SCNMaterial {
        let size = NSSize(width: 256, height: 256)
        let img = NSImage(size: size)
        img.lockFocus()
        // 배경 그라데이션 (위쪽이 살짝 밝음 — 입체감).
        let grad = NSGradient(colors: [
            base.blended(withFraction: 0.10, of: .white) ?? base,
            base,
            base.blended(withFraction: 0.15, of: .black) ?? base
        ])
        grad?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // 액센트 줄 (상단·하단).
        accent.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: 0, width: 256, height: 6).fill()
        NSRect(x: 0, y: 250, width: 256, height: 6).fill()

        // 테두리.
        NSColor(calibratedWhite: 0.32, alpha: 0.65).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 4, y: 4, width: 248, height: 248))
        border.lineWidth = 5
        border.stroke()

        // 라벨 텍스트.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 60, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1.0)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let strSize = str.size()
        let textRect = NSRect(
            x: (size.width - strSize.width) / 2,
            y: (size.height - strSize.height) / 2,
            width: strSize.width, height: strSize.height
        )
        // 텍스트 그림자 (depth).
        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            str.draw(in: textRect)
            ctx.restoreGraphicsState()
        } else {
            str.draw(in: textRect)
        }
        img.unlockFocus()

        let mat = SCNMaterial()
        mat.diffuse.contents = img
        mat.specular.contents = NSColor.white.withAlphaComponent(0.20)
        mat.shininess = 16
        mat.lightingModel = .blinn
        return mat
    }
}

// MARK: - SwiftUI wrapper

public struct ViewCubeWidget: NSViewRepresentable {
    public let controller: CameraController

    public init(controller: CameraController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> ViewCube3D {
        ViewCube3D(controller: controller)
    }

    public func updateNSView(_ nsView: ViewCube3D, context: Context) {
        nsView.controller = controller
    }
}
