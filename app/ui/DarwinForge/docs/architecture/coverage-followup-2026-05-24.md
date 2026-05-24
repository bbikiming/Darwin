# Coverage Follow-up — 2026-05-24 (V275-5)

## 측정 환경

| 항목 | 값 |
|------|----|
| 측정 시점 | 2026-05-24 10:23 KST (V275-5 사이클) |
| Branch | `claude/robotis-darwin-op-setup-oyzTi` |
| Swift 명령 | `swift test --enable-code-coverage --skip PilotConcurrentStressTests` |
| Report 도구 | `xcrun llvm-cov report` |
| 테스트 수 | **2130 tests, 0 failures** (V270-1 1954 → +176 추가 from V271-V274) |
| 소요 시간 | 126.0초 |
| profdata | `.build/debug/codecov/default.profdata` |

---

## 전체 Coverage 진행 추이

| 시점 | Regions | Functions | Lines |
|------|---------|-----------|-------|
| V270-1 baseline (2026-05-24 07:47) | 25.56% | 24.57% | **19.11%** |
| V275-5 측정 (2026-05-24 10:23) | **27.21%** | **26.06%** | **21.03%** |
| Δ (V271-V274 cycle 효과) | +1.65%p | +1.49%p | **+1.92%p** |

> V273-V274 cycle 3개 (StartCycle / Bus / Logging) 가 전체 line coverage **+1.92%p** 견인.
> 단일 cycle 평균 효과: 약 +0.6%p (이미 측정된 hot file 외 0% View 파일이 dilute 시킴).

---

## 결론 먼저

**P0 (다음 cycle 즉시) ROI 최고**: `WalkLabSession+WalkCycleEngine.swift` (현재 **0.00%**, 448 line) — 단일 file 로 전체 coverage 약 **+0.47%p** 견인 가능 (448 line × 80% target ÷ 75,562 total missed lines). 동시에 safety-critical 한 walk cycle 실행 엔진 (`runContinuousWalk` / `runWalkCycle` static async).

---

## P0 (다음 cycle 즉시) — safety-critical + line% < 50%

| 순위 | File | LOC (lines) | Current Line % | Region % | Target | 이유 |
|------|------|-------------|----------------|----------|--------|------|
| **1** | `WalkLab/WalkLabSession+WalkCycleEngine.swift` | 448 | **0.00%** | 0.00% | 80% | **walk cycle 실 송출 static engine 2개 (`runContinuousWalk`, `runWalkCycle`) — `private static` 격상 후 미테스트**. Phase 4 분할 직후 회귀 0 검증만 됨. safety-critical (실 모터 송출). |
| **2** | `WalkLab/WalkLabSession+ClaudeAnalysis.swift` | 77 | **18.18%** | 17.39% | 70% | Claude CLI 분석 invoke method. 외부 process 호출이지만 input/output marshalling 은 단위 테스트 가능. |
| **3** | `ForgeCore/MultiColorVision.swift` | 247 | **19.43%** | 18.45% | 60% | 비전 파이프라인 HSV multi-color detection. safety-adjacent (장애물 회피 입력). |
| **4** | `ForgeCore/VisionHsvPreset.swift` | 177 | **23.73%** | 32.43% | 70% | HSV preset 직렬화 + threshold 검증. pure logic 다수. |
| **5** | `WalkLab/Learning/WalkSessionAutoTuner.swift` | 70 | **38.57%** | 28.26% | 75% | 자동 튜닝 로직 — 실험 결과 → 다음 파라미터 도출. safety-critical (다음 walk preset 결정). |

**P0 5개 추정 효과**: 약 +1.5%p (총 ~1,019 미커버 line 중 800 line 커버 시).

---

## P1 (이후 cycle) — 도메인 핵심 + line% < 70%

| File | LOC | Current Line % | 이유 |
|------|-----|----------------|------|
| `WalkLab/WalkLabSession+StartCycle.swift` | 581 | 50.26% (V273-1 lift) | 47% 미커버 (~289 line). safety branch 다수 잔존. |
| `WalkLab/WalkPresetCatalog.swift` | 92 | 57.61% | 42% 미커버. preset 검증 분기. |
| `WalkLab/Learning/WalkSessionClaudePromptV2.swift` | 350 | 57.71% | 42% 미커버 (~148 line). 프롬프트 generation branch. |
| `WalkLab/WalkLabSession+Logging.swift` | 435 | 84.60% (V274-2 lift) | 15% 미커버 (~67 line). 일부 에러 경로. |
| `WalkLab/WalkLabSession+BalanceCorrection.swift` | 279 | 64.87% | 35% 미커버 (~98 line). 알고리즘 분기. |
| `Connection/RemoteShell.swift` | 242 | 59.50% | 40% 미커버. SSH 통신 분기. |
| `WalkLab/Learning/WalkSessionClaudeAnalyst.swift` | 173 | 68.79% | 31% 미커버. Claude 분석 결과 파싱. |
| `WalkLab/Trials/WalkTrial.swift` | 210 | 70.48% | 30% 미커버. edge case + 실패 분기. |
| `WalkLab/BalanceExperimentConfig.swift` | 119 | 78.99% | safety-critical, 80% 도달 미달. |
| `WalkLab/WalkLabSession+SafetySampling.swift` | 117 | 78.63% (V274) | safety-critical, 80% target 1.37%p 미달. |
| `ForgeCore/Bus.swift` | 338 | 31.36% (V274-1 lift) | FFI 244 line 제외 시 ~58% — 실 robot 필요. |
| `WalkLab/StaticTiltCalibration.swift` | 155 | 87.10% | 13% 미커버. 일부 calibration 실패 분기. |

