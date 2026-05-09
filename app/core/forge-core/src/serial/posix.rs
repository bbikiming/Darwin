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
}
