# UI/UX · Design System 고도화 로드맵

작성일: 2026-05-13
작성자: Claude
대상: 다음 Sprint 구현 담당자 / Codex 리뷰어
선행 문서: `2026-05-13-uiux-design-system-audit.md` (Codex 감사)
대상 코드: DarwinForge SwiftUI 앱 (`app/ui/DarwinForge/Sources/DarwinForgeUI/**` — Swift 120 파일)

---

## 결론 (한 줄)

**디자인 시스템 토큰은 이미 충분하다 — 빠진 것은 "강제력"과 "고밀도/안전색 등 의미 팔레트"다.** 따라서 다음 4개 Sprint를 **토큰 추가 → lint 가드 → Top 5 화면 정리 → density/safety 팔레트** 순서로 풀면 raw 패턴 119건을 0건에 수렴시키면서 회귀 위험을 최소화할 수 있다.

---

## 1. 현 상태 정량 진단 (Codex 감사 + 실측 보강)

### 1.1 디자인 시스템 자체는 탄탄하다
- 토큰 파일 1,772 lines: `DesignTokens.swift(396)`, `DFComponents.swift(529)`, `GlassNeon(229)`, `KoreanUX(247)`, `StepperField(271)`, `ResponsiveBreakpoints(70)`, `ResponsiveToolbarRow(30)`
- 색상은 **KS S ISO 7010 안전 색상 표준**과 Apple HIG Liquid Glass에 정합되어 있음 (`DFColor.success/warning/danger/info/torque`)
- 폰트는 semantic alias + numeric size 이중화로 한국어 가독성 8pt 한계 명시 — 이미 성숙

### 1.2 실측: raw 패턴 분포 (DesignSystem/Visualization 제외)

| 항목 | 건수 | 비고 |
|---|---:|---|
| `RoundedRectangle(cornerRadius: <수>)` | **185** | 가장 심각. 화면 대부분이 수동 chrome 사용 |
| `cornerRadius: <정수>` 직접 호출 | 46 | |
| `.padding(<정수>)` raw 호출 | 43 | |
| `NSColor.controlBackgroundColor/windowBackgroundColor` | 12 | 다크모드 추적 어려움 |
| `Color.red/green/blue/orange/yellow/gray/secondary` | 10 | Codex 우려보다 적음 — 이미 어느 정도 정리됨 |
| **DFPanel 사용** | 20 | (양호) |
| **DFCard / dfCard 사용** | 2 | (거의 사장됨) |
| GroupBox 사용 | 4 | (소규모) |

### 1.3 Top 5 오프엔더 — 60%를 차지

| 순위 | 파일 | raw padding+radius+RR 합 |
|---:|---|---:|
| 1 | `Connection/ConnectionWizard.swift` | **32** |
| 2 | `Motion/TransportBar.swift` | 16 |
| 3 | `Remote/RemoteShellView.swift` | 14 |
| 4 | `Connection/ConnectionDashboard.swift` | 14 |
| 5 | `WalkLab/WalkLabView.swift` | 12 |
| 합계 | | **88 / 145 (60.7%)** |

→ **이 5개 파일만 정리해도 raw chrome의 60% 이상이 사라진다.** 우선순위 명확.

### 1.4 DFPageScaffold 적용 현황 — 4/11 화면 (36%)

| 화면 | Scaffold | 메모 |
|---|:-:|---|
| Expert (`ExpertDashboard`) | ✅ | |
| Teach (`TeachModeView`) | ✅ | |
| Conversation (`ConversationView`) | ✅ | |
| Remote (`RemoteShellView`) | ✅ | 내부 raw 14건 별도 |
| Studio (`StudioView`) | ❌ | |
| Motion (`MotionLibraryView`) | ❌ | |
| Pilot (`RemotePilotView`) | ❌ | |
| Joints (`JointControlView`) | ❌ | |
| Board (`BoardStatusView`) | ❌ | |
| Strategy (`StrategyView`) | ❌ | |
| WalkLab (`WalkLabView`) | ❌ | |

→ **메인 메뉴 11개 중 7개가 스캐폴드 부재** = 화면 간 "제품감" 단절의 근본 원인.

---

## 2. Codex 제안 비판적 평가

Codex 감사는 거의 모두 타당하나, 세 군데에서 우선순위와 범위를 조정한다.

