# 디자인 시스템 레퍼런스 — Linear / Raycast / Things 3 / Arc / Apple HIG

> 우리 `DesignTokens.swift`가 이미 일부 채용한 모범 사례 + 확장 후보.

## 1. Linear (이슈 트래커)

특징:
- 키보드 우선 — 거의 모든 액션이 단축키
- 인라인 편집 + autosave
- Cmd-K 명령 팔레트

DarwinForge 차용:
- ✅ ⌘1 / ⌘⇧E / ESC (이미 채용)
- ⏳ ⌘K 명령 팔레트 (Sprint 10 후보) — 예: ⌘K → "왼팔 들어" → enter

색 팔레트 (관찰):
- Background: `#0A0A0B` (다크) / `#FAFAFA` (라이트)
- Accent: `#5E6AD2` (purple-blue)
- Border: `rgba(255,255,255,0.06)` 매우 미묘

## 2. Raycast (Spotlight 대체)

특징:
- 명령 팔레트 1차 인터페이스
- 확장(extensions) 시스템 — 사용자 도구 추가
- AI Chat 통합

DarwinForge 차용:
- ⏳ Extensions 패턴 — 사용자가 자기 forge tool 추가 가능?
- ⏳ 명령 팔레트 (Linear와 동일)

## 3. Things 3 (할 일 앱)

특징:
- 매우 심플한 typography (라운드 sans + 큰 행간)
- 색·아이콘은 절제, 의미가 있을 때만
- 한 행 = 한 일

DarwinForge:
- 메시지 / 도구 호출 카드도 "한 카드 = 하나의 의도" 원칙
- ✅ 기본 line-height / 행간 (DesignTokens.swift)

## 4. Arc Browser

특징:
- Glass 효과 (Apple Liquid Glass 전조)
- Sidebar가 메인 — tab도 sidebar에서
- 색 강조 최소

DarwinForge:
- ⚠️ Liquid Glass는 macOS 26 SDK 후. 현재는 Material 폴백.

## 5. Apple HIG (Human Interface Guidelines)

기본 원칙:
- Clarity / Deference / Depth
- macOS 14 (Sonoma) / 15 (Sequoia) 기준 SF Symbols 5+
- NavigationSplitView, ToolbarItem, Material 등

DarwinForge:
- ✅ NavigationSplitView (RootView)
- ✅ Material 폴백 (Liquid Glass 미사용)
- ✅ SF Symbols (모든 아이콘)

## 6. Vercel / Linear / Notion 공통 — Token system

```swift
// 우리 DesignTokens.swift (현재)
public enum DFColor {
    static let canvas      = Color(NSColor.windowBackgroundColor)
    static let surface     = Color(NSColor.controlBackgroundColor)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let accent      = Color.accentColor
    static let success     = Color.green
    static let warning     = Color.orange
    static let danger      = Color.red
    // …
}

public enum DFSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

public enum DFFont {
    static let title    = Font.system(size: 22, weight: .semibold)
    static let bodyEmph = Font.system(size: 14, weight: .medium)
    static let body     = Font.system(size: 14, weight: .regular)
    static let caption  = Font.system(size: 12, weight: .regular)
    // …
}
```

확장 후보 (Linear/Vercel 패턴):
- `DFRadius` (이미 일부 — sm 6, md 10, lg 14)
- `DFShadow` (3 등급 — small / md / large)
- `DFAnimation` (`reduceMotion` 자동 처리)
- `DFOpacity` (disabled 0.5, hover 0.85, etc.)

## 출처

- Linear: https://linear.app
- Raycast: https://www.raycast.com
- Things 3: https://culturedcode.com/things/
- Arc: https://arc.net
- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/
- Vercel Geist Design System: https://vercel.com/geist
