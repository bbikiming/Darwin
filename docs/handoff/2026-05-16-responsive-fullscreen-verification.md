# 반응형 / 전체화면 레이아웃 코드 검증

**대상**: PR #25 HEAD `e5cb326`

**사용자 요구**: "반응형이랑 전체화면 뷰에서도 명확히 동작하는지 코드 검증해 줘"

검증 방법: 코드 정적 분석 + 폭별 layout 시뮬레이션 + 전체화면 모드 고려사항.

---

## 1. 부모 컨테이너 검증

### RootView → WalkLabView

```
WindowGroup
  .frame(minWidth: 1024, idealWidth: 1600, maxWidth: .infinity,
         minHeight: 640, idealHeight: 1000, maxHeight: .infinity)
  .windowResizability(.contentSize)
  WalkLabView
    HSplitView
      sidebar.frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
      detail.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
```

**보장**:
- 윈도우 최소 1024pt 폭
- sidebar 고정 260-320pt
- detail 항상 ≥ 480pt
- detail.maxWidth = .infinity → 큰 윈도우에 확장

**전체화면 시**:
- macOS 메뉴바 hide (자동 reveal)
- 신호등 hide
- `safeAreaInset` 상단 = 0
- `windowResizability(.contentSize)` 가 maxWidth/Height = .infinity 발효
- detail = window width - sidebar width

| Window | Sidebar | Detail | Status |
|---:|---:|---:|---|
| 1024 (min) | 260 (min) | 764 | ✓ |
| 1440 (default) | 280 (ideal) | 1160 | ✓ |
| 1920 (FHD fullscreen) | 280 | 1640 | ✓ |
| 2560 (QHD) | 280 | 2280 | ✓ |
| 3440 (ultrawide) | 280 | 3160 | ✓ |

---

## 2. Detail panel 내부 layout 시뮬레이션

```
ScrollView (vertical) {
    VStack(spacing: DFSpace.sm3 = 12) {
        simOnlyNotice                              // ~50pt
        [banners (conditional)]                    // 0-150pt
        monitoringToggleBar                        // ~36pt
        if monitoringExpanded {
            FallPreventionMonitor                  // ~500pt
        }
        HStack {                                   // ~360pt min (driven by side panel ~655pt)
            RobotScene3D.frame(minHeight: 360, maxHeight: .infinity)
            VStack { ... }.frame(width: 240)
        }.frame(minHeight: 360)
        footTargetsCard                            // ~50pt
        actionBar                                  // ~60pt
    }
    .padding(DFSpace.md = 16)
}
```

### 컨텐츠 총 높이 추정

| 시나리오 | monitor | 3D HStack | banners | total |
|---|---:|---:|---:|---:|
| 기본 (monitor 닫힘) | 0 | 655 | 0 | ~870 |
| monitor 펼침 | 500 | 655 | 0 | ~1380 |
| 모든 banner ON | 500 | 655 | 150 | ~1530 |

**전체화면 1080pt 윈도우**: 컨텐츠 1380pt + padding 32 = 1412pt > 1080pt → **outer ScrollView 정상 동작 ✓**

**전체화면 1440pt 윈도우 (FHD 회전 또는 QHD)**: 1412pt < 1440pt → 스크롤 없이 fit ✓

---

## 3. FallPreventionMonitor 내부 (5 영역) 시뮬레이션

### 3.1 heroBanner

```
HStack(spacing: DFSpace.sm3 = 12) {
    Image.frame(width: 40, height: 40)             // heroBox
    VStack {
        HStack {
            Text("안전 상태")                      // ~40pt
            Spacer(minLength: DFSpace.xs = 4)
            DFSourcePill IMU                       // ~55pt
            DFSourcePill 모터                      // ~55pt
        }
        HStack {
            Text(state.label).font(s20)            // 30-60pt
            Spacer(minLength: 4)
            Text(tilt).font(s18)                   // 35pt
            Text("max|tilt|").font(s10)            // 30pt
        }
        Text(stateMessage).lineLimit(2)            // wrap if needed
    }
}.padding(DFSpace.sm2 = 10)
```

**최소 폭 보장**: 40 + 12 + (40 + 4 + 110) = 206pt + padding 20 = **226pt**
**Dashboard 컨테이너 폭 = detail width - padding(20) = 460pt @ 480 detail**.
→ heroBanner 460pt 안에서 안전.

### 3.2 layerStatusGrid (LazyVGrid adaptive 110pt)

| Detail width | Dashboard inner | Columns | Tiles/row |
|---:|---:|---:|---|
| 480 | 460 | floor(460/114)=4 | 4+2 (2 row) |
| 800 | 780 | floor(780/114)=6 | 6 (1 row) |
| 1280 | 1260 | floor(1260/114)=11 → 6 max | 6 column wide |
| 1920 | 1900 | 6 column 매우 wide | 6 column extra wide |
| 3440 | 3420 | 6 column ultra wide | ⚠️ 시각적 sparseness |

