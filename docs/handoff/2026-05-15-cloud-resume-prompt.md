# 클라우드/새 환경에서 DarwinForge 작업 이어가기 — handoff 프롬프트

**시점**: v1.0.0 release 완료 (2026-05-15, squash commit `eddb5b4`)
**대상**: GitHub Codespaces / Claude Web (Code Interpreter) / 다른 Mac / Codex CLI
**목표**: 새 환경에서도 동일 컨텍스트로 v1.1 작업 이어가기

---

## 빠른 시작 (Mac 로컬 / Codespaces)

```bash
# 1. 저장소 clone
git clone https://github.com/bbikiming/Darwin.git
cd Darwin

# 2. v1.0 안정 마일스톤 확인
git checkout v1.0.0    # 또는 main HEAD (eddb5b4)
git log -1 --oneline

# 3. Mac 빌드 + 설치 (macOS 14+ 필요)
bash scripts/install-app.sh

# 4. Rust + Swift test 검증
cd app/core && cargo test       # 349 통과 기대
cd ../ui/DarwinForge && swift test    # 223 통과 기대
```

---

## Claude / Codex 새 세션 시작 프롬프트 (복붙용)

다음 블록을 새 Claude/Codex 세션 첫 입력으로 붙여넣으면 v1.0 컨텍스트 + v1.1 계획
이 한 번에 로드됩니다:

````markdown
# DarwinForge — v1.1 작업 시작

## 프로젝트 개요

ROBOTIS DARwIn-OP 휴머노이드 로봇 원격 조종 + 모션 합성 + 보행 시각화 Mac 앱.
저장소: `https://github.com/bbikiming/Darwin`

## 현재 상태 (2026-05-15 기준)

- **v1.0.0 release 완료** — squash commit `eddb5b4`, GitHub Release tag `v1.0.0`
- Codex 4-pass audit (19건) 모두 처리 + 회귀 가드 lock-in
- Rust 349 + Swift 223 test 통과
- 모든 변경이 ROBOTIS 공식 source (motion_4096.bin / Action.h / Walking.cpp /
  Camera.h / ColorFinder.h) 와 1:1 정합

## 핵심 파일 위치

