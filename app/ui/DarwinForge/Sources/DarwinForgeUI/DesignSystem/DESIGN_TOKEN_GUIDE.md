# DarwinForge Design Token 사용 가이드

**2026-05-16**: monitoring 영역 100% 통합 + broader app 점진 migration 중.

## 빠른 결정 트리

### 폰트 (DFFont)

```
사용 상황 → 토큰
─────────────────────────────────────────────────────
hero icon (40×40 큰 아이콘)    → DFFont.heroIcon (28pt semibold)
hero state label ("정상"/"위험") → DFFont.heroState (20pt semibold)
hero tilt value ("28.3°")     → DFFont.dataLarge (18pt semibold mono digit)

modal sheet 제목 ("위험한 보행 모드") → DFFont.modalHeader (22pt semibold)
modal sheet 강조 ("위험") → DFFont.modalHero (20pt bold)

page section 제목 ("Walk Lab") → DFFont.sectionMedium (16pt semibold)
sub-section header ("6-Layer 안전") → DFFont.sectionLabel (10pt medium)
card 제목 ("안전 상태: 정상")  → DFFont.captionEmph (11pt medium)
toggle bar 제목 ("Fall Prevention") → DFFont.sectionBody (12pt semibold)

본문 13pt    → DFFont.body
본문 13pt 강조 → DFFont.bodyEmph
본문 12pt    → DFFont.bodySmall
본문 12pt 강조 → DFFont.bodySmallEmph

cap 11pt    → DFFont.caption
caption 11pt 강조 → DFFont.captionEmph

label 10pt 일반 → DFFont.label
label 10pt 강조 → DFFont.labelStrong (semibold)

micro 9pt    → DFFont.micro

monospace 12pt 본문 → DFFont.mono
mono 13pt semibold → DFFont.monoBody (phase label 등)
mono 11pt → DFFont.monoCaption
mono 10pt → DFFont.monoLabel
mono 9pt → DFFont.monoMicro

데이터 값 표시 (숫자 정렬 필수):
  9pt micro 값 → DFFont.dataMicro
  11pt small 값 → DFFont.dataSmall
  12pt medium 값 → DFFont.dataMedium
  18pt large 값 → DFFont.dataLarge

데이터 source pill (8pt) → DFFont.pill
```

### 색상 (DFColor)

```
의미 → 토큰
─────────────────────────────────────────────────────
정상 / 성공 / OK            → DFColor.success
주의 / 경고 (낮은 강도)     → DFColor.warning
심각 / 강한 경고 (중간 단계) → DFColor.severe   ← NEW (warning↔danger)
위험 / 비상 / 오류           → DFColor.danger
정보 / telemetry            → DFColor.info
모터 / 토크 시각화           → DFColor.torque

표면:
canvas (윈도우 배경)         → DFColor.canvas
card                        → DFColor.card
nested card                 → DFColor.elev2
sub-panel (level 3)         → DFColor.elev3

텍스트:
primary                     → DFColor.textPrimary
secondary / muted            → DFColor.textSecondary

상호작용:
hover bg                    → DFColor.hoverBg
selected bg                 → DFColor.selectedBg
focus ring                  → DFColor.focusRing
disabled overlay            → DFColor.disabledOverlay

브랜드:
forge accent                → DFColor.forge
generic accent              → DFColor.accent

❌ 절대 금지:
.red, .green, .yellow, .orange, .blue, .purple (system color literals)
→ 의미 토큰 사용. WCAG color-blind safe X.
```

### 아이콘 (DFIcon + Image)

```
컨텍스트 → 토큰
─────────────────────────────────────────────────────
인라인 with 텍스트 → 텍스트와 같은 DFFont 사용 (자동 정렬)
  예: Text("정상").font(DFFont.label)
      Image(systemName: "...").font(DFFont.label)

독립 / 큰 아이콘 → DFIcon.* + .frame()
  hero icon (40pt 박스 안) → DFIcon.hero + DFSize.heroBox
  section icon (header 옆) → DFIcon.section
  toolbar icon → DFIcon.body
  pill icon → DFIcon.caption
  list row icon → DFIcon.micro

상태 표시 아이콘 (강조):
  small state → DFIcon.stateSmall (12pt semibold)
  medium → DFIcon.stateMedium (14pt semibold)
  large → DFIcon.stateLarge (18pt semibold)
```

### 간격 (DFSpace)

