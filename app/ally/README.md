# DARwIn FPV — ROG Ally 콕핏 앱

ROG Ally(Windows 11 핸드헬드)에서 DARwIn-OP2 를 **라이브 카메라를 보며 원격
조종**하는 시뮬레이터 게임 스타일 전용 앱. Armoury Crate 게임 라이브러리에
등록되어 게임처럼 실행된다. Mac DarwinForge 가 "작업장"이라면 DARwIn FPV 는
"출격한 조종석"이다.

- 스택: **Tauri 2 하이브리드** — Rust 코어가 안전·통신 전담(게임패드 250Hz·
  DFCMD 20Hz·E-STOP 3연발·TEL2 30Hz·ssh2), WebView2 풀스크린 게임 UI.
  webview 는 어떤 안전 경로에도 없다.
- 와이어 계약: `docs/ssh-parity-contract.md` (§G UDP·§C 14-token·§A.2-TEL2) —
  로봇 펌웨어 변경 없음, Switch·Mac 과 동일 계약.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/00_PRODUCT_BRIEF.md](docs/00_PRODUCT_BRIEF.md) | 기획서 — 비전·시나리오·포지셔닝·계승/혁신·제품 원칙·성공 지표 |
| [docs/01_PRD.md](docs/01_PRD.md) | PRD — 기능 요구(REQ-ID)·NFR·안전 불변식·수용 기준·결정(D#) |
| [docs/02_UIUX_DESIGN.md](docs/02_UIUX_DESIGN.md) | UX/UI 설계 — 시뮬레이터 게임 레퍼런스·토큰·화면맵·HUD·UX 라이팅 |
| [docs/03_ARCHITECTURE.md](docs/03_ARCHITECTURE.md) | 기술 아키텍처 — 스레드 모델·Rust⇄UI 계약·세션 시퀀스·안전 계층 |
| [docs/04_ACCEPTANCE_ROADMAP.md](docs/04_ACCEPTANCE_ROADMAP.md) | 웨이브 로드맵(W0~W4)·실기 게이트·장애 주입 매트릭스 |
| [docs/05_ALLY_DEV_SETUP.md](docs/05_ALLY_DEV_SETUP.md) | Ally 개발 환경 세팅·파일 전달(GitHub/microSD bundle)·Mac 원격 체크 |

## 구조

```
crates/
  df-wire/     와이어 계약 순함수 (의존 0, 골든 벡터 패리티) — W0 ✅
  ally-link/   UDP·ssh2 세션 계층 — W1
  ally-input/  gilrs + G01 동결 매핑(g01.rs 상수 ✅) + 안전 게이트 — W1
  ally-pose/   TEL2 phase → forge-core walk FK 합성 포즈 — W3
  ally-cli/    헤드리스 수용시험 — W1
  darwin-fpv/  Tauri 앱 (워크스페이스 멤버 등록은 W1) — W2
ui/            웹 프론트 (Switch 웹 콕핏 자산 1080p 스케일업) — W2
assets/        darwin.glb 등 (출처: tools/switch-pilot/web/assets) — W3
scripts/       골든 벡터 생성기 · Ally 부트스트랩(ally-bootstrap.ps1) ·
               SD 번들 생성(make-sd-bundle.sh) · Windows 빌드/패키징
```

## 빌드·테스트

```sh
# 골든 벡터 재생성 (Python 원본 df_udp.py 실행 — 결정적)
python3 app/ally/scripts/gen-golden-vectors.py

# 테스트 (macOS/Linux 호스트에서 동작 — 와이어 계층은 플랫폼 무관)
cargo test --manifest-path app/ally/Cargo.toml

# 린트 (CI 게이트와 동일)
cargo fmt --check --manifest-path app/ally/Cargo.toml
cargo clippy --manifest-path app/ally/Cargo.toml --all-targets -- -D warnings

# Windows 빌드 (W1+, Ally 실기): scripts/build-windows.ps1 참조
```

**패리티 규칙**: `tests/fixtures/` 골든 벡터는 실기 검증된 Python 원본
(`tools/switch-pilot/src/darwin_switch_agent/df_udp.py`)의 실행 결과다.
패리티 테스트가 실패하면 픽스처가 아니라 Rust 구현을 고친다 — 원본(계약)이
바뀐 경우에만 생성기로 재생성한다.

## 안전 (요약 — 전체는 PRD §7)

- E-STOP 경로(물리 B·터치·파일)에 디바운스/스로틀/확인 다이얼로그 금지
- 이동 명령 생성은 Rust 단독 — webview 프리즈가 명령 안전에 영향 불가
- 패드 단절 즉시 zero 주입 + auto-disarm; 클라이언트가 죽어도 로봇 온보드
  워치독(명령 신선도, ≤320ms 계약)이 정지시킨다
- 로봇 접근 실기 검증은 한 번에 한 세션만 (로봇 세션 경합 규칙)
