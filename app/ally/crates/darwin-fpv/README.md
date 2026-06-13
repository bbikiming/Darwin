# darwin-fpv — DARwIn FPV 런타임 + Tauri 셸

DARwIn FPV 의 실행 바이너리. `ally-input`(게임패드·G01 매핑·안전 게이트)과
`ally-link`(UDP·SSH·메트릭) 위에 docs/03_ARCHITECTURE.md §2 의 7-스레드 모델을 올린다.

## 현재 상태 (W1)

- **Phase 2a — 안전·제어 코어 (구현됨, tauri-free):** `src/{state,event,estop,tx,supervisor}.rs`.
  - INV-2: 런타임 라이브러리는 **tauri 를 의존하지 않는다**. 표시계층 push 는
    [`event::EventSink`] 트레이트로만 — 안전 스레드는 webview 객체를 일절 참조하지 않는다.
  - 단위검증: 무장 게이트·신선도(>150ms→zero+disarm)·E-STOP 래치·복구 램프·무손실 채널·
    하트비트 워치독. `cargo test -p darwin-fpv`.
- **Phase 2b — 스레드 런타임 (구현됨):** `src/runtime.rs` — control-tx(20Hz)·udp-rx·estop·
  supervisor(100ms)·estop-fwd·ssh-session(Robot) 6스레드. 입력 250Hz 는 `InputService` 내부.
  - `Endpoint::Loopback` 로 헤드리스 검증, `Endpoint::Robot` 은 실로봇 경로(아래 안전수칙).
- **Phase 3 — Tauri 셸 (예정):** `EventSink` 의 Tauri 구현 + 씬 상태머신(타이틀→접속→콕핏) +
  WebView2 표시 + 전원관리. 아래 스캐폴딩 절차 참조.

## 바이너리 사용 (헤드리스, 로봇 불요)

```powershell
cargo run -p darwin-fpv -- trace                  # TX 파이프라인 합성 트레이스(안전 거동 시연)
cargo run -p darwin-fpv -- selfcheck --seconds 3  # 런타임 6스레드 + 루프백 에코로봇 검증
```

`selfcheck` 기대: eff_hz ~20 · state/stick 이벤트 발행 · 클린 종료 PASS.

## ⚠️ 실로봇 기동(Endpoint::Robot)

런타임은 mode/단일세션 가드를 반복하지 않는다 — **`ally-cli connect` 로 운영자가 단일
세션·walklab 모드를 선검증한 뒤에만** 띄운다. 리포 안전수칙(요람 거치 + 다리 토크 해제 +
배터리 차단 인접) 준수. 종료 시 `shutdown()` 이 핸드셰이크를 철회한다(§7-7 MUST).

## Phase 3 Tauri 스캐폴딩 절차 (Windows)

1. `cargo install tauri-cli --version "^2"` 후 `cargo tauri init`
   (frontendDist: `../../ui`, identifier: `dev.darwinforge.fpv`)
2. `[dependencies]` 에 `tauri = "2"` 추가(bin 전용 — 라이브러리는 tauri-free 유지).
3. tauri.conf.json: 풀스크린 borderless, `useHttpsScheme: false`
   (robot 8080 MJPEG http 이미지 로드 — mixed content 회피, docs/03_ARCHITECTURE.md §4),
   CSP `img-src` 에 robot IP 대역(`http://192.168.123.1:8080 http://192.168.0.33:8080`) 허용.
4. `main` 에서 `Runtime::start` 를 Tauri 빌더보다 **먼저** 띄우고, Tauri 쪽 `EventSink`
   구현(AppHandle 보유)을 넘긴다 — webview 는 어떤 안전 경로에도 없다 (INV-2).

설계 전문: docs/03_ARCHITECTURE.md §2(스레드 모델)·§3(Rust⇄UI 계약)·§7(세션 시퀀스).
