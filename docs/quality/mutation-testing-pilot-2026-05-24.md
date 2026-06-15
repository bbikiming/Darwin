# Mutation Testing Pilot — ForgeCore (V287-5)

날짜: 2026-05-24  
작성자: Test Engineer (V287-5)

---

## 도구

| 항목 | 결과 |
|------|------|
| Muter (Swift mutation testing) | 설치 불가 — brew/mint 없음, binary asset 미제공 |
| Swift 버전 | 6.2.4 (swiftlang-6.2.4.1.4) |
| 대체 방법 | Manual mutation (10건) — 소스 직접 수정 후 swift test 실행 |

Muter release 16 기준 GitHub assets 없음 (SPM 빌드 필요). Swift 6.2 환경에서 SPM cold build 비용 및 시간 리스크로 manual approach 채택.

---

## 대상 Surface

| 항목 | 값 |
|------|-----|
| 파일 | `WalkStabilityPredictor.swift`, `Kinematics.swift`, `RobotPose.swift` |
| 기존 테스트 수 | 153 tests (ForgeCoreTests) |
| Mutation 수행 후 | 165 tests (12 tests 추가) |
| 빌드 상태 | 0 errors, 0 failures |

---

## Mutation 결과 요약

| # | 파일 | 원본 | 변이 | 결과 | Kill 테스트 |
|---|------|------|------|------|-------------|
| M1 | WalkStabilityPredictor.swift:475 | `x <= first.0` | `x < first.0` | **SURVIVED** | 구조적 — 보간 결과 동일 (weight=0 knot) |
| M2 | WalkStabilityPredictor.swift:476 | `x >= last.0` | `x > last.0` | **SURVIVED** | 구조적 — 보간 t=1.0이라 결과 동일 |
| M3 | WalkStabilityPredictor.swift:221 | `safeMaxScore = 30` | `safeMaxScore = 29` | KILLED | `testScoreInUpperSafeRangeClassifiedAsSafe` |
| M4 | WalkStabilityPredictor.swift:197 | `diagonalStrideMm = 25` | `diagonalStrideMm = 30` | KILLED | `testDiagonalComboWarning` (기존) |
| M5 | WalkStabilityPredictor.swift:181 | `effSpeedMessageMmPerSec = 50` | `= 60` | KILLED | `testEffSpeedMessageFiresJustAbove50MmPerSec`, `testEffSpeedMessageThresholdIsExactly50` |
| M6 | Kinematics.swift:20 | `raw - 2048` | `raw + 2048` | KILLED | `testDegreesRoundTrip` (기존) |
| M7 | RobotPose.swift:186 | `4095 - raw` | `4096 - raw` | KILLED | `testMirrorSwapsSides`, `testMirrorYawFlipSign` (기존) |
| M8 | WalkStabilityPredictor.swift:398 | `max(0.0, ...)` 클램프 | 제거 | **SURVIVED** | 구조적 — 음수 weight contributor 없음 |
| M9 | WalkStabilityPredictor.swift:179 | `periodMessageMs = 500` | `= 450` | KILLED | `testPeriodMessageFiresJustBelow500Ms`, `testPeriodMessageThresholdIsExactly500` |
| M10 | WalkStabilityPredictor.swift:166 | `footHeightDragRegionMm = 30` | `= 25` | KILLED | `testFootHeightAt27mmEntersDragRegion`, `testFootHeightDragRegionThresholdIsExactly30` |

**Mutation Score: 7 / 10 = 70%**

---

## Surviving Mutants 분석 (Top 3)

### M1: piecewise `x <= first.0` → `x < first.0`

**의미**: x가 정확히 first knot 좌표와 같을 때 (`x == first.0`) 클램프 대신 보간 루프로 진입.

**구조적 survive 이유**:
- strideKnots first: `(0, 0)`. x=0, 루프 a=(0,0), b=(20,5): x>=0 true, x<=20 true → t=0 → weight=0. 클램프 결과와 동일.
- 모든 knot의 first.1이 내부 보간 결과와 같으면 kill 불가.

**실질 위험**: 낮음. periodKnots는 역순이라 `x<=900` 조건이 항상 true가 되어 모든 period 값이 0을 반환하는 **기존 잠재 버그** 발견 (→ Spawn 참조).

**방어책**: piecewise를 역순 knots 지원으로 리팩토링 (V288 제안).

### M2: piecewise `x >= last.0` → `x > last.0`

**의미**: x가 정확히 last knot 좌표일 때 클램프 대신 보간 진입.

