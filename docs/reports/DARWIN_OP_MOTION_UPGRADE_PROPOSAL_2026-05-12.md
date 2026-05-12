# DARwIn-OP 모션 안정화 업그레이드 기획서

작성일: 2026-05-12  
대상: DarwinForge / ROBOTIS DARwIn-OP, ROBOTIS OP2 계열 제어 앱  
목표: 현재 앱에서 발생하는 관절 뒤틀림, 좌우 반전, 보행/킥 모션 불안정 문제를 공식 데이터와 코드 근거로 분해하고, 수정 우선순위와 검증 기준을 제안한다.

## 1. 결론 요약

현재 프로젝트는 “제어 앱의 형태”는 꽤 갖춰져 있지만, 모션 안정성 관점에서는 기준 데이터가 여러 층에서 섞여 있다. 특히 Swift UI 계층, Rust core 계층, 공식 ROBOTIS motion_4096 데이터의 31-slot 인덱스 규칙과 좌우 관절 부호 규칙이 일관되지 않다.

가장 먼저 고칠 부분은 다음 4개다.

1. **Swift `MotionStep`의 관절 인덱스 매핑 수정**
   - 공식 `motion_4096.bin`과 Rust core는 `positions[joint_id]` 규칙을 쓰는 구조다. 즉 slot 0은 예약/invalid, joint ID 1은 `positions[1]`이다.
   - 현재 Swift `MotionDoc.swift`는 `positions[joint_id - 1]`로 읽고 쓴다. 공식 모션이나 Rust에서 만든 모션을 Swift로 가져오면 모든 관절이 한 칸씩 밀릴 수 있다.

2. **Swift 관절 각도 제한 재정의**
   - 공식 `ini_pose.yaml`과 `motion_4096.bin`은 왼쪽 팔꿈치, 왼쪽 무릎, 왼쪽 발목 pitch에 음수 방향 값을 사용한다.
   - 현재 Swift `Kinematics.swift`는 좌우 팔꿈치와 무릎을 모두 `0...150`도로 제한한다. 이러면 왼쪽 무릎 `-53도`, 왼쪽 팔꿈치 `-29도` 같은 공식 walk ready 값이 UI/pose 생성 과정에서 0도 쪽으로 클램프될 수 있다.

3. **실제 로봇 송출은 반드시 SYNC_WRITE 중심으로 통합**
   - Rust core에는 이미 다중 관절 동시 명령 `set_positions_many`가 있다.
   - Swift FFI/UI에서는 아직 관절마다 `setPosition`을 반복 호출하는 경로가 많다. 동작 중 관절별 시간차가 생기면 모션이 비틀린 것처럼 보이거나 실제로 균형을 잃을 수 있다.

4. **WalkLab 실기체 보행은 “공식 보행”이 아니라 “수제 joint-space 보간”으로 분리**
   - 현재 Rust `walk::engine`은 주석상 “실 IK는 후속 사이클”인 MVP 상태다.
   - `WalkMotionLibrary.swift`는 공식 보행 IK가 아니라 hand-authored pose sequence다. 실제 바닥 보행 기능처럼 노출하면 위험하다. 크래들/무부하 검증 전까지 실기체 보행은 실험 모드로 잠그는 것이 맞다.

## 2. 공식 기준 데이터

이번 판단에서 기준으로 삼은 공식/원본 데이터는 다음이다.

