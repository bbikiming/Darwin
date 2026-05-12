# DarwinForge 모션 부호 hotfix 검증 요청 — 2026-05-13

> **Audience**: Codex / 외부 코드 리뷰 에이전트
> **상태**: **main 머지 완료** — commit [`b2e9ec6`](../../) (PR #19 `claude/arm-sign-integrate`). Swift 158 tests 통과. 시각·물리 검증 + §B 누락 모션 식별 요청.

## 한 줄 요약

PoseLibrary / OfficialCatalogReference / 일부 starter 모션의 **팔 / 다리 / 발목 pitch joint 부호가 ROBOTIS-OP2 URDF axis 와 정반대**로 작성돼 있어서, "정면 가리키기"가 팔이 뒤로 가고 "의자에 앉기"가 다리가 뒤로 가는 버그가 있었다. 일괄 부호 반전 + 회귀 테스트 추가. **현재 변경이 URDF 와 ROBOTIS 공식 데이터에 정합한지, 시각적으로 의도대로 보이는지 확인** 필요.

## 근본 원인 (Root Cause)

ROBOTIS-OP2 URDF 의 pitch joint axis 는 신체 부위에 따라 Y 방향이 **반대**임:

| 관절 | R axis | L axis |
|---|---|---|
| `hip_pitch` (다리) | `(0, +1, 0)` | `(0, -1, 0)` |
| `knee` (다리) | `(0, +1, 0)` | `(0, -1, 0)` |
| `ank_pitch` (다리) | `(0, -1, 0)` | `(0, +1, 0)` |
| `sho_pitch` (팔) | `(0, -1, 0)` | `(0, +1, 0)` |
| `elbow` (팔) | `(0, -1, 0)` | `(0, +1, 0)` |

검증 출처: `vendor/robotis-op2-common/urdf/robotis_op2.structure.{arm,leg}.xacro`.

→ **다리 hip pitch 와 팔 shoulder pitch 는 부호 의미가 정반대**.

Rodrigues 회전 + ROBOTIS `ini_pose.yaml` `tar_pose` (`r_hip_pitch=-65 = hip flex 65°`) 교차 검증 결과, **"신체 앞·위 의도"** 의 올바른 부호:

| 의도 | R 부호 | L 부호 | 검증 |
|---|:-:|:-:|---|
| 다리 앞·굽힘 (hip flex) | **−** | **+** | ini_pose `r_hip_pitch=-65 / l_hip_pitch=+65` |
| 무릎 굽힘 | **+** | **−** | ini_pose `r_knee=+130 / l_knee=-130` |
| 발끝 위 (ankle dorsiflex) | **+** | **−** | ini_pose `r_ank_pitch=+70 / l_ank_pitch=-70` |
| **팔 앞·위 (sho pitch)** | **+** | **−** | URDF Rodrigues + `Walking.cpp dir[R_ARM_SWING]=+1` |
| 팔꿈치 굽힘 (elbow flex) | **+** | **−** | ini_pose `r_el=+30 / l_el=-30` |

기존 PoseLibrary 작성자가 "R 음수 = 앞" 한 가지 규칙을 모든 관절에 일반화 → 팔(반대 axis)·일부 다리 모션의 부호가 통째로 뒤집혀 있었음.

## 변경 사항

> **두 부분이 같은 commit (`b2e9ec6`) 에 함께 들어감**. 분석 흐름상 1차 (팔) / 2차 (다리) 로 구분해 서술하지만 실제로는 단일 PR.
> 총 `git show b2e9ec6 --stat`: 7 파일, +357 / −109.

### 1차 — 팔 (shoulder pitch) 일괄 반전

**파일** (모두 `app/ui/DarwinForge/` 하위):
- `Sources/ForgeCore/PoseLibrary.swift` — 모든 entry 의 `r/lShoulderPitch` 값 부호 반전 (48 occurrences). PoseLibrary diff 총 168 라인 (다리 fix 포함).
- `Sources/DarwinForgeUI/Motion/OfficialCatalogReference.swift` — `thankYou` / `sitDown` / `yesGo` / `wow` / `byeBye` / `clapPlease` 의 shoulder pitch 부호 반전 (13).
- `Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift` — 5개 reference motion 의 shoulder pitch 반전 (9).
- `Sources/DarwinForgeUI/Motion/MotionStudioView.swift` — starter `손 흔들기` (203) 의 `rShoulderPitch -120 → +120` (4 occurrences).
- `Tests/DarwinForgeUITests/RobotSnapshotTests.swift` — 스냅샷 `waving` pose 반전.

### 2차 — 다리 (hip pitch / ankle pitch) per-motion 반전

같은 작성자 실수가 일부 다리 모션에도 있어서 의도별 검증 후 부호 반전. **`squat_down` 의 hip 만 처음부터 맞고 나머지 다 뒤집힘**.

**파일**: `app/ui/DarwinForge/Sources/ForgeCore/PoseLibrary.swift` (위 1차 diff 의 일부)

| 모션 ID | 의도 | 수정 |
|---|---|---|
| `sit_chair` | 앉기 (다리 앞 굽힘) | rHip `80→-80` / lHip `-80→+80` / rAnk `-10→+10` / lAnk `10→-10` |
| `lunge_right` | R 발 앞 lunge | rHip `45→-45` / rAnk `-35→+35` |
| `kick_forward_right` | R 발 앞 차기 | rHip `60→-60` / rAnk `-20→+20` |
| `kick_back_right` | R 발 뒤로 빼기 | rHip `-30→+30` |
| `soccer_kick_right_swing` | R 발 앞 임팩트 | rHip `50→-50` / rAnk `-25→+25` |
| `soccer_kick_right_back` | R 발 백스윙 | rHip `-25→+25` / rAnk `10→-10` |
| `warrior_pose` | R 발 앞 (요가) | rHip `30→-30` / rAnk `-25→+25` |
| `tree_pose` | L 발 들기 | lHip `-40→+40` |
| `fighting_stance` | 양다리 앞 (boxing) | rHip `10→-10` / lHip `-10→+10` |
| `gangnam_horse` | 양다리 앞 (말춤) | rHip `20→-20` / lHip `-20→+20` |
| `squat_down` | (hip 이미 정답) | rAnk `-25→+25` / lAnk `25→-25` 만 |

### 손대지 않은 부분 (의도적으로 보존)

- **`RobotPose.walkReady`** — ROBOTIS `motion_4096.bin` page 9 의 raw 그대로. `rShoulderPitch=-48° / lShoulderPitch=+48°` 는 deep squat counter-balance 의 의도적 후방 자세.
- **knee 부호** — 모든 모션에서 R+, L- 일관적, 변경 없음.
- **`OfficialCatalogReference` 의 leg motion** — `sitDown` (rHip `-75/+75`), `rightKick` (rHip `-60`), `leftKick` (lHip `+60`) 모두 URDF 와 이미 일치, 변경 없음.
- **`WalkMotionLibrary`** 보행 gait — `walkReady ± swingDeg` 수식이 이미 URDF-consistent, 변경 없음.
- **shoulder roll, hip roll/yaw, ankle roll, head** — 이번 hotfix 범위 밖.
- **`goalkeeper_save_right`** — 다이빙 복합 자세, 단순 forward/back 분류 어려워 보류.

### 문서·에이전트 갱신

- `docs/architecture/joint-conventions.md` — "신체 방향 부호 규칙 (motion authoring)" 섹션 추가. 다리 vs 팔 URDF Y-axis 반전 명시 + 의도별 R/L 부호표.
- `.claude/agents/motion-composer.md` — 시스템 지식에 동일 부호 규약 표 박아넣음. 향후 LLM 작성 모션이 같은 실수 반복 방지.

### 신규 회귀 테스트 (3 + 6 = 9개)

**파일**: `app/ui/DarwinForge/Tests/DarwinForgeUITests/ArmSignConventionTests.swift`

1. `testForwardIntentHasPositiveRShoulder` — `point_forward / handshake / salute / wave_right` 의 `rShoulderPitch > 0`.
2. `testHandsUpHasMirrorPair` — `hands_up` 의 R+/L- mirror.
3. `testMirrorPairInvariantInPoseLibrary` — 9개 만세류 자세의 `|R| ≈ |L|` (tolerance 10°, walkReady 7° 비대칭 흡수).
4. `testOfficialCatalogArmIntentsArePositive` — `thankYou / yesGo / wow / byeBye / clapPlease / sitDown` peak step 의 `rShoulderPitch > walkReady`.
5. `testRightElbowMovesForwardWithPositiveShoulderPitch` — **geometry-level**, MeshRig 인스턴스에 `rShoulderPitch +90°` 적용 후 `joints[.rElbow].worldPosition.z` 가 더 음수쪽으로 (SceneKit -Z = ROS forward).
6. `testLeftElbowMovesForwardWithNegativeShoulderPitch` — mirror.
7. `testForwardLegIntentHasNegativeRHipPitch` — `squat_down / sit_chair / lunge_right / kick_forward_right / warrior_pose / soccer_kick_right_swing` 의 `rHipPitch < 0`.
8. `testBackwardLegIntentHasPositiveRHipPitch` — `kick_back_right / soccer_kick_right_back` 의 `rHipPitch > 0`.
9. `testLeftLegLiftHasPositiveLHipPitch` — `tree_pose` 의 `lHipPitch > 0`.

## 검증 요청 (Codex 가 해줬으면 하는 것)

### A. 부호 정합성 재확인

위 표의 R/L 부호가 **ROBOTIS-OP2 URDF + `ini_pose.yaml` + Walking.cpp `dir[]` 배열** 과 100% 일치하는지 독립 검증.

특히:
1. `vendor/robotis-op2-common/urdf/robotis_op2.structure.{arm,leg}.xacro` 의 `<axis>` 태그 vs 본 hotfix 의 R/L 부호 가정.
2. `research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml` 의 `tar_pose` 값 → "deep squat" 의도 → 위 부호 표.
3. `DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/modules/Walking.cpp:366` 의 `dir[14]` 배열이 본 hotfix 의 부호 가정과 모순되지 않는지.

### B. 누락 모션 식별

본 hotfix 가 **놓쳤을 수도 있는** 모션을 찾아줘:

1. **PoseLibrary.swift** 의 entry 중 hip pitch / ankle pitch 가 명시됐고, description 이 "forward / backward / lift / kick / sit / squat / lunge / dive" 등 방향성을 담고 있는데 위 표에 없는 것.
2. **OfficialCatalogReference.swift** 의 16 page 중 hip/ankle pitch 가 URDF 와 안 맞는 항목 (이번엔 leg 쪽은 변경 안 했음).
3. **ReferenceMotionLibrary.swift** 의 hip/ankle pitch override (현재까진 reference motion 의 다리 부호는 검토 안 함).
4. **MotionStudioView.swift** starter 의 다리 부호. `앉기` starter (ID 204) 는 `sitDeltas` (rHip −9 / lHip +9 / rKnee +37 / lKnee −37 / rAnklePitch +15 / lAnklePitch −15) 로 작성돼 URDF 정합 — 별도 검증 완료. **다른 starter 가 있다면 동일 확인 필요**.
5. `goalkeeper_save_right` 의 의도 분석 — 다이빙 자세의 hip pitch 부호가 옳은지.

### C. 시각·물리 검증 (가능하면)

1. `swift test --filter ArmSignConventionTests` 가 9/9 통과하는지.
2. SwiftUI 앱 (`.build/debug/DarwinForgeApp`) 실행 후 동작 라이브러리 / 공식 카탈로그 / Motion Studio 에서 다음을 재생하고 시각 확인:
   - "정면 가리키기" → 오른팔이 정면 (camera Z- 방향) 으로 뻗어야.
   - "의자에 앉기" → 양 무릎 굽힘 + 양 허벅지가 정면 쪽으로 (Z- 방향) 향해야.
   - "만세" → 양팔 위로 올라가야.
   - "오른발 앞 차기" → R 발이 정면으로 swing.
   - "왼발 들기 (tree pose)" → L 무릎 굽혀 위로 들어 올림.
3. **회귀**: 변경 이전엔 잘 보였던 모션 중 이번에 깨진 것이 없는지 — 특히 `walkReady` 자체 (deep squat) 가 여전히 정상으로 보이는지.

### D. 코드 품질

- 부호 반전이 `RobotPose.with()` 의 `clamped(to: rawLimits)` 에 잘려서 의도가 손실된 곳은 없는지 (이전에 `lKnee -130` 이 `0…150` 범위에 잘리던 버그가 있어 `KinematicsTests` 가 이를 잡고 있음 — 신뢰).
- mirror pair invariant (`R + L ≈ 0`) 가 깨진 곳은 없는지 (`testMirrorPairInvariantInPoseLibrary` 참조).
- `validate` 4-stage (JointLimit / Velocity / SelfCollision / StaticStability) 결과가 hotfix 전후 동일하게 PASS 인지 (특히 deep flex motion 에서 self-collision 신규 발생 위험).

## 빠른 검증 커맨드

repo root: `/Users/bbikiming/Documents/vibe_coding/Darwin` (branch: `main`).

```bash
# 1. Build + 모든 테스트
cd app/ui/DarwinForge
swift build && swift test 2>&1 | tail -10
# 기대: "Executed 158 tests, with 0 failures"

# 2. 부호 회귀 테스트만 (9개)
swift test --filter ArmSignConventionTests 2>&1 | tail -15

# 3. 머지된 commit 의 변경 내용 확인
cd ../../..
git show b2e9ec6 --stat
git show b2e9ec6 -- app/ui/DarwinForge/Sources/ForgeCore/PoseLibrary.swift

# 4. 모션 JSON 시각 변환 (시뮬레이터/Webots 보유 시)
forge motion play --slot 15 --dry-run --bin <path-to-motion_4096.bin-copy>
```

## 참고 문서

- `docs/architecture/joint-conventions.md` — 신체 방향 부호 규칙 표 + 검증 출처
- `docs/reports/CLAUDE_NEGATIVE_JOINT_FIX_DIRECTIVE_2026-05-12.md` — 1차 (limit + mirror) hotfix 디렉티브
- `docs/reports/DARWIN_OP_MOTION_UPGRADE_PROPOSAL_2026-05-12.md` — 전체 모션 layer 업그레이드 plan
- `vendor/robotis-op2-common/urdf/robotis_op2.structure.{arm,leg,head}.xacro` — URDF ground truth
- `research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml` — `tar_pose` ground truth
- `DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/modules/Walking.cpp:366` — `dir[14]` per-joint sign 배열

## 머지된 commit 정보

```
b2e9ec6  hotfix(motion): URDF 기반 팔 부호 통일 — R shoulder pitch 양수 = 정면
f92d3a5  Merge pull request #19 from bbikiming/claude/arm-sign-integrate
```

`b2e9ec6 --stat`:
```
 .../DarwinForgeUI/Motion/MotionStudioView.swift              |   8 +-
 .../Motion/OfficialCatalogReference.swift                    |  26 +--
 .../Motion/ReferenceMotionLibrary.swift                      |  18 +-
 .../Sources/ForgeCore/PoseLibrary.swift                      | 168 ++++++++--------
 .../Tests/DarwinForgeUITests/ArmSignConventionTests.swift    | 216 +++++++++++++++++++++  (신규)
 .../Tests/DarwinForgeUITests/RobotSnapshotTests.swift        |   5 +-
 docs/architecture/joint-conventions.md                       |  25 +++
 7 files changed, 357 insertions(+), 109 deletions(-)
```

> ⚠️ commit subject 는 "팔 부호" 만 언급하지만 **실제로는 다리 (hip/ankle pitch) 부호 hotfix 까지 함께 포함**. PoseLibrary diff 168 라인 중 후반부가 다리 fix.

---

**Follow-up 흐름**: Codex 검증 결과 (특히 §B 누락 모션) 회수 후,
- 추가 부호 반전이 필요하면 별도 PR `claude/<branch>` 생성 → 회귀 테스트 확장 → main 머지.
- 시각 검증에서 회귀 발견되면 동일 사이클.
- `motion-composer` 에이전트가 향후 새 모션 작성 시 [joint-conventions.md](../architecture/joint-conventions.md) 의 부호 표 자동 참조하도록 이미 박혀 있음.
