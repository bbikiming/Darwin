# 노드 플로우 에디터 패턴

> Behavior Tree, Strategy FSM, Walk Engine pipeline 등을 시각적으로 편집하기
> 위한 후속 UI 후보. 비전문가도 노드 드래그·연결로 로직 구성 가능.

## 주요 도구

### 1. Blender — Geometry Nodes / Shader Editor ★★

**DarwinForge에 가장 어울림** — 오픈소스, 데이터 흐름 + 매개변수 노드.
Mac 네이티브.

핵심 패턴:
- 좌측: 노드 카탈로그 (검색)
- 중앙: 무한 캔버스 (Pan + Zoom + Bezier 연결선)
- 우측: 선택 노드 인스펙터
- 하단: 결과 미리보기

### 2. Houdini — SOPs (Surface Operators)

전문 VFX. 노드가 "이전 노드의 결과를 받아 변환" 식으로 직렬 흐름.
DarwinForge보다는 영화/3D 워크플로우.

### 3. TouchDesigner

실시간 미디어 노드 (오디오·비디오·OSC). 휴머노이드 dance-show에 사용된
사례 다수 (Spot Choreographer 인접).

### 4. Unreal Blueprints

게임 개발에서 비주얼 스크립팅. 함수·이벤트·변수 노드. AAA 게임 표준.
DarwinForge에 직접 차용은 무거움.

### 5. n8n / Zapier / Make

비즈니스 로직 자동화. **트리거 + 액션** 단순 모델. DarwinForge의 Strategy
FSM 시각 편집기에 가장 적합:
- 트리거 = "공이 보이면"
- 액션 = "공으로 다가가기"

### 6. Cycling '74 Max/MSP

음악 + 라이브 퍼포먼스 노드. Spot Choreographer가 영향 받음.

## DarwinForge 적용 — Strategy FSM 시각 에디터

```
┌──────────────────────────────────────────┐
│  Strategy FSM 에디터 (Sprint 10+ 후보)   │
│                                          │
│  [Idle]──→[LookingForBall]               │
│             │                            │
│             ↓ ball.found                 │
│           [Approaching]                  │
│             │                            │
│             ↓ pixel_count > 1000         │
│           [Kicking]──→[Cooldown]         │
│                          │               │
│                          ↓ 1500 ms       │
│                       [Looking]          │
└──────────────────────────────────────────┘
```

SwiftUI 구현 — Canvas + DragGesture + 노드 모델.

```swift
struct FSMNode: Identifiable {
    let id: UUID
    var state: StrategyState
    var position: CGPoint
}

struct FSMEdge: Identifiable {
    let id: UUID
    var from: UUID
    var to: UUID
    var condition: String   // "ball.found", "pixel_count > 1000", "since_kick > 1500"
}
```

캔버스: SwiftUI `Canvas` API로 Bezier 그리기 + `DragGesture`로 노드 이동.

## 핵심 인터랙션 패턴

| 패턴 | Blender | n8n | DarwinForge 적용 |
|------|---------|-----|------------------|
| 노드 추가 | Shift+A | + 버튼 | 우클릭 메뉴 |
| 연결 | 출력 → 입력 드래그 | 동일 | 동일 |
| 삭제 | X 키 | 백스페이스 | Backspace |
| 검색 | Tab → fuzzy | 우측 패널 | ⌘K |
| 그룹화 | Ctrl+G | 동일 | ⌘G |
| 미리보기 | Real-time | Test execution | "시뮬 실행" 버튼 |

## 출처

- Blender Geometry Nodes: https://docs.blender.org/manual/en/latest/modeling/geometry_nodes/
- Houdini: https://www.sidefx.com/products/houdini/
- TouchDesigner: https://derivative.ca/
- Unreal Blueprints: https://docs.unrealengine.com/en-US/blueprints-visual-scripting-in-unreal-engine/
- n8n: https://n8n.io
