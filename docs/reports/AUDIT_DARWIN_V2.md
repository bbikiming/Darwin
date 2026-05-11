# DarwinForge V2 — 냉정한 점검 (Pre-Production Audit)

> 본 문서는 [`PROGRESS.md`](../../PROGRESS.md) Sprint 7까지의 빌드를 *고객이 실제로
> 로봇을 움직이려 한다*는 가정 아래 점검한다. 합리화 없음. 결론 먼저, 근거는
> 파일·라인으로 명시한다.

---

## TL;DR — 결론 먼저

| 영역 | 평가 | 한 줄 요약 |
|---|---|---|
| **하드웨어 안전 / 신뢰** | ⚠️ 위험 | 슬라이더 한 번 움직임마다 **16-관절 × 50ms ≈ 800ms 버스 플러드**. liveApply 토글 confirm 흐름에 race + USB drop 미감지 |
| **로보틱스 정확성** | ⚠️ 데모 수준 | Walk Engine은 sim only (실 모터 명령 안 나감), IMU·IK 닫힌 루프 부재, Strategy FSM은 raw 픽셀 카운트만 입력 |
| **3D 시각화 충실도** | ✅ 양호 | URDF + STL mesh 정확, 좌표계 변환 명시. 하지만 카메라 초기 시점 25° 비스듬, STL fallback 시 사용자 통지 없음 |
| **UX 일관성 / 비전문가** | ⚠️ 부분적 | Studio onboarding은 좋음. 그러나 ⌘1..5 단축키가 macOS 메뉴에서 안 보임 (HIG 위배), motion library 사전 적재 0개 |
| **테스트 커버리지** | ✅ 73 Rust + 36 Swift | 핵심 비즈니스 로직 양호. 하지만 UI 단위 테스트 0, 통합 테스트 0, snapshot 회귀 5개만 |
| **코드 모듈화** | ⚠️ 비대 | RobotScene3D 936줄, StudioView 495줄, MotionStudioView 448줄 — body·viewBuilder 분리 필요 |
| **App Store 적합성** | n/a | macOS dev tool — code signing + Gatekeeper notarization은 V2.5에 다룰 별개 작업 |

**점검 점수: 32 / 50 — C+ / "사람이 옆에서 보고 있어야 안전한 단계"**

---

## 1. 하드웨어 안전 — 가장 큰 약점

### 1.1 ❌ 슬라이더 → 버스 플러드 (P0)

