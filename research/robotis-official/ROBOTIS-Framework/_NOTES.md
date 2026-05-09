# ROBOTIS-Framework — _NOTES.md

- 출처: https://github.com/ROBOTIS-GIT/ROBOTIS-Framework
- 라이선스: Apache 2.0
- 클론 시점: 2026-05-09
- 우리 코어 적용: ★★ (Phase 4 모듈 경계, Sprint 5 워크 엔진 포팅 시 1차 참고)

## 패키지 구성

- `robotis_framework_common` — 공통 타입, 매크로
- `robotis_device` — 장치 추상화 (모터, 컨트롤러)
- `robotis_controller` — 실시간 컨트롤 루프 (MotionManager 패턴)
- `robotis_framework` — 메타 패키지

## 우리에게 유용한 것

- 컨트롤 루프의 **시간 제약 패턴** (8 ms tick, sync read/write 사이클): Sprint 5 walk engine에 이식.
- `MotionModule` 추상 클래스 → `MotionManager`가 등록·실행하는 패턴 → Rust trait + scheduler로 직역.

## 우리가 무시하는 것

- ROS1 의존성 — 우리 앱은 ROS 비사용. 패키지 메타데이터(`package.xml`, `CMakeLists.txt`)는 무시.
