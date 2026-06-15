# Phase 1.5: WalkLab Apply-Scope Badge — 구현 plan

- **작성일**: 2026-05-21
- **목표**: WalkLab 설정의 적용 범위 (3-경로) 시각화 → 사용자 오해 차단
- **트리거 문서**: `~/Downloads/WALKLAB_VERIFICATION_FINAL_2026-05-21.md` (Critical Gap 발견)
- **작업 원칙**: UX layer 추가만. 동작/송신/제어 path 변경 X.

---

## 1. 문제 (verification 문서 §4 요약)

WalkLab 설정은 3-경로 (시뮬 / Mac sparse / Onboard) 로 분기되는데, UI 가 단일 "실시간 반영" 인 척 보여 **사용자가 잘못된 기대** 형성. 특히:

| 항목 | 위험 | Mac sparse | Onboard SSH |
|---|---|---|---|
| `balanceGain` | **HIGH** | ✅ 반영 | ❌ 미송신 (필드 부재) |
| `enableBalanceCorrection` | MEDIUM | ✅ pose transform | ❌ 미송신 |
| `correctorIntensityLevel` | MEDIUM | ✅ corrector 재구성 | ❌ 미송신 |
| `balanceExperimentConfig` (4축) | MEDIUM | ✅ corrector 재생성 | ❌ 미송신 |

**증상**: "슬라이더를 올렸는데 왜 로봇은 그대로지?" — Onboard 모드 사용자 혼동.

---

## 2. 해결 — Apply-Scope Badge 시스템

### 2.1 핵심 아이디어
각 설정 옆에 **현재 모드에서 어떻게 작동하는지** 명시하는 작은 chip (배지).
모드 (`session.walkingEngine`) 가 변하면 배지도 자동 변경 (reactive).

### 2.2 Apply Scope enum (6 case)

```swift
enum WalkLabApplyScope: Equatable {
    case sentBoth              // Mac sparse + Onboard 모두 (정상 송신)
    case macSparseOnly         // Onboard 모드에선 미송신 (HIGH/MEDIUM gap)
    case onboardOnly           // 매우 드문 경우 (현재 없음)
    case startGateOnly         // preflight 게이트만 (cradle/risk)
    case nextSession           // 다음 세션부터 (operatorNote)
    case previewOnly           // 화면만 (sim, 보행 비활성)

    var label: String { ... }    // "로봇 송신" / "Mac 전용" / "다음 세션" 등
    var color: Color { ... }     // green/orange/blue/gray
    var icon: String { ... }     // SF Symbol
    var detailedMessage: String? // hover tooltip (긴 설명)
}
```

### 2.3 결정 로직 (순수 함수, mode-aware)

```swift
enum WalkLabApplyScopeResolver {
    /// 설정 항목별 + 현재 walkingEngine 별 scope 결정.
    static func scope(
        for field: WalkLabField,
        engine: WalkingEngineMode
    ) -> WalkLabApplyScope {
        switch (field, engine) {
        case (.preset, _),
             (.strideMm, _),
             (.sideMm, _),
             (.turnDeg, _),
             (.customPeriodMs, _),
             (.footHeightMm, _),
             (.hipPitchOffset, _):
            return .sentBoth
        case (.balanceGain, .robotisOnboard),
             (.enableBalanceCorrection, .robotisOnboard),
             (.correctorIntensityLevel, .robotisOnboard),
             (.balanceExperimentConfig, .robotisOnboard):
            return .macSparseOnly  // ❌ Onboard 미송신
        case (.balanceGain, .macSparseKeyframe), ...:
            return .sentBoth       // Mac sparse 만 활성이면 양쪽 OK
        case (.cradle, _), (.risk, _):
            return .startGateOnly
        case (.operatorNote, _), (.comparisonTag, _):
            return .nextSession
        }
    }
}

enum WalkLabField: String, CaseIterable {
    case preset, strideMm, sideMm, turnDeg, customPeriodMs, footHeightMm,
         hipPitchOffset, balanceGain, enableBalanceCorrection,
         correctorIntensityLevel, balanceExperimentConfig,
         cradle, risk, operatorNote, comparisonTag
}
```

### 2.4 SwiftUI Badge View

```swift
struct WalkLabApplyScopeBadge: View {
    let scope: WalkLabApplyScope
    /// compact = 아이콘만 (슬라이더 옆), full = 아이콘+텍스트 (별도 row).
    let style: Style

    enum Style { case compact, full }

    var body: some View { ... }  // capsule + color + icon + label
}
```

### 2.5 3D 뷰 하단 실시간 상태

