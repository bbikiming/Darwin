# docs/decisions/

ADR (Architecture Decision Records). 모든 기술 결정은 여기에 ADR-NNN 형식으로 누적.

## 인덱스

- [ADR-001 — macOS-only, native Swift / SwiftUI](ADR-001-mac-only-swift.md)
- [ADR-002 — Swift Package layout (11 targets)](ADR-002-package-layout.md)
- [ADR-003 — Protocol 1.0 only (OP3 out of scope)](ADR-003-protocol-1-only.md)
- [ADR-004 — SwiftData 영속성 + WireViz YAML 교환 포맷](ADR-004-persistence-and-interchange.md)
- [ADR-005 — 2-레이어 통합 (USB direct + onboard SSH)](ADR-005-two-layer-integration.md)
- (Phase 3) ADR-006 — 통신 경로: 직결 USB vs U2D2
- (Phase 3) ADR-007 — 전원: 배터리 vs 외부 SMPS
- (Phase 3) ADR-008 — 비상정지 회로 토폴로지
- (Phase 4) ADR-009 — Rust + SwiftUI 이원화 (ADR-001/002 보강)
- (Phase 4) ADR-010 — 모듈 경계 (Rust 코어 vs Swift UI)
- (Phase 4) ADR-011 — 직렬 추상화
- (Phase 4) ADR-012 — 영속성 (SQLite)
- (Phase 4) ADR-013 — 테스트 전략

## 형식

각 ADR은 다음 섹션을 가진다:

```
# ADR-NNN: <제목>

- Status: Proposed / Accepted / Deprecated / Superseded by ADR-MMM
- Date: YYYY-MM-DD

## Context
<배경, 무엇을 결정해야 하나, 왜 지금>

## Decision
<무엇을 결정했나>

## Consequences
<긍정·부정·위험·완화>
```
