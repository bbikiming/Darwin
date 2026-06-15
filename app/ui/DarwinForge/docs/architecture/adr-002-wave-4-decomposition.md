# ADR-002: Wave 4 God Object 분할 (struct + actor 추출)

- 상태: Proposed (실행 보류 — 의존성 미충족)
- 결정자: 사이클 255 (2026-05-23)
- 의존 사이클: 239-254 (Wave 1-3 + W4.3.1/2 + 6 god method 분해 + 검증 P0 fix)
- 관련 ADR: ADR-001 (Harness DI 추상화)

## 컨텍스트

DarwinForge 의 잔존 god object 3건:

- `WalkLabSession.swift` 2,266줄 (W2.x 6 god method 분해 후도 잔존, 167 internal access surface)
- `ConnectionStore.swift` 1,935줄 (W2.8/2.9 분해 + ApsContext/RecoverContext 신규)
- `MotionStudioView.swift` 1,404줄 (W4.3.1/2 분리 후)

Critic + Test-coverage 발견 (사이클 252-254 검증 사이클):

- WalkLabSession internal access 167 members — god object 가 access level 로 shift 됨
- `@Observable` (WalkLabSession) / `ObservableObject` (ConnectionStore) 혼용 → view invalidation 영역 불일치
- 50Hz closed-loop timing 보존 검증 부재 (actor 추출 phase 위험)

## 결정

Wave 4 plan (`docs/architecture/wave-4-god-object-plan.md`) 의 18 phase 를 다음 순서로 진행.

### Order (안전도 역순)

1. **Wave 4.3 (MotionStudioView)**: 4.3.3-7 (5 phase 남음, LOW-MED)
2. **Wave 4.2 (ConnectionStore)**: 4.2.1-6 (6 phase)
3. **Wave 4.1 (WalkLabSession)**: 4.1.1-6 (6 phase)

Actor 추출 phase (4.1.4 WalkEngineRuntime, 4.2.3 TelemetryPoller) 는 동일 PR 에 묶어 50Hz / 50ms IMU 의존성을 한 번에 검증.

### Rollback Criteria (Critic 권장)

각 phase 진행 시 다음 조건 중 하나라도 위반하면 **즉시 rollback**:

- Test 회귀: 기존 baseline 미달 (현재 1,819 tests 기준)
- Build 실패: `swift build -c release` 0 errors 미달
- 50Hz freshness gate 위반: actor 추출 phase 에서 timing measurement P99 > 5ms
- Public API 의도치 않은 변경: 외부 caller 영향

### Timing Measurement Gate (HIGH risk phase 의 사전 조건)

Phase 4.1.4 + Phase 4.2.3 진입 전 필수:

1. **현재 baseline 측정**: Instruments signpost `imu_iter` / `walk_tick` P50/P95/P99 기록
2. **목표 측정**: actor 추출 후 동일 측정 → regression 없음 (P99 < 5ms)
3. **실패 시 actor 추출 보류** + 추가 분석 사이클 진입

## 대안 검토

### A. 현 상태 유지 (분할 없이)

- Pros: 회귀 위험 0
- Cons: god object 누적 → 새 feature 추가 시 코드 navigability 저하 (이미 발생 중)
- 결정: 거부

### B. 단순 sub-ObservableObject 분할 (actor 추출 X)

- Pros: 회귀 위험 낮음
- Cons: 50Hz closed-loop background 작업이 `@MainActor` 점유 → UI lag 잔존
- 결정: 거부 (Reference research 권고와 불일치)

### C. TCA (Composable Architecture) 전면 도입

- Pros: 일관된 unidirectional 흐름
- Cons: 100k LOC 전환 비용 막대, 학습 곡선
- 결정: 보류 (Wave 5+ 에서 PoC 후 재평가)

### D. 채택안 — struct + actor 추출 (composition over inheritance)

- 5 reference (WWDC 2023 session 10149, Apple Doc, Point-Free)
- `@MainActor` ViewModel ←→ `AsyncStream` ←→ `actor` Engine ←→ HardwareBus
- Phase 별 점진 진행 + rollback criteria

## 결과 예상

- 사이클 255+: 18 phase 진행 (각 1 사이클, 4.1.4 / 4.2.3 은 2 사이클)
- 총 약 20-22 사이클
- Test coverage 향상: Mock Bus + struct extraction 후 unit-level 검증 가능
- Performance 보장: timing gate 로 50Hz 영향 0 보장

## 후속 후보

1. ConnectionStore `@Observable` migration (W4.2 phase 와 병행)
2. swift-dependencies 도입 평가 (W3 / Bus / Settings DI 누적 후)
3. 모듈 분리 (`DarwinForgeUI` → `DarwinForgeWalkLab` / `DarwinForgeMotion` sub-modules) — internal access 167 문제 영구 해결

## 참고

- `docs/architecture/wave-4-god-object-plan.md` (상세 phase 정의)
- `docs/architecture/reference-research-2026-05.md` (Reference 근거)
- `docs/architecture/adr-001-harness-di.md` (선행 ADR, 같은 패턴)
- Critic review (사이클 252) — "WalkLabSession internal access 167" 발견
- Test-coverage review (사이클 252) — "50Hz freshness gate boundary 미검증" 발견 (V-P0-1 에서 fix 완료)