| 기준 | 위치 | 이 문서에서 사용하는 의미 |
| --- | --- | --- |
| ROBOTIS OP2 device config | `research/robotis-official/ROBOTIS-OP2/op2_manager/config/OP2.robot` | 제어 주기 8ms, MX-28 Protocol 1.0, joint ID 1..20의 공식 이름 |
| ROBOTIS OP2 init pose | `research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml` | 보행 모듈 초기 목표 자세. hip/knee/ankle가 깊게 접히는 기준 자세 |
| ROBOTIS OP2 walking params | `research/robotis-official/ROBOTIS-OP2/op2_walking_module/config/param.yaml` | 공식 보행 모듈의 period, double support, foot height, balance gain 기준 |
| ROBOTIS GUI motion catalog | `research/robotis-official/ROBOTIS-OP2/op2_gui_demo/config/gui_motion.yaml` | 사용자에게 노출되는 공식 action page 이름과 page ID |
| ROBOTIS motion binary | `research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin` | 실제 action page raw pose. walk ready page 9 검증 fixture |

공식 웹/원격 출처:

- ROBOTIS OP2 ROS package e-Manual: https://emanual.robotis.com/docs/en/platform/op2/ros_package/
- ROBOTIS-GIT/ROBOTIS-OP2 repository: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2
- `OP2.robot`: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2/blob/master/op2_manager/config/OP2.robot
- `ini_pose.yaml`: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2/blob/master/op2_manager/config/ini_pose.yaml
- `param.yaml`: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2/blob/master/op2_walking_module/config/param.yaml
- DYNAMIXEL Protocol 1.0 Sync Write: https://emanual.robotis.com/docs/en/dxl/protocol1/#sync-write

## 3. 현재 프로젝트 구조 요약

현재 앱은 크게 세 층이다.

| 층 | 역할 | 현재 상태 |
| --- | --- | --- |
| Swift UI / ForgeCore | macOS UI, pose editing, Motion Studio, Walk Lab, Bus wrapper | UX는 빠르게 확장됐지만 모션 포맷과 limits 일부가 공식 기준과 다름 |
| Rust forge-core | joint model, bus/protocol, synth, safety, walking stub | joint ID 매핑과 일부 synth는 안정화됐으나 walk engine은 아직 공식 보행 수준이 아님 |
| ROBOTIS official data mirror | OP2 config, walking params, motion_4096 | 기준 데이터로 사용할 수 있으나 앱 UI 경로 전체에 아직 일관되게 반영되지 않음 |

중요한 점은 Rust core의 일부 과거 문제는 이미 수정된 것으로 보인다는 것이다. 예를 들어 mirror synth 쪽의 joint ID mapping은 현재 `positions[joint_id]` 기준으로 수정돼 있다. 따라서 기존 감사 문서를 그대로 믿고 “Rust 전체가 틀렸다”고 판단하면 안 된다. 지금 가장 위험한 부분은 Swift UI 계층과 FFI/실기체 송출 경로에 남아 있다.

## 4. 핵심 문제와 근거

### P0-1. Swift MotionDoc의 31-slot 인덱스가 공식 motion_4096과 다름

현재 코드:

- `app/ui/DarwinForge/Sources/ForgeCore/MotionDoc.swift`
- `raw(for:)`가 `idx = joint.rawValue - 1` 사용
- `from(pose:)`도 `positions[joint_id - 1]`에 기록

문제:

- 공식 motion_4096과 Rust core가 쓰는 구조는 `positions[joint_id]`이다.
- slot 0은 pad/invalid 영역이다.
- Swift에서 공식 모션을 가져오면 joint 1 값이 joint 2처럼 해석되는 식의 한 칸 밀림이 생긴다.

공식 page 9 Walk ready의 step 0을 로컬 binary에서 직접 디코딩하면 다음과 같다.

```text
slot 0  = 16384 = 0x4000 invalid
slot 1  = 1498  = r_sho_pitch
slot 2  = 2518  = l_sho_pitch
slot 5  = 2381  = r_el
slot 6  = 1712  = l_el
slot 11 = 1637  = r_hip_pitch
slot 12 = 2459  = l_hip_pitch
slot 13 = 2653  = r_knee
slot 14 = 1443  = l_knee
slot 15 = 2389  = r_ank_pitch
slot 16 = 1707  = l_ank_pitch
slot 20 = 2161  = head_tilt
```

