# Code Coverage Baseline — 2026-05-24

## Measurement Context

| Item | Value |
|------|-------|
| 측정 시점 | 2026-05-24 07:47 KST |
| Commit SHA | `fb031ea442f32faf2f8a117088dc6847dc579f73` |
| Branch | `claude/robotis-darwin-op-setup-oyzTi` |
| Swift 명령 | `swift test --enable-code-coverage` |
| Report 도구 | `xcrun llvm-cov report` |
| 제외 패턴 | `Tests\|\.build\|Mocks` |
| 테스트 수 | **1962 tests, 0 failures** |
| 소요 시간 | 148.7초 (약 2.5분) |

---

## 전체 Coverage 결과

| 항목 | Covered | Total | Coverage |
|------|---------|-------|----------|
| **Regions** | 5,496 | 21,425 | **25.65%** |
| **Functions** | 2,186 | 8,876 | **24.63%** |
| **Lines** | 18,207 | 95,111 | **19.14%** |

> SonarQube Sonar way 기준 80% **미달** (현재 19.14%).
> 그러나 측정 자체가 확립됨 — 이후 사이클에서 증분 개선 가능.

---

## 파일 통계

| 항목 | 수치 |
|------|------|
| 전체 소스 파일 (Tests/Mocks 제외) | 277개 |
| 0% coverage 파일 | 122개 (44%) |
| 100% coverage 파일 | 30개 (11%) |

---

## Top 10: 가장 낮은 Coverage 파일 (0%이며 규모 큰 순)

이 파일들은 View 레이어 — SwiftUI body 특성상 단위 테스트 어려움.

| 순위 | 파일 | Lines | Line Coverage |
|------|------|-------|--------------|
| 1 | `DarwinForgeUI/Connection/ConnectionWizard.swift` | 3,807 | 0.00% |
| 2 | `DarwinForgeUI/WalkLab/WalkLabView.swift` | 2,837 | 0.00% |
| 3 | `DarwinForgeUI/RootView.swift` | 2,197 | 0.00% |
| 4 | `DarwinForgeUI/WalkLab/Components/FallPreventionMonitor.swift` | 2,140 | 0.00% |
| 5 | `DarwinForgeUI/Studio/StudioView.swift` | 1,930 | 0.00% |
| 6 | `DarwinForgeUI/WalkLab/Learning/WalkDataView.swift` | 1,688 | 0.00% |
| 7 | `DarwinForgeUI/WalkLab/Components/BalanceExperimentControls.swift` | 1,463 | 0.00% |
| 8 | `DarwinForgeUI/WalkLab/Trials/WalkTrialLibraryView.swift` | 1,402 | 0.00% |
| 9 | `DarwinForgeUI/Pilot/PilotCameraView.swift` | 1,381 | 0.00% |
| 10 | `DarwinForgeUI/Pilot/RemotePilotView.swift` | 1,290 | 0.00% |

---

## Top 10: 가장 높은 Coverage 파일 (100%)

| 순위 | 파일 | Lines | Line Coverage |
|------|------|-------|--------------|
| 1 | `ForgeCore/UserPoseLibrary.swift` | 65 | 100% |
| 2 | `ForgeCore/MotorSpeedProfile.swift` | 50 | 100% |
| 3 | `ForgeCore/Morphology.swift` | 30 | 100% |
| 4 | `ForgeCore/ImuFilter.swift` | 51 | 100% |
| 5 | `DarwinForgeUI/WalkLab/WalkSafetyState.swift` | 7 | 100% |
| 6 | `DarwinForgeUI/WalkLab/WalkLabSession+PersistentLog.swift` | 23 | 100% |
| 7 | `DarwinForgeUI/WalkLab/Pilot/PilotIntent.swift` | 169 | 100% |
| 8 | `DarwinForgeUI/WalkLab/Pilot/PilotAudioFeedback.swift` | 25 | 100% |
| 9 | `DarwinForgeUI/WalkLab/Pilot/KeyboardPilotMapper.swift` | 83 | 100% |
| 10 | `DarwinForgeUI/WalkLab/Learning/WalkSessionSample.swift` | 203 | 100% |

---

## 80% Gate 결과

```
FAIL: Coverage 19.14% < threshold 80%
```

예상된 결과. 이유:
1. SwiftUI View 파일 122개 (0%) — `body` property가 런타임 렌더링 의존성으로 단위 테스트 불가
2. God object 분할 진행 중 (Phase 1-10 완료, 일부 확장 미테스트)
3. 연결 레이어 (`ConnectionWizard`, `ConnectionDashboard`) 하드웨어 의존성으로 mock 부재

---

## Coverage 보강 권장 영역 (우선순위순)

### HIGH Priority — 비즈니스 로직 (단위 테스트 가능)

| 파일 | 현재 | 이유 |
|------|------|------|
| `ForgeCore/Bus.swift` | 27.81% | 핵심 메시지 버스, 이벤트 라우팅 로직 |
| `DarwinForgeUI/ConnectionStore.swift` | 61.55% | 연결 상태 관리, 8876 lines 중 616 미커버 |
| `DarwinForgeUI/WalkLab/WalkLabSession.swift` | 75.16% | 메인 세션 로직, 266 lines 미커버 |
| `DarwinForgeUI/WalkLab/WalkLabSession+Logging.swift` | 28.97% | 텔레메트리 로깅 경로 |
| `ForgeCore/MultiColorVision.swift` | 19.43% | 비전 파이프라인 |

### MEDIUM Priority — 부분 커버 (갭 보강)

| 파일 | 현재 | 추가 테스트 방향 |
|------|------|-----------------|
| `DarwinForgeUI/WalkLab/Trials/WalkTrial.swift` | 70.48% | 실패 케이스, edge case |
| `DarwinForgeUI/WalkLab/WalkLabSession+Preflight.swift` | 72.37% | 프리플라이트 실패 경로 |
| `DarwinForgeUI/WalkLab/WalkLabSession+BalanceCorrection.swift` | 64.87% | 보정 알고리즘 브랜치 |
| `DarwinForgeUI/WalkLab/Learning/WalkSessionClaudePromptV2.swift` | 57.71% | 프롬프트 생성 경로 |
| `DarwinForgeUI/WalkLab/WalkLabSession+StartCycle.swift` | 3.79% | 사이클 시작 로직 |

### LOW Priority — SwiftUI View (E2E로 커버)

- `RootView.swift`, `WalkLabView.swift`, `ConnectionWizard.swift` 등 122개 0% View 파일
- SwiftUI Preview 기반 스냅샷 테스트 또는 XCUITest로 커버하는 것이 현실적

---

## SonarQube 통과 전략

현재 19.14%에서 80%로 올리려면 구조적 접근 필요:

1. **ViewInspector 도입** — SwiftUI View 단위 테스트 가능하게 만드는 라이브러리
   - 122개 0% View 파일 커버 시 ~40%p 상승 가능
2. **ForgeCore 강화** — `Bus.swift`, `MultiColorVision.swift`, `VisionHsvPreset.swift`
3. **WalkLab 비즈니스 로직 갭 보강** — `+Logging`, `+StartCycle`, `+BalanceCorrection`
4. **SonarQube exclusion 설정** — `*View.swift`, `*Dashboard.swift` 등 순수 View를 커버리지 제외 설정 (프로젝트 정책에 따라 결정)

---

## 재측정 명령

```bash
bash scripts/coverage.sh
# 또는 임계값 변경:
COVERAGE_THRESHOLD=25 bash scripts/coverage.sh
```
