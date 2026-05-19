import SwiftUI

/// DarwinForge 디자인 시스템 — 색상·타이포·스페이싱 토큰.
///
/// 근거: Apple HIG Liquid Glass (macOS 26 — 본 빌드에선 Material 폴백),
/// LiquidGlassReference §1.6 (접근성 자동 적응),
/// NN/g Liquid Glass 비판 (본문엔 솔리드 색상),
/// KS S ISO 7010 안전 색상 (위험=빨강, 주의=노랑, 정보=파랑, 안전=초록).
///
/// 향후 Xcode 26 + macOS 26 SDK 마이그레이션 시 `Material.regularMaterial`을
/// `.glassEffect()`로 자동 교체 가능.
public enum DFColor {
    // MARK: - Surface
    /// 윈도우 배경
    public static let canvas = Color(light: "#F2F2F7", dark: "#1C1C1E")
    /// 카드
    public static let card = Color(light: "#FFFFFF", dark: "#2C2C2E")
    /// nested 카드
    public static let elev2 = Color(light: "#F9F9FB", dark: "#3A3A3C")
    /// **2026-05-16**: nested level 3 — dashboard 내부 sub-panel.
    public static let elev3 = Color(light: "#EFEFF4", dark: "#48484A")

    // MARK: - Text
    public static let textPrimary = Color(light: "#1C1C1E", dark: "#FFFFFF")
    public static let textSecondary = Color(light: "#3C3C43", dark: "#EBEBF5").opacity(0.6)

    // MARK: - Accent
    public static let accent = Color(light: "#0A84FF", dark: "#0A84FF")
    /// 브랜드 (로봇 / 모션 강조).
    /// **2026-05-16**: orange 계열 (#FF6A00) → blue 계열 (#0050D5). 메인 컬러 통일.
    /// `DFColor.accent` (system blue #0A84FF) 와 구분되는 짙은 brand blue —
    /// 같은 파랑 계열이지만 더 진해 brand identity 유지.
    public static let forge = Color(light: "#0050D5", dark: "#3F8CFF")

    // MARK: - State (KS S ISO 7010 매핑 + WCAG High Contrast 변형)
    //
    // 2026-05-16: High Contrast 변형 추가. macOS Accessibility "대비 늘리기" ON 시
    // 더 진한 톤 자동 적용 — WCAG AAA 명도비 (7:1+) 만족.

    /// 정상 / 정보 (KS 초록). High contrast: 더 진한 녹색.
    public static let success = Color(
        light: "#34C759", dark: "#30D158",
        highContrastLight: "#248A3D", highContrastDark: "#3AE65A"
    )
    /// 한계 근접 / 주의 (KS 노랑). High contrast: 더 진한 amber.
    public static let warning = Color(
        light: "#FF9F0A", dark: "#FFD60A",
        highContrastLight: "#C26C00", highContrastDark: "#FFEA38"
    )
    /// 위험 / E-Stop / fault (KS 빨강). High contrast: 더 진한 빨강.
    public static let danger = Color(
        light: "#FF3B30", dark: "#FF453A",
        highContrastLight: "#C7160C", highContrastDark: "#FF6961"
    )
    /// 텔레메트리 / 정보 (KS 파랑). icon / background tint 용도.
    /// **주의**: text foregroundStyle 용도로는 `infoText` 사용 (WCAG AA 4.5:1).
    /// light variant `#5AC8FA` 가 흰 배경 위 약 2.3:1 → small text 부적합.
    public static let info = Color(
        light: "#5AC8FA", dark: "#64D2FF",
        highContrastLight: "#0A75AB", highContrastDark: "#7DDBFF"
    )

    /// 2026-05-17 a11y audit fix (WCAG 1.4.3): `info` text variant.
    /// `info` 보다 darker (light) / lighter (dark) — body/small text 대비 4.5:1+.
    /// PilotHudStrip metricCell value text 등에서 사용.
    public static let infoText = Color(
        light: "#0A75AB", dark: "#7DDBFF",
        highContrastLight: "#06547A", highContrastDark: "#A8E5FF"
    )
    /// 토크 / 모터 시각화 (보라).
    public static let torque = Color(
        light: "#BF5AF2", dark: "#DA8FFF",
        highContrastLight: "#8E2CC2", highContrastDark: "#E3AAFF"
    )

    /// **2026-05-16**: 5-tier safety state 의 intermediate "심각" 단계.
    /// warning(노랑) ↔ danger(빨강) 사이 — fall prevention 의 22-30° 등.
    /// macOS `.orange` 와 유사하지만 light/dark + highContrast 명시 제어.
    public static let severe = Color(
        light: "#FF6F00", dark: "#FF9F0A",
        highContrastLight: "#C24A00", highContrastDark: "#FFB733"
    )

    // MARK: - Interaction state (2026-05-16)

    /// 마우스 hover background — Apple HIG `controlBackgroundColor` 변형.
    /// macOS native pattern: `NSColor.selectedControlColor` 의 light variant.
    public static let hoverBg = Color(light: "#E5E5EA", dark: "#3A3A3C")
    /// selected row / item background — `NSColor.selectedContentBackgroundColor` 대응.
    public static let selectedBg = Color(light: "#D0E4FE", dark: "#0A4D8A")
    /// focus ring 색 — Apple HIG `NSColor.keyboardFocusIndicatorColor`.
    /// keyboardShortcut / Tab navigation 시 강조 outline.
    public static let focusRing = Color(light: "#0A84FF", dark: "#0A84FF")
    /// 비활성 (disabled) overlay — control 위에 덧씌워 dim 효과.
    public static let disabledOverlay = Color(light: "#FFFFFF", dark: "#000000").opacity(0.4)