이 값은 `RobotPose.walkReady`에 들어간 값과도 일치한다. 따라서 Swift `MotionDoc`이 공식 모션과 맞으려면 joint ID를 그대로 index로 써야 한다.

수정 제안:

- `MotionStep.raw(for:)`: `idx = Int(joint.rawValue)`로 변경
- `MotionStep.from(pose:)`: `positions[Int(j.rawValue)]`에 기록
- slot 0은 공식 `0x4000` invalid로 보존
- 기존 앱 내부 문서에서 쓰던 `32767` skip marker는 마이그레이션 호환으로만 처리

검증 기준:

- page 9 fixture에서 `.rShoulderPitch == 1498`, `.lShoulderPitch == 2518`, `.rKnee == 2653`, `.lKnee == 1443`가 통과해야 한다.
- `MotionDocTests`의 `positions[0] = r_shoulder` 테스트는 폐기하고 `positions[1] = r_shoulder`로 바꿔야 한다.
- Swift -> Rust -> Swift roundtrip에서 31개 slot이 byte-preserving이어야 한다.

### P0-2. Swift 관절 제한이 공식 좌우 부호와 충돌

현재 코드:

- `app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift`
- 팔꿈치: `.rElbow, .lElbow: 0...150`
- 무릎: `.rKnee, .lKnee: 0...150`

공식 근거:

- `ini_pose.yaml` target pose:
  - `r_knee = 130`
  - `l_knee = -130`
  - `r_ank_pitch = 70`
  - `l_ank_pitch = -70`
- `motion_4096.bin` page 9:
  - `r_knee ≈ +53도`
  - `l_knee ≈ -53도`
  - `r_ank_pitch ≈ +30도`
  - `l_ank_pitch ≈ -30도`
  - `r_elbow ≈ +29도`
  - `l_elbow ≈ -29도`

문제:

- 현재 Swift limit에서는 왼쪽 무릎/팔꿈치의 음수 방향이 허용되지 않는다.
- `RobotPose.with()`는 모든 입력을 `joint.rawLimits`로 클램프한다.
- 그래서 공식 기준에 맞춰 만든 왼쪽 다리/팔 동작이 UI 내부에서 무의식적으로 0도 근처로 잘릴 수 있다.
- 사용자가 보는 현상으로는 “오른쪽은 되는 것 같은데 왼쪽이 안 접힌다”, “좌우가 비대칭”, “반대로 움직인다”로 나타날 가능성이 높다.

수정 제안:

- Swift `JointID.degreeLimits`를 좌우별 signed limit로 다시 정의한다.
- 단기적으로는 Rust `JointLimits`와 동일한 source of truth를 Swift로 export하거나 generated file로 맞춘다.
- 중기적으로는 공식 motion_4096 전체를 스캔해 관절별 raw min/max를 산출하고, 그 주변에 안전 margin을 둔 “official observed range”와 “hardware absolute range”를 분리한다.

검증 기준:

- `ini_pose.yaml`의 target pose를 Swift `RobotPose`로 만들 때 어느 관절도 의도치 않게 0도 쪽으로 클램프되지 않아야 한다.
- page 9 walk ready를 `MotionDoc -> RobotPose -> MotionDoc` roundtrip해도 좌우 knee/ankle/elbow 값이 유지돼야 한다.
- UI slider range는 “좌우 같은 숫자 범위”가 아니라 “공식 부호가 반영된 움직임 의미”로 보여야 한다.

### P0-3. 실제 송출 경로가 관절별 반복 호출 중심

현재 코드:

- Rust `JointController.set_positions_many()`는 SYNC_WRITE를 사용한다.
- Swift `Bus.swift`는 단일 `setPosition()`만 FFI로 노출한다.
- `BusActor.setPositions()`, `MotionStudioView.applyPoseToRobot()`, `WalkLabSession.runWalkCycle()`은 관절마다 단일 write를 반복한다.

