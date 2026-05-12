# Sprint 6 — Vision & Strategy MVP

## 요약

`forge-core::vision` (Frame, Pixel, HSV, blob detection) + `forge-core::strategy` (FSM 5상태) + `forge strategy` CLI 시뮬레이션. 73 tests pass. 카메라 캡처는 Mac AVFoundation에 위임 (forge-core는 알고리즘만).

## 핵심 산출물

### 신규 모듈

- `forge-core/src/vision/frame.rs`
  - `Pixel` (RGBA + HSV 변환 — atan2 기반 색상환)
  - `Frame` (width/height + Vec<Pixel>, solid 생성, get/set)
- `forge-core/src/vision/segmentation.rs`
  - `HsvRange` (h_min/max wrap-around 지원, s/v floor)
  - `HsvRange::ROBOCUP_BALL` (주황 0..30°), `ROBOCUP_GOAL_YELLOW` (40..70°)
  - `BlobResult` (pixel_count + centroid x/y) + `NONE` 상수 + `found()`
  - `detect_blob(&Frame, HsvRange)` — 모든 매칭 픽셀의 무게중심
- `forge-core/src/strategy/mod.rs`
  - `StrategyState` (Idle / LookingForBall / ApproachingBall / Kicking / Cooldown)
  - `StrategyInput` (ball: BlobResult, since_kick_ms, abort)
  - `next(input)` 결정성 전이
  - `is_close_enough(ball)`: pixel_count > 1000 (320x240 기준 ~1.3%)
  - `label()` UI/CLI용 한국 부재 (영문 — 식별자)

### CLI

```sh
forge strategy --ball=found
```

출력 (실 실행):
```
== Strategy FSM 시뮬레이션 ==
  ball: pixel_count=1120  centroid=(39.5,23.5)
  step 0  Idle                 → Looking for Ball
  step 1  Looking for Ball     → Approaching Ball
  step 2  Approaching Ball     → Kicking
  step 3  Kicking              → Cooldown
  step 4  Cooldown             → Looking for Ball
  step 5  Looking for Ball     → Approaching Ball
```

이로써 5단계 FSM 사이클이 한 커맨드에 통째로 시뮬레이션됨.

### 검증

| 항목 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ |
| `cargo test --workspace` | ✅ **73 / 73 PASS** (Sprint 5 59 + Sprint 6 +14) |
| `cargo clippy -- -D warnings` | ✅ |
| `cargo fmt --check` | ✅ |
| `forge strategy --ball=found` | ✅ FSM 사이클 정상 |
| `forge --help` | ✅ **9개 서브커맨드** 표시 |

신규 테스트 14개:
- frame: 4 (HSV red/green/blue, frame solid+modify+oob)
- segmentation: 4 (empty frame, orange centroid, low saturation reject, hue wrap)
- strategy: 6 (idle→looking, looking stable, approaching kick condition, lost ball, kicking→cooldown→looking, abort forces idle)

## 자기검증 결과

- [x] HSV 변환이 R/G/B 기본색에서 정확
- [x] Hue wrap-around (350..10) 지원
- [x] BlobResult 무게중심이 4×4 블록 중심 정확
- [x] FSM 5개 상태 모두 전이 시나리오 커버
- [x] abort 입력이 어떤 상태에서든 Idle로 강제

## 한계 (MVP)

- 카메라 캡처 미구현 — Frame은 메모리에서만 생성. AVFoundation/UVC ↔ Frame 어댑터는 Mac SwiftUI 측 후속.
- 거리 추정은 픽셀 카운트만 사용. 카메라 캘리브레이션 + 직경 기반 거리는 후속.
- FSM이 Walk/Joint 명령을 발행하지 않음 — 순수 결정 로직만. 실 액션 디스패처는 Mac 측 strategy harness에서.
- Kick 모션 자체는 motion 라이브러리에서 가져와야 함 — Sprint 4 motion::Library와 통합 후속.

## Mac에서 후속

```sh
# 카메라 → Frame 어댑터 (Swift, 별도)
# Strategy harness가 Walk/Joint 명령을 dispatch
# 실 게임 시뮬레이션
```

## Blockers

없음.

## 다음 단계 — MVP 완성

ROADMAP의 MVP 정의:
> Sprint 1 ~ 3 완성 + Sprint 4 골격 + Sprint 5/6 데이터 모델 = "고퀄리티 MVP"

✅ Sprint 1 완성 (Connection Layer)
✅ Sprint 2 완성 (Joint Control)
✅ Sprint 3 완성 (Motion I/O)
✅ Sprint 4 골격 (Motion Editor data + SwiftUI stub)
✅ Sprint 5 데이터 모델 + sim (Walk Engine MVP)
✅ Sprint 6 데이터 모델 + FSM (Vision/Strategy MVP)

**MVP 달성**. PROGRESS.md / ROADMAP.md를 갱신하고 push + PR 업데이트.
