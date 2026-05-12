# 휴머노이드 워킹 (Locomotion) 핵심 자료

## ZMP 기반 (전통)

- Vukobratović 1969 — ZMP 개념 도입
- Kajita et al. 2003 — Linear Inverted Pendulum Model (LIPM)
- Park & Park 2002 — DARwIn-OP의 op2_walking_module 핵심 알고리즘 출처
- Kajita 2014 책 — 표준 교과서

## MPC (Model Predictive Control)

- Wieber 2006 — Convex MPC for ZMP
- Faraji 2017 — 3LP 모델

## RL 기반 (2020~)

- Yu et al. 2018 — Sim-to-Real with deep RL
- Siekmann et al. 2021 — Cassie 워크 RL
- Radosavovic et al. 2024 — Berkeley humanoid RL (위 recent-2024-2026.md)

## DARwIn-OP 특화

- ROBOTIS-OP2 op2_walking_module의 algorithm + parameters는
  Park&Park 2002에 가까움.
- Webots DARwIn-OP 컨트롤러도 같은 구조.

## DarwinForge 적용 매핑

forge-core::walk::engine의 sin파 발 궤적은 LIPM의 매우 단순화된 버전.
실 IK 추가 시 (Sprint 5 후속):
- Closed-form IK for 6-DOF leg (Kajita 2014, Ch. 3) 직접 구현
- 또는 Drake `InverseKinematics` 호출

## 출처

자세한 인용은 [`BIBLIOGRAPHY.bib`](BIBLIOGRAPHY.bib).