문제:

- 동작은 “한 시점의 자세”로 설계되지만, 실제 버스에는 joint 1부터 joint 20까지 순차적으로 도착한다.
- action page, walk ready, kick, walk cycle처럼 균형이 중요한 자세에서는 수십 ms 차이도 비틀림으로 느껴질 수 있다.
- 특히 보행/킥은 한쪽 다리 지지 상태가 있으므로 관절 동기화가 품질보다 안전에 가깝다.

수정 제안:

- FFI에 `fc_joint_set_positions_many` 추가
- Swift `Bus.setPositions(_:)`를 실제 Rust `set_positions_many()`에 연결
- Motion Studio, Pose Inspector, Walk Lab, official action playback 모두 batch command를 기본값으로 전환
- moving speed, P gain, torque enable도 가능하면 batch command 정책으로 통일

검증 기준:

- loopback bus test에서 GOAL_POSITION SYNC_WRITE packet이 한 번만 나가는지 확인
- 실기체 테스트 전에는 bus log로 한 step당 write count가 1인지 확인
- step transition jitter를 로그에 남겨 UI에서 볼 수 있게 한다.

### P0-4. WalkLab 프리셋은 공식 보행으로 노출하면 안 됨

현재 코드:

- `app/core/forge-core/src/walk/engine.rs`는 “MVP: 다리 IK는 간단한 mapping. 실 IK는 후속 사이클”이라고 명시한다.
- `WalkMotionLibrary.swift`는 preset별 pose sequence를 손으로 구성한다.
- `WalkLabSession.swift`는 이 sequence를 실제 bus에 보낼 수 있다.

문제:

- 공식 ROBOTIS 보행 모듈은 period time, double support ratio, foot height, pelvis offset, arm swing, balance gain, IMU feedback 등을 포함한다.
- 현재 WalkLab preset은 공식 보행 모듈의 IK/동역학/피드백 경로가 아니다.
- 이 상태에서 “걷기” 버튼처럼 노출하면 사용자는 공식 보행이라고 오해할 수 있고, 실기체가 바닥에서 넘어질 수 있다.

수정 제안:

- WalkLab의 실기체 송출은 당분간 `Experimental / Cradle only`로 잠근다.
- slider 기반 보행은 명확히 `Simulation only`로 표시한다.
- 공식 보행 구현 전까지 실제 로봇 버튼은 `Walk ready`, `official action page`, `single-pose test` 중심으로 제한한다.

검증 기준:

- 크래들 확인, 리스크 확인, 배터리/온도/토크 상태 확인이 없으면 실기체 송출 불가
- WalkLab preset은 기본적으로 motor disabled 또는 torque-off preview만 허용
- 실기체 보행 기능은 공식 IK 또는 official motion page direct playback이 들어온 뒤 별도 베타로 승격

## 5. 우선순위별 업그레이드 백로그

### P0. 모션 데이터 기준 통합

목표: 좌우 반전, 한 칸 밀림, 의도치 않은 클램프를 먼저 제거한다.

작업:

1. `MotionDoc` 31-slot indexing 수정
2. `0x4000` invalid, `0x2000` torque-off flag 처리 보존
3. Swift `JointID.degreeLimits` 재정의
4. official page 9 / ini_pose fixture test 추가
5. 기존 Swift-generated motion 파일이 있다면 old-index migration tool 작성

완료 기준:

- official page 9 walk ready가 Swift, Rust, UI preview에서 같은 joint raw로 보인다.
- 왼쪽 무릎/발목/팔꿈치의 음수 방향 공식 값이 클램프되지 않는다.
- 테스트 이름이 “공식 page ID / joint ID / raw value”를 직접 드러낸다.

### P1. 공식 motion playback 경로 구축

목표: 앱이 “공식 원본 모션”과 “앱이 합성한 모션”을 구분하고, 공식 원본은 byte-exact하게 재생한다.

작업:

