# 03-D — DarwinForge 차용 포인트 (구체적 SwiftUI 적용 제안)

본 보고서는 위 세 카테고리의 분석에서 도출된 패턴을 **DarwinForge 의 실제 SwiftUI 뷰** 에 어떻게 반영할지 구체적으로 제안한다. 각 항목은 ① 문제 / 기회 ② 영감 출처 ③ 적용 대상 SwiftUI 뷰 ④ 구현 스케치 ⑤ 우선순위 의 5단으로 정리.

---

## Takeaway 1. **Pose Capture 버튼 (현재 자세 → 키프레임)**

### 문제 / 기회
ROBOTIS Bioloid (RoboPlus Motion), Aldebaran NAO (Choregraphe Hold Pose), Inria Poppy (Move Recorder), UBTECH Alpha 1 (Pose Capture) — **휴머노이드 저작 도구의 가격 / 규모를 불문하고 공통**. DarwinForge 가 아직 명시적 Pose Capture 기능이 없다면, 사용자는 매 키프레임마다 모터 ID 별로 각도를 손으로 입력해야 한다. 도입 즉시 모션 저작 시간 1/5 수준으로 단축.

### 영감 출처
- RoboPlus Motion (직계 OP/OP2 조부)
- NAO Choregraphe Timeline 박스 우상단 "Hold pose"
- Poppy Move Recorder (드래그 티칭)

### 적용 대상 SwiftUI 뷰
`MotionLibraryView` 의 모션 편집 모달 (또는 신설 `MotionEditorView`).

### 구현 스케치
```swift
struct MotionEditorView: View {
    @EnvironmentObject var bus: Bus
    @State private var keyframes: [Keyframe] = []

    var body: some View {
        // ... existing timeline ...

        HStack {
            Button {
                Task { await captureCurrentPose() }
            } label: {
                Label("Capture Pose", systemImage: "camera.aperture")
            }
            .keyboardShortcut("k", modifiers: .command)

            Toggle("Torque OFF (drag-to-teach)", isOn: $isDragMode)
                .onChange(of: isDragMode) { _, off in
                    Task { await bus.setTorqueAll(enabled: !off) }
                }
        }
    }

    private func captureCurrentPose() async {
        let positions = await bus.readAllPresentPositions()  // 20 motors
        let kf = Keyframe(time: currentTime, jointAngles: positions)
        keyframes.append(kf)
    }
}
```

### 우선순위
**P0 — 즉시.** 1주일 이내 PoC 가능. 사용자 만족도에 가장 큰 영향.

---

## Takeaway 2. **다중 트랙 타임라인 (Spot Choreographer 패턴)**

### 문제 / 기회
DarwinForge 의 현재 .mtn step 모델은 **단일 트랙 (한 step = 모든 모터 동시 명령)** 이다. Boston Dynamics Spot Choreographer 는 Body / Legs / Arms / Lights / Audio 의 **5종 트랙을 독립적으로 편집**, BPM 비트에 자동 스냅. 이렇게 하면:
- 머리만 따로 흔들면서 다리는 걷는 동작 가능 (현재 .mtn 으로도 가능하지만, **트랙별 편집 / 잠금 / 음소거** 가 없어 작업 효율 낮음).
- LED / 발화 트랙을 추가하면 모션 + 표현 + 발화가 한 시점에서 동기화.

### 영감 출처
- Boston Dynamics Spot Choreographer (다중 트랙 + BPM 스냅 + 파형 표시)
- Apple Logic Pro (다중 트랙 + 트랙별 mute / solo)

### 적용 대상 SwiftUI 뷰
`MotionEditorView` (위 1번에서 확장).

### 구현 스케치
- 각 트랙은 `LazyVStack` 의 행. 가로 `ScrollView` 로 시간 축 공유.
- 트랙 헤더: 이름 + Mute / Solo / Lock 토글 + 색상.
- 트랙 본문: `Canvas` 로 키프레임 도형 그리기. 드래그로 시간 이동.
- 상단 `Ruler` 뷰: 초 또는 BPM 비트 격자.
- BPM 입력 필드 + (옵션) "Tap tempo" 버튼.

```swift
struct TimelineView: View {
    let tracks: [Track] = [.head, .leftArm, .rightArm, .leftLeg, .rightLeg, .led, .speech]

    var body: some View {
        VStack(spacing: 0) {
            RulerView(bpm: $bpm, snapToBeat: $snapToBeat)
            ForEach(tracks) { track in
                TrackRow(track: track, keyframes: $keyframes[track])
                    .frame(height: 44)
            }
        }
    }
}
```

