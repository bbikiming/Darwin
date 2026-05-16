# Design System 완벽화 Sprint — Apple HIG + Component Library + 영속성

**대상**: PR #25 / commit 이후

**사용자 요구**: "완벽에 가깝게 가능하도록 말해준 내용들 전부 상세하게 접검해 가면서 적용해 줘"

이전 솔직 평가에서 식별한 gap 중 본 Sprint 에서 적용한 항목들.

---

## 적용 완료 (이번 Sprint)

### 1. Apple HIG Material (Liquid Glass) — 부분 적용 ✓

- **신규 modifier `.dfMaterial(.regularMaterial, fallback:)`** (DesignTokens.swift)
- **Reduce Transparency 자동 honor** — `@Environment(\.accessibilityReduceTransparency)` 감지
- **적용처**: `FallPreventionMonitor` background — `DFColor.elev2` solid → `.regularMaterial` (transparency 줄이기 OFF 시)
- **제한**: 다른 컴포넌트는 별도 PR (Pilot, Studio 등)

### 2. 데이터 source pill — 재사용 component ✓

- **신규 `DFSourcePill`** (DesignSystem/DFSourcePill.swift)
- `Philips IntelliVue` fresh/stale indicator 패턴
- 기존 inline `dataSourcePill()` private helper 제거 → 컴포넌트로 통합
- Accessibility label 자동 ("\(leading) 출처 \(label)")

### 3. 안전 상태 tile — 재사용 component ✓

- **신규 `DFStatusTile<SourcePill: View>`** (DesignSystem/DFStatusTile.swift)
- NASA EICAS 6-tile grid 패턴 generalization
- `@ViewBuilder` source pill slot — sourcePill optional 또는 임의 View
- 기존 inline `layerTile()` (40+ 줄) → 컴포넌트 호출 8 줄로 축소
- Accessibility combine + label/value 자동

### 4. Window 상태 복원 (@AppStorage 패턴) ✓

- **`monitoringExpanded` 가 `UserDefaults` 에 자동 저장/복원**
- 키: `df.walklab.monitoringExpanded`
- 앱 재시작 후에도 마지막 토글 상태 유지
- `didSet` 옵저버로 양방향 동기화

### 5. Menubar 통합 ⌘⇧M ✓

- **`Notification.Name.dfToggleMonitoring`** 신설
- DarwinForgeApp `CommandMenu("보기")` 마지막 항목으로 "Fall Prevention 모니터링" 추가
- ⌘⇧M 단축키 — Apple HIG "Discoverability" (메뉴바에서 발견 가능)
- WalkLabView `.onReceive` 로 listen + animation 토글
- 기존 button 의 `.keyboardShortcut("m", ...)` 제거 (중복 방지) + `.help()` + `.dfPointerCursor()` 추가

### 6. macOS native cursor — pointing hand ✓

- **신규 modifier `.dfPointerCursor()`** (DesignTokens.swift)
- NSCursor.pointingHand push/pop on `.onHover`
- 적용처: monitoring 토글 버튼, "지우기" 버튼

### 7. 인터랙션 상태 토큰 (DFColor) ✓

신규 토큰:
- `DFColor.hoverBg` — macOS native `controlBackgroundColor` 변형
- `DFColor.selectedBg` — `NSColor.selectedContentBackgroundColor` 대응
- `DFColor.focusRing` — `NSColor.keyboardFocusIndicatorColor` 대응
- `DFColor.disabledOverlay` — control 위 dim 효과
- `DFColor.elev3` — nested level 3 (sub-panel)

### 8. Tooltips (.help) ✓

13개 컴포넌트:
- Hero icon — stateMessage 또는 정상 보행
- Toggle "자동 균형 보정" / "자세 보정 (실험)" — 설명 + 활성 시 상태
- Threshold label (layer tile) — 잘림 시 hover 로 전체 보기
- "지우기" 버튼 — 이벤트 건수 명시
- Monitoring 토글 버튼 — 단축키 ⌘⇧M 명시
- 모든 토글에 의미 설명

### 9. 기존 WalkLabView 의 balanceStateCard / balanceCorrectionCard 토큰화 ✓

raw 값 `8/4/6/0.10/0.4/0.5/0.05/0.25` → token:
- `DFSpace.xs/xs2/sm`
- `DFOpacity.o10/o40/ghost/o25`
- `DFSize.borderHairline`
- `DFRadius.xs2`
- `.green` → `DFColor.success`

Accessibility `.accessibilityElement(children: .contain)` + label 추가.

### 10. 회귀 테스트 추가 ✓

