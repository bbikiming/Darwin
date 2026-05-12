# research/community/INDEX.md

> 커뮤니티 DARwIn-OP / OP2 자료 카탈로그. 우선순위는 우리 OP1/OP2 코어에서 알고리즘·페이지
> 인용 가치 기준. 적용 등급: ★★★ 직접 코드 참조 / ★★ 알고리즘·아키텍처 참조 / ★ 메타정보·비교.
>
> 갱신: 2026-05-12.

## 우선순위 1 — OP1 정본 reference

### `darwinop-ens-darwin-op` ★★★

| 분야 | 등급 | 위치 | 비고 |
|------|-----:|------|------|
| Walking ZMP 알고리즘 | ★★★ | `Framework/src/motion/modules/Walking.cpp` | Sprint 5 walk-engine 직역 베이스 |
| Action 파일 포맷 | ★★★ | `Framework/include/Action.h` | `docs/motion-format/page-format.md` ground truth |
| Kinematics | ★★★ | `Framework/include/Kinematics.h` | OP1 링크 길이·DH |
| CM-730 Protocol 1.0 | ★★★ | `Framework/hardware/CM730.{h,cpp}` | Sprint 1 Rust 포팅 |
| Joint ID 매핑 | ★★★ | `Framework/include/JointData.h` | 런타임 vendored 헤더 |
| action_editor UX | ★★★ | `Linux/project/action_editor/` | Sprint 4 SwiftUI 매핑 |
| walk_tuner UX | ★★★ | `Linux/project/walk_tuner/` | Sprint 5 파라미터 튜닝 UI |
| OP1 stock motion 카탈로그 | ★★★ | `Data/motion_4096.bin` | 45 명명 페이지 (스톡 정본) |
| 페이지 12 (rk) / 13 (lk) | ★★★ | `Data/motion_4096.bin` | Sprint 9~13 좌우 미러 reference |

## 우선순위 2 — 보행·낙상 보호 알고리즘

### `nimbro-op` ★★★ (알고리즘 인용)

| 분야 | 등급 | 위치 | 비고 |
|------|-----:|------|------|
| Walking 튜닝 (smooth start, spline pitch balance) | ★★★ | `patches-essential/0012-Walking-tuned-for-NimbRo-OP.patch` | 알고리즘만 인용, 파라미터는 OP1/OP2 재튜닝 |
| Fall protection | ★★★ | `patches-essential/0016-Fall-protection-implementation.patch` | IMU 임계값 → fall-recovery 페이지 자동 호출 |
| AngleEstimator (complementary filter) | ★★★ | `patches-essential/0010-Simple-angle-estimator.patch` | 자이로 + 가속도 융합 — forge-core IMU 1차 reference |
| MotionManager torque mask | ★★★ | `patches-essential/0007-MotionManager-torque-management.patch` | 페이지 단위 dynamic torque ON/OFF API |
| LinuxMotionTimer jitter 축소 | ★★ | `patches-essential/0009-LinuxMotionTimer-improved-performance.patch` | macOS 측은 다른 OS 추상 사용 |
| ActionEditor 미러 페이지 자동 생성 | ★★★ | `patches-optional/0024-…apply-mirrored-pages.patch` | Sprint 9~13 `synth mirror` prior art |
| UDP state publisher | ★★ | `patches-optional/0018-…UDP-state-publisher.patch` | Sprint 11 텔레메트리 패킷 포맷 |
| TeenSize CAD | ★ | `hardware/CAD/{IGS,STEP} 3D/` | CC BY-NC-SA, 우리 코어 임베드 X |

## 우선순위 3 — 모션 편집기·인터랙티브 패턴

### `_gpl-isolated/HROS5-Framework` ★★ (GPL 격리 — 알고리즘·메타데이터만)

| 분야 | 등급 | 위치 | 비고 |
|------|-----:|------|------|
| `rme` (개선된 Action Editor) | ★★ | `Linux/project/rme/cmd_process.cpp` | 개별 limb torque toggle UX — clean-room 재구현 |
| PS3 컨트롤러 → 페이지 dispatch | ★★ | `Linux/project/ps3_demo/` | Sprint 11 원격 제어 UX |
| `exit=1` 안전 복귀 패턴 | ★★ | `Data/motion_4096.bin` | 인터랙티브 페이지 안전 종료 관습 |
| 의미화 리네이밍 (`motion_dest.bin`) | ★★ | `Data/motion_dest.bin` | 라이브러리 페이지 이름 가이드 |
| Arbotix-Pro 컨트롤러 | — | `Framework/src/controller/` | 우리 CM-730/740 와 호환 X |

## 우선순위 4 — OP2 라이브 모션 카탈로그

### `robot_personal_assistant_op2` ★★ (코드 보류, 페이지 인용 OK)

| 분야 | 등급 | 위치 | 비고 |
|------|-----:|------|------|
| Ergonomic 페이지 100~108 | ★★★ | `motion_4096.bin` | 책상 작업자 케어 시나리오 직접 적용 |
| 인사 페이지 250~255 | ★★★ | `motion_4096.bin` | `init_pose` 베이스 + 인사 set 패턴 |
| `pain_handler.py` RL 매핑 | ★★ | `scripts/main/pain_handler.py` | 음성 명령 → 모션 페이지 dispatch 디자인 |
| ROS 분산 토폴로지 (PC ↔ Darwin) | ★ | `launch/robot.launch`, `launch/laptop.launch` | 우리 USB 직결 모델과 다름. 토픽 이름만 참고 |
| Project Documentation PDF | ★★ | `Project Documentation.pdf` | 설계 의도·RL 보상 함수 |

## 미수집 (BLOCKER 후보 아님)

| 후보 | 이유 | 우선순위 |
|------|------|----------|
| `darwinop-ens/simulink` | Matlab Simulink 연동, Phase 2 운동학 검증 시 필요 시 추가 클론 | 낮음 |
| `darwinop-ens/kinematics` | 운동학·동역학 모델, 위와 동일 | 낮음 |
| RoboCup 팀 코드 (Hambot, UPennalizers 등) | 이미 `research/INDEX.md` 에 메타만 등재 | 낮음 |
| ROBOTIS OP/OP2 Recovery Image | 전체 OS 이미지 — Phase 1 스코프 외 | 낮음 |

## 인용 시 첨부 필수 (라이선스별)

| 라이선스 | 인용 시 필요한 것 |
|----------|-------------------|
| Apache 2.0 (`darwinop-ens`) | 헤더의 ROBOTIS 저작권 라인 보존 |
| BSD-3 (`nimbro-op` 소프트웨어) | LICENSE 의 저작권·면책 조항 `vendor/LICENSES.md` 에 반영 |
| GPL v3 (`_gpl-isolated/HROS5-Framework`) | **코드 인용 금지.** 알고리즘 설명만, "이 패턴은 HROS5 에서 영감을 받음" 명시 |
| CC BY-NC-SA 3.0 (`nimbro-op` CAD) | 비상업 + ShareAlike — 우리 코어 임베드 X |
| TODO (`robot_personal_assistant_op2`) | **코드 임포트 보류.** 페이지 메타데이터 (사실) + README/PDF 인용만 OK |
