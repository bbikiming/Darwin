# darwin-fpv — Tauri 앱 자리 (W1 스캐폴딩)

DARwIn FPV 의 실행 바이너리(Tauri 2). **W0 에서는 의도적으로 비어 있다** —
Tauri 의존이 무거워 골격 단계의 `cargo test` 를 가볍게 유지하기 위해
워크스페이스 멤버 등록을 W1 으로 보류했다 (app/ally/Cargo.toml 주석 참조).

W1 스캐폴딩 절차 (Windows 작업 머신에서):

1. `cargo install tauri-cli --version "^2"` 후 `cargo tauri init`
   (frontendDist: `../../ui`, identifier: `dev.darwinforge.fpv`)
2. `app/ally/Cargo.toml` members 에 `crates/darwin-fpv` 추가
3. tauri.conf.json: 풀스크린 borderless, `useHttpsScheme: false`
   (robot 8080 MJPEG http 이미지 로드 — mixed content 회피,
   docs/03_ARCHITECTURE.md §4), CSP `img-src` 에 robot IP 대역 허용
4. Rust 코어 스레드 기동(ally-input·ally-link)은 main 에서 Tauri 빌더보다
   먼저 — webview 는 어떤 안전 경로에도 없다 (PRD §7 INV-2)

설계 전문: docs/03_ARCHITECTURE.md §2(스레드 모델)·§3(Rust⇄UI 계약).
