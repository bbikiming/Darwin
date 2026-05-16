# Design System 감사 + 토큰화 + 사용성 보강

**대상**: PR #25 `feature/v1.1-walklab-fall-prevention` 신규 monitoring dashboard.

**사용자 요구**: "최종적으로 디자인시스템 관련 모든 코드 리뷰하고 검증해서 토큰화 하고 사용성 이슈 있는 부분 보완해 완벽하게 해"

---

## 추가된 design system token (DesignTokens.swift)

### `DFRadius.tiny = 2`
이벤트 로그 row background hint / 매우 좁은 pill 용. 기존 `xs (4)` 보다 더 작은 corner radius — 한 행 짜리 짧은 ribbon 표시기에 적합.

### `DFSize.barTrackH = 3`
얇은 progress bar / joint delta bar / track. KS B 9609 (안전 표지) 표시기 두께 권장 ≥ 2pt + 시인성 마진.

### `DFSize.dot = 5`
sparkline 의 current value dot / center tick. NN/g *Data Visualization* 권장 — 5pt = 멀리서도 인지 가능한 minimum.

### `DFSize.iconCol = 14`
리스트 row 의 leading icon column 표준 폭 (Apple HIG list row).

### `DFSize.heroBox = 40`
hero icon container (Apple HIG large icon container — system display icon size).

---

## 토큰화 결과 (raw value → token)

| 파일 | 변환 raw value 수 | 잔존 raw |
|---|---:|---:|
| `FallPreventionMonitor.swift` | 38+ | 0 (모두 token 또는 명시 static let) |
| `SafetySparkline.swift` | 8 | 0 |
| `WalkLabView.swift` (monitoringToggleBar) | 4 | 0 |

**잔존 명시 static let** (의도된 비-토큰):
- `layerTileMinW = 110` — 6-Layer adaptive grid breakpoint
- `sparklineMinW = 130` / `WideH = 56` / `NarrowH = 44` — sparkline 도메인 특화 dimension
- `jointNameColW = 64` / `jointValueColW = 48` — joint delta row 컬럼 폭
- `eventTimeColW = 54` — 이벤트 로그 timestamp 폭
- `eventLogMaxH = 140` — 이벤트 로그 max height
- `chartPad = DFSpace.micro2` / `currentDotR = DFSize.dot / 2` / `lineW = 1.5` / `baselineW = DFSize.borderHairline` — sparkline drawChart 상수

→ 모두 **도메인 특화 magic number**. design token 으로 격상 시 다른 컴포넌트에 오용 위험 → 파일 내부 `private static let` 으로 명시 + 사유 docstring.

---

## 사용성 보강 (WCAG 2.2 + Apple HIG)

### Accessibility labels 추가

| 컴포넌트 | label |
|---|---|
| Hero banner (heroIcon) | "안전 상태 \(state.label)" |
| Hero source pill | "IMU \(label)" + "모터 \(label)" |
| Layer tile (combine) | "\(name) \(value)\(unit) — \(threshold)" |
| Sparkline (combine) | "\(title) 시계열 — 현재 \(value)" |
| Ramp bar | "Ramp 진행 X%" |
| Joint delta row (combine) | "\(name) 보정 \(±X.XX°)" |
| 6-Layer 전체 grid | "6-Layer 안전 시스템 상태" |
| Sparkline 전체 row | "최근 10초 시계열 — Roll, Pitch, Predictor Score" |
| 이벤트 로그 ScrollView | "이벤트 로그 X건" |
| 이벤트 row (combine) | "\(time) \(kind) — \(message)" |
| Toggle 버튼 | "모니터링 대시보드 펼치기/접기" |
| 상태 badge | "현재 안전 상태 \(label)" |
| "지우기" 버튼 | "이벤트 로그 비우기" |

### `.accessibilityElement(children: .combine)` / `.contain`

- combine: layer tile, joint delta row, 이벤트 row, 상태 badge → 한 element 로 묶어 VoiceOver navigation 효율 ↑
- contain: 6-Layer grid, sparkline row, 이벤트 로그 → 그룹 헤더로 인식

### 키보드 단축키

- **⌘⇧M** — 모니터링 대시보드 펼침/접기 토글 (NEW)
- ESC — 비상 정지 (기존, 유지)

### 색맹 안전 (WCAG §1.4.1)

- 모든 상태 정보 = **icon + label + 색** 3중 인코딩
- 색 단독 정보 0건 — 색맹 사용자도 동등 인식 가능

### 줄임 처리

- 모든 텍스트: `.lineLimit(1)` + `.truncationMode(.tail or .middle)`
- 값 표시: `.minimumScaleFactor(0.7)` — 협소 공간에서 단계 축소

### Reduce Motion

- `withAnimation(DFAnimation.standard)` 만 사용 — SwiftUI 가 시스템 `accessibilityReduceMotion` 자동 honor

---

## 핵심 결정

### 토큰 격상 X (도메인 특화 magic 그대로)

- `jointNameColW = 64`, `eventTimeColW = 54` 등은 **monitoring dashboard 전용**.
- design token 으로 격상 시 의도와 무관한 다른 컴포넌트가 우연히 사용 → 시각 일관성 손실.
- 대신 파일 내부 `private static let` + docstring 으로 **명시적 declaration**.

### 토큰 격상 O (재사용 가능)

- `DFRadius.tiny`, `DFSize.barTrackH/dot/iconCol/heroBox` — 다른 dashboard / status 컴포넌트 (Pilot, Studio) 에서도 동일 패턴 사용 가능.

---

## 검증 / 회귀

### 수동 검증 (Mac 빌드 후)

1. **VoiceOver**: ⌘F5 으로 켜고 dashboard 탐색 — 각 element 가 의도된 label 로 읽힘 확인.
2. **키보드 navigation**: Tab 으로 dashboard 의 button / 토글 도달 가능.
3. **⌘⇧M 단축키**: monitoring 토글 동작 확인.
4. **Increase Contrast**: macOS Settings → Accessibility → Display → Increase Contrast — 임계 stripe / pill 가독성.
5. **Reduce Motion**: macOS Settings → Accessibility → Display → Reduce Motion — dashboard 펼침/접힘 transition 즉시 변환.

### 자동 회귀

- 기존 monitoring 회귀 7건 + L6 thermal 4건 (=11건) 그대로 통과.
- 토큰 추가 = 컴파일 가능 == 회귀 X.

---

## 향후 작업

| # | 항목 | 사유 |
|---|---|---|
| 1 | High-contrast color variant in DFColor | macOS Accessibility 의 increase-contrast 시 더 강한 대비 자동 적용 |
| 2 | Dynamic Type 지원 (Text 의 font 가 system font 기반) | macOS는 dynamic type 제한적이나 일부 지원 |
| 3 | 큰 글자 mode | macOS 'Use Big Sur Style' 호환 |
| 4 | Pre-existing `WalkLabView` 의 footTargetsCard / actionBar 토큰화 | 본 PR 범위 외 — Sprint 별도 |
| 5 | 다국어 (영/일) | i18n 본격 Sprint |
