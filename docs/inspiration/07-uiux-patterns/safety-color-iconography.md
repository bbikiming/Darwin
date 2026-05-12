# 안전 색상 / 아이콘 표준

> DarwinForge가 이미 채택한 ISO 13850 + KS S ISO 7010 보강.

## 1. ISO 13850 — 비상정지 (E-Stop)

산업 기계 안전 표준. 휴머노이드도 적용 권고.

| 요소 | 규격 |
|------|------|
| 버튼 색 | **빨강 (Pantone 485C 근사, sRGB ~ #DA291C)** |
| 배경 색 | **노랑 (Pantone 109C 근사, sRGB ~ #FFCC00)** |
| 형태 | mushroom-head (push to stop, twist to release) |
| 위치 | 한 손이 즉시 닿는 거리 (50 cm 이내) |
| 조작 | 단동 작동 — push-to-engage |
| 카테고리 | Cat-0 (즉시 차단) 또는 Cat-1 (제어된 정지 후 차단) |

DarwinForge `EStopButton`:
```swift
struct EStopButton: View {
    var body: some View {
        ZStack {
            Circle().fill(DFColor.estopYellow)         // #FFCC00
                .frame(width: 56, height: 56)
            Circle().fill(DFColor.estopRed)            // #DA291C
                .frame(width: 44, height: 44)
            Image(systemName: "octagon.fill")
                .foregroundStyle(.white)
        }
    }
}
```

✅ 이미 채용. 좌상단 항상 가시.

## 2. KS S ISO 7010 — 안전 표지 색상

한국 산업 표준. 안전 색상 + 형태 매핑.

| 의미 | 색상 | 형태 | DarwinForge 사용 |
|------|------|------|------------------|
| **금지 (Prohibition)** | 빨강 | 원 + 빗금 | 위험 명령 거부 시 |
| **경고 (Warning)** | 노랑 | 삼각형 | 전압 < 9.5V 등 |
| **지시 (Mandatory)** | 파랑 | 원 | "토크 끄세요" 등 |
| **안전 조건 (Safe)** | 초록 | 정사각형 | 정상 상태 / OK |
| **소방 (Fire)** | 빨강 | 정사각형 | 우리 미사용 |

DarwinForge에서:
- `StatusPill`이 4 severity (info / warning / danger / success)
- 각 severity = 색 + 아이콘 + 텍스트 3중 의미 → 색맹 사용자도 인지 가능

## 3. ISO 3864 — 안전 색 좌표

CIE 1931 (x, y) 좌표 권고:
- Red: (0.690, 0.305)
- Yellow: (0.515, 0.475)
- Green: (0.300, 0.495)
- Blue: (0.130, 0.105)

sRGB 환산:
- DFColor.danger  ≈ #D32F2F (RoboPlus와 비슷)
- DFColor.warning ≈ #F9A825
- DFColor.success ≈ #388E3C
- DFColor.info    ≈ #1976D2

## 4. Apple HIG 색

macOS는 system color (System Red / Yellow / Green / Blue). 우리는
NSColor 기반으로 시스템 dark mode에 자동 대응.

```swift
DFColor.danger = Color(.systemRed)
DFColor.warning = Color(.systemOrange)
DFColor.success = Color(.systemGreen)
DFColor.info = Color(.systemBlue)
```

## 5. 색 + 아이콘 + 텍스트 3중 의미

**색맹 사용자 (인구 ~5%)** 와 **저시력 사용자**도 정보를 잃지 않도록.

```swift
struct StatusPill: View {
    let severity: Severity
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severity.icon)
            Text(label)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(severity.color.opacity(0.18))
        .foregroundStyle(severity.color)
        .clipShape(Capsule())
    }
}

enum Severity {
    case info, success, warning, danger

    var color: Color {
        switch self {
        case .info: return DFColor.info
        case .success: return DFColor.success
        case .warning: return DFColor.warning
        case .danger: return DFColor.danger
        }
    }

    var icon: String {  // SF Symbols
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        }
    }
}
```

✅ DarwinForge 이미 채택.

## 출처

- ISO 13850 (비상 정지): https://www.iso.org/standard/59970.html
- KS S ISO 7010: https://standard.go.kr/KSCI/standardIntro/getStandardSearchList.do
- ISO 3864: https://www.iso.org/standard/52030.html
- Apple HIG Color: https://developer.apple.com/design/human-interface-guidelines/color
- W3C WCAG 2.2 contrast: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum
