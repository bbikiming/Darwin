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
}

mod loopback;
mod posix;
pub use loopback::LoopbackBus;
pub use posix::PosixSerial;
