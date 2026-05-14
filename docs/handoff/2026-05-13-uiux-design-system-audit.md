# UI/UX 디자인 시스템 적용 불일치 검수 및 개선 제안

작성일: 2026-05-13  
작성자: Codex  
대상: Claude 구현 담당자  
범위: DarwinForge SwiftUI UI 계층, 디자인 토큰/컴포넌트 사용 일관성

## 결론

현재 프로젝트에는 `DFColor`, `DFFont`, `DFSpace`, `DFRadius`, `DFSize`, `DFOpacity`, `DFPanel`, `DFButton`, `DFChip`, `DFPageScaffold` 등 디자인 시스템의 뼈대가 이미 있다. 문제는 디자인 시스템 부재가 아니라 적용 규칙이 강제되지 않아 화면별로 다음 패턴이 섞인다는 점이다.

1. 같은 카드/패널 역할에 `DFPanel`, `DFCard`, `dfCard`, `DashboardCard`, `GroupBox`, 수동 `RoundedRectangle`이 섞인다.
2. `DFColor` 대신 `.red`, `.green`, `.orange`, `.secondary`, `Color(NSColor.controlBackgroundColor)`가 직접 쓰인다.
3. `DFSpace`, `DFRadius`, `DFSize`가 있는데도 `padding(8)`, `cornerRadius: 6`, `frame(width: 240)` 같은 raw 값이 광범위하게 남아 있다.
4. 버튼/칩/배너를 매번 수동 조합해 같은 액션도 화면마다 높이, radius, 색 농도, hover 느낌이 달라진다.
5. 구형/전문가 화면은 `DFPageScaffold`와 `DFPanel`을 거의 쓰지 않아 앱 전체의 제품감이 끊긴다.

따라서 우선순위는 "색을 조금 예쁘게 수정"이 아니라 **디자인 시스템의 단일 소유권을 정하고, raw 스타일 사용을 줄이며, 반복 UI를 컴포넌트화하는 것**이다.

## 근거 기준

- 정적 코드 검수 기준이다. 실제 스크린샷 QA는 아직 하지 않았다.
- 라인 번호는 2026-05-13 현재 worktree 기준이다.
- `Visualization/RobotScene3D`, STL material 등 3D 렌더링 내부 색상은 별도 그래픽 레이어로 보고 이번 우선순위에서 제외했다.

## 주요 발견

### P1. 카드/패널 컴포넌트가 여러 벌이라 화면마다 표면 질감이 달라진다

디자인 시스템 파일에는 이미 `DFPanel`과 `dfCard`가 있다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:281-358`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DesignTokens.swift:285-301`

그런데 별도 `DFCard`도 존재한다. 이 컴포넌트는 주석상 "radius 16 + 그림자"를 표준 카드라고 설명하고, 실제로 `DFRadius.lg`와 shadow를 사용한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Components/DFCard.swift:3-27`

반면 `DFPanel`은 `DFRadius.md`와 shadow 없는 얇은 border다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:312-328`

또 `ConnectionDashboardView`에는 로컬 전용 `DashboardCard`가 따로 있다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/ConnectionDashboard.swift:568-599`

이 구조는 다음 문제를 만든다.

- 새 화면을 만들 때 어떤 카드가 표준인지 판단하기 어렵다.
- 같은 카드라도 radius 12/16, shadow 있음/없음, padding 12/16이 섞인다.
- 컴포넌트 이름이 "DF"여도 실제 표준이 여러 개라 디자인 시스템이 가이드 역할을 못 한다.

개선 제안:

1. `DFPanel`을 기본 카드/패널 표준으로 고정한다.
2. `DFCard`는 deprecated 처리하거나 `DFPanel` 내부 구현으로 변경한다.
3. `DashboardCard` 같은 로컬 카드는 `DFMetricCard` 또는 `DFPanel(variant: .metric)`으로 디자인 시스템에 흡수한다.
4. 표면 규칙을 명확히 한다.
   - 일반 패널: `DFPanel`, radius `DFRadius.md`, shadow 없음
   - 작은 inline chip/card: `DFChip` 또는 `DFSurface.inline`
   - modal/sheet: `DFDialog` 또는 `DFPanel(variant: .modal)`

### P1. 구형 화면은 디자인 시스템을 거의 쓰지 않아 앱 내부에서 다른 앱처럼 보인다

`StrategyView`는 페이지 스캐폴드 없이 기본 SwiftUI 스타일과 raw 시스템 색을 쓴다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/StrategyView.swift:14-18`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/StrategyView.swift:63-77`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/StrategyView.swift:89-96`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/StrategyView.swift:100-114`

`JointControlView`도 `.title2`, `.headline`, `.secondary`, `.red`, `.green`, `Color(NSColor.controlBackgroundColor)`를 직접 사용한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/JointControlView.swift:51-75`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/JointControlView.swift:77-97`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/JointControlView.swift:112-146`

