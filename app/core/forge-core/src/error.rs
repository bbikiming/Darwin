//! 공통 에러 타입.

use thiserror::Error;

/// `forge-core`의 통합 에러.
#[derive(Debug, Error)]
pub enum Error {
    /// 직렬 포트 I/O 에러.
    #[error("serial I/O: {0}")]
    Io(#[from] std::io::Error),

    /// 패킷 디코드 에러.
    #[error("dynamixel codec: {0}")]
    Codec(#[from] crate::dynamixel::CodecError),

    /// 응답 시간 초과.
    #[error("timeout after {0:?}")]
    Timeout(std::time::Duration),

    /// 알 수 없는 디바이스 ID.
    #[error("device id {0} not found on bus")]
    DeviceNotFound(u8),

    /// E-STOP 선점 — 진행 중 read 가 긴급정지 요청으로 조기 abort 됨 (S4).
    /// 이는 오류가 아니라 의도된 중단 — 호출자(백그라운드 리더/폴러)는 무음 skip.
    #[error("read aborted by e-stop preempt")]
    EstopPreempted,

    /// 일반 에러.
    #[error("{0}")]
    Other(String),
}

/// `forge-core` 전용 `Result` 별칭.
pub type Result<T> = std::result::Result<T, Error>;
