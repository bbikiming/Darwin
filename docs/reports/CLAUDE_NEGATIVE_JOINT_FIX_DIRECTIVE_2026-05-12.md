# Claude 변경 지시서: 모션 조인트 음수 방향 / 좌우 미러 수정

작성일: 2026-05-12  
대상: DarwinForge Swift UI / ForgeCore motion layer  
목적: 현재 구현된 모션에서 음수 방향 관절값이 잘리거나, 좌우 미러 시 반대쪽 관절 부호가 잘못 적용되는 문제를 수정한다.

## 0. 작업 결론

이번 수정은 단순히 왼쪽 무릎 하나를 고치는 작업이 아니다. 현재 Swift 계층에는 다음 두 문제가 같이 있다.

1. `Kinematics.degreeLimits`가 공식 문서/Rust core보다 좁아서 음수 방향 관절값이 `RobotPose.with()`에서 0도 근처로 잘린다.
2. `mirrorSignFlip`가 yaw/roll만 반전하도록 되어 있어, 공식 데이터상 좌우 반전이 필요한 elbow, hip pitch, knee, ankle pitch, shoulder pitch가 잘못 복사된다.

이 두 문제 때문에 사용자는 “왼쪽 관절이 안 굽는다”, “좌우 미러가 반대로 움직인다”, “킥이나 앉기에서 한쪽 다리가 이상하다”고 느낄 수 있다.

## 1. 공식 기준

### 1.1 공식 init pose의 음수 관절

`research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml`

```text
r_el          = +30
l_el          = -30
r_hip_pitch   = -65
l_hip_pitch   = +65
r_knee        = +130
l_knee        = -130
r_ank_pitch   = +70
l_ank_pitch   = -70
```

### 1.2 공식 action page 9 Walk Ready

`research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin` page 9 step 0

```text
r_el          ≈ +29.3°
l_el          ≈ -29.5°
r_hip_pitch   ≈ -36.1°
l_hip_pitch   ≈ +36.1°
r_knee        ≈ +53.2°
l_knee        ≈ -53.2°
r_ank_pitch   ≈ +30.0°
l_ank_pitch   ≈ -30.0°
```

### 1.3 공식 GUI 카탈로그 관측 범위

공식 GUI page `1,2,3,4,9,10,11,12,13,15,17,23,24,27,38,54`에서 invalid/zero slot을 제외하고 관측한 범위다.

| ID | Joint | min | max | 의미 |
| --- | --- | ---: | ---: | --- |
| 5 | `r_el` | -94.7° | +69.9° | 오른쪽 팔꿈치도 음수 사용 |
| 6 | `l_el` | -71.0° | +88.3° | 왼쪽 팔꿈치도 양수 사용 |
| 11 | `r_hip_pitch` | -100.8° | +31.2° | get-up 계열에서 -90° 초과 |
| 12 | `l_hip_pitch` | -33.5° | +98.3° | get-up 계열에서 +90° 초과 |
| 13 | `r_knee` | -1.6° | +130.5° | 거의 양수지만 공식상 약한 음수 존재 |
| 14 | `l_knee` | -132.2° | +0.2° | 왼쪽 무릎은 음수 굽힘이 핵심 |
| 15 | `r_ank_pitch` | -22.3° | +74.9° | 오른쪽 발목도 음수 사용 |
| 16 | `l_ank_pitch` | -77.1° | +18.4° | 현재 Swift -75°보다 살짝 더 음수 |

따라서 “왼쪽 관절만 음수 허용”이 아니라 **좌우 모두 대칭 signed range**로 다루는 것이 맞다.

## 2. 현재 구현 문제

### 2.1 `Kinematics.degreeLimits`가 Rust/docs와 불일치

파일: `app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift`

현재:

```swift
case .rElbow, .lElbow:                   return 0...150
case .rHipPitch, .lHipPitch:             return -90...60
case .rKnee, .lKnee:                     return 0...150
case .rAnklePitch, .lAnklePitch:         return -75...90
```

문제:

- `lElbow = -30`, `lKnee = -130`, `lAnklePitch = -70` 같은 공식값이 safety/UI 경로에서 잘릴 수 있다.
- `RobotPose.with()`는 업데이트되는 joint를 `rawLimits`로 clamp한다.
- 따라서 `.walkReady.with([.lKnee: raw(-80)])`는 현재 `lKnee`를 실제로 -80도로 유지하지 못하고 0도 근처로 잘라버린다.

