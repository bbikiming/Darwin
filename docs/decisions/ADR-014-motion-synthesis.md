# ADR-014: Motion Synthesis 아키텍처

- Status: Accepted (PRD-001 Draft 시점에 합의)
- Date: 2026-05-12
- Supersedes: 없음
- Related: PRD-001 [`docs/prd/motion-synthesis-v1.md`](../prd/motion-synthesis-v1.md), ADR-010 (모듈 경계), ADR-013 (테스트 전략)

## Context

Darwin Forge 는 Sprint 1~7 까지 모션 **재생·편집·임포트/익스포트** 까지 다뤘다.
다음 사용자 요구는 **"기존 모션을 reference 로 새 모션을 알고리즘적으로 생성"** 이다.
이를 위해 PRD-001 이 6개 연산자 + 4단계 안전 검증 + Claude CLI 3-track 통합을
설계했다.

병행으로 `claude/gracious-mahavira-74d8c2` 및 `claude/humanlike-motion-design`
두 worktree (둘 다 `4b5672a` 시점) 가 **`motion::bin4096` 파서**·**`safety::self_collision`
룰 기반 검증**·**`OFFICIAL_CATALOG` 임베드** 를 이미 구현했다. 합성 레이어는
이를 lower-level 빌딩 블록으로 재사용해야 한다 — 중복 구현 금지.

본 ADR 은 다음 6개 의사결정을 동결한다.

## Decision

### D1 — 모듈 위치 & 경계

```
app/core/forge-core/src/
├── motion/          (Sprint 3 + 4b5672a)  ─ MotionPage / MotionStep / bin4096 / OFFICIAL_CATALOG
├── safety/          (4b5672a)             ─ self_collision::check_page / torque_ramp
├── joint/           (Sprint 1 + 4b5672a)  ─ JointId / JointMap (좌우 페어는 synth 가 자체 정의)
└── synth/           (Sprint 9 — 본 ADR)   ─ 합성 레이어
    ├── library      ─ MotionPage + metadata 의 in-memory 라이브러리
    ├── ops/         ─ 6 연산자 (Sequence / Layer / Morph / Mutate / Mirror / Procedural)
    ├── validator/   ─ 4 단계 (Joint Limit / Velocity / SelfCollision / StaticStability)
    └── provenance   ─ 합성 결과 manifest
```

- `synth` 는 `motion::*` 과 `safety::*` 를 **단방향으로** 의존. 역방향 금지.
- `safety::self_collision` 는 raw 룰 체크. `synth::validator::SelfCollisionValidator` 는
  그 결과를 `ValidatorReport` 로 매핑하는 **thin adapter**.

### D2 — 합성 연산자 인터페이스

모든 연산자는 `synth::ops::SynthOp` trait 을 구현하고 **순수 함수**.

```rust
pub trait SynthOp {
    type Params;
    fn synthesize(&self, inputs: &[&MotionPage], params: &Self::Params)
        -> Result<Vec<MotionPage>>;
}
```

- 입력 `MotionPage` 는 borrow only — mutation 금지 (immutability 원칙).
- 출력이 7 step 초과면 `Vec<MotionPage>` 로 분할되고 `next_page` 로 chain.
- 6 연산자: Sequence / Layer / Morph / Mutate / Mirror / Procedural.

### D3 — 데이터 보존: byte-preserving 통과

- Reference 페이지의 `positions[31]` 은 raw u16 그대로 유지.
- `0x4000` (INVALID), `0x2000` (TORQUE_OFF) 등 상위 플래그 비트는 합성 시
  **보존**. 즉 `output_pos = (input_pos & FLAG_MASK) | new_position_12bit`.
- `compliance[31]` 도 raw — 합성 연산자가 명시적으로 바꾸지 않으면 그대로.
- 시간 단위는 raw (`time × 8 ms`). ms 환산은 디스플레이 / 검증 시점에만.

### D4 — 안전 검증 (V1~V4) 순서 & 거부 정책

| 단계 | 책임 | 거부 정책 |
|------|------|-----------|
| V1 Joint Limit | `synth::validator::joint_limit` | Hard fail (관절 한계 초과) |
| V2 Velocity | `synth::validator::velocity` | 75% 임계 초과 = WARN, 100% = FAIL |
| V3 Self-Collision | `safety::self_collision::check_page` wrap | rule 위반 = FAIL |
| V4 Static Stability | `synth::validator::static_stability` | CoM 이 support polygon 밖 = FAIL (margin < safety) = WARN |

- 합성 → V1 → V2 → V3 → V4 순서로 검증.
- 어느 단계든 FAIL 이면 `commit` (bin write) 거부.
- WARN 은 명시적 확인 후 진행 가능.

### D5 — 4b5672a 머지 통합 (옵션 A)

- 본 worktree (`naughty-chebyshev-713072`) 는 `synth/*` **새 디렉토리만** 추가.
- `lib.rs` 는 `pub mod synth;` **1줄 추가만** — 다른 worktree 와 add-only 머지.
- `motion/`, `safety/`, `joint/` 는 **건드리지 않는다**.
- 머지 후 `synth::library` 가 `motion::bin4096` 를 import 해 raw 로딩 담당.
- 머지 후 `synth::validator::SelfCollisionValidator` 가 `safety::self_collision::check_page`
  를 호출 (자체 휴리스틱 구현 안 함).

### D6 — Test fixture: 공식 모션 기반

- 합성 단위 테스트의 ground truth 는 **`DARwIn-OP_ROBOTIS_v1.6.0/Data/motion_4096.bin`**
  에서 직접 디코드한 6개 페이지 (1 init, 2 ok, 9 walkready, 12 rk, 13 lk, 16 stand up).
- 모듈: `synth::test_fixtures` (`#[cfg(test)]`).
- 위치·플래그 비트·compliance 모두 byte-preserving.
- Mirror 의 ground truth: `mirror(page_12_right_kick()) ≈ page_13_left_kick()`.

## Consequences

- **긍정**: lower-level 빌딩 블록을 재사용 — 중복 코드 0, 머지 충돌 최소화.
- **긍정**: 6 연산자 인터페이스가 단순 → 단위 테스트 / Claude CLI 호출 모두
  동일 trait 으로 다룬다.
- **긍정**: V3 가 thin adapter 이므로 `safety` 룰이 강화되면 자동으로 합성에도
  반영된다.
- **부정**: Mirror 가 자체 좌우 페어 상수를 가지면 `joint/map.rs` 와 두 군데
  유지보수. 머지 후 `JointId` enum 으로 단일화 예정 (PRD §17.2).
- **부정**: byte-preserving 원칙 때문에 합성 결과 위치 값에서 상위 플래그를
  명시적으로 제거/추가하는 로직이 모든 연산자에 필요 — 공통 helper 가
  Sprint 9-2 에서 추가될 것.
- **위험**: 4b5672a 의 `MotionPage` 가 schedule 등 새 필드를 추가하면 fixture
  코드 수정 필요. 머지 시점에 회귀 테스트 9개로 즉시 검출 (`synth::test_fixtures::tests`).

## Notes

- 본 ADR 은 PRD-001 §14 의 D1~D8 결정과 정합. PRD 가 product spec, ADR 이
  engineering decision 이라는 관례에 따른다.
- 변경 시 superseding ADR 을 신설하고 본 ADR 의 Status 를 `Superseded` 로 갱신.
