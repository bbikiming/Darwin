# DARwIn FPV — Windows 빌드·패키징 (W1+ 에서 구현)
#
# 자리표시 스크립트: 절차만 고정해 둔다. Ally(또는 Windows 작업 머신)에서 실행.
#
# 선행 조건:
#   - rustup target add x86_64-pc-windows-msvc (네이티브면 기본)
#   - VS Build Tools (MSVC), WebView2 런타임(Win11 기본 내장)
#   - cargo install tauri-cli --version "^2"   (W2, darwin-fpv 빌드 시)
#
# W1 (헤드리스 코어):
#   cargo build --manifest-path app/ally/Cargo.toml -p ally-cli --release
#
# W2+ (Tauri 앱):
#   cargo tauri build  # crates/darwin-fpv 에서
#
# 패키징 단계 (W4, PKG-01/02):
#   1. exe + assets 묶음
#   2. 방화벽 인바운드 규칙 (TEL2 UDP 수신):
#      New-NetFirewallRule -DisplayName "DARwIn FPV TEL2" -Direction Inbound `
#        -Program <exe 경로> -Action Allow -Protocol UDP
#   3. WiFi 어댑터 절전 해제 (NIC power saving → RTT 스파이크 방지)
#   4. Armoury Crate 게임 등록 안내 출력 (수동 1회: 라이브러리 → 앱 추가)
#
Write-Host "W0 골격 — 빌드 절차는 W1에서 구현됩니다. (위 주석 참조)"