이미 맞는 기준:

- `docs/architecture/joint-conventions.md`는 `ELBOW -150...150`, `KNEE -150...150`, `ANK_PITCH -90...90`로 정의되어 있다.
- Rust `app/core/forge-core/src/joint/state.rs`도 같은 대칭 limit을 사용한다.

### 2.2 `RobotPose.walkReady` 자체는 맞지만, `.with()` 경로가 망가뜨림

파일: `app/ui/DarwinForge/Sources/ForgeCore/RobotPose.swift`

현재 `RobotPose.walkReady`는 official page 9 raw를 직접 넣고 있어서 맞다.

```swift
.lElbow:      1712   // ≈ -29°
.lKnee:       1443   // ≈ -53°
.lAnklePitch: 1707   // ≈ -30°
```

하지만 `RobotPose.with()`는 다음처럼 clamp한다.

```swift
copy[joint] = value.clamped(to: joint.rawLimits)
```

즉 직접 raw dictionary로 만든 pose는 살아남고, `.with()`로 만든 pose는 음수 방향이 잘릴 수 있다. 이 때문에 같은 프로젝트 안에서도 어떤 모션은 맞고 어떤 모션은 틀어지는 비일관성이 생긴다.

### 2.3 Swift 좌우 미러가 pitch 계열을 반전하지 않음

파일: `app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift`

현재:

```swift
public var mirrorSignFlip: Bool {
    switch self {
    case .rShoulderRoll, .lShoulderRoll,
         .rHipYaw, .lHipYaw,
         .rHipRoll, .lHipRoll,
         .rAnkleRoll, .lAnkleRoll,
         .headPan:
        return true
    default:
        return false
    }
}
```

문제:

- 공식 page 9 기준으로 `rKnee +53°`의 mirror는 `lKnee -53°`다.
- 현재 Swift 미러는 knee/elbow/hipPitch/anklePitch/shoulderPitch를 raw 그대로 복사한다.
- `PoseInspector`의 mirror mode도 이 값을 사용하므로, 오른쪽 무릎 +50도를 움직이면 왼쪽 무릎도 +50도로 들어갈 수 있다. 공식 기준에서는 -50도가 되어야 한다.

Rust core의 `synth/ops/mirror.rs`는 이미 모든 좌우 pair를 중심 기준 reflect하도록 수정되어 있다. Swift도 이 기준에 맞춰야 한다.

### 2.4 starter motion에 명시적 부호 오류 있음

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionStudioView.swift`

현재 starter “앉기”:

```swift
.rKnee: Kinematics.raw(fromDegrees: 90),
.lKnee: Kinematics.raw(fromDegrees: 90)
```

왼쪽 무릎은 공식 convention상 `-90`이어야 한다.

```swift
.lKnee: Kinematics.raw(fromDegrees: -90)
```

이 줄은 limit 수정만으로 해결되지 않는 명시적 부호 오류다.

### 2.5 `ReferenceMotionLibrary`가 예전 walkReady 기준값을 아직 주석/값으로 사용

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift`

예:

```swift
// walkReady 의 hipPitch -8/+8, knee +16/-16, anklePitch -7/+7 에서 ...
let squat3 = RobotPose.walkReady.with([
    .rHipPitch: -9.5,
    .lHipPitch:  9.5,
    .rKnee: 19.0,
    .lKnee: -19.0,
    ...
])
```

현재 `RobotPose.walkReady`는 공식 page 9 기준으로 이미 `rHipPitch ≈ -36`, `rKnee ≈ +53`, `rAnklePitch ≈ +30`이다. 따라서 이 reference page는 “walkReady에서 3도 조정”이 아니라 deep squat에서 거의 직립 쪽으로 크게 펴는 동작이 되어 있다.

이건 음수 clamp와 별개로 모션 의미가 깨져 있는 부분이다. `walkReady` 기준 delta helper로 다시 작성해야 한다.

## 3. Claude에게 요청할 실제 변경 사항

### 작업 1. Swift joint limits를 Rust/docs와 맞춰라

수정 파일:

- `app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift`
- `app/ui/DarwinForge/Tests/ForgeCoreTests/KinematicsTests.swift`

P0 수정값:

```swift
case .rShoulderPitch, .lShoulderPitch: return -180...180
case .rShoulderRoll, .lShoulderRoll:   return -90...90
case .rElbow, .lElbow:                 return -150...150
case .rHipYaw, .lHipYaw:               return -90...90
case .rHipRoll, .lHipRoll:             return -45...45
case .rHipPitch, .lHipPitch:           return -90...90
case .rKnee, .lKnee:                   return -150...150
case .rAnklePitch, .lAnklePitch:       return -90...90
case .rAnkleRoll, .lAnkleRoll:         return -45...45
case .headPan:                         return -90...90
case .headTilt:                        return -45...45
```

주의:

- 공식 get-up page 10/11은 hip pitch가 약 ±100도까지 간다. 하지만 Rust 현재 software limit은 ±90도이므로, 이번 P0에서는 Swift만 독자적으로 ±110으로 넓히지 말 것.
- get-up official raw를 앱에서 직접 재생하려면 별도 P1 작업으로 Swift/Rust limit, self-collision, high-risk gate를 함께 조정해야 한다.

테스트 추가:

- `lElbow`, `lKnee`, `lAnklePitch`가 각각 `-30`, `-130`, `-70`을 포함해야 한다.
- `rElbow`도 `-90`을 포함해야 한다. 공식 GUI catalog에서 `r_el` 음수가 관측된다.
- `rKnee`와 `lKnee` 모두 `-150...150`이어야 한다.

### 작업 2. Swift 좌우 mirror를 공식/Rust 기준으로 수정하라

수정 파일:

- `app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift`
- `app/ui/DarwinForge/Sources/ForgeCore/RobotPose.swift`
- `app/ui/DarwinForge/Tests/ForgeCoreTests/RobotPoseTests.swift`
- `app/ui/DarwinForge/Tests/ForgeCoreTests/KinematicsTests.swift`

변경 방향:

- 모든 좌우 pair는 mirror 시 중심 기준 reflect가 필요하다.
- `headPan`도 reflect가 필요하다.
- `headTilt`만 reflect하지 않는다.

권장 구현:

```swift
public var mirrorSignFlip: Bool {
    switch self {
    case .headTilt:
        return false
    default:
        return true
    }
}
```

단, 위처럼 쓰면 `headPan`은 true, 모든 left/right joint도 true가 된다. 더 명확하게 하려면 `mirrorReflectsAroundCenter`로 rename해도 된다.

`RobotPose.mirrored()`의 reflect 공식은 하나로 고정한다.

현재 Swift는 `4096 - raw`를 사용한다. `Kinematics.raw(fromDegrees:)` 기준으로는 `+d`와 `-d`가 대부분 raw 합 4096이므로 이 방식이 UI angle symmetry에는 맞다. Rust `mirror.rs`는 12-bit value 기준 `4095 - val`을 사용한다. 둘 중 하나로 통일하거나, Swift/Rust fixture에서 ±1 raw 오차를 허용한다. 중요한 것은 “reflect를 해야 한다”는 점이지 raw 1 tick 차이가 아니다.

테스트 추가:

```swift
func testMirrorWalkReadyKeepsOfficialSignedPairs() {
    let mirrored = RobotPose.walkReady.mirrored()
    XCTAssertEqual(mirrored.raw(.lKnee), 4096 - RobotPose.walkReady.raw(.rKnee), accuracy: 1)
    XCTAssertEqual(mirrored.raw(.rKnee), 4096 - RobotPose.walkReady.raw(.lKnee), accuracy: 1)
    XCTAssertEqual(mirrored.raw(.lElbow), 4096 - RobotPose.walkReady.raw(.rElbow), accuracy: 1)
    XCTAssertEqual(mirrored.raw(.lAnklePitch), 4096 - RobotPose.walkReady.raw(.rAnklePitch), accuracy: 1)
}
```

`XCTAssertEqual(..., accuracy:)`는 Int에는 바로 안 맞을 수 있으니 실제 Swift 테스트에서는 `abs(a - b) <= 1` helper를 쓰면 된다.

### 작업 3. `RobotPose.with()` 음수 clamp 회귀 테스트를 추가하라

수정 파일:

- `app/ui/DarwinForge/Tests/ForgeCoreTests/RobotPoseTests.swift`

추가해야 할 테스트:

