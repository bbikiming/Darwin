# ADR-011: 직렬 추상화

- Status: Accepted
- Date: 2026-05-09

## Context

`forge-core::serial`는 Mac/Linux/loopback 셋을 추상화해야 한다:
- **Mac**: `/dev/cu.usbserial-*` IOKit/posix
- **Linux**: `/dev/ttyUSB*` posix (사용자가 onboard에서 직접 실행할 가능성)
- **Loopback**: 단위 테스트용 in-memory queue

## Decision

`pub trait SerialPort: Send + Sync`를 정의:

```rust
pub trait SerialPort: Send + Sync {
    fn write_all(&mut self, buf: &[u8]) -> Result<(), Error>;
    fn read_exact(&mut self, buf: &mut [u8], timeout: Duration) -> Result<(), Error>;
    fn flush(&mut self) -> Result<(), Error>;
    fn set_baud(&mut self, baud: u32) -> Result<(), Error>;
    fn close(&mut self) -> Result<(), Error>;
}
```

구현체:
- `PosixSerial` — Mac/Linux 공통 termios + `/dev/cu.*`/`/dev/tty*`
- `LoopbackBus` — `Vec<u8>`을 양방향 큐로 — 단위 테스트
- (옵션) `MockReplay` — 캡처된 트레이스를 재생 — 통합 테스트

## Consequences

- **긍정**: 단위 테스트가 진짜 시리얼 없이 가능. CI(컨테이너)에서 100% 커버.
- **긍정**: 같은 코드가 Mac/Linux 양쪽에서 빌드.
- **부정**: macOS의 FTDI latency timer 같은 플랫폼 전용 튜닝은 `PosixSerial::Mac` 변형으로 흡수.
- **위험**: 1 Mbps 정확도. Rust `serialport` 크레이트가 일부 환경에서 1M baud를 지원 안 함 → 직접 termios 호출하는 fallback 준비.

## 의존성

- `serialport` 크레이트 (4.x) — 1차 시도
- 실패 시 `nix` 크레이트로 직접 termios 조작

선택 결정은 Sprint 1에서 `cargo test` 통과 여부로.