    // MARK: - 2026-05-19 v1.11.15: 흰색 플랫 테마 전용 표면 색상
    //
    // `DFTheme.lightFlat` 활성 시 canvas/card/elev2/border 를 순백 톤으로 override.
    // 기본 light variant (canvas = #F2F2F7) 보다 더 흰색에 가까워 "흰색 플랫" 인상 강화.
    // shadow 는 비활성 (DFThemedShadow modifier 가 처리), 표면 구분은 옅은 보더만.
    //
    // **2026-05-19 cycle 2**: 완벽 무채색 (achromatic) 보강 — 모든 RGB 채널 동일값.
    // 종전 b 채널이 r=g 보다 살짝 컸음 (cool 톤 잔존) → 모든 surface r=g=b 로 통일.
    // 상태 색상 (forge/danger/success/...) 은 RootView 의 `.saturation(0)` modifier 가
    // flat 모드에서 자동 desaturate → 전체 GUI 가 진정한 grayscale.

    /// 흰색 플랫 — 윈도우 배경 (순백, r=g=b=1.0).
    public static let flatCanvas = Color(red: 1.0, green: 1.0, blue: 1.0)
    /// 흰색 플랫 — 카드 (r=g=b=0.985).
    public static let flatCard = Color(red: 0.985, green: 0.985, blue: 0.985)
    /// 흰색 플랫 — nested 카드 elev2 (r=g=b=0.965).
    public static let flatElev2 = Color(red: 0.965, green: 0.965, blue: 0.965)
    /// 흰색 플랫 — deepest nested elev3 (r=g=b=0.940).
    public static let flatElev3 = Color(red: 0.940, green: 0.940, blue: 0.940)
    /// 흰색 플랫 — 표면 보더 (r=g=b=0.860).
    public static let flatBorder = Color(red: 0.860, green: 0.860, blue: 0.860)
    /// 흰색 플랫 — 본문 텍스트 (r=g=b=0.110).
    public static let flatTextPrimary = Color(red: 0.110, green: 0.110, blue: 0.110)
    /// 흰색 플랫 — 보조 텍스트 (r=g=b=0.360).
    public static let flatTextSecondary = Color(red: 0.360, green: 0.360, blue: 0.360)

    // MARK: - 2026-05-19 v1.11.15 cycle 2: 3D 뷰포트 전용 배경
    //
    // 흰색 플랫 / 라이트 모드에서도 3D 모델 (회색 mesh) 시인성 보장 위해 어두운 톤 유지.
    // Apple 자체 도구 (Reality Composer, Xcode SceneKit Editor) 도 어두운 viewport 사용.
    // 테마 무관 항상 dark — 사용자 명시 요청 (2026-05-19).

    /// 3D 뷰포트 상단 그라데이션 (#2A2A2E — 어두운 회색).
    public static let scene3DTop = Color(red: 0.165, green: 0.165, blue: 0.180)
    /// 3D 뷰포트 하단 그라데이션 (#15151A — 거의 검정).
    public static let scene3DBottom = Color(red: 0.082, green: 0.082, blue: 0.102)

    // MARK: - 테마 인식 accessor (theme: DFTheme)
    //
    // flat 모드에서 핵심 표면을 자동 분기. 사용처:
    //   `.background(DFColor.adaptiveCanvas(theme))`
    // 의도: 점진적 마이그레이션 — 새 컴포넌트는 adaptive 사용, 기존은 그대로.

    /// 윈도우 배경 — flat 일 때 #FFFFFF, 아니면 light/dark 자동.
    public static func adaptiveCanvas(_ theme: DFTheme) -> Color {
        theme.prefersWhiteSurfaces ? flatCanvas : canvas
    }
    /// 카드 — flat 일 때 거의 흰색, 아니면 light/dark 자동.
    public static func adaptiveCard(_ theme: DFTheme) -> Color {
        theme.prefersWhiteSurfaces ? flatCard : card
    }
    /// nested 카드 (elev2) — flat 일 때 옅은 회색, 아니면 light/dark 자동.
    public static func adaptiveElev2(_ theme: DFTheme) -> Color {
        theme.prefersWhiteSurfaces ? flatElev2 : elev2
    }
    /// nested 카드 (elev3) — flat 일 때 옅은 회색, 아니면 light/dark 자동.
    public static func adaptiveElev3(_ theme: DFTheme) -> Color {
        theme.prefersWhiteSurfaces ? flatElev3 : elev3
    }
    /// 카드/패널 보더 — flat 일 때 명확한 회색, 아니면 textSecondary subtle.
    public static func adaptiveBorder(_ theme: DFTheme) -> Color {
        theme.prefersWhiteSurfaces ? flatBorder : textSecondary.opacity(DFOpacity.subtle)
    }
}

