//! Dynamixel **Protocol 1.0** 패킷 빌더·파서.
//!
//! 본 모듈은 Sprint 1 핵심. 단위 테스트 100% 커버 목표.

use thiserror::Error;

/// Protocol 1.0 인스트럭션.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Instruction {
    /// 0x01 — 디바이스 존재 확인.
    Ping = 0x01,
    /// 0x02 — 컨트롤 테이블 read.
    ReadData = 0x02,
    /// 0x03 — 컨트롤 테이블 write.
    WriteData = 0x03,
    /// 0x04 — write를 큐잉 (action으로 commit).
    RegWrite = 0x04,
    /// 0x05 — 큐잉된 write commit.
    Action = 0x05,
    /// 0x06 — 공장 초기화.
    FactoryReset = 0x06,
    /// 0x08 — 디바이스 reboot.
    Reboot = 0x08,
    /// 0x83 — sync write (다중 ID에 같은 레지스터 write).
    SyncWrite = 0x83,
    /// 0x92 — bulk read (다중 ID에서 다른 레지스터 read).
    BulkRead = 0x92,
}

impl Instruction {
    /// 바이트 → enum.
    pub fn from_byte(b: u8) -> Option<Self> {
        Some(match b {
            0x01 => Self::Ping,
            0x02 => Self::ReadData,
            0x03 => Self::WriteData,
            0x04 => Self::RegWrite,
            0x05 => Self::Action,
            0x06 => Self::FactoryReset,
            0x08 => Self::Reboot,
            0x83 => Self::SyncWrite,
            0x92 => Self::BulkRead,
            _ => return None,
        })
    }
}

/// Status 패킷의 ERROR 바이트 비트 플래그.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ErrorFlags(pub u8);

impl ErrorFlags {
    /// 비트 0 — 입력 전압 한계 초과.
    pub const INPUT_VOLTAGE: u8 = 1;
    /// 비트 1 — goal position이 angle limit 외부.
    pub const ANGLE_LIMIT: u8 = 2;
    /// 비트 2 — 내부 온도 한계.
    pub const OVERHEATING: u8 = 4;
    /// 비트 3 — parameter out of range.
    pub const RANGE: u8 = 8;
    /// 비트 4 — 디바이스 측 RX checksum mismatch.
    pub const CHECKSUM: u8 = 16;
    /// 비트 5 — torque overload.
    pub const OVERLOAD: u8 = 32;
    /// 비트 6 — 알 수 없는 인스트럭션.
    pub const INSTRUCTION: u8 = 64;

    /// 에러 없음?
    pub fn is_ok(self) -> bool {
        self.0 == 0
    }

    /// 특정 비트 set?
    pub fn contains(self, bit: u8) -> bool {
        self.0 & bit != 0
    }
}

/// 호스트가 디바이스로 보내는 Instruction 패킷.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstructionPacket {
    /// 대상 디바이스 ID. 254 = 브로드캐스트.
    pub id: u8,
    /// 인스트럭션 코드.
    pub instruction: Instruction,
    /// 파라미터 바이트 (인스트럭션별 의미 다름).
    pub parameters: Vec<u8>,
}

/// 디바이스가 호스트로 응답하는 Status 패킷.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusPacket {
    /// 응답한 디바이스 ID.
    pub id: u8,
    /// 에러 플래그.
    pub error: ErrorFlags,
    /// 응답 파라미터 (READ_DATA의 결과 등).
    pub parameters: Vec<u8>,
}

/// 코덱 에러.
#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum CodecError {
    /// 입력 길이 부족.
    #[error("packet truncated (need {need}, got {got})")]
    Truncated {
        /// 필요한 최소 길이.
        need: usize,
        /// 실제 길이.
        got: usize,
    },

    /// 헤더 (`0xFF 0xFF`) 누락.
    #[error("missing 0xFF 0xFF header")]
    MissingHeader,

    /// 길이 필드와 실제 패킷 길이 불일치.
    #[error("length mismatch (declared {declared}, actual {actual})")]
    LengthMismatch {
        /// 패킷에 선언된 길이.
        declared: usize,
        /// 실제 바이트 수.
        actual: usize,
    },

    /// 체크섬 불일치.
    #[error("checksum mismatch (expected 0x{expected:02X}, got 0x{actual:02X})")]
    ChecksumMismatch {
        /// 우리가 계산한 값.
        expected: u8,
        /// 패킷에 적힌 값.
        actual: u8,
    },
}

/// 코덱 함수.
pub struct Codec;

impl Codec {
    /// 체크섬: `~(id + length + opcode + Σparams) & 0xFF`.
    pub fn checksum(id: u8, length: u8, opcode: u8, params: &[u8]) -> u8 {
        let mut sum: u32 = id as u32 + length as u32 + opcode as u32;
        for &b in params {
            sum = sum.wrapping_add(b as u32);
        }
        !(sum as u8)
    }

