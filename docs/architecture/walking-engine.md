# Walking Engine — DARwIn-OP / OP2 워킹 엔진 명세

> Sprint 5 `forge-core::walk` Rust 포팅의 명세. 1차 출처는
> `research/robotis-official/ROBOTIS-OP2/op2_walking_module/`.
>
> 알고리즘 출처: Ha et al. (RoMeLa) ZMP 기반 워킹.

## 알고리즘 개요

DARwIn-OP의 워킹은 **고정 주기 + ZMP 보정** 기반의 **closed-form** 워킹 패턴 생성기:

1. 보행 주기(period_time) 동안 좌우 발의 X·Y·Z 궤적을 사인파 합으로 생성
2. 골반(pelvis) 오프셋 + 팔 스윙으로 무게중심 보상
3. 역기구학으로 20관절 (사실상 다리 12관절) 목표 위치 계산
4. IMU 피드백으로 hip-roll / knee / ankle gain을 실시간 조정 (균형 보정)

이는 LIPM(linear inverted pendulum) MPC 같은 동적 워킹은 아니나, DARwIn-OP의 작은 풋프린트와 안정적 무게 분포에 잘 맞는다.

## 파라미터 (업스트림 `op2_walking_module/config/param.yaml` 직접 발췌)

```yaml
x_offset:                 -0.010   # m, 전후 오프셋
y_offset:                 0.005    # m, 좌우 오프셋
z_offset:                 0.020    # m, 직립 시 발 들기
roll_offset:              0        # rad
pitch_offset:             0        # rad
yaw_offset:               0        # rad
hip_pitch_offset:         13       # deg, 정적 자세 보정
period_time:              600      # ms, 한 보행 사이클
dsp_ratio:                0.1      # double-support phase 비율 (0..1)
step_forward_back_ratio:  0.28
foot_height:              0.04     # m, 발 들리는 최대 높이
swing_right_left:         0.020    # m, 좌우 발 흔들림
swing_top_down:           0.005    # m, 상하 본체 흔들림
pelvis_offset:            3.0      # deg, 골반 보정각
arm_swing_gain:           1.5      # 팔이 다리에 비례 흔들리는 게인
balance_hip_roll_gain:    0.5      # IMU roll → hip 보정
balance_knee_gain:        0.3      # IMU pitch → knee 보정
balance_ankle_roll_gain:  1.0
balance_ankle_pitch_gain: 0.9
p_gain:                   32       # MX-28 P gain 직접 설정
i_gain:                   0
d_gain:                   0
```

## 단계 (Phase) 모델 (업스트림 `op2_walking_parameter.h`에서 직접)

```
PHASE0 = 0
PHASE1 = 1   # 첫 발 떼기
PHASE2 = 2   # 양 발 지지
PHASE3 = 3   # 다음 발 떼기
```

각 phase의 시간 분할:
- `phase1_time = ssp_ratio * period_time / 2`
- `phase2_time = phase1_time + dsp_ratio * period_time`
- `phase3_time = phase2_time + ssp_ratio * period_time / 2`

`ssp_ratio = 1 - dsp_ratio`.

## 입력 명령

워크 엔진은 4개의 명령 변수를 받는다:

| 변수 | 단위 | 의미 |
|------|------|------|
| `x_move_amplitude` | m | 보행 주기당 전후 이동 거리 |
| `y_move_amplitude` | m | 보행 주기당 좌우 이동 거리 |
| `a_move_amplitude` | rad | 보행 주기당 회전각 |
| `enable` | bool | 워킹 on/off |

소스: `op2_walking_module.cpp` (Sprint 5에서 line-by-line 인용 후 Rust 포팅).

## 역기구학

DARwIn-OP의 다리는 6-DOF (yaw → roll → pitch → knee → pitch → roll). 발 위치 + 발 자세에서 6개 관절각을 closed-form으로 푸는 IK가 framework에 포함됨. 우리는 그것을 Rust로 포팅:
- 입력: 골반 좌표계에서 발 위치 (x, y, z) + 발 자세 (roll, pitch, yaw)
- 출력: 6개 관절 라디안

## IMU 피드백 루프

```
loop every 8 ms:
  read CM_730 GYRO + ACCEL (BULK_READ)
  estimate body roll/pitch
  walk_engine.update_balance(roll, pitch)  // hip_roll/knee/ankle gain 적용
  for joint in 20:
    target[joint] = walk_engine.next(joint)
  SYNC_WRITE goal_positions to all 20 servos
```

## Sprint 5 구현 계획

1. **수동 자세 모드** — 모든 파라미터를 받아 한 사이클의 20관절 시퀀스를 생성. IMU 무관, 단위 테스트 가능.
2. **균형 보정 모드** — IMU 입력을 받아 게인을 적용. 시뮬레이터(가짜 IMU 데이터)로 단위 테스트.
3. **실기기 검증** — 사용자 Mac에서 사용자 OP2와 함께 walking 명령 발행, 안정성 관찰. (BLOCKER 가능성: 컨테이너에서 검증 불가)

## 출처

- `research/robotis-official/ROBOTIS-OP2/op2_walking_module/` (Apache 2.0)
- Ha et al. 2011 "Development of Open Humanoid Platform DARwIn-OP" (`research/papers/REFERENCES.bib`)
- ROBOTIS Framework `motion::Walking` (darwinop-ens 미러)

## 라이선스 노트

ROBOTIS-OP2의 `op2_walking_module`은 Apache 2.0. **알고리즘과 파라미터는 자유롭게 차용 가능, 단 cargo 메타데이터에 출처 표기**.