### 우선순위
**P1 — 1~2 개월.** UI 복잡도가 있으나 기존 .mtn 모델과 호환되도록 설계 가능 (트랙 = 모터 그룹의 시각적 분리에 불과).

---

## Takeaway 3. **박스 기반 Behavior Graph (Choregraphe Flow Diagram)**

### 문제 / 기회
DarwinForge 의 `StrategyView` 는 텍스트 기반 의도 / 룰 셋 (또는 결정 트리) 으로 추정. NAO Choregraphe 의 박스 그래프 (Box ↔ Box 의 단자-케이블 연결) 는 **25년간 휴머노이드 행동 저작의 표준**으로 남았는데, 그 이유는:
- 각 박스가 입력/출력 단자만 갖는 **순수 함수** 처럼 합성됨.
- 분기 / 병렬 / 루프가 시각적으로 자명.
- 박스 안에 또 다른 박스 그래프 (재귀) 를 둘 수 있어 큰 행동을 작은 박스로 분해 가능.

### 영감 출처
- Aldebaran Choregraphe Flow Diagram + Behavior Box 재귀
- Apple Quartz Composer (legacy), Notch Builder, Unity Visual Scripting

### 적용 대상 SwiftUI 뷰
신설 `BehaviorGraphView` (StrategyView 의 시각적 모드).

### 구현 스케치
- `Canvas` 또는 `ZStack` 위에 `BoxNodeView` 들을 절대 좌표로 배치.
- 박스 = 사각형 카드 (제목 + 입력 단자 좌측 + 출력 단자 우측).
- 단자 사이 케이블 = `Path` 로 베지어 곡선.
- 드래그 제스처 + `DropDelegate` 로 박스 추가.
- 박스 더블 클릭 → 박스 안의 코드 / 모션 / 하위 그래프 진입.
- 박스 종류: **Motion 박스** (모션 라이브러리에서 선택), **Intent 박스** (자연어 의도 = ClaudeCommander 호출), **Sensor 박스** (CM-740 입력), **Logic 박스** (if / while), **Subgraph 박스** (재귀).

```swift
struct BehaviorGraphView: View {
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []

    var body: some View {
        ZStack {
            ForEach(edges) { edge in CableShape(edge: edge).stroke() }
            ForEach($nodes) { $node in
                BoxNodeView(node: $node)
                    .position(node.position)
                    .gesture(DragGesture().onChanged { node.position = $0.location })
            }
        }
        .background(GridBackground())
    }
}
```

### 우선순위
**P1.5 — 2~3 개월.** 가장 큰 차별화 잠재력. 하지만 단순 사용자에게는 처음에 부담일 수 있어, **타임라인 모드 / 그래프 모드 토글** 로 제공.

---

## Takeaway 4. **자연어 명령 → 의도 스키마 → 박스 / 키프레임 자동 배치 (Helix 의 안전한 변형)**

### 문제 / 기회
Figure Helix 는 자연어를 직접 액션 토크로 변환 (VLA). DarwinForge 는 안전한 중간 계층 (의도 스키마) 을 두는 설계. 이 설계의 진가는, **자연어 명령으로 박스 그래프 / 타임라인을 자동 생성** 시 발휘된다:
- "왼손 들고 인사한 다음 두 발 짚어 점프" → 의도 = `[wave_left, jump]` → BehaviorGraphView 에 두 박스 자동 배치 + 케이블 연결 + Pose 박스의 키프레임 자동 채움.
- 결과를 사용자가 시각적으로 확인 / 튜닝 / 거부 가능. **불투명한 VLA 보다 안전.**

### 영감 출처
- Figure Helix (자연어 → 액션, 의도성)
- ClaudeCommander 의 의도 스키마 (DarwinForge 자체 자산)
- Cursor / Copilot 의 "코드 제안 → 사용자 수락" UX

### 적용 대상 SwiftUI 뷰
`ConversationView` ↔ `BehaviorGraphView` ↔ `MotionEditorView` 의 연결.

### 구현 스케치
1. ConversationView 에서 사용자 발화 → ClaudeCommander.
2. ClaudeCommander 가 의도 + (선택) BehaviorGraph JSON 패치 반환.
3. UI 에 **"이 행동을 그래프에 추가하시겠습니까?"** 카드 (수락 / 거부 / 편집).
4. 수락 시 BehaviorGraph 에 박스가 회색 톤으로 등장 → 사용자가 확인 후 색을 바꿔 활성화.

