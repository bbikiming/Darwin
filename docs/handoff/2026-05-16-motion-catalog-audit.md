# v1.1 Motion Catalog Audit — Codex 검수 요청

**대상**: PR #24 (`feature/v1.1-motion-catalog-300`) 의 320 신규 모션 + 부호 hotfix.
**작성자**: Claude (자기 평가 채움) → **Codex** (외부 검수 요청).
**기준**: v1.0 의 4-pass Codex audit 패턴 (19 issues found and fixed).

---

## 배경

사용자 요구: "**모든 모션의 근거는 공식 모션과 로봇 자체에 있던 데모 모션 기반이어야 해**" + "관절이 반대로 동작하거나 신체끼리 겹치는 게 없이, 고장날 이슈가 없는 동작인지 논리적으로 파악."

PR #24 는 v1.1 의 320 신규 모션 카탈로그 + Sidebar+Grid UI. 부호 hotfix 1회 적용 (commit `9833ddc`) — sho pitch / elbow / head tilt 일괄 반전. 그러나 잔존 위험 영역이 있어 Codex 의 다각도 검수가 필요함.

## 검수 영역 6

### 1. 잔존 부호 정합성

**확정 정정 (commit `9833ddc`)**:
- `rShoulderPitch` / `lShoulderPitch` (어깨 pitch)
- `rElbow` / `lElbow` (팔꿈치)
- `headTilt` (머리 tilt)

**잔존 위험 영역** (자동 swap 제외):
- **`rShoulderRoll` / `lShoulderRoll`** — 외전 (T 자세) 은 R−/L+, 내전 (X 가슴) 은 R+/L−. 의도가 모션마다 달라 inline delta 검수 필요.
- **`rHipRoll` / `lHipRoll`** — balance 모션의 `hipSwayR/L` 자세에서 부호. doc 규약 정밀 비교.
- **`rAnkleRoll` / `lAnkleRoll`** — hip roll 보상용 ankle 보정. 부호 정합성.
- **`rHipYaw` / `lHipYaw`** — 회전 모션 (`90° 회전` 등). doc 에 명시되지 않은 케이스.

**검수 방법**: `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/BundledMotionCatalog.swift` 의 각 inline `deltaFromWalkReady` 호출을 `docs/architecture/joint-conventions.md` 의 부호 표와 대조.

### 2. 출처 정합성

각 모션이 다음 중 어디에 근거하는지 명확히 표기되어야 함:
- **공식 ROBOTIS** — `motion_4096.bin` page 1~54 (16 catalog) + 사용자 로봇의 실 페이지
- **Personal Assistant op2** — page 100~108 (ergonomic 케어) + page 250~255 (인사 set)
- **HROS5-Framework** — `Data/motion_4096.bin` (GPL 격리, 페이지 디자인만 인용)
- **NimbRo / DarwinOP-ENS** — Walking.cpp / Action.h 패턴
- **자체 발상** — 외부 출처 없음. UI/UX 기획자 (사용자) review 필요.

**검수 방법**: `BundledMotionCatalog.swift` 의 각 `funcPages()` 머리 docstring 의 출처 표기 정확성 + 카테고리별 자체 발상 비율 확인.

### 3. 신체 자가충돌

다음 자가충돌 시나리오를 모션마다 검토:
- **양팔 등 뒤 만남** — `rShoulderPitch` 강한 음수 + `lShoulderPitch` 강한 양수 동시 (자동 회귀 `testNoBackArmCollisionExtremes` 가 ±110°+ 차단)
- **손 - 얼굴 통과** — 양손이 머리 영역 (raw 1500~2600) 안에서 만나는 자세
- **팔 - 다리 통과** — `armsHipHip` 같은 자세에서 팔이 다리 영역 침범
- **발 - 발 충돌** — 양 다리 X자 교차 (`hip yaw` + `hip roll` 조합)
- **머리 - 어깨** — `headTilt` 강한 양수 + `rShoulderRoll` 강한 음수 = 머리가 어깨에 닿음

**검수 방법**: `forge-core/src/safety/self_collision.rs` 의 5 규칙 (knee hyperextension / hip roll / shoulder roll / arm-head / hip+knee 결합) 을 320 모션 fixture 에 대해 실행. Rust 측에서 cargo test 가능.

### 4. JointLimits 안전

모든 raw position 이 `app/core/forge-core/src/joint/state.rs::JointLimits::for_joint(j)` 의 software 한도 안:
- SHOULDER_PITCH ±180° / SHOULDER_ROLL ±90° / ELBOW ±150°
- HIP_YAW ±90° / HIP_ROLL ±45° / HIP_PITCH ±90°
- KNEE ±150° / ANKLE_PITCH ±90° / ANKLE_ROLL ±45°
- HEAD_PAN ±90° / HEAD_TILT ±45°

**검수 방법**: Rust `synth::validator::joint_limit::JointLimitValidator` 를 모든 카테고리 페이지에 적용. Mac 빌드 + cargo test 또는 `forge synth validate <page>` CLI.

### 5. Mirror invariant

좌·우 대칭 자세 (예: `armsUp`, `armsT`, `bowSlight`) 에서 R+L sum 이 walkReady 의 sum 과 ±100 raw 안.

```
walkReady sho_pitch sum  = 1498 + 2518 = 4016
walkReady sho_roll  sum  = 1845 + 2248 = 4093
walkReady hip_pitch sum  = 1637 + 2459 = 4096
walkReady knee      sum  = 2653 + 1443 = 4096
walkReady ankle_pitch sum = 2389 + 1707 = 4096
```

