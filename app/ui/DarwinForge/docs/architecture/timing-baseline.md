# ADR-002 Timing Baseline 측정 가이드

> 사이클 265 (V265-1) — 검증 III critic 3차 발견 대응. ADR-002 의 timing gate
> ("actor 추출 phase 진입 전 50Hz baseline 측정 필수") 를 napkin math 가 아닌
> 실측 evidence 로 충족하기 위한 인프라.

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

### 1. Release build

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift build -c release
```

### 2. Instruments launch (xctrace)

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

### 3. 분석 — Instruments GUI

1. `traces/imu_baseline_*.trace` 더블 클릭 → Instruments 열기.
2. 상단 instrument list 에서 `os_signpost` 활성 (없으면 + 버튼으로 추가).
3. Detail pane 의 **Custom Intervals** 필터:
   - `imu_iter` → IMU polling cycle 분포
   - `walk_tick` → tick facade 분포
4. **Summary**: average / P50 / P95 / P99 / max 자동 계산.

### 4. 분석 — CLI (xctrace export)

```bash
xcrun xctrace export \
  --input traces/imu_baseline_<timestamp>.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
  > traces/imu_baseline_<timestamp>.xml
```

XML 의 `<signpost>` 노드에서 `start-time` / `end-time` 으로 duration 계산.
Python `lxml` + `numpy.percentile()` 로 P50/P95/P99 산출.

### 5. ADR-002 5ms threshold 비교

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

## 관련 문서

- `docs/architecture/adr-002-wave-4-decomposition.md` — line 43-49 timing gate
- `docs/architecture/wave-4-god-object-plan.md` — Phase 4.1.4 / 4.2.3 actor 추출 계획
- `Tests/DarwinForgeUITests/TimingBaselineTests.swift` — CI 자동 envelope
