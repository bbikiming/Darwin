//! `SYNC_WRITE` (0x83) / `BULK_READ` (0x92) codec.
//!
//! 둘 다 다중 디바이스에 한 패킷으로 read/write — 워크엔진 8 ms 루프의 핵심.

use crate::dynamixel::v1::{Codec, Instruction, InstructionPacket, StatusPacket};
use crate::error::{Error, Result};
use crate::serial::SerialPort;

use super::Bus;

/// SYNC_WRITE에 묶을 디바이스별 데이터 한 묶음.
#[derive(Debug, Clone)]
pub struct SyncWriteEntry {
    /// 디바이스 ID.
    pub id: u8,
    /// 디바이스에 쓸 바이트 (start_address부터 length 만큼).
    pub data: Vec<u8>,
}

impl<P: SerialPort> Bus<P> {
    /// `SYNC_WRITE`. 모든 디바이스가 같은 `start_address`부터 `length` 바이트 write.
    ///
    /// 패킷: `0xFF 0xFF 0xFE LEN 0x83 ADDR LENGTH (ID DATA[LENGTH])* CSUM`
    /// LEN = (LENGTH+1) * N + 4
    pub fn sync_write(
        &mut self,
        start_address: u8,
        length: u8,
        entries: &[SyncWriteEntry],
    ) -> Result<()> {
        debug_assert!(entries.iter().all(|e| e.data.len() == length as usize));
        let mut params = Vec::with_capacity(2 + entries.len() * (1 + length as usize));
        params.push(start_address);
        params.push(length);
        for e in entries {
            params.push(e.id);
            params.extend_from_slice(&e.data);
        }
        // SYNC_WRITE는 broadcast(254)로 보내고 응답 없음.
        self.send(&InstructionPacket {
            id: 0xFE,
            instruction: Instruction::SyncWrite,
            parameters: params,
        })?;
        Ok(())
    }

    /// `BULK_READ`. 다중 디바이스에서 (잠재적으로 다른) 레지스터 read.
    ///
    /// 패킷: `0xFF 0xFF 0xFE LEN 0x92 0x00 (LENGTH ID ADDR)* CSUM`
    ///
    /// 응답: 각 디바이스가 순서대로 Status 패킷 1개씩 보냄.
    pub fn bulk_read(
        &mut self,
        requests: &[(u8 /*id*/, u8 /*addr*/, u8 /*len*/)],
    ) -> Result<Vec<StatusPacket>> {
        let mut params = Vec::with_capacity(1 + requests.len() * 3);
        params.push(0x00); // reserved
        for (id, addr, len) in requests {
            params.push(*len);
            params.push(*id);
            params.push(*addr);
        }
        self.send(&InstructionPacket {
            id: 0xFE,
            instruction: Instruction::BulkRead,
            parameters: params,
        })?;
        let mut out = Vec::with_capacity(requests.len());
        for _ in requests {
            out.push(self.recv()?);
        }
        Ok(out)
    }
}

/// 외부에서 패킷 직접 검증할 때 쓰는 codec.
pub mod codec {
    use super::*;

    /// SYNC_WRITE 패킷의 raw bytes 생성 (전송 없이).
    pub fn encode_sync_write(start_address: u8, length: u8, entries: &[SyncWriteEntry]) -> Vec<u8> {
        let mut params = Vec::with_capacity(2 + entries.len() * (1 + length as usize));
        params.push(start_address);
        params.push(length);
        for e in entries {
            params.push(e.id);
            params.extend_from_slice(&e.data);
        }
        Codec::encode(&InstructionPacket {
            id: 0xFE,
            instruction: Instruction::SyncWrite,
            parameters: params,
        })
    }
}

// 명시적으로 사용 안 됨이라는 컴파일러 힌트 회피
#[allow(unused_imports)]
use Error as _Error;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serial::LoopbackBus;

    #[test]
    fn sync_write_packet_layout() {
        let entries = vec![
            SyncWriteEntry {
                id: 1,
                data: vec![0x00, 0x08],
            },
            SyncWriteEntry {
                id: 2,
                data: vec![0x00, 0x08],
            },
        ];
        let bytes = codec::encode_sync_write(30, 2, &entries);
        // 헤더 + ID 254 + LENGTH + 0x83 + 30 + 2 + (1, 0, 8) + (2, 0, 8) + CSUM
        // length param = (LENGTH+1)*N + 4 = 3*2 + 4 = 10
        assert_eq!(&bytes[..6], &[0xFF, 0xFF, 0xFE, 0x0A, 0x83, 30]);
        assert_eq!(bytes[6], 2); // length
        assert_eq!(&bytes[7..10], &[1, 0x00, 0x08]); // ID 1 entry
        assert_eq!(&bytes[10..13], &[2, 0x00, 0x08]); // ID 2 entry
    }

    #[test]
    fn sync_write_via_bus_writes_correct_bytes() {
        let mut bus = Bus::new(LoopbackBus::default());
        let entries = vec![SyncWriteEntry {
            id: 5,
            data: vec![0xAA, 0xBB],
        }];
        bus.sync_write(30, 2, &entries).unwrap();
        let w = &bus.port_mut().written;
        assert_eq!(w[0..2], [0xFF, 0xFF]);
        assert_eq!(w[2], 0xFE); // broadcast ID
        assert_eq!(w[4], 0x83); // SYNC_WRITE opcode
    }
}