/// 타이포 스케일 — Apple HIG Typography 가이드 기반.
///
/// # 사용 규칙
/// - **Semantic alias 우선** (`.display`, `.title`, `.body`, `.caption`) — 의도 명확.
/// - **Numeric size (`DFFontSize.s9` ~ `.s28`)** — custom weight / monospaced 가 필요할 때만.
/// - `font.system(size: DFFontSize.s11, weight: .semibold)` 패턴 권장.
public enum DFFont {
    // MARK: - Display / Hero (existing)
    public static let display = Font.system(size: 28, weight: .bold, design: .default)
    public static let title = Font.system(size: 22, weight: .semibold, design: .default)
    public static let subtitle = Font.system(size: 20, weight: .regular, design: .default)
    public static let body = Font.system(size: 13, weight: .regular, design: .default)
    public static let bodyEmph = Font.system(size: 13, weight: .semibold, design: .default)
    public static let caption = Font.system(size: 11, weight: .regular, design: .default)
    public static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)

    // MARK: - 2026-05-16: 모니터링 dashboard semantic tokens
    //
    // dashboard 영역 (FallPreventionMonitor, DFSourcePill, DFStatusTile,
    // SafetySparkline) 의 dense layout 용. 일반 view 가 사용 가능하지만
    // 디자인 의도는 데이터-밀집 (Edward Tufte data-ink ratio 극대화).

    // Hero
    /// 28pt semibold — hero icon (FallPreventionMonitor heroIcon).
    public static let heroIcon = Font.system(size: 28, weight: .semibold)
    /// 20pt semibold — 큰 상태 label (state.label 등).
    public static let heroState = Font.system(size: 20, weight: .semibold)
    /// 18pt semibold — secondary hero data (medium).
    public static let heroSecondary = Font.system(size: 18, weight: .semibold)

    // Section headings
    /// 18pt semibold — large section heading.
    public static let sectionLarge = Font.system(size: 18, weight: .semibold)
    /// 16pt semibold — medium section heading.
    public static let sectionMedium = Font.system(size: 16, weight: .semibold)
    /// 14pt semibold — small section heading.
    public static let sectionSmall = Font.system(size: 14, weight: .semibold)
    /// 12pt semibold — body section heading (toggle bar title).
    public static let sectionBody = Font.system(size: 12, weight: .semibold)
    /// 10pt medium — sub-section heading (dashboard sub-section labels).
    public static let sectionLabel = Font.system(size: 10, weight: .medium)

    // Body / Caption / Label
    /// 13pt semibold — body emphasis.
    public static let bodySmall = Font.system(size: 12, weight: .regular)
    public static let bodySmallEmph = Font.system(size: 12, weight: .semibold)
    /// 11pt medium — caption emphasis (card heading).
    public static let captionEmph = Font.system(size: 11, weight: .medium)
    /// 10pt regular — generic small label.
    public static let label = Font.system(size: 10, weight: .regular)
    /// 9pt regular — micro label (threshold, joint name).
    public static let micro = Font.system(size: 9, weight: .regular)

    // Monospace variants (data display)
    /// 11pt regular mono — caption-sized data.
    public static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// 10pt regular mono — label-sized mono data.
    public static let monoLabel = Font.system(size: 10, weight: .regular, design: .monospaced)
    /// 9pt regular mono — micro mono (event log time, joint name).
    public static let monoMicro = Font.system(size: 9, weight: .regular, design: .monospaced)

    // Data values (semibold mono + monospacedDigit for aligned numbers)
    /// 18pt semibold mono digit — large data display (hero tilt).
    public static let dataLarge = Font.system(size: 18, weight: .semibold, design: .monospaced)
        .monospacedDigit()
    /// 12pt semibold mono digit — tile value display.
    public static let dataMedium = Font.system(size: 12, weight: .semibold, design: .monospaced)
        .monospacedDigit()
    /// 11pt semibold mono digit — current value display.
    public static let dataSmall = Font.system(size: 11, weight: .semibold, design: .monospaced)
        .monospacedDigit()
    /// 9pt regular mono digit — micro data (joint delta value).
    public static let dataMicro = Font.system(size: 9, weight: .regular, design: .monospaced)
        .monospacedDigit()

    // Pill (very small)
    /// 8pt medium mono — source pill / very small tag.
    public static let pill = Font.system(size: 8, weight: .medium, design: .monospaced)

    // Additional semantic tokens (WalkLabView migration completeness)
    /// 13pt semibold mono — phase label (footTargetsCard).
    public static let monoBody = Font.system(size: 13, weight: .semibold, design: .monospaced)
    /// 22pt semibold — modal heading (riskConfirmSheet).
    public static let modalHeader = Font.system(size: 22, weight: .semibold)
    /// 20pt bold — modal hero (riskConfirmSheet).
    public static let modalHero = Font.system(size: 20, weight: .bold)
    /// 10pt semibold — emphasized small label (status badge text).
    public static let labelStrong = Font.system(size: 10, weight: .semibold)
    // 2026-05-17 dead code purge: microThreshold (7pt) 토큰 제거.
    // SafetySparkline 리팩토링 (chart axis column 분리) 후 0 callers.
}

/// 타이포 raw size 토큰 — `font.system(size: ...)` 사용 시 raw 숫자 대신 사용.
///
/// Apple HIG + macOS 본문 / 캡션 / 헤딩 표준 스케일.
public enum DFFontSize {
    /// 8pt — extreme small (load tile indicator — 영문/숫자 전용, 한국어 비추천).
    public static let s8: CGFloat = 8
    /// 9pt — 매우 작은 helper text (한국어 가독 한계).
    public static let s9: CGFloat = 9
    /// 10pt — 작은 helper / tab 라벨.
    public static let s10: CGFloat = 10
    /// 11pt — 캡션 (== DFFont.caption).
    public static let s11: CGFloat = 11
    /// 12pt — pill 라벨 / mono (== DFFont.mono 의 size).
    public static let s12: CGFloat = 12
    /// 13pt — 본문 (== DFFont.body 의 size).
    public static let s13: CGFloat = 13
    /// 14pt — 보조 헤딩 / 강조 본문.
    public static let s14: CGFloat = 14
    /// 16pt — 섹션 헤딩 / 큰 본문.
    public static let s16: CGFloat = 16
    /// 18pt — 작은 카드 제목.
    public static let s18: CGFloat = 18
    /// 20pt — subtitle (== DFFont.subtitle 의 size).
    public static let s20: CGFloat = 20
    /// 22pt — 페이지 제목 (== DFFont.title 의 size).
    public static let s22: CGFloat = 22
    /// 24pt — section heading.
    public static let s24: CGFloat = 24
    /// 26pt — large heading variant.
    public static let s26: CGFloat = 26
    /// 28pt — hero display (== DFFont.display 의 size).
    public static let s28: CGFloat = 28
    /// 32pt — XL display variant.
    public static let s32: CGFloat = 32
}

