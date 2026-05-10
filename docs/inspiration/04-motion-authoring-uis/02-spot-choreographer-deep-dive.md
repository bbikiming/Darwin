# Boston Dynamics Spot Choreographer Deep Dive — 음악 동기화 모션 저작

> 작성일: 2026-05-10
> 분석 대상: Boston Dynamics Spot SDK 4.x Choreography Module + Choreographer GUI
> 본 문서는 Spot의 “music-driven” 모션 저작 패러다임을 DarwinForge `WalkSimView`의 단순 sin파 보행 모델을 BPM 기반 phase 동기 보행으로 확장하기 위한 참고 자료다.

---

## 1. Spot Choreographer 개요

Boston Dynamics는 2020년 Spot 댄스 영상 (“Do You Love Me”)을 계기로 댄스 저작 도구를 SDK에 정식 편입했다. 핵심은 **음악을 기준으로 모든 모션을 정렬한다**는 디자인 결정이다. 사용자가 mp3 / wav를 import 하면 BPM, beat onset, downbeat가 자동 분석되고 timeline의 beat ruler에 마커로 표시된다 (출처: https://dev.bostondynamics.com/docs/concepts/choreography/choreographer).

DARwIn-OP의 보행은 파이썬 / C++ 시절부터 LIPM 기반 phase 0~3 사이클이며 외부 트리거 없이 내부 시계로만 동작한다. Spot의 “BPM phase lock”을 차용하면 향후 음악 / 음성 / 시각 자극에 대한 라이브 댄스 / 응원 동작을 만들 수 있다.

BD의 디자인 결정 중 학습 가치가 큰 것은 **시간을 “초”가 아닌 “slice (1/4 beat)”로 저장**한다는 점이다. 이로 인해 BPM을 사후 변경해도 모든 모션이 비율 보존된다. 우리 `.mtn`은 ms 절대 단위라 BPM 변환 시 lossy인데, 새 포맷에서는 dual-storage (ms + slice)로 양쪽 호환을 권장.

---

## 2. 화면 구조

```
+----------------------------------------------------------+
| File  Edit  Robot  Music  View  Help                     |
+--------+-------------------------------------------------+
|  MOVES |  [▶][⏸][⏹]  120 BPM   ⟲ snap=1/4   audio: ▮▮▮  |
|  ────  +-------------------------------------------------+
|  ▸ Body|  beat: |1   |2   |3   |4   |5   |6   |7   |8   |
|  ▸ Step|  audio: ~~~~~∿∿∿~~~∿∿∿~~~∿∿∿~~~∿∿∿~~~~~~~~~~~~  |
|  ▸ Head|  Body   [Sway------][Twerk--][Sway-------]      |
|  ▸ Arms|  Step   [WalkF][Pirouette][SideStep]            |
|  ▸ Sound  Arms   [    ][Wave R][    ][Wave L][   ]       |
|  ▸ Light  Sound  [♪Bark]      [♪Howl]                    |
|  ▸ Anim.  Light  [LED Blue                              ]|
|        +-------------------------------------------------+
|  search:  Drag a move onto a track to place it           |
+--------+-------------------------------------------------+
```

(출처: https://dev.bostondynamics.com/docs/concepts/choreography/choreographer_overview)

좌측은 Move Library, 우측은 멀티트랙 timeline. 각 track은 한 번에 하나의 move만 활성화 (overlap 시 빨간 경고). beat ruler가 timeline 상단에 고정되며, 마우스로 move 끝을 잡고 드래그하면 1/8, 1/4, 1/2 beat에 자동 스냅된다.

---

## 3. BPM Sync 알고리즘

### 3.1 Beat 검출

오디오 import 시 librosa(또는 BD 내부 onset detector)가 다음 단계를 거친다 (출처: https://dev.bostondynamics.com/docs/concepts/choreography/working_with_audio).

1. STFT (window=2048, hop=512) → onset envelope.
2. Tempo estimation (자동 BPM, 사용자 override 가능).
3. Beat tracking (dynamic programming on onset envelope).
4. Downbeat 추정 (4/4 가정, 사용자 토글로 3/4, 6/8 가능).

결과는 `BeatGrid { bpm: f32, downbeats: [f32], beats: [f32], subdivisions: 4 }` 형태로 timeline에 첨부된다.

### 3.2 Move Phase Lock

각 Move는 “n beat 길이” 단위로 정의되어 있고, 시작 beat 위치만 timeline에 기록된다.

```
MoveInstance {
  move_id   : "twerk_v1"
  start_beat: 4              // 절대 beat 인덱스
  beat_count: 4              // 4 beats = 2 sec @ 120 BPM
  parameters: {
    "amplitude": 0.6,
    "frequency_multiplier": 2.0   // 2x = 4 wiggles per 4 beats
  }
}
```

BPM이 변경되면 모든 move가 자동 재타이밍되며 키프레임 형태가 아니라 “phase 비율”로 저장되어 있다는 점이 결정적 (출처: https://dev.bostondynamics.com/docs/concepts/choreography/move_reference).

> ★ 차용: DarwinForge `Walk.swift`의 `WalkPhase` enum (phase0..3)은 정확히 같은 패턴이지만 외부 동기 신호가 없다. `WalkEngine`에 `setBeatGrid(bpm: Double, offset: Double)`을 추가하고 `tick(dtMs:)`에서 wall-clock 대신 beat phase를 사용해 발 궤적을 산출하면 음악 동기 보행이 가능. SIMD 곱셈으로 코어 변경 없이 가능.

### 3.3 Phase 합성식 (제안)

현재 sin파 보행을 다음과 같이 확장:

```
phase(t)         = (t - t0) * step_freq                  // 기존
phase_synced(t)  = beat(t) * 0.25                        // 4 beats = 1 step cycle
foot_z(phase)    = h_step * sin(phase * 2π) * (phase < 0.5 ? 1 : 0)
```

여기서 `beat(t)` = `(t - downbeat_offset) * bpm / 60.0`. 이렇게 하면 BPM 변화에 보폭이 자동 추종.

---

## 4. 다중 트랙 데이터 모델

Spot timeline은 6 종류 track group을 지원 (출처: https://dev.bostondynamics.com/docs/concepts/choreography/move_reference).

| Track | 자원 | 예시 Move |
|-------|------|-----------|
| Body | trunk pose (roll/pitch/yaw, height) | Sway, Bourree, Twerk |
| Step | leg swing pattern | WalkForward, Pirouette, SideStep |
| Arms | (Spot Arm) | WaveLeft, Stow, Carry |
| Head/Gaze | gaze target | LookAt, ShakeHead |
| Sound | speaker | Bark, Howl, custom WAV |
| Lights | LEDs | RGB pattern |

각 group은 “하나의 active move” 정책. group 간 동시 실행은 자유. 이 자원 분리 모델은 NAO Choregraphe의 ResourceLock과 같은 정신이지만 group이 정적으로 고정되어 더 단순.

```
Sequence {
  bpm        : 120.0
  beat_grid  : BeatGrid
  audio      : "song.wav"
  tracks: {
    body  : [MoveInstance, ...]
    step  : [MoveInstance, ...]
    arms  : [MoveInstance, ...]
    gaze  : [MoveInstance, ...]
    sound : [SoundInstance, ...]
    light : [LightInstance, ...]
  }
}
```

JSON 형태로 `.csq` 파일에 직렬화. 사람이 손으로 편집 가능하며, GitHub에 BD 공식 예시 다수 존재.

> ★ 차용: DarwinForge에 `Sequence` 타입을 도입. DARwIn-OP의 16관절을 다음 그룹으로 분할:
>
> - **Locomotion**: 양다리 12관절 (HipYaw/Roll/Pitch, Knee, Ankle Pitch/Roll × 2).
> - **Arms**: 양팔 6관절 (Shoulder Pitch/Roll, Elbow × 2). 사실 OP는 6관절.
> - **Head**: HeadPan, HeadTilt 2관절.
> - **Sound**: 호스트 macOS 스피커 (NSSound).
> - **Light**: CM-740 RGB LED.
>
> 각 그룹별 단일 active move 제약을 두고, Locomotion이 활성이면 Walk Sim과 Kick이 자원 충돌 → 큐.

---

## 5. Move Library ABI

각 Move는 다음 시그니처로 등록 (출처: https://dev.bostondynamics.com/docs/concepts/choreography/move_reference#move_parameters).

```protobuf
message MoveParams {
  string type = 1;           // "twerk", "pirouette", ...
  google.protobuf.Duration duration = 2;     // 또는 beat_count
  oneof params {
    BodyParams body = 10;
    StepParams step = 11;
    ArmParams  arms = 12;
    GazeParams gaze = 13;
  }
}

message BodyParams {
  ParamFloat amplitude        = 1;
  ParamFloat frequency        = 2;
  ParamPose  base_pose        = 3;
  ParamBool  return_to_start  = 4;
}

message ParamFloat {
  float value = 1;
  google.protobuf.FloatValue minimum = 2;
  google.protobuf.FloatValue maximum = 3;
  google.protobuf.FloatValue default_value = 4;
}
```

`ParamFloat`이 단순 값이 아니라 `(value, min, max, default)` 묶음이라는 점이 Choregraphe의 Parameter와 직결되며, GUI 슬라이더 자동 생성에 사용된다.

> ★ 차용: 우리 Swift에서 동등한 모델:
>
> ```swift
> public struct ForgeParam<T: Comparable & Sendable>: Sendable {
>     public var value: T
>     public let min: T
>     public let max: T
>     public let `default`: T
>     public let label: LocalizedStringKey
> }
>
> public protocol ForgeMove: Identifiable, Sendable {
>     associatedtype Params: Codable
>     var id: String { get }
>     var beatCount: Int { get }
>     var params: Params { get set }
>     func sample(at phase: Double) -> JointTargets   // phase 0..1
> }
> ```
>
> SwiftUI에서 `ForEach(Mirror(reflecting: move.params).children)`로 슬라이더를 자동 생성. (Mirror 대신 macro도 가능 — Swift 5.9+ `@Observable`.)

---

## 6. Beat Snapping & 편집 인터랙션

- 드래그 시 마우스 좌표 → time → 가장 가까운 beat fraction에 스냅. snap 설정: 1/1, 1/2, 1/4, 1/8, 1/16, off.
- Shift 누르면 snap 일시 해제 (free placement).
- Alt 누르고 move를 끌면 duplicate.
- 기본 단축키: `B`로 BPM 입력 모달, `M`으로 metronome on/off, `Tab`으로 beat ↔ second 표시 토글.
- timeline scroll: 트랙패드 가로 스크롤. zoom: ⌘+휠.

(출처: https://dev.bostondynamics.com/docs/concepts/choreography/choreographer)

> ★ 차용: SwiftUI `MotionTimelineView`에 `BeatSnapMode` enum (`oneOver1, oneOver2, ...`)과 modifier `.snapToBeats(grid:)`를 두고, 내부에서 마우스 좌표 → time → snap → time 변환 함수를 캡슐화.

---

## 7. Choreography Sequence 파일 포맷

`.csq` 파일은 Protocol Buffers 텍스트 형식 (또는 JSON 변형). 헤더에 BPM, audio 파일 상대 경로, 각 track의 move list. SDK는 이 파일을 Spot에 업로드하고 `ChoreographyClient.execute_choreography()`로 재생한다 (출처: https://github.com/boston-dynamics/spot-sdk/tree/master/python/examples/choreography).

```
sequence_info {
  sequence_name: "ballet_demo"
  bpm: 100.0
  start_slice: 0
  slices_per_minute: 400      # 100 BPM * 4 subdivisions
}
moves {
  type: "step"
  start_slice: 0
  requested_slices: 4
  step_params { ... }
}
moves {
  type: "twerk"
  start_slice: 16
  requested_slices: 8
  body_params { ... }
}
```

`start_slice` 단위가 “slice = 1/4 beat” 라는 점에 주목 — 시간을 절대 초가 아니라 beat 분할로 저장한다. 이 결정이 BPM 변환을 무손실로 만든다.

> ★ 차용: 우리 `.forge` (또는 `.mtn` 확장) 파일 포맷에 “slice” 개념 도입. 현재 `motions/*.json`의 `frame: 25fps` 절대 정수 대신 `slice: bpm * subdivisions` 기반 정수를 옵션으로. 기존 `.mtn` 호환성은 “bpm=null, slice=frame * 25”으로 polymorphic 표현.

---

## 8. DarwinForge “Walk Sim” 확장 설계안

현재 코드:

```swift
// WalkEngine.tick(dtMs:) → FootTargets { phase, leftXYZ, rightXYZ }
// internal: phase = (elapsedMs / stepDurMs) % 4
```

확장 후:

```swift
public struct BeatGrid: Sendable, Equatable {
    public var bpm: Double            // 60..200
    public var subdivisions: Int      // 4
    public var downbeatOffsetMs: Double
}

extension WalkEngine {
    public func setBeatGrid(_ grid: BeatGrid?) { /* C ABI 호출 */ }
}
```

C 측 (`forge-core::walk`):

```rust
pub fn fc_walk_set_beat_grid(h: *mut Walk, bpm: f64, subdiv: i32, offset_ms: f64) -> i32;

// inside tick():
let phase_t = if let Some(grid) = self.grid {
    let beat = (self.elapsed_ms - grid.offset_ms) * grid.bpm / 60_000.0;
    (beat / 4.0) % 1.0    // 4 beats = full step cycle
} else {
    (self.elapsed_ms / self.step_dur_ms) % 1.0
};
```

UI (`WalkSimView`):

```swift
HStack {
    Toggle("BPM Sync", isOn: $bpmSync)
    if bpmSync {
        TextField("BPM", value: $bpm, format: .number).frame(width: 60)
        Stepper("", value: $bpm, in: 40...200)
        BeatPulseIndicator(bpm: bpm)   // 현재 beat 시각화
    }
}
```

이 확장으로 기대 효과:

1. macOS 마이크 입력 → AVAudioEngine FFT → 실시간 BPM → 보행 동기 (테크노 / 응원가).
2. 사용자 mp3 import → librosa 동등 분석 (Accelerate vDSP) → 정적 시퀀스.
3. 향후 Strategy FSM의 “KICK 타이밍”을 음악 박자에 정렬 (cool 데모용).

---

## 9. 한계와 주의

- DARwIn-OP는 12 V SMPS 안정 보행 한계가 있어 BPM이 너무 빠르면(>140) ZMP 미스. 안전 BPM 범위 `[40, 130]`을 권장 — 코드에서 clamp.
- Spot은 4족이라 ZMP 제약이 적지만 OP는 2족이라 phase 0..3 (DSP/SSP) 분배가 BPM 의존. step_height / step_length를 BPM의 sigmoid 함수로 자동 축소하는 안전망이 필요.
- Audio 분석은 MainActor 외 스레드에서, 결과만 BeatGrid struct로 actor에 전달. AVAudioEngine tap closure는 리얼타임 우선순위라 락 금지.
- BPM 변경 시 진행 중인 보행에 “위상 점프” 발생 가능 — 부드러운 ramp가 필요. forge-core::walk에 `phase_blend_ms` 파라미터(기본 200 ms)를 추가하고, BPM 전환 시 이전 phase와 새 phase를 선형 보간.
- Spot의 Sequence는 곡 한 번 재생용. DarwinForge는 라이브 음악 입력 (마이크) + 연속 재생을 모두 노출하므로, “fixed sequence mode”와 “live BPM tracking mode”를 명시적으로 분리.

추가로 Spot Choreographer의 **Animation Recorder**는 Spot을 직접 손으로 끌어 자세 캡처 → 클립 저장. 이는 §01 NAO Pose Capture와 같은 패턴이며 음악 기반 도구도 결국 키프레임 캡처가 핵심임을 보인다. 우리도 BPM sync UI와 Pose Capture UI를 통합 — “캡처한 자세를 다음 downbeat에 자동 정렬”이 자연스러운 합류점.

---

## 10. 1차 도입 범위 (4주 추정)

| 주차 | 작업 |
|------|------|
| W1 | `BeatGrid` 타입 + `WalkEngine.setBeatGrid` C ABI |
| W2 | `BeatPulseIndicator` SwiftUI + 메트로놈 NSSound |
| W3 | `.forge` 파일 포맷 slice 옵션 |
| W4 | mp3 import + Accelerate vDSP onset detection (간이) |

mp3 import는 “확인 필요” — Apple Music DRM 호환성 미검증. WAV / AIFF만 우선 지원하는 안전 경로 권장.

---

(전체 출처: https://dev.bostondynamics.com/docs/concepts/choreography/choreographer, https://dev.bostondynamics.com/docs/concepts/choreography/move_reference, https://dev.bostondynamics.com/docs/concepts/choreography/working_with_audio, https://github.com/boston-dynamics/spot-sdk/tree/master/python/examples/choreography. Spot SDK 4.x 기준. 향후 4.x 변경 가능성 확인 필요.)
