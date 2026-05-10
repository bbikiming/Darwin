# ROS2 — Robot Operating System 2

## 한 줄 소개

ROS1의 후속. DDS 기반 분산 통신, 실시간 보장, 보안 (DDS-Security). 휴머노이드
표준 미들웨어.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | Apache 2.0 |
| 플랫폼 | Linux / macOS / Windows |
| 최신 LTS | Jazzy Jalisco (2024-05 ~ 2029) |
| 통신 | DDS (Data Distribution Service) |
| 언어 | C++ / Python / Rust(unofficial r2r, ros2-rust) |

## DARwIn-OP / OP2 ROS 호환

- **`ROBOTIS-GIT/ROBOTIS-OP2`** — ROS1 패키지. ROS2 미공식 포팅 (확인 필요).
- **HumaRobotics/darwin_description** — URDF (BSD-2). ROS1/2 공통.

## DarwinForge 통합 검토

### 옵션 A — ROS2 노드로 통째 변환 (큰 변화)

DarwinForge.app 자체를 ROS2 노드로. macOS에서도 ROS2 Jazzy 동작 가능.

장점: 산업 표준 호환, 다른 ROS2 노드와 즉시 연동.
단점: ROS2 의존성 + 큰 binary, 비전문가 사용자에게 복잡도 ↑.

### 옵션 B — 별도 forge-ros2-bridge crate (권장)

```
app/core/
├── forge-core/        (기존)
├── forge-ffi/         (기존)
├── forge-cli/         (기존)
└── forge-ros2-bridge/ (신규 옵션)
    └── src/
        ├── lib.rs
        └── topics.rs   # /darwin/joint_states 등 publish/subscribe
```

`forge-ros2-bridge`는 별도 crate로, ros2-rust (`r2r`) 사용. DarwinForge 본
앱은 의존하지 않음. 사용자가 원하면 `cargo run -p forge-ros2-bridge`로
별도 프로세스 실행.

### 권장 토픽 매핑

```
/darwin/joint_states          (sensor_msgs/JointState, 50 Hz)
/darwin/board_state           (custom msg or diagnostic_msgs)
/darwin/imu                   (sensor_msgs/Imu)
/darwin/foot_contact          (custom msg, FSR 있을 때)
/darwin/cmd_vel               (geometry_msgs/Twist) ← Walk 명령
/darwin/joint_command         (trajectory_msgs/JointTrajectory)
/darwin/emergency_stop        (std_msgs/Trigger)
```

## 차용 우선순위

★ — 5순위. 현재 DarwinForge가 ROS-free로 더 깔끔. ROS2 통합은 산업 환경
배치 시점 (Sprint 12+) 고려.

## 출처

- ROS2 Jazzy: https://docs.ros.org/en/jazzy/
- ros2-rust: https://github.com/ros2-rust/ros2_rust
- r2r crate: https://github.com/sequenceplanner/r2r
- ROBOTIS-OP2 ROS: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2
- HumaRobotics URDF: https://github.com/HumaRobotics/darwin_description