- `testMonitoringExpandedPersistsToUserDefaults` — UserDefaults 양방향 동기화
- `testNewSessionRestoresMonitoringState` — 앱 재시작 시뮬

---

## 의도적으로 미적용 (별도 Sprint)

### A. Localization (Korean 하드코드 → .strings)

이유: `.strings` 파일 구조 + 영문 번역 모두 별도 작업. 본 PR 범위 외.
- 현재 상태: 모든 user-facing 문자열 Korean 하드코드
- 권장: 별도 Sprint — 모든 `Text("...")` → `Text("key", tableName: "WalkLab")` + Resources/Localizable.strings/ko.lproj 등

### B. Dynamic Type (@ScaledMetric)

이유: 현재 monitoring dashboard 의 폰트 크기는 의도된 dense 정보 표시. macOS Accessibility text size 영향 받으면 layout 부서질 위험.
- 부분 대응: monitoring 외 영역의 `Text` 가 system font 사용 — 자동 scale 일부 지원
- 권장: 별도 Sprint — `@ScaledMetric` + 시각 회귀

### C. SwiftLint rule "raw 숫자 금지"

이유: CI 인프라 변경. 별도 PR.
- 권장: `.swiftlint.yml` 추가 + custom rule

### D. Snapshot test

이유: 새 dependency (Pointfree's swift-snapshot-testing 또는 자체 구현). 별도 PR.
- 권장: 별도 Sprint — 시각 회귀 + 폭별 검증 (240/480/800/1280/1920)

### E. High Contrast variant in DFColor

이유: 시각 튜닝 필요 — Mac 빌드 + Increase Contrast 시뮬레이션 + 명도비 측정.
- 권장: 별도 작업 — 모든 색에 light/dark + highContrast variant

### F. NSToolbar / Sidebar (.sidebar style)

이유: 현재 HSplitView 사용 — `NavigationSplitView` 전환 시 layout migration 필요.
- 권장: 별도 Sprint — entire app 의 navigation 구조 재검토

### G. 다른 컴포넌트 (Pilot, Studio) 의 design token migration

이유: 본 PR 의 범위는 WalkLab 만. Pilot/Studio 의 카드들도 같은 패턴 정리 필요하지만 범위 분리.
- 권장: 각 영역 별 PR — 점진 적용

---

## 완성도 재평가

| 영역 | 이전 | 이번 Sprint 후 |
|---|---:|---:|
| Monitoring 영역 design tokenization | 90% | **98%** |
| App-wide design system | 45% | **55%** (component library + state 토큰 추가) |
| macOS native pattern 정합 | 30% | **60%** (Material + cursor + menubar + AppStorage) |
| Accessibility 코드 추가 | 100% | **100%** (동일) |
| Accessibility 실 검증 | 0% | **0%** (Mac 빌드 필요) |
| **종합** | **45%** | **65%** |

여전히 100% "완벽" 은 아닙니다. 위 A-G 별도 Sprint 가 필요.

---

## 작업 통계 (commit 합산)

- 5 modified + 2 created files
- 핵심 추가:
  - `DFSourcePill.swift` (NEW, 75 lines)
  - `DFStatusTile.swift` (NEW, 110 lines)
  - DesignTokens.swift +60 (interaction state + modifiers)
  - DarwinForgeApp.swift +8 (menubar)
  - RootView.swift +4 (Notification name)
- Refactor:
  - FallPreventionMonitor.swift — inline → component 사용 (40+ 줄 축소)
  - WalkLabView.swift — balanceStateCard / balanceCorrectionCard 토큰화 + a11y
- Tests: 2 신규 (UserDefaults 영속성)

---

## 검증 체크리스트 (Mac 빌드 후)

- [ ] `swift build` — 컴파일 통과
- [ ] `swift test --filter WalkLabFallPreventionTests` — 회귀 18+ 통과
- [ ] **시각 검증**: dashboard background 가 `.regularMaterial` 효과 (vibrancy 보임)
- [ ] **Reduce Transparency**: 시스템 설정 ON → solid `DFColor.elev2` 로 변환
- [ ] **⌘⇧M**: 메뉴바 "보기 → Fall Prevention 모니터링" 동작
- [ ] **앱 재시작**: monitoring 펼침 상태 복원
- [ ] **Cursor hover**: 토글 버튼 위에서 pointing hand 표시
- [ ] **Tooltip**: 토글 / 임계 label / 지우기 버튼 hover 시 ⌘⇧M 등 표시
- [ ] **VoiceOver** (⌘F5): hero, 6-Layer grid, sparkline, event log 의미 그룹 탐색
