# 17. 프로토콜 / 표준 — 미들웨어 + 산업 통합

> ROS2, DDS, OPC UA 등 산업 미들웨어. DarwinForge는 현재 ROS 비의존
> 단독 앱이지만, 향후 ROS2 통합 / 산업 환경 배치 / 다중 로봇 동시 제어
> 시 결정적 표준.

## 인덱스

| 표준 | 영역 | DarwinForge 가능성 |
|------|------|---------------------|
| [ROS2](ros2.md) | 로봇 미들웨어 | ★★ — ROBOTIS-OP2 ROS 패키지 활용 |
| [DDS](dds.md) | 데이터 분산 (ROS2 기반) | ★ — 실시간 통신 |
| [micro-ROS](micro-ros.md) | MCU용 ROS2 | ★ — CM-730 펌웨어가 micro-ROS화 가능? |
| [OPC UA](opc-ua.md) | 산업 자동화 표준 | ★ — 공장 통합 |
| [Foxglove WebSocket](foxglove.md) | bag 시각화 | ★★ — 트레이스 시각화 |
| [USD](usd.md) | 3D 씬 표준 | ★★ — 멀티 도구 호환 |
| [glTF / FBX](mesh-formats.md) | 메시 포맷 | ★ — DARwIn-OP 시각화 |
| [MQTT](mqtt.md) | IoT pubsub | ★ — 다중 로봇 lightweight |

## DarwinForge — 현재 / 미래

### 현재 (ROS-free)
- forge-core가 직접 USB 시리얼로 CM-730 통신
- Mac 앱이 단독 실행
- 외부 통합 X

### 미래 (선택적 통합 시)
- **forge-mcp** (이미 05에서 제안) — MCP 서버 expose → 다른 에이전트 호출
- **ROS2 bridge** — `forge-core::ros2_bridge` 옵션 crate
- **Foxglove WebSocket** — 트레이스를 외부 도구로 시각화

## ROS2 통합 검토

ROS2 (Humble / Iron / Jazzy) 위에 DarwinForge가 publish하는 것:
- `/darwin/joint_states` — 16개 관절 + IMU 1Hz
- `/darwin/board_state` — 보드 모델 / 전압 / 버튼

ROS2를 받는 것:
- `/darwin/cmd_vel` — geometry_msgs/Twist → walk 명령
- `/darwin/joint_trajectory` — trajectory_msgs/JointTrajectory → 모션 재생

이 매핑은 ROBOTIS-OP2 패키지 (`ROBOTIS-GIT/ROBOTIS-OP2`)가 이미 구현. 우리는
같은 토픽 이름 사용 시 호환.

→ Sprint 12+ 후보 — 현재 우선순위 낮음.

## 안전 / 산업 표준 (10번 카테고리와 중복 제외)

- ISO 23482 (사회적 로봇 안전) — 일본 주도, 2020 발효
- ISO 22166 (모듈러 로봇)
- IEC 61508 (functional safety)

## 출처

- ROS2: https://docs.ros.org/en/jazzy/
- DDS: https://www.dds-foundation.org/
- micro-ROS: https://micro.ros.org/
- OPC UA: https://opcfoundation.org/
- Foxglove: https://foxglove.dev/
- USD: https://openusd.org/
- ROBOTIS-OP2 ROS package: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2