| 영역 | 경로 |
|---|---|
| Mac UI | `app/ui/DarwinForge/Sources/DarwinForgeUI/` |
| Mac core (Swift) | `app/ui/DarwinForge/Sources/ForgeCore/` |
| Rust core | `app/core/forge-core/src/` |
| Rust CLI | `app/core/forge-cli/src/` |
| Rust ↔ Swift FFI | `app/core/forge-ffi/src/lib.rs` |
| MCP server | `app/core/forge-mcp-synth/` |
| ROBOTIS firmware reference | `DARwIn-OP_ROBOTIS_v1.6.0/` (gitignored, 별도 다운로드 필요) |
| WalkLab | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/` |
| Pilot 원격 조종 | `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/` |
| 보행 진단 | `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/` |

## v1.1 roadmap

`docs/prd/v1.1-roadmap.md` — 8개 후순위 항목.

**최우선 (P0)**:
1. 실 USB HIL 검증 시나리오 — 사용자 robotis Ubuntu 환경 + 정량 OK/NG 캡처
2. `signal-hook` Ctrl+C emergency stop 도입 (motion_play.rs:341 placeholder 제거)

**중요 (P1)**:
3. raw motion chain replay (motion_play.rs trapezoid) — Action.cpp:271-683 의
   PRE/MAIN/POST/PAUSE section 재구현
4. ROBOTIS Walking.cpp 8 ms realtime loop — IMU closed-loop 포함

## 작업 워크플로우

1. `docs/prd/v1.1-roadmap.md` 에서 항목 선택
2. `git checkout -b feature/v1.1-<name>` (main 에서)
3. Plan first (3+ 파일 변경 예상이면 `/plan` 또는 계획 단계)
4. 구현 + 단위 테스트 (TDD)
5. `bash scripts/install-app.sh` 로 로컬 검증
6. Codex 검수 받기 (`docs/handoff/2026-05-14-motion-code-audit-claude-prompt.md`
   같은 방식의 자기 평가 + 외부 검수)
7. PR → squash merge → 누적 후 `v1.1.0` tag

## 안전 / 코딩 원칙

- ROBOTIS 공식 source 와 다른 인덱싱 / 상수는 **즉시 정정** (v1.0 의 Codex audit
  19건이 모두 이런 사례 처리)
- 모든 회귀를 unit test 로 lock-in (옛 잘못된 동작 부활 시 즉시 fail)
- 사용자 화면에 "작동하는 척" 표시 금지 — 실패는 정직하게 surface
- 한국어 응답 (사용자 = UI/UX 기획자, 개발 전문성 낮음)

## 첫 작업 제안

위 P0 중 하나를 골라 시작:
- "실 HIL 검증 시나리오 도와줘 — 단계별 절차 + 캡처 양식 만들어줘"
- "signal-hook 도입해서 motion_play 의 Ctrl+C 처리 실제 구현해줘"

또는 `docs/prd/v1.1-roadmap.md` 전체 보고 우선순위 재논의.
````

---

## 환경별 추가 안내

### GitHub Codespaces

```bash
# Codespaces 는 Linux — Swift macOS UI 빌드 불가.
# Rust 측 (forge-core / forge-cli / forge-ffi) 만 작업.
cd app/core && cargo test    # 정상 작동
```

Mac UI 작업은 사용자 Mac 으로 PR 받아 진행 권장.

### Codex CLI (`codex` 또는 `gemini-codex`)

```bash
codex "@docs/prd/v1.1-roadmap.md 보고 P0 의 signal-hook 항목 구현해줘"
```

### Claude Web / Claude Code 새 세션

위 "Claude / Codex 새 세션 시작 프롬프트" 블록을 그대로 붙여넣고 시작.

---

## 컨텍스트 보존 자료

- **v1.0 PR body** (PR #22): 9 commits 의 누적 변경 요약
- **GitHub Release v1.0.0**: 사용자 화면 기능 표 + 검증 결과
- **Codex audit 누적**: `docs/handoff/2026-05-14-motion-code-audit-claude-prompt.md`
- **v1.1 roadmap**: `docs/prd/v1.1-roadmap.md`
- **firmware reference**: `DARwIn-OP_ROBOTIS_v1.6.0/Framework/include/Action.h` 등
  (별도 ROBOTIS 다운로드)

## 자주 보는 명령

```bash
# Mac 빌드 + 설치
bash scripts/install-app.sh

# Mac 앱 실행
open '/Applications/DarwinForge.app'

# 빌드 캐시 정리
rm -rf app/ui/DarwinForge/.build app/core/target

# 테스트 전체
cd app/core && cargo test
cd ../ui/DarwinForge && swift test

# 특정 테스트
cd app/ui/DarwinForge && swift test --filter WalkMotionLibraryTests
cd app/core && cargo test -p forge-core motion::

# git status (긴 hash 회피)
git log --oneline -5
git log v1.0.0..HEAD --oneline
```

## 로봇 측 셋업 (사용자 작업)

```bash
# robot 의 VNC 터미널에서 한 번만:
# (마스터 셋업 = SSH + forge-bridge 5530 + df-inbox 모두 영구 등록)
# Mac 앱 ⌘1 → 마스터 셋업 → 명령 복붙
```

---

**필수 사용자 액션** (새 환경 시작 시):
1. ROBOTIS firmware reference (`DARwIn-OP_ROBOTIS_v1.6.0`) 다운로드 — gitignored
2. `git clone https://github.com/bbikiming/Darwin.git`
3. `git checkout v1.0.0` 으로 안정 상태 확인 후 새 작업 branch 분기

문제 발생 시 GitHub Issue 등록 또는 `docs/handoff/` 의 최근 작업 보고 참조.