---

## P2 (View — ViewInspector Phase A/B)

규모 큰 0% View 파일 (단위 테스트 불가, E2E 또는 ViewInspector 도입 필요):

| File | LOC | 우선순위 |
|------|-----|---------|
| `Components/FallPreventionMonitor.swift` | 2,140 | A (safety-critical View) |
| `Components/BalanceExperimentControls.swift` | 1,463 | A |
| `Components/SceneSpeedometerOverlay.swift` | 1,105 | B |
| `Components/SafetyBandedSlider.swift` | 531 | A |
| `Components/SafetySparkline.swift` | 535 | A |
| `Connection/ConnectionWizard.swift` | 3,807 | B |
| `WalkLab/WalkLabView.swift` | 2,837 | B |
| `RootView.swift` | 2,197 | C |
| `Learning/WalkDataView.swift` | 1,534 | C |

**ViewInspector 도입 시 추정 효과**: 122개 0% View 파일 (총 약 30,000 line) 커버 시 **+30~40%p**.

---

## 100% 도달 hot file (V273-V274 cycle 성과 검증)

| File | V270 baseline | V275-5 측정 | Δ |
|------|---------------|-------------|---|
| `WalkLab/WalkLabSession+StartCycle.swift` | 3.79% | 50.26% | **+46.47%p** |
| `ForgeCore/Bus.swift` | 27.81% | 31.36% (regions 35.40%) | **+3.55%p** (FFI 244 line 제외 시 +7.59%p) |
| `WalkLab/WalkLabSession+Logging.swift` | 28.97% | 84.60% | **+55.63%p** |

세 file 합산 line 1354 × Δ 평균 +35.22%p → 전체 95,689 line 대비 약 +0.50%p 견인.
실측 전체 Δ +1.92%p — 나머지 +1.42%p 는 V271-V272 cycle (Phase 8 BalanceMitigation, Phase 9 SafetySampling, Phase 10 Preflight 확장 테스트) 효과.

---

## 전체 60% 도달 추정 시나리오

현재 21.03% → 60% 도달 = 약 **+39%p** 필요.

| 전략 | 예상 효과 | 누적 |
|------|----------|------|
| P0 5개 file 80% target 도달 | +1.5%p | 22.5% |
| P1 12개 file 80% target 도달 | +3.5%p | 26.0% |
| ViewInspector Phase A (safety View 9개) | +6.0%p | 32.0% |
| ViewInspector Phase B (도메인 View ~30개) | +14.0%p | 46.0% |
| ViewInspector Phase C (잔여 View ~80개) | +12.0%p | 58.0% |
| ForgeCore 잔여 (Bus FFI mock + harness) | +2.0%p | 60.0% |

**현실적 path**: P0+P1 = ~5%p (4-6 cycle), ViewInspector 도입이 필수 인플렉션 포인트.

---

## 다음 cycle 권고

**P0 #1 (`WalkLabSession+WalkCycleEngine.swift`) 즉시 진행**:

- ROI 최고 (단일 file +0.47%p, P0 5개 중 최대 견인)
- safety-critical (실 모터 송출 경로 — V275 이전 회귀 0 검증만 됨)
- pure static async — DI / harness 없이 mock servo 로 테스트 가능 (`ServoBus` mock 이미 V274-1 Bus.swift 테스트에서 사용)
- 분할 직후 (사이클 90 — 2026-05-22) 미테스트 — 기술 부채 빠르게 청산

**대안 ROI 후보**:

- `MultiColorVision.swift` (P0 #3, +0.36%p) — pure pipeline 함수 다수
- `WalkSessionAutoTuner.swift` (P0 #5, +0.05%p) — small file 이나 safety 영향 큼

---

## 재측정 명령

```bash
swift test --enable-code-coverage --skip PilotConcurrentStressTests
xcrun llvm-cov report \
  .build/debug/DarwinForgePackageTests.xctest/Contents/MacOS/DarwinForgePackageTests \
  -instr-profile=.build/debug/codecov/default.profdata \
  Sources/ | tail -10
```

**임계값 게이트** (옵션):
```bash
COVERAGE_THRESHOLD=22 bash scripts/coverage.sh  # 22% gate (현재 21.03% + 1%p buffer)
```
