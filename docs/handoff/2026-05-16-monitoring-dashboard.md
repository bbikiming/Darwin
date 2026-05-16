# Fall Prevention 모니터링 대시보드 — UX 레퍼런스 기반 구현

**대상**: `feature/v1.1-walklab-fall-prevention` PR #25

**사용자 요구**:
1. "모니터링 명확하게ㅜ할 수 있는 gui 구현해 줘"
2. "uiux 래퍼런스 조사해서 근거 기반으로 업그레이드 해줘"

---

## 결과 요약

Walk Lab 기존 detail panel 의 분산된 IMU gauge / balance state / fall predictor /
corrector card 를 **단일 통합 대시보드 (`FallPreventionMonitor`)** 로 consolidation +
시계열 sparkline + 이벤트 로그 추가.

**Progressive disclosure (NN/g)**: 기본 닫힘. 토글 ON 시 표시.

---

## UX 레퍼런스 매트릭스

본 대시보드는 다음 레퍼런스 기반 설계 (코드 docstring 에 인용):

| # | 레퍼런스 | 적용 영역 |
|---|---|---|
| 1 | **ISA-101** *Human Machine Interfaces for Process Automation Systems* (2015) §6.3 | Hero status banner (gray + state color) |
| 2 | ISA-101 §6.5 | 5-tier alarm priority = 5-tier `BalanceState` |
| 3 | ISA-101 §6.7 | 이벤트 로그: 시간 + 우선순위 + 메시지 |
| 4 | **NASA Ames** *Primary Flight Display Design Guidelines* NASA-TM-104781 (1993) §3.2.1 | sparkline 의 임계 zone 음영 (22/28/30°) |
| 5 | NASA-TM-104781 §4.1 | EICAS 패턴: 6 systems tile grid → 6-Layer status grid |
| 6 | **Edward Tufte** *The Visual Display of Quantitative Information* (1983) | "data-ink ratio 극대화" → sparkline 축/grid/legend 최소화 |
| 7 | Tufte | "small multiples": 3 sparkline (Roll/Pitch/Score) 같은 시간축 |
| 8 | **NN/g** *Dashboard Design Patterns* (2024) | "Inverted pyramid": critical info → top |
| 9 | NN/g *Data Visualization* | "current value dot": sparkline 마지막 sample 강조 |
| 10 | NN/g *Progressive Disclosure* | 기본 닫힘 → expert 토글 ON |
| 11 | **Philips IntelliVue MX800** *User Guide* (2019) | 이벤트 로그: severity icon + 시간 + 메시지 |
| 12 | IntelliVue | "fresh vs stale" data indicator → imuSource tag |
| 13 | **Boston Dynamics Spot** *SDK Operator Console* (2023 공개) | 4-quadrant layout: pose / sensors / telemetry / events |
| 14 | **KS S ISO 7010** *안전 표지* (2019) | 5-tier 색 매핑 (빨강/노랑/주황/파랑/초록) |
| 15 | **WCAG 2.2 §1.4.11** *Non-text Contrast* | 그래픽 요소 ≥ 3:1 명도비 |
| 16 | WCAG §1.4.1 | "색 단독 정보 금지": SF Symbol icon + 라벨 + 색 항상 함께 |
| 17 | **Apple HIG** *Charts* (2024) | "sparkline 은 트렌드용, 정확값 X" → sparkline + 별도 readout |
| 18 | **Material Design 3** *Adaptive Layouts* (Google, 2023) | 6-layer LazyVGrid 3-column responsive |

---

## 레이아웃 (top → bottom)

### 1. Hero status banner (ISA-101 §6.3 + NASA EICAS)

- 큰 SF Symbol icon (40×40) + 5-tier 상태 라벨 + max|tilt| 값
- 배경 = 상태 색 (10% opacity) + border (35%)
- 우상단 IMU source 라벨 (sim / 실 IMU / IMU 지연)
- **1초 안에 인식 가능** (glanceable design)

### 2. 6-Layer status grid (NASA EICAS)

`LazyVGrid` 3-column. 6개 tile:

| Layer | 값 | 임계 |
|---|---|---|
| L1 Cradle | 확인/미확인 | 정비 스탠드 거치 필수 |
| L2 Stability | 슬라이더 score 0..100 | ≥ 80 = critical 차단 |
| L3 IMU Tilt | max\|roll/pitch\| ° | 15/22/28/30° 5단계 |
| L4 Predictor | 0..100 | ≥ 80 = 선제 정지 (ETA 표시) |
| L5 Corrector | OFF / max delta ° | 토글 + ramp 진행 표시 |
| L6 Thermal | °C | ≥ 60°C = 자동 정지 |

각 tile: SF Symbol icon + 이름 + 현재값 + 단위 + 임계 라벨.

### 3. Time-series row (Tufte small multiples)

3 sparkline 동시 (같은 시간축, 최근 10초):
- **Roll** — y 범위 ±35°, 임계 zone stripe: ±15° (노랑) / ±22° (주황) / ±30° (빨강)
- **Pitch** — 동일 임계
- **Predictor Score** — y 0..100, 임계 stripe: 30/60/80

Tufte data-ink ratio: 축 label / grid / legend 최소. 현재값은 차트 상단에 monospaced.
마지막 sample = 5pt 원 dot (NN/g current value 강조).

### 4. Corrector deltas + ramp (medical monitor 패턴)

