//! 라이브러리 + 합성 엔진 상태 — MCP 호출 사이에 공유.
//!
//! `motion_4096.bin` 을 lazy load 해서 in-memory 캐시. `commit` 시점에는 실제
//! 파일 시스템 write.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use forge_core::synth::library::PageLibrary;

/// 합성 엔진 — `PageLibrary` 캐시.
pub struct Engine {
    /// `motion_4096.bin` 경로. None 이면 in-memory only (테스트용).
    pub bin_path: Option<PathBuf>,
    library: Mutex<Option<PageLibrary>>,
}

impl Engine {
    /// 기본 엔진 — `FORGE_MOTION_BIN` env 또는 workspace 기본 경로 사용.
    pub fn new_default() -> Self {
        let bin_path = std::env::var("FORGE_MOTION_BIN")
            .ok()
            .map(PathBuf::from)
            .or_else(|| {
                let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
                p.push("../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin");
                if p.exists() {
                    Some(p)
                } else {
                    None
                }
            });
        Self {
            bin_path,
            library: Mutex::new(None),
        }
    }

    /// 명시적 bin 경로로 엔진 생성.
    pub fn new_with_bin(path: impl Into<PathBuf>) -> Self {
        Self {
            bin_path: Some(path.into()),
            library: Mutex::new(None),
        }
    }

    /// 테스트용 — bin 파일 없이 빈 라이브러리.
    pub fn new_in_memory() -> Self {
        Self {
            bin_path: None,
            library: Mutex::new(Some(PageLibrary::new())),
        }
    }

    /// 라이브러리 lazy load + 캐시.
    ///
    /// `with_library(|lib| ...)` 패턴으로 호출 — `MutexGuard` 라이프타임을
    /// 호출자에 노출하지 않고 closure 안에서만 빌림.
    pub fn with_library<R>(&self, f: impl FnOnce(&PageLibrary) -> R) -> Result<R, EngineError> {
        let mut guard = self.library.lock().map_err(|_| EngineError::Poisoned)?;
        if guard.is_none() {
            let path = self.bin_path.as_ref().ok_or(EngineError::NoBinConfigured)?;
            if !path.exists() {
                return Err(EngineError::BinNotFound(path.clone()));
            }
            let lib = PageLibrary::from_official_bin(path)
                .map_err(|e| EngineError::LoadFailed(e.to_string()))?;
            *guard = Some(lib);
        }
        let lib = guard.as_ref().expect("loaded above");
        Ok(f(lib))
    }

    /// 라이브러리 강제 reload — 디스크 변경 후 호출.
    pub fn reload(&self) -> Result<(), EngineError> {
        let mut guard = self.library.lock().map_err(|_| EngineError::Poisoned)?;
        *guard = None;
        Ok(())
    }

    /// `bin_path` 가 존재하는지 확인.
    pub fn bin_exists(&self) -> bool {
        self.bin_path.as_ref().map(|p| p.exists()).unwrap_or(false)
    }
}

/// 엔진 동작 에러.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    /// `bin_path` 가 설정되지 않음 (in-memory mode 인데 라이브러리 요청).
    #[error("bin path not configured")]
    NoBinConfigured,
    /// 설정된 bin 파일이 존재하지 않음.
    #[error("motion_4096.bin not found at {0:?}")]
    BinNotFound(PathBuf),
    /// 라이브러리 로드 실패.
    #[error("failed to load library: {0}")]
    LoadFailed(String),
    /// Mutex 가 다른 thread 의 panic 으로 poisoned.
    #[error("internal lock poisoned")]
    Poisoned,
    /// 파일 시스템 I/O 에러.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// `commit` 시 백업 sidecar 파일 경로 생성.
pub fn backup_path(bin: &Path) -> PathBuf {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    bin.with_extension(format!("bin.{secs}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_engine_has_empty_library() {
        let e = Engine::new_in_memory();
        let count = e.with_library(|lib| lib.len()).expect("lib");
        assert_eq!(count, 0);
    }

    #[test]
    fn missing_bin_returns_error() {
        let e = Engine::new_with_bin("/nonexistent/path/motion.bin");
        let err = e.with_library(|_| ()).expect_err("should error");
        assert!(matches!(err, EngineError::BinNotFound(_)));
    }

    #[test]
    fn no_bin_configured_returns_error() {
        let e = Engine {
            bin_path: None,
            library: Mutex::new(None),
        };
        let err = e.with_library(|_| ()).expect_err("should error");
        assert!(matches!(err, EngineError::NoBinConfigured));
    }

    #[test]
    fn backup_path_appends_timestamp_extension() {
        let p = Path::new("/data/motion_4096.bin");
        let b = backup_path(p);
        let s = b.to_string_lossy();
        // 원본 파일명에 timestamp suffix 가 붙어야 함.
        assert!(s.starts_with("/data/motion_4096.bin."), "got {s}");
        // suffix 가 숫자 (epoch secs).
        let suffix = s.rsplit('.').next().unwrap();
        assert!(
            suffix.chars().all(|c| c.is_ascii_digit()),
            "suffix '{suffix}' should be numeric"
        );
    }
}
