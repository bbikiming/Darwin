# Phase 0 — Bootstrap

## 요약

워크스페이스 디렉토리 트리(§2)를 강제하고, 거버넌스 파일과 도구 점검 스크립트를 신규 생성. 기존 자산은 `git mv`로 이력 보존하며 새 구조로 흡수. 사용자 승인 모드는 **한 번 승인 후 끝까지 자율**.

## 핵심 산출물

### 거버넌스
- `PROGRESS.md` — Phase/Sprint 체크박스, 직전 체크포인트, 다음 단계
- `ROADMAP.md` — Phase 0..5 + Sprint 1..6 전체 일정 + MVP 정의
- `BLOCKERS.md` — 잠재 위험 항목 5개 선제 인지 (Mac 빌드, 실기기 테스트, emanual WebFetch, 펌웨어 업로드, GPL 격리)
- `vendor/LICENSES.md` — 호환성 매트릭스 + 주요 출처 사전 인덱스
- `LICENSE` — Apache 2.0 (확정)

### 디렉토리 트리 (§2 100% 일치)
- `docs/{architecture,protocols,motion-format,harness,decisions,reports}/` — 각 폴더에 README
- `research/{robotis-official,community,papers}/` — INDEX/EXTERNAL_LINKS/REFERENCES.bib 골격
- `vendor/{reference}/` — LICENSES.md + 기존 reference/ 흡수
- `harness/{op1,op2,shared}/` — 각 폴더 README
- `app/{core,ui,motion-engine,walk-engine,tests}/` — 각 폴더 README, 기존 SwiftPM 패키지는 `app/ui/DarwinForge/`에 흡수
- `motions/`, `scripts/` — README

### 스크립트
- `scripts/bootstrap-tools.sh` — required/macOS-only/optional 분류 점검, 컨테이너에서 OK 8 / WARN 5 / FAIL 0
- `scripts/check-mac-drivers.sh` — FTDI/CP210x/Apple In-Kernel 점검, Linux에서는 graceful degrade

### 이동 (`git mv`로 이력 보존)
- 5개 ADR (`docs/architecture/adr-0001~0005.md` → `docs/decisions/ADR-001~005-*.md`)
- `docs/protocol/` → `docs/protocols/`
- `docs/hardware/op1-vs-op2.md` → `docs/architecture/op1-vs-op2-matrix.md`
- `docs/research/upstream-survey.md` → `research/SURVEY.md`
- `docs/research/harness-engineering.md` → `docs/harness/engineering-foundations.md`
- `docs/harness/darwin-1g/leg-l-bus.yaml` → `harness/op1/leg-l-bus.yaml`
- `reference/` → `vendor/reference/`
- `fixtures/` → `app/tests/fixtures/`
- `DarwinForge/` → `app/ui/DarwinForge/`

## 자기검증 결과

- [x] `tree -L 2` (대체로 `find`/`ls`)가 §2 구조와 일치 — 검증
- [x] 모든 placeholder 폴더에 `README.md` 또는 `.gitkeep` 존재
- [x] `PROGRESS.md` / `ROADMAP.md` / `BLOCKERS.md` 존재
- [x] `bootstrap-tools.sh`가 컨테이너에서 무사 통과 (FAIL 0)
- [x] `check-mac-drivers.sh`가 syntax-clean (Linux에서 graceful exit)
- [x] 체크포인트 커밋 1개 (`9b2bf34 checkpoint: phase-0 - bootstrap workspace`)

## Blockers

없음. BLOCKERS.md에 적힌 5개 항목은 후속 단계의 잠재 위험 항목으로, 현재 진행 차단 요소 아님.

## 도구 점검 결과 요약

| 카테고리 | 도구 | 상태 |
|----------|------|------|
| Required | git, python3, node, cargo, rustc | ✅ 5/5 |
| Optional | jq, yq, pip3 | ✅ 3/3 |
| Optional | shellcheck, tree | ⚠️ 2개 누락 (영향 없음) |
| Mac-only | swift, xcode-select, brew | ⚠️ 컨테이너에 없음 — Mac에서 필요 |

Rust 1.94 + Cargo 1.94가 설치되어 있어 Phase 4·Sprint 1~6의 Rust 코드를 컨테이너에서 빌드·테스트 가능. Swift 코드는 작성하되 컴파일 검증은 사용자 Mac에 위임 (`docs/reports/SPRINT_N_REPORT.md`에 빌드 명령어 명시).

## 다음 단계

**Phase 1 — Discovery & Archive**를 즉시 자율 시작:
1. 시드 소스 §5.1 전수 조사 (ROBOTIS 공식·1세대·커뮤니티·학술)
2. `research/INDEX.md`에 표 카탈로그 작성
3. `vendor/LICENSES.md`에 라이선스 누적
4. `research/papers/REFERENCES.bib`에 학술 자료 추가
5. 각 발견 저장소에 `_NOTES.md` (얕은 클론은 컨테이너 네트워크 환경상 메타데이터 위주로 정리)
6. `docs/reports/PHASE_1_REPORT.md` 작성 + 체크포인트 커밋