```swift
struct IntentSuggestionCard: View {
    let suggestion: BehaviorGraphPatch
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(suggestion.summary).font(.headline)
            BehaviorGraphPreview(patch: suggestion).frame(height: 120)
            HStack {
                Button("Reject", role: .destructive, action: onReject)
                Spacer()
                Button("Accept & Tune", action: onAccept).keyboardShortcut(.return)
            }
        }
        .padding().background(.regularMaterial).cornerRadius(12)
    }
}
```

### 우선순위
**P1 — 1~2 개월.** ClaudeCommander 가 이미 있다는 가정 하에, 의도 → 그래프 패치 변환 함수가 핵심. 박스 그래프가 P1.5 면 의도 → 키프레임 자동 배치만 먼저 가능.

---

## Takeaway 5. **모터 진단 카드 그리드 (RoboPlus Manager 의 모던화)**

### 문제 / 기회
ROBOTIS RoboPlus Manager 는 모터 ID 별 status (전압, 온도, 부하, 현재 위치, 목표 위치, 오류 플래그) 를 표 형태로 보여줌. **사용자가 시범 도중 모터 1개가 발열로 토크 오프 되었을 때, 어느 모터인지 즉시 알 수 있어야 한다** — 이는 OP/OP2 의 가장 흔한 운용 문제.

### 영감 출처
- RoboPlus Manager (ROBOTIS 자체)
- Dynamixel Wizard 2.0 (ROBOTIS 후속)
- 항공기 cockpit instrument cluster

### 적용 대상 SwiftUI 뷰
신설 `HardwareDiagnosticsView` (또는 기존 진단 뷰의 강화).

### 구현 스케치
- 20 개 모터를 **카드 그리드** (4×5 또는 5×4) 로 배치.
- 각 카드: 모터 ID + 이름 + **현재 자세 미니 게이지** + 온도 / 전압 / 부하 막대 + status LED (녹/황/적).
- 카드 색상 = 온도 임계 (>60°C → 황, >80°C → 적). 적 카드가 그리드에서 즉각 도드라지도록.
- 카드 탭 → 상세 시계열 그래프 (ChartView).

```swift
struct MotorCard: View {
    let motor: MotorStatus
    var statusColor: Color {
        switch motor.tempC {
        case ..<60: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("ID \(motor.id)").bold()
                Spacer()
                Circle().fill(statusColor).frame(width: 10, height: 10)
            }
            Text(motor.name).font(.caption).foregroundStyle(.secondary)
            JointAngleGauge(angle: motor.position, range: motor.range)
                .frame(height: 40)
            HStack {
                Label("\(motor.tempC)°C", systemImage: "thermometer")
                Spacer()
                Label("\(motor.voltageV, specifier: "%.1f") V", systemImage: "bolt")
            }
            .font(.caption2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(statusColor.opacity(0.5)))
    }
}
```

### 우선순위
**P0.5 — 2주.** RoboPlus 의 핵심 기능 중 가장 만들기 쉽고 효용 큼.

---

## Takeaway 6. **모션 라이브러리 / 의도 스니펫 공유 (EZ-Robot Skill Store 의 미니 버전)**

### 문제 / 기회
EZ-Robot Skill Store 는 사용자가 만든 박스 / 모션을 다른 사용자가 다운로드해서 즐길 수 있게 한다. DarwinForge 가 OP/OP2 라는 작은 시장에서 출발하더라도, **사용자가 만든 모션 / 박스 그래프 / 의도 스크립트를 GitHub Gist 또는 자체 리포에서 가져올 수 있게 만들면** 공유 효과 발생.

### 영감 출처
- EZ-Robot Skill Store
- Apple Shortcuts 의 iCloud 공유 (URL 단일 클릭으로 가져오기)
- Figma Community

### 적용 대상 SwiftUI 뷰
`MotionGalleryGridView` 의 우상단 신규 메뉴 + 신설 `CommunityGalleryView`.

### 구현 스케치
- "Share..." 메뉴 → 모션 / 그래프 / 스크립트를 JSON 으로 export → URL 생성 (Gist API 또는 자체 백엔드).
- 메인 화면 우상단 "Browse Community" 버튼 → 카드 목록 (이름 + 미리보기 GIF + 작성자 + 별점).
- 다운로드 시 **샌드박스에서 시뮬 미리보기** 후 "내 라이브러리에 추가" 버튼.

### 우선순위
**P2 — 4~6 개월.** 사용자 베이스가 어느 정도 형성된 후. 그러나 **JSON 직렬화 표준** 만 미리 깔끔히 정해두면 (P0 단계에서) 부담이 적다.

---

## Takeaway 7. **시뮬-실기 토글 + URDF/MJCF 자산 동봉 (Unitree 패턴)**