| Codex 제안 | 평가 | 조정 |
|---|---|---|
| **P1. 카드 통합** (`DFPanel` 표준화) | ✅ 동의 | 그대로 — Sprint 1 |
| **P1. 구형 화면 Scaffold 도입** | ✅ 동의 | 단 `MotionLibraryView`는 macOS 14 `NavigationSplitView` 동작과 충돌할 수 있으므로 별도 단계로 분리 |
| **P1. 안전 색상 통합 (`DFSafetyColor`)** | ✅ 동의 + 강화 | 단순 alias가 아니라 **명도 차 모드/HC 모드 자동 적응 + 색각 이상 대응** 까지 포함 (KS S ISO 7010 + WCAG 1.4.11 NonText Contrast) |
| **P1. raw spacing/radius 제거** | ✅ 동의 | 단 "토큰 승격" 위주 — 의도 없는 일괄 치환은 회귀 위험 |
| **P1. 버튼/칩 컴포넌트화** | ⚠️ 부분 동의 | Codex는 `DFIconButton`/`DFActionButton`/`DFDangerButton`을 모두 추가 제안 — 우리는 **`DFButton`에 variant enum**으로 통합 (컴포넌트 폭증 방지) |
| **P2. DS 내부 raw 값 정리** | ✅ 동의 | `private enum DFComponentMetrics`로 모으는 안 채택 |
| **P2. Density 규칙** (`DFDensity`) | ✅ 동의 + 우선순위 ↑ | Walk Diagnostics는 사용자 사용 빈도 높음 → P2 → **P1** 승격 |
| Codex 미언급 | — | **Lint 가드(`scripts/check_ui_tokens.sh` + Pre-commit)** 가 가장 먼저 들어가야 한다 (인풋 흐름 차단) |

---

## 3. 4-Sprint 로드맵

### 비유

> 디자인 시스템은 **도로 표지판**과 같다. 표지판이 잘 있어도 운전자가 안 보면 사고가 난다.
> 지금 우리는 표지판은 있지만 **차선 표시(lint)** 와 **교통경찰(CI)** 이 없는 도로다.
> 따라서 (1) 차선 페인트를 칠하고 → (2) 가장 사고 잦은 교차로(Top 5)를 정비하고 → (3) 특수 구역(고밀도)에 별도 규칙을 깐다.

### Sprint A — 토큰 보강 + 컴포넌트 단일화 (3-4일, 회귀 위험 낮음)

목표: **컴포넌트 카탈로그 합의** — "어떤 카드를 써야 하나?"라는 질문이 영원히 사라지게 만든다.

작업:
1. `DFCard` deprecated 처리 → 내부 typealias로 `DFPanel`을 가리킴
2. `DashboardCard` 삭제 → `DFPanel(variant: .metric)`로 흡수
3. `DFPanel`에 variant enum 추가:
   - `.regular` (기본, radius `md`, shadow 없음)
   - `.metric` (대시보드 메트릭 — 컬럼 정렬용 fixed-height 옵션)
   - `.modal` (시트/다이얼로그 — radius `lg`, shadow)
   - `.inline` (작은 인라인 — radius `sm`)
4. `DFButton`에 variant enum 추가:
   - `.primary`, `.secondary`, `.success`, `.danger`, `.warning`, `.ghost`
   - 키보드 힌트, confirm rule을 variant 내부에서 처리
5. `DFStatusPill` 신설 (연결 상태/안전 상태 — `DFChip`과 역할 분리)
6. 신규 의미 팔레트 추가 (Codex 제안 + 색각 이상 대응):
   - `DFSafetyColor` (4단계: safe/caution/highRisk/disabled)
   - `DFLoadColor` (4단계: normal/moderate/high/critical)
   - `DFChartPalette` (gyroX/Y/Z, accelX/Y/Z — 6색, ColorBrewer Set1 기반)
7. `DFDensity` enum 추가 (`.regular`/`.compact`/`.dataDense`) + `DFPanel`에 옵션
8. DS 내부 raw 값을 `private enum DFComponentMetrics`로 모음 (DFChip 7pt padding, DFPanel `md-4`, DFKeyboardHint radius 3 등)

산출물:
- 새 토큰 PR — Swift 빌드 통과 + `swift test` 회귀 없음
- 컴포넌트 카탈로그 1-pager (`docs/design-system/CATALOG.md`)

성공 기준:
- `DFCard` import가 0건 (deprecated warning만 남음)
- `DashboardCard` 정의 0건

### Sprint B — Lint 가드 도입 + CI 강제 (1-2일, 회귀 위험 매우 낮음)

목표: **재발 방지선 구축** — 새 코드에 raw 패턴이 들어오지 못하게 만든다.

작업:
1. `scripts/check_ui_tokens.sh` 신설 — Codex 제안 regex를 직접 실행
   ```regex
   Color\.(red|green|blue|orange|yellow|gray|secondary|primary)
   NSColor\.(control|window)BackgroundColor
   RoundedRectangle\(cornerRadius:\s*[0-9]
   \.padding\(\s*[0-9]+\s*\)
   \.padding\(\s*\.(horizontal|vertical),\s*[0-9]
   \.font\(\.(title|title2|title3|headline|caption|caption2|body)\)
   ```
