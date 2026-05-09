//! 단위 테스트용 in-memory 직렬 포트.

use std::collections::VecDeque;
use std::time::Duration;

use super::SerialPort;
use crate::error::{Error, Result};

/// 호스트가 보낸 바이트와, 디바이스가 응답할 바이트를 둘 다 큐로 보유.
///
/// 사용 패턴:
/// ```ignore
/// let mut bus = LoopbackBus::default();
/// // 디바이스가 보낼 응답을 미리 set
/// bus.queue_read(&[0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC]);
/// // 호스트 측 동작
/// bus.write_all(&[0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB])?;
/// // 그 후 read_exact가 미리 큐된 바이트를 돌려줌
/// ```
#[derive(Default)]
pub struct LoopbackBus {
    /// 호스트가 write_all로 보낸 바이트.
    pub written: Vec<u8>,
    /// 디바이스가 응답할 바이트.
    pub to_read: VecDeque<u8>,
    /// 현재 baud (정보용).
    pub baud: u32,
}

impl LoopbackBus {
    /// 디바이스가 응답할 바이트를 큐에 enqueue.
    pub fn queue_read(&mut self, bytes: &[u8]) {
        self.to_read.extend(bytes);
    }
}

impl SerialPort for LoopbackBus {
    fn write_all(&mut self, buf: &[u8]) -> Result<()> {
        self.written.extend_from_slice(buf);
        Ok(())
    }

    fn read_exact(&mut self, buf: &mut [u8], _timeout: Duration) -> Result<()> {
        if self.to_read.len() < buf.len() {
            return Err(Error::Timeout(_timeout));
        }
        for slot in buf.iter_mut() {
            *slot = self.to_read.pop_front().unwrap();
        }
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        Ok(())
    }

    fn set_baud(&mut self, baud: u32) -> Result<()> {
        self.baud = baud;
        Ok(())
    }

    fn close(&mut self) -> Result<()> {
        self.to_read.clear();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_round_trip() {
        let mut bus = LoopbackBus::default();
        bus.queue_read(&[1, 2, 3]);
        bus.write_all(&[10, 20]).unwrap();

        let mut buf = [0u8; 3];
        bus.read_exact(&mut buf, Duration::from_millis(1)).unwrap();
        assert_eq!(buf, [1, 2, 3]);
        assert_eq!(bus.written, vec![10, 20]);
    }

    #[test]
    fn loopback_timeout_when_underflow() {
        let mut bus = LoopbackBus::default();
        bus.queue_read(&[1]);

        let mut buf = [0u8; 5];
        let err = bus
            .read_exact(&mut buf, Duration::from_millis(1))
            .unwrap_err();
        assert!(matches!(err, Error::Timeout(_)));
    }

    #[test]
    fn loopback_set_baud_records() {
        let mut bus = LoopbackBus::default();
        bus.set_baud(1_000_000).unwrap();
        assert_eq!(bus.baud, 1_000_000);
    }
}