1. `motion_4096.bin` parser를 UI 기능에 연결
2. `gui_motion.yaml` 기반 official catalog 구성
3. `OfficialCatalogReference.swift`의 synthesized imitation 성격을 명확히 라벨링하거나 이름 변경
4. action page별 safety class 지정
5. 실행 전 `precheck_motion()` 연결

완료 기준:

- UI에서 “Official raw”, “Synthesized”, “Experimental” badge가 구분된다.
- page 9 Walk ready, page 12 Right Kick, page 13 Left Kick을 공식 raw 기준으로 preview할 수 있다.
- official raw playback은 byte-preserving test가 있다.

### P1. 실기체 송출을 SYNC_WRITE로 통합

목표: 같은 step의 관절 목표값이 한 packet으로 들어가도록 한다.

작업:

1. Rust FFI batch API 추가
2. Swift `Bus.setPositions` 구현
3. Motion Studio / WalkLab / Pose apply 경로 교체
4. bus log에 per-step packet count 기록

완료 기준:

- 한 pose apply에 GOAL_POSITION SYNC_WRITE packet 1개
- 실패 시 어느 joint가 clamp됐는지 UI에서 표시
- 단일 joint slider 조작과 full-pose apply의 UX가 분리된다.

### P2. 공식 보행 모듈 기반으로 WalkLab 재설계

목표: 현재 hand-authored gait을 공식 보행 또는 공식 motion 재생과 분리한다.

작업:

1. ROBOTIS `op2_walking_module`의 파라미터와 단계 구조 분석
2. leg IK / pelvis offset / foot trajectory / double support ratio 구현 또는 포팅
3. IMU feedback 기반 balance gain 연결
4. 8ms control cycle 기준 scheduler 설계
5. WalkLab slider를 공식 parameter와 1:1로 매핑

완료 기준:

- slider 값이 실제 보행 엔진 파라미터로 들어간다.
- 크래들 테스트, 매달림 테스트, 바닥 저속 테스트의 단계별 결과가 저장된다.
- current WalkMotionLibrary는 deprecated 또는 demo-only로 격리된다.

### P2. 3D preview와 실기체 방향 검증

목표: 화면에서 보이는 방향과 실제 모터 방향이 같은지 검증한다.

작업:

1. official page 9, ini_pose, right kick, left kick을 3D pose fixture로 등록
2. 관절별 +10도 command의 화면 방향과 실제 로봇 방향을 캘리브레이션 wizard로 확인
3. `mirrorSignFlip`, rotation axis, left/right geometry transform을 fixture 기반으로 검증

완료 기준:

- UI가 “이 관절 +10도는 실제로 어느 방향인가”를 사용자에게 시각적으로 확인시킨다.
- calibration mismatch가 있으면 실기체 playback을 막는다.

### P3. 문서/테스트/감사 자료 정리

목표: 오래된 감사 문서와 현재 코드 상태가 충돌하지 않게 한다.

작업:

1. 기존 `AUDIT_MOTION_WALK_SYNTH.md`에서 이미 해결된 항목 표시
2. `POSE_SAFETY_NORMALIZATION.md`의 page 9 기준과 `ini_pose.yaml` 기준을 명확히 분리
3. official fixture 생성 명령과 raw decode 결과를 문서화
4. UI copy에서 “공식”, “참고”, “합성”, “실험” 용어를 고정

완료 기준:

- 새 개발자가 어떤 파일을 기준으로 봐야 하는지 헷갈리지 않는다.
- “walk ready”가 action page 9인지 walking module init pose인지 문맥에서 항상 명확하다.

## 6. UI/UX 기획 관점 제안

이 앱은 로봇 제어 앱이라서 일반 생산성 앱보다 “오해 방지”가 훨씬 중요하다. 사용자가 버튼 하나를 누르면 실제 관절과 기체 안정성이 바뀐다. 따라서 UX는 멋진 조작보다 위험한 조작의 의미를 정확히 드러내야 한다.

