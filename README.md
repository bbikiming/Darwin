<p align="left">
  <img src="docs/assets/logo-darwinforge.svg" alt="DarwinForge" height="80" />
</p>

<p align="left">
  <img src="docs/assets/badge-darwin-op-compatible.svg" alt="Works with DARwIn-OP / OP2" height="28" />
</p>

> macOS 전용 통합 앱: ROBOTIS DARWIN-OP (1세대 OP1 / CM-730) 와 ROBOTIS-OP2 (2세대 / CM-740) 두 대를 USB로 직접 제어하고, 모션을 설계하고, 전략을 프로그래밍한다.
>
> 핵심 스택: **Rust 코어 (`app/core/`) + SwiftUI UI (`app/ui/`)**. ADR-009~013 참조.
>
> 비공식(unofficial) 도구 — ROBOTIS와 직접 제휴 관계 없음. 자세한 브랜드 자산은 [`docs/assets/README.md`](docs/assets/README.md).
>
> *상표 고지*: "ROBOTIS", "DARwIn-OP", "DARWIN-OP" 는 ROBOTIS Co., Ltd. 의 상표이며,
> 본 앱은 해당 로봇과 함께 쓰는 **비공식 서드파티 도구**입니다. © 2026 YUSEOK KIM.

## 빠른 시작

### 사전 준비 (Mac)

```sh
# 도구 점검
bash scripts/bootstrap-tools.sh
# Mac USB-Serial 드라이버 상태
bash scripts/check-mac-drivers.sh
```

필요 도구: Xcode 15.4+, Swift 5.10+, Rust 1.78+ (MSRV; 권장 toolchain 1.94+), Python 3.11+, Node 22+, Homebrew.

### 빌드 + 실행

```sh
# Rust 코어 + cbindgen 헤더 + Vendor/ 자동 생성 + 로봇 STL 메시 동기화 + (옵션) swift build
bash scripts/build-mac.sh -u --swift

# 앱 실행
swift run --package-path app/ui/DarwinForge DarwinForgeApp

# 또는 Xcode
xed app/ui/DarwinForge/Package.swift
```

> **로봇 3D 모델 메시**: `Resources/Meshes/*.stl`(21개)은 `.gitignore` 대상이라 fresh
> clone / git worktree 에는 없다. `build-mac.sh --swift`·`build-app.sh` 가 빌드 전 자동으로
> `vendor/robotis-op2-common/meshes`(SSOT) → `Resources/Meshes` 동기화한다. Xcode/
> `swift run` 으로 직접 빌드하기 전엔 한 번 `bash scripts/sync-meshes.sh` 를 실행하라.
> 메시가 없으면 3D 뷰포트에 로봇이 안 보이고 바닥만 렌더된다.

자세한 가이드: [`docs/MAC_RUN_GUIDE.md`](docs/MAC_RUN_GUIDE.md)

### 실기기 연결

```sh
# 살아있는 모터 ID 스캔 (Sprint 1 이후 작동)
cargo run -p forge-cli -- ping --port /dev/cu.usbserial-XXXX
```

### Motion Synthesis (Sprint 9~13)

기존 ROBOTIS-OP2 16 카탈로그 페이지를 reference 로 새 모션을 합성:

```sh
# 카탈로그 조회
cargo run -p forge-cli -- synth library list

# Right Kick 좌우 미러링
cargo run -p forge-cli -- synth mirror 12 --new-id 100 --name lk_synth --out /tmp/lk.json

# walkready → kick → walkready 시퀀스
cargo run -p forge-cli -- synth sequence 9 12 9 --base-id 200 --out /tmp/routine.json

# 4-stage validator 실행
cargo run -p forge-cli -- synth validate /tmp/routine.json --single-foot-ok

# 실 robot 송출 (기본 dry-run — `--engage` 로 활성)
cargo run -p forge-cli -- motion play --slot 100 --bin path/to/motion_4096.bin
```

명세: [`docs/prd/motion-synthesis-v1.md`](docs/prd/motion-synthesis-v1.md) · [`docs/reports/SPRINT_9_10_12_REPORT.md`](docs/reports/SPRINT_9_10_12_REPORT.md) · [`docs/reports/SPRINT_13_REPORT.md`](docs/reports/SPRINT_13_REPORT.md) · [`docs/HARDWARE_VERIFICATION_PROTOCOL.md`](docs/HARDWARE_VERIFICATION_PROTOCOL.md)