/// 스페이싱 — Apple HIG 8pt 그리드 (semantic) + 4pt half-grid (보조) + 1-2pt micro.
///
/// # Grid 계층 (Apple HIG / Material Design 정합)
///
/// 1. **8pt 그리드** (primary semantic) — section / card / hero spacing 기준.
///    값: `sm (8)`, `md (16)`, `lg (24)`, `xl (32)`, `xxl (48)`
/// 2. **4pt half-grid** (sub-step) — 작은 조정.
///    값: `xs (4)`, `sm3 (12)`, `md2 (20)`
/// 3. **2pt micro** (hairline / pill 전용 — off-grid 의도된 예외).
///    값: `micro (1)`, `micro2 (2)`, `xs2 (6)`, `sm2 (10)`
///
/// # 사용 규칙
/// 1. 매직 넘버 금지 — 모든 padding/spacing 은 본 토큰 사용.
/// 2. **Semantic alias 우선** (`.pillV`, `.pillH`, `.toolbarGap`, `.cardInner`)
///    — 의도 명확. NEW (2026-05-16).
/// 3. **Numeric (`xs/sm/md`)** — semantic alias 가 없는 경우.
/// 4. **Micro (`micro/micro2`)** — border / pixel-perfect 정렬에 한해.
///
/// # 명명 컨벤션 (legacy 호환)
/// `xs (4)` < `xs2 (6)` < `sm (8)` < `sm2 (10)` < `sm3 (12)` < `md (16)` < `md2 (20)` < `lg (24)` < `xl (32)` < `xxl (48)`
/// 숫자 접미사 (`xs2 = 6`) = "xs(4) 보다 큰 첫 interstitial".
public enum DFSpace {
    public static let none: CGFloat = 0
    /// 1pt — pixel-perfect alignment.
    public static let micro: CGFloat = 1
    /// 2pt — 매우 조밀한 inline gap (badge 내부, super-tight).
    public static let micro2: CGFloat = 2
    /// 4pt — tight grouping (icon ↔ label). **4pt half-grid**.
    public static let xs: CGFloat = 4
    /// 6pt — pill vertical padding, 조밀 그룹. **off-grid (pill 표준 예외)**.
    public static let xs2: CGFloat = 6
    /// 8pt — standard inner spacing (button padding, card inner). **8pt 그리드**.
    public static let sm: CGFloat = 8
    /// 10pt — inline gap (toolbar pill 사이). **off-grid (toolbar 표준 예외)**.
    public static let sm2: CGFloat = 10
    /// 12pt — pill horizontal padding, 작은 카드 패딩. **4pt half-grid**.
    public static let sm3: CGFloat = 12
    /// 16pt — section padding (sidebar 좌·우, card 내부 큰). **8pt 그리드**.
    public static let md: CGFloat = 16
    /// 20pt — generous spacing (모달 내부, 큰 카드). **4pt half-grid**.
    public static let md2: CGFloat = 20
    /// 24pt — section breathing (페이지 외곽). **8pt 그리드**.
    public static let lg: CGFloat = 24
    /// 32pt — hero spacing. **8pt 그리드**.
    public static let xl: CGFloat = 32
    /// 48pt — big hero spacing. **8pt 그리드**.
    public static let xxl: CGFloat = 48

    // MARK: - 2026-05-16: Semantic aliases (의도 명확)

    /// 6pt — pill 의 vertical padding. KS Apple HIG pill 표준.
    public static let pillV: CGFloat = xs2
    /// 12pt — pill 의 horizontal padding. KS Apple HIG pill 표준.
    public static let pillH: CGFloat = sm3
    /// 10pt — toolbar 의 inline gap (pill 사이, status indicator 사이).
    public static let toolbarGap: CGFloat = sm2
    /// 8pt — card / panel 의 inner padding (compact).
    public static let cardInnerCompact: CGFloat = sm
    /// 16pt — card / panel 의 inner padding (standard).
    public static let cardInner: CGFloat = md
    /// 20pt — modal / sheet 의 inner padding.
    public static let modalInner: CGFloat = md2
    /// 4pt — icon ↔ label 의 tight gap.
    public static let iconLabel: CGFloat = xs
    /// 8pt — 일반 section content gap (8pt grid 기본).
    public static let sectionGap: CGFloat = sm
}

/// 코너 라운드 — Apple HIG + Linear/Vercel Geist 스케일.
///
/// # 사용 규칙 (각 토큰의 의도)
/// | 토큰 | 값 | 용도 |
/// |---|---:|---|
/// | `tiny` | 2 | event log row hint, 매우 좁은 ribbon |
/// | `xs` | 4 | status tile (dense, snug) |
/// | `xs2` | 6 | 버튼 / pill / 작은 indicator |
/// | `sm` | 8 | 표준 card |
/// | `md` | 12 | 큰 card / 패널 |
/// | `lg` | 16 | 모달 / sheet |
/// | `xl` | 20 | hero card |
/// | `full` | 999 | capsule (height 의 절반 이상) |
///
/// # 시맨틱 alias 우선
/// `.button`, `.statusTile`, `.card`, `.panel`, `.modal`, `.hero`, `.capsule` — 의도 명확.
public enum DFRadius {
    public static let none: CGFloat = 0
    /// 2pt — 매우 좁은 pill / event log row 의 hint background.
    public static let tiny: CGFloat = 2
    /// 4pt — status tile / dense rounded element.
    public static let xs: CGFloat = 4
    /// 6pt — 버튼 / pill / 작은 indicator (이전 raw 6 통일).
    public static let xs2: CGFloat = 6
    /// 8pt — 표준 card.
    public static let sm: CGFloat = 8
    /// 12pt — 큰 card / panel.
    public static let md: CGFloat = 12
    /// 16pt — 모달 / sheet.
    public static let lg: CGFloat = 16
    /// 20pt — hero card.
    public static let xl: CGFloat = 20
    public static let full: CGFloat = 999

    // MARK: - 2026-05-16: Semantic aliases (의도 명확)

    /// 6pt — 버튼 / pill 의 표준 corner (= xs2).
    public static let button: CGFloat = xs2
    /// 4pt — dense status tile (= xs).
    public static let statusTile: CGFloat = xs
    /// 8pt — 표준 card 의 corner (= sm).
    public static let card: CGFloat = sm
    /// 12pt — panel 의 corner (= md).
    public static let panel: CGFloat = md
    /// 16pt — 모달 / sheet 의 corner (= lg).
    public static let modal: CGFloat = lg
    /// 20pt — hero card 의 corner (= xl).
    public static let hero: CGFloat = xl
    /// 999pt — capsule (= full).
    public static let capsule: CGFloat = full
}