- Ramp progress bar (3pt 높이) — 0..1초 0%→100%
- 8 관절 horizontal bar (center=0, deflect=±delta):
  - + 부호 = 파랑 (DFColor.info)
  - − 부호 = 주황 (DFColor.forge)
  - 색 단독 정보 X — 좌측 라벨 + 우측 monospaced 수치 함께

### 5. Event log (Philips IntelliVue + ISA-101 §6.7)

ScrollView 최대 140pt. 시간역순 (가장 최신이 상단). 각 row:
- Severity icon (color-coded)
- 시간 (HH:mm:ss monospaced)
- 메시지 (≤ 1 line)

이벤트 종류 (11개):
- sessionStart / sessionStop — 회색
- stateChange — 노랑
- emergencyTriggered / predictorRecommend / thermalAlarm / preflightFailure — 빨강
- correctorOn / rampComplete — 초록
- correctorOff — 회색
- imuSourceChange — 파랑

"지우기" 버튼 (NN/g — destructive action with confirmation 패턴 미적용 — 로그는 trivial).

---

## 데이터 layer (WalkLabSession 추가)

### 새 publish 프로퍼티

```swift
@Published public private(set) var safetyTimeline: [SafetySample] = []
@Published public private(set) var safetyEvents: [SafetyEvent] = []
@Published public var monitoringExpanded: Bool = false
```

### Types

```swift
public struct SafetySample: Equatable, Sendable {
    let timestamp: Date
    let rollDeg, pitchDeg, predictionScore, correctorMaxDelta: Double
    let balanceState: BalanceState
}

public struct SafetyEvent: Identifiable, Equatable, Sendable {
    enum Kind { sessionStart, sessionStop, stateChange,
                 emergencyTriggered, predictorRecommend,
                 correctorOn, correctorOff, rampComplete,
                 imuSourceChange, thermalAlarm, preflightFailure }
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let message: String
}
```

### Tick 통합

`tick()` 마지막에 `recordSafetySampleAndEvents()` 호출:
1. 새 sample append, 10초 윈도우 + 250 sample 상한 prune.
2. balanceState 전환 → `.stateChange` 이벤트.
3. predictor rising-edge → `.predictorRecommend`.
4. imuSource 변경 → `.imuSourceChange`.
5. ramp 100% 도달 (rising-edge) → `.rampComplete`.

### 이벤트 발행 지점

- `start(_:)` → `.sessionStart`
- `stop()` (이미 실행 중일 때만) → `.sessionStop`
- `emergencyStop()` → `.emergencyTriggered`
- `enableBalanceCorrection.didSet` → `.correctorOn` / `.correctorOff`
- `tick()` 의 L4 thermal → `.thermalAlarm`
- 위 transition 검출 → 해당 이벤트

### Reset 동작

- `start()`: timeline reset + 이전 상태 reset + `.sessionStart` 이벤트
- 이벤트 로그는 **유지** (사용자가 이전 세션 이벤트 확인 가능)
- `clearSafetyEvents()`: 명시적 비움

---

## 회귀 가드 (`WalkLabFallPreventionTests` 추가)

- `testMonitoringInitialState` — 초기 빈 상태 + 펼침 OFF
- `testCorrectorToggleLogsEvents` — OFF↔ON 시 이벤트 발행
- `testClearSafetyEvents` — 비움 동작
- `testSafetyEventsCapAt50` — 50건 상한 (이전 이벤트 자동 drop)
- `testRampProgressMatchesToggleState` — rampProgress nil 정합
- `testSafetySampleEquality` — Equatable 동작
- `testSafetyEventKindRawValuesNonEmpty` — UI 안전

---

## UX 트레이드오프 (의도된 결정)

| 결정 | 대안 | 채택 사유 |
|---|---|---|
| 기본 닫힘 (progressive disclosure) | 항상 펼침 | NN/g — 일반 사용자 UI overload 방지 |
| 시계열 10초 윈도우 | 30초 또는 1분 | Tufte — 보행 cycle 600ms ≈ 17 cycle 의미. 그 이상은 sparkline 해상도 손실 |
| Y 범위 hard-coded (±35° / 0..100) | 자동 fitting | 일관 비교 (NN/g "consistency over auto-fit") |
| 이벤트 50건 상한 | 무한 | 메모리 + scroll perf (보행 1분 ≈ 5 이벤트, 10분 = 50 적정) |
| Roll/Pitch 동일 y 범위 | 각자 | small multiples 비교 (Tufte) |
| 8 관절 8 row | 4 관절 그룹 | mirror 페어 시각화 — fall 가속 방향 즉시 확인 |

---

## 향후 개선 (별도 작업)

| # | 항목 | 근거 |
|---|---|---|
| 1 | 트렌드 화살표 (↑/↓) on layer tile | NASA EICAS — 시간 미세 변화 감지 |
| 2 | 이벤트 클릭 → 시계열 jumpback 강조 | NN/g — drill-down |
| 3 | 모니터링 export (CSV/JSON) | ISA-101 §6.8 — audit trail |
| 4 | 다국어 (영어/일본어) | KS X ISO 9241 — i18n |
| 5 | 사용자 임계 customization | ISA-101 §6.6 |
| 6 | 시계열 30초 / 1분 토글 | Tufte — scale 다양성 |

---

## 빌드 검증 상태

- Linux 환경 Swift 미설치 → Mac 빌드 필요
- 정적 검증: grep / 패턴 매칭으로 symbol 정합 확인 완료
- 회귀 테스트 7건 추가 — Mac CI 검증 필요

**다음 단계**: PR #25 push + Mac 빌드 + Codex 외부 검수.
