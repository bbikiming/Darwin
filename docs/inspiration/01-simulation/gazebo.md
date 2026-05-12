# Gazebo Classic / Gazebo Sim (Ignition) — ROS 표준 시뮬

## 한 줄 소개

ROS 1/2 생태계의 사실상 표준 시뮬레이터. Open Robotics(현 Open Source
Robotics Foundation, OSRF)에서 개발.

## 핵심 정보

| 항목 | Gazebo Classic 11 | Gazebo (Ignition) 신규 |
|------|---|---|
| 라이선스 | Apache 2.0 | Apache 2.0 |
| 플랫폼 | Linux 권장 / macOS 일부 | 동일 |
| 물리 엔진 | ODE / Bullet / Simbody / DART | DART, Bullet (default) |
| ROS 통합 | `gazebo_ros_pkgs` | `ros_gz_bridge` |
| 종료 시점 | EOL 2025-01 | 후속 |

## 왜 우리에게 덜 중요한가

- **macOS 지원이 약함** — DarwinForge가 macOS-only인데 Gazebo는 Linux
  중심.
- **ROS 의존 의도가 강함** — DarwinForge는 ROS를 안 씀.
- **Webots / MuJoCo가 같은 일을 macOS에서 더 깔끔히 처리.**

## ROBOTIS-OP2 / OP3 측면에서

- `robotis_op2_gazebo` (`ROBOTIS-GIT/ROBOTIS-OP2-Common`) 패키지가 존재
  (research/SURVEY.md 인덱스 #2 참조). Linux + ROS Noetic 환경에서 동작.
- 이 패키지를 직접 차용하기보다 **URDF만 추출해서 MuJoCo/Webots로
  이식**하는 것이 macOS 친화적.

## 차용 우선순위

★ — 4순위. 우리 사용자가 Linux + ROS 머신을 따로 운영하면 도움. macOS-only
에서는 우선순위 낮음.

## 출처

- Gazebo: https://gazebosim.org/
- ROS Gazebo bridge: https://github.com/gazebosim/ros_gz
- ROBOTIS-OP2-Common: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2-Common
- Open Robotics: https://www.openrobotics.org/
