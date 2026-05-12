# PyBullet — 가벼운 빠른 프로토타입

## 한 줄 소개

Bullet Physics 위 Python wrapper. Erwin Coumans(전 Sony, 현 Google) 개발.
가볍고 빠르며 학습 곡선이 낮다.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | Zlib (Bullet) / MIT (pybullet) |
| 플랫폼 | Linux / macOS / Windows |
| 강점 | 즉시 시작, URDF 직접 로드, Gym 환경 다수 |
| 약점 | contact dynamics가 PhysX/MuJoCo보다 거침 |

## 왜 언급하는가

- DARwIn-OP RL 초기 실험에서 가장 진입 장벽이 낮음.
- `pybullet_envs`에 휴머노이드(NAO 류) 환경 다수 — 패턴 차용.

## DarwinForge 적용 우선순위

★ — 4순위. MuJoCo/Brax로 더 빠른 학습 가능. PyBullet은 "오늘 5분 안에 띄
워보자"의 도구.

## 출처

- PyBullet: https://pybullet.org/
- GitHub: https://github.com/bulletphysics/bullet3
- pybullet_envs: https://github.com/bulletphysics/bullet3/tree/master/examples/pybullet/gym
