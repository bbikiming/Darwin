import ForgeCore
import SceneKit
import SwiftUI

// MARK: - DarwinOP2Rig

/// ROBOTIS-OP2 (DARwIn-OP 2세대) 형상 본 트리.
///
/// **W0 (2026-06-11)**: 종전 `RobotScene3D.swift` 하단에서 이 파일로 분리. 로직 변화 0.
/// STL mesh 로드 실패 시 폴백 rig 이며 `CockpitChaseSceneView` 도 동일 클래스를 재사용.
final class DarwinOP2Rig {
    let root: SCNNode
    private var joints: [JointID: SCNNode] = [:]
    private var highlightMeshes: [JointID: [SCNNode]] = [:]
    private var originalEmissions: [ObjectIdentifier: NSColor] = [:]

    // ────────────────────────────────────────────────────────────────────────
    // 컬러 팔레트 (Webots OP2 스크린샷 기반)
    // ────────────────────────────────────────────────────────────────────────

    static let bodyShell    = NSColor(calibratedRed: 0.78, green: 0.78, blue: 0.80, alpha: 1.0)  // 본체 회색
    static let bodyShellHi  = NSColor(calibratedRed: 0.86, green: 0.86, blue: 0.88, alpha: 1.0)  // 밝은 면
    static let helmetDark   = NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.21, alpha: 1.0)  // 헬멧
    static let motorBlack   = NSColor(calibratedWhite: 0.13, alpha: 1.0)
    static let motorCap     = NSColor(calibratedWhite: 0.83, alpha: 1.0)
    static let detailDark   = NSColor(calibratedWhite: 0.20, alpha: 1.0)
    static let footBlack    = NSColor(calibratedWhite: 0.09, alpha: 1.0)
    static let solWhite     = NSColor(calibratedWhite: 0.88, alpha: 1.0)
    static let eyePurple    = NSColor(calibratedRed: 0.42, green: 0.36, blue: 1.00, alpha: 1.0)
    static let eyePupil     = NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.10, alpha: 1.0)
    static let ledGreen     = NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.42, alpha: 1.0)
    static let darwinRed    = NSColor(calibratedRed: 0.86, green: 0.14, blue: 0.10, alpha: 1.0)

    // ────────────────────────────────────────────────────────────────────────
    // 치수 (실제 ROBOTIS-OP2: 키 454.5 mm, 단위 m)
    // ────────────────────────────────────────────────────────────────────────

    static let pelvisHeight: CGFloat = 0.358

    // 머리
    static let helmetW: CGFloat = 0.094
    static let helmetH: CGFloat = 0.084
    static let helmetD: CGFloat = 0.092
    static let eyeRadius: CGFloat = 0.012

    // 가슴
    static let chestW: CGFloat = 0.124
    static let chestH: CGFloat = 0.122
    static let chestD: CGFloat = 0.084

    // 어깨/골반 anchor offsets
    static let shoulderOffX: CGFloat = 0.073
    static let shoulderOffY: CGFloat = 0.054
    static let hipOffX: CGFloat = 0.044
    static let hipOffY: CGFloat = -0.022

    // 팔 — Webots OP2처럼 stocky 비율
    static let upperArmLen: CGFloat = 0.072
    static let upperArmDia: CGFloat = 0.042
    static let forearmLen:  CGFloat = 0.140
    static let forearmDia:  CGFloat = 0.038

    // 다리 — 본 길이 +20%, 굵기 +25%
    static let thighLen: CGFloat = 0.110
    static let thighDia: CGFloat = 0.056
    static let shinLen:  CGFloat = 0.110
    static let shinDia:  CGFloat = 0.052

    // 발
    static let footW: CGFloat = 0.078
    static let footH: CGFloat = 0.028
    static let footD: CGFloat = 0.118
    static let footChamfer: CGFloat = 0.014

    init() {
        root = SCNNode()
        root.position = SCNVector3(0, Self.pelvisHeight, 0)
        buildBody()
    }

    // MARK: - Pose

    func apply(pose: RobotPose) {
        for j in JointID.allCases {
            guard let node = joints[j] else { continue }
            let rad = pose.radians(j)
            let robotAxis = j.rotationAxis
            let sceneAxis: SCNVector3
            if robotAxis == SIMD3(0, 1, 0) {
                sceneAxis = SCNVector3(1, 0, 0)        // pitch → SceneKit X
            } else if robotAxis == SIMD3(1, 0, 0) {
                sceneAxis = SCNVector3(0, 0, 1)        // roll → SceneKit Z
            } else {
                sceneAxis = SCNVector3(0, 1, 0)        // yaw → SceneKit Y
            }
            let isLeft = !j.rawValue.isOnRightHalf
            let sign: CGFloat = (isLeft && j.mirrorSignFlip) ? -1 : 1
            node.rotation = SCNVector4(sceneAxis.x, sceneAxis.y, sceneAxis.z,
                                       CGFloat(rad) * sign)
        }
    }

    func highlight(_ joint: JointID?) {
        for (_, meshes) in highlightMeshes {
            for m in meshes {
                let key = ObjectIdentifier(m)
                m.geometry?.firstMaterial?.emission.contents =
                    originalEmissions[key] ?? NSColor.black
            }
        }
        guard let j = joint, let meshes = highlightMeshes[j] else { return }
        for m in meshes {
            m.geometry?.firstMaterial?.emission.contents =
                NSColor.systemOrange.withAlphaComponent(0.55)
        }
    }

    // MARK: - Build

    private func buildBody() {
        // ── 골반: 검은 라운드 박스 (모터 어셈블리)
        let pelvis = makeBox(w: 0.090, h: 0.038, d: 0.062,
                             color: Self.motorBlack, chamfer: 0.008)
        pelvis.position = SCNVector3(0, 0, 0)
        root.addChildNode(pelvis)

        // 골반 위 흰색 마운트 (척추 베이스)
        let spineMount = makeBox(w: 0.072, h: 0.022, d: 0.052,
                                  color: Self.bodyShell, chamfer: 0.005)
        spineMount.position = SCNVector3(0, 0.030, 0)
        root.addChildNode(spineMount)

        // ── 가슴 어셈블리
        let chestRoot = SCNNode()
        chestRoot.position = SCNVector3(0, Self.chestH / 2 + 0.045, 0)
        root.addChildNode(chestRoot)

        // 검은 inner spine (가슴판 뒤)
        let innerSpine = makeBox(w: Self.chestW * 0.62,
                                  h: Self.chestH * 0.92,
                                  d: Self.chestD * 0.86,
                                  color: Self.detailDark, chamfer: 0.004)
        chestRoot.addChildNode(innerSpine)

        // 흰 가슴판 (앞면)
        let chestPlate = makeBox(w: Self.chestW,
                                  h: Self.chestH * 0.86,
                                  d: 0.020,
                                  color: Self.bodyShell, chamfer: 0.012)
        chestPlate.position = SCNVector3(0, -0.005, Self.chestD / 2 + 0.001)
        chestRoot.addChildNode(chestPlate)

        // 가슴 가운데 흰 layered 패널 (V-line 대신 매끈한 디테일)
        let centerPanel = makeBox(w: Self.chestW * 0.46,
                                   h: Self.chestH * 0.50,
                                   d: 0.006,
                                   color: Self.bodyShellHi, chamfer: 0.006)
        centerPanel.position = SCNVector3(0, 0.005, Self.chestD / 2 + 0.011)
        chestRoot.addChildNode(centerPanel)

        // 작은 다윈 로고 (빨강 LED)
        let logo = SCNSphere(radius: 0.0055)
        let logoMat = SCNMaterial()
        logoMat.diffuse.contents = Self.darwinRed
        logoMat.emission.contents = Self.darwinRed
        logoMat.lightingModel = .constant
        logo.firstMaterial = logoMat
        let logoNode = SCNNode(geometry: logo)
        logoNode.position = SCNVector3(0, -0.020, Self.chestD / 2 + 0.013)
        chestRoot.addChildNode(logoNode)

        // 가슴 측면 어깨 마운트 — 더 라운드한 회색 캡슐 형태.
        let shoulderMountR = makeBox(w: 0.038, h: 0.066, d: Self.chestD * 0.86,
                                      color: Self.bodyShellHi, chamfer: 0.018)
        shoulderMountR.position = SCNVector3(Self.chestW / 2 + 0.016,
                                              Self.chestH / 2 - 0.038, 0)
        chestRoot.addChildNode(shoulderMountR)

        let shoulderMountL = makeBox(w: 0.038, h: 0.066, d: Self.chestD * 0.86,
                                      color: Self.bodyShellHi, chamfer: 0.018)
        shoulderMountL.position = SCNVector3(-(Self.chestW / 2 + 0.016),
                                              Self.chestH / 2 - 0.038, 0)
        chestRoot.addChildNode(shoulderMountL)

        // 등판 (뒤 박스)
        let backPanel = makeBox(w: Self.chestW * 0.96,
                                 h: Self.chestH * 0.82,
                                 d: 0.018,
                                 color: Self.bodyShell, chamfer: 0.010)
        backPanel.position = SCNVector3(0, -0.005, -Self.chestD / 2 - 0.001)
        chestRoot.addChildNode(backPanel)

        // ── 머리 (목 → headPan → headTilt → 헬멧)
        let neckBase = SCNNode()
        neckBase.position = SCNVector3(0, Self.chestH / 2 + 0.002, -0.005)
        chestRoot.addChildNode(neckBase)

        // 짧고 두꺼운 목.
        let neckCyl = SCNCylinder(radius: 0.016, height: 0.014)
        neckCyl.firstMaterial = darkMat()
        let neckCylNode = SCNNode(geometry: neckCyl)
        neckCylNode.position = SCNVector3(0, 0.007, 0)
        neckBase.addChildNode(neckCylNode)

        let headPanNode = SCNNode()
        headPanNode.position = SCNVector3(0, 0.014, 0)
        neckBase.addChildNode(headPanNode)
        joints[.headPan] = headPanNode

        let headTiltNode = SCNNode()
        headTiltNode.position = SCNVector3(0, 0.005, 0)
        headPanNode.addChildNode(headTiltNode)
        joints[.headTilt] = headTiltNode

        buildHelmet(into: headTiltNode)

        // ── 어깨/팔
        buildArm(side: .right, attach: chestRoot,
                 anchor: SCNVector3( Self.chestW / 2 + 0.030,
                                     Self.chestH / 2 - 0.038, 0))
        buildArm(side: .left, attach: chestRoot,
                 anchor: SCNVector3(-(Self.chestW / 2 + 0.030),
                                      Self.chestH / 2 - 0.038, 0))

        // ── 다리
        buildLeg(side: .right, attach: pelvis,
                 anchor: SCNVector3( Self.hipOffX, Self.hipOffY, 0))
        buildLeg(side: .left, attach: pelvis,
                 anchor: SCNVector3(-Self.hipOffX, Self.hipOffY, 0))
    }

    // MARK: - Head (헬멧 + 큰 보라 눈 + 정수리 LED)

    private func buildHelmet(into parent: SCNNode) {
        // 메인 헬멧 — chamfer 큰 박스. 머리 중심을 (0, helmetH/2, 0)으로.
        let helmet = makeBox(w: Self.helmetW,
                              h: Self.helmetH,
                              d: Self.helmetD,
                              color: Self.helmetDark,
                              chamfer: 0.022)
        helmet.position = SCNVector3(0, Self.helmetH / 2, 0)
        parent.addChildNode(helmet)
        registerHighlight(.headPan, [helmet])
        registerHighlight(.headTilt, [helmet])

        // 정수리 흰 panel (cap) — 헬멧 윗면에 딱 붙임.
        let capH: CGFloat = 0.012
        let cap = makeBox(w: Self.helmetW * 0.62, h: capH, d: Self.helmetD * 0.66,
                          color: Self.bodyShell, chamfer: 0.006)
        cap.position = SCNVector3(0, Self.helmetH + capH / 2 - 0.002, 0)
        parent.addChildNode(cap)

        // 정수리 녹색 LED
        let ledGeom = SCNSphere(radius: 0.0048)
        let ledMat = SCNMaterial()
        ledMat.diffuse.contents = Self.ledGreen
        ledMat.emission.contents = Self.ledGreen
        ledMat.lightingModel = .constant
        ledGeom.firstMaterial = ledMat
        let ledNode = SCNNode(geometry: ledGeom)
        ledNode.position = SCNVector3(0, Self.helmetH + capH + 0.001, 0.014)
        parent.addChildNode(ledNode)

        // 헬멧 측면 흰 ridge (귀 부분)
        let ridgeL = makeBox(w: 0.005, h: 0.034, d: 0.046,
                              color: Self.bodyShell, chamfer: 0.002)
        ridgeL.position = SCNVector3(-Self.helmetW / 2 - 0.001, Self.helmetH * 0.55, 0)
        parent.addChildNode(ridgeL)
        let ridgeR = makeBox(w: 0.005, h: 0.034, d: 0.046,
                              color: Self.bodyShell, chamfer: 0.002)
        ridgeR.position = SCNVector3(Self.helmetW / 2 + 0.001, Self.helmetH * 0.55, 0)
        parent.addChildNode(ridgeR)

        // 큰 보라 LED 눈 (헬멧 정면).
        let eyeY = Self.helmetH * 0.52
        addEye(into: parent, x: -0.020, y: eyeY, z: Self.helmetD / 2 + 0.003)
        addEye(into: parent, x:  0.020, y: eyeY, z: Self.helmetD / 2 + 0.003)

        // 이마 카메라 (눈 사이 위)
        let cam = SCNCylinder(radius: 0.005, height: 0.005)
        let camMat = SCNMaterial()
        camMat.diffuse.contents = Self.eyePupil
        camMat.specular.contents = NSColor.white.withAlphaComponent(0.7)
        camMat.shininess = 80
        cam.firstMaterial = camMat
        let camNode = SCNNode(geometry: cam)
        camNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        camNode.position = SCNVector3(0, eyeY + 0.024, Self.helmetD / 2 + 0.005)
        parent.addChildNode(camNode)

        // 입 — 가로 검은 grill
        let mouth = makeBox(w: 0.022, h: 0.004, d: 0.002,
                             color: Self.eyePupil, chamfer: 0.001)
        mouth.position = SCNVector3(0, eyeY - 0.024, Self.helmetD / 2 + 0.004)
        parent.addChildNode(mouth)

        // 턱 (헬멧 아래쪽 검은 라인 - 더 매끈)
        let chin = makeBox(w: Self.helmetW * 0.72, h: 0.008, d: Self.helmetD * 0.84,
                            color: Self.detailDark, chamfer: 0.003)
        chin.position = SCNVector3(0, 0.004, 0)
        parent.addChildNode(chin)
    }

    private func addEye(into parent: SCNNode, x: CGFloat, y: CGFloat, z: CGFloat) {
        // 외부 보라 LED 디스크 (앞으로 살짝 튀어나옴)
        let outer = SCNCylinder(radius: Self.eyeRadius, height: 0.005)
        let outerMat = SCNMaterial()
        outerMat.diffuse.contents = Self.eyePurple
        outerMat.emission.contents = Self.eyePurple.withAlphaComponent(0.85)
        outerMat.specular.contents = NSColor.white.withAlphaComponent(0.5)
        outerMat.shininess = 30
        outerMat.lightingModel = .blinn
        outer.firstMaterial = outerMat
        let outerNode = SCNNode(geometry: outer)
        outerNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        outerNode.position = SCNVector3(x, y, z)
        parent.addChildNode(outerNode)

        // 검은 동공 (가운데)
        let pupil = SCNSphere(radius: 0.005)
        let pupilMat = SCNMaterial()
        pupilMat.diffuse.contents = Self.eyePupil
        pupilMat.specular.contents = NSColor.white.withAlphaComponent(0.9)
        pupilMat.shininess = 90
        pupil.firstMaterial = pupilMat
        let pupilNode = SCNNode(geometry: pupil)
        pupilNode.position = SCNVector3(x, y, z + 0.0035)
        parent.addChildNode(pupilNode)
    }

    // MARK: - Arm

    private enum Side { case right, left
        var sign: CGFloat { self == .right ? 1 : -1 }
    }

    private func buildArm(side: Side, attach: SCNNode, anchor: SCNVector3) {
        // shoulder pitch (앞뒤 회전) — 큰 둥근 모터
        let pitchAnchor = SCNNode()
        pitchAnchor.position = anchor
        attach.addChildNode(pitchAnchor)
        let pitchKey: JointID = (side == .right) ? .rShoulderPitch : .lShoulderPitch
        joints[pitchKey] = pitchAnchor

        let pitchMotor = makeMotor(.large, axis: .x)
        pitchAnchor.addChildNode(pitchMotor)
        registerHighlight(pitchKey, motorMeshes(in: pitchMotor))

        // shoulder roll (옆벌리기) — 직각 결합 모터
        let rollAnchor = SCNNode()
        rollAnchor.position = SCNVector3(side.sign * 0.026, -0.008, 0)
        pitchAnchor.addChildNode(rollAnchor)
        let rollKey: JointID = (side == .right) ? .rShoulderRoll : .lShoulderRoll
        joints[rollKey] = rollAnchor

        let rollMotor = makeMotor(.medium, axis: .y)
        rollAnchor.addChildNode(rollMotor)
        registerHighlight(rollKey, motorMeshes(in: rollMotor))

        // 위팔 (라운드 박스)
        let upper = makeBox(w: Self.upperArmDia,
                             h: Self.upperArmLen,
                             d: Self.upperArmDia * 0.90,
                             color: Self.bodyShell, chamfer: Self.upperArmDia * 0.18)
        upper.position = SCNVector3(0, -Self.upperArmLen / 2 - 0.024, 0)
        rollAnchor.addChildNode(upper)
        registerHighlight(rollKey, [upper])
        registerHighlight(pitchKey, [upper])

        // 팔꿈치 모터
        let elbowAnchor = SCNNode()
        elbowAnchor.position = SCNVector3(0, -Self.upperArmLen - 0.026, 0)
        rollAnchor.addChildNode(elbowAnchor)
        let elbowKey: JointID = (side == .right) ? .rElbow : .lElbow
        joints[elbowKey] = elbowAnchor

        let elbowMotor = makeMotor(.medium, axis: .x)
        elbowAnchor.addChildNode(elbowMotor)
        registerHighlight(elbowKey, motorMeshes(in: elbowMotor))

        // 아래팔 (라운드 박스, 어두운 회색)
        let fore = makeBox(w: Self.forearmDia,
                            h: Self.forearmLen,
                            d: Self.forearmDia * 0.90,
                            color: Self.detailDark, chamfer: Self.forearmDia * 0.20)
        fore.position = SCNVector3(0, -Self.forearmLen / 2 - 0.024, 0)
        elbowAnchor.addChildNode(fore)
        registerHighlight(elbowKey, [fore])

        // 그리퍼 (손 — 두 핑거 모양 박스)
        let palm = makeBox(w: 0.026, h: 0.024, d: 0.020,
                            color: Self.bodyShell, chamfer: 0.004)
        palm.position = SCNVector3(0, -Self.forearmLen - 0.030, 0)
        elbowAnchor.addChildNode(palm)

        let fingerL = makeBox(w: 0.008, h: 0.026, d: 0.010,
                               color: Self.helmetDark, chamfer: 0.002)
        fingerL.position = SCNVector3(-0.008, -Self.forearmLen - 0.052, 0.005)
        elbowAnchor.addChildNode(fingerL)
        let fingerR = makeBox(w: 0.008, h: 0.026, d: 0.010,
                               color: Self.helmetDark, chamfer: 0.002)
        fingerR.position = SCNVector3(0.008, -Self.forearmLen - 0.052, 0.005)
        elbowAnchor.addChildNode(fingerR)
    }

    // MARK: - Leg

    private func buildLeg(side: Side, attach: SCNNode, anchor: SCNVector3) {
        // hip yaw (Y축)
        let yawAnchor = SCNNode()
        yawAnchor.position = anchor
        attach.addChildNode(yawAnchor)
        let yawKey: JointID = (side == .right) ? .rHipYaw : .lHipYaw
        joints[yawKey] = yawAnchor

        let yawMotor = makeMotor(.medium, axis: .y)
        yawAnchor.addChildNode(yawMotor)
        registerHighlight(yawKey, motorMeshes(in: yawMotor))

        // hip roll
        let rollAnchor = SCNNode()
        rollAnchor.position = SCNVector3(0, -0.020, 0)
        yawAnchor.addChildNode(rollAnchor)
        let rollKey: JointID = (side == .right) ? .rHipRoll : .lHipRoll
        joints[rollKey] = rollAnchor

        let rollMotor = makeMotor(.medium, axis: .z)
        rollAnchor.addChildNode(rollMotor)
        registerHighlight(rollKey, motorMeshes(in: rollMotor))

        // hip pitch
        let pitchAnchor = SCNNode()
        pitchAnchor.position = SCNVector3(side.sign * 0.013, -0.015, 0)
        rollAnchor.addChildNode(pitchAnchor)
        let pitchKey: JointID = (side == .right) ? .rHipPitch : .lHipPitch
        joints[pitchKey] = pitchAnchor

        let pitchMotor = makeMotor(.large, axis: .x)
        pitchAnchor.addChildNode(pitchMotor)
        registerHighlight(pitchKey, motorMeshes(in: pitchMotor))

        // 허벅지 (라운드 박스, 흰)
        let thigh = makeBox(w: Self.thighDia,
                             h: Self.thighLen,
                             d: Self.thighDia * 0.92,
                             color: Self.bodyShell, chamfer: Self.thighDia * 0.18)
        thigh.position = SCNVector3(0, -Self.thighLen / 2 - 0.028, 0)
        pitchAnchor.addChildNode(thigh)
        registerHighlight(yawKey, [thigh])
        registerHighlight(rollKey, [thigh])
        registerHighlight(pitchKey, [thigh])

        // 허벅지 측면 검은 ridge (디테일)
        let thighRidge = makeBox(w: Self.thighDia * 0.30,
                                  h: Self.thighLen * 0.84,
                                  d: 0.004,
                                  color: Self.detailDark, chamfer: 0.001)
        thighRidge.position = SCNVector3(0, -Self.thighLen / 2 - 0.028,
                                          Self.thighDia * 0.48)
        pitchAnchor.addChildNode(thighRidge)

        // 무릎
        let kneeAnchor = SCNNode()
        kneeAnchor.position = SCNVector3(0, -Self.thighLen - 0.028, 0)
        pitchAnchor.addChildNode(kneeAnchor)
        let kneeKey: JointID = (side == .right) ? .rKnee : .lKnee
        joints[kneeKey] = kneeAnchor

        let kneeMotor = makeMotor(.large, axis: .x)
        kneeAnchor.addChildNode(kneeMotor)
        registerHighlight(kneeKey, motorMeshes(in: kneeMotor))

        // 정강이 (라운드 박스, 흰)
        let shin = makeBox(w: Self.shinDia,
                            h: Self.shinLen,
                            d: Self.shinDia * 0.92,
                            color: Self.bodyShell, chamfer: Self.shinDia * 0.18)
        shin.position = SCNVector3(0, -Self.shinLen / 2 - 0.026, 0)
        kneeAnchor.addChildNode(shin)
        registerHighlight(kneeKey, [shin])

        // 정강이 앞쪽 검은 ridge
        let shinRidge = makeBox(w: Self.shinDia * 0.34,
                                 h: Self.shinLen * 0.82,
                                 d: 0.004,
                                 color: Self.detailDark, chamfer: 0.001)
        shinRidge.position = SCNVector3(0, -Self.shinLen / 2 - 0.026,
                                         Self.shinDia * 0.48)
        kneeAnchor.addChildNode(shinRidge)

        // 발목 결합부 (회색 라운드 box)
        let ankle = makeBox(w: 0.058, h: 0.034, d: 0.064,
                             color: Self.detailDark, chamfer: 0.008)
        ankle.position = SCNVector3(0, -Self.shinLen - 0.046, 0.006)
        kneeAnchor.addChildNode(ankle)

        // 신발 (검은 부츠)
        let foot = makeBox(w: Self.footW, h: Self.footH, d: Self.footD,
                            color: Self.footBlack, chamfer: Self.footChamfer)
        foot.position = SCNVector3(0, -Self.shinLen - 0.072, 0.022)
        kneeAnchor.addChildNode(foot)

        // 신발 흰 밑창
        let sole = makeBox(w: Self.footW + 0.002,
                            h: 0.006,
                            d: Self.footD + 0.002,
                            color: Self.solWhite, chamfer: 0.003)
        sole.position = SCNVector3(0, -Self.shinLen - 0.090, 0.022)
        kneeAnchor.addChildNode(sole)

        // 신발 앞쪽 흰 ridge (장식)
        let toeRidge = makeBox(w: Self.footW * 0.62, h: 0.007, d: 0.016,
                                color: Self.solWhite, chamfer: 0.002)
        toeRidge.position = SCNVector3(0, -Self.shinLen - 0.082,
                                        0.022 + Self.footD / 2 - 0.014)
        kneeAnchor.addChildNode(toeRidge)
    }

    // MARK: - Building blocks

    /// MX-28T 모터 모형: 둥근 검은 박스 + 양쪽 흰 디스크.
    /// `axis`는 회전축 방향을 나타내며, 캡 두 개가 그 축 양 끝에 자리한다.
    private enum MotorSize { case small, medium, large }
    private enum MotorAxis { case x, y, z }

    private func makeMotor(_ size: MotorSize, axis: MotorAxis) -> SCNNode {
        let group = SCNNode()
        let dims: (w: CGFloat, h: CGFloat, d: CGFloat, capR: CGFloat, capH: CGFloat)
        switch size {
        case .small:  dims = (0.022, 0.030, 0.022, 0.010, 0.0025)
        case .medium: dims = (0.030, 0.040, 0.030, 0.013, 0.0030)
        case .large:  dims = (0.034, 0.046, 0.034, 0.015, 0.0035)
        }

        // 본체: chamfer 큰 검은 박스
        let body = makeBox(w: dims.w, h: dims.h, d: dims.d,
                            color: Self.motorBlack, chamfer: 0.005)
        group.addChildNode(body)

        // 두 캡 (양쪽). axis에 따라 위치 + 회전.
        let cap1 = makeMotorCap(radius: dims.capR, height: dims.capH)
        let cap2 = makeMotorCap(radius: dims.capR, height: dims.capH)
        switch axis {
        case .x:
            cap1.position = SCNVector3(-dims.w / 2 - dims.capH / 2, 0, 0)
            cap1.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            cap2.position = SCNVector3(dims.w / 2 + dims.capH / 2, 0, 0)
            cap2.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        case .y:
            cap1.position = SCNVector3(0, -dims.h / 2 - dims.capH / 2, 0)
            cap2.position = SCNVector3(0, dims.h / 2 + dims.capH / 2, 0)
        case .z:
            cap1.position = SCNVector3(0, 0, -dims.d / 2 - dims.capH / 2)
            cap1.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
            cap2.position = SCNVector3(0, 0, dims.d / 2 + dims.capH / 2)
            cap2.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        }
        group.addChildNode(cap1)
        group.addChildNode(cap2)
        return group
    }

    private func makeMotorCap(radius: CGFloat, height: CGFloat) -> SCNNode {
        let outer = SCNCylinder(radius: radius, height: height)
        outer.firstMaterial = lightCapMat()
        let outerNode = SCNNode(geometry: outer)

        // 가운데 작은 검은 축 표시
        let axle = SCNCylinder(radius: radius * 0.35, height: height + 0.001)
        let aMat = SCNMaterial()
        aMat.diffuse.contents = Self.detailDark
        aMat.specular.contents = NSColor.white.withAlphaComponent(0.4)
        aMat.shininess = 30
        axle.firstMaterial = aMat
        let axleNode = SCNNode(geometry: axle)
        outerNode.addChildNode(axleNode)
        return outerNode
    }

    private func motorMeshes(in motorGroup: SCNNode) -> [SCNNode] {
        // body + 두 캡(외부 cylinder만 — axle은 항상 같은 색).
        var out: [SCNNode] = []
        for child in motorGroup.childNodes {
            out.append(child)
        }
        return out
    }

    /// 캡슐 본 — 위/아래가 라운드된 길쭉한 형태.
    private func makeCapsule(diameter: CGFloat, height: CGFloat, color: NSColor) -> SCNNode {
        let cap = SCNCapsule(capRadius: diameter / 2, height: height)
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.specular.contents = NSColor.white.withAlphaComponent(0.20)
        m.shininess = 18
        m.lightingModel = .blinn
        cap.firstMaterial = m
        return SCNNode(geometry: cap)
    }

    /// **W1**: makeBox/darkMat/lightCapMat 를 PBR 로 승격 — IBL-only 조명(ambient
    /// 삭제)에서 Blinn 머티리얼이 검게 죽지 않도록. 부위별 색은 그대로 보존.
    private func makeBox(w: CGFloat, h: CGFloat, d: CGFloat,
                         color: NSColor, chamfer: CGFloat) -> SCNNode {
        let box = SCNBox(width: w, height: h, length: d, chamferRadius: chamfer)
        box.firstMaterial = RigMaterials.pbr(diffuse: color, metalness: 0.0, roughness: 0.5)
        return SCNNode(geometry: box)
    }

    private func darkMat() -> SCNMaterial {
        RigMaterials.pbr(diffuse: Self.detailDark, metalness: 0.0, roughness: 0.5)
    }

    private func lightCapMat() -> SCNMaterial {
        RigMaterials.pbr(diffuse: Self.motorCap, metalness: 0.3, roughness: 0.4)
    }

    private func registerHighlight(_ joint: JointID, _ meshes: [SCNNode]) {
        var existing = highlightMeshes[joint] ?? []
        existing.append(contentsOf: meshes)
        highlightMeshes[joint] = existing
        for m in meshes {
            let key = ObjectIdentifier(m)
            if originalEmissions[key] == nil {
                let cur = m.geometry?.firstMaterial?.emission.contents as? NSColor
                originalEmissions[key] = cur ?? NSColor.black
            }
        }
    }
}

// MARK: - JointID side helper

private extension UInt8 {
    var isOnRightHalf: Bool {
        switch self {
        case 1, 3, 5, 11, 13, 15, 17, 19, 20: return true
        default: return false
        }
    }
}
