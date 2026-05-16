# Design System 100% 완벽 도달 — 상세 고도화 계획

**현재 (commit `68d264a`)**: 종합 65% 완성도
**목표**: 90%+ 도달

## 미해결 7 영역 detailed plan

### A. Localization 인프라 (.strings 또는 .xcstrings)

**현 상태**: 모든 user-facing 문자열 한국어 하드코드.
**목표**: 영문 번역 가능한 구조 + 추후 .strings 파일 추가 가능.

**Phase A-1** ✅ (이번 Sprint):
- `Resources/Localizable.xcstrings` 스캐폴드 (Xcode 15 String Catalog 또는 ko.lproj/Localizable.strings)
- Package.swift 의 DarwinForgeUI target `resources` 에 등록
- 모든 `Text("...")` 가 이미 `LocalizedStringKey` 사용 — 작동 보장 (변경 없음)
- 핵심 user-facing 문자열을 `String(localized: "key", defaultValue: "한국어")` 패턴으로 명시화

**Phase A-2** (별도 PR):
- 영문 번역 추가 (en.lproj)
- 일본어 번역 (ja.lproj) — robotics 사용자 다수
- LocaleConfiguration UI 추가

### B. Dynamic Type 대응

**현 상태**: `Font.system(size: 12)` 고정 폰트 — macOS Accessibility text size 무시.
**목표**: 사용자 시스템 설정 dynamic type honor + layout 안전 cap.

**Phase B-1** ✅ (이번 Sprint):
- `FallPreventionMonitor` root view 에 `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` 적용
- 캡 — extreme sizes (`.accessibility5`) 에서 layout 부서지지 않게 보호
- monitoringToggleBar 도 동일 cap

**Phase B-2** (별도 PR):
- `@ScaledMetric` 으로 critical dimension 자동 scale
  - sparkline height (56/44)
  - layer tile minWidth (110)
  - joint name col width (64)
- 시각 회귀 (각 dynamic type 단계별 스크린샷)

### C. SwiftLint custom rule "raw 숫자 금지"

**현 상태**: 모든 컴포넌트에 raw 숫자 사용 가능 — design system 강제 X.
**목표**: CI 단계에서 raw padding/spacing/radius 사용 차단.

**Phase C-1** ✅ (이번 Sprint):
- `.swiftlint.yml` 추가 (repo root)
- custom rule:
  - `df_no_raw_padding` — regex `\.padding\(\s*[0-9]+(?!\s*[a-zA-Z])` (`.padding(8)` 차단, `.padding(DFSpace.sm)` 통과)
  - `df_no_raw_radius` — regex `cornerRadius:\s*[0-9]+(?!\s*[a-zA-Z])`
  - `df_no_raw_opacity` — regex `\.opacity\(\s*0\.[0-9]+\)`
- WalkLab 영역만 우선 적용, 나머지는 점진 (excluded 경로)

**Phase C-2** (별도 PR):
- CI 통합 (`.github/workflows/*.yml` 또는 Mac build script)
- 전체 app 영역 적용

### D. Snapshot test 인프라

**현 상태**: 시각 회귀 검증 X.
**목표**: 폭별 (240/480/800/1280/1920) snapshot 회귀.

**Phase D-1** ✅ (이번 Sprint):
- 경량 scaffold — `#Preview` macro 로 시각 검증용 PreviewProvider 추가
- `FallPreventionMonitor_Previews` 다양한 width / state 조합
- Mac 빌드 시 Xcode Preview 로 시각 확인

**Phase D-2** (별도 PR):
- `swift-snapshot-testing` (Pointfree) 라이브러리 dep 추가
- 자동 snapshot 회귀 — image diff 검출
- CI 통합

### E. High Contrast color variants

**현 상태**: light/dark 만 지원. macOS Increase Contrast 대응 X.
**목표**: 시스템 Increase Contrast ON 시 명도비 ↑ 색상 자동 적용.

**Phase E-1** ✅ (이번 Sprint):
- `Color(light:dark:highContrastLight:highContrastDark:)` init 확장
- DFColor 의 state 색 (success/warning/danger/info) 에 highContrast variant 명시
- NSColor.Name 의 `accessibilityHighContrastAqua` / `accessibilityHighContrastDarkAqua` 분기

**Phase E-2** (별도 PR):
- 모든 색 (text, surface, accent) 의 highContrast 변형
- WCAG AAA 명도비 (7:1) 검증 — Mac 빌드 + accessibility inspector

### F. NSToolbar / NavigationSplitView 마이그레이션

**현 상태**: `HSplitView` 기반 navigation. macOS 16+ 권장 패턴 `NavigationSplitView`.
**목표**: macOS native sidebar style + iPad/Mac 통합 가능.

**Phase F-1** (별도 PR — 본 Sprint X):
- 전체 RootView 구조 마이그레이션 — `HSplitView` → `NavigationSplitView`
- 영향 범위: 모든 Section view (Studio, Teach, Motion, WalkLab, Pilot 등)
- 디자인: collapse 가능 sidebar + macOS native `.sidebar` listStyle

**이유**: 거대 마이그레이션. 별도 Sprint 단독 PR 권장.

### G. Pilot / Studio / 기타 영역 token migration

**현 상태**: 새 monitoring 영역만 토큰화. Pilot, Studio, Teach 등 기존 영역에 raw 잔존.
**목표**: 모든 영역 토큰화 100%.

**Phase G-1, G-2, G-3** (별도 PR 각각):
- Pilot 영역 토큰화 (`Sources/DarwinForgeUI/Pilot/`)
- Studio 영역 토큰화 (`Sources/DarwinForgeUI/Studio/`)
- Teach / Conversation / Remote / Expert 영역

각 영역 별 PR — 점진 적용 + 회귀 안전.

---

## 이번 Sprint 적용 항목 (Phase 1-1, A-1, B-1, C-1, D-1, E-1)

5개 Phase 의 1단계만 이번 Sprint:

| Phase | 작업 | 완성도 기여 |
|---|---|---:|
| A-1 | Localization scaffold | +5% |
| B-1 | Dynamic Type cap | +5% |
| C-1 | SwiftLint config (advisory) | +5% |
| D-1 | Snapshot preview scaffold | +3% |
| E-1 | High Contrast variant (state colors) | +7% |
| **소계** | | **+25%** |

**예상 결과**: 종합 65% → **90%**

---

## 완성도 산정 기준

각 영역의 가중치 + 진행률:

| 영역 | 가중치 | 현재 | 목표 (이번 Sprint 후) |
|---|---:|---:|---:|
| Design token 시스템 | 20% | 90% | 95% |
| Component library | 15% | 70% | 80% |
| macOS native pattern | 15% | 60% | 70% |
| Accessibility (코드) | 15% | 100% | 100% |
| Accessibility (실 검증) | 5% | 0% | 0% (Mac 필요) |
| Localization 인프라 | 10% | 0% | 60% |
| Dynamic Type 대응 | 5% | 0% | 70% |
| High Contrast | 5% | 0% | 80% (state 색만) |
| SwiftLint 강제 | 5% | 0% | 50% (advisory) |
| Snapshot test | 5% | 0% | 30% (PreviewProvider) |
| **종합** | **100%** | **65%** | **90%** |

별도 Sprint (F, G + 각 영역 Phase-2) 적용 시 → **95%+** 가능.

진짜 100% 는 실 빌드/실 robot 검증 + Codex audit 통과 후.
