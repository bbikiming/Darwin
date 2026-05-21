# Phase 3 v2: Motion Catalog + Blending (Critic Fix 반영)

- **작성일**: 2026-05-21
- **변경 사유**: Critic 4 MAJOR + Missing 5건 반영
- **이전 plan**: `PHASE_3_MOTION_CATALOG_BLENDING_PLAN_2026-05-21.md` (deprecated)

---

## 1. Critic 반영 사항

### v1 → v2 변경

| # | 이전 | 신규 (v2) |
|---|---|---|
| MAJOR1 | `enum BodyRegion { legs, leftArm, rightArm, head, waist }` 신설 | **기존 `JointID.BodyPart` 사용** — Bus.swift:49. `waist` 제거 (DARwIn-OP2 미존재). 필요 시 `BodyPart.isLower` computed property 만 추가 |
| MAJOR2 | 신규 디렉토리 `Motion/Catalog/` | **기존 `Pilot/MotionCatalog.swift` 와 같은 위치 — `Pilot/Motion/` 또는 `Pilot/` 직접**. 기존 `MotionPageMetadata.bodyRegions: [JointID.BodyPart]` 활용 |
| MAJOR3 | `composite(MotionDescriptor, MotionDescriptor)` 재귀 | **2-element flat** — `composite(lower: MotionDescriptor, upper: MotionDescriptor)` 만. `validate()` 가 nested composite 거부 + region 중복 검출 |
| Minor1 | `BalanceState` bare | `WalkLabSession.BalanceState` qualified |
| Minor2 | `case teach(TeachCapture)` (class, non-Sendable) | `case teach(TeachCapture.PoseSnapshot)` 또는 ID ref |
| Minor3 | PilotIntent.motion(String) 변경 site 미명시 | **PilotInputAccumulator + TelloPilotHud 영향 명시** |
| Missing1 | Emergency 우선순위 미명세 | MotionBlender 에 `func emergencyKill()` — composite 강제 종료 |
| Missing2 | Duration mismatch 미명세 | `MotionBlender.upperFinished()` 콜백 — `loop: Bool` 옵션 (default false: 자동 nil) |
| Missing3 | Bus bandwidth 미명세 | Blended 송출 = lower body + upper body diff (joint mask 분리, packet 1개 within Dynamixel limit) — 본 phase sim 만 |
| Missing4 | WalkMotionLibrary 관계 | **그대로 두고 wrapper** — MotionCatalogUnified 가 .walk case 시 WalkMotionLibrary 위임 |
| Missing5 | composite safety class | **최보수 (most restrictive)** — safe < caution < highRisk 중 max |

---

## 2. v2 데이터 모델

```swift
public enum MotionDescriptor: Identifiable, Sendable, Hashable {
    case walk(WalkLabPreset)
    case page(MotionPageMetadata)               // 기존 Pilot/MotionCatalog.swift
    case teach(TeachCapture.PoseSnapshot)       // value type
    /// 동시 실행 — composite 안에 composite 불가 (validate).
    case composite(lower: MotionDescriptor, upper: MotionDescriptor)

    public var id: String { /* 자동 */ }
    public var bodyRegions: Set<JointID.BodyPart>   // 기존 JointID.BodyPart 재사용
    public var safetyClass: SafetyClass             // composite = max(lower, upper)
    public var blendable: Bool                       // composite 자체는 X
}
```

`JointID.BodyPart` (기존 Bus.swift:49) 확장:
```swift
extension JointID.BodyPart {
    /// 다리 — composite 의 lower channel 후보.
    public var isLower: Bool {
        self == .rightLeg || self == .leftLeg
    }
    /// 팔 / 머리 — composite 의 upper channel 후보.
    public var isUpper: Bool {
        self == .rightArm || self == .leftArm || self == .head
    }
}
```

## 3. MotionBlender v2

