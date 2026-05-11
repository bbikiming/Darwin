# 브랜드 자산

## 로고

| 파일 | 용도 | 미리보기 |
|------|------|----------|
| `logo-darwinforge.svg` | 메인 워드마크 — README 헤더, About 화면, 문서 표지 | 헥사곤 마크 + "DarwinForge" |
| `logo-darwinforge-mark.svg` | 마크 단독 — 앱 아이콘 소스, 파비콘, 컴팩트 사이드바, status pill | 헥사곤 200×200 |
| `badge-darwin-op-compatible.svg` | shields.io 스타일 호환성 배지 — README 상단, 도움말 푸터 | "WORKS WITH \| DARwIn-OP / OP2" |

## 컬러 토큰

| 토큰 | 16진 | 용도 |
|------|------|------|
| Slate | `#2E3940` | "Darwin" 텍스트, 헥사곤 본체, 어두운 UI 표면 |
| Forge | `#E97132` | "Forge" 텍스트, 마크의 스파크 액센트, 강조 |

`DarwinForgeUI/DesignSystem/DesignTokens.swift`의 `DFColor.slate`, `DFColor.forge`와 정확히 동일.

## SwiftUI 안에서 쓰기

```swift
import DarwinForgeUI

// 전체 로고 (마크 + 텍스트)
DarwinForgeLogo(variant: .full, density: .standard)

// 마크만 (사이드바, 컴팩트 위치)
DarwinForgeLogo(variant: .markOnly, density: .compact)

// 워드마크만 (이미 다른 곳에 마크가 있는 헤더)
DarwinForgeLogo(variant: .wordmarkOnly, density: .prominent)
```

## 사용 규칙

- 마크의 형상(헥사곤 + 스파크)과 색 두 가지는 변경하지 말 것. 다른 컬러로 색칠하지 말 것.
- 마크 주변에 최소 마크 높이의 ¼만큼 여백을 둘 것.
- 워드마크의 "Darwin"과 "Forge"는 절대 분리하지 말 것 (한 단어처럼 취급).
- DARwIn-OP / OP2는 ROBOTIS의 하드웨어 제품명. 호환성 배지에서 *팩트적 표기*로만 사용. ROBOTIS 공식 워드마크/로고를 차용하지 말 것.

## 상표 표기

DarwinForge와 그 마크는 본 프로젝트의 자체 브랜드 자산이다. ROBOTIS, DARwIn-OP, ROBOTIS-OP2 는 ROBOTIS의 등록 상표이며, 본 프로젝트는 ROBOTIS와 직접적인 제휴 관계가 없는 비공식(unofficial) 호환 도구다.