### 6.1 모션 출처 badge

모든 모션 카드에 출처를 표시한다.

| Badge | 의미 | 예 |
| --- | --- | --- |
| Official raw | ROBOTIS 공식 파일에서 byte-exact 로드 | motion_4096 page 9 |
| Official param | ROBOTIS 공식 walking parameter 기반 생성 | period_time 600ms |
| Synthesized | 앱 내부 알고리즘/템플릿으로 생성 | mirrored kick variant |
| Experimental | 공식 검증 전, 크래들 전용 | WalkLab preset gait |

### 6.2 실기체 실행 전 preflight

실기체 실행 버튼 앞에는 가벼운 체크리스트가 필요하다.

- 연결된 모델: OP2 / MX-28 / Protocol 1.0
- joint ID scan 결과: 1..20 모두 감지
- 배터리/전압/온도 정상
- torque enable 상태
- cradle confirmed
- selected motion safety class
- SYNC_WRITE enabled

### 6.3 관절 방향 캘리브레이션 wizard

사용자가 “반대로 움직인다”고 느끼는 문제를 해결하려면 개발자 로그보다 시각적 캘리브레이션이 좋다.

흐름:

1. 한 관절 선택
2. 앱이 +5도 또는 +10도 미세 명령
3. 사용자가 실제 움직임 방향을 UI 그림과 비교
4. 일치 / 반대 / 움직임 없음 선택
5. mismatch가 있으면 해당 관절의 실기체 playback 차단

### 6.4 Commanded vs Observed trace

Motion Studio와 WalkLab에는 최소한 다음 두 곡선이 필요하다.

- commanded raw position
- observed present position

이 차이가 크면 “모션 알고리즘 문제”가 아니라 “모터 torque/load/speed/통신 문제”일 수 있다. UI에서 이 차이를 보여줘야 원인 추적이 쉬워진다.

## 7. 검증 로드맵

### 단계 1. 파일/데이터 검증

- `motion_4096.bin` page 9 fixture decode
- `ini_pose.yaml` target pose decode
- Swift/Rust joint ID map comparison
- 31-slot roundtrip byte preservation

### 단계 2. 시뮬레이션 검증

- official page 9 preview
- right kick / left kick mirror preview
- joint limit clamp visualization
- self-collision precheck

### 단계 3. 무부하/크래들 검증

- torque off visual command
- single joint +5도 direction test
- walk ready hold
- arms only motion
- legs only slow transition

### 단계 4. 제한적 실기체 검증

- official walk ready
- official getup/kick은 크래들 또는 넓은 안전 공간에서만
- hand-authored WalkLab preset은 공식 IK 전까지 바닥 보행 금지

## 8. 구현 순서 제안

### Sprint A. Canonical Motion Foundation

기간: 2-4일  
핵심 산출물: Swift/Rust/official 데이터가 같은 joint map과 slot map을 쓰도록 고정

작업:

- `MotionDoc` indexing 수정
- `Kinematics` signed limits 수정
- official fixture tests 추가
- old Swift motion migration 여부 조사

### Sprint B. Official Catalog Playback

기간: 3-5일  
핵심 산출물: 공식 motion_4096 action page를 UI에서 정확히 preview/play

작업:

- official catalog loader
- official/synth/experimental badge
- safety precheck 연결
- page 9/12/13 playback smoke test

### Sprint C. Hardware Sync Pipeline

기간: 3-5일  
핵심 산출물: 실기체 pose apply와 motion playback이 SYNC_WRITE 기반으로 동작

작업:

- FFI batch API
- Swift Bus batch API
- UI 송출 경로 교체
- packet count / jitter log

### Sprint D. WalkLab Redesign

기간: 별도 장기 작업  
핵심 산출물: 공식 보행 모듈 또는 공식 모션 재생 기반으로 WalkLab 재설계

