//! `serialport` crate 기반 macOS/Linux 직렬 포트.
//!
//! Sprint 1. 1 Mbps default, 8-N-1, no flow control.

use std::io::{Read, Write};
use std::time::Duration;

use serialport::SerialPortBuilder;

use super::SerialPort;
use crate::error::{Error, Result};

/// macOS/Linux 직렬 포트 어댑터.
pub struct PosixSerial {
    inner: Box<dyn serialport::SerialPort>,
    path: String,
}

impl PosixSerial {
    /// 기본 1 Mbps로 open. timeout은 read_exact가 매번 전달.
    ///
    /// **J13 (bus D0)**: macOS 에선 `TTYPort` 를 직접 열어 raw fd 를 얻은 뒤
    /// `IOSSDATALAT` ioctl 로 FTDI latency timer 를 1ms 로 낮춘다(기본 16ms 버퍼링이
    /// 모든 status 왕복에 가산 — USB 직결 IMU 50Hz 의 전제). 미지원 어댑터는 no-op.
    #[cfg(target_os = "macos")]
    pub fn open(path: &str, baud: u32) -> Result<Self> {
        use std::os::unix::io::AsRawFd;
        let tty = serialport::TTYPort::open(&builder(path, baud))
            .map_err(|e| Error::Other(format!("open {}: {}", path, e)))?;
        set_data_latency(tty.as_raw_fd(), 1);
        Ok(Self {
            inner: Box::new(tty),
            path: path.to_string(),
        })
    }

    /// 기본 1 Mbps로 open. timeout은 read_exact가 매번 전달.
    #[cfg(not(target_os = "macos"))]
    pub fn open(path: &str, baud: u32) -> Result<Self> {
        let inner = builder(path, baud)
            .open()
            .map_err(|e| Error::Other(format!("open {}: {}", path, e)))?;
        Ok(Self {
            inner,
            path: path.to_string(),
        })
    }

    /// 디바이스 노드 경로 (디버그용).
    pub fn path(&self) -> &str {
        &self.path
    }

    /// 시스템에 등장한 USB 직렬 포트를 열거.
    pub fn list_ports() -> Result<Vec<String>> {
        let ports = serialport::available_ports()
            .map_err(|e| Error::Other(format!("list ports: {}", e)))?;
        Ok(ports
            .into_iter()
            .filter_map(|p| match p.port_type {
                serialport::SerialPortType::UsbPort(_) => Some(p.port_name),
                _ => None,
            })
            .collect())
    }
}

fn builder(path: &str, baud: u32) -> SerialPortBuilder {
    serialport::new(path, baud)
        .data_bits(serialport::DataBits::Eight)
        .parity(serialport::Parity::None)
        .stop_bits(serialport::StopBits::One)
        .flow_control(serialport::FlowControl::None)
}

/// macOS `IOSSDATALAT` = `_IOW('T', 0, unsigned long)`.
///
/// `_IOW(g, n, t)` = `IOC_IN | ((sizeof(t) & IOCPARM_MASK) << 16) | (g << 8) | n`.
/// LP64 에서 `sizeof(unsigned long) == 8` → `0x8000_0000 | (8 << 16) | ('T' << 8) | 0`.
/// (`<IOKit/serial/ioss.h>`)
#[cfg(target_os = "macos")]
const IOSSDATALAT: libc::c_ulong = 0x8008_5400;

/// FTDI latency timer 를 `latency_ms` (보통 1ms) 로 설정. best-effort —
/// 미지원 어댑터(비-FTDI 등)는 ioctl 이 -1 을 반환하지만 16ms 기본값을 유지한 채
/// 조용히 no-op 한다(시리얼 동작 자체엔 무해).
#[cfg(target_os = "macos")]
fn set_data_latency(fd: std::os::unix::io::RawFd, latency_ms: libc::c_ulong) {
    let value: libc::c_ulong = latency_ms;
    // SAFETY: `fd` 는 방금 연 유효한 직렬 포트 디스크립터이며, IOSSDATALAT 는
    // `unsigned long` 한 개를 가리키는 포인터를 받는다(_IOW 의 in-arg). 실패 시 -1.
    let _ = unsafe { libc::ioctl(fd, IOSSDATALAT, &value as *const libc::c_ulong) };
}

#[cfg(all(test, target_os = "macos"))]
mod posix_tests {
    use super::*;

    #[test]
    fn iossdatalat_matches_iow_formula() {
        // _IOW('T', 0, unsigned long), LP64.
        const IOC_IN: libc::c_ulong = 0x8000_0000;
        let group = b'T' as libc::c_ulong;
        let size = std::mem::size_of::<libc::c_ulong>() as libc::c_ulong; // 8
        let expected = IOC_IN | ((size & 0x1fff) << 16) | (group << 8);
        assert_eq!(expected, IOSSDATALAT);
    }

    #[test]
    fn set_data_latency_on_invalid_fd_is_noop() {
        // 잘못된 fd 에도 panic 없이 반환(ioctl 은 -1/EBADF).
        set_data_latency(-1, 1);
    }
}

impl SerialPort for PosixSerial {
    fn write_all(&mut self, buf: &[u8]) -> Result<()> {
        Write::write_all(&mut self.inner, buf).map_err(Error::Io)
    }

    fn read_exact(&mut self, buf: &mut [u8], timeout: Duration) -> Result<()> {
        self.inner
            .set_timeout(timeout)
            .map_err(|e| Error::Other(format!("set_timeout: {}", e)))?;
        Read::read_exact(&mut self.inner, buf).map_err(|e| {
            if e.kind() == std::io::ErrorKind::TimedOut {
                Error::Timeout(timeout)
            } else {
                Error::Io(e)
            }
        })
    }

    fn flush(&mut self) -> Result<()> {
        Write::flush(&mut self.inner).map_err(Error::Io)
    }

    fn set_baud(&mut self, baud: u32) -> Result<()> {
        self.inner
            .set_baud_rate(baud)
            .map_err(|e| Error::Other(format!("set_baud: {}", e)))
    }

    fn close(&mut self) -> Result<()> {
        // serialport crate에는 명시적 close가 없음 — Drop이 처리.
        Ok(())
    }

    /// `serialport` 의 `clear(ClearBuffer::Input)` 으로 input buffer 비우기.
    fn drain_input(&mut self) -> Result<()> {
        let _ = self.inner.clear(serialport::ClearBuffer::Input);
        Ok(())
    }
}