### 문제 / 기회
Unitree SDK2 는 URDF + MJCF + Isaac Gym 환경을 패키지에 포함해서, 사용자가 코드 한 줄로 시뮬 ↔ 실기 전환 가능. DarwinForge 의 `WalkSimView` 가 이미 시뮬을 갖고 있다면, **OP/OP2 의 URDF (또는 MJCF) 를 정식 자산으로 동봉**해서:
- "Connect to OP/OP2" 와 "Connect to Sim" 이 같은 메뉴에서 토글.
- 같은 모션 / 박스 그래프가 양쪽에 동일하게 작동.
- 학교 / 가정 사용자가 실기 없이도 모션 저작 학습 가능.

### 영감 출처
- Unitree SDK2 (URDF + MJCF + Gym 동봉)
- ROBOTIS OP3 의 Gazebo / RViz 공식 지원

### 적용 대상 SwiftUI 뷰
`WalkSimView` + `Bus` (또는 `BusV2`) 의 추상화 강화.

### 구현 스케치
- `Bus` 프로토콜에 두 구현: `HardwareBus` (CM-740 USB), `SimBus` (내부 시뮬 또는 외부 MuJoCo / Isaac WebSocket).
- `WalkSimView` 가 `SimBus` 의 사용자 — 모션 / 그래프는 `Bus` 만 알면 동작.
- 메뉴 토글: "Active target: Hardware OP2" / "Active target: Simulation" / "Active target: Both (mirror)".
- URDF 파일을 앱 번들에 동봉 (`OP2.urdf`, `OP2.mjcf`).

```swift
protocol Bus {
    func sendGoalPositions(_ positions: [MotorID: Double]) async
    func readPresentPositions() async -> [MotorID: Double]
    // ...
}

final class HardwareBus: Bus { /* CM-740 USB */ }
final class SimBus: Bus { /* internal sim or external MJCF */ }
```

### 우선순위
**P1 — 1~2 개월.** Bus 추상화는 이미 있다는 가정. URDF 동봉 + Sim 토글 추가.

---

## 요약 — DarwinForge 우선순위 매트릭스

| 차용 포인트 | 우선순위 | 영감 출처 (대표) | 적용 SwiftUI 뷰 |
| --- | --- | --- | --- |
| 1. Pose Capture | **P0** | Bioloid RoboPlus, NAO Choregraphe, Poppy | MotionEditorView |
| 5. 모터 진단 카드 그리드 | **P0.5** | RoboPlus Manager | HardwareDiagnosticsView |
| 2. 다중 트랙 타임라인 | **P1** | Spot Choreographer | MotionEditorView |
| 4. 자연어 → 그래프 패치 | **P1** | Figure Helix (안전 변형) | ConversationView ↔ BehaviorGraphView |
| 7. Sim ↔ Hardware 토글 + URDF 동봉 | **P1** | Unitree SDK2, OP3 ROS | WalkSimView, Bus |
| 3. 박스 기반 Behavior Graph | **P1.5** | NAO Choregraphe Flow Diagram | BehaviorGraphView (신설) |
| 6. 커뮤니티 공유 | **P2** | EZ-Robot Skill Store | CommunityGalleryView (신설) |

P0–P0.5 는 **OP/OP2 사용자 만족도에 즉각 영향**. P1 이후는 **DarwinForge 가 업계 표준에 합류** 하기 위한 항목. P1.5 는 **차별화의 결정타** — 박스 그래프 + 자연어 패치가 결합하면 NAO Choregraphe 와 Figure Helix 의 중간 지점에서 새로운 영역을 점유 가능.

---

## 위험 / 함정

1. **너무 많은 패턴을 한 번에 차용하면 UI 복잡도 폭증.** 우선순위 P0 → P1 → P2 순으로 분기 도입, 각 단계마다 사용자 테스트.
2. **NAO 의 Box 그래프는 매우 강력하지만 학습 비용이 높음** (Choregraphe 의 진입장벽). DarwinForge 가 어린 사용자 / 초심자 시장도 노린다면 **타임라인 모드를 default**, 그래프 모드는 옵션으로.
3. **자연어 → 그래프 자동 배치는 부정확할 수 있다.** 항상 사용자가 수락 / 거부 / 편집 가능하게 — Cursor 의 코드 제안 UX 모델을 따른다.
4. **시뮬-실기 동시 동작 시 동기화 문제.** Bus 추상화가 두 타깃 간 시간 슬립 / 누락 보상을 처리해야 한다.
5. **Pose Capture 시 토크 오프 안전성** — 사용자가 무거운 OP/OP2 의 다리를 잡고 있다 놓치면 자기 충돌 / 낙상. UI 에서 명시적 경고 + "다리 토크 항상 ON" 옵션을 default 로.
