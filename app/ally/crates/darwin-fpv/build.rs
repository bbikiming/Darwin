//! 빌드 스크립트 — `cockpit` feature 일 때만 tauri 빌드(컨텍스트·capabilities·리소스).
//! 기본 빌드는 tauri-build 를 들이지 않는다(경량 유지).

fn main() {
    #[cfg(feature = "cockpit")]
    tauri_build::build();
}