/// 컴포넌트 표준 크기 — 버튼 / 입력 / 인디케이터 / 패널.
///
/// # 사용 규칙
/// - **모든 component 는 본 토큰에서 시작**. 직접 `.frame(width: 5)` 같은 raw 금지.
/// - `pillH / pillPaddingH / pillPaddingV` = toolbar / status pill 표준.
/// - 새 컴포넌트가 기존 토큰과 안 맞으면 본 enum 에 추가 (코드에 분산 금지).
public enum DFSize {
    /// E-Stop 버튼 (ISO 13850 권장 머쉬룸 헤드 ≥40mm — 디지털 환산 56pt).
    public static let estop: CGFloat = 56
    public static let toolbarIcon: CGFloat = 22
    public static let badgeMin: CGFloat = 28

    // MARK: 버튼
    /// 버튼 표준 높이 — small / medium / large.
    public static let buttonHSmall: CGFloat = 24
    public static let buttonHMedium: CGFloat = 30
    public static let buttonHLarge: CGFloat = 40

    // MARK: 입력 / 칩
    /// 입력 필드 표준 높이.
    public static let inputH: CGFloat = 30
    /// 칩 표준 높이.
    public static let chipH: CGFloat = 22

    // MARK: Pill (toolbar / status pill 표준)
    /// pill 컨텐츠 높이 = 24pt (호흡 포함 외곽 ≈ 36pt).
    public static let pillH: CGFloat = 24
    /// pill 좌·우 패딩 (이전 raw 12 통일).
    public static let pillPaddingH: CGFloat = DFSpace.sm3   // 12
    /// pill 상·하 패딩 (이전 raw 6 통일).
    public static let pillPaddingV: CGFloat = DFSpace.xs2   // 6

    // MARK: Indicators (status dot / load tile / phase pixel)
    /// 5pt — 작은 grid indicator (load tile dot).
    public static let indicatorXs: CGFloat = 5
    /// 6pt — phase pixel / small status dot.
    public static let indicatorXxs: CGFloat = 6
    /// 8pt — connection / status circle.
    public static let indicatorSm: CGFloat = 8
    /// 12pt — larger badge dot.
    public static let indicatorMd: CGFloat = 12

    // MARK: Bars / tracks / dots (모니터링 대시보드 표준)
    /// 3pt — 얇은 progress bar / joint delta bar / 트랙. KS B 9609 (안전 표지) 의
    /// 표시기 두께 권장 ≥ 2pt + 시인성 마진.
    public static let barTrackH: CGFloat = 3
    /// 5pt — sparkline 의 current value dot / center tick. NN/g
    /// *Data Visualization* 권장 — 5pt = 멀리서도 인지 가능한 minimum.
    public static let dot: CGFloat = 5
    /// 14pt — 리스트 row 의 leading icon column 표준 폭 (Apple HIG list row).
    public static let iconCol: CGFloat = 14
    /// 40pt — hero icon container (Apple HIG large icon container).
    public static let heroBox: CGFloat = 40

    // MARK: Icons (SF Symbol container — `.frame(width: N, height: N)`)
    /// 12pt — 매우 작은 inline icon.
    public static let iconXs: CGFloat = 12
    /// 16pt — 작은 icon (DPad / 인디케이터 hub).
    public static let iconSm: CGFloat = 16
    /// 18pt — 작은 button icon.
    public static let iconSm2: CGFloat = 18
    /// 22pt — 표준 toolbar icon (== `toolbarIcon`).
    public static let iconMd: CGFloat = 22
    /// 24pt — 작은 panel icon.
    public static let iconMd2: CGFloat = 24
    /// 28pt — 중간 badge.
    public static let iconLg: CGFloat = 28
    /// 32pt — 큰 button icon container.
    public static let iconXl: CGFloat = 32
    /// 36pt — 큰 panel icon.
    public static let iconXl2: CGFloat = 36
    /// 48pt — hero icon.
    public static let iconXxl: CGFloat = 48

    // MARK: Sidebar / Panel widths
    /// 사이드바 collapsed 상태 폭.
    public static let sidebarCollapsedW: CGFloat = 28
    /// 보조 사이드바 (torque load 등) 표준 폭.
    public static let secondarySidebarW: CGFloat = 158

    // MARK: Stroke / divider widths
    /// 일반 border (Apple HIG 0.5pt).
    public static let borderHairline: CGFloat = 0.5
    /// 강조 border (focus / selected).
    public static let borderStrong: CGFloat = 1
}

/// Elevation — Material Design 영감 + macOS 톤다운 그림자 단계.
///
/// **2026-05-19 v1.11.15 cycle 3**: flat tier 추가 — 흰색 플랫 테마에서 깊이 cue 보장.
/// 종전 `DFTheme.lightFlat` 은 그림자 0 (no shadow) 이었으나, 사용자 피드백 — 입체감
/// 부족. 매우 부드러운 (radius 1.5x, opacity 절반) 그림자로 카드 ↔ 배경 구분 강화.
public enum DFShadow {
    public static let none: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (.clear, 0, 0, 0)
    public static let card: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.06), 8, 0, 2)
    public static let popover: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.12), 16, 0, 4)
    public static let modal: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.24), 28, 0, 8)

    // MARK: - Flat tier (v1.11.15 cycle 3 — 무채색 테마 전용 깊이 cue)

    /// 흰색 플랫 — 카드 그림자 (부드럽고 차분).
    public static let flatCard: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.05), 10, 0, 2)
    /// 흰색 플랫 — popover/dropdown 그림자.
    public static let flatPopover: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.08), 20, 0, 5)
    /// 흰색 플랫 — modal / sheet 그림자.
    public static let flatModal: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.14), 36, 0, 10)
}

