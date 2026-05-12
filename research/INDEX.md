# research/INDEX.md

> Phase 1 시드 소스 카탈로그. 컬럼: 출처 · 라이선스 · 핵심 모듈 · 적용 등급.
> 적용 등급: ★★★ 직접 코드 참조 / ★★ 알고리즘·아키텍처 참조 / ★ 메타정보·비교 용도.
>
> 최종 갱신: 2026-05-09 (Phase 1)

## ROBOTIS 공식 / 준공식

| # | 출처 | 라이선스 | 핵심 모듈 | 적용 |
|---|------|----------|-----------|------|
| 1 | [ROBOTIS-GIT/DynamixelSDK](https://github.com/ROBOTIS-GIT/DynamixelSDK) (tag 4.0.5, `2ded684`) — **클론 보존** `robotis-official/DynamixelSDK/` | Apache 2.0 | Protocol 1.0/2.0 패킷 빌더·파서 (C/C++/Python/etc) | ★★★ |
| 2 | [ROBOTIS-GIT/ROBOTIS-Framework](https://github.com/ROBOTIS-GIT/ROBOTIS-Framework) — **클론 보존** | Apache 2.0 | `robotis_controller`, `robotis_device`, `robotis_framework_common` (실시간 컨트롤 루프) | ★★ |
| 3 | [ROBOTIS-GIT/ROBOTIS-OP2](https://github.com/ROBOTIS-GIT/ROBOTIS-OP2) — **클론 보존** | Apache 2.0 | `cm_740_module`, `op2_walking_module`, `op2_kinematics_dynamics`, `op2_manager` | ★★ |
| 4 | [ROBOTIS-GIT/ROBOTIS-OP-Series-Data](https://github.com/ROBOTIS-GIT/ROBOTIS-OP-Series-Data) — **클론 보존 (OP/OP2 부분만)** | © ROBOTIS | Wiring Manual, Fabrication Manual, Assembly Manual, CM-730 control table PDFs | ★★★ |
| 5 | [ROBOTIS-GIT/ROBOTIS-Math](https://github.com/ROBOTIS-GIT/ROBOTIS-Math) (HEAD `190657d`) | Apache 2.0 | 행렬·벡터·쿼터니언 유틸 | ★ (자체 구현으로 대체) |
| 6 | [ROBOTIS-GIT/ROBOTIS-OP3](https://github.com/ROBOTIS-GIT/ROBOTIS-OP3) (HEAD `3bc2bd5`) | Apache 2.0 | OP3 진화형 (Protocol 2.0, XM-430) | ★ (참고만, 우리 스코프 외) |
| 7 | [ROBOTIS-GIT/ROBOTIS-OP3-Common](https://github.com/ROBOTIS-GIT/ROBOTIS-OP3-Common) (HEAD `0780e54`) | Apache 2.0 | URDF/메쉬 (OP3) | ★ (참고) |
| 8 | [ROBOTIS-GIT/dynamixel-workbench](https://github.com/ROBOTIS-GIT/dynamixel-workbench) (HEAD `55b000a`) | Apache 2.0 | 모터 ID 변경·점검·시각화 ROS 도구 | ★ (Mac에선 우리 자체 GUI로 대체) |
| 9 | [ROBOTIS-GIT/darwin (ROS)](https://github.com/ROBOTIS-GIT/darwin) | (저장소 미확인 — Phase 1 ls-remote 실패) | ROS 패키지 (있다면) | _ (BLOCKER 후보, 우선순위 낮음) |
| 10 | [emanual.robotis.com](https://emanual.robotis.com/docs/en/platform/op/getting_started/) | © ROBOTIS, 인용 가능 | OP/OP2/CM-730/MX-28 e-Manual | ★★★ (Phase 2 명세 출처) |

## 1세대 (DARwIn-OP / OP1) 커뮤니티 미러

| # | 출처 | 라이선스 | 핵심 모듈 | 적용 |
|---|------|----------|-----------|------|
| 11 | [darwinop-ens/darwin-op](https://github.com/darwinop-ens/darwin-op) | Apache 2.0 (upstream) | SourceForge 1세대 framework의 GitHub 미러 — 가장 깔끔 | ★★★ (Phase 2 walking·motion 분석 출처) |
| 12 | [Interbotix/HROS5-Framework](https://github.com/Interbotix/HROS5-Framework) (HEAD `a0640f1`, **archived 2021**) | **GPL v3** | DARwIn-OP framework의 HR-OS5 파생 | ★ (참고만, **GPL 격리** — 우리 코어 임베드 금지) |
| 13 | [HumaRobotics/darwin_description](https://github.com/HumaRobotics/darwin_description) (HEAD `2a0c4eb`) | BSD-2-Clause | URDF + 메시 (3D 시각화용) | ★★ (Sprint 4+ 3D pose preview) |
| 14 | [SourceForge: darwinop](https://sourceforge.net/projects/darwinop/) | Apache 2.0 | 오리지널 DARwIn-OP framework 소스 | ★★ (`darwinop-ens` 미러로 대체) |

## 커뮤니티 / 시뮬레이터 / RoboCup 팀

| # | 출처 | 라이선스 | 핵심 모듈 | 적용 |
|---|------|----------|-----------|------|
| 15 | [cyberbotics/webots](https://github.com/cyberbotics/webots) (HEAD `3d7ebe8`) | Apache 2.0 | DARwIn-OP 빌트인 모델, cross-compile to robot | ★★ (Sprint 5/6 시뮬레이션) |
| 16 | [cyberbotics/webots_ros2](https://github.com/cyberbotics/webots_ros2) (HEAD `a5a9c3f`) | Apache 2.0 | Webots ↔ ROS2 브릿지 | ★ (참고) |
| 17 | [bit-bots/hambot](https://github.com/bit-bots/hambot) (HEAD `579557d`) | (RoboCup, 저장소별 상이) | RoboCup 팀 Hamburg Bit-Bots 변형 하드웨어 | ★ (커뮤니티 정보) |
| 18 | [UPenn-RoboCup/UPennalizers](https://github.com/UPenn-RoboCup/UPennalizers) (HEAD `9d312ee`) | (확인 필요) | RoboCup Istanbul 2011 우승팀 코드 (Lua + C, 모션·비전·행동) | ★ (전략 영감) |
| 19 | NimbRo (papers 위주, github 산재) | (논문별 상이) | Humanoid League | ★ |
| 20 | DASL UNLV wiki — [Making the DARwIn-OP walk](https://www.daslhub.org/unlv/wiki/doku.php?id=making_the_darwin-op_walk) | © DASL | 실용 워킹 가이드 | ★ |
| 21 | NUbots OP2 Restoration Guide — [nubook](https://nubook.nubots.net/guides/hardware/darwin-op2-guide/) | (커뮤니티) | OP2 복원 실전 노하우 | ★★ (Phase 3 BOM 검증) |
| 22 | Seed Robotics — [DARwIn-OP framework KB](https://kb.seedrobotics.com/doku.php?id=dh4d:darwinopframework) | © Seed Robotics | 하네스/펌웨어 팁 | ★ |

## 학술 (자세한 인용은 `papers/REFERENCES.bib`)

| # | 출처 | 비고 |
|---|------|------|
| 23 | Ha et al. "Development of Open Humanoid Platform DARwIn-OP", SICE 2011 | OP1 발표 논문 |
| 24 | McGill et al. "Development of an Open Humanoid Robot Platform for Research and Autonomous Soccer Playing" | UPenn 팀 |
| 25 | Hong et al. "DARwIn's Evolution" | OP1 → OP2 전환기 |
| 26 | Hambot 논문 (Springer) | RoboCup 변형 |

## 라이선스 비호환 격리

- #12 **HROS5-Framework**: GPL v3 — 우리 Apache 2.0 코어에 임베드 금지. 알고리즘 참고만 가능, 코드 복사 금지.

## 미해결

- #9 ROBOTIS-GIT/darwin: ls-remote 실패. 저장소가 옮겨졌거나 비공개 가능. 실용 영향 낮음 (#3 ROBOTIS-OP2가 ROS 측 진리). BLOCKER 등급 아님.