### Claude Code 통합 (Sprint 12)

`.claude/commands/synth.md` + `.claude/agents/motion-composer.md` + `.claude/settings.json` 로 Claude Code 에서 `/synth <자연어>` 슬래시로 호출. MCP 서버 `forge-mcp-synth` (11 tools) 자동 spawn.

### 최근 (2026-06)

- **FPV 조종 탭**: 전문가 탭에서 ROG Ally FPV 데모를 런칭(`app/ally/`, Tauri 2). 설계 `app/ally/docs/`.
- **iOS 컴패니언 릴레이**: `app/mobile/DarwinForgeMobile/` 가 WebSocket 릴레이로 콕핏 텔레메트리/조종을 Mac 앱에 중계 (walk 10Hz throttle·conflation).

자세한 한 달치 진행은 [`PROGRESS.md`](PROGRESS.md) 2026-06 항목 참조.

## 디렉토리 구조

```
Darwin/  (리포 루트 — README가 'claude-forge/'로 잘못 표기)
├── README.md                    이 파일
├── PROGRESS.md                  살아있는 진행 상태 (단계별 체크박스)
├── ROADMAP.md                   전체 로드맵 (Phase 0..5 + Sprint 1..13 + 2026-06 확장 Wave 트랙)
├── BLOCKERS.md                  현재 막힘 항목
├── CONTRIBUTING.md              브랜치·커밋·하드웨어 안전
├── LICENSE                      Apache 2.0
│
├── docs/
│   ├── architecture/            모듈 경계, 워킹·관절·센서 명세
│   ├── protocols/               Dynamixel 1.0/2.0, CM-730/740
│   ├── motion-format/           .mtn / Page / Step 분석
│   ├── harness/                 하네스 이론 (engineering-foundations, data-model)
│   ├── decisions/               ADR-001..014
│   └── reports/                 PHASE_N_REPORT.md, SPRINT_N_REPORT.md
│
├── research/                    오픈소스 자료 아카이브 (Phase 1)
│   ├── SURVEY.md                상위 조사 보고서
│   ├── INDEX.md                 표 카탈로그
│   ├── EXTERNAL_LINKS.md        외부 링크
│   ├── papers/REFERENCES.bib
│   ├── robotis-official/
│   └── community/
│
├── vendor/                      외부 코드·문서 vendoring
│   ├── LICENSES.md              라이선스 누적 기록
│   └── reference/               ROBOTIS-OP-Series-Data PDF, framework headers
│
├── harness/                     실제 BOM·결선·테스트 (Phase 3)
│   ├── op1/
│   ├── op2/
│   └── shared/
│
├── app/                         앱 본체
│   ├── core/                    Rust 코어 (forge-core/) — Phase 4
│   ├── ui/DarwinForge/          SwiftPM 패키지 (3 products: App/ForgeCore/UI · 6 targets)
│   ├── motion-engine/           Sprint 3·4
│   ├── walk-engine/             Sprint 5
│   ├── tests/                   통합·시나리오 + fixtures
│   ├── ally/                    ROG Ally FPV 앱 (독립 Cargo workspace, Tauri 2)
│   ├── mobile/DarwinForgeMobile/ iOS 컴패니언 (WebSocket 릴레이)
│   ├── icon/                    앱 아이콘 자산
│   └── 스토어 스크린샷/          App Store 제출용 스크린샷
│
├── tools/                       switch-pilot(앱)·switch-appliance(봉인 어플라이언스)
├── firmware-patches/            walklab-brokerage(온보드 C++)·tools(실기 벤치 py)
│
├── motions/                     캡처·생성된 모션 라이브러리
│
└── scripts/                     자동화 (bootstrap, drivers, probe, build-release)
```

## 진행 상태

[`PROGRESS.md`](PROGRESS.md) 참조. 사용자 승인 모드: **한 번 승인 후 끝까지 자율** (2026-05-09).

## 라이선스

[Apache 2.0](LICENSE) — ROBOTIS upstream framework와 동일.
