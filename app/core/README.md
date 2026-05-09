# app/core/

Rust 코어 라이브러리. Dynamixel 직렬 통신·프로토콜·실시간 루프.

Phase 4에서 `forge-core/` 하위에 Cargo workspace로 초기화된다.

## 예정 모듈

- `serial::{TtyPort, U2D2}` — 시리얼 추상화
- `dynamixel::{ProtocolV1, ProtocolV2}` — 패킷 빌더·파서
- `controller::{CM730, CM740}` — 컨트롤러 보드 추상화
- `motion::{Page, Step, Player, Recorder}` — 모션 엔진
- `walk::{WalkEngine, Params}` — 워크 엔진
- `vision::{Pipeline, BallTracker}` — 비전 (Mac 측 카메라는 Swift FFI)
- `db::{MotionLib, RobotProfile}` — 영속성 (SQLite)

## Mac에서 호출

C-ABI (`extern "C"`) 또는 Swift Package로 노출. ADR-009 ~ ADR-013 참조.
