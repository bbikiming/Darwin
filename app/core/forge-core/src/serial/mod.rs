//! 직렬 포트 추상화 (ADR-011).
//!
//! Phase 4: trait + LoopbackBus만 정의. PosixSerial은 Sprint 1에서 추가.

use std::time::Duration;

use crate::error::Result;

/// Mac/Linux/Loopback 공통 직렬 포트.
pub trait SerialPort: Send {
    /// 모든 바이트를 전송 (혹은 에러).
    fn write_all(&mut self, buf: &[u8]) -> Result<()>;

    /// 정확히 `buf.len()` 바이트를 읽거나 timeout.
    fn read_exact(&mut self, buf: &mut [u8], timeout: Duration) -> Result<()>;

    /// 출력 버퍼 비우기.
    fn flush(&mut self) -> Result<()>;

    /// baud rate 변경 (1_000_000 등).
    fn set_baud(&mut self, baud: u32) -> Result<()>;

    /// 포트 close.
    fn close(&mut self) -> Result<()>;

    /// 입력 buffer 비우기 (best-effort, non-blocking).
    ///
    /// `Bus::send()` 가 새 명령 전 호출 — 이전 응답의 잔여 byte 또는 unsolicited
    /// broadcast 패킷이 다음 `recv()` 의 첫 byte로 들어가 misalignment를 일으키는
    /// 것을 방지. socat 등 byte-stream bridge 환경에서 특히 중요.
    /// 기본 구현은 noop — TCP/Posix만 override.
    fn drain_input(&mut self) -> Result<()> {
        Ok(())
    }
}

mod loopback;
mod posix;
mod tcp;
pub use loopback::LoopbackBus;
pub use posix::PosixSerial;
pub use tcp::TcpBus;
