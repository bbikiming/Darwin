# 접근성 — WCAG 2.3 + Apple Accessibility

## WCAG 2.3 (2024 기준) 핵심

> Web Content Accessibility Guidelines. 비록 우리는 macOS 네이티브 앱이지만
> SwiftUI도 동일 원칙 적용 가능.

| 원칙 | 요점 |
|------|------|
| 1. Perceivable | 색 + 아이콘 + 텍스트 3중, alt text, 자막 |
| 2. Operable | 키보드 전용 조작 가능, 단축키, 충분한 시간 |
| 3. Understandable | 일관된 라이팅, 에러 메시지, 도움말 |
| 4. Robust | 표준 컴포넌트 사용 (= NSAccessibility / SwiftUI accessibility modifier) |

## Apple Accessibility (macOS)

### 1. VoiceOver (스크린 리더)
- 모든 인터랙티브 요소에 `.accessibilityLabel` 필수
- 한국어: `Locale("ko-KR")` 음성 선택
- 그룹화: `.accessibilityElement(children: .combine)`

### 2. Reduce Motion
- 사용자 시스템 설정 — 애니메이션 최소화
- SwiftUI: `@Environment(\.accessibilityReduceMotion) private var reduce`

```swift
.animation(reduce ? nil : .easeInOut, value: someState)
```

### 3. Dynamic Type
- 시스템 글꼴 크기 변경 자동 반영
- `Font.system(size: 14, weight: .regular)`보다 `Font.body` 권장

### 4. Increased Contrast
- `@Environment(\.colorSchemeContrast)` — `.standard` / `.increased`
- 우리 `DFColor`가 자동 대응 (NSColor 시스템 색)

### 5. Color Filters
- 색맹 모드 — 우리는 색+아이콘 3중으로 이미 대응

### 6. Voice Control
- 사용자가 음성으로 macOS 조작
- 모든 버튼이 라벨 보이게 — `.accessibilityLabel` 일치 권장

## DarwinForge 점검

### ✅ 채택
- 색 + 아이콘 + 텍스트 (StatusPill)
- @Environment(\.accessibilityReduceMotion)
- macOS HIG 표준 컴포넌트 (NavigationSplitView, Button, Toggle, Slider)

### ⏳ 보강 필요
- VoiceOver label 한국어 본격 통일 (현재 일부 한국어, 일부 SwiftUI default)
- Dynamic Type 검증 (큰 글꼴에서 레이아웃 깨짐 없는지)
- Voice Control 테스트 (모든 버튼이 라벨로 호명 가능?)

## 코드 예시

```swift
Button {
    runTask()
} label: {
    Label("연결하기", systemImage: "link")
}
.accessibilityLabel("로봇 연결 시작")
.accessibilityHint("선택한 USB 포트로 ROBOTIS 보드와 통신을 엽니다.")
.accessibilityIdentifier("connect-button")
```

## 한국어 VoiceOver 라벨 가이드

- **명령형 X, 설명형 O**
  - 나쁨: "연결" — 사용자에게 행동 명령처럼 들림
  - 좋음: "로봇 연결 시작" — 무엇이 일어나는지 설명
- **단위 함께**
  - "12.3 V" → "12점 3 볼트"
  - "127°C" → "127도"
- **약어 풀어쓰기**
  - "USB" → 그대로
  - "MX-28" → "엠엑스 28"
  - "JID 5" → "관절 ID 5번"

## 키보드 단축키 일관성

| macOS 표준 | DarwinForge |
|-----------|-------------|
| ⌘N (새로 만들기) | ⌘N — 새 모션 페이지 |
| ⌘O (열기) | ⌘O — .mtn 파일 열기 |
| ⌘S (저장) | ⌘S — 모션 저장 |
| ⌘W (창 닫기) | 표준 |
| ⌘, (설정) | 표준 |
| ⌘? (도움말) | 표준 |
| **사용자 정의** | ⌘1 (대화) / ⌘⇧E (전문가) / ESC (e-stop) |

## 출처

- WCAG 2.3: https://www.w3.org/WAI/standards-guidelines/wcag/
- Apple Accessibility: https://developer.apple.com/accessibility/
- SwiftUI Accessibility: https://developer.apple.com/documentation/swiftui/accessibility
- macOS Voice Control: https://support.apple.com/guide/mac-help/use-voice-control-mh40719/mac
