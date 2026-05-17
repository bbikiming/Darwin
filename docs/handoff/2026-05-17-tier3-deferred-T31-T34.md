# Tier 3 Deferred — T3.1 & T3.4

**Date**: 2026-05-17
**Branch**: `feature/v1.1-walklab-fall-prevention`
**Context**: 100차 검증 종합 Round 3 (Tier 3) 마무리. 7건 (T3.8/T3.7/T3.5/T3.6/T3.3/T3.9/T3.2) 완료, 2건 (T3.1/T3.4) 별도 sprint deferral.

---

## T3.1 — WalkLabSession 1535+ LOC god object 분리

### 현황
- **WalkLabSession.swift**: 1599 LOC, **33 private symbols** (func/var/let)
- 책임 7개 통합: walk engine 제어, safety state machine, fall prediction, balance corrector, real-time motor dispatch, sim thermal, monitoring dashboard publish
- @Published properties 38개

### Defer 이유
1. **Access modifier 폭발**: private → fileprivate 또는 internal 일괄 변경 필요. extension file 분리 시 같은 module 내 다른 file 에서 private 접근 불가 → 33 symbols × 호출지 100+ = 거대 surface area 노출
2. **회귀 위험 매우 큼**: Tier-1/2 fix 들 (deinit, IMU stale gate, FallPredictor stale, busDisconnected) 이 god object 안에 안전 의존. 분리 시 fix 회귀 가능성
3. **테스트 인프라 부족**: WalkLabSession 의 race / cancel / state-transition 통합 테스트 부재 (현재는 enum/struct invariant 위주). 분리 후 회귀 자동 검출 불가

### 다음 Sprint 권장 작업
1. **Phase 1 — 테스트 인프라 강화 (선결)**: WalkLabSession injection seam 도입 (`init(engine:, store:)`) — mock 가능. 통합 테스트 30+ 케이스 추가
2. **Phase 2 — Extension file 분리**: 응집도 기준 4-5 파일
   - `WalkLabSession+Types.swift` (~400 LOC) — enum, struct
   - `WalkLabSession+WalkCycle.swift` (~500 LOC) — startWalkCycle / runWalkCycle / runContinuousWalk / preflightForWalkCycle
   - `WalkLabSession+Safety.swift` (~250 LOC) — recordSafetySample / logSafetyEvent / balance
   - `WalkLabSession+IMU.swift` (~200 LOC) — updateImuFromRealOrSim / updateSimIMU / updateMotorTempFromRealOrSim / updateSimThermal / updateFallPrediction
   - 핵심 class file (~250 LOC) — init / deinit / start / stop / tick
3. **Phase 3 — Sub-store 분리 (선택)**: WalkSafetyMonitor / WalkMotorDispatcher / WalkSimEngine 별도 ObservableObject. 양방향 binding 패턴 적용.

**예상 LOC**: ~600 (refactor + 통합 테스트 신규)
**예상 소요**: 별도 sprint 1주

---

## T3.4 — MjpegStreamingClient byte → chunk parser

### 현황
- **MjpegStreamingClient.swift**: 430 LOC
- `parseFrames`: `for try await byte in URLSession.AsyncBytes` byte-by-byte iteration
- 30fps × 50KB JPEG = **1.5M await suspensions/sec** (perf agent 추정 15-20% CPU 1 core)
- 상태 머신: seekingBoundary → readingHeaders → readingJPEG

### Defer 이유
1. **Refactor 규모**: 100+ LOC, URLSessionDataDelegate pattern + AsyncStream<Data> 전환 + nonisolated(unsafe) chunk continuation
2. **회귀 위험**: 카메라 스트림 backpressure / cancellation / 5MB Content-Length cap 보호 모두 재검증 필요
3. **ROI 불확실**: perf 추정만 있고 실측 부재. Instruments Time Profiler 측정 없이 대형 refactor 진행 위험

### 다음 Sprint 권장 작업
1. **Step 1 — 측정 evidence 수집**: Instruments Time Profiler + Allocations 로 현재 MjpegStreamingClient 의 CPU/메모리 baseline 확보
2. **Step 2 — URLSessionDataDelegate 전환**: NSObject 상속 + delegate methods 구현 + `AsyncStream<Data>` continuation
3. **Step 3 — chunk parser 재작성**: boundary search 를 chunk 경계 넘어서도 동작하도록 stateful KMP
4. **Step 4 — 측정 비교**: refactor 전후 같은 환경 측정. 20% 이상 CPU 감소 시 머지, 미만이면 revert

**예상 LOC**: ~150 (refactor + 테스트)
**예상 소요**: 별도 sprint 3-5일 + Mac 실 robot 검증

---

## 종합

T3 9건 중 7건 완료, 2건 deferral. 잔여 작업은 **dedicated sprint 1.5주** 분량 — Round 4 audit 대상.