/// 애니메이션 — 표준 timing + semantic alias.
///
/// # 사용 규칙
/// - **Semantic alias 우선** (`.cardExpand`, `.modalPresent`) — 의도 명확.
/// - **Primitive (`.fast/.standard/.smooth/.bounce`)** — semantic alias 가 없을 때만.
/// - **WCAG 2.3**: 자동 reduce-motion 대응 — SwiftUI 의 withAnimation 이 시스템
///   설정 honor.
public enum DFAnimation {
    // Primitive timings
    /// 120ms ease-out — feedback (button press, hover state).
    public static let fast = Animation.easeOut(duration: 0.12)
    /// 220ms ease-out — 일반 UI 전환 (expand/collapse, toggle).
    public static let standard = Animation.easeOut(duration: 0.22)
    /// 400ms spring — 부드러운 motion (smooth navigation, card animations).
    public static let smooth = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// 500ms bouncy spring — 강조 motion (success state, attention).
    public static let bounce = Animation.spring(response: 0.5, dampingFraction: 0.7)

    // MARK: - 2026-05-16: Semantic aliases (의도 명확)

    /// 토글 / 펼침 / 접힘 (monitoring dashboard, sidebar 등).
    public static let toggle = standard
    /// 카드 expand / collapse (dashboard sections).
    public static let cardExpand = smooth
    /// Modal / sheet 등장.
    public static let modalPresent = smooth
    /// 리스트 row 변경 (insert / delete).
    public static let listChange = standard
    /// 페이지 / view 전환.
    public static let pageTransition = smooth
    /// 강조 (state change → danger, emergency).
    public static let emphasis = bounce
    /// hover / focus 상태 변경.
    public static let hover = fast
}

/// **2026-05-16**: Icon 시스템 — 텍스트와 짝지어진 아이콘의 크기 / weight 일관성.
///
/// # 사용 패턴 — **결정 트리**
///
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │ Q1: 아이콘이 텍스트와 인라인 (옆) 있는가?                       │
/// │   ├─ YES → DFFont.* (텍스트와 같은 토큰) — 자동 baseline 정렬   │
/// │   │       예: HStack { Image.font(DFFont.label) + Text.font(DFFont.label) } │
/// │   └─ NO (독립) → Q2                                          │
/// │ Q2: 아이콘이 고정 크기 박스 안에 있는가?                       │
/// │   ├─ YES → DFIcon.* (font) + DFSize.* (frame)                │
/// │   │       예: Image.font(DFIcon.hero).frame(40,40)            │
/// │   └─ NO (flex) → DFIcon.* (font) only                       │
/// └─────────────────────────────────────────────────────────────┘
/// ```
///
/// # 1. 인라인 패턴 (텍스트 옆)
/// 아이콘과 텍스트가 같은 행 — `DFFont.*` 사용 (자동 정렬):
/// ```swift
/// HStack {
///     Image(systemName: "checkmark").font(DFFont.label)
///     Text("확인").font(DFFont.label)
/// }
/// ```
/// 이유: `.font()` 가 텍스트의 baseline 과 line-height 에 자동 맞춤.
///
/// # 2. 독립 패턴 (큰 아이콘 + 박스)
/// 아이콘이 색 배경 박스 안 — `DFIcon.*` (font) + `DFSize.*` (frame):
/// ```swift
/// Image(systemName: "figure.balanced")
///     .font(DFIcon.hero)
///     .frame(width: DFSize.heroBox, height: DFSize.heroBox)
///     .background(color.opacity(DFOpacity.o15))
/// ```
/// 이유: `font` = 아이콘 자체 크기 / `frame` = 박스 크기 (독립 제어).
///
/// # Weight 규칙
/// - **state indicator (danger/warning/success)**: `.semibold` → `DFIcon.stateSmall/Medium/Large`
/// - **decorative / inline**: `.regular` → `DFIcon.body/caption/label/micro`
/// - **action button label icon**: `.medium` → `DFIcon.action`
///
/// # ❌ 비추천 패턴
/// - `Image.font(.system(size: 10))` — raw 숫자, 의미 X
/// - `Image.frame(width: 14)` only (font 없음) — 아이콘 크기가 frame 에 종속
public enum DFIcon {
    /// Hero icon (28pt semibold) — banner / 큰 표시기.
    public static let hero = Font.system(size: 28, weight: .semibold)
    /// Section icon (18pt semibold) — section header 옆 아이콘.
    public static let section = Font.system(size: 18, weight: .semibold)
    /// Body icon (14pt regular) — toolbar / 본문.
    public static let body = Font.system(size: 14)
    /// Caption icon (12pt regular) — pill / chip.
    public static let caption = Font.system(size: 12)
    /// Label icon (10pt regular) — small label inline.
    public static let label = Font.system(size: 10)
    /// Micro icon (9pt regular) — list row 의 leading icon.
    public static let micro = Font.system(size: 9)

    // Action 버튼 의 icon (medium weight = 강조)
    /// Action 버튼의 standard size icon.
    public static let action = Font.system(size: 14, weight: .medium)

    // State icon (semibold = 강조)
    /// 상태 표시 icon (small).
    public static let stateSmall = Font.system(size: 12, weight: .semibold)
    /// 상태 표시 icon (medium).
    public static let stateMedium = Font.system(size: 14, weight: .semibold)
    /// 상태 표시 icon (large).
    public static let stateLarge = Font.system(size: 18, weight: .semibold)
}

/// 불투명도 토큰 — 일관 dim/disabled/border 처리.
///
/// # 사용 규칙
/// - **Semantic alias 우선** (`.disabled`, `.dim`, `.ghost`, `.subtle`, `.strong`)
///   — 의도가 명확한 곳.
/// - **Numeric (o06 ~ o85)** — semantic 매핑이 없는 정확한 알파값 필요한 곳.
/// - Numeric 명명: `o<percent×100>` (e.g. `o35 = 0.35`).
public enum DFOpacity {
    // MARK: - Semantic
    public static let disabled: Double = 0.4
    public static let dim: Double = 0.6
    /// 거의 안 보임 — background tint (raw 0.06 통일).
    public static let ghost: Double = 0.06
    public static let subtle: Double = 0.12
    public static let strong: Double = 0.35