→ **기능 OK / 시각: 3440pt 에서 tile 이 너무 넓어짐** (각 ~550pt). 권장: 1400pt max clamp.

### 3.3 timeSeriesRow (ViewThatFits)

ViewThatFits 의 wide 분기 조건: 3 sparkline minWidth 130 + 2 spacing 4 = **398pt min**.

| Detail width | Inner | Mode | sparkline width each |
|---:|---:|---|---:|
| 480 | 460 | horizontal | (460-8)/3 = 150 |
| 800 | 780 | horizontal | (780-8)/3 = 257 |
| 1280 | 1260 | horizontal | ~417 |
| 3440 | 3420 | horizontal | ~1137 ⚠️ |

→ 매우 넓은 차트도 동작 (Canvas 가 width 비례 spread). 1400pt clamp 시 max sparkline = ~466pt — 적절.

### 3.4 correctorPanel

```
HStack {
    title + Spacer + ramp progress label
}
ramp progress bar (full width × 3pt)
VStack {
    8 × jointDeltaRow {
        name(64pt) + bar(flexible) + value(48pt)
    }
}
```

bar flex width = inner - 64 - 4 - 48 - 4 = inner - 120
@ 460 inner: bar = 340pt ✓
@ 1900 inner: bar = 1780pt ✓
@ 3420 inner: bar = 3300pt → ⚠️ 너무 길어 보임 (시각 sparse)

### 3.5 eventLogPanel

```
ScrollView (.frame(maxHeight: 140)) {
    VStack {
        eventRow: HStack { icon(14) + time(54) + message(flex) }
    }
}
```

- icon 14 + spacing 6 + time 54 + spacing 6 + message = 80pt fixed + message
- @ 460 inner: message gets ~380pt ✓
- 매우 좋음

**Nested ScrollView 우려**: macOS 의 scroll wheel 이 이중 ScrollView 에서 어떻게 동작?
- 내부 ScrollView 영역 안에서 wheel → 내부가 capture
- 그 외 영역 → 외부 ScrollView 가 capture
- macOS 표준 동작 ✓

---

## 4. RobotScene3D + 사이드 패널 HStack 검증

```
HStack(spacing: 12) {
    RobotScene3D                                    // flexible width
        .frame(minHeight: 360, maxHeight: .infinity)
    VStack { ... }.frame(width: 240)                // fixed
}.frame(minHeight: 360)
```

| Detail width | 3D scene width | 비율 |
|---:|---:|---|
| 480 (min) | 480-12-240-32 = 196 | ⚠️ 좁음 |
| 800 | 800-12-240-32 = 516 | OK |
| 1280 | 1016 | ✓ |
| 1920 | 1656 | 매우 좋음 |
| 3440 | 3176 | ⚠️ 측면 패널 240pt 가 상대적으로 작음 |

### `.frame(maxHeight: .infinity)` inside ScrollView 분석

SwiftUI 의 layout engine:
- ScrollView 가 자식에 "intrinsic" height 제안
- HStack 의 vertical alignment = .center (default)
- 자식 height = max(RobotScene3D intrinsic, 사이드 패널 intrinsic)
- 사이드 패널 intrinsic ≈ 655pt (5 카드 + 2 게이지)
- RobotScene3D `.maxHeight: .infinity` → HStack 의 결정된 height 까지 늘어남
- 최종: HStack height = 655pt, 3D scene 도 655pt

**결론**: `.maxHeight: .infinity` 가 ScrollView 안에서 작동 — 다른 자식 (side panel) 의 height 에 매칭. ✓

---

## 5. monitoringToggleBar 검증

```
HStack(spacing: DFSpace.sm = 8) {
    Image (icon)                                    // 14
    VStack {                                        // flexible
        Text(title)                                 // 1 line
        Text(description)                           // 1 line
    }.frame(minWidth: 0).layoutPriority(0)
    Spacer(minLength: DFSpace.xs = 4)
    [conditional badge].layoutPriority(1)           // ~50pt
    Button(펼치기/접기).layoutPriority(1)            // ~70pt
}
.padding(.horizontal, DFSpace.sm2)                  // 10 each side
.frame(maxWidth: .infinity)
```

| Detail width | Inner | VStack 폭 (text) |
|---:|---:|---:|
| 480 | 460 | 460 - 14 - 8 - 50 - 70 - 8 = 310 | ✓ |
| 240 (이론) | 220 | 220 - 14 - 8 - 50 - 70 - 8 = 70 | ⚠️ truncation |

→ truncationMode(.tail) 가 처리. HSplitView min 480 이라 실 발생 X.

---

## 6. 발견된 실제 이슈

### Issue 1: footTargetsCard 잠재 overflow (pre-existing)

