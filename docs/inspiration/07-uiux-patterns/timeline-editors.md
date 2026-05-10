# 타임라인 에디터 패턴

> 모션 키프레임, 워크 BPM 동기화, 이벤트 시퀀스 등 시간 축 기반 UI 후보.

## 주요 도구

### 1. Adobe After Effects — 키프레임 + 베지어 곡선 ★★★

**DarwinForge 모션 에디터의 1순위 모델.**

```
┌────────────────────────────────────────────────┐
│  [재생] [STOP] 00:00:01:15  ━━━━━━━━━━━━━━━━━ │
├────────────────────────────────────────────────┤
│ Layer 1 ▶ Position    ◆────◆──────◆           │
│ Layer 1 ▶ Rotation    ◆────────◆──◆           │
│ Layer 2 ▶ Opacity     ◆────────◆               │
└────────────────────────────────────────────────┘
        ▲ 키프레임 (◆) 클릭 → 베지어 핸들 편집
```

핵심:
- 좌측 layer 트리
- 각 속성마다 별도 트랙
- 키프레임 사이 보간 (Linear / Bezier / Hold)
- Easing curve 그래프 별도 패널

### 2. Pro Tools / Logic Pro — 다중 트랙 + 자동화 lane

음악 편집에서 트랙별 볼륨 / 팬 / 효과를 별도 lane으로 자동화.

DarwinForge 적용:
- 16관절 = 16 트랙
- 각 트랙 별 키프레임 (= step의 해당 관절 위치)
- 재생 헤드 이동 시 모든 관절 위치 일괄 변화

### 3. Final Cut Pro X — Magnetic Timeline

클립을 빈 공간에 두면 자동으로 인접 클립에 흡착. 트랙 갭 없음.

DarwinForge: 모션 step 사이 timing이 자동 정렬. 사용자는 step 자체만 편집.

### 4. Ableton Live — Session View + Arrangement

- Session View: clip을 격자로 배치, 즉시 launch
- Arrangement View: 시간축 위 clip 정렬 (전통 DAW)

DarwinForge 적용:
- Session View = 모션 라이브러리 (page를 clip 카드로 그리드)
- Arrangement = 페이지 시퀀스 (page들을 시간축으로)

### 5. DaVinci Resolve — 색 보정 + 키프레임

전문 VFX. 우리에게는 무거움.

## DarwinForge — 모션 에디터 화면 후보

```
┌─────────────────────────────────────────────────────┐
│  Page: "Wave"  ▶ ▮▮  00:00:00 / 00:01:30          │
├─────────────┬───────────────────────────────────────┤
│ Joint List  │  Trace + 키프레임 grid               │
│             │                                       │
│ R_SHL_PITCH │  ◆──────◆────────◆────◆            │
│ L_SHL_PITCH │  ◆──────◆────────◆────◆            │
│ R_SHL_ROLL  │  ◆────◆────────────◆──             │
│ …           │                                       │
│             │                                       │
│             │  Play time:    [16] [32] [16] [32]   │
│             │  Pause time:   [ 0] [ 4] [ 0] [ 0]   │
└─────────────┴───────────────────────────────────────┘
```

SwiftUI:
- `LazyVStack` 내부에 16 트랙
- 각 트랙은 `Canvas` API로 키프레임 마커 + 보간 curve 그리기
- 재생 헤드 = `Path` 위 vertical line
- 클릭 + 드래그로 키프레임 이동
- Step play_time 변경 = 트랙 전체 horizontal scaling

## BPM 기반 타임라인 (Spot Choreographer 패턴)

음악 비트와 모션 step의 동기화. 4/4 박자 120 BPM = 0.5초/박.

```swift
struct BeatGrid {
    var bpm: Double = 120
    var beatsPerMeasure: Int = 4

    func msAtBeat(_ beat: Int) -> Double {
        Double(beat) * 60_000 / bpm
    }

    /// 가까운 beat에 step 자동 snap
    func snapMs(_ ms: Double) -> Double {
        let beat = (ms * bpm / 60_000).rounded()
        return msAtBeat(Int(beat))
    }
}
```

Spot Choreographer의 타임라인은 BPM을 음악 import 시 자동 추정 +
사용자 fine-tune. DarwinForge에선 MP3/WAV 임포트 → AVFoundation으로 BPM
추정 → 모션 step을 beat에 snap.

## 출처

- After Effects 키프레임 가이드: https://helpx.adobe.com/after-effects/using/animation-basics.html
- FCPX Magnetic Timeline: https://www.apple.com/final-cut-pro/
- Ableton Live: https://www.ableton.com/live/
- BPM detection (AVFoundation): https://developer.apple.com/documentation/avfoundation
