# app/tests/

통합 테스트. Rust 단위 테스트는 각 크레이트의 `tests/`에 둔다 — 여기는 **앱-레벨 시나리오**.

## 디렉토리

- [`fixtures/`](fixtures/) — 캡처된 직렬 트레이스, 골든-마스터 모션, WireViz YAML 등 (Phase 1에서 일부 정리됨)
- (Phase 5) `integration/` — Rust + Swift 통합 시나리오
- (Phase 5) `e2e/` — 실기기 또는 시뮬레이터 모드의 끝-끝 테스트

## 실행

Mac에서:
```sh
# Rust 단위 + 통합
cargo test --workspace
# Swift
swift test --package-path app/ui/DarwinForge
```
