# app/walk-engine/

DARwIn-OP 워킹 엔진. ZMP 기반 워킹 패턴 생성, 역기구학, 발 궤적.

Phase 5 Sprint 5에서 Rust 크레이트로 구현 (`forge-core::walk`).

## 책임

- 보폭·발높이·횡진·앞뒤 오프셋 등 파라미터를 받아 20관절 시퀀스 생성
- IMU 피드백을 받아 자세 보정
- 직진·회전·정지 명령 인터페이스

## 참고 알고리즘

- Ha et al. ZMP 기반 워킹 (Phase 1에서 수집)
- ROBOTIS Framework `motion::Walking` (Apache 2.0)
- UPenn UPennalizers 워크
