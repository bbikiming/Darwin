# Animation & Timeline References — 게임/애니메이션/미디어/노드 도구 벤치마크

> 작성일: 2026-05-10
> 대상: 게임·애니메이션 (13~17), 음악·미디어 타임라인 (18~21), 노드 플로우 (22~27)
> 본 문서는 인접 영역의 UI/UX 패턴을 100~200단어 단위로 정리하고, 끝에 “DarwinForge 차용 패턴” 섹션에서 구체적 매핑을 제시한다.

---

## 가) 게임/애니메이션 모션 저작 (벤치마크)

### 13. Autodesk MotionBuilder

캐릭터 애니메이션 + 모션 캡처 후처리에서 산업 표준. 핵심은 **Character / Control Rig** 추상화 — FK/IK가 통합된 effector를 사용자가 잡고 끌면 키프레임이 자동 기록된다. **Story Editor**가 다중 클립을 magnetic하게 배치하는 비선형 편집기. 초당 30~60fps 키프레임을 다루는 데 최적화되어 있어, 로봇 모션 (25~50 Hz target) 규모와 잘 맞는다 (출처: https://www.autodesk.com/products/motionbuilder/overview).

특이점: **Constraint Stack** — Aim, Position, Parent, Path 등 제약을 stack으로 쌓아 effector 동작 합성. 로봇으로 옮기면 “HeadPan은 ball을 aim, HeadTilt는 horizon을 lock”처럼 표현. 추가로 **Time Warp curve** — 클립의 재생 시간을 정확히 1:1이 아니라 임의 곡선으로 매핑할 수 있어 “걷는 속도를 후반부에 가속”이 trivial. 우리 .mtn step의 “time(ms)” 필드를 곡선화하면 동등 효과.

> ★ 차용 후보: SwiftUI에 `Effector` 추상화. 우리는 IK 솔버 부재라 직접 적용은 어렵지만, “Look At Ball” 박스가 자동으로 HeadPan/Tilt를 계산하는 패턴은 가능 — 단순 atan2. 향후 “Foot Effector” 박스로 발 위치 → 다리 6관절 IK도 가능 (analytic IK는 OP 다리 구조 단순해서 closed-form 풀이 가능).

### 14. Blender Animation (Dope Sheet + Graph Editor)

오픈 소스, 가장 학습 가치 큰 reference. 두 에디터를 항상 분리 노출.

- **Dope Sheet**: y축 = 본/속성, x축 = 프레임. 키프레임이 작은 마름모로 표시. 선택 / 이동 / 복사 / scale (S 단축키, 키프레임 시간 압축/확장)이 매우 빠르다. (출처: https://docs.blender.org/manual/en/latest/editors/dope_sheet/)
- **Graph Editor**: 같은 데이터를 곡선으로. F-Curve의 Bezier handle을 G/R/S (move/rotate/scale)로 직접 조작. handle type: Vector / Aligned / Free / Auto / Auto Clamped — 5가지가 노출되어 정밀 보간 제어. (출처: https://docs.blender.org/manual/en/latest/editors/graph_editor/)

**NLA Editor**가 “motion clip = 트랙 strip” 비선형 편집을 추가. clip 한 strip의 weight를 0..1 슬라이더로 alpha-blend, action 라이브러리에서 끌어와 배치.

Blender의 단축키 철학은 **modal verb-noun**: G(rab) / R(otate) / S(cale) 누른 뒤 마우스 이동, 좌클릭 confirm / 우클릭 cancel. 한 손은 키보드, 한 손은 마우스. 우리도 timeline 위에서 키프레임 선택 후 G로 이동, S로 시간 stretch, X로 삭제하는 시스템을 그대로 채용하면 Blender 사용자에게 즉시 친숙. SwiftUI `.onKeyPress`와 `DragGesture`의 lazy state machine으로 구현 가능.

> ★ 차용: 도프 시트 + 그래프 에디터 분리 노출은 우리 16관절 timeline의 표준 답안. SwiftUI tab 또는 ⌘1/⌘2로 토글.

### 15. Maya Trax Editor

Maya의 비선형 클립 편집기. **Trax**가 일반 “clip” (애니메이션 묶음)을 timeline strip으로 노출하고, 각 clip의 시간 / 속도(time scale) / weight를 GUI로 조작. 시작/끝에 ease in/out fade. 클립 간 cross-fade도 지원. (출처: https://help.autodesk.com/view/MAYAUL/2024/ENU/?guid=Animation_Trax)

가치: **time scale 슬라이더** — 같은 모션을 0.5x ~ 2.0x로 늘리거나 줄여서 재사용. DarwinForge `.mtn` re-time도 같은 기능으로 가능.

### 16. Unreal Sequencer

게임 엔진 시네마틱 도구. **Track + Section** 데이터 모델. 각 Track은 actor의 한 속성(position, rotation, parameter)을 다루고, 그 위에 여러 Section이 시간 구간으로 배치된다. Section 마다 보간 모드 / 여러 sub-track. (출처: https://docs.unrealengine.com/5.0/en-US/cinematics-and-movie-making-in-unreal-engine/)

특별히 강력한 점: **Sub-Sequence**. Sequencer 안에 다른 Sequencer를 nest. 캐릭터 단위로 시퀀스를 분리해 두고 마스터에서 합성. 로봇 모션의 “인사하기 + 걷기 동시” 합성 패턴에 적합. Sequencer는 또한 **Take Recorder**라는 별도 도구로 라이브 녹화를 지원 — Unreal 시뮬레이션 중 Take 버튼을 누르면 actor 상태가 새 시퀀스로 자동 기록된다. 우리 Pose Capture가 “여러 frame을 25 Hz로 녹화”하는 모드와 같은 메타포.

### 17. Rokoko Motion Capture

Smartsuit Pro 등 모션 캡처 하드웨어 + Rokoko Studio 소프트웨어. Studio는 라이브 IK 미리보기 + 녹화 + FBX/JSON export. JSON 포맷이 비교적 단순 (frame array, joint dict, quaternion or euler) — DarwinForge가 캡처 데이터 import할 때 참고할 표준. (출처: https://www.rokoko.com/products/studio)

Rokoko의 “Retargeting” UI는 source rig (예: 인간 자세) → target rig (캐릭터)로 본 매핑을 GUI 드래그로 정의. 인간 16~21관절을 OP의 16관절로 retargeting하는 매핑 테이블 UI는 우리도 필요해질 시점이 있을 것 — 휴머노이드 모션 데이터셋(SMPL, AMASS)이 풍부해 retarget만 잘하면 모션 라이브러리가 폭증한다.

> ★ 차용: 향후 사용자가 iPhone Vision Pro / 스마트폰 자세 추정 → DarwinForge에 자세 import 시 “Rokoko-style JSON”을 lingua franca로 채택 권장. Retarget UI를 SwiftUI로 만들 때, 양쪽 트리를 좌우에 두고 line으로 연결하는 “Bone Mapping” 위젯이 단순하면서도 강력.

---

## 나) 음악·미디어 타임라인

### 18. Ableton Live (Session + Arrangement)

전자 음악 핵심 도구. 두 view가 동시 노출:

- **Session View**: 가로축 = 트랙, 세로축 = clip slot. clip을 클릭하면 즉시 launch, 박자에 quantize. “라이브 잼” 메타포.
- **Arrangement View**: 가로축 = 시간. 일반적 timeline.

같은 데이터를 두 시점으로 보여주는 패턴은 우리 Strategy FSM (실행 가능 행동 grid) ↔ Timeline (실제 재생 sequence)에 그대로 매핑된다 (출처: https://www.ableton.com/en/manual/live-concepts/).

Ableton의 **Follow Action** — 한 clip이 끝나면 다음 clip을 확률적으로 선택해서 launch 하는 기능. “50 % 확률로 다음, 30 %로 같은 clip 반복, 20 %로 무작위” 같은 분포 지정. 이는 우리 로봇 행동 변주 (idle 상태에서 가만히 있지 않고 무작위로 손을 흔들거나 좌우 둘러보기)에 그대로 적용 가능.

> ★ 차용: SwiftUI에 “Session View 모드” 추가. 그리드 셀을 ⌘+숫자로 launch, 박자 quantize. Follow Action을 박스 속성으로 추가하면 “살아있는 idle” 표현력 크게 향상.

### 19. Pro Tools / Logic Pro (Track + Automation Lane)

Pro Tools (Avid) / Logic Pro (Apple)는 트랙 자체에 “Automation Lane”을 펼쳐 볼륨 / 팬 / 플러그인 파라미터의 시간 곡선을 편집한다. 트랙당 lane 다수, lane 별 enable/disable. (출처: https://support.apple.com/guide/logicpro/mix-with-automation-lgcpc15555595/mac)

> ★ 차용: 우리 timeline의 “모션 트랙”에 자동화 lane 개념 — joint 별 lane을 접고 펼치기. 한 화면에 16관절 모두 펼치면 좁으니 기본 collapse.

### 20. Adobe After Effects (Keyframe + Bezier)

Property별로 ◇ 키프레임을 timeline에 찍고, 우클릭 → “Easy Ease” / “Hold” / “Bezier” 보간 선택. **Graph Editor**에서 Speed Graph / Value Graph를 토글. handle drag로 ease curve 정밀 제어. (출처: https://helpx.adobe.com/after-effects/using/animation-keyframes.html)

특히 **Hold keyframe** (constant interpolation) — 다음 키프레임까지 값 유지. 로봇에서 “이 자세를 N ms 유지” 패턴. AE의 **Roving keyframe**도 흥미롭다 — 시간 위치를 “시간 grid에 고정” 하지 않고, 인접 키프레임의 곡선이 매끄럽도록 자동 시간 재배치. 사용자는 “언제”가 아니라 “어디”만 정해도 된다. 로봇 모션은 정확한 타이밍이 중요해서 직접 적용은 위험하지만, 도프 시트에 보조 토글로 두면 빠른 prototyping에 유용.

### 21. DaVinci Resolve / FCPX (Magnetic Timeline)

FCPX의 magnetic timeline은 클립 삽입 시 뒤 클립이 자동 push. 충돌이 발생하지 않는다. 클립은 **storyline** (메인 스토리라인 + connected clips)으로 구조화. (출처: https://www.apple.com/final-cut-pro/)

DaVinci Resolve는 더 전통적 (track-based) + 컬러 / Fusion / Fairlight 통합. Magnetic 모드 옵션 존재.

FCPX의 또 다른 핵심 패턴은 **Compound Clip** — 여러 클립을 묶어 하나의 단위처럼 다룬다. 더블클릭으로 진입, ESC로 탈출. 우리 .mtn 페이지를 묶어 “인사 시퀀스 = 손 흔들기 + 허리 굽히기”로 정의하면 같은 추상화. SwiftUI `NavigationStack`으로 자연스럽게 표현.

> ★ 차용: `.mtn` step strip을 magnetic으로 — 사용자가 step 삽입 시 뒤 step 자동 push. 우리 RoboPlus 호환 모델은 step time이 절대값이라 push 후 재계산 필요. Compound Clip 패턴으로 모션 페이지 그룹화.

---

## 다) 노드 플로우 에디터

### 22. Blender Geometry Nodes / Shader Editor

Blender 3.x의 Geometry Nodes는 mesh 변형을 노드 그래프로 표현. **Group input → 처리 노드 → Group output** 패턴. socket 색상으로 타입 구분 (geometry: 초록, vector: 보라, float: 회색, int: 파랑 …). 커스텀 group을 다른 그래프에서 재사용 가능. (출처: https://docs.blender.org/manual/en/latest/modeling/geometry_nodes/)

Blender 노드 에디터의 단축키 디자인이 모범적이다. `Shift+A`로 노드 추가 메뉴, `G`로 grab, `F`로 connect (선택된 두 노드 자동 연결), `Ctrl+J`로 group, `Tab`으로 group 진입/탈출. 매우 빠르다. 우리 SwiftUI 그래프에 동일 단축키를 적용하면 학습 곡선 낮음.

> ★ 차용: socket 색상 타입 코드는 Choregraphe Bang/Number/String/Dynamic과 정확히 동일 정신. 우리도 일관 색상. Blender 단축키 차용으로 사용자 학습 부담 최소화.

### 23. Houdini SOPs (Surface Operators)

VFX 산업 표준. **노드 = 동사 (verb)** 가 핵심 메타포. 각 노드는 입력을 받아 변형하고 출력. 그래프는 통상적으로 위→아래 흐름. 노드별 “bypass” / “display” / “render” 플래그가 그래프 위에 시각적으로 표시 — 어느 노드의 출력이 현재 viewport에 보이는지 명시적. (출처: https://www.sidefx.com/docs/houdini/nodes/sop/)

> ★ 차용: 박스에 “Display flag” = “이 시점의 모션이 3D Viewer에 미리보기”. 디버깅 시 매우 유용.

### 24. TouchDesigner

실시간 멀티미디어 노드. CHOP (Channel) / TOP (Texture) / SOP (Surface) / DAT (Data) / COMP (Component) 5종으로 분리. **타입별 색상 강하게 구분**. 노드 간 type-converting 자동.

라이브 패치를 위한 **Replicator / Performer** 모드 분리 — 편집 중에는 모든 디버그 정보 노출, 공연 모드는 깔끔한 fullscreen. (출처: https://derivative.ca/UserGuide)

> ★ 차용: “Authoring 모드 / Performance 모드” 토글. 공연 / 데모 시 깔끔한 UI.

### 25. Unreal Blueprints

게임 시각 스크립팅. **Execution wire (흰색, 굵음)** + **Data wire (타입별 색상)** 분리가 가장 핵심. 실행 흐름과 데이터 흐름을 시각적으로 구분. 노드는 좌→우 흐름 강제. (출처: https://docs.unrealengine.com/5.0/en-US/blueprints-visual-scripting-in-unreal-engine/)

각 노드에 “tooltip = 함수 doc + signature + example”. 검색은 fuzzy + categorical (가장 자주 쓰는 노드는 카테고리 trim).

> ★ 차용: 우리 Strategy 그래프에 execution wire / data wire 분리. NAO Choregraphe Bang vs Number 와 같은 개념을 Unreal식 강한 시각 차이로.

### 26. Cycling '74 Max/MSP

음악/미디어 노드 30년 표준. **Object** = 박스. 박스는 윗변에 inlet (입력), 아래 변에 outlet (출력). hot vs cold inlet (왼쪽 = 트리거, 오른쪽 = 데이터만 갱신). (출처: https://docs.cycling74.com/legacy/max8/)

특히 **subpatcher** (`p` 박스) → 더블클릭으로 nested graph. 우리 Strategy FSM의 hierarchical state에 직결.

> ★ 차용: 박스 더블클릭 = subgraph 진입. NAO Choregraphe와 동일 패턴.

### 27. n8n / Zapier / Make

비즈니스 자동화 (Workflow Automation) 노드. **Trigger → Action → Action**. 각 노드는 외부 SaaS API 호출. node 간 **expression** (예: `{{$json.email}}`)으로 데이터 추출. (출처: https://docs.n8n.io/, https://zapier.com/help)

표준 노드 라이브러리가 매우 크고(수천 개), 검색 / 카테고리 / “featured” 큐레이션이 잘 되어 있다. 사용자 onboarding 모범.

n8n / Make의 **Run Once / Test Webhook** UI는 노드 단위 dry-run을 매우 쉽게 만든다. 사용자가 한 노드를 클릭 → “Execute node” 버튼 → 노드 단독 실행 후 결과 JSON을 우측 패널에 표시. 이 패턴은 우리 박스 디버깅에 그대로 적용 가능 — Strategy 박스 우클릭 → “Run This Box Only” → 입출력 값을 inspector에 표시.

> ★ 차용: 박스 라이브러리 검색 UX. recently used / favorites / categorical / fuzzy text 4 axis. 노드 단독 dry-run 패턴은 디버깅 가치 매우 높음.

---

## 라) DarwinForge 차용 패턴 — 종합

본 절은 위 15개 도구의 패턴을 우리 SwiftUI 코드에 매핑한다.

### 1. 도프 시트 (Blender) → 16관절 × 시간 grid

```swift
struct DopeSheetView: View {
    @ObservedObject var doc: MotionDocument
    @State private var rowHeight: CGFloat = 18    // 16개 row * 18 = 288 pt
    @State private var pxPerSecond: CGFloat = 100
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawGrid(ctx, size)
                    for kf in doc.allKeyframes { drawKeyframe(ctx, kf) }
                }
                .frame(width: doc.totalSeconds * pxPerSecond, height: 16 * rowHeight)
                JointLabelColumn()              // sticky leading
                TimeRulerRow()                  // sticky top
            }
        }
        .focusable()
        .onKeyPress("g") { /* grab selected keyframes */ return .handled }
        .onKeyPress("s") { /* scale selected keyframes */ return .handled }
        .onKeyPress("x") { /* delete */ return .handled }
    }
}
```

요점: y축 = `JointID` enum 16개, x축 = `frame` (또는 §02 문서의 slice). 키프레임은 ◇ shape, 선택 시 색상 변화. Blender의 G/S/X 단축키 그대로 채용 — Blender 사용자에게 즉시 익숙.

### 2. Magnetic timeline (FCPX) → step 자동 정렬

```swift
extension MotionDocument {
    /// step을 frame=t에 삽입하고, 충돌 시 뒤 step을 push.
    public func insertStepMagnetic(_ step: Step, at frame: Int) {
        let dur = step.duration
        for i in 0..<steps.count where steps[i].startFrame >= frame {
            steps[i].startFrame += dur
        }
        steps.append(Step(startFrame: frame, ...))
        steps.sort { $0.startFrame < $1.startFrame }
    }
}
```

옵션: timeline 우상단 `Toggle("Magnetic", isOn: $magnetic)`로 on/off. magnetic off 시 클래식 absolute 모드.

### 3. 노드 플로우 (Blueprints/Max/Geometry Nodes) → Strategy FSM 시각 편집기

Strategy.swift의 5상태 enum을 그래프 데이터로 승격.

```swift
public struct StrategyNode: Identifiable, Codable {
    public let id: UUID
    public var state: StrategyState
    public var position: CGPoint                  // 캔버스 좌표
}
public struct StrategyEdge: Identifiable, Codable {
    public let id: UUID
    public let from: UUID
    public let to: UUID
    public var condition: Predicate               // ballPixel > 200 등
    public var kind: WireKind                     // .execution / .data
}
public enum WireKind: String, Codable {
    case execution    // 흰색 굵은 선 (Unreal 식)
    case data         // 타입별 색상
}
```

캔버스 렌더링은 SwiftUI `Canvas { ctx, size in ... }`. 노드 드래그는 `@State var dragOffset` + `DragGesture`. 연결선은 노드 출력 핀에서 마우스 다운 → 드래그 → 다른 노드 입력 핀에 드롭. 호버 시 핀이 16 px 강조 — Unreal Blueprints UX.

### 4. Bezier handle (After Effects / Blender)

Graph Editor 모달:

```swift
struct GraphEditorView: View {
    @Binding var keyframes: [MotionKeyframe]
    var body: some View {
        Canvas { ctx, size in
            for kf in keyframes { drawCurve(ctx, kf) }
            for kf in keyframes where kf.isSelected {
                drawTangent(ctx, kf.inHandle, kf.outHandle)
            }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            // hit test handle, then drag tangent
        })
    }
}
```

handle type: `auto`, `aligned`, `free` (Blender 식). 단축키 `V` cycle.

### 5. BPM sync (Spot / Ableton) → §02 문서 참조

`BeatGrid` 타입이 `MotionDocument`에 attach. 메트로놈 NSSound + `BeatPulseIndicator` SwiftUI.

### 6. 라이브러리 검색 (n8n)

`BoxLibrarySidebar`:

```swift
@State var query: String = ""
@State var category: BoxCategory? = nil
@State var favorites: Set<UUID> = []

var filtered: [BoxDef] {
    library.boxes.filter { box in
        (category == nil || box.category == category) &&
        (query.isEmpty || box.name.fuzzyMatches(query) || box.tags.contains(query))
    }.sorted {
        let af = favorites.contains($0.id), bf = favorites.contains($1.id)
        return af && !bf
    }
}
```

### 7. Sub-graph (Max / Sequencer)

Behavior Box 더블클릭 → 그 박스의 내부 그래프를 새 탭으로 push. NavigationStack 으로:

```swift
@State var graphPath: [BoxRef] = []
NavigationStack(path: $graphPath) {
    StrategyGraphView(boxRef: nil)
        .navigationDestination(for: BoxRef.self) { ref in
            StrategyGraphView(boxRef: ref)
        }
}
```

### 8. Display flag (Houdini)

박스의 우상단에 작은 “eye” 아이콘. 켜진 박스의 출력이 3D viewer에 표시.

```swift
@State var displayBoxID: UUID? = nil
// 한 번에 하나만 켜질 수 있게 라디오 동작.
```

### 9. Layer alpha (Blender NLA / V-Sido / MotionBuilder)

```swift
public struct MotionLayer {
    public var name: String
    public var weight: Double      // 0..1
    public var muted: Bool
    public var keyframes: [MotionKeyframe]
}
// sample at t = sum_l(layer_l.weight * layer_l.sample(t))
// (각 joint 별 가중 평균)
```

UI: layer row 우측에 작은 슬라이더 + speaker 아이콘 (mute) + 자물쇠.

### 10. Authoring vs Performance (TouchDesigner)

⌘⇧F로 “Performance 모드” — 사이드바 / inspector 숨기고 3D Viewer + 큰 재생 컨트롤만. 데모 / 발표 / 공연용.

---

## 마) 우선순위 매트릭스

| 패턴 | 구현 난이도 | 사용자 가치 | 우선 |
|------|-------------|-------------|------|
| 도프 시트 | 중 | 매우 높음 | ★★★ |
| 그래프 에디터 | 높음 | 높음 | ★★ |
| Strategy 노드 그래프 | 높음 | 매우 높음 | ★★★ |
| Magnetic step | 낮음 | 중 | ★★ |
| BPM sync | 중 | 중 (데모) | ★★ |
| 라이브러리 검색 | 낮음 | 중 | ★★ |
| Sub-graph nav | 중 | 중 | ★ |
| Display flag | 낮음 | 중 | ★★ |
| Layer alpha | 중 | 높음 | ★★ |
| Performance 모드 | 낮음 | 낮음 | ★ |

도프 시트 + Strategy 노드 그래프가 “★★★” — 우리 차별화의 핵심.

---

## 바) 라이선스 / 표준 / 참조

DarwinForge가 직접 코드를 가져오는 것은 없다. 모두 패턴 / 인터랙션 / 데이터 모델만 차용. 단 다음은 표준 포맷이라 import 지원 검토 가치가 있다.

- **FBX** (Autodesk, 부분 공개 SDK): MotionBuilder / Maya / Blender 공통.
- **glTF / glb** (Khronos, open): 3D 모델 표준. SceneKit 일부 지원.
- **BVH** (Biovision Hierarchy, open ASCII): 모션 캡처 lingua franca.
- **USD** (Pixar, open): Isaac Lab / Omniverse.
- **Rokoko JSON** (사실상 표준).

DARwIn-OP 16관절을 BVH의 hierarchical bone에 매핑하면 Blender / MotionBuilder에서 직접 편집 후 import 가능 — 장기 가치 매우 큼. 단 BVH 회전축 컨벤션 (ZYX vs ZXY)이 도구마다 다름, “확인 필요”.

---

(전체 출처는 각 단락 끝의 URL. Adobe / Autodesk / Apple / Blender / Side FX / Cycling '74 / Derivative / Epic Games / Boston Dynamics 공식 문서 위주. 2026-05-10 기준.)