```swift
func testWithPreservesOfficialNegativeMirrorJoints() {
    let p = RobotPose.walkReady.with([
        .lElbow: Kinematics.raw(fromDegrees: -70),
        .lKnee: Kinematics.raw(fromDegrees: -130),
        .lAnklePitch: Kinematics.raw(fromDegrees: -70),
        .rElbow: Kinematics.raw(fromDegrees: -90)
    ])

    XCTAssertLessThan(p.degrees(.lElbow), -69)
    XCTAssertLessThan(p.degrees(.lKnee), -129)
    XCTAssertLessThan(p.degrees(.lAnklePitch), -69)
    XCTAssertLessThan(p.degrees(.rElbow), -89)
}
```

이 테스트가 현재 코드에서는 실패해야 정상이다. limit 수정 후 통과해야 한다.

### 작업 4. `PoseInspector` mirror mode는 `mirrorSignFlip` 수정 후 수동 보정하지 말 것

파일:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Studio/PoseInspector.swift`

현재 logic:

```swift
let sign = joint.mirrorSignFlip ? -1.0 : 1.0
next = next.with(mate, raw: Kinematics.raw(fromDegrees: degrees * sign))
```

`mirrorSignFlip`를 모든 좌우 pair에 대해 true로 바꾸면 이 경로는 자연스럽게 고쳐진다.

별도 하드코딩으로 knee/elbow만 예외 처리하지 말 것. 예외가 늘어나면 다시 불일치가 생긴다.

### 작업 5. 명시적 잘못된 왼쪽 무릎 부호를 고쳐라

수정 파일:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionStudioView.swift`

수정:

```diff
- .lKnee:     Kinematics.raw(fromDegrees: 90)
+ .lKnee:     Kinematics.raw(fromDegrees: -90)
```

테스트 또는 smoke check:

- starter page “앉기”의 key step에서 `lKnee` degree가 음수인지 확인한다.

### 작업 6. `ReferenceMotionLibrary.walkProgressionPages`의 old walkReady 기준을 제거하라

수정 파일:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift`

현재 문제:

- 주석과 값이 과거 `walkReady hip ±8 / knee ±16 / ankle ±7` 기준이다.
- 현재 기준은 official page 9 `hip ±36 / knee ±53 / ankle ±30`이다.

변경 방향:

- absolute degree를 직접 쓰지 말고, 현재 `.walkReady`에서 delta를 적용하는 helper를 만든다.

예시:

```swift
func deltaPose(_ deltas: [JointID: Double]) -> RobotPose {
    var dict = RobotPose.walkReady.positions
    for (joint, delta) in deltas {
        let base = RobotPose.walkReady.degrees(joint)
        dict[joint] = Kinematics.raw(fromDegrees: base + delta)
    }
    return RobotPose(positions: dict)
}
```

`squat3` 의도 유지 예:

```swift
let squat3 = deltaPose([
    .rHipPitch: -1.5,
    .lHipPitch: +1.5,
    .rKnee: +3.0,
    .lKnee: -3.0,
    .rAnklePitch: +1.5,
    .lAnklePitch: -1.5
])
```

`leanFwd`, `leanBack`도 같은 방식으로 바꿀 것.

주의:

- 여기서는 “현재 walkReady에서 몇 도 더 움직일지”만 표현해야 한다.
- 과거 walkReady 절대값을 주석에 남기지 말 것.

### 작업 7. `WalkMotionLibrary`의 clamp 우회 주석/테스트를 정리하라

수정 파일:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkMotionLibrary.swift`
- `app/ui/DarwinForge/Tests/DarwinForgeUITests/WalkMotionLibraryTests.swift`

현재 `WalkMotionLibrary`는 `mutate()` helper로 `RobotPose.with()` clamp를 우회한다. 이 helper는 현재 limit bug 때문에 필요했던 임시 우회다.

수정 후 선택지:

1. `Kinematics.degreeLimits` 수정 후 `mutate()`를 제거하고 `RobotPose.with()`를 사용한다.
2. 또는 `mutate()`를 유지하되, 주석에서 “Kinematics가 틀려서 우회”라는 설명을 삭제하고 “보행 pose builder는 raw dict를 명시적으로 구성한다” 정도로 바꾼다.

테스트는 hardware range만 보지 말고 software limits도 다시 검증해야 한다.

현재 테스트 주석:

```text
JointID.degreeLimits는 좌우 mirror 비대칭을 표현하지 못해 ...
본 테스트는 hardware-level 안전만 검증.
```

수정 후에는 이 주석을 삭제하고, 모든 WalkLab generated pose가 `JointID.rawLimits` 안에 들어오는지 검증한다.