```
사용 → 토큰
─────────────────────────────────────────────────────
0pt → DFSpace.none
1pt → DFSpace.micro (pixel-perfect)
2pt → DFSpace.micro2 (조밀 inline)
4pt → DFSpace.xs (tight grouping)
6pt → DFSpace.xs2 (pill vertical)
8pt → DFSpace.sm (standard inner)
10pt → DFSpace.sm2 (toolbar pill gap)
12pt → DFSpace.sm3 (pill horizontal)
16pt → DFSpace.md (section padding)
20pt → DFSpace.md2 (modal inner)
24pt → DFSpace.lg (section breathing)
32pt → DFSpace.xl (hero spacing)
48pt → DFSpace.xxl (big hero)
```

### 코너 라운드 (DFRadius)

```
사용 → 토큰
─────────────────────────────────────────────────────
2pt → DFRadius.tiny (event log row hint)
4pt → DFRadius.xs (status tile)
6pt → DFRadius.xs2 (button / pill / 작은 indicator)
8pt → DFRadius.sm (표준 card)
12pt → DFRadius.md (큰 card)
16pt → DFRadius.lg (모달)
20pt → DFRadius.xl
999pt → DFRadius.full (capsule)
```

### 애니메이션 (DFAnimation)

```
의도 → 토큰
─────────────────────────────────────────────────────
hover / focus    → DFAnimation.hover (fast 120ms)
toggle / expand  → DFAnimation.toggle (standard 220ms)
card expand      → DFAnimation.cardExpand (smooth spring)
modal present    → DFAnimation.modalPresent (smooth spring)
list change      → DFAnimation.listChange (standard)
page transition  → DFAnimation.pageTransition (smooth)
emphasis (danger) → DFAnimation.emphasis (bouncy)

❌ 비추천:
Animation.easeOut(duration: 0.X) raw 사용 — 의미 불명.
```

### 불투명도 (DFOpacity)

```
의미 → 토큰
─────────────────────────────────────────────────────
disabled control → DFOpacity.disabled (0.4)
dim text         → DFOpacity.dim (0.6)
ghost background → DFOpacity.ghost (0.06)
subtle border    → DFOpacity.subtle (0.12)
strong border    → DFOpacity.strong (0.35)

정확한 수치 (numeric)  → DFOpacity.o06 ~ o85
```

## 컴포넌트 우선순위

### 항상 컴포넌트 우선 (재구현 금지)

| 패턴 | 사용 |
|---|---|
| 데이터 source pill (sim/real/stale) | `DFSourcePill(label:tint:leading:)` |
| 안전 layer tile (icon+value+threshold) | `DFStatusTile(name:icon:valueLabel:unit:thresholdLabel:tint:sourcePill:)` |
| 카드 외곽선 | `.dfCard()` modifier |
| Pill chrome (badge) | `.dfPill(active:tint:)` modifier |
| pointing hand cursor | `.dfPointerCursor()` modifier |
| Material background (Reduce Transparency 대응) | `.dfMaterial(.regularMaterial)` modifier |

### 기존 component (사용 가능)

DFButton, DFChip, DFBadge, DFSectionHeader, DFEmptyState, DFKeyboardHint, DFPanel, DFMetricRow, DFKeyValueGrid, DFPageScaffold, DFProgressDots.

## 검증 도구

### SwiftLint (advisory)

```bash
brew install swiftlint
swiftlint lint
```

`.swiftlint.yml` 의 5 custom rule 이 raw value 사용 경고:
- `df_no_raw_padding`
- `df_no_raw_spacing`
- `df_no_raw_corner_radius`
- `df_no_raw_opacity`
- `df_prefer_dfcolor_over_system_named`

### 마이그레이션 현황 (2026-05-16)

| 영역 | font.system 사용 | 마이그레이션 |
|---|---:|---|
| **WalkLab monitoring** (5 files) | 0 | ✓ 100% |
| RootView | 26 | ⚪ pending |
| Expert/WalkDiagnostics | 25 | ⚪ pending |
| Connection (Wizard + Dashboard) | 38 | ⚪ pending |
| Motion (TransportBar + Studio) | 30 | ⚪ pending |
| Expert/Dashboard | 16 | ⚪ pending |
| Components/TorqueLoadSidebar | 14 | ⚪ pending |
| MotionLibraryView | 13 | ⚪ pending |
| Teach | 12 | ⚪ pending |
| 기타 | ~150 | ⚪ pending |
| **전체** | **330** | **~10% 완료** |

**별도 sprint × 4-5 회** 필요. 점진 적용 — 각 영역별 PR.