    // MARK: - Numeric (0.06 ~ 0.85, 5pp 단위)
    public static let o06: Double = 0.06
    public static let o10: Double = 0.10
    public static let o12: Double = 0.12
    public static let o15: Double = 0.15
    public static let o18: Double = 0.18
    public static let o20: Double = 0.20
    public static let o25: Double = 0.25
    public static let o30: Double = 0.30
    public static let o35: Double = 0.35
    public static let o40: Double = 0.40
    public static let o45: Double = 0.45
    public static let o50: Double = 0.50
    public static let o60: Double = 0.60
    public static let o70: Double = 0.70
    public static let o85: Double = 0.85
}

// MARK: - View modifiers (정형 helper)

public extension View {
    /// **카드 표준 modifier** — corner + border + shadow.
    ///
    /// **2026-05-19 v1.11.15 cycle 3**: 흰색 플랫 테마에서 자동 부드러운 그림자 적용.
    /// `shadow: false` (default) 라도 flat 모드면 `DFShadow.flatCard` 자동. 카드 ↔ 배경
    /// 구분이 명확해져 무채색 GUI 도 입체감 유지.
    ///
    /// # 사용 vs DFPanel
    ///
    /// | 사용 | 컴포넌트 |
    /// |---|---|
    /// | **간단한 카드** (just chrome) | `dfCard()` modifier (이) |
    /// | **구조화 카드** (title + content + footer) | `DFPanel` component |
    /// | **inline 패턴** (raw `.background + .clipShape`) | **❌ 비추천** — `dfCard()` 사용 |
    ///
    /// # 예시
    /// ```swift
    /// VStack { ... }
    ///     .dfCard()                          // 표준 (flat 모드 자동 부드러운 그림자)
    ///     .dfCard(radius: DFRadius.card)     // 명시 (= sm 8pt)
    ///     .dfCard(shadow: true)              // 모든 테마에서 그림자 강제
    ///     .dfCard(padded: false)             // padding 없이 chrome 만
    /// ```
    func dfCard(radius: CGFloat = DFRadius.md, padded: Bool = true,
                shadow: Bool = false) -> some View {
        modifier(DFCardModifier(radius: radius, padded: padded, explicitShadow: shadow))
    }

    /// 디스에이블 시 자연스러운 dim 처리.
    func dfDisabled(_ disabled: Bool) -> some View {
        self
            .opacity(disabled ? DFOpacity.disabled : 1)
            .allowsHitTesting(!disabled)
    }

    /// Pill 표준 패딩 — 12pt / 6pt (toolbar pill / status pill).
    ///
    /// 사용:
    /// ```swift
    /// Text("연결됨").dfPillPadding()  // .padding(.horizontal, 12).padding(.vertical, 6)
    /// ```
    func dfPillPadding() -> some View {
        self
            .padding(.horizontal, DFSize.pillPaddingH)
            .padding(.vertical, DFSize.pillPaddingV)
    }

    /// 표준 pill chrome — pill 패딩 + capsule clip + 0.5pt subtle 보더 + tint 배경 opacity.
    ///
    /// active = true 일 때 tint.opacity(0.14) 배경 + tint.opacity(0.35) 보더,
    /// active = false 면 secondary background + 더 흐린 보더.
    /// 디자인 ref: Apple HIG 8pt 그리드 + Linear 미묘 보더 (테두리 12% 알파).
    func dfPill(active: Bool, tint: Color) -> some View {
        self
            .dfPillPadding()
            .background(active ? tint.opacity(0.14) : DFColor.textSecondary.opacity(DFOpacity.ghost))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    active ? tint.opacity(DFOpacity.strong) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                    lineWidth: DFSize.borderHairline
                )
            )
    }

    /// 표준 카드 외곽선 — RoundedRectangle + 0.5pt subtle 보더.
    /// dfCard 안 쓰는 곳 (e.g. clipped 안 한 카드) 에서 사용.
    func dfCardBorder(radius: CGFloat = DFRadius.sm) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline)
        )
    }

    /// **macOS native cursor** — clickable area 에 pointing hand 표시.
    /// Apple HIG: interactive element 는 cursor 가 변경되어야 affordance 명확.
    /// SwiftUI 자체엔 API 없어 NSCursor wrapper 로 처리.
    ///
    /// 사용:
    /// ```swift
    /// Button { … } label: { … }.dfPointerCursor()
    /// ```
    func dfPointerCursor() -> some View {
        self.onHover { hovering in
            #if canImport(AppKit)
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
            #endif
        }
    }

    /// **Reduce Transparency 대응 material** — Apple HIG + WCAG.
    /// 시스템 Reduce Transparency 시: solid `card` 배경.
    /// 그 외: `material` (`.regularMaterial` / `.thickMaterial` 등).
    /// **2026-05-19 v1.11.15**: `DFTheme.lightFlat` 도 fallback 강제 — 플랫 모드는
    /// blur 효과 없이 solid 카드 색상 사용.
    ///
    /// 사용:
    /// ```swift
    /// .dfMaterial(.regularMaterial)
    /// ```
    func dfMaterial(_ material: Material = .regularMaterial,
                    fallback: Color = DFColor.card) -> some View {
        self.modifier(DFMaterialBackground(material: material, fallback: fallback))
    }

    /// **2026-05-19 v1.11.15**: 테마 인식 그림자.
    ///
    /// `DFTheme.lightFlat` (flat 모드) 일 때 shadow 비활성화 — 평평한 시각 효과.
    /// 그 외 테마는 일반 `.shadow(...)` 와 동일.
    ///
    /// 사용:
    /// ```swift
    /// myCard.dfThemedShadow(DFShadow.card)
    /// myCard.dfThemedShadow(color: .black.opacity(0.1), radius: 8, y: 2)
    /// ```
    func dfThemedShadow(_ shadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)) -> some View {
        modifier(DFThemedShadowModifier(color: shadow.color, radius: shadow.radius,
                                        x: shadow.x, y: shadow.y))
    }

    /// 명시 파라미터 변형 — DFShadow 토큰 없이 임시 그림자 적용.
    func dfThemedShadow(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(DFThemedShadowModifier(color: color, radius: radius, x: x, y: y))
    }

    /// **2026-05-19 v1.11.15 cycle 2**: 그래프/시각화 영역의 색 보존.
    ///
    /// `lightFlat` 테마에서 RootView 가 `.saturation(0)` 으로 전체 GUI 를 무채색화하지만,
    /// 차트/그래프 같은 데이터 시각화는 색이 인사이트 표현의 핵심. 본 modifier 는
    /// `.saturation(1.0)` 강제 적용하여 부모의 desaturate 를 무력화 — 차트 색이 살아남.
    ///
    /// 사용 사례:
    /// - `TelemetrySparkline`, `TimeSeriesStripChart`, `SafetySparkline`
    /// - 임의 `Chart { ... }` SwiftUI Charts 컨테이너
    /// - PoseInspector 의 joint delta bar 등
    ///
    /// 차트의 default tint 가 `DFColor.forge` (푸른색 메인 컬러) 이면 무채색 GUI 안에서
    /// 푸른 강조로 표시되어 시각적 위계 명확.
    ///
    /// 사용:
    /// ```swift
    /// TelemetrySparkline(samples: data, range: r, label: "Roll").dfChartAccent()
    /// ```
    func dfChartAccent() -> some View {
        self.saturation(1.0)
    }
}

