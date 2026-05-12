# 휴머노이드 3D 시각화

> DarwinForge에 3D 자세 미리보기를 추가할 때 참고할 도구·라이브러리.

## 주요 도구

### 1. RViz (ROS) — Linux 표준

ROS의 3D viewer. URDF 표시 + 토픽 시각화. **macOS 네이티브 불가** —
ROS 의존.

### 2. Foxglove Studio ★

차세대 RViz 후속. **macOS 지원** + Electron 기반. URDF + bag 파일 시각화.
오픈 소스 + 상용.

DarwinForge 차용: 직접 import는 무겁지만, "URDF + 관절 상태 → 3D 포즈"
패턴은 같음.

### 3. Apple SceneKit (★ DarwinForge 1순위)

macOS 네이티브 3D 프레임워크. SwiftUI에 직접 임베디드.

```swift
import SceneKit
import SwiftUI

struct PoseView: View {
    let jointStates: [JointID: JointState]
    @State private var scene = SCNScene()

    var body: some View {
        SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            .onChange(of: jointStates) { _, new in
                applyToScene(new)
            }
    }

    private func applyToScene(_ states: [JointID: JointState]) {
        // 각 관절을 SCNNode로 매핑
        for (jid, state) in states {
            let radians = (Double(state.presentPosition) - 2048) * .pi / 2048
            scene.rootNode.childNode(withName: jid.name, recursively: true)?
                 .eulerAngles.x = Float(radians)
        }
    }
}
```

### 4. RealityKit (Apple, 더 새로운 3D)

iOS/macOS 새 3D 프레임워크. SceneKit 후속이지만 SceneKit이 여전히
잘 작동. **DarwinForge에는 SceneKit이 충분.**

### 5. Three.js / Babylon.js (웹)

웹 기반. 만약 DarwinForge 웹 변형이 필요할 때.

### 6. Open3D / VTK

사이언티픽 시각화. DarwinForge 스코프 외.

## DARwIn-OP 3D 모델 출처

URDF + STL 메시:

1. **HumaRobotics/darwin_description** (BSD-2-Clause) — 우리가 이미
   research/INDEX.md 등록
2. **ROBOTIS-OP2-Common/robotis_op2_description** (Apache 2.0) — research
   클론에 포함

URDF → SceneKit 변환:
- URDF의 `<link>` → `SCNNode`
- `<visual><geometry><mesh filename="*.stl">` → SCNGeometry from STL
- `<joint type="revolute">` → 회전 axis 정보 보존
- 부모-자식 트리 그대로

URDF 파서 후보:
- Swift: 직접 XMLParser로 작성 (URDF는 단순)
- Python: `urdfpy` (subprocess로 한번 → JSON으로 cache)
- Rust: `urdf-rs` crate

## DarwinForge 적용 — Sprint 4 후속

```
Motion Library 디테일 패널
  ┌─────────────────────────┐
  │ 3D Pose Preview         │
  │  (현재 선택 step의 자세) │
  │                         │
  │   [DARwIn-OP rendered]  │
  │                         │
  │  [Play] [<<] [>>]       │
  └─────────────────────────┘
```

또는 Joint Control 우측 상단 작은 3D viewer (전체 자세 한눈에).

## 출처

- Foxglove Studio: https://foxglove.dev/
- Apple SceneKit: https://developer.apple.com/documentation/scenekit
- RealityKit: https://developer.apple.com/documentation/realitykit
- HumaRobotics URDF: https://github.com/HumaRobotics/darwin_description
- ROBOTIS-OP2 URDF: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2-Common
- urdf-rs: https://github.com/openrr/urdf-rs