```swift
@MainActor
public final class MotionBlender {
    /// 현재 활성 motion descriptor. Bindable.
    public private(set) var current: MotionDescriptor?

    public func play(_ descriptor: MotionDescriptor, loop: Bool = false) -> BlendResult { ... }

    /// composite 의 upper motion 종료 콜백.
    public func upperFinished() { /* loop=false 면 current = .walk 만 남김 */ }

    /// emergency kill — composite + 단일 motion 모두 강제 종료.
    public func emergencyKill() { current = nil }

    /// blended pose 산출 — RobotPose.with(joints:) 활용.
    public func currentPose(walkBasePose: RobotPose) -> RobotPose { ... }
}

public enum BlendResult: Equatable, Sendable {
    case accepted
    case rejectedConflict(String)   // 두 motion 의 region 충돌
    case rejectedNestedComposite(String)
    case rejectedSafetyBlocked(String)
}
```

## 4. MotionTransitionPolicy v2

```swift
public enum MotionTransitionPolicy {
    public static func validate(
        target: MotionDescriptor,
        currentBalance: WalkLabSession.BalanceState,   // qualified
        currentRobotConnected: Bool
    ) -> TransitionVerdict
}

public enum TransitionVerdict: Sendable {
    case allow
    case requireStop(reason: String)
    case blocked(reason: String)
}
```

## 5. PilotIntent.motion 변경 영향

`PilotIntent.Kind.motion(String)` → `.motion(MotionDescriptor.ID)` (= String 자체이지만 의미 명시).

영향 site:
- `PilotInputAccumulator.record()` (PilotIntent.swift:179) — `.motion` 처리 (현재 break) → ID 기록
- `TelloPilotHud.intentLabel()` (TelloPilotHud.swift:155) — `"🎬 모션 \(id)"` 그대로 OK
- `WalkLabRCBridge.handleMotion(_ id: String)` 신규 — MotionBlender.play() 위임

## 6. 신규 + 수정 파일 (v2)

```
Sources/DarwinForgeUI/Pilot/Motion/
  ├── MotionDescriptor.swift              # enum + safetyClass + validate
  ├── MotionBlender.swift                 # play/emergencyKill/currentPose
  ├── MotionTransitionPolicy.swift        # validate
  └── BodyPart+IsLower.swift              # extension

Tests/DarwinForgeUITests/Motion/
  ├── MotionBlenderTests.swift
  ├── MotionDescriptorTests.swift
  └── MotionTransitionPolicyTests.swift
```

**수정 (3 site)**:
- `Sources/DarwinForgeUI/WalkLab/Pilot/PilotIntent.swift` — .motion case 의미 명시 (String 유지)
- `Sources/DarwinForgeUI/WalkLab/Pilot/WalkLabRCBridge.swift` — handleMotion 분기 + blender 보유
- `Sources/DarwinForgeUI/WalkLab/Pilot/TelloPilotHud.swift` — composite 표시 (선택)

## 7. 비-목표 (이번 phase 안 함)

- 실 robot 송출 (sim 만)
- 모든 255 MotionPage 의 bodyRegions 자동 분류 (이미 메타에 있음 — 그대로 사용)
- Pilot view 의 motion 단축키 매핑 UI (별도)
- Recommender 가 motion 추천 (Phase 5+)

## 8. 검증

- swift build (debug + release): 0 errors
- swift test: 880+ 회귀 0 fail + 신규 15+ pass
- architect / critic / code-reviewer 검수 후 fix loop
- 코덱스 (별도 critic) 2차 검수

## 9. 시간 추정 (v2 수정)

- 모듈 4개: 1.5시간 (validate + emergencyKill 추가로 v1 보다 30분 추가)
- 테스트: 45분
- 빌드 + 회귀: 15분
- 병렬 에이전트: 30분
- 코덱스: 20분
- fix loop: 30분

**합계: 3-4시간** (v1 의 2.5-3 → 3-4)