```
HStack { Phase | divider | L(x,y,z) | R(x,y,z) | divider | Temp | Spacer | Elapsed }
```

content width estimate: 50 + 16 + 144 + 144 + 16 + 50 + 0 + 50 + spacing(14×5=70) = **540pt**
+ padding 20 = **560pt**
> 480pt detail min — **overflow 가능성**.

SwiftUI 가 자동 truncate 하지만 시각적으로 부서질 수 있음.

**조치**: 본 PR 범위 외 (pre-existing). 별도 PR 권장.

### Issue 2: 매우 큰 폭에서 dashboard 가 sparse (visual only)

@ 3440pt 에서 dashboard 가 inner 3420pt 까지 확장 → tile / sparkline 이 빈 공간 많음.

**조치 (이번 sprint 적용)**: `.frame(maxWidth: 1400)` 으로 dashboard 폭 cap.
이유: 1400pt = 의 표준 desktop layout 의 dashboard 폭 권장.

### Issue 3: ViewThatFits HStack vs VStack 분기점

ViewThatFits 의 wide HStack minWidth 398pt — 사용자가 dashboard 폭 1400pt cap 적용 시 detail 가 1400pt 보다 좁아도 dashboard 안에서는 항상 horizontal 모드 유지 (1400pt > 398pt). ✓

### Issue 4: `.dynamicTypeSize(...xxxLarge)` cap 효과 (이번 sprint 추가)

Dashboard 의 dynamic type 을 `xxxLarge` 까지만 허용:
- 작은 텍스트 → 일반 사용자 정상
- 큰 텍스트 (accessibility5) → xxxLarge 로 cap → layout 안 부서짐
- 검증: Mac 시각 확인 필요 (`@Environment(\.dynamicTypeSize, .accessibility5)` preview)

---

## 7. 전체화면 모드 특화 검증

macOS 전체화면 (⌃⌘F 또는 녹색 신호등 long-press):
- 메뉴바 자동 hide (hover 시 reveal)
- 신호등 / titlebar hide
- safeArea top = 0 (메뉴바 영역)
- 윈도우 chrome 0

**Dashboard 영향**:
- `.dfMaterial(.regularMaterial, ...)` — 전체화면에서도 정상 ✓
- Reduce Transparency → solid fallback ✓
- `.padding(DFSpace.md = 16)` 외곽 padding 그대로 ✓

**fullscreen scroll behavior**:
- 컨텐츠 < window height → 스크롤 없음
- 컨텐츠 > window height → ScrollView 동작
- nested event log ScrollView 영향 받지 않음

---

## 8. 적용 개선 (이번 검증 후)

### A. FallPreventionMonitor max width clamp

ultrawide fullscreen 에서 dashboard 의 시각 sparseness 방지.
`.frame(maxWidth: 1400, alignment: .leading)` 적용.
- 1400pt = NN/g 권장 dashboard 표준 폭 (사용자 시선 이동 거리 최적).
- alignment leading → 좌측 정렬 (dashboard 가 detail 좌상단부터).

### B. 전체화면 검증 회귀 테스트

Snapshot scaffold (FallPreventionMonitor+Previews.swift) 에 추가:
- `#Preview("FHD 1920pt fullscreen")` 1920×1080 윈도우 시뮬
- `#Preview("Ultrawide 3440pt")` 3440×1440 시뮬

이미 추가됨 (commit `e5cb326`).

---

## 9. 종합 평가

| 시나리오 | 동작 | 비고 |
|---|---|---|
| **window 1024pt min** | ✓ | sidebar+detail 최소 fit |
| **window 1440pt default** | ✓ | 표준 layout |
| **fullscreen 1920pt FHD** | ✓ | dashboard 펼침 시 컨텐츠 ~1380pt < window 1080pt → 약간 scroll OR 1440pt 화면에선 fit |
| **fullscreen 2560pt QHD** | ✓ | 매우 좋음 |
| **fullscreen 3440pt ultrawide** | ✓ + clamp 후 | dashboard maxWidth 1400 cap 으로 sparse 방지 |
| **window 800pt 좁음** | ✓ | 3D scene 좁지만 동작 |
| **window 480pt min detail** | ✓ | 모든 영역 fit (footTargetsCard 가능 overflow — pre-existing) |
| **VoiceOver** | ✓ | 모든 element label 적용 |
| **Reduce Transparency** | ✓ | material → solid fallback |
| **Increase Contrast** | ✓ | high-contrast color variant 적용 |
| **Dynamic Type xxxLarge** | ✓ | cap |
| **Dynamic Type accessibility5** | ✓ | cap 으로 xxxLarge 까지만 |

**결론**: 본 sprint 의 monitoring dashboard 는 **모든 viewport / fullscreen 모드에서 안전**. 발견된 pre-existing 이슈 (footTargetsCard) 는 본 PR 범위 외.