`BoardStatusView` 역시 비슷하다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/BoardStatusView.swift:13-55`

`MotionLibraryView`도 native `NavigationSplitView/List/ContentUnavailableView` 중심이며, 안전 색상이 `.red/.orange/.green`으로 직접 매핑된다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/MotionLibraryView.swift:31-109`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/MotionLibraryView.swift:174-185`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/MotionLibraryView.swift:188-245`

개선 제안:

1. `StrategyView`, `JointControlView`, `BoardStatusView`, `MotionLibraryView`를 `DFPageScaffold`로 감싼다.
2. `GroupBox`와 수동 카드 대신 `DFPanel`을 쓴다.
3. 상태 값 표시는 `DFMetricRow`, `DFKeyValueGrid`, `DFChip`으로 통일한다.
4. 색상은 `.red/.green/.orange/.secondary` 대신 `DFColor.danger/success/warning/textSecondary`로 대체한다.

### P1. 상태 색상과 안전 색상이 직접 Color로 흩어져 있다

WalkLab은 연결/상태/온도 색상에 `.green`, `.blue`, `.red`, `.orange`, `.yellow`, `.secondary`를 직접 사용한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:151-165`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:205-238`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:298-304`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:337-341`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:366-374`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:378-414`

Torque load 컴포넌트도 load 단계에서 `Color.yellow`, `Color.orange`를 직접 쓴다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Components/TorqueLoadGrid.swift:51-56`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Components/TorqueLoadGrid.swift:181-188`

Walk Diagnostics의 차트 색상은 완전히 로컬 RGB 팔레트다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:665-674`

개선 제안:

1. `DFStatusColor` 또는 `DFSemanticColor`를 추가한다.
   - `.connected`, `.disconnected`, `.simOnly`, `.warning`, `.danger`, `.recovering`
2. `DFLoadPalette`를 추가한다.
   - `.normal = DFColor.success`
   - `.moderate = DFColor.warning`
   - `.high = 별도 orange 토큰 또는 DFColor.warningHigh`
   - `.critical = DFColor.danger`
3. `DFChartPalette`를 추가한다.
   - gyro/accel/filter 색상은 이 파일 하나에서만 정의
   - 색각 이상 대응 가능한 팔레트로 고정
4. 화면 내부에서 `Color.red/green/orange/yellow/blue/gray` 직접 사용을 금지한다. 예외는 3D material, chart gradient 내부처럼 명시 주석이 있는 경우만 허용한다.

### P1. raw spacing/radius/size가 디자인 토큰 규칙과 충돌한다

`DesignTokens.swift`는 "매직 넘버 금지"를 명시한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DesignTokens.swift:95-102`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DesignTokens.swift:154-159`

하지만 실제 화면에는 raw 값이 많이 남아 있다.

WalkLab:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:25-35`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:80-87`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:186-202`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:261-295`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:378-414`

RootView:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:471-502`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:508-530`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:550-605`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:620-647`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:692-709`

RemoteShell:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:142-180`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:184-232`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:269-366`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:368-459`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:461-490`

