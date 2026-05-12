# 01. 로봇 시뮬레이션 환경

> 실 로봇 없이 모션·워킹·비전 알고리즘을 검증하기 위한 시뮬레이터들.
> DARwIn-OP / OP2 모델이 이미 존재하는 곳을 ★로 표기.

## 인덱스

| 도구 | 라이선스 | DARwIn-OP 모델 | 학습/RL 친화 | 우리 차용 우선순위 |
|------|----------|:---------------:|:------------:|--------------------|
| [Webots](webots.md) (Cyberbotics) | Apache 2.0 | ★★★ 빌트인 | ⚠️ 제한적 | **1순위** — 모션 검증 |
| [Gazebo Classic / Sim](gazebo.md) | Apache 2.0 | ★★ 커뮤니티 URDF | ⚠️ ROS 의존 | 2순위 |
| [NVIDIA Isaac Sim + Lab](isaac-sim.md) | 무료 (라이선스 별도) | ❌ 직접 import 필요 | ★★★ 최강 | 3순위 — 실험 |
| [MuJoCo](mujoco.md) (DeepMind) | Apache 2.0 (2021~) | ❌ MJCF 변환 필요 | ★★★ 강 | 3순위 |
| [Drake](drake.md) (TRI) | BSD-3 | ❌ | ★★ | 4순위 — 학습용 |
| [PyBullet](pybullet.md) | Zlib | ❌ | ★★ | 4순위 |
| [Genesis](genesis.md) (CMU 2024) | Apache 2.0 | ❌ | ★★★ 새로움 | 4순위 — 평가 단계 |

## DarwinForge 적용 전략

### Phase A — Webots 기반 sim-to-real (가장 현실적)

Webots는 **DARwIn-OP를 빌트인 모델로 가지고 있고**, 컨트롤러 코드를 sim과 실
기기 양쪽에 동일하게 컴파일할 수 있다. 우리 forge-core(Rust)가 stdin/stdout으로
sim과 통신하는 controller 모드를 지원하면, 동일 로직으로:

- ✅ 실기기 없이 모션 검증
- ✅ Walk loop 디버깅 (Sprint 5 IK 보강 시)
- ✅ Strategy FSM 시뮬레이션 (Sprint 6)

→ [`webots.md`](webots.md) 참조.

### Phase B — Isaac Lab으로 RL 실험 (Walk 재학습)

DARwIn-OP의 stock walk 알고리즘은 ROBOTIS-OP2/op2_walking_module
(Apache 2.0)을 그대로 가져온 것. 향후 RL로 walk gait를 fine-tune하고 싶다면
Isaac Lab + Isaac Sim 조합이 표준. URDF는
[`HumaRobotics/darwin_description`](https://github.com/HumaRobotics/darwin_description)
(BSD-2-Clause) 활용 가능.

→ [`isaac-sim.md`](isaac-sim.md) 참조.

### Phase C — MuJoCo + Brax (학습 가속)

Google DeepMind의 MuJoCo는 미분가능 시뮬레이션과 GPU 가속(Brax)을 지원해
RL 실험에서 Isaac Sim보다 가벼움. URDF → MJCF 변환만 하면 된다.

→ [`mujoco.md`](mujoco.md) 참조.

## 시뮬-실기 차이 (sim-to-real gap)

| 영역 | 시뮬 | 실기 |
|------|------|------|
| 모터 응답 | 즉시 (stiff PD) | 1~5 ms latency, MX-28 P-gain 32 기준 noticeable error |
| 관성 / 마찰 | 단순 모델 | 신발 고무 ~ 카펫 차이 큼 |
| 배터리 sag | 없음 | LiPo cell당 3.7 V 미만에서 토크 격감 |
| IMU 노이즈 | 0 또는 가우시안 | gyro drift 0.5°/min, 가속도 진동 |
| 통신 jitter | 0 | FTDI latency timer + USB hub 영향 |

DarwinForge가 sim-to-real 격차를 줄이려면:
- 시뮬 측에 **모터 응답 지연 + battery sag** 모델 주입
- 실기 측에 **IMU complementary filter** (이미 forge-core::walk::imu에 구현)
- **Domain randomization** — Isaac Lab의 표준 패턴 차용

## 다음 단계 후보

- [ ] Webots controller stub 작성 — `app/core/forge-sim/` Rust crate
- [ ] HumaRobotics URDF → MJCF 변환 스크립트
- [ ] Isaac Lab walk RL 환경 (`darwinforge_env.py`)

## 출처

- [Cyberbotics Webots](https://cyberbotics.com/)
- [NVIDIA Isaac Lab](https://isaac-sim.github.io/IsaacLab/)
- [MuJoCo / DeepMind](https://mujoco.org/)
- [Drake / Toyota Research Institute](https://drake.mit.edu/)
- [PyBullet](https://pybullet.org/)
- [Genesis](https://github.com/Genesis-Embodied-AI/Genesis)
