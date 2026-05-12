# Sprint 3 — Motion Import/Export

## 요약

`forge-core::motion` 모듈로 `.mtn` ↔ JSON 양방향 변환. 31-슬롯 페이지 데이터 모델, 텍스트 파서/라이터, 무손실 round-trip 단위 테스트, 2-page sample fixture, `forge motion import/export/inspect` CLI 모두 작동. 43 tests pass.

## 핵심 산출물

### 신규 모듈

- `forge-core/src/motion/page.rs` — 데이터 모델
  - `MotionStep` (31-slot positions + pause/play time, `pause_ms()`/`play_ms()` 환산)
  - `MotionPage` (id, name 14ch, compliance[31], next_page/exit_page/repeat/speed/accel, steps Vec)
  - `Motion` (version, robot_generation, pages Vec, JSON 직/역직렬화)
- `forge-core/src/motion/parser.rs` — `.mtn` 텍스트 파서
  - `page_begin/page_end` block 처리
  - `id`, `name`, `compliance`, `play_param`, `step` 라인 인식
  - `#` 주석 + 빈 라인 무시
  - 9개 `ParseError` enum (UnmatchedPage, StepArity, ComplianceArity, PlayParamArity, IntParse, BadLine)
- `forge-core/src/motion/writer.rs` — `Motion` → `.mtn` 텍스트
  - `parse_mtn(write_mtn(m)) == m` round-trip 단위 테스트

### Fixture

- `app/core/forge-core/tests/fixtures/sample-2page.mtn` — 2-page (Stand Up + Wave) 실제 파싱 가능 샘플

### CLI

```sh
forge motion import sample.mtn --generation op2  # → sample.json
forge motion export sample.json                  # → sample.mtn
forge motion inspect sample.mtn                  # 페이지 요약
forge motion inspect sample.json                 # JSON도 같은 inspect
```

### 검증 e2e (컨테이너에서 직접 실행)

```
$ forge motion inspect /tmp/sample.mtn
== /tmp/sample.mtn ==
  version            : 1
  robot_generation   : op2
  pages              : 2
---
  page id=  1 name=Stand Up             steps=2 next=2 exit=0 repeat=1 speed=32
  page id=  2 name=Wave                 steps=4 next=0 exit=0 repeat=2 speed=32

$ forge motion import /tmp/sample.mtn --generation op2
imported /tmp/sample.mtn → /tmp/sample.json (2 pages)

$ forge motion export /tmp/sample.json --output /tmp/sample-rt.mtn
exported /tmp/sample.json → /tmp/sample-rt.mtn (2 pages)

$ diff /tmp/sample.mtn /tmp/sample-rt.mtn
1,2d0    # 주석 라인만 차이 (의도적 — round-trip은 의미 있는 데이터만)
< # DarwinForge sample motion — 2 page (Stand Up + Wave)
< # format: see app/core/forge-core/src/motion/parser.rs
25a24
>        # 마지막 빈 라인
```

### 테스트

| 항목 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ |
| `cargo test --workspace` | ✅ **43 / 43 PASS** (Sprint 2 35 + Sprint 3 +8) |
| `cargo clippy -- -D warnings` | ✅ |
| `cargo fmt --check` | ✅ |
| e2e: import → export round-trip | ✅ (주석/trailing whitespace 외 동일) |

신규 테스트 8개:
- page: 3 (step time 변환, JSON round-trip, page lookup)
- parser: 3 (sample parses, unmatched page, step arity)
- writer: 2 (round-trip, sample writes)

## 자기검증 결과

- [x] 31-slot positions 보존 (RoboPlus 호환)
- [x] 메타데이터 round-trip (next_page, exit_page, repeat, speed, accel)
- [x] step pause_time / play_time 보존
- [x] 주석/빈 라인 graceful 처리
- [x] CLI 3개 서브액션 작동 (import/export/inspect)
- [x] 모든 PUBLIC API에 doc comment

## 한계 (mtn-format.md TODO 미해결)

- 본 sprint의 `.mtn` 형식은 우리 정의 (RoboPlus 변형). 진짜 RoboPlus `.mtn`은 약간 다를 수 있음 (라벨 차이, EUC-KR 인코딩 등).
- 사용자가 실 RoboPlus `.mtn` 파일을 제공하면 fixture에 추가하고 parser를 보강 (Sprint 4 또는 별도 사이클).
- `motion_4096.bin` 바이너리 포맷은 Sprint 5 (walk engine 시작 직전) 별도.

## Blockers

없음.

## 다음 단계

**Sprint 4 — Motion Editor 데이터 모델 + SwiftUI 스켈레톤** 즉시 자율 시작:
- `forge-core/src/motion/timeline.rs` — 키프레임 보간 (선형, 쿠빅, 이징)
- `forge-core/src/motion/library.rs` — 모션 라이브러리 (in-memory + SQLite 백엔드 인터페이스)
- `forge-core/src/db/mod.rs` — SQLite 스키마 (rusqlite, migration v1)
- `forge motion play --port --id <page>` (실기기 재생 — Mac에서 검증)
- `forge motion capture --port` (현재 자세를 키프레임으로)
- SwiftUI 측: `app/ui/DarwinForge/Sources/DarwinForgeUI/MotionEditorView.swift` 스켈레톤
