# Drake (TRI) — 학술적 엄밀성 + 컨트롤 시스템

## 한 줄 소개

MIT Russ Tedrake 그룹 출발, 현재 Toyota Research Institute(TRI) 주도.
강건한 contact 해석 + convex 최적화 기반 컨트롤(LQR, MPC, TAMP)에 강점.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | BSD-3-Clause |
| 플랫폼 | Linux / macOS (Apple Silicon 지원) ★ |
| 언어 | C++ / Python (pydrake) |
| 강점 | 미분가능 계약 솔버, MPC, IK 솔버, TAMP |
| 약점 | 빠른 RL에는 부적합 (정확성 우선) |

## 우리에게 의미

- **macOS 네이티브** — DarwinForge가 Drake를 임베디드할 수 있는 후보.
- **IK 솔버** — Sprint 5 walk loop 본격 활성화 시 Drake의 다목적 IK
  (`InverseKinematics`)를 forge-core::walk::ik 모듈에서 호출 가능.
- **Russ Tedrake "Underactuated Robotics" 강의** — 워킹 알고리즘 학술
  자료의 표준.

## DARwIn-OP 적용 가능성

```
forge-core::walk
  ├── engine.rs           # phase + sin파 (현재)
  ├── ik.rs (신규)        # Drake IK 호출 — 다리 6-DOF 역기구학
  └── mpc.rs (신규)       # Drake MPC — ZMP 추적
```

Drake의 Python API는 무겁지만, C++ API로 정적 링크 가능. 단, forge-core가
이미 Rust인 점을 고려하면 **`pydrake` subprocess** 또는 **`drake-rs`(미존재)**
중 전자가 빠른 길.

## 차용 우선순위

★★ — Walk loop 본 활성화 후 IK 보강 시 1순위 후보. 일반 시뮬은 MuJoCo가
더 빠름.

## 출처

- 공식 사이트: https://drake.mit.edu/
- GitHub: https://github.com/RobotLocomotion/drake
- Underactuated Robotics 강의: https://underactuated.csail.mit.edu/
- pydrake 문서: https://drake.mit.edu/pydrake/index.html
