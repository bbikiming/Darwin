# ADR-013: 테스트 전략

- Status: Accepted
- Date: 2026-05-09

## Context

3개 환경:
- **컨테이너 (이 자리)**: Rust 빌드/테스트 가능, Swift 미설치, 실기기 X
- **Mac 개발**: 모두 가능
- **Mac + 로봇**: 통합 테스트 (사용자 수동)

## Decision

### 4가지 테스트 등급

| 등급 | 위치 | 환경 | 실행 |
|------|------|------|------|
| 1. **순수 unit** (Rust) | `app/core/forge-core/src/` 내 `#[cfg(test)] mod tests` | 컨테이너 + Mac | `cargo test --lib` |
| 2. **integration** (Rust) | `app/core/forge-core/tests/` | 컨테이너 + Mac, LoopbackBus | `cargo test --test '*'` |
| 3. **Swift unit** | `app/ui/DarwinForge/Tests/` | Mac만 | `swift test` |
| 4. **e2e (실기기)** | `app/tests/e2e/` | Mac + 로봇 | 사용자 수동 + `forge` CLI 스크립트 |

### 커버리지 목표

- 1·2 등급 합쳐: **70% 이상** (cargo llvm-cov로 측정, Sprint 1부터)
- 3 등급: 새 코드만 (기존 SwiftUI 스냅샷은 Mac에서 느슨)
- 4 등급: 사용자 매뉴얼 시나리오 5개 (ping → joint slider → motion replay → walk start → vision)

### CI

- 컨테이너 CI(가상): `cargo fmt --check && cargo clippy -D warnings && cargo test`
- 사용자 Mac은 별도 (`scripts/build-release.sh` 안에 swift test 호출)

### Mock 전략

- `LoopbackBus` — DynamixelKit (Rust)
- `MockClock` — Walk engine 시간 의존성
- `MockShell` — OnboardSyncKit (이미 ADR-005에서 명세)
- 실 SQLite + `:memory:` — 영속성 (mock 없이 진짜 SQLite 사용)

## Consequences

- **긍정**: 우리가 컨테이너에서도 코어 변경에 대한 회귀를 즉시 검출.
- **긍정**: 사용자가 Mac에 swift만 깔면 3등급도 통과 — 통합 검증 가능.
- **부정**: 4등급은 자동화 어려움 — 사용자가 매번 수동.
- **위험**: 1·2등급이 통과해도 실기기에서 실패 가능 (FTDI latency 등). 매 스프린트 보고서에 "실기기 검증 필요" 명시.
