# Architecture Reference Research — 2026-05-23

> 출처: knowledge cutoff 2026-01 기반 reference 조사. 핵심 출처(WWDC session 번호, Swift Evolution proposal, GitHub repo URL)는 원본 확인 권장.

## 핵심 권고 5선

1. **God Object 분할 — 진행 중 방향 유지 + actor 분리 병행**
   - WalkLabSession Phase 7-10 split 패턴이 best practice (composition over inheritance)
   - 단순 sub-ObservableObject 분할에 그치지 말고 백그라운드 동작은 `actor` 추출
   - Pattern: `@MainActor ViewModel ←→ AsyncStream ←→ actor Engine ←→ HardwareBus`
   - 근거: WWDC 2023 "Discover Observation in SwiftUI" (session 10149), WWDC 2024 session 10169

2. **`@Observable` 매크로 점진 도입**
   - 신규 코드는 `@Observable` 우선, View가 실제 read 한 keypath에만 의존 → fine-grained tracking
   - 1,764줄 MotionStudioView 같은 큰 View 의 불필요 리렌더 비용 감소
   - 조건: macOS 14+ deployment (DarwinForge 확인 필요)

3. **Swift Testing 신규 도입 (점진)**
   - 기존 1788 XCTest는 유지. 신규 테스트만 `@Test`, `#expect`
   - Hardware preflight 시나리오 → `@Test(arguments:)` parametric 활용

4. **Hardware bus → AsyncStream 표준화**
   - 다중 입력 (키보드/게임패드/음성/Tello state) → 모두 `AsyncStream` normalize
   - Backpressure: `bufferingNewest(N)` 또는 swift-async-algorithms `throttle`
   - Cancellation: actor `stop()` → 자식 Task cancel → `withTaskCancellationHandler`

5. **패턴 통일 — MV 정리, TCA 보류**
   - 100k LOC 전면 TCA 도입 비권장 (ROI 낮음)
   - ObservableObject → `@Observable` + composition 분할이 현실적 path
   - TCA는 새 격리 feature 1개에서 PoC 후 평가

## DarwinForge 적용 우선순위 매핑

| Reference 권고 | DarwinForge 대상 | Wave |
|---|---|---|
| God object 분할 + actor 분리 | WalkLabSession 2599줄 → State/Engine/CommandBus | Wave 4 |
| Harness.shared singleton 제거 | Harness DI protocol + Environment 주입 | Wave 3 |
| @Observable migration | 33 @Published 파일 점진 | Wave 5 |
| AsyncStream normalize | 다중 pilot 입력 5종 | Wave 5 |
| Swift Testing 신규 | 향후 신규 테스트 | 점진 |

## 5개 follow-up 연구 질문

1. DarwinForge의 실제 macOS deployment target 확인 — `@Observable` 채택 결정
2. 50Hz 자이로 루프의 jitter 허용치 실측 — soft vs hard real-time 결정
3. swift-async-algorithms ABI 안정성 점검
4. Snapshot testing macOS 다국어/dark mode 매트릭스 비용
5. swift-dependencies 단독 도입 (TCA 없이) 평가

## 정직성 노트

본 환경에서 web 도구 미가용. Knowledge cutoff (2026-01) 까지의 지식 기반.
의사결정 전 핵심 출처 원본 확인 권장.
