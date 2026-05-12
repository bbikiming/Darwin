# Sprint 5 — Walk Engine MVP

## 요약

`forge-core::walk` 모듈 (params, engine, IMU complementary filter) + `forge walk` 시뮬레이션 CLI. 59 tests pass. 실 IK·실기기 검증은 후속 / Mac 측.

## 핵심 산출물

### 신규 모듈

- `forge-core/src/walk/params.rs` — `WalkParams`. **`op2_walking_module/config/param.yaml` 1:1 복사** (period_time=600 ms, dsp_ratio=0.1, foot_height=0.04 m, balance gains 4종, P=32 등). `phase1/2/3_end_ms()` 헬퍼 + JSON serde.
- `forge-core/src/walk/imu.rs` — `ComplementaryFilter` (gyro_weight 기본 0.98) + `ImuSample`. atan2 기반 가속도 → roll/pitch 추정 + 자이로 적분. 정지 상태 100 step 후 roll/pitch < 0.01 rad 검증.
- `forge-core/src/walk/engine.rs` — `WalkEngine`:
  - `WalkCommand` (x/y/a amplitude + enabled)
  - `WalkPhase` enum (Phase0/1/2/3)
  - `tick(dt)` — period_time wrap 포함
  - `phase()` — 현재 phase
  - `foot_targets()` — sin파 기반 좌·우 발 (x, y, z) 골반 좌표계
  - 비활성 시 정지 자세 (좌·우 y_offset 부호만 다름)

### CLI

```sh
forge walk --x 0.04 --cycles 1
```

출력 예 (실 컨테이너 실행):
```
== walk 시뮬레이션 (실기기 명령 안 보냄) ==
  command: x=0.04 y=0 a=0 (m/cycle, rad/cycle)
  period: 600 ms, cycles: 1
  tick   phase    left(x,y,z)            right(x,y,z)
     0  Phase1  (+0.030 +0.005 +0.020)  (-0.050 -0.005 -0.020)
     2  Phase1  (-0.030 +0.005 -0.020)  (+0.010 -0.005 -0.000)
     4  Phase3  (-0.030 +0.005 -0.020)  (+0.010 -0.005 +0.000)
     ...
```

### 검증

| 항목 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ |
| `cargo test --workspace` | ✅ **59 / 59 PASS** (Sprint 4 50 + Sprint 5 +9) |
| `cargo clippy -- -D warnings` | ✅ |
| `cargo fmt --check` | ✅ |
| `forge walk` 시뮬레이션 | ✅ |

신규 테스트 9개:
- params: 3 (default = param.yaml, phase endpoint 순서, JSON round-trip)
- imu: 2 (정지 시 수렴, 자이로 적분 응답)
- engine: 4 (idle = Phase0, enabled phase 진행, period wrap, foot height ≤ param max)

## 자기검증 결과

- [x] WalkParams 기본값이 ROBOTIS-OP2 param.yaml과 일치
- [x] phase 4단계 진행 (Phase0/1/2/3) + period_time wrap
- [x] foot_targets()가 비활성 시 정지 자세 + 활성 시 sin파
- [x] IMU 정지 100 step → roll/pitch ~0
- [x] complementary filter 자이로-only 모드에서 정확한 적분

## 한계 (MVP)

- 실 IK 미구현 — foot_targets은 골반 좌표계 위치만 반환. JointController로 각도 변환은 Mac 측 후속에서 (실제로는 6-DOF leg IK가 필요).
- IMU 닫힌 루프 미연결 — engine이 ComplementaryFilter 결과를 받아 게인 적용하는 부분은 미구현.
- 실기기 walk 실행 미검증 — `forge walk` CLI는 시뮬레이션만, `--port` 인자 없음. Mac에서 SyncWriteEntry 변환 후 실 모터 명령 발행은 후속 사이클.
- 팔 swing arm_swing_gain 적용 미구현.

## Blockers

없음.

## 다음 단계

**Sprint 6 — Vision & Strategy MVP** 즉시 자율 시작:
- `forge-core/src/vision/mod.rs` — 이미지 추상화 (`Frame`, `Pixel`, color spaces)
- `forge-core/src/vision/segmentation.rs` — HSV 색 segmentation (공·골 후보)
- `forge-core/src/strategy/mod.rs` — FSM (LookForBall → ApproachBall → Kick)
- `forge strategy run --port` — 단발 사이클 시뮬레이션
- 단위 테스트