/// **v1.11.15 cycle 3**: 카드 chrome — flat 모드 자동 부드러운 그림자 인식.
private struct DFCardModifier: ViewModifier {
    let radius: CGFloat
    let padded: Bool
    let explicitShadow: Bool

    @Environment(\.dfTheme) private var theme: DFTheme

    func body(content: Content) -> some View {
        let shadowSpec = resolveShadow()
        content
            .padding(padded ? DFSpace.md : 0)
            .background(DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: 0.5)
            )
            .shadow(color: shadowSpec.color, radius: shadowSpec.radius,
                    x: shadowSpec.x, y: shadowSpec.y)
    }

    private func resolveShadow() -> (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
        if explicitShadow {
            // 명시 호출자 — flat 모드면 flatCard (부드러움), 그 외 일반 card 그림자.
            return theme.isFlat ? DFShadow.flatCard : DFShadow.card
        }
        if theme.isFlat {
            // flat 모드 자동 — 사용자 명시 X 라도 부드러운 그림자 (사용자 피드백).
            return DFShadow.flatCard
        }
        // 비 flat + 명시 X — 그림자 없음 (기존 동작 보존, visual regression 차단).
        return DFShadow.none
    }
}

/// 테마 인식 그림자 modifier.
///
/// **2026-05-19 v1.11.15 cycle 3 (사용자 피드백 반영)**: 종전 flat 모드 = no-op 으로
/// 그림자 제거했으나 카드 ↔ 배경 구분이 약해진다는 피드백. 이제 flat 모드에서도
/// 부드러운 (radius 1.4x, color 그대로) 그림자 적용 — 호출자 color hint 보존.
private struct DFThemedShadowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    @Environment(\.dfTheme) private var theme: DFTheme

    func body(content: Content) -> some View {
        if theme.isFlat {
            // flat 모드: 더 큰 radius, 그러나 호출자 color (대개 black low-opacity 또는
            // tint low-opacity) 그대로. saturation(0) 가 hue 를 자동 grayscale 처리.
            content.shadow(color: color, radius: radius * 1.4, x: x, y: max(y, 1))
        } else {
            content.shadow(color: color, radius: radius, x: x, y: y)
        }
    }
}

/// Reduce Transparency 대응 material background.
/// 시스템 설정 → 손쉬운 사용 → 디스플레이 → 투명도 줄이기 ON → solid color.
/// **2026-05-19 v1.11.15**: `DFTheme.lightFlat` 도 같은 fallback 사용 — 플랫 모드는
/// blur 효과 없이 평평한 표면 유지.
private struct DFMaterialBackground: ViewModifier {
    let material: Material
    let fallback: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dfTheme) private var theme: DFTheme

    func body(content: Content) -> some View {
        if reduceTransparency || theme.isFlat {
            content.background(fallback)
        } else {
            content.background(material)
        }
    }
}

// MARK: - Color helpers (light/dark hex)

extension Color {
    /// hex 문자열에서 light/dark 분기 색상 생성.
    init(light: String, dark: String) {
        self.init(light: light, dark: dark,
                  highContrastLight: nil, highContrastDark: nil)
    }

    /// **2026-05-16**: High Contrast variant 지원.
    ///
    /// macOS Accessibility "디스플레이 → 대비 늘리기" ON 시 자동 적용.
    /// `highContrastLight` / `highContrastDark` nil 이면 light/dark fallback.
    ///
    /// # WCAG AAA 명도비
    ///
    /// 일반 모드: 4.5:1 (AA) 이상 권장. high contrast: 7:1 (AAA) 이상.
    /// 자세한 명도비 검증은 Apple Accessibility Inspector 또는 WCAG 도구 사용.
    init(light: String, dark: String,
         highContrastLight: String?, highContrastDark: String?) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.name {
            case .accessibilityHighContrastDarkAqua,
                 .accessibilityHighContrastVibrantDark:
                return NSColor(hex: highContrastDark ?? dark) ?? .systemGray
            case .darkAqua, .vibrantDark:
                return NSColor(hex: dark) ?? .systemGray
            case .accessibilityHighContrastAqua,
                 .accessibilityHighContrastVibrantLight:
                return NSColor(hex: highContrastLight ?? light) ?? .systemGray
            default:
                return NSColor(hex: light) ?? .systemGray
            }
        })
        #else
        self = Color(hex: light) ?? .gray
        #endif
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

#if canImport(AppKit)
import AppKit
extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1.0
        )
    }
}
#endif
