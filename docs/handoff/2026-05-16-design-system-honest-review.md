# Design System 통합 솔직 평가 (2026-05-16)

**사용자 요구**: "모든 gui와 폰트, 아이콘 요소들이 전부 유기적으로 하나의 디자인시스템을 이루는지 솔직하게 리뷰해서 보완"

---

## 솔직한 평가

### 정량 데이터

| 메트릭 | 측정 |
|---|---:|
| 토큰 시스템 정의 (DFColor + DFFont + DFSpace + DFRadius + DFSize + DFOpacity + DFAnimation + DFShadow + DFIcon) | 96+ tokens |
| 재사용 컴포넌트 | 13 (DFButton/Chip/Badge/SectionHeader/EmptyState/Keyboard/Panel/MetricRow/KeyValueGrid/PageScaffold/ProgressDots/SourcePill/StatusTile) |
| Monitoring 영역의 raw `.font(.system())` | **0** (100% 마이그레이션) |
| **App 전체의 raw `.font(.system())`** | **330** (← 큰 gap) |
| Monitoring 영역의 raw 색 (`.red/.green` 등) | 0 |
| App 전체의 raw 색 | 6 (낮음 — 대부분 OK) |
| 마이그레이션 완료 영역 | WalkLab monitoring 만 |

### "유기적으로 하나의 디자인시스템" 평가

| 영역 | 점수 | 사유 |
|---|---:|---|
| **토큰 정의** | 95% | 거의 모든 시각 속성 (색/폰트/간격/반경/불투명도/그림자/애니메이션/아이콘) tokenized |
| **WalkLab Monitoring 적용** | 100% | 0 raw 폰트, 0 raw 색, 모든 모티프 컴포넌트 사용 |
| **WalkLabView 본체 적용** | 95% | 폰트/색 마이그레이션 완료 (몇 개 raw frame 잔존) |
| **그 외 영역 적용** | **20-30%** | RootView, Pilot, Studio, Teach, Motion 등 330 raw 호출 |
| **Icon 시스템 명시** | 70% | 이전 DFSize.icon* (frame) + 신규 DFIcon (font) 두 패턴 명시 |
| **Animation 시스템** | 80% | DFAnimation primitive (4) + semantic alias (7) — 적용은 monitoring 만 |
| **Documentation** | 60% | docstring 추가 + 결정 트리 cheat sheet 작성 |
| **검증 도구** | 50% | SwiftLint config (.swiftlint.yml) 추가 — CI 통합 X |
| **종합** | **65%** | monitoring 영역 95% + broader app 30% 가중 평균 |

### 솔직히, "유기적" 평가는 65% 정도

이유:
1. **Monitoring 영역만 깊이 정리**. 다른 영역 (Pilot, Studio, Teach 등) 은 design system 정의는 사용 가능하나 raw 호출 잔존.
2. **하나의 디자인시스템 안에서 inconsistency 다수**:
   - DFSpace 의 4pt grid 가 일관 안 됨 (6/10/12 가 grid 어긋남)
   - DFRadius 의 단계 (xs/xs2/sm) 가 명확한 사용 규칙 없음
   - 아이콘 크기 패턴 두 가지 (font vs frame) 가 양립 (대체 X)
3. **DFBadge vs DFSourcePill** — 비슷한 역할인데 별도 컴포넌트
4. **DFCard modifier vs DFPanel component vs 인라인 카드 스타일** — 카드 컨셉이 3개 중복

### 솔직한 결론

**"하나의 design system" 으로 정의는 되었지만 (95%), 실제 "하나의 system 으로 동작" 측면은 65%**.

진짜 100% 도달:
- App 전체 raw 호출 0건까지 마이그레이션 — **별도 PR × 4-5건**
- 컴포넌트 통합 / 중복 제거 — **별도 PR**
- CI 통합 + SwiftLint 강제 — **별도 PR**
- Snapshot test 자동 회귀 — **별도 PR**
- 다른 영역 (Pilot/Studio/Teach/Motion) 각각 별도 PR

본 PR (#25) 의 범위에선 monitoring 영역 + design system 인프라 정의 + 결정 트리 완료.

---

## 이번 sprint 적용

### A. Icon 시스템 명시 ✓

신규 `DFIcon` enum (DesignTokens.swift):
- `hero/section/body/caption/label/micro`
- `action` (medium weight)
- `stateSmall/stateMedium/stateLarge` (semibold = 강조)

기존 `DFSize.icon*` 는 `.frame()` 용 — 두 패턴이 양립.
사용 규칙 docstring 명시 (인라인 vs 독립).

### B. Animation semantic aliases ✓

기존 primitive (`fast/standard/smooth/bounce`) +
신규 semantic (`toggle/cardExpand/modalPresent/listChange/pageTransition/emphasis/hover`).

적용:
- `withAnimation(DFAnimation.standard)` → `withAnimation(DFAnimation.toggle)` (의미 명확)

### C. Design Token Guide 문서 ✓

`Sources/DarwinForgeUI/DesignSystem/DESIGN_TOKEN_GUIDE.md`:
- 빠른 결정 트리 (font/color/icon/spacing/radius/animation/opacity)
- 컴포넌트 우선순위 (재구현 금지 목록)
- SwiftLint 검증 도구
- 마이그레이션 현황 (영역별)

### D. Monitoring 영역에 신규 토큰 적용 ✓

- Hero icon: `DFFont.heroIcon` → `DFIcon.hero` (semantic: independent state icon)
- Animation: `DFAnimation.standard` → `DFAnimation.toggle` (semantic: 펼침/접힘)

---

## 별도 PR 권장 (점진)

### Phase 2.1: RootView + ExpertDashboard 마이그레이션
- 26 + 16 = 42 raw 호출
- 표준 패턴 적용 후 추가 영역 cascade

### Phase 2.2: Connection (Wizard + Dashboard) 마이그레이션
- 23 + 15 = 38 raw 호출
- 사용자 첫 진입점 — 시각 일관성 우선순위 ↑

### Phase 2.3: Motion (Studio + TransportBar + MotionLibraryView)
- 13 + 17 + 13 = 43 raw 호출

### Phase 2.4: Pilot 전체 영역
- 약 50 raw 호출 추정

### Phase 2.5: 나머지 (Teach/Conversation/Remote/Components)
- 약 120 raw 호출

### Phase 3: 컴포넌트 통합
- DFBadge ↔ DFSourcePill 통합 (semantic 분리 유지)
- DFCard modifier + DFPanel component 통합
- DFSize.icon* + DFIcon (두 패턴) decision tree 명시

### Phase 4: CI + 자동 회귀
- SwiftLint .github/workflows 통합
- Snapshot test (swift-snapshot-testing)
- 시각 회귀 자동 PR check

---

## 진짜 100% 도달 로드맵

| Sprint | 범위 | 예상 효과 |
|---|---|---:|
| 2.1 | RootView + ExpertDashboard | +5% |
| 2.2 | Connection | +5% |
| 2.3 | Motion | +5% |
| 2.4 | Pilot | +7% |
| 2.5 | 나머지 + 컴포넌트 통합 | +10% |
| 3 | CI + 자동 회귀 | +3% |
| **합계 (별도 sprint 6개)** | | **65% → 100%** |

본 PR 종료 후 v1.2 master plan 으로 잡고 점진 진행 권장.