2. 예외 화이트리스트 (파일 단위):
   - `DesignSystem/**`
   - `Visualization/**` (3D material, STL color)
   - 인라인 주석 `// design-system-exception: <reason>`
3. **점진적 모드**: 최초 실행 시 현재 위반 건수를 `.ui-tokens-baseline` 파일로 저장
   - 새 PR이 baseline을 늘리면 CI fail, 줄이면 baseline 갱신 (rachet pattern)
4. GitHub Actions `ci.yml` 또는 pre-commit hook 후크 추가
5. README + CLAUDE.md에 가드 사용법 1단락 추가

산출물:
- `scripts/check_ui_tokens.sh` + baseline 파일 + CI 통합
- 위반 건수 트렌드 출력 (현재 → 목표)

성공 기준:
- CI에서 baseline 이상으로 늘어나면 fail
- baseline = 약 145건 (초기), Sprint C 종료 시 ≤ 60건

### Sprint C — Top 5 화면 정리 (4-5일, 회귀 위험 중간)

목표: **88건 raw 패턴을 토큰화** + **메인 메뉴 7개 화면에 Scaffold 적용**.

순서 (영향 큰 화면부터):
1. **RootView** — sidebar row + E-stop + recovery + remote tool button을 `DFSidebarRow`/`DFButton(.danger)`/`DFStatusPill`로 통일
2. **WalkLabView** (12건) — `Color(NSColor...)` 6건 제거, `simOnlyNotice/banner/connectionPill/footTargetsCard`를 재사용 컴포넌트로 승격
3. **ConnectionWizard** (32건) — 가장 raw 패턴 많은 파일. wizard step 카드 → `DFPanel(.modal)`, 진행 인디케이터 → `DFStepIndicator` 신설
4. **ConnectionDashboard** (14건) — `DashboardCard` 흡수 (Sprint A에서 정의된 `.metric` 사용)
5. **RemoteShellView** (14건) — quick action / command chip / code block / exchange card 전부 DS 컴포넌트화
6. **TransportBar** (16건) — Motion Studio 재생 컨트롤. transport 버튼 = `DFButton(.icon variant)` + `DFKeyboardHint`
7. **StrategyView / JointControlView / BoardStatusView** — `DFPageScaffold` 적용 + `.red/.green/.orange` → `DFColor.danger/success/warning`
8. **MotionLibraryView** — `NavigationSplitView` 구조는 보존하되 detail card만 `DFPanel`로

각 화면 PR 체크리스트:
- [ ] raw cornerRadius / padding 정수 0건
- [ ] `Color.<basic>` / `NSColor.*BackgroundColor` 0건
- [ ] `DFPageScaffold` 적용 (해당 화면)
- [ ] before/after 스크린샷 첨부 (다크/라이트)
- [ ] `swift test` 통과
- [ ] `scripts/check_ui_tokens.sh` baseline 감소 증명

성공 기준:
- raw 패턴 baseline: 145 → **≤ 60** (≥ 58% 감소)
- DFPageScaffold 적용률: 4/11 → **11/11 (100%)**

### Sprint D — 고밀도 화면 + 색각/접근성 (3-4일, 회귀 위험 낮음)

목표: **Walk Diagnostics 등 전문 화면을 별도 density로 격리** + 접근성 인증 수준 확보.

작업:
1. `WalkDiagnosticsView`를 `DFPanel(density: .dataDense)`로 전환
2. `DFDataLayout` 신설 — 차트 높이(`chartHSmall/Medium`), 테이블 컬럼 폭, divider 두께
3. `DFChartPalette` 적용 — 로컬 RGB 팔레트 제거, 색각 이상 대응 검증 (Coblis simulator 캡처)
4. WCAG 1.4.11 Non-Text Contrast 자가 검증 — 모든 `DFStatusPill` 변형 대비 ≥ 3.0:1
5. macOS Increase Contrast / Reduce Transparency 모드에서 토큰 자동 적응 확인
6. **Density 가이드** 문서 (`docs/design-system/DENSITY.md`):
   - `.regular`: 일반 사용자, 클릭 우선 (touch target 44pt+)
   - `.compact`: 전문가/setup wizard (touch target 32pt+)
   - `.dataDense`: 모니터링/진단 (touch target 24pt+, 키보드 우선)

성공 기준:
- Walk Diagnostics raw width/height 모두 토큰화
- 라이트/다크/Increase Contrast 3개 모드 스크린샷 동일 화면에서 깨짐 없음
- 색각 이상 시뮬레이션 통과

---

## 4. 리스크와 대응

