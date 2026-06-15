# ADR-002 Timing Baseline 측정 가이드

> 사이클 265 (V265-1) — 검증 III critic 3차 발견 대응. ADR-002 의 timing gate
> ("actor 추출 phase 진입 전 50Hz baseline 측정 필수") 를 napkin math 가 아닌
> 실측 evidence 로 충족하기 위한 인프라.
>
> **V287-1 갱신 (2026-05-24)** — `walk_tick` baseline 1차 실측 완료. P50/P95/P99/max
> + ADR gate satisfied 여부를 `docs/architecture/baselines/walk_tick_*.json` 에 영구
> 기록. ADR-002 의 "napkin math" 상태 해소.

## 결론 (V287-1, 한 줄)

`walk_tick` P99 = **0.0205 ms** (debug build, 30초 trial) — ADR-002 의 5ms gate
대비 **99.6% headroom**. actor 추출 후 회귀 측정 시 동일 harness 재실행.

## 측정 결과 (V287-1, 2026-05-24)

| Metric | 값 (debug, 300 sample, 30s 등가) | ADR-002 gate | Pass/Fail |
|--------|-----------------------------------|--------------|-----------|
| P50    | 0.012 ms                          | —            | —         |
| P95    | 0.014 ms                          | —            | —         |
| P99    | **0.0205 ms**                     | < 5.0 ms     | **PASS**  |
| max    | 0.025 ms                          | —            | —         |
| mean   | 0.012 ms                          | —            | —         |
| stddev | 0.002 ms                          | —            | —         |

- baseline file: `docs/architecture/baselines/walk_tick_20260524-134207.json`
- harness: `Tests/DarwinForgeUITests/WalkTickBaselineHarness.swift`
- 측정 머신: darwin-arm64 (Apple Silicon dev machine)
- build config: **debug** — release build 은 unrelated `#if DEBUG` test 의존성으로
  현재 swift test 실패. 별도 cycle 에서 release 측정 재실행 필요.

## 비유

비행기 fly-by-wire 의 sensor latency 측정에 stopwatch 를 끼우는 것과 같다.
실제 비행 (실 hardware 보행) 안 해도 ground test (Instruments capture) 로
응답 시간 envelope 를 기록 → 부품 교체 (actor 추출) 전후 비교.

## 인프라 (사이클 265, V265-1)

`ConnectionStore.runImuLoop` + `WalkLabSession.tick` 에 `OSSignposter` 추가:

| Signpost interval | 위치 | 발화 주기 | 예상 budget |
|-------------------|------|-----------|-------------|
| `imu_iter` | `ConnectionStore.runImuLoop` (loop body) | 20Hz (fast) / 5Hz (slow) | < 5ms P99 |
| `walk_tick` | `WalkLabSession.tick` (facade) | 10Hz (simTimer) | < 5ms P99 |

- **subsystem**: `com.robotis.darwinforge`
- **category**: `imu_loop` / `walk_tick`
- begin/end intervals — Instruments Time Profiler 의 Custom Intervals 에서
  시각화 + filter 가능.

## ADR-002 gate 충족 기준

W4.1.4 (TelemetryPoller actor 추출) + W4.2.3 (WalkEngineRuntime actor 추출)
**진입 전** 필수 절차:

1. **현재 baseline 측정** (이 문서의 "측정 방법" 절차).
2. P50 / P95 / P99 기록 → `docs/architecture/baselines/imu_iter_<date>.json` 등.
3. **목표 측정**: actor 추출 후 동일 측정 → P99 regression 없음 (< 5ms).
4. **실패 시**: actor 추출 보류 + 추가 분석 사이클.

## 측정 방법

### Path A — opt-in XCTest harness (V287-1, **권장**)

GUI 없이 자동 trial. CI 환경에서도 동일 명령으로 reproducible.

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
DARWIN_BASELINE_RECORD=1 swift test \
  --filter 'WalkTickBaselineHarness/testRecordWalkTickP99Baseline' 2>&1 | tail -10
```

- env var 미설정 시 즉시 `XCTSkipUnless` → 일반 test suite 영향 0.
- 300 sample (= 30s @ 10Hz simTimer 등가) 측정 후 자동 JSON 저장.
- 저장 경로: `docs/architecture/baselines/walk_tick_<YYYYMMDD-HHmmss>.json`.

**release 권장**: `swift test -c release` (현재 unrelated `#if DEBUG` 의존성 fix
필요 — V287-2 후보). debug 측정은 ARC overhead 로 ~2-3x 부풀려진 floor.

### Path B — Instruments xctrace (GUI 기반 signpost capture)

실 hardware 시나리오 + simTimer dispatch overhead 까지 포함된 end-to-end 측정.

#### 1. Release build

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift build -c release
```

#### 2. Instruments launch (xctrace)

실 hardware 연결 없이도 sim 모드의 simTimer 가 자동으로 발화 → `walk_tick`
interval 측정 가능. `imu_iter` 는 bus 연결 필요 (`runImuLoop` guard).

```bash
mkdir -p traces
xcrun xctrace record \
  --template "Time Profiler" \
  --launch -- .build/release/DarwinForgeApp \
  --output traces/imu_baseline_$(date +%Y%m%d_%H%M%S).trace \
  --time-limit 30s
