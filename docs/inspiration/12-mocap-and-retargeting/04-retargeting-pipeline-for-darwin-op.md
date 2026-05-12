# DARwIn-OP 모션 리타겟 파이프라인 — SMPL → 20-DOF

> 사람 (SMPL 24 / ARKit 91 / Mixamo 65) 모션을 ROBOTIS DARwIn-OP / OP2
> (20 DOF) 로 옮기는 알고리즘과 도구. 핵심 도전: **관절 수 차이, 본
> 길이 차이, 토크 / 속도 한계, 자기 충돌, 발 접지**. HumanPlus / OmniH2O
> 등 2024년 학술 baseline + 우리 forge-core 신규 모듈 설계.
>
> 작성일: 2026-05-10. 출처 URL 필수.

---

## 1. 문제 정의

### 1.1 SMPL 24-joint 모델 (사람 표준)

SMPL (Skinned Multi-Person Linear, MPI 2015) 은 사람 신체 메시 + 24-joint 골격의 사실상 표준이다.

```
SMPL 24 joints (kinematic tree):
  0  pelvis (root)
  1  left_hip      → 4 left_knee     → 7 left_ankle    → 10 left_foot
  2  right_hip     → 5 right_knee    → 8 right_ankle   → 11 right_foot
  3  spine1        → 6 spine2        → 9 spine3
                                     → 12 neck         → 15 head
                                     → 13 left_collar  → 16 left_shoulder
                                                       → 18 left_elbow
                                                       → 20 left_wrist
                                                       → 22 left_hand
                                     → 14 right_collar → 17 right_shoulder
                                                       → 19 right_elbow
                                                       → 21 right_wrist
                                                       → 23 right_hand
```

