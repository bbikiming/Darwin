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

## 빠른 시작

### 사전 준비 (Mac)

```sh
# 도구 점검
bash scripts/bootstrap-tools.sh
# Mac USB-Serial 드라이버 상태
bash scripts/check-mac-drivers.sh
```

필요 도구: Xcode 15.4+, Swift 5.10+, Rust 1.94+, Python 3.11+, Node 22+, Homebrew.

### 빌드 + 실행

```sh
# Rust 코어 + cbindgen 헤더 + Vendor/ 자동 생성 + (옵션) swift build
bash scripts/build-mac.sh -u --swift

# 앱 실행
swift run --package-path app/ui/DarwinForge DarwinForgeApp

# 또는 Xcode
xed app/ui/DarwinForge/Package.swift
```

자세한 가이드: [`docs/MAC_RUN_GUIDE.md`](docs/MAC_RUN_GUIDE.md)

### 실기기 연결

```sh
# 살아있는 모터 ID 스캔 (Sprint 1 이후 작동)
cargo run -p forge-cli -- ping --port /dev/cu.usbserial-XXXX
```

## 디렉토리 구조

```
claude-forge/
├── README.md                    이 파일
├── PROGRESS.md                  살아있는 진행 상태 (단계별 체크박스)
├── ROADMAP.md                   전체 로드맵 (Phase 0..5 + Sprint 1..6)
├── BLOCKERS.md                  현재 막힘 항목
├── CONTRIBUTING.md              브랜치·커밋·하드웨어 안전
├── LICENSE                      Apache 2.0
│
├── docs/
│   ├── architecture/            모듈 경계, 워킹·관절·센서 명세
│   ├── protocols/               Dynamixel 1.0/2.0, CM-730/740
│   ├── motion-format/           .mtn / Page / Step 분석
│   ├── harness/                 하네스 이론 (engineering-foundations, data-model)
│   ├── decisions/               ADR-001..013
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
│   ├── ui/DarwinForge/          SwiftPM 11-target 패키지
│   ├── motion-engine/           Sprint 3·4
│   ├── walk-engine/             Sprint 5
│   └── tests/                   통합·시나리오 + fixtures
│
├── motions/                     캡처·생성된 모션 라이브러리
│
└── scripts/                     자동화 (bootstrap, drivers, probe, build-release)
```

## 진행 상태

[`PROGRESS.md`](PROGRESS.md) 참조. 사용자 승인 모드: **한 번 승인 후 끝까지 자율** (2026-05-09).

## 라이선스

[Apache 2.0](LICENSE) — ROBOTIS upstream framework와 동일.
