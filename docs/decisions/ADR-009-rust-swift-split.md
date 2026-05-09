# ADR-009: Rust + SwiftUI 이원화 (ADR-001/002 보강)

- Status: Accepted
- Date: 2026-05-09
- Supersedes part of: ADR-002 (순수 Swift 11-target 안)

## Context

ADR-001은 macOS 전용으로, ADR-002는 Swift 11-target 패키지로 결정했었다. 그러나 사용자 프로토콜 §8은 다음을 요구한다:

- 코어 (Dynamixel 통신, 모션 엔진, 워크 엔진, 비전): **Rust**
- UI: **SwiftUI**
- 영속성: SQLite

Rust로 코어를 두는 이유:
1. **단위 테스트 용이성** — 시리얼 백엔드를 가짜로 swap, 컨테이너에서 cargo test 통과
2. **재사용성** — 미래에 CLI / 임베디드 / Linux 시연 도구로 확장 가능
3. **메모리 안전 + 성능** — 8 ms tick의 실시간 컨트롤 루프
4. **Cargo 패키지 관리** — Rust ecosystem의 검증된 직렬·SQLite·argparse 크레이트

## Decision

코어는 Rust, UI는 SwiftUI. 두 층은 **C-ABI로 연결**하거나, 빌드 시 Swift Package가 Rust staticlib을 임포트하는 방식으로 결합 (ADR-010에서 상세).

ADR-002의 Swift 11-target 안은 **UI 레이어로 축소**:
- 도메인 (RobotKit, HarnessKit) 일부는 Rust로 이전, 나머지는 Swift wrapper
- 인프라 (DynamixelKit, SerialPortKit)는 **Rust로 완전 대체**
- 응용 (PersistenceKit, OnboardSyncKit, WireVizBridge)은 Swift 유지
- UI (DarwinForgeUI, DarwinForgeApp, DarwinForgeCLI)는 그대로

## Consequences

- **긍정**: 컨테이너에서 `cargo test`로 코어 검증 가능. Swift 미설치 환경에서도 코어 발전 가능.
- **긍정**: forge-cli (Rust)가 Mac이 아니더라도 작동 — Linux 데스크탑에서도 ping 가능.
- **부정**: Mac에서 두 빌드 시스템(cargo + xcodebuild). 통합 빌드 스크립트 (`scripts/build-release.sh`) 필요.
- **위험**: Swift ↔ Rust C-ABI는 reference counting / async 호환 문제. ADR-010에서 명시적 boundary 정의.

## 변경된 ADR-002 부분

ADR-002의 11-target 중:
- `SerialPortKit`, `DynamixelKit` → **삭제** (Rust forge-core가 대체)
- `RobotKit`, `HarnessKit` → 데이터 모델만 Swift로 유지, 실제 로직은 Rust 호출
- `OnboardSyncKit`, `PersistenceKit`, `WireVizBridge` → 그대로 (Swift)
- `DarwinForgeUI`, `DarwinForgeApp`, `DarwinForgeCLI` → 그대로

ADR-002의 의의는 "도메인과 인프라를 분리한다"는 모듈 경계 원칙이므로 그 정신은 ADR-010에서 계승.
