# Phase 3: Motion Catalog + Upper/Lower Body Blending — Plan

- **작성일**: 2026-05-21
- **목표**: 보행 (lower body) + named motion (upper body) 동시 실행 → "걸으면서 손 흔들기"
- **트리거**: 사용자 궁극 목표 ("게임 캐릭터처럼 조종") + 갭 분석 우선순위 #1
- **작업 원칙**: 코드 단 논리 검증만, 실 hardware 없이도 progress

---

## 1. 문제

현재 WalkLab + Pilot 가 **단일 motion at a time** 만 허용:
- WalkLab preset 진행 중 motion 트리거 시 conflict
- motion_4096.bin 의 255 페이지 = chain 미구현 (단발 자세 approximation)
- Teach capture 와 WalkLab preset 사이 통합 없음 — 별도 자산

## 2. 해결 — 4 핵심 모듈

### 2.1 MotionCatalogUnified
WalkLabPreset + MotionPage + Teach capture 를 **단일 catalog** view 로 통합.

```swift
public enum MotionDescriptor: Identifiable, Sendable {
    case walk(WalkLabPreset)
    case page(MotionPage)
    case teach(TeachCapture)
    case composite(MotionDescriptor, MotionDescriptor)

    public var bodyRegions: Set<BodyRegion>  // legs / arms / head / waist
    public var blendable: Bool
}

public enum BodyRegion: Sendable, Hashable {
    case legs, leftArm, rightArm, head, waist
}
```

### 2.2 MotionBlender
upper/lower body channel router — joint mask 기반.

```swift
public final class MotionBlender {
    /// 동시 motion 실행 — region 충돌 시 lower body (균형) 우선.
    public func blend(
        lower: MotionDescriptor?,
        upper: MotionDescriptor?
    ) -> RobotPose
}
```

### 2.3 MotionTransitionPolicy
walk → idle → motion 안전 전환 + preflight gate.

```swift
public enum MotionTransitionPolicy {
    public static func canTransition(
        from current: MotionDescriptor?,
        to target: MotionDescriptor,
        balanceState: BalanceState
    ) -> TransitionVerdict
}

public enum TransitionVerdict: Sendable {
    case allow
    case requireStop(reason: String)   // 현재 motion 정지 후
    case blocked(reason: String)        // 안전상 불가
}
```

### 2.4 PilotIntent.motion 활성화
기존 `case motion(String)` placeholder 를 catalog id 기반으로 실 구현.

---

## 3. 신규 파일 (4개)

```
Sources/DarwinForgeUI/Motion/Catalog/
  ├── MotionDescriptor.swift            # enum + BodyRegion
  ├── MotionCatalogUnified.swift        # WalkPreset + MotionPage + Teach 통합
  ├── MotionBlender.swift               # upper/lower channel
  └── MotionTransitionPolicy.swift      # 안전 전환

Tests/DarwinForgeUITests/Motion/Catalog/
  └── MotionBlenderTests.swift
  └── MotionTransitionPolicyTests.swift
```

## 4. 수정 site (3개)

- `WalkLab/Pilot/PilotIntent.swift` — `.motion` case 의 String → `MotionDescriptor.ID`
- `WalkLab/Pilot/WalkLabRCBridge.swift` — motion intent 처리 분기 + MotionBlender 호출
- `WalkLab/Pilot/TelloPilotHud.swift` — motion 단축키 표시 (선택)

## 5. 비-목표 (이번 phase 안 함)

- 실 hardware motion 송출 (sim 모드만)
- 모든 255 MotionPage 의 BodyRegion 자동 분류 (수동 mapping 또는 휴리스틱만)
- Claude critic 의 motion 추천 (Phase 5+)
- Motion editing UI (Teach 모듈에 기존)

## 6. 검증 단계

1. swift build 0 errors
2. swift test 880+ 회귀 유지 + 신규 unit test 10+ pass
3. 병렬 에이전트 4건 (architect / code-reviewer / test-engineer / critic) 다각 검증
4. 코덱스 (별도 critic agent) 검수
5. fix loop 1-2 round

## 7. 예상 소요

- 모듈 4개: 1-1.5시간
- 테스트: 30분
- 빌드 + 회귀: 15분
- 병렬 에이전트: 5분 spawn + 20분 대기
- 코덱스 검수: 5분 spawn + 10분 대기
- fix loop: 30분

**합계: 2.5-3시간** (이번 무한 루프 사이클 1)
