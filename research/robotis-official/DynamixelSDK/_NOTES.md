# DynamixelSDK — _NOTES.md

- 출처: https://github.com/ROBOTIS-GIT/DynamixelSDK
- 라이선스: Apache 2.0
- 클론 시점: 2026-05-09, tag 4.0.5 (`2ded684`)
- 우리 코어 적용: ★★★ (Sprint 1의 Rust 포팅 1차 참고)

## 우리에게 유용한 것

- `c++/include/dynamixel_sdk/` — Protocol 1.0 / 2.0 패킷 빌더·파서의 정식 C++ 구현. 우리 Rust 포팅의 **참조 진리**.
- `python/src/dynamixel_sdk/` — 같은 알고리즘의 Python 버전. 코드가 짧아 알고리즘 이해 용이.
- `c++/example/protocol1.0/` — 모터 ping, sync read/write의 사용 예제. Sprint 1 CLI 동작 검증용.
- `control_table/` — MX-28T·XL-320·XM-430 등 모터별 컨트롤 테이블 PDF/페이지. Phase 2 명세 작성 시 출처.

## 우리가 무시하는 것

- `c#/`, `java/`, `labview/`, `matlab/`, `ros/` — 우리 스택 무관.
- `documents/` (Doxygen 출력) — 온라인 문서로 대체 가능.

## Mac 측 사용

DynamixelSDK는 Mac C++ 빌드 가능. 우리는 직접 임포트하지 않고 Rust 포팅. 단, Sprint 1 검증 단계에서 사용자 Mac에 SDK를 빌드해 두면 우리 forge-cli 출력과 dispense하게 비교 가능.
