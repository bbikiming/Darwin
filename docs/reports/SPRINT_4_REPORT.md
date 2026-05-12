# Sprint 4 — Motion Editor (data model + scaffold)

## 요약

Motion 편집의 데이터·로직 레이어 (timeline 보간, library) 완성. SwiftUI MotionEditorView 스켈레톤. 50 tests pass. 실시간 재생/캡처 명령은 Sprint 5에서 walk loop 위에 자연스럽게 얹음.

## 핵심 산출물

### 신규 모듈

- `forge-core/src/motion/timeline.rs`
  - `Easing` enum: Linear / SmoothInOut / EaseIn / EaseOut. `apply(t)` 0..1 → 0..1.
  - `interpolate(from, to, t, easing)` — 31-슬롯 단위 보간된 `MotionStep`.
  - `sample_at_ms(steps, ms, easing)` — 페이지의 elapsed_ms 시점의 자세를 윈도우 단위로 계산. play_ms()와 pause_ms()를 모두 진행.
- `forge-core/src/motion/library.rs`
  - `MotionRecord` (id, name, motion, source_mtn)
  - `Library` in-memory (HashMap, upsert/get/remove/list/len)
  - SQLite 백엔드는 Sprint 4 후속에서 (`forge-core::db`).

### SwiftUI

- `app/ui/DarwinForge/Sources/DarwinForgeUI/MotionEditorView.swift` — NavigationSplitView 스켈레톤. 페이지 목록 + 빈 디테일. FFI 후 채움.

### 검증

| 항목 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ |
| `cargo test --workspace` | ✅ **50 / 50 PASS** (Sprint 3 43 + Sprint 4 +7) |
| `cargo clippy -- -D warnings` | ✅ |
| `cargo fmt --check` | ✅ |

신규 테스트 7개:
- timeline: 5 (easing endpoints, linear midpoint, smooth midpoint, sample within segment, sample after end)
- library: 2 (upsert/get, list sorted)

## 자기검증 결과

- [x] 4개 easing 모두 endpoint 0/1 정확
- [x] 선형 / smoothstep 중간점 정확
- [x] sample_at_ms는 segment 경계 통과 후 마지막 step 반환
- [x] Library가 id 알파벳 순으로 list

## Mac에서 후속 (사용자)

```sh
# SwiftUI 스켈레톤 컴파일 확인
xed app/ui/DarwinForge/Package.swift
# Run scheme = DarwinForge → MotionEditorView 진입
```

## 한계

- forge motion play/capture는 Sprint 5의 walk loop와 함께 (8 ms tick 인프라 필요).
- SQLite 백엔드는 ADR-012 스키마를 Sprint 4 후속 사이클에서 추가.

## 다음 단계

**Sprint 5 — Walk Engine MVP** 즉시 자율 시작:
- `forge-core/src/walk/params.rs` — `param.yaml` 1:1 복사한 `WalkParams`
- `forge-core/src/walk/engine.rs` — phase 시스템, sin파 발 궤적, 20관절 시퀀스 출력 (가짜 IK 단순 매핑으로 시작)
- `forge-core/src/walk/imu.rs` — complementary filter
- `forge walk start --x 0 --y 0 --a 0 [--port]` CLI
- 단위 테스트: 시간 따라 phase 진행, 명령 amplitude=0이면 정지 자세
