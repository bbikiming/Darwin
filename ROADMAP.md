# ROADMAP

> 전체 일정 — Phase 0..5 + Sprint 1..6.
> 각 항목은 **자율 실행** (사용자가 한 번 승인했음).
> BLOCKER 발생 시에만 사용자 개입 요청.

## Phase 0 — Bootstrap

- 워크스페이스 디렉토리 트리 강제 (§2)
- 도구 점검 (`bootstrap-tools.sh`), Mac 드라이버 점검 스크립트
- `PROGRESS.md` / `ROADMAP.md` / `BLOCKERS.md` / `vendor/LICENSES.md` 생성
- 기존 자산 git mv로 이력 보존 흡수
- `LICENSE`: Apache 2.0 (확정)

## Phase 1 — Discovery & Archive

- 시드 소스 (§5.1) 전수 조사
  - ROBOTIS 공식: ROBOTIS-OP2, ROBOTIS-Framework, ROBOTIS-Math, ROBOTIS-OP3, DynamixelSDK, dynamixel-workbench, ROBOTIS-OP3-Common, e-Manual
  - 1세대: thor-mang/darwin-op, UPenn RoboCanes, sourceforge darwin-op, HumaRobotics
  - 커뮤니티: Webots, Gazebo/ROS2, RoboCup 팀(NimbRo, Hamburg Bit-Bots, Team DARwIn)
  - 학술: Ha et al. ZMP, IEEE/Springer 논문
- 각 저장소 `_NOTES.md`, `vendor/LICENSES.md` 누적
- 산출물: `research/INDEX.md`, `research/papers/REFERENCES.bib`, `research/EXTERNAL_LINKS.md`, `docs/reports/PHASE_1_REPORT.md`

## Phase 2 — Knowledge Synthesis

- `docs/protocols/dynamixel-1.0.md` (보강)
- `docs/protocols/dynamixel-2.0.md` (신규)
- `docs/protocols/cm-730-740.md` (신규)
- `docs/motion-format/mtn-format.md`, `page-format.md` (신규)
- `docs/architecture/walking-engine.md`, `joint-conventions.md`, `sensor-stack.md` (신규)
- `docs/architecture/op1-vs-op2-matrix.md` (보강)

## Phase 3 — Harness Engineering

- `harness/op1/BOM.md`, `harness/op2/BOM.md`
- `harness/shared/cable-specs.md`, `mac-driver-setup.md`, `wiring-diagram.{svg,mmd}`, `safety.md`
- `scripts/harness/probe.sh`
- ADR-006 (통신 경로), ADR-007 (전원), ADR-008 (e-stop)

## Phase 4 — App Architecture

- ADR-009 (Rust + SwiftUI 이원화 채택), ADR-010 (모듈 경계), ADR-011 (직렬 추상화), ADR-012 (영속성/SQLite), ADR-013 (테스트 전략)
- `app/core/forge-core/` Rust 워크스페이스 초기화 + `cargo build` 통과
- `app/ui/DarwinForge/Package.swift` 보강 (FFI 브리지 자리)
- 기존 Swift `DynamixelKit`은 Rust 코어로 대체 예정 (Sprint 1)

## Phase 5 — Sprints

### Sprint 1 — Connection Layer
- `forge-core::serial` (mac/linux abstraction)
- `forge-core::dynamixel::v1` 패킷 빌더·파서·체크섬 (구현 + 단위 테스트)
- `forge-core::dynamixel::v2` 패킷 빌더·파서·CRC
- `forge-core::controller::{cm730, cm740}`
- CLI: `forge ping --port <path>`
- 데모: 더미 백엔드로 ID 스캔, 통합 테스트는 옵션 플래그

### Sprint 2 — Live Joint Control
- Sync Read/Write
- 안전 한계 클램핑·토크 ON/OFF·온도 모니터
- SwiftUI 슬라이더 화면 (코드만, 컴파일은 Mac에서)
- e-stop 단축키 ⌘⇧.

### Sprint 3 — Motion Import/Export
- `.mtn` 포맷 파서·라이터 (Phase 2 명세 기반)
- 내부 JSON 포맷 정의 (round-trip 무손실)
- 기존 모션 라이브러리 임포트

### Sprint 4 — Motion Editor
- 타임라인 데이터 모델 (Rust) + SwiftUI 뷰 골격
- 실기기 캡처 자세 → 키프레임 (CLI로 데모)
- SQLite 영속화

### Sprint 5 — Walk Engine
- DARwIn-OP 워킹 알고리즘 Rust 포팅 (라이선스 검토 후)
- 파라미터 튜너 데이터 모델
- IMU 폴링 → 자세 추정

### Sprint 6 — Vision & Strategy
- 카메라 추상화 (Mac 카메라 + 로봇 카메라 패스스루 — 후자는 Mac에서만)
- 공·골 후보 검출 (러스트 + opencv 또는 Vision.framework FFI)
- FSM 데이터 모델

## 품질 바 — 모든 Sprint 공통

- `cargo fmt --check && cargo clippy -- -D warnings` 통과
- `cargo test` 통과 + 커버리지 보고
- Swift 빌드 가이드 (`docs/reports/SPRINT_N_REPORT.md`에 Mac 명령어 명시)
- 라이선스 추가 시 `vendor/LICENSES.md` 갱신
- PUBLIC API에 doc comment
- PROGRESS.md / ROADMAP.md 갱신
- Sprint 보고서 작성

## MVP 정의

- Sprint 1 ~ 3 완성 + Sprint 4 골격 + Sprint 5/6 데이터 모델 = "고퀄리티 MVP".
- Mac에서 OP1/OP2를 USB로 연결, 모터 ID 스캔, 한 관절 슬라이더 제어, `.mtn` 모션 임포트·재생까지 가능한 상태.
