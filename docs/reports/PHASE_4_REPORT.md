# Phase 4 — App Architecture + Cargo Workspace

## 요약

Rust+SwiftUI 이원화의 5개 ADR을 작성하고 `app/core/`에 Cargo workspace
(`forge-core` 라이브러리 + `forge-cli` 실행파일)를 초기화. 컨테이너에서
`cargo build`, `cargo test` (18 테스트 통과), `cargo clippy`, `cargo fmt --check` 모두 GREEN.

## 핵심 산출물

### ADR (5개)
- `ADR-009-rust-swift-split.md` — ADR-001/002 보강. 코어=Rust, UI=SwiftUI.
- `ADR-010-module-boundaries.md` — Rust↔Swift 책임 분담 표, 1차 boundary = staticlib + 헤더, 동기/비동기 모델, 데이터 통과 규약.
- `ADR-011-serial-abstraction.md` — `SerialPort` trait, `PosixSerial`/`LoopbackBus` 구현, `serialport` crate 1차 시도.
- `ADR-012-persistence.md` — SQLite (rusqlite), `~/Library/Application Support/DarwinForge/library.sqlite`, 스키마 v1 초안.
- `ADR-013-test-strategy.md` — 4등급 테스트, 70% 커버리지 목표, mock 전략.

### Cargo workspace (`app/core/`)
- `Cargo.toml` (workspace) — resolver=2, 멤버=[forge-core, forge-cli], 공통 deps (thiserror/anyhow/serde/serde_json/clap/tracing).
- `forge-core/` 라이브러리 (rlib + staticlib):
  - `error.rs` — Error enum, Result alias
  - `dynamixel/v1.rs` — Codec / Instruction / ErrorFlags / InstructionPacket / StatusPacket / CodecError 모두 완성, **Sprint 1 본 구현이 사실상 끝남**
  - `dynamixel/v2.rs` — placeholder (ADR-003)
  - `serial/mod.rs` + `serial/loopback.rs` — `SerialPort` trait + `LoopbackBus` 단위 테스트 백엔드
  - `joint.rs` — `JointId`(16개) / `BodyPart` / `special` 모듈 / position↔라디안 변환
  - `controller/mod.rs` — `ControllerModel` enum, `cm_register` & `mx28_register` 주소 상수
- `forge-cli/` 실행파일 (`forge` 바이너리):
  - clap 4 derive, 3개 서브커맨드 (`ping`, `scan`, `list-joints`)
  - `list-joints`는 즉시 작동 — JointId::ALL 출력
  - `ping`/`scan`은 Sprint 1에서 LoopbackBus 너머 PosixSerial 추가 시 작동

### 검증

| 도구 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ 18.02s |
| `cargo test --workspace` | ✅ **18 / 18 통과** |
| `cargo clippy --workspace -- -D warnings` | ✅ clean |
| `cargo fmt --check` | ✅ clean (apply 후) |

테스트 18개 분포:
- dynamixel/v1 codec: 8 (encode PING/WRITE_DATA, decode 4가지 케이스, error flags, instruction round trip)
- joint: 5 (16개 카운트, body part 그룹, from_byte, position 변환, clamp)
- serial/loopback: 3 (round trip, baud 기록, timeout)
- controller: 2 (serde, 기본)

## 자기검증 결과

- [x] ADR-009..013 모두 Status/Date/Context/Decision/Consequences 표준 양식
- [x] `cargo build --workspace` 통과
- [x] `cargo test --workspace` 100% 통과
- [x] `cargo clippy -- -D warnings` 통과
- [x] `cargo fmt --check` 통과 (자동 정렬 후)
- [x] `forge-core`가 `staticlib` + `rlib` 두 산출물 생성 (Swift FFI 준비)
- [x] PUBLIC API 모두 doc comment (`#![warn(missing_docs)]`)

## Blockers

없음. Sprint 1을 위한 모든 인프라 준비 완료.

## 다음 단계

**Sprint 1 — Connection Layer** 즉시 자율 시작:
1. `forge-core/src/serial/posix.rs` 추가 (`/dev/cu.*` 직접 open, 1 Mbps)
2. `forge-core/src/dynamixel/bus.rs` (`Bus` 추상화: write_packet → read_status, timeout 포함)
3. `forge-core/src/controller/cm.rs` (CM-730/740 wrapper)
4. `forge-cli ping --port` 실 작동
5. `forge-cli scan --port --range` 실 작동
6. 통합 테스트 — LoopbackBus에서 ID 1 ping → 응답 검증