Walk Diagnostics:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:69-106`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:116-221`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:463-488`

개선 제안:

1. raw 값을 무조건 없애기보다 "semantic token으로 승격"한다.
2. 다음 토큰을 추가한다.
   - `DFLayout.sidebarWCompact`, `sidebarWRegular`, `sidebarWWide`
   - `DFLayout.inspectorW`, `diagnosticLeftW`, `diagnosticRightW`
   - `DFLayout.modalWMedium`, `modalHMedium`
   - `DFSize.dividerH`, `DFSize.chartHSmall`, `chartHMedium`
   - `DFSize.codeBlockMinH`, `DFSize.commandInputButton`
3. `padding(8)`, `padding(10)`, `padding(12)`는 대부분 `DFSpace.sm`, `DFSpace.sm2`, `DFSpace.sm3`로 치환한다.
4. `cornerRadius: 3/4/5/6`는 `DFRadius.xs/xs2`로 치환한다.
5. 고정 width는 토큰 이름으로 의도를 드러낸다. 예: `frame(width: 240)` → `DFLayout.walkLabSidePanelW`.

### P1. 버튼/칩/배너가 수동 조합되어 액션의 위계가 일관되지 않다

RootView에는 연결 마법사, 로봇 복구, E-stop, 원격 도구 버튼이 모두 수동 스타일이다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:477-502`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:508-530`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:550-605`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:692-709`

RemoteShell도 quick action, mode toggle, channel chip, copy buttons, preset chips를 각각 새로 그린다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:142-180`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:184-232`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:280-350`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift:476-490`

WalkLab의 배너와 action bar도 native `Button`, `.tint(.red)`, 수동 banner 조합을 쓴다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:240-259`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:306-354`

개선 제안:

1. 디자인 시스템에 다음 컴포넌트를 추가한다.
   - `DFIconButton`
   - `DFActionButton`
   - `DFDangerButton`
   - `DFStatusPill`
   - `DFNoticeBanner`
   - `DFCodeBlock`
   - `DFCommandChip`
   - `DFQuickActionCard`
2. E-stop, recovery, connect, send, copy 같은 액션은 variant로만 구분한다.
   - `.primary`, `.secondary`, `.success`, `.danger`, `.warning`, `.ghost`
3. 수동 `.buttonStyle(.plain)` + background + capsule 패턴은 디자인 시스템 내부로 이동한다.
4. 위험 액션은 항상 `DFDangerButton` + icon + keyboard hint + confirm rule로 통일한다.

### P2. 디자인 시스템 내부에도 raw 값이 남아 있어 외부 코드가 따라 하기 어렵다

디자인 시스템 컴포넌트 내부에서도 raw 값이 많다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:99-114`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:183-197`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:258-274`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:312-358`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DFComponents.swift:466-499`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/GlassNeon.swift:129-166`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/GlassNeon.swift:199-222`

디자인 시스템 내부의 raw 값 자체는 허용될 수 있다. 다만 지금은 일부 값이 토큰 문서와 충돌한다.

예:

- `DFChip`은 `.padding(.horizontal, 7)`을 쓴다. 토큰에는 pill padding이 이미 있다.
- `DFPanel`은 `.padding(DFSpace.md - 4)`처럼 산술식을 쓴다.
- `DFKeyboardHint`는 cornerRadius 3을 직접 쓴다.
- `GlassNeonButtonStyle`은 `.padding(.horizontal, 14)`를 직접 쓴다.

개선 제안:

1. 디자인 시스템 내부 raw 값은 모두 `private enum DFComponentMetrics`로 모은다.
2. 외부 화면에서는 raw 값을 쓰지 않고, 디자인 시스템 내부에서만 허용한다.
3. `DFChip`, `DFKeyboardHint`, `DFPanel`, `DFButton`의 metrics를 명시 토큰으로 분리한다.

### P2. 전문/진단 화면의 고밀도 UI는 별도 density 규칙이 필요하다