(출처: SMPL https://smpl.is.tue.mpg.de/ / Loper et al. SIGGRAPH Asia 2015)

### 1.2 DARwIn-OP 20-DOF

ROBOTIS DARwIn-OP (2010) / OP2 (2014) 의 20개 Dynamixel MX-28 모터:

```
DARwIn-OP 20 joint IDs (forge-core/src/joint/mod.rs 확인):
  ID  1  R_SHOULDER_PITCH
  ID  2  L_SHOULDER_PITCH
  ID  3  R_SHOULDER_ROLL
  ID  4  L_SHOULDER_ROLL
  ID  5  R_ELBOW
  ID  6  L_ELBOW
  ID  7  R_HIP_YAW
  ID  8  L_HIP_YAW
  ID  9  R_HIP_ROLL
  ID 10  L_HIP_ROLL
  ID 11  R_HIP_PITCH
  ID 12  L_HIP_PITCH
  ID 13  R_KNEE
  ID 14  L_KNEE
  ID 15  R_ANKLE_PITCH
  ID 16  L_ANKLE_PITCH
  ID 17  R_ANKLE_ROLL
  ID 18  L_ANKLE_ROLL
  ID 19  HEAD_PAN  (Yaw)
  ID 20  HEAD_TILT (Pitch)
```

(출처: ROBOTIS DARwIn-OP 매뉴얼 https://emanual.robotis.com/docs/en/platform/op/getting_started/ / 본 코드베이스 forge-core/src/joint/mod.rs)

### 1.3 핵심 차이

| 측면 | SMPL (사람) | DARwIn-OP |
|------|-------------|-----------|
| **DOF 합계** | 24 joints × 3 (rotation) = 72 | 20 |
| **손가락** | 22, 23 (1-joint hand) | **없음** |
| **목** | 12 neck (3 DoF) | 19 HEAD_PAN, 20 HEAD_TILT (2 DoF only) |
| **척추** | spine1/2/3 + neck (4 segments × 3) | **없음** (고정 몸통) |
| **어깨** | collar + shoulder (2 segments) | shoulder pitch/roll만 (yaw 없음) |
| **손목** | 20, 21 wrist (3 DoF) | **없음** |
| **발끝** | 10, 11 foot | ankle pitch/roll만 |
| **신장 비례** | 175 cm (성인 평균) | 45.5 cm (DARwIn-OP) — **1/4 스케일** |
| **다리 비례** | 0.50 (전체 대비) | ~0.42 (DARwIn-OP) — 짧음 |

핵심 통찰: 사람의 모션을 DARwIn-OP에 그대로 넣으면 **상체 동작 (척추, 손가락, 손목)** 의 대부분을 버리고, **하체 + 어깨 + 머리** 만 남긴다. 비례 차이는 발 접지 / 무게 중심 보정으로 흡수해야 한다.

---

## 2. 관절 매핑 (1-to-1, drop, fold)

### 2.1 매핑 테이블

| SMPL joint | → | DARwIn-OP joint | 변환 |
|-----------|---|------------------|------|
| 0 pelvis | → | (root, FK origin) | 위치만 사용, 회전은 base orientation |
| 1 left_hip | → | ID 8/10/12 (L_HIP_YAW/ROLL/PITCH) | 3-DoF SMPL → 3 모터 분해 |
| 2 right_hip | → | ID 7/9/11 | 동일 (대칭) |
| 4 left_knee | → | ID 14 (L_KNEE) | pitch만 사용 (knee는 1-DoF) |
| 5 right_knee | → | ID 13 | 동일 |
| 7 left_ankle | → | ID 16/18 (L_ANKLE_PITCH/ROLL) | 3-DoF SMPL → 2 모터 (yaw 버림) |
| 8 right_ankle | → | ID 15/17 | 동일 |
| 10 left_foot | → | (drop) | DARwIn-OP는 발끝 미모델 |
| 11 right_foot | → | (drop) | 동일 |
| 3 spine1 | → | (fold into pelvis) | 척추 회전을 pelvis에 흡수 |
| 6 spine2 | → | (fold into pelvis) | 동일 |
| 9 spine3 | → | (fold into shoulder base) | 어깨 회전에 일부 합산 |
| 12 neck | → | ID 19 HEAD_PAN (yaw만) | pitch는 buffer |
| 15 head | → | ID 20 HEAD_TILT | pitch만 사용 |
| 13 left_collar | → | (fold into shoulder) | |
| 16 left_shoulder | → | ID 2/4 (L_SHOULDER_PITCH/ROLL) | 3-DoF → 2 모터 (yaw 버림) |
| 18 left_elbow | → | ID 6 (L_ELBOW) | pitch만 |
| 20 left_wrist | → | (drop) | |
| 22 left_hand | → | (drop) | |
| (right side 대칭) | → | ID 1, 3, 5 | |

(출처: 본 §2.1 — SMPL https://smpl.is.tue.mpg.de/ + forge-core/src/joint/mod.rs)

### 2.2 회전 분해 알고리즘 (3-DoF → 2/1 DoF)

SMPL은 모든 관절이 axis-angle 또는 quaternion 3-DoF. DARwIn-OP의 1-DoF / 2-DoF 모터로 분해할 때 **순서 의존** intrinsic Euler 분해를 쓴다.

예: SMPL `left_shoulder` quaternion `q` → DARwIn-OP `L_SHOULDER_PITCH` (Y축) + `L_SHOULDER_ROLL` (X축):

```rust
// app/core/forge-core/src/mocap/retarget.rs (제안)
pub fn shoulder_quat_to_pitch_roll(q: UnitQuaternion<f64>) -> (f64, f64) {
    // YXZ Euler intrinsic 분해 (yaw 무시)
    let euler = q.euler_angles();      // (roll=X, pitch=Y, yaw=Z)
    let pitch = euler.1;               // Y axis → SHOULDER_PITCH
    let roll  = euler.0;               // X axis → SHOULDER_ROLL
    (pitch, roll)                       // yaw (Z) 버림
}
```

knee / elbow는 단축 1-DoF이므로 **swing twist 분해** 후 swing의 주성분만 사용.

### 2.3 척추 보존 알고리즘

DARwIn-OP는 척추가 고정된 단일 강체. SMPL의 spine1/2/3 회전을 그대로 버리면 모션이 너무 뻣뻣해진다. 우리 옵션:

1. **무시** (단순) — 사람의 척추 회전을 모두 버림. 인사 모션이 어색.
2. **pelvis fold** — spine 회전을 pelvis (base) 회전에 합산. 전체가 기우는 모션.
3. **shoulder fold** — spine 회전을 어깨 (좌/우) 에 분배. 상체 트위스트 효과.

**권장: 옵션 2 + 3 혼합**. spine1 → pelvis 80%, spine3 → shoulder 20%.

---

## 3. SMPL → DARwIn-OP 비례 (스케일링)

### 3.1 본 길이 차이

| 본 | SMPL (m) | DARwIn-OP (m) | 비율 |
|----|----------|---------------|------|
| 상체 (hip → shoulder) | 0.50 | 0.13 | 0.26 |
| 상박 (shoulder → elbow) | 0.27 | 0.06 | 0.22 |
| 전박 (elbow → hand) | 0.25 | 0.06 | 0.24 |
| 대퇴 (hip → knee) | 0.43 | 0.07 | 0.16 |
| 하퇴 (knee → ankle) | 0.42 | 0.08 | 0.19 |
| 신장 합계 | ~1.75 | ~0.455 | 0.26 |

(출처: SMPL 평균 vs ROBOTIS DARwIn-OP 데이터시트 https://www.robotis.us/darwin-op2/)

핵심: **회전은 그대로 옮길 수 있다**. 본 길이가 비례적으로 줄면 SMPL의 quaternion (회전) 그대로 적용해도 자세는 보존된다 (Forward Kinematics 결과만 1/4 크기). 따라서 스케일링은 **위치 (pelvis root)** 에만 적용:

```rust
darwin_pelvis_pos.y = smpl_pelvis_pos.y * 0.26;  // 신장 비율
darwin_pelvis_pos.x = smpl_pelvis_pos.x * 0.26;  // 측면 보폭
darwin_pelvis_pos.z = smpl_pelvis_pos.z * 0.26;  // 진행 방향
```

### 3.2 비례 불일치 부작용

DARwIn-OP의 다리 비율 (0.42) 이 SMPL (0.50) 보다 **상대적으로 짧다**. 따라서 사람이 "팔 끝과 무릎 끝이 닿는" 동작 (예: 깊은 squat) 은 DARwIn-OP에서 **자기 충돌** 발생 가능. §6에서 충돌 회피.

---

## 4. 발 접지 (Foot Contact) 보정

### 4.1 문제

사람 모션은 사람 골격으로 만들어졌으므로, 발이 바닥에 닿는 위치가 SMPL 좌표에서 정확하다. 그러나:

1. SMPL → DARwIn-OP 스케일 후 root 위치를 그대로 쓰면 **발이 공중에 뜨거나 (float)** 또는 **바닥을 뚫는다 (penetrate)**.
2. SMPL은 발을 단일 본으로 모델 (10/11) 인데 DARwIn-OP는 ankle_pitch/roll까지만 — 발 평면 접지가 다름.

### 4.2 알고리즘 (HumanPlus 식)

HumanPlus (Stanford 2024) 는 사람 모션 → H1 humanoid 리타겟에서 **foot IK + ZMP 보정** 을 단계적으로 한다.

```
Step 1: SMPL 모션 → DARwIn-OP forward kinematics
Step 2: 각 프레임에서 두 발의 ankle 위치 계산
Step 3: 한 발이라도 바닥 (z=0) 보다 아래면 root을 위로 lift, 위면 lower
Step 4: 두 발 동시 접지 시 root을 두 발 중간 z = max(z_left, z_right)
Step 5: 무게 중심 (CoM) 이 support polygon 안에 있는지 검사
Step 6: 안 들면 hip yaw / ankle 미세 조정 (IK)
Step 7: Throughput 100 Hz → DARwIn-OP에 50 Hz 다운샘플
```

(출처: HumanPlus https://humanoid-ai.github.io/ / 논문 https://arxiv.org/abs/2406.10454)

### 4.3 ZMP 검사

ZMP (Zero Moment Point) 는 로봇이 넘어지지 않을 핵심 조건.

```
ZMP가 두 발의 support polygon 안 → 안정
ZMP가 polygon 밖 → 넘어질 위험
```

DARwIn-OP는 발이 작아 (가로 5 cm × 세로 9 cm) ZMP 여유가 매우 좁다. 사람의 빠른 동작은 거의 항상 ZMP 위반 → **속도 / 가속도 클립** 또는 모션 거부 필요.

> ★ 차용 1: forge-core::mocap::zmp 모듈. simulator (Webots / Bullet)
> 와 통합해 매 프레임 ZMP 검사, 위반 시 사용자에 경고 ("이 모션은
> DARwIn-OP가 따라할 수 없어요. 키프레임 35~42에서 넘어집니다").

---

## 5. 자기 충돌 회피 (Self-Collision)

### 5.1 문제

사람 비례에서는 안전한 동작 (예: 양손을 가슴 앞에서 모음) 이 DARwIn-OP의 짧은 팔 + 큰 가슴부 비율에서 **팔이 가슴 안에 들어가는** 자기 충돌을 일으킨다.

### 5.2 알고리즘

```
1. URDF로 DARwIn-OP collision capsule 정의 (각 본을 capsule 또는 cylinder로 근사)
2. 각 retarget 프레임에 대해 모든 본 쌍의 capsule-capsule 거리 검사
3. 거리 < 임계 (예: 5 mm) 면 충돌 감지
4. 충돌 시 두 옵션:
   a. 그 프레임의 관절 각도를 충돌 방향과 반대로 미세 조정 (IK)
   b. 모션 거부 후 사용자에 알림
```

### 5.3 라이브러리 후보

- **collide-rs** (Rust) — Bullet 비슷한 충돌 검사
- **rapier3d** (Rust) — 게임용 fast collision
- **k** (Rust) — kinematics 라이브러리, OpenRR 생태
- **bullet3** (C++ FFI) — 산업 표준

(출처: rapier3d https://rapier.rs/ / k https://github.com/openrr/k)

> ★ 차용 2: forge-core::mocap::collision 모듈, rapier3d 의존성 추가.
> URDF 로더 → collision shape 추출 → frame-by-frame 검사. macOS Apple
> Silicon에서 Rust native 빌드 가능.

---

## 6. 토크 / 속도 한계 (Joint Limits)

### 6.1 DARwIn-OP MX-28 사양

각 관절의 모터 한계 (출처: ROBOTIS MX-28 데이터시트 https://emanual.robotis.com/docs/en/dxl/mx/mx-28/):

| 항목 | 값 |
|------|-----|
| 각도 범위 | 0~360° (절대), but 기구적 제한은 관절별 다름 |
| 최대 속도 | 약 67 RPM = 6.98 rad/s |
| Stall torque | 2.5 Nm @ 12V |
| 분해능 | 0.088° / step (4096 steps / 360°) |

기구적 한계는 forge-core/src/joint/state.rs의 `JointLimits` 에 정의 (확인됨).

### 6.2 클리핑 알고리즘

```rust
// app/core/forge-core/src/mocap/limits.rs (제안)
pub fn clip_motion_to_joint_limits(
    motion: &mut RetargetedMotion,
    limits: &[JointLimits; 20],
) -> Vec<LimitWarning> {
    let mut warnings = Vec::new();
    let dt = 1.0 / motion.fps as f64;

    for frame_idx in 0..motion.frames.len() {
        for (joint_idx, limit) in limits.iter().enumerate() {
            let q = &mut motion.frames[frame_idx].angles[joint_idx];

            // 각도 클립
            if *q < limit.min { *q = limit.min; warnings.push(...); }
            if *q > limit.max { *q = limit.max; warnings.push(...); }

            // 속도 클립 (이전 프레임과 비교)
            if frame_idx > 0 {
                let prev = motion.frames[frame_idx - 1].angles[joint_idx];
                let velocity = (*q - prev) / dt;
                if velocity.abs() > limit.max_velocity {
                    *q = prev + limit.max_velocity.copysign(velocity) * dt;
                    warnings.push(LimitWarning::VelocitySlowed { joint_idx, frame_idx });
                }
            }
        }
    }
    warnings
}
```

### 6.3 시간 재조정 (Retiming)

속도 위반이 잦으면 **모션 전체를 천천히** 하는 게 자연스럽다. SMPL 100 Hz → DARwIn-OP 50 Hz 다운샘플 후 violation 잦으면 1.5x / 2x 늘리기.

---

## 7. HumanPlus / OmniH2O — 학술 baseline 적용

### 7.1 HumanPlus (Stanford 2024)

- 사람 SMPL → Unitree H1 (19 DOF) zero-shot 리타겟
- 핵심: **shadow learning** — 사람과 휴머노이드를 동시에 시뮬, 정책이 사람을 모방
- **HIT (Humanoid Imitation Transformer)** — 이미지 + 동작 → 행동 정책

(출처: HumanPlus https://humanoid-ai.github.io/ / 논문 Cheng et al. 2024 https://arxiv.org/abs/2406.10454)

DarwinForge 적용도 **★★ 학술 baseline**. 우리는 19 DOF H1 → 20 DOF DARwIn-OP 적용 — 비슷한 차원. 그러나 RL 정책 학습 비용 큼. 우선은 알고리즘 일부 (foot IK, ZMP 검사) 만 차용.

### 7.2 OmniH2O (CMU/MIT 2024)

- "Universal" 사람 → 휴머노이드 전이
- VR / RGB / 텍스트 등 다양한 입력 → 휴머노이드
- H1 / G1 / 다른 휴머노이드 transferable

(출처: OmniH2O https://omni.human2humanoid.com/ / 논문 https://arxiv.org/abs/2406.08858)

DarwinForge 적용도 **★★★ 우리 비전과 일치**. 자연어 / 카메라 / 키프레임 모두 입력으로 받는 우리 앱과 발상 동일.

### 7.3 Expressive Whole-Body Control (CMU 2024)

- "Expressive" — 표현형 동작 (인사, 댄스, 손짓) 강조
- whole-body control = 손 + 발 + 머리 동기화

(출처: Expressive Whole-Body Control https://expressive-humanoid.github.io/)

작은 휴머노이드 (DARwIn-OP) 의 데모 / 시연 / 엔터테인먼트 시나리오와 직접 일치.

---

## 8. DeepMimic / AMP — 물리 + RL 모방

### 8.1 DeepMimic (UCB 2018)

Berkeley Peng et al.의 DeepMimic은 **PPO + reference motion** 으로 시뮬 휴머노이드가 사람 모션을 정확히 따라하는 정책 학습.

- 입력: 사람 reference 모션 (BVH / Mocap)
- 학습: PPO, 시뮬레이터 (Bullet / MuJoCo)
- 출력: 정책 (actor network) — torque / target angle

(출처: DeepMimic https://xbpeng.github.io/projects/DeepMimic/)

### 8.2 AMP (Adversarial Motion Priors, UCB 2021)

DeepMimic의 reward를 GAN discriminator로 대체. "이 동작이 사람 같은가?" 를 학습한 discriminator 가 reward.

(출처: AMP https://xbpeng.github.io/projects/AMP/)

### 8.3 PHC (Physical Humanoid Controller, CMU 2023)

Range of physical humanoid trajectories 를 single 정책으로 처리.

(출처: PHC https://research.nvidia.com/labs/dair/phc/)

### 8.4 DarwinForge 적용

**★ 장기 연구 단계**. RL 학습 비용 (수일 ~ 수주, GPU 필요), 시뮬레이터 통합 (Webots / MuJoCo) 등 부담. 우선은 **kinematic retarget** (관절 매핑 + IK + 한계 클립) 으로 80% 사용 케이스 커버. RL은 sim-to-real 정밀도 필요 시 후속.

---

## 9. DarwinForge SwiftUI 워크플로우 (사용자 시나리오)

### 9.1 시나리오 A — "iPhone 시범"

```
[macOS DarwinForge] - "동작 시범 → iPhone 사용" 메뉴
  ↓ Multipeer Connectivity
[iPhone DarwinForge Companion] - ARKit Body Tracking 시작
  ↓ 사용자 10초간 인사 동작
[iPhone] - 91-joint 시계열을 macOS로 60 Hz 스트림
  ↓
[macOS forge-core::mocap::arkit_to_smpl] - 91 → 24 SMPL 매핑
  ↓
[forge-core::mocap::retarget] - SMPL 24 → DARwIn-OP 20
  - 관절 매핑 (§2)
  - 척추 fold (§2.3)
  - 비례 스케일 (§3)
  - 발 IK (§4)
  - 자기 충돌 검사 (§5)
  - 한계 클립 (§6)
  ↓
[Walk Sim 미리보기] - DARwIn-OP 시뮬레이션
  ↓ (사용자 검토, HITL L4)
"저장" → 모션 라이브러리 카드 추가
```

### 9.2 시나리오 B — "Mixamo 다운로드"

```
[Mixamo 웹사이트] - 사용자가 "Wave Hello" 검색, FBX 다운
  ↓
[macOS DarwinForge] - .fbx 파일 drag & drop
  ↓
[forge-core::mocap::fbx_loader] - FBX 파싱, T-pose binding
  ↓
[Mixamo 65-bone → SMPL 24 매핑] - 사전 정의 테이블
  ↓
[retarget] - 동일 §2~§6 파이프라인
  ↓
"Mixamo_Wave_Hello" 카드 추가
```

### 9.3 시나리오 C — "Claude 자연어"

```
사용자 입력: "DARwIn-OP가 손을 흔들면서 인사하면 좋겠어요"
  ↓ Claude tool_use
Claude 호출: search_mixamo_motion("waving hello")
  → 5개 결과 카드
사용자: "두 번째가 좋아요. 조금 더 빠르게요"
Claude 호출: import_and_retarget(id=..., speed=1.3)
  → 미리보기
사용자: "저장"
Claude 호출: save_to_library(name="인사_빠르게")
  → HITL L4 승인 sheet
```

### 9.4 SwiftUI 화면 — `MocapView.swift` (제안)

```swift
public struct MocapView: View {
    @StateObject var session: MocapSession
    var body: some View {
        NavigationSplitView {
            // 사이드바: 입력 소스 선택
            List {
                Section("실시간 캡처") {
                    Label("iPhone (ARKit)", systemImage: "iphone")
                        .badge(session.iPhonePaired ? "연결됨" : "")
                    Label("macOS Vision", systemImage: "camera")
                    Label("Rokoko Suit", systemImage: "figure.walk")
                        .badge(session.rokokoConnected ? "연결됨" : "")
                }
                Section("파일 import") {
                    Label("BVH", systemImage: "doc.text")
                    Label("FBX (Mixamo)", systemImage: "doc.fill")
                    Label("MVNX (Xsens)", systemImage: "doc.badge.gearshape")
                }
                Section("AI 합성") {
                    Label("자연어 (Claude)", systemImage: "bubble.left")
                    Label("MDM (텍스트)", systemImage: "wand.and.stars")
                }
            }
        } detail: {
            // 메인: 라이브 캡처 미리보기 + DARwIn-OP 시뮬 동기화
            HStack {
                CaptureSourceView(source: session.activeSource)
                Divider()
                DarwinOpSimView(motion: session.retargetedMotion)
            }
            .toolbar {
                Button("캡처 시작") { session.startCapture() }
                Button("저장…") { session.saveToLibrary() }
            }
        }
    }
}
```

---

## 10. Rust forge-core::mocap 신규 모듈 — 제안 구조

```
app/core/forge-core/src/mocap/
├── mod.rs                  공개 API + 타입
├── skeleton.rs             SMPL 24 / DARwIn-OP 20 / Mixamo 65 enum
├── frame.rs                MocapFrame { time, joints[], root_pos }
│
├── // 입력 소스
├── arkit.rs                Apple ARKit 91-joint 수신 (Swift FFI 통해)
├── rokoko.rs               Rokoko LiveStream UDP listener
├── natnet.rs               OptiTrack NatNet multicast UDP
├── bvh.rs                  Biovision BVH 파서 / 라이터
├── fbx.rs                  FBX 파서 (mixamo / autodesk)
├── mvnx.rs                 Xsens MVNX XML
│
├── // 변환
├── arkit_to_smpl.rs        91 joints → 24 SMPL
├── mixamo_to_smpl.rs       65 bones → 24 SMPL (사전 매핑 테이블)
│
├── // 리타겟 코어
├── retarget.rs             SMPL → DARwIn-OP 메인 파이프라인
├── joint_mapping.rs        관절 1:1 / fold 매핑 (§2)
├── decompose.rs            quaternion → 1/2-DoF 모터 분해 (§2.2)
├── scale.rs                비례 스케일 (§3)
│
├── // 안전 / 한계
├── limits.rs               각도 / 속도 / 가속도 클립 (§6)
├── collision.rs            rapier3d 자기 충돌 (§5)
├── zmp.rs                  Zero Moment Point 검사 (§4.3)
├── foot_ik.rs              발 접지 IK (§4)
│
└── // 출력
    └── to_motion_page.rs   forge-core::motion::page 로 변환 (.mtn 호환)
```

### 10.1 타입 시그니처 예시

```rust
pub struct SmplFrame {
    pub time:       f64,                    // sec
    pub joints:     [UnitQuaternion<f64>; 24],  // SMPL 표준 순서
    pub root_pos:   Vector3<f64>,
}

pub struct DarwinFrame {
    pub time:       f64,
    pub angles:     [f64; 20],              // joint id 1..=20 (rad)
}

pub struct RetargetReport {
    pub frames_total:        usize,
    pub angle_violations:    Vec<(usize, JointId)>,    // (frame, joint)
    pub velocity_violations: Vec<(usize, JointId)>,
    pub collision_frames:    Vec<usize>,
    pub zmp_unstable_frames: Vec<usize>,
    pub estimated_torque_pk: f64,           // peak Nm
}

pub fn retarget_smpl_to_darwin_op(
    smpl: &[SmplFrame],
    cfg: &RetargetConfig,
) -> Result<(Vec<DarwinFrame>, RetargetReport), MocapError> {
    // §2 ~ §6 파이프라인 통합
    todo!()
}
```

### 10.2 외부 의존성

```toml
# app/core/forge-core/Cargo.toml 에 추가
[dependencies]
nalgebra = "0.33"          # quaternion / Euler
rapier3d = "0.22"          # 충돌 검사 (자기 충돌)
serde = "1"                # ARKit / Rokoko JSON
quick-xml = "0.36"         # MVNX / BVH 일부
tokio = "1"                # UDP listener (Rokoko / NatNet)
```

---

## 11. SwiftUI / Swift 측 노출

```swift
// app/ui/DarwinForge/Sources/ForgeCore/Mocap.swift (신규)
public enum Mocap {
    public static func importBVH(_ path: URL) throws -> MotionAsset { ... }
    public static func importFBX(_ path: URL) throws -> MotionAsset { ... }
    public static func startRokokoListener(port: UInt16 = 14043) -> AsyncStream<MocapFrame> { ... }
    public static func startARKitSession() async throws -> AsyncStream<MocapFrame> { ... }
    public static func retargetToDarwinOp(_ smpl: [SmplFrame],
                                          cfg: RetargetConfig) throws -> (DarwinMotion, RetargetReport) { ... }
}
```

forge-ffi (CForgeCore) 확장 + Swift 래퍼 표준 패턴.

---

## 12. 검증 / 테스트 시나리오

### 12.1 단위 테스트

- `quat_to_euler_yxz_decomposition` — 24개 SMPL → 20 모터 라운드트립 오차 < 0.5°
- `bvh_roundtrip_test` — BVH 파일 import → export → 다시 import, byte-level 동일
- `mixamo_t_pose_alignment` — Mixamo의 T-pose 첫 프레임이 DARwIn-OP의 zero pose와 ±2° 이내

### 12.2 시뮬 통합 테스트 (Webots)

- Mixamo "Wave Hello" → retarget → Webots DARwIn-OP 모델에서 실행
- 1000개 모션 자동 검증: 자기 충돌 / ZMP / 한계 위반 카운트 → 90%+ 정상 가능 동작인지 확인

### 12.3 사용자 인수 (UAT)

- 사용자 A: iPhone 인사 시범 → 라이브러리 저장 → 실 DARwIn-OP에 전송 → 비슷하게 인사하는지 시각 검사
- 사용자 B: Mixamo Wave Hello 검색 → 저장 → 동일 재생

---

## 13. ★ 차용 박스 — 최종 정리

> ★ 차용 1 (★★★ 1순위, 즉시): forge-core::mocap::bvh + ::fbx 표준 import.
> Mixamo 100~200 모션을 사전 retarget해 라이브러리에 포함.
>
> ★ 차용 2 (★★★ 1순위, 1~2주): forge-core::mocap::retarget 메인 모듈.
> 관절 매핑 (§2) + 한계 클립 (§6) 만으로 80% 동작 케이스 커버. 자기 충돌
> / ZMP는 warning만, 다음 분기에 IK 보정.
>
> ★ 차용 3 (★★ 2순위, 2~4주): DarwinForge Companion (iOS) + ARKit Body
> Tracking + Multipeer 페어링. macOS forge-core::mocap::arkit 수신.
>
> ★ 차용 4 (★ 3순위, 장기): MDM / MotionGPT 자연어 → 모션 합성. Claude
> tool_use 노출. RL 기반 DeepMimic / AMP / HumanPlus는 sim-to-real
> 정밀도 요구 시.

---

## 14. 정리 — 우리 우선 작업

`forge-core::mocap` 모듈 신설을 다음 4단계로:

1. **BVH / FBX 파서** — 모든 mocap 도구의 공약수 표준
2. **SMPL → DARwIn-OP 관절 매핑** — §2 알고리즘
3. **한계 클립 + 1차 미리보기** — Walk Sim 통합
4. **자기 충돌 + ZMP + foot IK** — HumanPlus 일부 차용

이 4단계가 끝나면 DarwinForge가:
- Mixamo 다운로드 → drag & drop → DARwIn-OP 모션 추가
- iPhone 카메라 → 사용자 시범 → DARwIn-OP 모션 추가
- Claude "인사 동작 만들어줘" → 라이브러리 검색 → 추천 → 저장

세 시나리오를 동시에 지원. 이는 NAO Choregraphe의 Pose Capture, Spot Choreographer의 Choreography library, MotionBuilder의 retarget을 한 화면에 통합하는 셈. DarwinForge의 차별화 가치.

(출처: 본 §14 결론 — 본인 작성, 인용은 §1~§13 출처 참조)

---

## 부록 A — 표준 포맷 (BVH / FBX / glTF / USD / C3D / AMC+ASF) 요약

### A.1 BVH (Biovision Hierarchy, 1990s) ★

ASCII 텍스트 포맷. 두 섹션:

```
HIERARCHY                         <- 골격 (offsets, channels)
ROOT Hips
{
  OFFSET 0.0 0.0 0.0
  CHANNELS 6 Xposition Yposition Zposition Zrotation Yrotation Xrotation
  JOINT LeftUpLeg
  { ... }
}
MOTION                            <- 시계열
Frames: 240
Frame Time: 0.0333333
0 92 0 -3.41 0.49 0 -178.06 ...    <- 240줄
```

(출처: Wisconsin BVH 사양 https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html)

DarwinForge: **표준 import 1순위**. forge-core::mocap::bvh 모듈로 처리.

### A.2 FBX (Autodesk, 1996~)

바이너리 / ASCII 양쪽. Mixamo / 게임 엔진 / 영화 산업 표준. Autodesk SDK 무료지만 license는 자체 진입 장벽.

오픈소스 파서: **ufbx** (Rust 가능, MIT) — https://github.com/ufbx/ufbx

DarwinForge: **Mixamo 호환을 위해 필요**.

### A.3 glTF + animations

Khronos 표준, 웹 친화 (JSON + binary buffer). Animation 채널이 keyframed sampler로 정의. DarwinForge: 미래 웹 export 용.

(출처: glTF https://www.khronos.org/gltf/)

### A.4 USD (Pixar / NVIDIA)

Universal Scene Description. NVIDIA Isaac Sim 통합 시 필수. DarwinForge: **장기, sim-to-real 단계에서 도입**.

(출처: USD https://openusd.org/)

### A.5 C3D (Vicon, 1980s)

마커 시계열 (3D position + analog), 의생체역학 표준. Vicon / OptiTrack / Qualisys 모두 지원. 스켈레톤이 아니라 **마커 위치만**, 솔브는 별도. DarwinForge: 직접 의미 약함.

(출처: C3D format https://www.c3d.org/)

### A.6 AMC + ASF (CMU)

Acclaim 게임 회사 포맷. CMU Mocap DB 기본 형식. ASF (skeleton) + AMC (motion). DarwinForge: CMU DB 사용 시.

(출처: CMU Mocap https://mocap.cs.cmu.edu/)

---

## 부록 B — 학술 인용 BibTeX (요약)

```bibtex
@inproceedings{Tevet2023MDM,
  title={Human Motion Diffusion Model},
  author={Tevet, Guy and Raab, Sigal and Gordon, Brian and Shafir, Yonatan and Bermano, Amit H. and Cohen-Or, Daniel},
  booktitle={ICLR},
  year={2023},
  url={https://guytevet.github.io/mdm-page/}
}

@article{Cheng2024HumanPlus,
  title={HumanPlus: Humanoid Shadowing and Imitation from Humans},
  author={Cheng, Zipeng and others},
  journal={arXiv:2406.10454},
  year={2024},
  url={https://humanoid-ai.github.io/}
}

@article{HeOmniH2O2024,
  title={OmniH2O: Universal and Dexterous Human-to-Humanoid Whole-Body Teleoperation and Learning},
  author={He, Tairan and others},
  journal={arXiv:2406.08858},
  year={2024},
  url={https://omni.human2humanoid.com/}
}

@article{Loper2015SMPL,
  title={SMPL: A Skinned Multi-Person Linear Model},
  author={Loper, Matthew and Mahmood, Naureen and Romero, Javier and Pons-Moll, Gerard and Black, Michael J.},
  journal={ACM Trans. Graphics (SIGGRAPH Asia)},
  year={2015},
  url={https://smpl.is.tue.mpg.de/}
}

@inproceedings{Peng2018DeepMimic,
  title={DeepMimic: Example-Guided Deep Reinforcement Learning of Physics-Based Character Skills},
  author={Peng, Xue Bin and Abbeel, Pieter and Levine, Sergey and van de Panne, Michiel},
  booktitle={SIGGRAPH},
  year={2018},
  url={https://xbpeng.github.io/projects/DeepMimic/}
}
```

(출처: 각 논문의 공식 페이지 / arXiv)

---

본 문서는 DarwinForge가 모션 캡처 → 휴머노이드 리타겟의 본격 도입을 위해 **즉시 시작 가능한 4단계 작업 (BVH/FBX → 매핑 → 클립 → IK)** 을 정리했다. 다음 카테고리 [13-llm-datasets](../13-llm-datasets/) 또는 [16-ar-xr-robotics](../16-ar-xr-robotics/) 와 자연스럽게 연결됨.