대칭 자세는 자가 검증: `pose.raw(.rX) + pose.raw(.lX) ≈ wr.raw(.rX) + wr.raw(.lX)`.

**검수 방법**: 모든 페이지 의 모든 step 에 대해 R+L sum 계산. 의도된 비대칭 (예: `armsRightWave`, `armsLeftWave`) 은 예외 처리.

### 6. 이름-동작 일치

모션 이름이 실제 동작과 일치:
- "만세" → 양 어깨 raw 가 walkReady 보다 위 방향 (`+/−` 정합)
- "절" → hip 앞 굽힘 + head chin down
- "T 자세" → 양 어깨 roll 외전
- "위 봄" → head tilt chin up
- "오른손 인사" → R 어깨 pitch raw 증가, L 변화 미미

**검수 방법**: 모션 이름 키워드 (만세 / 절 / T / 위 / 아래 / 오른손 / 왼손 / 굽힘 / 펴기 / 들기 등) 와 실제 raw delta 방향을 자동 매칭. Codex 가 카테고리별 sample 검토.

---

## 자기 평가 (Claude)

### 잘된 점
- **부호 hotfix 적용** (commit `9833ddc`): sho pitch / elbow / head tilt 일괄 반전 후 9 회귀 테스트 lock-in
- **자가충돌 사전 검출**: `testNoBackArmCollisionExtremes` 가 양 팔 등 뒤 ±110°+ 차단
- **JointLimits 보수 한도**: `testAllRawsWithinConservativeSoftwareLimit` 가 ±168° 안 강제
- **카테고리 구조**: 15 카테고리 + Sidebar+Grid UI 로 일관 분류
- **회귀 9 건**: walkReady 시작·종료, ID unique, 부호 정합성, 자가충돌 가드

### 부족한 점 (사용자 지적)
- **출처 정합성 75% 미흡** — 320 모션 중 약 250 (78%) 가 자체 발상. 공식 ROBOTIS·외부 reference 인용 없음.
  - 사용자 요구 "공식+로봇 데모 기반" 과 미정렬.
  - **선택 B** 진행: 320 유지 + 출처 docstring 추가 (이번 PR 정정 commit).
- **잔존 부호 미검수**: sho roll / hip roll / ankle roll / hip yaw inline delta 부호 자동 swap 제외. 의도가 모션마다 달라 1:1 review 필요.
- **Mac 빌드 미검증**: 컨테이너에서 `swift test --filter BundledMotionCatalogTests` 실행 불가. 9 회귀가 실제 통과하는지 사용자 Mac 검증 필요.
- **Self-collision Rust 회귀 미실행**: `synth::validator::self_collision` 을 320 페이지에 안 돌렸음 — Mac/cargo test 필요.

### 알려진 한계
- `MotionPrimitives` 의 일부 자세 (예: `armsRightSalute`, `armsPraying`) 가 휴머노이드 어깨/팔꿈치 메커니즘에 정확히 매칭되지 않을 수 있음 — 실 로봇 실행 시 자세가 예상과 다를 가능성.
- `bowDeep` (-25°/+25° hip pitch + head -20° tilt) 의 깊이가 실 로봇의 균형 한계 (낙상 임계) 안인지 미검증.

---

## Codex 에게 — 검수 절차

### 진행 방식

1. **저장소 동기화**
   ```bash
   git fetch origin
   git checkout feature/v1.1-motion-catalog-300
   git pull
   ```

2. **검수 영역 1~6 시행** — 위 각 영역의 "검수 방법" 항목 따라 분석.

3. **카테고리별 sample 검토** (15 카테고리, 각 3~5 페이지 sample):
   - 기본자세 / 인사 / 표현감정 / 댄스 / 스트레칭 / 요가 / 무술 / 보행변형 / 균형 / 시선 / 데모 / 체조 / 복구 / 명상 / 합성

4. **회귀 테스트 추가 권고** — 자동으로 검출 가능한 invariant 가 누락됐다면 신규 테스트 작성 권장.

5. **PR #24 comment** 로 결과 보고:
   ```
   ## Codex Audit Result — v1.1 Motion Catalog

   ### 영역 1 (부호 정합성): [PASS / FAIL]
   - 발견 사항 N개
   - ...

   ### 영역 2 (출처 정합성): ...
   ### ...
   ```

### 출력 형식

각 영역마다:
- **Status**: PASS / WARN / FAIL
- **Findings**: 발견된 issue (있다면)
- **Recommendation**: 정정 권고 (작은 수정 / 큰 refactor / 별도 PR 등)

---

## 참고 자료

- v1.0 audit handoff: `docs/handoff/2026-05-14-motion-code-audit-claude-prompt.md`
- Joint 부호 규약: `docs/architecture/joint-conventions.md` (특히 2026-05-13 hotfix 표)
- ROBOTIS 공식 모션 16: `app/core/forge-core/src/motion/library.rs::OFFICIAL_CATALOG`
- 외부 reference 카탈로그: `motions/external/_pages-summary.md`
- 기존 starter motion: `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift`
- v1.1 카탈로그: `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/BundledMotionCatalog.swift`

## Sign-off

검수 완료 후 사용자 (UI/UX 기획자) 가 다음 결정:
- 자체 발상 모션 중 유지할 항목 / 제거할 항목
- Codex 발견 issue 의 정정 우선순위
- v1.1.0 tag 머지 여부