    /// Instruction packet → 바이트 시퀀스.
    pub fn encode(packet: &InstructionPacket) -> Vec<u8> {
        let length = (packet.parameters.len() + 2) as u8;
        let mut out = Vec::with_capacity(6 + packet.parameters.len());
        out.push(0xFF);
        out.push(0xFF);
        out.push(packet.id);
        out.push(length);
        out.push(packet.instruction as u8);
        out.extend_from_slice(&packet.parameters);
        out.push(Self::checksum(
            packet.id,
            length,
            packet.instruction as u8,
            &packet.parameters,
        ));
        out
    }

    /// 바이트 시퀀스 → Status packet.
    pub fn decode_status(bytes: &[u8]) -> Result<StatusPacket, CodecError> {
        if bytes.len() < 6 {
            return Err(CodecError::Truncated {
                need: 6,
                got: bytes.len(),
            });
        }
        if bytes[0] != 0xFF || bytes[1] != 0xFF {
            return Err(CodecError::MissingHeader);
        }
        let id = bytes[2];
        let length = bytes[3] as usize;
        let total = 4 + length;
        if bytes.len() < total {
            return Err(CodecError::LengthMismatch {
                declared: total,
                actual: bytes.len(),
            });
        }
        let error = bytes[4];
        let params = bytes[5..(total - 1)].to_vec();
        let received = bytes[total - 1];
        let expected = Self::checksum(id, length as u8, error, &params);
        if received != expected {
            return Err(CodecError::ChecksumMismatch {
                expected,
                actual: received,
            });
        }
        Ok(StatusPacket {
            id,
            error: ErrorFlags(error),
            parameters: params,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_ping_id1_matches_protocol_fixture() {
        let p = InstructionPacket {
            id: 1,
            instruction: Instruction::Ping,
            parameters: vec![],
        };
        // Protocol 1.0 reference: PING ID=1 → FF FF 01 02 01 FB
        assert_eq!(Codec::encode(&p), vec![0xFF, 0xFF, 0x01, 0x02, 0x01, 0xFB]);
    }

    #[test]
    fn encode_write_data_id1_addr3_val1_checksum() {
        let p = InstructionPacket {
            id: 1,
            instruction: Instruction::WriteData,
            parameters: vec![0x03, 0x01],
        };
        let bytes = Codec::encode(&p);
        assert_eq!(&bytes[..5], &[0xFF, 0xFF, 0x01, 0x04, 0x03]);
        assert_eq!(&bytes[5..7], &[0x03, 0x01]);
        // Σ = 1+4+3+3+1 = 12 = 0x0C, ~0x0C = 0xF3
        assert_eq!(*bytes.last().unwrap(), 0xF3);
    }

    #[test]
    fn decode_status_no_error_round_trip() {
        // Status: ID=1, error=0, no params → FF FF 01 02 00 FC
        let bytes = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC];
        let s = Codec::decode_status(&bytes).unwrap();
        assert_eq!(s.id, 1);
        assert!(s.error.is_ok());
        assert!(s.parameters.is_empty());
    }

    #[test]
    fn decode_status_with_params() {
        // Status: ID=1, error=0, params=[0x20, 0x00] (예: position read 결과)
        // length = 4, checksum = ~(1+4+0+0x20+0) = ~0x25 = 0xDA
        let bytes = [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x20, 0x00, 0xDA];
        let s = Codec::decode_status(&bytes).unwrap();
        assert_eq!(s.parameters, vec![0x20, 0x00]);
    }

    #[test]
    fn decode_status_rejects_bad_header() {
        let bytes = [0x00, 0xFF, 0x01, 0x02, 0x00, 0x00];
        assert!(matches!(
            Codec::decode_status(&bytes),
            Err(CodecError::MissingHeader)
        ));
    }

    #[test]
    fn decode_status_rejects_bad_checksum() {
        let bytes = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0x00];
        assert!(matches!(
            Codec::decode_status(&bytes),
            Err(CodecError::ChecksumMismatch { .. })
        ));
    }

    #[test]
    fn decode_status_rejects_truncated() {
        let bytes = [0xFF, 0xFF, 0x01];
        assert!(matches!(
            Codec::decode_status(&bytes),
            Err(CodecError::Truncated { .. })
        ));
    }

    #[test]
    fn error_flags_bits() {
        let e = ErrorFlags(ErrorFlags::OVERLOAD | ErrorFlags::OVERHEATING);
        assert!(!e.is_ok());
        assert!(e.contains(ErrorFlags::OVERLOAD));
        assert!(e.contains(ErrorFlags::OVERHEATING));
        assert!(!e.contains(ErrorFlags::INPUT_VOLTAGE));
    }

    #[test]
    fn instruction_round_trip() {
        for inst in [
            Instruction::Ping,
            Instruction::ReadData,
            Instruction::WriteData,
            Instruction::SyncWrite,
            Instruction::BulkRead,
        ] {
            assert_eq!(Instruction::from_byte(inst as u8), Some(inst));
        }
        assert_eq!(Instruction::from_byte(0xAB), None);
    }
}
