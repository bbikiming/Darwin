# ROBOTIS-OP2 — _NOTES.md

- 출처: https://github.com/ROBOTIS-GIT/ROBOTIS-OP2
- 라이선스: Apache 2.0
- 클론 시점: 2026-05-09
- 우리 코어 적용: ★★ (CM-740 module + walking module이 OP2 워킹의 정식 구현)

## 패키지

- `cm_740_module` — CM-740 컨트롤러와 직렬 통신 + IMU/voltage/button/LED 드라이버. Sprint 1 검증 진리.
- `op2_walking_module` — OP2 워킹 알고리즘 ROS 노드. Sprint 5 포팅 1차 참고.
- `op2_kinematics_dynamics` — 역기구학·관성 매개변수.
- `op2_manager` — 라이프사이클 매니저.
- `op2_gui_demo` — Qt GUI 데모 (구식, 참고 X).
- `robotis_op2` — 메타 패키지.

## 우리에게 유용한 것

- `cm_740_module/src/` — CM-740 특정 시퀀스(부팅 시 sub-controller power up, IMU calibration)의 정확한 순서.
- `op2_walking_module/src/` — Phase 2 walking-engine.md + Sprint 5 forge-core::walk 작성 시 line-by-line 참조.

## 주의

- 마지막 의미 있는 commit이 오래 전 — 유지보수 거의 정지. 알고리즘은 안정적이지만 새 모터/카메라 지원은 없음.