| 리스크 | 가능성 | 영향 | 대응 |
|---|:-:|:-:|---|
| `MotionLibraryView`의 `NavigationSplitView` + Scaffold 충돌 | 중 | 중 | Sprint C 8번 항목을 별도 PR로 — split view 동작 회귀 테스트 추가 |
| `DFCard` deprecation 후 외부 import 잔존 | 낮 | 낮 | Sprint A에서 typealias로 유지 → Sprint D 종료 시 완전 삭제 |
| 색상 일괄 치환으로 라이트/다크 비주얼 회귀 | 중 | 높 | 화면별 before/after 스크린샷 PR 첨부 강제 (체크리스트) |
| Lint baseline rachet 우회 (주석으로 회피) | 낮 | 중 | `// design-system-exception: <reason>` 사용 시 reason 필수, CI에서 빈 reason 거부 |
| Codex의 컴포넌트 폭증 안 vs 우리 variant 안 충돌 | 낮 | 낮 | Sprint A 종료 시 Codex에 카탈로그 PR 리뷰 요청 |
| `swift test`가 UI 회귀를 못 잡음 | 높 | 중 | snapshot test (e.g. SnapshotTesting) 도입은 Sprint E 후속 — 이번 4-Sprint 범위 밖. 그 전엔 수동 스크린샷 |

---

## 5. 측정 지표 (KPI)

각 Sprint 종료 시 다음 4개 숫자를 README 트래커에 갱신:

| 지표 | 현재 | Sprint A 후 | Sprint B 후 | Sprint C 후 | Sprint D 후 |
|---|---:|---:|---:|---:|---:|
| `RoundedRectangle(cornerRadius: <int>)` 건수 | 185 | 185 | 185 (baseline) | ≤ 80 | ≤ 30 |
| `.padding(<int>)` 건수 | 43 | 43 | 43 (baseline) | ≤ 15 | ≤ 5 |
| `Color.<basic>` + `NSColor.*BackgroundColor` 건수 | 22 | 22 | 22 (baseline) | ≤ 5 | 0 |
| `DFPageScaffold` 적용 화면 수 | 4/11 | 4/11 | 4/11 | 11/11 | 11/11 |
| DS 컴포넌트 카탈로그 항목 수 | 미정 | 명시화 | — | — | — |

KPI 자동 수집: `scripts/check_ui_tokens.sh --report` 를 매 sprint 종료일에 실행 → 결과를 PR description에 첨부.

---

## 6. 의존성과 비의존성

### Sprint 의존성

```
Sprint A (토큰/컴포넌트)
   ↓ (Sprint B는 A 토큰을 모르면 baseline을 못 만듦)
Sprint B (Lint 가드)
   ↓ (Sprint C는 B 가드로 회귀 차단하면서 진행)
Sprint C (Top 5 화면 정리)
   ↓ (Sprint D는 C 결과 위에 density 레이어)
Sprint D (Density / 접근성)
```

### 비의존성 (병렬 가능)

- `DFChartPalette` 정의(A) 와 Lint 가드 작성(B)은 서로 독립 → 인력 2명이면 병렬 가능
- Sprint C의 RootView 정리와 ConnectionWizard 정리는 파일 분리 → 충돌 없음

### 다른 작업과의 충돌

- Sprint 17 v1.5 Pilot 작업과 **충돌 없음** — Pilot은 이미 DS 토큰을 잘 사용 중
- Codex의 humanlike-motion-design 브랜치는 **머지 제외** 결정 (985K줄 삭제 다른 디자인 방향)

---

## 7. 다음 액션 (이 문서 승인 후)

1. **이 로드맵 자체에 대한 사용자/Codex 승인** — Sprint A에 들어가기 전 카탈로그 합의가 가장 중요
2. 승인 후 Sprint A 시작 — 첫 PR은 `DFPanel.variant` enum + `DFSafetyColor`/`DFLoadColor`/`DFChartPalette` 추가
3. Sprint B Lint 가드 PR — baseline 파일 커밋
4. Sprint C는 PR 1개당 화면 1개 원칙 (8개 PR) — 리뷰 부하 분산

---

## 8. 검증 — 이 기획 자체에 대한 자체 검토

| 원칙 | 적용 여부 |
|---|---|
| 결론 먼저 | ✅ 1줄 결론 → 진단 → 평가 → 로드맵 |
| 정량 근거 | ✅ raw 건수 + Top 5 + 적용률 모두 실측 |
| 비유 | ✅ 도로 표지판 + 차선 + 교통경찰 |
| 측정 가능한 성공 기준 | ✅ KPI 5개 + Sprint별 수치 목표 |
| 회귀 위험 명시 | ✅ 6개 리스크 + 대응 |
| Codex 제안 존중 + 비판 | ✅ 8개 제안 중 7개 동의, 3개 조정 |
| 의존성 그래프 | ✅ Sprint A→B→C→D + 병렬 가능 항목 |
| 다음 액션 명확 | ✅ 4단계 next step |

— 끝.
