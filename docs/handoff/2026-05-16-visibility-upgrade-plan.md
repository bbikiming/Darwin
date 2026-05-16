# Dashboard 시인성 (Visibility) 분석 + 기획

**대상**: PR #25 — FallPreventionMonitor 의 시각화 컴포넌트들.

**사용자 요구**: "대시보드, 그래프 등등 시각화 정보들의 시인성을 올려줄 수 있는 방안을 기획해서 구현해 줘"

---

## 1. 현 상태 분석

### 강점 ✓
- ISA-101/NASA EICAS 패턴 적용 — 검증된 디자인
- ISO 7010 색 매핑 (success/warning/severe/danger)
- WCAG 색맹 안전 (icon + label + 색 3중)
- High Contrast variant 자동 적용

### 약점 (시인성 측면)
| # | 컴포넌트 | 약점 |
|---|---|---|
| 1 | Sparkline | y-axis 라벨 X — 값 의미 모호 |
| 2 | Sparkline | 임계선 표시 X — zone stripe 만 (사용자가 정확히 어디가 22°인지 모름) |
| 3 | Sparkline | 트렌드 (↑↓) 미표시 — 현재 값만 |
| 4 | Sparkline | empty 상태 X — 첫 로딩 시 빈 영역만 |
| 5 | Sparkline | line trace 단일 색 — area fill 없어 trend 강조 약함 |
| 6 | Hero banner | 상태 전환 시 즉시 변환 — 시각 cue 약함 |
| 7 | Hero banner | emergency 시 시각 강조 X — 그냥 빨강만 |
| 8 | Layer tile | 시계열 미니뷰 X — 현재값만 |
| 9 | Joint delta bar | threshold tick mark X — 5°/10° 어딘지 모름 |
| 10 | Event log | severity 시각 cue 좌측 stripe X — 색만 (텍스트와 분리 X) |
| 11 | Event log | 최신 이벤트 강조 X — scroll 시 위치 모호 |

---

## 2. 기획 — 시인성 강화 11 항목

### A. Sparkline (5 개선)
1. **Y-axis 임계 라벨**: 차트 우측 가장자리에 "30°" "22°" "15°" 라벨
2. **임계 라인 그리기**: zone stripe 위에 thin dashed line (22°, 28°, 30°)
3. **Area fill (gradient)**: line 아래 채움 — lineColor opacity gradient (macOS Stocks 패턴)
4. **트렌드 화살표**: 차트 title 옆 ↑/→/↓ 표시 (최근 N sample 의 회귀 slope)
5. **Empty state**: sample 0개 또는 < 2개 시 "데이터 수집 중..." 라벨

### B. Hero banner (2 개선)
6. **상태 전환 animation**: stateColor / icon 변경 시 `.transition(.opacity.combined(with: .scale))` smooth fade
7. **Emergency pulse**: danger/emergency 시 hero icon 박스에 subtle pulse glow (DFAnimation.emphasis 활용)

### C. Layer tile (2 개선)
8. **Mini sparkbars**: L3 Tilt / L4 Predictor 의 최근 N sample 을 super-mini sparkline 으로 tile 안에 embed (NN/g "Bullet Graph" 영감)
9. **Active state indicator**: tile color 가 threshold 초과 시 좌측 가장자리에 가는 pulse line

### D. Joint delta bar (1 개선)
10. **Threshold tick marks**: bar 위에 ±5°/10° tick mark — 사용자가 보정 magnitude 즉시 비교

### E. Event log (1 개선)
11. **Severity stripe + newest 강조**: 각 row 좌측에 severity 색 stripe (3pt) + 최신 row 에 subtle bg highlight + fade-in animation

---

## 3. 우선순위 (impact × effort)

| 우선순위 | 항목 | impact | effort |
|---|---|---|---|
| **P0** | 1. Y-axis 임계 라벨 | high | low |
| **P0** | 2. 임계 라인 그리기 | high | low |
| **P0** | 5. Empty state | high | low |
| **P0** | 11. Severity stripe + newest 강조 | high | low |
| **P1** | 3. Area fill gradient | high | medium |
| **P1** | 4. 트렌드 화살표 | medium | low |
| **P1** | 10. Threshold tick marks (joint) | medium | low |
| **P2** | 6. 상태 전환 animation | medium | low |
| **P2** | 7. Emergency pulse | medium | medium |
| **P3** | 8. Mini sparkbars in tile | high | high (별도 component) |
| **P3** | 9. Active state indicator | low | medium |

이번 sprint: P0 + P1 (총 7 개선). P2/P3 별도 PR.

---

## 4. UX 레퍼런스

| 영감 | 출처 |
|---|---|
| Area fill below line | Apple Stocks app, NYT data viz |
| Threshold line + label | NASA PFD attitude indicator, Boeing EICAS |
| Trend arrow | Apple Health/Fitness 트렌드 카드 |
| Severity stripe | Philips IntelliVue alarm log left bar |
| Newest highlight | Twitter/X 새 트윗 fade-in |
| Empty state | NN/g *Empty States* 가이드 |
| State transition | Material Design *Motion* — content morph |
| Emergency pulse | Tesla Model S 경고 시 dashboard pulse |

---

## 5. 구현 계획

### Phase A (P0): SafetySparkline 강화
- y-axis 우측 가장자리에 임계 라벨 (small monospace)
- 임계 라인 dashed (0.5pt) 우측 끝부분 짧게
- Empty state: 라벨 + 회색 placeholder

### Phase B (P1): SafetySparkline + area fill + 트렌드
- Area fill: lineColor opacity gradient (top: 0.3, bottom: 0)
- 트렌드: 최근 3 sample 의 평균 slope → ↑↓→ Image (title 우측)

### Phase C (P1): Joint delta tick marks
- ±5°/10° tick mark (1pt vertical line) 위에 small label

### Phase D (P0): Event log severity stripe
- 각 row 좌측에 3pt vertical stripe (severity 색)
- 최신 1개 row 에 subtle bg highlight + ease-in fade animation

총 4 phase 신규 구현. 5 컴포넌트 (sparkline / joint bar / event log) 영향.

---

## 6. Verification

각 개선 후:
- Mac 빌드 시 시각 확인 (PreviewProvider 시나리오 추가)
- Reduce Motion ON → animation 자동 disable 확인
- Increase Contrast ON → 추가 강조 효과