### 작업 8. `OfficialCatalogReference`는 limit 수정 후 왼쪽 음수값이 유지되는지 테스트하라

수정/테스트 파일:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/OfficialCatalogReference.swift`
- 새 테스트 또는 기존 Motion tests

확인할 페이지:

- `sitDown`: `lKnee`가 -105도 근처여야 한다.
- `wow`: `lElbow`가 -10도 근처여야 한다.
- `oops`: `lElbow`가 -70도 근처여야 한다.
- `clapPlease`: `lElbow`가 -40도 근처여야 한다.
- `leftKick`: lift step의 `lKnee`가 -80도 근처여야 한다.

현재 코드에서는 `RobotPose.with()` 때문에 일부가 0도 근처로 잘릴 가능성이 크다. limit 수정 후 이 테스트가 통과해야 한다.

## 4. 바꾸지 말아야 할 것

이번 작업에서 다음은 건드리지 말 것.

- 하드웨어 FFI / SYNC_WRITE 구현은 별도 작업이다.
- `MotionDoc` 31-slot indexing 문제는 별도 P0이지만, 이번 문서의 주제는 음수 방향과 mirror다.
- Rust `JointLimits`는 이미 Swift보다 올바른 상태다. Swift와 테스트를 Rust/docs에 맞추는 것이 우선이다.
- 공식 get-up page를 통과시키기 위해 Swift만 hip pitch를 ±110으로 넓히지 말 것. Rust/safety와 같이 조정해야 한다.

## 5. 변경 후 기대되는 동작

수정 후 다음이 가능해야 한다.

1. Pose Inspector에서 왼쪽 무릎 slider가 -130도까지 내려간다.
2. 오른쪽 무릎 +50도를 mirror mode로 움직이면 왼쪽 무릎은 -50도가 된다.
3. `RobotPose.walkReady.with([.lKnee: raw(-80)])`가 -80도를 유지한다.
4. OfficialCatalogReference의 left kick이 왼쪽 무릎을 실제로 굽힌다.
5. Starter “앉기”가 양쪽 무릎을 공식 convention대로 `rKnee +90`, `lKnee -90`으로 만든다.
6. WalkLab 테스트에서 더 이상 “Kinematics limit bug 때문에 hardware range만 검사”라는 예외가 필요 없다.

## 6. 완료 조건

Claude는 변경 후 다음을 수행하고 결과를 보고해야 한다.

```bash
swift test
cargo test --workspace
```

최소 통과해야 하는 회귀 테스트:

- `KinematicsTests.testDegreeLimits`
- `RobotPoseTests.testWithPreservesOfficialNegativeMirrorJoints`
- `RobotPoseTests.testMirrorWalkReadyKeepsOfficialSignedPairs`
- `WalkMotionLibraryTests.testAllPosesWithinHardwareLimits` 또는 renamed software-limit test
- OfficialCatalogReference left-kick/sit-down negative joint test

테스트를 실행할 수 없다면, 실행 불가 이유와 대체 검증 결과를 문서화할 것.

## 7. Claude에게 줄 요약 명령

아래 문장을 그대로 작업 지시로 전달하면 된다.

```text
Swift 모션 계층에서 음수 방향 joint와 좌우 mirror를 공식 ROBOTIS/Rust 기준에 맞춰 수정해줘.

핵심은 Kinematics.degreeLimits를 docs/architecture/joint-conventions.md 및 forge-core JointLimits와 일치시키는 것, mirrorSignFlip을 모든 좌우 관절 pair + headPan에 대해 중심 반전하도록 고치는 것, RobotPose.with()가 lElbow/lKnee/lAnklePitch 같은 공식 음수 관절을 clamp하지 않게 회귀 테스트를 추가하는 것이야.

추가로 MotionStudioView starter “앉기”의 lKnee +90 부호 오류를 -90으로 고치고, ReferenceMotionLibrary.walkProgressionPages가 과거 walkReady(-8/+8, ±16, ±7) 기준을 쓰는 부분을 현재 RobotPose.walkReady 기준 delta 방식으로 바꿔줘. WalkMotionLibrary의 clamp 우회 주석과 테스트도 limit 수정 후 기준에 맞게 정리해줘.

하드웨어 FFI/SYNC_WRITE와 MotionDoc slot indexing은 이번 작업 범위 밖으로 두고, Swift 음수 방향/미러/테스트에 집중해줘. 변경 후 swift test와 cargo test --workspace 결과를 알려줘.
```
