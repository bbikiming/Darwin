# ADR-001: Harness DI 추상화 (Singleton → Protocol + Environment)

- 상태: Accepted
- 결정자: 사이클 241-244 (2026-05-23)
- 관련 사이클: 239, 240, 241, 242, 243(예정), 244(예정)

## 컨텍스트

DarwinForge 의 텔레메트리 시스템 `Harness.shared` 는 49 파일 257 호출 사이트에서 singleton 으로 직접 호출됨. Architecture audit (2026-05-23) 의 핵심 발견:

- 테스트 가능성 4/10 — singleton 의 in-memory state 가 테스트 간 공유 → flaky
- DI 부재 — Mock harness 주입 불가 → 32 파일이 회귀 테스트 시 telemetry side effect 발생
- ISP 위반 — 90% caller 는 `record()` 만 필요한데 startHeartbeat / registerContextProvider 도 접근 가능

## 결정

3-way Protocol Split + Environment 주입 (점진 migration).

### Protocol 구조

```swift
@MainActor protocol HarnessRecording { record/bookmark/flush }
@MainActor protocol HarnessHeartbeat { startHeartbeat/stopHeartbeat }
@MainActor protocol HarnessContext { registerContextProvider }
protocol HarnessLifecycle { start/stop }
typealias HarnessFacade = HarnessRecording & HarnessHeartbeat & HarnessContext & HarnessLifecycle
```

### 3 구현

- `LiveHarness` — `Harness.shared` thin wrapper (production)
- `NoopHarness` — 테스트/preview default
- `RecordingHarness` — assertion 용 in-memory 캡처

### 주입 path

- View struct: `@Environment(\.harness) private var harness`
- Class: `init(..., harness: (any HarnessFacade)? = nil)` + body `harness ?? LiveHarness.shared`

## 대안 검토

### A. swift-dependencies (Point-Free) 도입

- Pros: 표준화된 DI infra, withDependencies { } 로 test 격리
- Cons: 새 dependency 도입, 학습 곡선, TCA 미사용 환경에서 overengineering
- 결정: 보류. 향후 다른 cross-cutting service (settings, hardware bus) 도입 시 재평가.

### B. Property wrapper @Injected

- Pros: boilerplate 적음
- Cons: 컴파일 타임 안전성 손실, debug 어려움
- 결정: 거부.

### C. Singleton 유지 + 테스트마다 mock 주입

- Cons: 기존 문제 그대로
- 결정: 거부.

## 결과

- 사이클 241 (Phase 3.1): 6 신규 인프라 파일, +432 LOC, 1814 tests (+3 회귀 가드)
- 사이클 242 (Phase 3.2): 6 caller 72 사이트 migration, +250/-76 LOC, 1819 tests (+5)
- 사이클 243 (예정 — Phase 3.3): 42 파일 batch
- 사이클 244 (예정 — Phase 3.4): deprecation + SwiftLint regex CI gate

## 후속 후보

1. Hardware bus DI 추상화 (BusFacade) — 같은 패턴
2. SettingsStore DI 추상화
3. swift-dependencies 도입 평가 (3 도메인 정도 DI 추상화 누적 후)

## 참고

- WWDC 2023 "Discover Observation in SwiftUI" (session 10149)
- swift-dependencies (Point-Free): https://github.com/pointfreeco/swift-dependencies
- docs/architecture/reference-research-2026-05.md (Wave 3 plan 근거)