```

> 실 hardware 시나리오:
> 1. ROBOTIS Darwin-OP 보드 USB 연결.
> 2. App 에서 transport 연결 + 1 보행 cycle 시도.
> 3. `imu_iter` interval 이 fast (20Hz) / slow (5Hz) 양쪽 모두 capture 되도록
>    walk start/stop 1 회씩 수행.

#### 3. 분석 — Instruments GUI

1. `traces/imu_baseline_*.trace` 더블 클릭 → Instruments 열기.
2. 상단 instrument list 에서 `os_signpost` 활성 (없으면 + 버튼으로 추가).
3. Detail pane 의 **Custom Intervals** 필터:
   - `imu_iter` → IMU polling cycle 분포
   - `walk_tick` → tick facade 분포
4. **Summary**: average / P50 / P95 / P99 / max 자동 계산.

#### 4. 분석 — CLI (xctrace export)

```bash
xcrun xctrace export \
  --input traces/imu_baseline_<timestamp>.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
  > traces/imu_baseline_<timestamp>.xml
```

XML 의 `<signpost>` 노드에서 `start-time` / `end-time` 으로 duration 계산.
Python `lxml` + `numpy.percentile()` 로 P50/P95/P99 산출.

#### 5. ADR-002 5ms threshold 비교

| Metric | Threshold | Action |
|--------|-----------|--------|
| `imu_iter` P99 < 5ms | PASS | actor 추출 진행 가능 |
| `imu_iter` P99 ≥ 5ms | FAIL | 추출 보류, hot path 분석 |
| `walk_tick` P99 < 5ms | PASS | actor 추출 진행 가능 |
| `walk_tick` P99 ≥ 5ms | FAIL | tick helper 추가 분해 검토 |

## Micro-benchmark (CI 자동화)

`Tests/DarwinForgeUITests/TimingBaselineTests.swift` — XCTest `measure {}`
block 으로 throughput envelope baseline 자동 측정.

```bash
swift test --filter TimingBaseline
```

**한계**:
- CI 환경에서 absolute number 불안정 (CPU 부하 / thermal throttling 의존).
- 본 measure 는 regression smoke (envelope 가 N 배 늘어나면 즉시 발견) 용.
- ADR-002 의 "P99 < 5ms" gate 는 Instruments 수동 측정 가이드 + baseline 자동화
  못 한다는 것 명시.

**대안 — `XCTPerformanceMetric_WallClockTime` baseline**:
Xcode 의 `setBaseline` 기능으로 historical baseline 등록 시 stddev 비교 가능.
swift-package-manager 의 `swift test` 만으로는 baseline storage 없음 → Xcode
project 마이그레이션 후 활성화 검토.

## 운영 영향

- **release build overhead**: `OSSignposter.beginInterval` ~10-30ns. 20Hz × 30ns
  = 0.0001% CPU — ADR-002 의 50Hz freshness gate 영향 무시 가능.
- **debug build overhead**: 동일. signpost 는 OS-level 비활성 시 거의 zero cost.
- **Instruments capture 중**: 인터럽트 hop ~1µs/interval. 측정 자체가 일시
  perf 영향 — capture 종료 후 정상 복귀.

## Baselines (history)

baseline JSON 은 `docs/architecture/baselines/` 에 timestamped 로 누적. 각 actor
추출 phase 진입 전/후 1 trial 씩 추가 → P99 regression 가시화.

| File | interval | trial 시점 | build | P99 (ms) | gate |
|------|----------|-----------|-------|----------|------|
| `walk_tick_20260524-134207.json` | walk_tick | V287-1 baseline | debug | 0.0205 | PASS (215x headroom) |

## V286-2 SLO 재활용

본 baseline 의 P99 분포는 **Google SRE Four Golden Signals — Latency SLI** 의
정의에 그대로 매핑:

- **Service**: WalkLabSession safety loop (robot fall prevention).
- **SLI**: `walk_tick` 한 cycle 의 wall-clock latency (ms).
- **SLO**: P99 < 5ms (= ADR-002 gate, 99% error budget).
- **Error Budget**: 1% (3 sample / 300 trial) → 초과 시 actor 추출 보류 + alerting.
- **Burn-rate alert**: 1 시간 윈도우의 P99 가 5ms 초과 빈도 ≥ 5% → critical.

V286-2 의 SLO 정의 문서가 작성되면 본 section 을 reference 로 인용.

## 관련 문서

- `docs/architecture/adr-002-wave-4-decomposition.md` — line 43-49 timing gate
- `docs/architecture/wave-4-god-object-plan.md` — Phase 4.1.4 / 4.2.3 actor 추출 계획
- `docs/architecture/baselines/` — 측정 결과 JSON (V287-1 부터 영구 누적)
- `Tests/DarwinForgeUITests/TimingBaselineTests.swift` — CI 자동 envelope (smoke)
- `Tests/DarwinForgeUITests/WalkTickBaselineHarness.swift` — V287-1 opt-in harness