작업:

- 현재 preset gait을 experimental로 격리
- official walking module 파라미터 매핑
- IK, balance, IMU feedback 설계
- 단계별 실기체 검증 프로토콜

## 9. 즉시 수정 후보 파일

| 파일 | 우선순위 | 이유 |
| --- | --- | --- |
| `app/ui/DarwinForge/Sources/ForgeCore/MotionDoc.swift` | P0 | 31-slot 인덱스 한 칸 밀림 가능성 |
| `app/ui/DarwinForge/Tests/ForgeCoreTests/MotionDocTests.swift` | P0 | 현재 잘못된 slot 0 테스트가 기준을 고정하고 있음 |
| `app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift` | P0 | 좌우 signed limits가 공식 값과 충돌 |
| `app/ui/DarwinForge/Tests/ForgeCoreTests/KinematicsTests.swift` | P0 | 잘못된 elbow/knee limit 기대값 |
| `app/ui/DarwinForge/Sources/ForgeCore/Bus.swift` | P1 | batch set positions FFI 필요 |
| `app/ui/DarwinForge/Sources/ForgeCore/BusActor.swift` | P1 | 현재 batch처럼 보이지만 내부는 단일 write loop |
| `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionStudioView.swift` | P1 | full pose apply가 관절별 loop |
| `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift` | P1 | walk cycle 실기체 송출이 관절별 loop |
| `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkMotionLibrary.swift` | P1 | official walking이 아닌 experimental gait로 라벨 조정 필요 |
| `app/core/forge-core/src/synth/ops/mutate.rs` | P1 | `AmplitudeScale`에 `joint_id - 1` indexing 잔존 |

## 10. 의사결정 포인트

다음 선택은 기획자가 먼저 방향을 정하면 좋다.

1. **공식 raw 우선 앱으로 갈 것인가, 창작 모션 툴로 갈 것인가**
   - 안정성 우선이면 official raw playback과 검증 UI부터 만든다.
   - 창작 모션 우선이면 calibration, clamp visualization, rollback/safe pose가 먼저 필요하다.

2. **WalkLab을 당장 실기체 기능으로 유지할 것인가**
   - 현재 근거상 바닥 보행 기능으로 유지하는 것은 위험하다.
   - 추천은 `Simulation / Cradle only`로 낮추고, official walking 기반으로 다시 올리는 것이다.

3. **기존 Swift motion 문서 호환을 유지할 것인가**
   - `MotionDoc` indexing을 고치면 과거 Swift-generated 문서가 달라질 수 있다.
   - 따라서 migration marker 또는 version bump가 필요하다.

## 11. 최종 제안

이 프로젝트의 다음 업그레이드는 새로운 모션을 더 만들기보다, 먼저 “기준 좌표계”를 하나로 고정하는 작업이어야 한다. 현재 증상인 관절 뒤틀림과 반대 방향 움직임은 자연스러운 튜닝 문제라기보다, 데이터 slot/index/부호/송출 타이밍이 서로 다른 기준으로 섞여 생기는 구조적 문제일 가능성이 높다.

추천 순서는 다음이다.

1. official page 9 Walk ready를 기준 fixture로 삼는다.
2. Swift `MotionDoc` indexing과 signed limits를 고친다.
3. 실기체 송출을 SYNC_WRITE로 통합한다.
4. official motion catalog를 먼저 안정화한다.
5. WalkLab은 official walking module 기반으로 재설계하기 전까지 experimental/cradle-only로 둔다.

이렇게 하면 사용자는 “내가 누르는 이 동작이 공식 원본인지, 앱이 합성한 것인지, 실험 기능인지”를 분명히 알 수 있고, 개발자는 관절이 이상하게 움직일 때 원인을 데이터 변환, UI limits, 송출 타이밍, 실제 하드웨어 상태 중 어디에서 찾아야 하는지 분리할 수 있다.