[`Studio/PoseInspector.swift:115-126`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Studio/PoseInspector.swift#L115)

```swift
Slider(
    value: Binding(
        get: { Double(degree) },
        set: { newDeg in update(joint: j, degrees: newDeg) }   // ← 매 프레임
    ),
    in: limits
)
```

`update(joint:degrees:)`는 슬라이더 한 픽셀 움직임마다 호출되고, `liveApply` 켜져
있으면 `onApplyToHardware(next)` → `StudioView.applyToHardware(_:)`가 즉시 실행:

[`Studio/StudioView.swift:354-364`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Studio/StudioView.swift#L354)

```swift
private func applyToHardware(_ pose: RobotPose) async {
    guard let bus = store.bus else { return }
    do {
        for j in JointID.allCases {                     // ← 매번 16개 모두
            let raw = UInt16(clamping: pose.raw(j))
            _ = try bus.setPosition(j, raw: raw)        // ← 1개씩 직렬 패킷
        }
    } catch { lastError = error.localizedDescription }
}
```

**문제 정량화** (출처: ROBOTIS Dynamixel Protocol 1.0 / e-Manual control table 응답):
- WRITE 패킷 6 bytes header + 4 bytes payload + 1 status return ≈ 50 ms RTT @ 1 Mbaud (status return 200 µs delay 포함)
- 16 joint × 50 ms = **800 ms / slider tick**
- macOS Slider drag 시 onChanged ≈ 60 Hz → 초당 60회 호출 → **48 동시 패킷 큐 적체**
- `BusActor`로 직렬화는 되지만 큐가 무한 누적 — UI는 실시간이 아니라 *눈에 띄는 lag* 발생

**근거 / 비교군**:
- ROBOTIS-Framework `robotis_controller`는 **Sync_Write (한 패킷, N motor)** 사용. 8 ms 제어 루프. 16 joint 한 번에 1 패킷 ≈ 12 ms.
- Dynamixel SDK [Protocol 1.0 SYNC_WRITE](https://emanual.robotis.com/docs/en/dxl/protocol1/#sync-write): 0xFE broadcast + 다중 ID payload — 우리 forge-core::dynamixel::sync에 구현 있음 (Sprint 2). FFI에 노출만 안 됨.
- Webots `op2.proto`: motor.setPosition()을 controller가 모아서 한 simulation step에 push.

### 1.2 ❌ Live Apply confirm race (P0)

[`Studio/StudioView.swift:64-77`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Studio/StudioView.swift#L64)

```swift
Toggle(isOn: Binding(
    get: { liveApply },
    set: { newValue in
        if newValue && !hasAcceptedLiveApply {
            showLiveApplyConfirm = true
            liveApply = true            // ← 임시. 사용자 취소 시 alert에서 false로 되돌림.
        } else {
            liveApply = newValue
        }
    }
))
```

`liveApply = true`를 alert 표시 전에 *낙관적으로* set한다. 그 사이 사용자가 슬라이더를
건드리면 **미동의 상태에서 모터가 움직인다**. ISO 13850 §4.4 (e-stop 지연 금지)와는
별개로, "실행 의도 사전 동의" 패턴 위배.

근거: Apple HIG "Confirming Destructive Actions" — *상태 변경은 confirm 이후에만*.
Tesla Autopilot UI / DJI flight gating UX도 동일.

### 1.3 ❌ USB drop 미감지 (P0)

[`ConnectionStore.swift:133-167`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift#L133)

```swift
private func runTelemetryLoop(periodNs: UInt64) async {
    while !Task.isCancelled, let bus = self.bus {
        let board: BoardSnapshot? = (tick % 5 == 0) ? (try? bus.boardSnapshot()) : ...
        // try?로 swallow — 실패해도 status 변경 없음
        ...
    }
}
```

USB 케이블이 빠지면 `try?`가 nil을 반환하지만 `status`는 여전히 `.connected(snap)`.
사용자가 나중에 슬라이더를 움직이면 `setPosition` 호출이 timeout을 거쳐 throw —
그제야 `lastError`에 노출. **수십 초의 잘못된 신뢰 윈도우**.

근거: macOS IOKitNotification `kIOServiceDevicePublishKey`/`kIOServiceTerminate` —
Apple 공식 USB hot-plug 감지 패턴. ROS2 `dynamixel_sdk` Mac builds도 동일.

### 1.4 ⚠ Walk Engine은 simulation only (P1)

[`ForgeCore/Walk.swift:36-53`](../../app/ui/DarwinForge/Sources/ForgeCore/Walk.swift#L36)

```swift
/// 워크 엔진 시뮬레이션 wrapper. 실 모터 명령은 발행하지 않음 (forge-core::walk가 sim only).
public final class WalkEngine: @unchecked Sendable {
    ...
    public func tick(dtMs: UInt32) -> FootTargets { ... }
}
```

WalkLab은 발 trace를 그리지만 **로봇은 트레이스에 맞춰 다리를 움직이지 않음**.
연구자/RoboCup 사용자 입장에서 핵심 가치 부재.

근거: ROBOTIS-OP2 `op2_walking_module` (Apache 2.0) [`research/robotis-official/ROBOTIS-OP2/op2_walking_module`]는 IK + ZMP-aware 보행 + IMU pid 닫힌 루프를 구현. NimbRo gait controller (Schwarz et al. RoboCup 2014) 도 동일 패턴.

---

## 2. 로보틱스 정확성

### 2.1 ⚠ Strategy FSM은 raw 입력만 받음 (P2)

[`ForgeCore/Strategy.swift:24-34`](../../app/ui/DarwinForge/Sources/ForgeCore/Strategy.swift#L24)

```swift
public static func step(
    from state: StrategyState,
    ballPixelCount: UInt32,                 // ← UI로 들어온 값 = 사용자 수동 입력
    sinceKickMs: UInt32,
    abort: Bool
) -> StrategyState
```

카메라/비전 통합 0. Strategy 화면은 입력란에 숫자 적는 디버그 콘솔.
**RoboCup standard**: AVFoundation Frame → forge-core::vision (HSV blob, 이미 있음) → ballPixelCount 자동 갱신.

### 2.2 ⚠ Joint angle limits이 보수적이라 RoboPlus 모션과 호환 안 될 가능성 (P1)

[`ForgeCore/Kinematics.swift:43-56`](../../app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift#L43)

```swift
case .rShoulderPitch, .lShoulderPitch: return -180...180
case .rHipPitch, .lHipPitch:           return -90...60       // ← 60° upper
case .rKnee, .lKnee:                   return 0...150
```

ROBOTIS RoboPlus 기본 모션 ([`emanual.robotis.com/docs/en/platform/op2/.../motion_data`](https://emanual.robotis.com))은 hip pitch를 **-100..+80**까지, knee를 0..170까지 사용. 임포트 시 클램프되어 모션이 망가질 수 있음. 안전과 호환성 trade-off가 명시 안 됨.

### 2.3 ⚠ MeshRig 좌표계 변환은 정확하지만 검증 부재 (P2)

[`Visualization/MeshRig.swift:33-41`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Visualization/MeshRig.swift#L33)

```swift
// ROBOTIS world(X 정면, Y 좌, Z 위) → SceneKit(X 우, Y 위, Z 카메라).
let n = CGFloat(1.0 / sqrt(3.0))
root.transform = SCNMatrix4MakeRotation(2.0 * .pi / 3.0, -n, n, n)
```

수학적으로 맞지만 **자동 회귀 테스트가 없다**. RobotSnapshotTests는 PNG가 *생성되는지*만 검증, 픽셀 비교 없음. 맥북 GPU 변경/SceneKit 버전 변경 시 silently regress 가능.

근거: `robotis-op2-common/urdf/robotis_op2.structure.xacro` — head_tilt initial rpy(0, 33°, 0) 등 비자명 offset이 16개. 1개 회귀 시 전체 자세가 어그러짐.

---

## 3. UX 일관성 / 비전문가 친화성

### 3.1 ⚠ ⌘1..5 단축키는 메뉴에 없다 (P1)

[`RootView.swift:285-330`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift#L285)

```swift
private var globalShortcuts: some View {
    ZStack {
        Button("Open palette") { paletteOpen = true }
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)         // ← invisible
        Button("Section 1") { section = .studio }
            .keyboardShortcut("1", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)
        ...
    }
}
```

작동은 하지만 **macOS 메뉴바의 View / Window 메뉴에 항목이 없다**. Apple HIG "Keyboard Shortcuts" §"Discoverability" 위배. 사용자가 단축키 존재를 모르면 못 쓴다.

### 3.2 ⚠ Motion Library 빈 시작 (P1)

[`Motion/MotionStudioView.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionStudioView.swift) → `starterDoc()`에 **빈 페이지 1개**.

ROBOTIS RoboPlus는 출시 시 "Walking", "Sit Down", "Stand Up", "Bow", "Wave Right Hand" 등 기본 모션 18개를 prebundle. 이 앱은 첫 실행 시 보여줄 게 없음.

### 3.3 ⚠ Camera 초기 시점 비스듬 (P1)

[`Visualization/InteractiveSceneView.swift:18-21`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Visualization/InteractiveSceneView.swift#L18)

```swift
public var orbitAzimuth: CGFloat = 0.45    // ≈ 25° offset
public var orbitElevation: CGFloat = 0.18
```

기본 정면이 아니라 25° 비스듬. "다윈 idle 자세" 사용자가 처음 봤을 때 *왜 옆에서 보이지?* 라는 인지 비용. Webots, RViz, Foxglove 모두 정면 기본.

### 3.4 ⚠ STL load 실패 silent (P2)

[`Visualization/MeshRig.swift:255`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Visualization/MeshRig.swift#L255)

```swift
} catch {
    // mesh 로드 실패 시 그냥 plain color cube placeholder.
    print("STL load failed for \(name): \(error)")
}
```

console에만 출력. 사용자는 primitive fallback rig이 나타나도 *왜 외형이 다르지?*를 모름. 빌드 시 .stl resource missing 또는 손상 시 production app에서 뜻밖의 비주얼 노출.

### 3.5 ⚠ Help 페이지 / 문서 링크 부족 (P2)

`DarwinForgeApp.swift`의 commands에 e-Manual / README 링크 2개. 단축키 cheat sheet, 안전 매뉴얼, BLOCKER 응급처치 가이드 같은 *빠른 도움말 모달* 없음. 토스 / Linear의 inline help center 패턴 참고 가치.

---

## 4. 코드 품질

### 4.1 ⚠ 거대 파일 (P2)

| 파일 | 줄 수 | 비고 |
|---|---|---|
| `RobotScene3D.swift` | **936** | DarwinOP2Rig + 헤드리스 렌더 + Coordinator + helpers — 4개 파일로 분리 필요 |
| `MotionStudioView.swift` | **448** | sidebar/center/right body가 하나 — sub-View 추출 |
| `Studio/StudioView.swift` | **495** | onboarding panel (110줄) 분리 가능 |
| `RootView.swift` | **389** | sidebar (90줄) + globalShortcuts (45줄) 분리 가능 |
| `CommandPalette.swift` | **453** | 카탈로그 (95줄) 분리 가능 |

문화 표준: Swift 1 파일 ≤ 400줄 (Apple SwiftUI sample). React/Vue 컴포넌트는 ≤ 300줄. 800줄 넘어가면 reviewer가 한 화면에 안 잡힘.

### 4.2 ⚠ NotificationCenter fan-out (P2)

[`RootView.swift:263-273`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift#L263)

```swift
case .applyPose, .mirrorPose, .resetPose,
     .fillFromTelemetry, .saveCurrentPoseAsKeyframe:
    NotificationCenter.default.post(
        name: .dfStudioCommand,
        object: action
    )
```

타입 안전 X, 런타임 의존성. ObservableObject (`StudioCoordinator`) 또는 SwiftUI `@Environment` custom value로 깔끔하게 대체 가능.

### 4.3 ⚠ `@unchecked Sendable` 미보호 (P2)

[`ForgeCore/Bus.swift:111`](../../app/ui/DarwinForge/Sources/ForgeCore/Bus.swift#L111)

```swift
public final class Bus: @unchecked Sendable {
    private var handle: OpaquePointer?
```

FFI 핸들 raw pointer는 thread-safe 보장 없음. `BusActor`를 통해서만 접근하면 안전하지만 *static 보장이 없다*. 누군가 직접 `Bus`를 hold하면 race condition.

### 4.4 ⚠ MotionPlayer Timer drift (P2)

[`Motion/MotionPlayer.swift:48-54`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionPlayer.swift#L48)

```swift
timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
    Task { @MainActor in self?.tick() }
}
```

Foundation `Timer`는 RunLoop drift (commonModes 미설정 시 스크롤 중 멈춤) + Task 호출 stagger. CADisplayLink 또는 SwiftUI `TimelineView` 권장.

근거: WWDC 2021 "Discover refinements in SwiftUI" — TimelineView는 60Hz 정밀.

### 4.5 ⚠ Walk loop step 누락 시 무한 루프 가능 (P3)

[`Motion/MotionPlayer.swift:97-130`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionPlayer.swift#L97)

`recompute()`가 모든 step을 순회하며 elapsedMs 비교. step이 너무 많으면 frame당 O(steps). 페이지가 100 step + 60Hz = 6000 비교/초. 현재는 OK이지만 200 step 모션에서 GC pressure.

### 4.6 ⚠ Persistence 0 (P1)

`PROGRESS.md`에 ADR-012 (영속성/SQLite) 명시되어 있지만 SQLite/Realm/Core Data 어느 것도 통합 안 됨. Pose, motion, settings 모두 메모리. 앱 재시작 시 사라짐. 비전문가 UX 큰 마이너스.

### 4.7 ⚠ Undo/Redo 부재 (P1)

PoseInspector 슬라이더, MotionStudio step 편집 모두 undo 없음. Cocoa NSUndoManager 또는 SwiftUI `@Environment(\.undoManager)` 패턴 미사용.

---

## 5. 테스트 커버리지

| 영역 | 테스트 | 평가 |
|---|---|---|
| Rust core (forge-core) | 73 단위 + integration smoke | ✅ 양호 |
| Swift ForgeCore wrapper | 31 단위 (Kinematics 10, RobotPose 10, MotionDoc 8, Strategy 3) | ✅ 양호 |
| Swift UI 단위 | 0 | ❌ |
| Swift UI snapshot | 5 (Robot 자세 PNG 생성만) | ⚠ 픽셀 비교 없음 — false positive 위험 |
| 통합 (Bus mock + 슬라이더 스트리밍) | 0 | ❌ |
| Hardware-in-the-loop | 0 (BLOCKERS 명시) | n/a — Mac에서만 가능 |

**권장**: ViewInspector 또는 swift-snapshot-testing 도입 — UI 회귀 자동 감지. 현재는 사용자가 빌드해서 눈으로 확인하는 단계.

---

## 6. 점검 점수표

각 5점 만점.

| 영역 | 점수 | 코멘트 |
|---|---|---|
| 하드웨어 안전 | 2 | 슬라이더 플러드 + USB drop 미감지 — 실 로봇 위험 |
| 로보틱스 정확성 | 2 | walking 실 미작동, 비전 통합 0 |
| 3D 시각화 | 4 | URDF + STL 정확, 좌표계 변환 명시 |
| UX (비전문가) | 3 | onboarding 양호, 메뉴/모션 라이브러리 부재 |
| 코드 모듈화 | 3 | 거대 파일 4개, 그 외는 깔끔 |
| 테스트 커버리지 | 3 | Rust 양호, Swift UI 부족 |
| 문서화 (docs/) | 4 | ADR + Sprint 보고서 잘 갖춰짐 |
| 빌드/배포 | 4 | Makefile + run-app.sh 작동 |
| Onboarding | 3 | Studio onboarding panel 좋으나 메뉴/help 부족 |
| 커뮤니티 핏 (RoboCup, ROS) | 2 | walking 실작동 + ROS bridge 없음 — 핵심 사용자에게 어필 약함 |
| **합계** | **30 / 50** | **C+ — production 6주 작업 필요** |

---

## 7. 다음 — V2 업그레이드 계획

→ [`docs/reports/UPGRADE_PLAN_DARWIN_V2.md`](UPGRADE_PLAN_DARWIN_V2.md)

핵심 4주 로드맵:
1. **Week 1 (P0)**: 슬라이더 edit-end gating + diff apply + USB watchdog + 카메라 + STL banner + 메뉴 명령
2. **Week 2 (P1)**: Sync_Write FFI + walking IK 닫힌 루프 + motion library preload
3. **Week 3 (P2)**: 카메라 통합 + Strategy live + persistence (SQLite) + undo
4. **Week 4 (P3)**: 거대 파일 분리 + UI snapshot 회귀 + ROS2 bridge 검토
