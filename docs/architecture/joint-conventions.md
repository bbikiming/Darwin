# Joint Conventions — DARwIn-OP / OP2 관절 규약

> 20개 Dynamixel MX-28T 서보의 ID, 이름, 좌표계, 회전 방향 약속.
> 1차 출처: `Framework/include/JointData.h` (darwinop-ens 미러).

## ID 매핑

| ID | 심볼 | 부위 | 축 | 비고 |
|----|------|------|----|------|
| 1 | R_SHOULDER_PITCH | 우측 어깨 | pitch | + = 앞으로 들기 |
| 2 | L_SHOULDER_PITCH | 좌측 어깨 | pitch | + = 앞으로 들기 |
| 3 | R_SHOULDER_ROLL | 우측 어깨 | roll | + = 옆으로 벌리기 |
| 4 | L_SHOULDER_ROLL | 좌측 어깨 | roll | + = 옆으로 벌리기 |
| 5 | R_ELBOW | 우측 팔꿈치 | pitch | + = 굽히기 |
| 6 | L_ELBOW | 좌측 팔꿈치 | pitch | + = 굽히기 |
| 11 | R_HIP_YAW | 우측 고관절 | yaw | + = 안쪽으로 회전 |
| 12 | L_HIP_YAW | 좌측 고관절 | yaw | + = 안쪽으로 회전 |
| 13 | R_HIP_ROLL | 우측 고관절 | roll | + = 다리 벌리기 |
| 14 | L_HIP_ROLL | 좌측 고관절 | roll | + = 다리 벌리기 |
| 15 | R_HIP_PITCH | 우측 고관절 | pitch | + = 다리 들기 |
| 16 | L_HIP_PITCH | 좌측 고관절 | pitch | + = 다리 들기 |
| 17 | R_KNEE | 우측 무릎 | pitch | + = 굽히기 |
| 18 | L_KNEE | 좌측 무릎 | pitch | + = 굽히기 |
| 19 | HEAD_PAN | 목 | yaw | + = 좌측 회전 |
| 20 | HEAD_TILT | 목 | pitch | + = 위로 들기 |

> 7~10은 사용 안 함 (구버전 ID 흔적). 일부 community 문서가 7/8을 alt hip-yaw로 표기하는데 우리는 11/12 표준만 사용.

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
| SHOULDER_PITCH | -180° | +180° | 모터 전체 범위 (충돌 위험은 별도 검사) |
| SHOULDER_ROLL | -90° | +90° | 어깨-몸통 간섭 회피 |
| ELBOW | 0° | +150° | 자기 충돌 회피 |
| HIP_YAW | -90° | +90° | |
| HIP_ROLL | -45° | +45° | 다리 분리 |
| HIP_PITCH | -90° | +60° | |
| KNEE | 0° | +150° | |
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

- `Framework/include/JointData.h` (`darwinop-ens/darwin-op` mirror)
- `research/robotis-official/ROBOTIS-OP2/op2_kinematics_dynamics/`
- ROBOTIS e-Manual MX-28T 컨트롤 테이블