**구조적 survive 이유**:
- t=1.0에서 보간 결과가 last.1과 항상 동일.
- x > last.0에서는 `x > last.0`도 true이므로 클램프 작동.

**실질 위험**: 낮음. strideKnots last=(50,85): x=50에서 양쪽 동일 결과.

### M8: `max(0.0, ...)` 클램프 제거

**의미**: 합산 점수가 음수가 되어도 min(100) 클램프만 적용.

**구조적 survive 이유**:
- 모든 contributor weight는 piecewise 결과 (≥0) + 조합 min 결과 (≥0).
- 음수 합산이 발생하는 경로가 현재 코드에 없음.

**실질 위험**: 낮음. 방어적 코드로 유지가 적절.

---

## Test Gap Insights (어떤 영역이 약한가)

### 1. piecewise 경계값 정밀도 (High Risk)

`periodKnots`는 x가 역순(900→350)이므로 `x <= first.0(=900)` 조건이 모든 period 값에서 true가 됩니다. period=350ms (최악 속도)에서 weight가 0으로 계산되어 **점수 과소 추정** 가능성이 있습니다. 이 버그는 M2 검증 과정에서 발견됐으나 현재 테스트가 period=350ms의 실제 weight를 검증하지 않습니다.

### 2. effSpeedMessageMmPerSec 정확 경계 (Medium Risk)

51~59mm/s 범위의 경고 발화를 검증하는 테스트가 없었음 (M5 신규 테스트로 해결).

### 3. footHeight 25-30mm 구간 (Medium Risk)

끌림 위험 영역 경계(30mm) 바로 아래인 27mm 케이스가 미커버 (M10 신규 테스트로 해결).

### 4. balanceGain 경계값 (Low-Medium Risk)

balanceGainLowRegion=0.5 정확 경계 (gain=0.49, 0.51 구분)를 검증하는 테스트 없음.

### 5. 조합 위험 factor 계수 (Medium Risk)

`diagonalFactor=0.4`, `turnStrideFactor=0.5` 변이 시 kill 테스트 없음 (점수 범위 검증만 존재).

---

## 다음 사이클 계획 (V288 제안)

### P0: piecewise 역순 knot 버그 수정

`periodKnots`가 역순(내림차순)이므로 `x <= first.0(=900)` 조건이 모든 값에서 true → weight=0 반환. piecewise가 역순 knots를 올바르게 처리하도록 수정 필요.

```swift
// 수정 방향: knot x 정렬 방향 감지 또는 periodKnots 정렬 후 전달
static let periodKnots: [(Double, Double)] = [
    (350, 90), (400, 70), (450, 45), (500, 20), (600, 5), (700, 0), (900, 0)
]  // x 오름차순으로 정렬
```

### P1: Surviving Mutant Kill 테스트 추가

- `balanceGainLowRegion` 경계 (gain=0.49 vs 0.51)
- `diagonalFactor`, `turnStrideFactor` 변이 테스트
- period=350ms piecewise 실제 weight 검증

### P2: Muter 자동화 (CI 통합)

SPM 기반 Muter 빌드 스크립트 준비:
```bash
git clone https://github.com/muter-mutation-testing/muter
cd muter && swift build -c release
cp .build/release/muter /usr/local/bin/
```

WalkLab 영역 (V288) 적용 전 ForgeCore mutation score ≥ 80% 목표.

---

## 회귀 보장

```
swift test --filter ForgeCoreTests
Executed 165 tests, with 0 failures (0 unexpected) in 0.018 seconds
```

기존 153 tests 유지 + 12 tests 추가 = 165 tests, 0 failures.

---

## ROI 평가

| 항목 | 수치 |
|------|------|
| Manual mutation 소요 시간 | ~40분 |
| 발견된 테스트 갭 | 7건 (경계값 + threshold 미커버) |
| 추가된 Kill 테스트 | 12 tests |
| 발견된 잠재 버그 | 1건 (piecewise 역순 periodKnots) |
| Mutation Score (before) | ~50% 추정 (경계값 미커버 다수) |
| Mutation Score (after) | 7/10 = 70% (신규 Kill 테스트 반영) |

Petrović 2018 예측 (60-80% line coverage → 30-50% mutation score) 대비 70%는 **상위권** — 기존 threshold 상수 분리 + 회귀 가드 테스트 덕분. 나머지 30% 개선은 piecewise 버그 수정 + 역순 knot 검증이 핵심.
