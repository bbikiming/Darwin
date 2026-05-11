# Joint Conventions — DARwIn-OP / OP2 관절 규약

> 20개 Dynamixel MX-28T 서보의 ID, 이름, 좌표계, 회전 방향 약속.
> 1차 출처: ROBOTIS 공식 [`ROBOTIS-OP2/op2_manager/config/OP2.robot`](../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/OP2.robot) (Apache 2.0).
> DARwIn-OP 1세대(CM-730)와 2세대(CM-740, =ROBOTIS-OP2) 모두 **동일한 매핑**.

## ID 매핑 (공식)

| ID | 심볼 | 라벨 (`OP2.robot`) | 부위 | 축 |
|----|------|-------------------|------|----|
| 1 | R_SHOULDER_PITCH | `r_sho_pitch` | 우측 어깨 | pitch |
| 2 | L_SHOULDER_PITCH | `l_sho_pitch` | 좌측 어깨 | pitch |
| 3 | R_SHOULDER_ROLL | `r_sho_roll` | 우측 어깨 | roll |
| 4 | L_SHOULDER_ROLL | `l_sho_roll` | 좌측 어깨 | roll |
| 5 | R_ELBOW | `r_el` | 우측 팔꿈치 | pitch |
| 6 | L_ELBOW | `l_el` | 좌측 팔꿈치 | pitch |
| 7 | R_HIP_YAW | `r_hip_yaw` | 우측 고관절 | yaw |
| 8 | L_HIP_YAW | `l_hip_yaw` | 좌측 고관절 | yaw |
| 9 | R_HIP_ROLL | `r_hip_roll` | 우측 고관절 | roll |
| 10 | L_HIP_ROLL | `l_hip_roll` | 좌측 고관절 | roll |
| 11 | R_HIP_PITCH | `r_hip_pitch` | 우측 고관절 | pitch |
| 12 | L_HIP_PITCH | `l_hip_pitch` | 좌측 고관절 | pitch |
| 13 | R_KNEE | `r_knee` | 우측 무릎 | pitch |
| 14 | L_KNEE | `l_knee` | 좌측 무릎 | pitch |
| 15 | R_ANK_PITCH | `r_ank_pitch` | 우측 발목 | pitch |
| 16 | L_ANK_PITCH | `l_ank_pitch` | 좌측 발목 | pitch |
| 17 | R_ANK_ROLL | `r_ank_roll` | 우측 발목 | roll |
| 18 | L_ANK_ROLL | `l_ank_roll` | 좌측 발목 | roll |
| 19 | HEAD_PAN | `head_pan` | 목 | yaw |
| 20 | HEAD_TILT | `head_tilt` | 목 | pitch |

부호 약속(좌표계): +X 정면, +Y 좌측, +Z 위. 좌·우 관절은 부호 반전 — 예: walkReady의 `r_hip_pitch=-65°`, `l_hip_pitch=+65°`.

## Legacy OP1 매핑 (fallback)

일부 OP1 firmware 분기에서 다리를 ID 11~18로 재배치한 흔적이 있다(공식과 충돌). DarwinForge `forge_core::joint::JointMap::LegacyOp1` 는 다음과 같이 fallback:

- 어깨/팔꿈치/머리: 공식과 동일.
- 다리: 11..=18 (hip yaw/roll/pitch + knee 순서). **발목 ID는 사용자가 마법사에서 지정** — 미정의 시 발목 명령 미발행 + 경고.

연결 시 `controller::cm::detect_joint_map` 가 PING ID 1..=20 sweep으로 자동 선택. 7..=10 응답 = `Official`, 7..=10 무응답 + 11..=18 응답 = `LegacyOp1`.

특수 ID:
- **200** = CM-730 / CM-740 sub-controller
- **254** = 브로드캐스트 (응답 없음)
- **111** = 우측 발 FSR
- **112** = 좌측 발 FSR

## 좌표계

DARwIn-OP world frame:
- **X**: 정면 방향 (앞 +)
- **Y**: 좌측 방향 (좌 +)
- **Z**: 위 방향 (위 +)

오일러 각: ZYX (yaw → pitch → roll), 라디안.

## Position 단위

MX-28T는 **0..4095** (12-bit) 위치 레지스터. 0 = -180°, 2048 = 0°, 4095 = +180° (단, 모터별 angle limit이 별도 설정됨).

```
position_radians = (raw - 2048) * (π / 2048)
position_degrees = (raw - 2048) * (180 / 2048)
```

## 안전 한계

| 관절 | 최소 | 최대 | 출처 |
|------|------|------|------|
| SHOULDER_PITCH | -180° | +180° | 모터 전체 범위 (충돌 검사는 별도) |
| SHOULDER_ROLL | -90° | +90° | 어깨-몸통 간섭 회피 |
| ELBOW | -150° | +150° | 좌·우 부호 반대 (walkReady r=30°, l=-30°) |
| HIP_YAW | -90° | +90° | |
| HIP_ROLL | -45° | +45° | 다리 분리 |
| HIP_PITCH | -90° | +90° | walkReady ±65° 수용 |
| KNEE | -150° | +150° | walkReady ±130° 수용, 좌·우 부호 반전 |
| ANK_PITCH | -90° | +90° | walkReady ±70° 수용 |
| ANK_ROLL | -45° | +45° | |
| HEAD_PAN | -90° | +90° | |
| HEAD_TILT | -45° | +45° | 카메라 시야 |

> 위 표는 보수적 기본값. 실제 모터 EEPROM의 CW/CCW Angle Limit과 비교해 더 작은 쪽 채택. forge-core가 Sprint 2에서 첫 연결 시 모터의 angle limit을 읽고 클램프 한계로 등록.

## Compliance / PID

기본 P-gain = 32 (Walking 기본값). 정적 자세 유지가 필요한 페이지는 P=8~16으로 낮춰 충격 흡수. Action 페이지의 `compliance[20]`이 0..7 슬라이더로 P-gain을 매핑한다.

| compliance | P-gain (대략) |
|------------|---------------|
| 0 | 8 |
| 1 | 16 |
| 5 | 64 (기본) |
| 7 | 254 (강성 최대) |

## OP1 ↔ OP2 차이

ID 매핑·좌표계·각도 방향 모두 **동일**. Joint convention만큼은 1.0/2.0 모두 통일된 것이 ROBOTIS framework의 강점.

## 출처

- ROBOTIS 공식 [`ROBOTIS-OP2/op2_manager/config/OP2.robot`](../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/OP2.robot)
- ROBOTIS 공식 [`ROBOTIS-OP2/op2_kinematics_dynamics/`](../../research/robotis-official/ROBOTIS-OP2/op2_kinematics_dynamics/)
- ROBOTIS 공식 [`ROBOTIS-OP2/op2_manager/config/ini_pose.yaml`](../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml) (walkReady target_pose)
- ROBOTIS e-Manual MX-28T 컨트롤 테이블
