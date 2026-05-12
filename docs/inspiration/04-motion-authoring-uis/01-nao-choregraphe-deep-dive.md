# NAO Choregraphe Deep Dive — DarwinForge 차용 1순위 분석

> 작성일: 2026-05-10
> 분석 대상: Aldebaran (United Robotics Group) Choregraphe Suite 2.8.x (NAO V6 / Pepper)
> 본 문서의 목적은 DarwinForge SwiftUI 앱의 모션 저작 화면을 Choregraphe 수준의 표현력으로 끌어올리기 위한 구체적 인터랙션 / 데이터 모델 / 위젯 시그니처 매핑을 정리하는 것이다.

---

## 1. 개요와 디자인 철학

Choregraphe는 NAO/Pepper용 공식 IDE로 2008년 출시 이후 약 17년간 진화한 “block-based + timeline + 3D viewer” 하이브리드 도구이다. 핵심 철학은 **세 개의 시점을 한 화면에 동시에 노출** 하는 것이다.

1. 행동의 *논리적 흐름* (Behavior Box / Flow Diagram)
2. 행동의 *시간적 전개* (Timeline)
3. 행동의 *공간적 결과* (3D Viewer + 실 로봇)

이 세 시점은 서로 양방향으로 동기화된다. 예: Timeline에서 0.6 s 시점에 머리 좌우 키프레임을 잡으면 3D Viewer에서 즉시 그 자세가 보이고, Behavior Box “Look at Object”의 내부 Animation 슬롯에 timeline 데이터가 임베드된다 (출처: http://doc.aldebaran.com/2-8/software/choregraphe/objects/timeline.html).

> ★ 차용: DarwinForge 현재 RootView는 Connection / Walk Sim / Strategy / Conversation / Motion Library가 탭 형태로 분리되어 있다. Choregraphe식 “3-pane sync” (Strategy FSM 그래프 + Motion Timeline + 3D Viewer)를 한 화면에 배치하는 `NSSplitViewController` 기반 메인 워크스페이스로 재설계할 것.

---

## 2. 화면 구조 (ASCII)

```
+--------------------------------------------------------------------------------+
| Menu Bar  | File  Edit  Connection  View  Run  Help                            |
+----------+-----------------------------------------+------------+-------------+
|          |                                         |            |             |
| BOX      |   FLOW DIAGRAM (Behavior canvas)        |  3D        |  ROBOT      |
| LIBRARY  |   ┌─[onStart]─→[Set Posture]─→[Walk]─┐  |  VIEWER    |  VIEW       |
| (tree)   |   │                                  │  | (NAOqi sim)|  (live cam) |
|          |   │   [Look at Person]──→[Say "Hi"] ─┤  |            |             |
| ▸ Audio  |   └──────────────────────────────────┘  |  +X→  +Y↑  |  joint LEDs |
| ▸ Motion |                                         |  +Z⊙       |  battery    |
| ▾ Anim.  |   onStart ────→ outputDone             |            |  posture    |
|   Stand  |                                         |            |             |
|   Sit    +-----------------------------------------+------------+-------------+
| ▸ Speech |                                                                    |
| ▸ Vision |   TIMELINE  (current Animation Box: "Walk to Ball")                |
| ▸ LEDs   |   ┌─────────────────────────────────────────────────────────────┐  |
| ▸ Logic  |   │ frame:    0    25   50   75   100  125  150  175  200       │  |
| ▸ Custom |   │ [Motion]  ●────────●─────────●─────────●─────────●           │  |
|          |   │ [Behav.]       ◇ Hello                                       │  |
| ▸ My Box |   │ HeadYaw  ╱──╲────╱──╲                                         │  |
|          |   │ HeadPitch ──╲──╱──╲──                                         │  |
|          |   │ LShoulder ─────────────                                       │  |
|          |   │ RShoulder ─────────────                                       │  |
|          |   │ Curve panel (Bezier) ▼ for selected joint                     │  |
|          |   └─────────────────────────────────────────────────────────────┘  |
|          |                                                                    |
+----------+--------------------------------------------------------------------+
| Status: connected to nao.local | FPS: 60 | sim/real: REAL | log [▸]            |
+--------------------------------------------------------------------------------+
```

(출처: http://doc.aldebaran.com/2-8/software/choregraphe/choregraphe_overview.html)

### 2.1 위젯별 역할

| 영역 | 위젯 | 역할 |
|------|------|------|
| 좌측 | Box Library Panel | 카테고리 트리 + 검색. 드래그하면 Flow Diagram에 인스턴스 생성. |
| 중앙 상단 | Flow Diagram | Behavior Box 노드 그래프. onStart 입력 → 실행 흐름. |
| 중앙 하단 | Timeline | 선택된 Animation Box 내부 키프레임 편집. |
| 우상단 | 3D Viewer | NAOqi simulator. mouse drag로 카메라 회전, 축 기즈모. |
| 우하단 | Robot View | 실 로봇 연결 시 카메라 스트림 + 관절 LED 미니맵. |
| 하단 | Status Bar | 연결 / FPS / sim-real 토글 / 로그 펼침. |

---

## 3. Behavior Box 데이터 모델

Behavior Box는 “함수 + 상태머신 + UI 폼”이 결합된 단위다. XML(.xar) 포맷으로 직렬화된다 (출처: http://doc.aldebaran.com/2-8/software/choregraphe/objects/box_libraries.html).

### 3.1 시그니처

```
Box {
  id          : UUID
  name        : "Walk To Ball"
  bitmap      : Resource (.png)
  tooltip     : String
  inputs      : [Input]
  outputs     : [Output]
  parameters  : [Parameter]
  resources   : [ResourceLock]   // 예: "All motors", "Speakers"
  script      : Python | Diagram | Timeline
}

Input {
  name  : "onStart"
  nature: Bang | Number | String | Dynamic
  type  : Stm | Punct | Event
}

Output {
  name  : "onStopped"
  nature: Bang | Punct
  type  : Stm | Event
}

Parameter {
  name  : "Distance"
  type  : Int | Float | Bool | String | Choice
  default: 0.5
  range : (0.0 ... 5.0)
  inheritable: Bool   // 부모 박스에서 상속 여부
  ui    : Slider | Spinner | TextField | Dropdown
}
```

핵심 통찰은 **Resource Lock**. 한 박스가 “All Motors”를 잠그면 동일 자원을 요구하는 다른 박스는 큐에 대기한다 — 하드웨어 동시성 충돌을 컴파일 타임이 아닌 런타임에 직렬화한다.

### 3.2 입출력 연결 규약

- Bang(◆): 이벤트 트리거 (값 없음).
- Number(○): float 데이터 흐름.
- String(□): 문자열.
- Dynamic(◎): 모든 타입.

타입 미스매치 연결은 시도 시 빨간색 경고와 함께 거부된다. 같은 타입은 자동 캐스팅되며 (Number → String 등), 사용자가 마우스 휠로 연결선의 라우팅(직선 / 베지어 / 직각) 변경 가능 (출처: http://doc.aldebaran.com/2-8/software/choregraphe/objects/box_basics.html).

> ★ 차용: 우리 `Strategy.swift`의 `StrategyState` enum을 Behavior Box로 그래프화. 각 state를 박스로, transition을 input/output line으로 표시. SwiftUI에서 `Canvas` + `GeometryReader` 기반 노드 에디터 (`StrategyGraphView`)를 신설하고, 자원 잠금 개념을 도입하여 “Walk + Kick 동시 실행 금지”를 시각적으로 표시.

---

## 4. Timeline 에디터 — 키프레임과 Bezier

Choregraphe Timeline은 두 종류 트랙을 지원한다.

1. **Motion track**: 관절 각도. Frame 단위(기본 25 fps, 변경 가능). 각 관절(JointName)별 lane.
2. **Behavior track**: Flow Diagram 또는 Script 임베드. Frame 시점에 box 실행.

### 4.1 키프레임 데이터

```
Keyframe {
  frame      : Int          // timeline 프레임 인덱스
  joint      : JointName    // "HeadYaw", "LShoulderPitch", ...
  angle      : Float        // 라디안
  interp     : Bezier | Linear | Constant | Smooth
  inHandle   : (dx, dy)     // bezier in tangent
  outHandle  : (dx, dy)     // bezier out tangent
  symmetric  : Bool         // in/out handle 미러링 여부
}
```

### 4.2 Bezier handle 인터랙션

선택된 키프레임을 더블클릭하면 곡선 패널이 펼쳐지며, in/out tangent를 마우스로 드래그할 수 있다. Shift 누르면 기울기 고정, Alt 누르면 in/out 분리(broken handle), Ctrl 누르면 시간축 스냅 (출처: http://doc.aldebaran.com/2-8/software/choregraphe/objects/timeline.html#editing-the-curve).

기본 보간은 “Smooth” (Catmull-Rom 변형)로, 사용자가 시간만 찍어도 자동으로 매끄러운 자세 전이가 만들어진다. 물리 한계 (관절 속도 / 가속도 한계)를 넘는 곡선은 빨간색으로 highlight 된다.

### 4.3 Layer & Library 분리

Timeline은 “Layer”로 멀티트랙을 구성한다. 각 Layer는 자기 자신의 motion lane들을 갖고, 가장 위에 있는 layer가 우선권 — Photoshop의 layer 모델과 동일한 alpha-blend 우선순위. 이 모델은 “기본 standing pose layer + 위에 wave hand layer” 식으로 partial motion 합성을 가능하게 한다.

> ★ 차용: 현재 DarwinForge `Motion.swift`는 `.mtn` ↔ JSON 변환만 담당. SwiftUI에서 `MotionTimelineView`를 신설하고 데이터 모델은 다음 시그니처로:
>
> ```swift
> public struct MotionKeyframe: Hashable, Sendable {
>     public let frame: Int           // 25 fps 기준
>     public let joint: JointID       // 16개 enum
>     public let angle: Double        // radian
>     public var interp: Interp       // .bezier(InHandle, OutHandle) / .linear / .step
> }
> public struct MotionLayer: Identifiable {
>     public let id: UUID
>     public var name: String
>     public var keyframes: [MotionKeyframe]
>     public var muted: Bool
>     public var locked: Bool
> }
> ```

---

## 5. Library Browser

좌측 Box Library는 4계층 트리: `Category → Subcategory → Box → Variant`.

- 검색은 fuzzy match (이름 + tag + script 본문). 결과는 카테고리 헤더가 sticky로 남고 매치된 박스가 highlight.
- Box 우클릭 → `Save in My Box` → 사용자 라이브러리(`~/Choregraphe/boxLibraries/myBox.bxl`)에 직렬화.
- 드래그 앤 드롭 시 ghost preview가 Flow Diagram의 그리드(40px)에 스냅된다.
- Box별 “Help” 패널 마우스 호버 후 1.2초 지연 시 자동 표시 (단, 30 px 이상 이동 시 dismiss).

(출처: http://doc.aldebaran.com/2-8/software/choregraphe/objects/box_libraries.html)

> ★ 차용: 우리 `MotionLibraryView.swift`는 현재 단순 리스트. SwiftUI `NavigationSplitView`의 sidebar로 트리를 표시하고, drag-and-drop을 통해 `MotionTimelineView` 또는 `StrategyGraphView`에 직접 박스 인스턴스화. 로컬 `~/Library/Application Support/DarwinForge/Boxes/*.json` 디렉터리를 watch 하여 hot reload.

---

## 6. Pose Capture 흐름

Choregraphe의 강력한 차별점. 실 NAO에서 토크를 풀고(stiffness=0) 사람이 손으로 포즈를 잡은 뒤 Timeline의 카메라 버튼을 누르면 모든 관절 각도가 현재 프레임에 키프레임으로 기록된다.

### 6.1 단계별

1. NAO 연결 (TCP NAOqi proxy).
2. Timeline 패널 우상단 “Disable Stiffness on Whole Body” 클릭 → ALMotion proxy → `setStiffnesses("Body", 0.0)`.
3. 사용자가 NAO 팔/다리를 원하는 자세로 이동. (NAO V6는 무게 5.4 kg, free 자세 유지 가능.)
4. Timeline에 “기록” 버튼 (빨간 원). 누르면:
   - 현재 프레임에 모든 16개 motor의 `getAngles("Body")` 결과를 키프레임 삽입.
   - 단일 frame일 수도 있고, “rolling capture” 모드면 25 fps로 연속 기록.
5. 다시 stiffness 1.0으로 복원하여 자세 재생.

### 6.2 데이터 흐름

```
[NAO V6 motors]
   │  setStiffness=0
   ▼
[ALMotion]
   │  getAngles("Body") → list<float>[26]   # NAO는 26 DoF
   ▼
[Choregraphe]
   │  inject keyframes at currentFrame
   ▼
[Timeline .xar]
```

(출처: http://doc.aldebaran.com/2-8/software/choregraphe/tutos/animation_editor.html)

DARwIn-OP/OP2는 16 DoF, MX-28 / RX-28 모터의 torque OFF는 `Goal Torque = 0` 또는 P/I/D = 0 트릭으로 가능. CM-740 BulkRead로 `Present Position(36)`을 25 Hz로 폴링하면 이 흐름이 그대로 재현된다.

> ★ 차용: DarwinForge에 `PoseCaptureView`를 추가. 워크플로:
> 1. `Bus.swift`로 USB 연결 후 “Compliance OFF” 버튼 → CM-740에 P=0,I=0,D=0 패킷 전송.
> 2. 사용자가 로봇 손으로 자세 잡음.
> 3. “Capture” 버튼 → BulkRead 결과를 현재 timeline frame에 inject.
> 4. “Continuous Capture” 토글 → 25 Hz 타이머로 연속 기록.
> 5. 종료 시 P=32,I=0,D=0 (DARwIn-OP 기본값) 복구.

---

## 7. Python / Lua 임베딩

Animation Box가 아닌 일반 Behavior Box는 Python 스크립트로 동작 정의. NAOqi가 임베디드 Python 2.7 인터프리터를 제공하며 `self.onInput_<inputName>__()` 와 같은 콜백 메서드를 사용자가 작성한다.

```python
class MyClass(GeneratedClass):
    def __init__(self):
        GeneratedClass.__init__(self)

    def onLoad(self):
        self.tts = ALProxy("ALTextToSpeech")

    def onUnload(self):
        pass

    def onInput_onStart(self):
        self.tts.say("Hello")
        self.onStopped()  # 출력 트리거
```

(출처: http://doc.aldebaran.com/2-8/software/choregraphe/objects/box_script.html)

이 패턴의 의의: **GUI에서 정의한 입출력이 자동으로 메서드 시그니처로 노출**된다. Lua는 로봇 임베디드 빠른 평가용 (V-Sido와 유사 위치).

> ★ 차용: 우리는 macOS 네이티브이므로 사용자 박스 스크립트 언어로 Swift Subprocess 또는 JavaScriptCore 임베드(`JSContext`)가 현실적. 가장 단순하게는 “Box = Swift func 시그니처”로 컴파일 타임에 정의하고, 사용자 정의는 일단 “스크립트 박스 = bash 또는 zsh shell”로 한정 (보안: sandbox).

---

## 8. 단축키 표 (10+)

| 단축키 | 기능 | DarwinForge 대응 |
|--------|------|------------------|
| Ctrl+N | 새 프로젝트 | ⌘N |
| Ctrl+S | 저장 (.crg) | ⌘S |
| Ctrl+Z / Ctrl+Y | undo / redo | ⌘Z / ⇧⌘Z (UndoManager) |
| Ctrl+Enter | Run Behavior | ⌘R |
| Esc | Stop Behavior | ⌘. (period) |
| F5 | Reload box from library | ⌘⇧R |
| Ctrl+드래그 | Box duplicate | ⌥-드래그 |
| Ctrl+휠 | Flow Diagram zoom | trackpad pinch |
| Space (timeline) | play / pause | Space |
| Home / End | timeline 처음 / 끝 | Home / End |
| → / ← | 프레임 단위 nudge | → / ← |
| Shift+→/← | 10 frame nudge | ⇧→ / ⇧← |
| K | 현재 프레임에 keyframe insert | K |
| I / O | timeline in / out marker | I / O |
| Ctrl+T | Stiffness on/off (글로벌) | ⌘T |
| Ctrl+Shift+P | Pose capture | ⌘⇧P |

(출처: http://doc.aldebaran.com/2-8/software/choregraphe/shortcuts.html)

---

## 9. SwiftUI 매핑 제안 (구체 시그니처)

### 9.1 메인 워크스페이스

```swift
struct ForgeWorkspaceView: View {
    @StateObject var doc: MotionDocument          // .forge 파일 (JSON)
    @StateObject var bus: Bus                     // 시리얼 연결
    var body: some View {
        NavigationSplitView {
            BoxLibrarySidebar(doc: doc)           // §5
        } content: {
            VSplitView {
                StrategyGraphView(doc: doc)       // §3
                MotionTimelineView(doc: doc)      // §4
            }
        } detail: {
            VSplitView {
                Robot3DViewer(doc: doc, bus: bus) // SceneKit
                LiveRobotPanel(bus: bus)
            }
        }
        .toolbar { ForgeToolbar(doc: doc, bus: bus) }
    }
}
```

### 9.2 Timeline 핵심

```swift
struct MotionTimelineView: View {
    @ObservedObject var doc: MotionDocument
    @State private var playhead: Double = 0       // seconds
    @State private var zoom: Double = 1.0         // px/sec
    @State private var selectedKeys: Set<KeyframeID> = []

    var body: some View {
        VStack(spacing: 0) {
            TimelineRuler(playhead: $playhead, zoom: $zoom)
            ForEach(doc.layers) { layer in
                LayerLane(layer: layer, zoom: zoom, selected: $selectedKeys)
            }
            BezierCurveEditor(selected: $selectedKeys, doc: doc)  // §4.2
        }
        .focusable()
        .onKeyPress(.space) { doc.togglePlay(); return .handled }
        .onKeyPress("k")    { doc.insertKeyframeAtPlayhead(); return .handled }
    }
}
```

### 9.3 Pose Capture

```swift
struct PoseCaptureBar: View {
    @ObservedObject var bus: Bus
    @ObservedObject var doc: MotionDocument
    @State private var continuous = false
    @State private var captureTimer: Timer?

    var body: some View {
        HStack {
            Toggle("Compliance OFF", isOn: Binding(
                get: { bus.complianceOff },
                set: { bus.setCompliance(off: $0) }))
            Button("Capture") { captureFrame() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Toggle("Continuous", isOn: $continuous).onChange(of: continuous, perform: toggleTimer)
        }
    }

    private func captureFrame() {
        let angles = bus.bulkReadPositions()                     // [JointID: Double]
        doc.insertKeyframes(angles, at: doc.playhead)
    }
}
```

### 9.4 Behavior Box 캔버스

```swift
struct StrategyGraphView: View {
    @ObservedObject var doc: MotionDocument
    var body: some View {
        Canvas { ctx, size in
            for box in doc.boxes { drawBox(ctx, box) }
            for edge in doc.edges { drawEdge(ctx, edge) }
        }
        .gesture(DragGesture().onChanged(handleDrag).onEnded(handleDrop))
        .contextMenu { Button("Add Box") { doc.addBox() } }
    }
}
```

---

## 9.5 추가 SwiftUI 패턴 — 키프레임 스크러빙

NAO Choregraphe의 timeline은 마우스 좌클릭으로 playhead를 잡고 끌면 “Scrub” 모드 — 실 로봇이 그 시점 자세를 즉시 따라간다 (sim에서는 3D viewer가 따라감). 이 인터랙션이 의외로 강력 — 사용자가 시간축을 손으로 “재생”하는 경험은 키프레임 위치 결정 시 직관을 극적으로 개선한다.

SwiftUI 구현:

```swift
struct PlayheadHandle: View {
    @Binding var playhead: Double
    @ObservedObject var bus: Bus
    var body: some View {
        Rectangle().fill(.red).frame(width: 2)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    playhead = pixelToTime(g.location.x)
                    let pose = doc.sample(at: playhead)
                    bus.sendPose(pose)         // 라이브 자세 전송
                })
    }
}
```

주의: 60 fps 마우스 이동마다 모터 명령을 보내면 시리얼 버스 포화. 30 Hz로 throttle 또는 사용자 마우스 stop 후 100 ms 디바운스 권장.

## 10. 결론 — DarwinForge 1차 도입 우선순위

1. **Timeline + 16-joint dope sheet** (4주): §4 데이터 모델 + §9.2 SwiftUI.
2. **Pose Capture** (2주): §6 + §9.3. CM-740 BulkRead 위에서 즉시 가능.
3. **Behavior Box 그래프** (4주): §3 + §9.4. `Strategy.swift` FSM을 데이터 모델로 재사용.
4. **Resource Lock** (1주): §3.1. “Walk vs. Motion vs. Kick” 자원 직렬화.
5. **Library 트리 + 검색** (2주): §5 + `NavigationSplitView` sidebar.

총 13주 추정. Pose Capture가 가장 ROI 높음 — 우리 motions/ 디렉터리 확장의 진입 장벽을 결정한다.

---

(전체 출처 모음: http://doc.aldebaran.com/2-8/index.html, http://doc.aldebaran.com/2-8/software/choregraphe/index.html, http://doc.aldebaran.com/2-8/software/choregraphe/objects/timeline.html, http://doc.aldebaran.com/2-8/naoqi/motion/almotion-api.html. NAO V6 / Choregraphe 2.8.6 기준. 2.9 / Pepper 전용 항목은 본 문서에서 제외.)