기존 `lastRobotEvent` 활용 (이미 WalkLabSession 에 있음). 슬라이더 조작 시:
- Mac sparse: "🛰 220ms 후 cycle 재시작"
- Onboard 정상: "📡 송신 중... → ✅ ACK 12ms"
- Onboard 미송신 (balanceGain 등): "⚠️ Onboard 모드 미송신 — Mac sparse 로 전환하면 반영"

`OnboardHealthIndicator` 와 통합 — 이미 있는 indicator 옆에 송신 상태 추가.

---

## 3. 구현 site 매트릭스

| 파일 | 추가 위치 | 적용 field | scope |
|---|---|---|---|
| `Components/AdvancedSlidersPanel.swift` | 각 슬라이더 row 옆 | strideMm/sideMm/turnDeg/customPeriodMs/footHeightMm | sentBoth |
| `Components/AdvancedSlidersPanel.swift` | balanceGain row 옆 | balanceGain | mode-aware (HIGH gap) |
| `Components/BalanceExperimentControls.swift` | 4축 picker 위 | balanceExperimentConfig | macSparseOnly @ Onboard |
| `Components/GyroCorrectorControls.swift` | intensity 5-button row | correctorIntensityLevel | macSparseOnly @ Onboard |
| `WalkLabView.swift` | balanceCorrectionCard (toggle) | enableBalanceCorrection | macSparseOnly @ Onboard |
| `WalkLabView.swift` | balanceStateCard (autoFallPrevention) | autoFallPrevention | Mac 안전망 안내 |
| `WalkLabView.swift` | sidebar cradleConfirmed toggle | cradle | startGateOnly |
| `WalkLabView.swift` | riskConfirmSheet | risk | startGateOnly |

---

## 4. 신규 파일 (3개)

```
Sources/DarwinForgeUI/WalkLab/ApplyScope/
  ├── WalkLabApplyScope.swift          # enum + WalkLabField enum + Resolver
  ├── WalkLabApplyScopeBadge.swift     # SwiftUI view (compact + full)
  └── WalkLabApplyScopeMessages.swift  # detailed messages 분리 (i18n 친화)

Tests/DarwinForgeUITests/ApplyScope/
  └── WalkLabApplyScopeResolverTests.swift  # 결정 logic 순수 함수 test
```

## 5. 수정 파일 (4개)

```
Components/AdvancedSlidersPanel.swift       (6 슬라이더에 compact badge)
Components/BalanceExperimentControls.swift  (4축 picker 상단 full badge)
Components/GyroCorrectorControls.swift      (intensity row 옆 compact badge)
WalkLab/WalkLabView.swift                   (balanceCard/cradle/risk badge)
```

## 6. 신규 테스트 (1개)

`WalkLabApplyScopeResolverTests.swift` — 모든 `(WalkLabField, WalkingEngineMode)` 조합의 scope 결정:
- `balanceGain @ robotisOnboard` → `.macSparseOnly`
- `balanceGain @ macSparseKeyframe` → `.sentBoth`
- `strideMm @ 모든 engine` → `.sentBoth`
- `cradle @ 모든 engine` → `.startGateOnly`
- ...

15 cases (15 field × 2 engine 일부 + edge cases).

---

## 7. 비-목표 (이번 phase 에서 안 할 것)

- 펌웨어 daemon 의 `balanceGain` 지원 (P2-1, 별도 협의 필요)
- 슬라이더 disable (옵션 a 인데, 옵션 b "활성 + 배지" 선택 — UX 자연스러움)
- 실물 로봇 검증 (코드 검증만, 사용자 테스트 별도)
- `autoOnboardBrokering=false` 시각 표시 (P3-2, 후속)

---

## 8. 검증 단계

1. **swift build** (debug + release) — 0 errors
2. **swift test** — 827+ 회귀 0 fail + 신규 Resolver tests 추가
3. **병렬 에이전트 4건** (plan 수립 후 즉시 검증):
   - architect — 데이터 모델 + 의존성 정합
   - code-reviewer — UX 일관성 + 안티 패턴
   - test-engineer — 회귀 가드 + 신규 테스트 시나리오
   - critic — 다각 비판 + 누락 항목

---

## 9. 사용자 결정 항목 (구현 진입 전 확인)

1. **옵션 (b) 확정?** — 활성 유지 + 배지 (verification §7.3 옵션 a/b/c 중 b)
2. **3D 뷰 하단 메시지 통합 OK?** — `lastRobotEvent` 재사용
3. **Phase 2 (학습 알고리즘) 와 충돌 없는가?** — 별도 UX layer 라 무관 (확인)

---

## 10. 작업 시간 예상

- enum + Resolver + Badge view: 30분
- 4 파일 수정: 1시간
- 테스트 작성: 30분
- 빌드 + 회귀 검증: 15분
- 병렬 에이전트 검증 + 통합 fix: 1-2시간

**합계: 3-4시간** (Phase 2 보다 빠름 — 단순 UX layer)