Walk Diagnostics는 의도적으로 "Bloomberg 터미널 스타일"의 고밀도 화면이다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:5-18`

이런 화면은 일반 사용자 화면과 같은 spacing을 강제하면 오히려 나빠진다. 문제는 고밀도 규칙이 디자인 시스템에 정의되어 있지 않아 raw width, raw chart height, raw table column이 화면 내부에 박혀 있다는 점이다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:81-106`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:142-181`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:344-381`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift:463-488`

개선 제안:

1. `DFDensity`를 추가한다.
   - `.regular`: 일반 사용자 화면
   - `.compact`: 전문가/진단 화면
   - `.dataDense`: 차트/telemetry 화면
2. `DFPanel`에 density 옵션을 추가한다.
3. 차트 높이와 테이블 컬럼 폭은 `DFDataLayout`로 분리한다.

## 권장 개선 순서

### 1단계: 디자인 시스템 단일 소유권 정리

먼저 컴포넌트 종류를 줄인다.

1. `DFPanel`을 표준 panel/card로 선언.
2. `DFCard`와 `DashboardCard`를 `DFPanel` 기반으로 흡수.
3. `StatusPill`과 `DFChip`을 합치거나 역할을 분리한다.
   - `DFChip`: 일반 태그/필터
   - `DFStatusPill`: 상태/안전/연결
4. `DFPageScaffold`를 모든 메인 메뉴 화면의 기본 컨테이너로 지정.

### 2단계: 하드코딩 금지 규칙을 lint로 강제

SwiftLint custom rule 또는 `scripts/check_ui_tokens.sh`를 추가한다.

금지 패턴:

```regex
Color\.(red|green|blue|orange|yellow|gray|secondary|primary)
NSColor\.controlBackgroundColor
NSColor\.windowBackgroundColor
RoundedRectangle\(cornerRadius: [0-9]
\.padding\([0-9]
\.padding\(\.horizontal, [0-9]
\.padding\(\.vertical, [0-9]
\.font\(\.(title|title2|title3|headline|caption|caption2|body)
```

예외 허용:

- `DesignSystem/**`
- `Visualization/**`
- 차트/3D material에서 주석으로 `// design-system-exception:`을 붙인 경우

### 3단계: 고빈도 화면부터 정리

사용자가 많이 보는 화면부터 바꾼다.

1. `RootView`
   - sidebar row, E-stop, recovery, remote tool button을 `DFSidebarRow`, `DFDangerButton`, `DFStatusPill`로 통일.
2. `WalkLabView`
   - `Color(NSColor...)`, `.red/.green/.blue`, raw padding/frame 제거.
   - `simOnlyNotice`, `banner`, `connectionPill`, `footTargetsCard`를 재사용 컴포넌트로 승격.
3. `RemoteShellView`
   - quick action, command chip, code block, exchange card를 디자인 시스템 컴포넌트로 승격.
4. `StrategyView`, `JointControlView`, `BoardStatusView`
   - `DFPageScaffold` + `DFPanel` 기반으로 전환.
5. `MotionLibraryView`
   - safety color를 `DFMotionSafetyColor`로 통일하고 detail card를 `DFPanel`로 전환.

### 4단계: 데이터/안전 팔레트 분리

로봇 제어 앱에서는 색상이 단순 장식이 아니라 안전 정보다.

추가할 팔레트:

```swift
public enum DFSafetyColor {
    public static let safe = DFColor.success
    public static let caution = DFColor.warning
    public static let highRisk = DFColor.danger
    public static let disabled = DFColor.textSecondary
}

public enum DFLoadColor {
    public static let normal = DFColor.success
    public static let moderate = DFColor.warning
    public static let high = Color(light: "#FF7A1A", dark: "#FF9F0A") // 필요 시 토큰화
    public static let critical = DFColor.danger
    public static let unknown = DFColor.textSecondary.opacity(DFOpacity.disabled)
}

public enum DFChartPalette {
    public static let gyroX = ...
    public static let gyroY = ...
    public static let gyroZ = ...
    public static let accelX = ...
}
```

## Claude에게 전달할 변경 지시

이번 작업은 화면별 미세 수정이 아니라 디자인 시스템 적용률을 높이는 구조 개선으로 진행해줘.

우선순위는 다음과 같아.

1. 디자인 시스템의 표준 컴포넌트를 정리한다.
   - 표준 panel/card: `DFPanel`
   - 표준 button: `DFButton`
   - 표준 status/chip: `DFStatusPill`/`DFChip`
   - 표준 page: `DFPageScaffold`
2. `DFCard`, `DashboardCard`, 수동 card chrome을 `DFPanel` 기반으로 흡수한다.
3. `Color.red/green/orange/yellow/blue/gray/secondary`, `NSColor.controlBackgroundColor`, `NSColor.windowBackgroundColor` 직접 사용을 제거한다.
4. `padding(8/10/12/16)`, `cornerRadius: 4/5/6/8`, 고정 width/height를 토큰으로 승격하거나 기존 토큰으로 치환한다.
5. `RootView`, `WalkLabView`, `RemoteShellView`, `StrategyView`, `JointControlView`, `BoardStatusView` 순서로 정리한다.
6. 진단/차트 화면은 일반 화면과 분리해 `DFDensity`와 `DFChartPalette`를 만든다.

완료 후 보고해야 할 것:

- 어떤 raw style 패턴을 제거했는지.
- 새로 추가한 design token/component 목록.
- 남긴 예외와 이유.
- 주요 화면 스크린샷 또는 최소한 빌드 결과.
- `swift test` 결과.

## 최소 수용 기준

1. 신규 UI 코드에서 `Color.red`, `.foregroundStyle(.secondary)`, `Color(NSColor.controlBackgroundColor)`가 나오지 않는다.
2. 신규 UI 코드에서 `RoundedRectangle(cornerRadius: 6)` 같은 raw radius가 나오지 않는다.
3. 카드/패널은 `DFPanel` 또는 디자인 시스템 컴포넌트만 사용한다.
4. E-stop, recovery, connect, send, copy 버튼은 화면마다 수동 스타일을 만들지 않는다.
5. 안전/상태/부하 색상은 semantic palette를 통해서만 사용한다.
6. 전문가/진단 화면은 별도 density 규칙을 사용하되, 그 규칙도 디자인 시스템 안에 둔다.
