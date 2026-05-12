//! Motion Synthesis 엔진 에러 타입.

use thiserror::Error;

/// 합성 작업 중 발생할 수 있는 에러.
#[derive(Debug, Error)]
pub enum SynthError {
    /// 입력 페이지가 라이브러리에 없음.
    #[error("page {0} not found in library")]
    PageNotFound(u16),

    /// 합성 결과 step 수가 페이지 분할로도 수용 불가.
    #[error("output exceeds {0} steps and cannot be split into pages")]
    StepOverflow(usize),

    /// 좌우 미러링 시 페어가 정의되지 않은 관절.
    #[error("joint id {0} has no left/right mirror pair")]
    MissingMirrorPair(u8),

    /// 검증 단계 실패.
    #[error("validation failed: {0}")]
    ValidationFailed(String),

    /// 알 수 없는 합성 옵션.
    #[error("unknown synth option: {0}")]
    UnknownOption(String),

    /// 디코드 실패 (`motion_4096.bin` 페이지 구조 등).
    #[error("decode failed: {0}")]
    Decode(String),

    /// 그 외 일반 에러.
    #[error("{0}")]
    Other(String),
}

/// `synth` 모듈 전용 `Result` 별칭.
pub type Result<T> = std::result::Result<T, SynthError>;
