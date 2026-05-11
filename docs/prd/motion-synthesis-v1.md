# PRD — Motion Synthesis Engine v1

> **상태**: Draft (구현 대기)
> **작성일**: 2026-05-12
> **작성자**: Darwin Forge planning agent
> **대상 스프린트**: Sprint 9 (`forge-core::synth`) — Sprint 12 (Claude CLI 통합)
> **선행 의존**: Sprint 3 motion import/export, Sprint 4 motion editor, Sprint 7 SwiftUI Studio (모두 완료)

---

## 0. TL;DR (한 줄 결론)

**기존 `motion_4096.bin`의 45개 페이지를 reference 라이브러리로 두고, 6가지 합성 연산자(Sequence / Layer / Morph / Mutate / Mirror / Procedural)와 안전 검증 파이프라인을 통해 새로운 페이지를 알고리즘적으로 생성한다.** 사용자는 SwiftUI Studio GUI, `forge synth` CLI, 또는 Claude Code 슬래시 커맨드 / MCP 도구로 동일한 엔진을 호출한다. **본 PRD는 알고리즘과 데이터 모델을 동결하되 코드 작성은 보류한다 — 사용자 승인 시점에 Sprint 9를 개시한다.**

---

## 1. 배경 & 문제 정의

### 1.1 현재 상태
- DARwIn-OP는 **256개 페이지 × 7 step × 20 관절**의 keyframe 모델로 모션을 보관 (`motion_4096.bin`, 128 KiB).
- 페이지 생성은 ROBOTIS 공식 `action_editor` CLI로 **수동 키프레이밍** 또는 실기기 자세 캡처에 의존.
- 본 Darwin Forge 프로젝트는 Sprint 3에서 `.mtn ↔ JSON round-trip`을 구현했고, Sprint 4에서 timeline 편집 골격을 깔았다.
- **그러나 현재는 "기존 페이지를 읽고 쓰고 편집"하는 단계까지만 가능하고, 페이지를 새로 생성하는 알고리즘적 수단이 없다.**

### 1.2 사용자가 원하는 것 (이 PRD의 트리거 요청)
> *"기존 모션 파일을 레퍼런스로 새로운 모션을 창조해 낼 수 있는 기능을 클로드 CLI와 연계해서 만들고 싶다."*

### 1.3 핵심 문제
DARwIn-OP 모션 합성은 다음 세 가지 제약을 동시에 만족해야 한다:
1. **포맷 호환** — 결과물은 `motion_4096.bin`에 그대로 기록 가능해야 한다 (256 page slot, 7 step, 64-byte alignment, checksum 등).
2. **물리 안정성** — 페이지가 로봇에서 재생될 때 (a) 관절 한계, (b) 토크/속도 한계, (c) ZMP 측면 정적 안정성, (d) self-collision을 위반하면 안 된다.
3. **의도 표현력** — "왼손 흔들면서 고개를 끄덕여" 같은 자연어 의도를 페이지 조합으로 변환할 수 있어야 한다 — 이 부분이 **Claude CLI 통합 지점**.

수동 키프레이밍은 1번만 만족시킨다. 단순 데이터 변환은 1·2를 만족시킨다. **본 엔진은 1·2·3을 모두 해결한다.**

---

## 2. 목표 & 비목표

### 2.1 목표 (in-scope)

| # | 목표 | 측정 가능한 기준 |
|---|------|------------------|
| G1 | 6가지 합성 연산자 구현 | `forge synth <op>` 6 서브커맨드, 각 단위 테스트 ≥ 5 |
| G2 | 모든 reference 페이지 round-trip | 45개 페이지 디코딩→재인코딩 byte-identical (checksum 포함) |
| G3 | 안전 검증 파이프라인 | 4-stage validator (limit / velocity / collision / stability) 통과 못 한 페이지는 `motion_4096.bin`에 기록 거부 |
| G4 | Claude CLI 통합 | `/synth` 슬래시 커맨드 + `forge-motion-synth` MCP 서버 + `motion-composer` subagent 3-track 동시 제공 |
| G5 | 시각/촉각 미리보기 | (a) SwiftUI Studio 3D 미리보기 (b) `forge synth simulate --gif` (c) 실기기 dry-run (torque off) |
| G6 | 결정론적 재현 | 동일 시드 + 동일 입력 → byte-identical 출력 (랜덤 mutation 포함) |

### 2.2 비목표 (out-of-scope)
- **NB1**: 보행(walking) 모션 합성은 본 엔진의 대상이 아니다 → `forge walk` (Sprint 5)가 IK 기반으로 별도 처리.
- **NB2**: 동적 안정성(dynamic ZMP, momentum-based) 검증은 v1에서 제외. **정적 안정성 + heuristic만** 적용. (v2 후보)
- **NB3**: 강화학습/신경망 기반 모션 생성은 v1 비목표. v1은 **결정론적 규칙 기반**만.
- **NB4**: 비전(카메라 trigger) ↔ 합성 모션 연결은 strategy 레이어 책임. 본 엔진은 모션 결과물만 생산.
- **NB5**: 새로운 .bin 포맷 정의 금지. **기존 ROBOTIS 포맷을 100% 보존**한다. (확장 메타데이터는 별도 sidecar JSON으로.)

---

## 3. 사용자 스토리

### Persona A — Hobbyist Operator (Mac SwiftUI)
- "DARwIn에게 친구가 박수치는 시연을 보여주고 싶다."
- → SwiftUI Studio에서 "Clap please (page 54-58)" + "Wave hand (page 4)"를 드래그하면 **Sequence** 합성기로 1 페이지 짜리 chain 생성.
- 미리보기 GIF 확인, "save as page 100" 클릭 → `motion_4096.bin` 슬롯 100 기록.

### Persona B — Researcher (CLI)
- "Right kick (12)을 좌우 미러링해서 left kick variant를 새로 만들고 싶다 — 기존 13번과 다른 변형으로."
- → `forge synth mirror --src 12 --dst 100 --variant accel*1.2`
- 결과: page 100에 좌우 반전된 kick. 발목 roll만 `mutate` 추가로 5도 비틀어서 측면 슛.

### Persona C — Claude Code 사용자 (자연어)
- "두 번째 모니터에서 Claude Code 켜고 그냥 말로 시킨다."
- → `/synth 손을 흔들며 인사하고 앉아` → Claude가 page 4(`hi`) → page 1(`init` transition) → page 15(`sit down`)를 Sequence 합성기로 연결, 페이지 100~102에 기록, 결과 JSON과 GIF 미리보기 반환.
- 만족 안 하면 "더 천천히, 인사는 두 번 반복" → mutation (speed×0.6) + repeat (page 4) 재적용.

### Persona D — Roboticist (안전 검증)
- "신입이 만든 합성 페이지가 실기기에서 무릎 꺾이는 사고를 냈다 — 사전 차단해야 한다."
- → 모든 합성 결과는 4-stage validator를 통과해야 `.bin` 기록 가능. CI에서 `forge synth lint <page.json>`이 fail 시 PR 머지 차단.

---

## 4. 시스템 분석 (Reference)

### 4.1 ROBOTIS 모션 데이터 모델 (확정)
- **256 페이지 × 512 byte = 128 KiB 파일**.
- **PAGEHEADER (64 byte)**: name[14], repeat, schedule(=0x0A TIME_BASE), stepnum(1..7), speed, accel, next, exit, slope[31], checksum.
- **STEP (64 byte)**: position[31] (uint16 LE), pause, time.
- **Position 특수 비트**: `0x4000` = INVALID(이전 값 유지), `0x2000` = TORQUE_OFF.
- **관절**: 20개 (ID 1..20), MX28 (4096 해상도) / RX28 (1024 해상도).
- **재생 알고리즘**: 3-section 보간 (PRE 가속 → MAIN 선형 → POST 감속). `Action.cpp` line 367-399.
- **Module 합성**: `MotionManager`가 Action/Walking/Head를 list 순차 처리, 마지막 모듈이 enable한 관절을 덮어쓴다.

> 상세는 [`docs/motion-format/page-catalog-motion4096.md`](../motion-format/page-catalog-motion4096.md) 참고.

### 4.2 합성에 활용 가능한 reference 통계
- **단일 자세 anchor**: page 1, 9, 15, 16, 58.
- **단일 동작(독립)**: 12개 (kick, pass, wave, ok/no 등).
- **체인 시퀀스**: 6개 (Introduction은 7-page chain).
- **좌우 대칭쌍**: 12↔13, 70↔71 — mirror 알고리즘 ground truth.
- **속도 분포**: speed 32(기본), 21(대화), 16(부드러움), 12(슬로우).

### 4.3 데모 코드의 페이지 호출 패턴
- 페이지를 **명령 단위**로 사용 (2~8초 지속).
- Soccer/Vision/Motion 모드가 페이지를 동적으로 트리거 (`Action::GetInstance()->Start(<id>)`).
- 자이로 fallen detection 후 자동 복구 페이지 호출(10/11).

> 이 패턴은 본 엔진의 출력물이 **"독립 호출 가능한 페이지" 단위**여야 함을 시사한다 — chain은 next 필드로 연결하되, 각 페이지는 그 자체로 valid해야 한다.

---

## 5. 기능 요구사항

### 5.1 Motion Library (FR-LIB)

| ID | 요구사항 |
|----|---------|
| FR-LIB-1 | `motion_4096.bin` (또는 .mtn) 임포트 → 내부 JSON (Sprint 3 포맷)로 정규화 |
| FR-LIB-2 | 각 페이지에 **시맨틱 메타데이터**를 sidecar (`page-metadata.toml`)로 보관: `tags`(상체/하체/머리/대화/이동/낙상), `body_regions`(어떤 관절 그룹 사용), `duration_ms`, `mirror_pair`(있다면) |
| FR-LIB-3 | 라이브러리 조회 API: `library.find_by_tag("greeting")`, `library.get_by_id(4)`, `library.list_chains()` |
| FR-LIB-4 | 사용자 정의 metadata 오버라이드 (수동 라벨링 보강) |
| FR-LIB-5 | 메타데이터 자동 추론 (휴리스틱): 머리 관절만 움직이면 `head_only`, 다리 진폭 > θ면 `lower_body_dominant` 등 |

### 5.2 합성 연산자 (FR-OP)

여섯 가지 연산자는 모두 **순수 함수**: `synth_op(inputs, params, library) -> Page[]`. 입력 페이지는 변경되지 않는다 (immutability).

#### FR-OP-1: **Sequence** (시간축 연결)
- 입력: 페이지 ID 배열 `[A, B, C, ...]` + transition 옵션
- 동작: A의 마지막 step → B의 첫 step 사이에 **bridge step** 자동 삽입 (linear blend, 기본 time=80)
- 출력: 새 페이지(들). step 합계 > 7이면 자동 분할 후 next 필드로 chain
- 파라미터: `transition_time_ms` (기본 1000), `transition_mode`(linear|ease-in-out), `repeat_first|last`

#### FR-OP-2: **Layer** (부위별 동시 합성)
- 입력: `{upper_body: page_A, lower_body: page_B, head: page_C}`
- 동작: 각 관절 그룹을 다른 페이지에서 가져와 같은 시간축에 병합.
  - 상체: 관절 1~6
  - 하체: 관절 7~18
  - 머리: 관절 19~20
- step 수가 다르면 **시간 정규화 (resampling)** 후 step-wise merge.
- 출력: 단일 페이지 (또는 chain).
- 충돌 정책: 동일 관절을 두 입력이 정의하면 `priority` 옵션으로 결정 (`upper`|`lower`|`head` 우선순위 명시).

#### FR-OP-3: **Morph** (포즈 보간/모핑)
- 입력: 두 페이지 A, B + ratio α ∈ [0,1] (또는 시간 함수 α(t))
- 동작: 각 step의 관절 값을 `(1-α) * A + α * B`로 가중합.
- α가 함수면 progressive morph (시작은 A, 끝은 B로 부드럽게 전이).
- 출력: 단일 페이지.
- 제약: A와 B의 step 수가 다르면 **시간 정규화** 후 동일 step 수로 resample.

#### FR-OP-4: **Mutate** (변형)
- 입력: 페이지 A + mutation spec
- 동작들 (조합 가능):
  - `joint_offset`: 특정 관절에 ±N delta (예: HEAD_TILT +50으로 더 위 보기)
  - `time_scale`: 모든 step의 `time` 필드 ×k (가속/감속)
  - `speed_scale`: PAGEHEADER.speed ×k
  - `amplitude_scale`: 특정 관절 그룹의 진폭 ×k (중심점 기준 스케일)
  - `repeat`: PAGEHEADER.repeat 변경
- 출력: 단일 페이지.
- 결정론: 동일 입력 → 동일 출력 (랜덤 mutation은 별도 시드 인자).

#### FR-OP-5: **Mirror** (좌우 반전)
- 입력: 페이지 A
- 동작:
  - 좌우 관절 쌍 swap: (1↔2, 3↔4, 5↔6, 7↔8, 9↔10, 11↔12, 13↔14, 15↔16, 17↔18).
  - HEAD_PAN(19): `position` → `4095 - position` (또는 적절한 중심 반전, 중심값은 calibration 의존).
  - HEAD_TILT, knee 등 sagittal-symmetric 관절은 그대로.
  - roll 관절은 부호 반전 처리 (중심점 기준).
- 출력: 단일 페이지. 페이지 이름에 `_mirror` 접미사.
- 검증: page 12(`rk`) mirror → page 13(`lk`)에 byte 수준으로 ≥ 95% 일치 (ground truth 테스트).

#### FR-OP-6: **Procedural** (시드 페이지 + 변환식)
- 입력: anchor 페이지(시작/끝 자세) + 궤적 함수
- 동작: 두 anchor 사이의 step을 **수학적 함수**로 생성.
  - 예: 사인파 head sway, 카탈로그에 없는 손 흔들기 진동
  - 함수 라이브러리: `linear`, `ease_in_out`, `sin(ω, φ)`, `bezier(p1, p2)`, `b-spline(control_points)`
- 출력: 1~3 페이지.
- 활용: "5초 동안 머리만 좌우로 두 번 흔들기" 같은 procedural 패턴.

### 5.3 안전 검증 파이프라인 (FR-VAL)

모든 합성 결과는 4-stage validator를 **통과해야** 디스크 기록·기기 송출 가능. 각 stage는 PASS/WARN/FAIL을 반환하고, FAIL은 거부.

| Stage | 명세 |
|-------|------|
| **V1 Joint Limit** | 각 관절의 절대값이 `joint_limits.toml`의 (min, max) 범위 내. 초과 시 FAIL. (`0x4000`, `0x2000` 플래그는 검증 제외.) |
| **V2 Velocity / Acceleration** | step 간 관절 변화량 ÷ time = 추정 각속도. `MX28 max velocity` 초과 시 WARN/FAIL (보수적 임계 75%). |
| **V3 Self-Collision** | 사전 정의된 **black-list pose region** (예: 팔이 다리와 겹치는 각도 조합)에 진입하면 FAIL. v1은 단순 휴리스틱 (joint pair ranges). |
| **V4 Static Stability** | 각 step에서 **CoM(질량 중심)의 ground projection**이 지지 다각형(support polygon) 내부에 있는지 확인. 단일 발 지지 페이지는 별도 플래그(`single_foot_ok`)가 있을 때만 허용. |

### 5.4 출력 & 영속화 (FR-OUT)

| ID | 요구사항 |
|----|---------|
| FR-OUT-1 | 결과 페이지는 우선 **JSON sidecar**(Sprint 3 포맷)로 저장 |
| FR-OUT-2 | 사용자 명시 시 `motion_4096.bin`의 **빈 슬롯**(0번/7번/8번/14번/20~22번/26번/28번/32~37번/40번/48~53번/59~69번/72~89번/92~236번/238번/242~255번 — 211개)에 기록 |
| FR-OUT-3 | 기록 시 **자동 백업**: 원본 `motion_4096.bin`을 `firmware-backups/motion_4096.<utc-iso>.bin`으로 사본 생성 |
| FR-OUT-4 | 모든 합성 결과에 **provenance manifest** (`page-{id}.provenance.json`) 첨부: 사용한 연산자, 입력 페이지 ID, 파라미터, 시드, validator 결과 |

### 5.5 Claude CLI 통합 (FR-CLAUDE)

세 가지 통합 채널을 동시에 제공. 모두 동일한 `forge-core::synth` Rust 엔진을 백엔드로 사용 (FFI 또는 CLI 호출).

#### FR-CLAUDE-1: `/synth` 슬래시 커맨드
- 위치: `~/.claude/commands/synth.md` 또는 프로젝트 로컬.
- 입력: 자연어 한 줄 (예: "손 흔들며 인사하고 앉아").
- Claude의 작업:
  1. 의도 분해 (intent decomposition) → 부분 동작 목록.
  2. Motion Library에서 매칭되는 reference 페이지 검색.
  3. 적절한 합성 연산자 선택 (Sequence vs Layer vs ...).
  4. `forge synth <op>` CLI를 실행 → JSON 결과.
  5. validator 결과 확인. FAIL 시 자동 retry (다른 페이지 조합 또는 parameter 조정, 최대 3회).
  6. GIF/3D 미리보기 경로와 함께 사용자에게 보고.

#### FR-CLAUDE-2: MCP 서버 `forge-motion-synth`
- 위치: 프로젝트 로컬 (`app/mcp/motion-synth/`).
- 노출 도구:
  - `library_search(query: str, tags: [str])` → page list
  - `synth_sequence(pages: [int], options: {...})` → new page JSON
  - `synth_layer(...)`, `synth_morph(...)`, `synth_mutate(...)`, `synth_mirror(...)`, `synth_procedural(...)`
  - `validate(page_json)` → validator report
  - `commit(page_json, slot: int)` → bin write
  - `preview(page_json, format: "gif"|"3d")` → asset path
- 호스트: 표준 MCP stdio. 로컬 Rust 바이너리 `forge-synth-mcp`.

#### FR-CLAUDE-3: Subagent `motion-composer`
- 위치: `.claude/agents/motion-composer.md`.
- 모델: opus (전체 합성 흐름의 reasoning에 적합).
- 권한: Read, Bash(`forge synth *`만 화이트리스트), MCP `forge-motion-synth`만.
- 시스템 프롬프트는 본 PRD의 §4(시스템 분석)와 카탈로그를 reference로 포함.
- 호출 패턴: `/synth` 슬래시가 이 서브에이전트에 위임. 메인 컨텍스트가 합성 추론으로 오염되지 않게 분리.

#### FR-CLAUDE-4: 자연어 → 합성 계획 (Intent Compiler)
- Claude의 머릿속 단계:
  1. **분해**: "손 흔들며 인사하고 앉아" → `[wave_hand, greet, sit]`.
  2. **검색**: 각 부분에 대해 library에서 best-match 페이지 검색 (태그 기반).
  3. **연산자 선택 휴리스틱**:
     - 시간상 순차면 **Sequence**.
     - 동시 발생(상체/하체 동시)이면 **Layer**.
     - "더 천천히", "더 부드럽게"면 **Mutate(time/speed)**.
     - "반대로" 또는 좌우 변형이면 **Mirror**.
     - "두 자세 사이"면 **Morph**.
     - 카탈로그에 없는 패턴은 **Procedural**.
  4. **실행**: MCP 도구 호출.
  5. **검증**: validate 결과 보고.
  6. **회복**: FAIL 시 (a) parameter 완화 (속도 down), (b) 다른 reference 페이지 시도, (c) 사용자에게 명세 요청.

### 5.6 미리보기 & 시뮬레이션 (FR-PREVIEW)

| ID | 요구사항 |
|----|---------|
| FR-PREVIEW-1 | `forge synth simulate <page.json> --out gif` — 합성 페이지를 토크 끈 상태의 시뮬레이션으로 재생, 30fps GIF로 export |
| FR-PREVIEW-2 | SwiftUI Studio에서 3D 미리보기(이미 Sprint 7에 viewer 존재) → 합성 페이지를 viewer에 로드 |
| FR-PREVIEW-3 | 실기기 dry-run: 토크 OFF 모드에서 합성 페이지를 CM-730에 송출하되 모터는 free, 충돌 시뮬레이션 가능 |
| FR-PREVIEW-4 | validator 결과를 미리보기에 overlay (위반 step을 빨간 프레임으로) |

---

## 6. 기술 아키텍처

### 6.1 컴포넌트 다이어그램 (텍스트)

```
┌───────────────────────────────────────────────────────────────────────┐
│                          User Surfaces                                │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────────┐ │
│  │ SwiftUI      │  │ forge CLI    │  │ Claude Code                 │ │
│  │ Studio       │  │ `synth ...`  │  │ (slash / MCP / subagent)    │ │
│  └──────┬───────┘  └──────┬───────┘  └──────────────┬──────────────┘ │
└─────────┼──────────────────┼──────────────────────────┼───────────────┘
          │ FFI              │ exec                     │ MCP stdio
          ▼                  ▼                          ▼
┌───────────────────────────────────────────────────────────────────────┐
│                  forge-core::synth (Rust, new)                        │
│                                                                       │
│  ┌────────────┐  ┌───────────────┐  ┌──────────────┐  ┌────────────┐│
│  │ library    │  │ operators     │  │ validator    │  │ provenance ││
│  │ - load_bin │  │ - sequence    │  │ - V1 limits  │  │ - manifest ││
│  │ - metadata │  │ - layer       │  │ - V2 vel     │  │ - audit    ││
│  │ - search   │  │ - morph       │  │ - V3 collide │  │            ││
│  │            │  │ - mutate      │  │ - V4 stable  │  │            ││
│  │            │  │ - mirror      │  │              │  │            ││
│  │            │  │ - procedural  │  │              │  │            ││
│  └─────┬──────┘  └───────┬───────┘  └──────┬───────┘  └─────┬──────┘│
│        │                 │                 │                │       │
│        └─────────────────┴─────────────────┴────────────────┘       │
│                                  │                                    │
└──────────────────────────────────┼────────────────────────────────────┘
                                   ▼
                ┌─────────────────────────────────┐
                │ forge-core::motion (existing)   │
                │ - PageData, StepData            │
                │ - bin4096 read/write            │
                │ - mtn parser/writer             │
                └─────────────────────────────────┘
```

### 6.2 신규 Rust 모듈 (Sprint 9 산출물)

```
app/core/forge-core/src/synth/
├── mod.rs                  // public API
├── library.rs              // PageLibrary, metadata
├── metadata.rs             // tag inference heuristics
├── ops/
│   ├── mod.rs              // SynthOp trait
│   ├── sequence.rs
│   ├── layer.rs
│   ├── morph.rs
│   ├── mutate.rs
│   ├── mirror.rs
│   └── procedural.rs
├── validator/
│   ├── mod.rs              // Validator trait + Report
│   ├── joint_limit.rs      // V1
│   ├── velocity.rs         // V2
│   ├── self_collision.rs   // V3
│   └── static_stability.rs // V4
├── provenance.rs           // Manifest
└── error.rs
```

### 6.3 CLI 서브커맨드 추가 (`forge-cli`)

```
forge synth library list [--tag <t>] [--id <n>]
forge synth library tag <id> <tag>+
forge synth sequence <id>+ [--transition-ms <n>] [--out <path>]
forge synth layer --upper <id> --lower <id> [--head <id>] [--out <path>]
forge synth morph <id-a> <id-b> --ratio <0..1> [--curve linear|ease] [--out <path>]
forge synth mutate <id> [--joint-offset <name>=<delta>]+ [--time-scale <k>] [--out <path>]
forge synth mirror <id> [--out <path>]
forge synth procedural --anchor-start <id> --anchor-end <id> --curve <spec> [--out <path>]
forge synth validate <page.json>
forge synth commit <page.json> --slot <n> [--no-backup]
forge synth simulate <page.json> --format gif|stl-trace [--out <path>]
```

### 6.4 Swift UI 통합 (Sprint 11)

`app/ui/DarwinForge/Sources/Studio/SynthPalette.swift` 신규 (시뮬레이트):
- 좌측 패널: Library browser (페이지 카드, drag source)
- 중앙: 합성 캔버스 (drag-and-drop으로 sequence/layer)
- 우측: parameter inspector + validator report
- 하단: 3D 미리보기 (Sprint 7 viewer 재사용)

---

## 7. 데이터 모델

### 7.1 Page (확장 — Sprint 3 호환)

```json
{
  "id": 100,
  "name": "wave_then_sit",
  "schedule": "time_base",
  "repeat": 1,
  "speed": 32,
  "accel": 32,
  "next": 0,
  "exit": 0,
  "slope": [85,85,85,85,...],
  "steps": [
    {
      "positions": {
        "R_SHOULDER_PITCH": {"value": 2048, "flags": []},
        "L_SHOULDER_PITCH": {"value": null,  "flags": ["INVALID"]},
        "HEAD_TILT":        {"value": 2100, "flags": ["TORQUE_OFF"]}
      },
      "pause": 0,
      "time": 80
    }
  ]
}
```

### 7.2 Page Metadata (sidecar TOML)

```toml
[page.4]
name = "hi"
tags = ["greeting", "upper_body", "demo"]
body_regions = ["upper_body", "head"]
duration_ms = 1200
mirror_pair = null   # 좌우 대칭쌍이 없음
description = "Right hand wave with subtle head tilt — used for Thank you mp3"

[page.12]
name = "rk"
tags = ["soccer", "kick", "right", "balance_critical"]
body_regions = ["lower_body"]
duration_ms = 2800
mirror_pair = 13
single_foot_ok = true   # V4 검증 완화 플래그
```

### 7.3 Synthesis Recipe

합성 의도를 declarative로 저장 (재현 가능, Claude가 생성하기 좋음):

```toml
[recipe]
version = 1
name = "wave_then_sit"
description = "손 흔들며 인사하고 앉기"
output_slot = 100

[[recipe.steps]]
op = "sequence"
inputs = [4, 1, 15]
options = { transition_ms = 800 }

# 시드/파라미터를 기록 → byte-identical 재현 보장
[recipe.repro]
synth_engine_version = "0.1.0"
random_seed = null  # 결정론적이라 시드 불필요
```

### 7.4 Provenance Manifest

```json
{
  "page_id": 100,
  "created_utc": "2026-05-12T10:00:00Z",
  "engine_version": "0.1.0",
  "recipe": "<inline TOML or path>",
  "validator_report": {
    "V1": "PASS",
    "V2": "WARN: knee velocity 82% of max",
    "V3": "PASS",
    "V4": "PASS"
  },
  "inputs": [{"id": 4, "checksum": "sha256:..."}, {"id": 1, "checksum": "sha256:..."}],
  "claude_session": "ses-abc123"
}
```

---

## 8. 알고리즘 명세

### 8.1 Sequence — 의사코드

```
function sequence(pages: [Page], transition_ms: int) -> [Page]:
  result_steps = []
  for i, p in enumerate(pages):
    if i > 0:
      bridge = build_bridge(
        from_step = result_steps[-1],
        to_step   = p.steps[0],
        time_ms   = transition_ms,
      )
      result_steps.append(bridge)
    result_steps.extend(p.steps)
  return split_into_pages(result_steps, max_steps=7)

function build_bridge(from, to, time_ms) -> Step:
  # linear interpolation은 actually 의미 없음 (Action.cpp의 PRE 가속이 처리)
  # 그러나 명시적 anchor가 더 안전 → "midpoint pose" + time=time_ms
  positions = { j: (from[j].value + to[j].value) // 2 for j in joints }
  return Step(positions, pause=0, time=time_ms_to_units(time_ms))

function split_into_pages(steps, max_steps) -> [Page]:
  # step이 7개 초과면 페이지 분할 + next 필드로 chain
  pages = []
  for i in range(0, len(steps), max_steps):
    chunk = steps[i:i+max_steps]
    p = new_page(steps=chunk)
    if i + max_steps < len(steps):
      p.next = assign_next_slot()
    pages.append(p)
  return pages
```

### 8.2 Layer — 의사코드

```
function layer(upper: Page, lower: Page, head: Optional[Page]) -> Page:
  # 시간축 정규화
  total_ms = max(duration_of(upper), duration_of(lower), duration_of(head or empty))
  resampled_upper = resample(upper, total_ms, num_steps=7)
  resampled_lower = resample(lower, total_ms, num_steps=7)
  resampled_head  = resample(head,  total_ms, num_steps=7) if head else None
  
  merged_steps = []
  for i in range(7):
    pos = {}
    pos.update(joints_in_region(resampled_upper.steps[i], "upper_body"))
    pos.update(joints_in_region(resampled_lower.steps[i], "lower_body"))
    if resampled_head:
      pos.update(joints_in_region(resampled_head.steps[i], "head"))
    merged_steps.append(Step(positions=pos, pause=0, time=total_ms // 7))
  return Page(steps=merged_steps)

function resample(page: Page, target_ms: int, num_steps: int) -> Page:
  # cubic spline 보간으로 시간 정규화. 위치 0x4000(INVALID) 비트는 skip.
  ...
```

### 8.3 Morph — 의사코드

```
function morph(a: Page, b: Page, ratio: float | Callable[[int], float]) -> Page:
  n = max(len(a.steps), len(b.steps))
  resampled_a = resample(a, n)
  resampled_b = resample(b, n)
  out_steps = []
  for i in range(n):
    alpha = ratio if isinstance(ratio, float) else ratio(i / (n-1))
    pos = {}
    for j in JOINTS:
      va = resampled_a.steps[i].positions[j].value
      vb = resampled_b.steps[i].positions[j].value
      if va is None: pos[j] = vb        # one-sided INVALID
      elif vb is None: pos[j] = va
      else: pos[j] = round((1-alpha) * va + alpha * vb)
    out_steps.append(Step(positions=pos, ...))
  return Page(steps=out_steps)
```

### 8.4 Mirror — 의사코드

```
LEFT_RIGHT_PAIRS = [(1,2), (3,4), (5,6), (7,8), (9,10), (11,12), (13,14), (15,16), (17,18)]
ROLL_JOINTS = {3, 4, 9, 10, 17, 18}    # 좌우 부호 반전 대상
HEAD_PAN = 19                          # 중심 반전 (4095 - v)

function mirror(p: Page) -> Page:
  new_steps = []
  for s in p.steps:
    new_pos = {}
    for (l, r) in LEFT_RIGHT_PAIRS:
      new_pos[l] = s.positions[r]
      new_pos[r] = s.positions[l]
    for j in ROLL_JOINTS:
      new_pos[j] = mirror_around_center(new_pos[j], center=2048)
    new_pos[HEAD_PAN] = 4095 - s.positions[HEAD_PAN].value
    # HEAD_TILT, 무릎 등 sagittal symmetric → 그대로
    new_pos[20] = s.positions[20]   # HEAD_TILT
    new_pos[13] = mirror_swap_only(...)   # KNEE는 좌우 swap만, 부호 반전 X
    new_steps.append(Step(positions=new_pos, ...))
  return Page(name=f"{p.name}_mirror", steps=new_steps)

# Validation: mirror(page 12) ≈ page 13 within tolerance.
```

### 8.5 Validator V4 (Static Stability) — 의사코드

```
function validate_static_stability(p: Page, robot: KinematicModel) -> Report:
  for i, step in enumerate(p.steps):
    pose = decode_positions(step)
    com = robot.compute_com(pose)              # 3D point (x, y, z)
    com_ground = (com.x, com.y)                # XY projection
    support_poly = robot.support_polygon(pose) # 발 접지 영역의 convex hull
    if not point_in_polygon(com_ground, support_poly):
      margin = signed_distance(com_ground, support_poly)
      if margin < -SAFETY_MARGIN_MM:
        return FAIL(f"step {i}: CoM outside support polygon by {-margin}mm")
      else:
        return WARN(...)
  return PASS
```

> 운동학(FK)은 Sprint 5 walk engine의 `Kinematics.cpp` 포팅을 재사용. 질량 분포는 `docs/architecture/op1-vs-op2-matrix.md`에서 가져온다.

---

## 9. Claude CLI 통합 명세

### 9.1 `/synth` 슬래시 커맨드 시방

**파일**: `.claude/commands/synth.md`

```markdown
---
description: 자연어로 새 모션 페이지 합성. Motion Synthesis 엔진 호출.
---

당신은 `motion-composer` 서브에이전트로 위임할 책임이 있다.
사용자 입력을 의도 단위로 분해하고, `forge-motion-synth` MCP를 통해
적절한 합성 연산자를 호출하라.

**필수 절차**:
1. 입력 자연어 → 부분 동작 목록
2. `library_search`로 reference 페이지 매칭
3. 연산자 선택 (Sequence / Layer / Morph / Mutate / Mirror / Procedural)
4. 합성 실행 → validator 결과 확인
5. WARN/FAIL이면 한 번까지 자동 재시도 (parameter 완화 또는 reference 교체)
6. 결과 페이지 ID, 미리보기 경로, validator 요약을 한국어로 보고
7. `commit` 단계는 **항상 사용자 확인 후**에만 실행 (FR-OUT 안전 절차)

**금지**:
- validator를 우회한 commit
- `motion_4096.bin` 직접 편집 (반드시 엔진 경유)
- 백업 없는 덮어쓰기

**예시 입력 / 출력**:
- "손 흔들며 인사하고 앉아" → page 100 (Sequence 4→1→15)
- "오른발 킥을 왼발로 미러링" → page 101 (Mirror 12)
- "Wow 동작 50% 느리게" → page 102 (Mutate 24, time_scale=2.0)
```

### 9.2 MCP 서버 도구 시그니처

```typescript
// 도구 목록 (MCP 형식)
{
  "library_search": {
    "input": { "query": "string", "tags": "string[]" },
    "output": { "pages": [{ "id": "int", "name": "string", "tags": "string[]", "duration_ms": "int" }] }
  },
  "synth_sequence": {
    "input": { "page_ids": "int[]", "transition_ms": "int = 800" },
    "output": { "page_json": "object", "validator_report": "object" }
  },
  "synth_layer": { /* upper, lower, head */ },
  "synth_morph":  { /* a, b, ratio */ },
  "synth_mutate": { /* page_id, mutations[] */ },
  "synth_mirror": { /* page_id */ },
  "synth_procedural": { /* anchor_start, anchor_end, curve */ },
  "validate": { "input": { "page_json": "object" }, "output": { "report": "object" } },
  "commit": {
    "input": { "page_json": "object", "slot": "int", "backup": "bool = true" },
    "output": { "bin_path": "string", "backup_path": "string", "manifest_path": "string" }
  },
  "preview": {
    "input": { "page_json": "object", "format": "gif|3d_trace" },
    "output": { "asset_path": "string" }
  }
}
```

### 9.3 `motion-composer` 서브에이전트 정의

**파일**: `.claude/agents/motion-composer.md`

핵심 시스템 프롬프트 요소:
- 본 PRD §4 시스템 분석 + 페이지 카탈로그 임베드.
- 권한: `Bash(forge synth*)`, `Read`, MCP `forge-motion-synth`만. **`Write`는 명시적 commit 시점에만**.
- 6가지 연산자 선택 의사결정 트리 (§5.5.4의 휴리스틱).
- 안전 명세: validator FAIL = "절대 commit 금지".
- 출력 양식: 한국어 1~2줄 요약 + page id + 미리보기 경로.

### 9.4 Claude API 캐싱 (FR-CLAUDE 확장)

본 워크플로우는 라이브러리 카탈로그(~40KB) + 시스템 프롬프트가 매 호출 동일 → **prompt caching** 적용.
- `library catalog` 블록을 `cache_control: ephemeral`로 마크.
- 캐시 히트율 ≥ 80% 목표.

---

## 10. 검증 계획

### 10.1 단위 테스트 (Rust, Sprint 9)

| 영역 | 테스트 |
|------|--------|
| library | 45 페이지 round-trip, metadata 추론 정확도 ≥ 90% |
| sequence | 2개 / 3개 / 8개(분할) 페이지, transition mode 3종 |
| layer | upper/lower 단순, 충돌 정책 우선순위 3가지 |
| morph | ratio=0/0.5/1, callable ratio, step 수 차이 |
| mutate | 5가지 mutation 종류 각각 |
| mirror | **page 12 mirror ≈ page 13 (Hamming ≤ 5%)**, page 70 mirror ≈ page 71 |
| procedural | 3가지 curve 함수 |
| validator | 4 stage 각각 (PASS/WARN/FAIL 시나리오 9개 이상) |
| bin write | 빈 슬롯 기록 후 round-trip = byte-identical, checksum valid |

**목표**: 신규 ≥ 60 tests, total ≥ 130 tests (현 73 + 신규 ~60).

### 10.2 통합 테스트 (Sprint 10)

1. **End-to-end recipe**: `wave_then_sit.recipe.toml` → JSON → validator → bin slot 100 → re-read → byte-identical.
2. **Claude scenario simulation**: 자연어 입력 10개를 가짜 Claude 응답으로 mock → 모두 valid 페이지 산출.
3. **regression**: `motion_4096.bin`의 모든 45개 page → 합성 라이브러리 로딩 → 다시 export → byte-identical.

### 10.3 사용자 수용 테스트 (Sprint 11)

- Persona A~D 각 시나리오를 SwiftUI Studio + CLI + Claude `/synth`로 수행.
- 성공 기준: 4/4 persona가 도움 없이 1차 시도에서 의도된 모션 생성.

### 10.4 실기기 검증 (Sprint 12, optional)

- Mac → CM-730 (Sprint 1 connection 재사용) → 합성 페이지 송출.
- 토크 off mode로 시작, 사용자가 확인 후 torque on.
- 4-stage validator의 안전성을 1차 dry-run으로 검증.

---

## 11. 구현 단계 (Sprint 9 ~ 12)

| Sprint | 기간(목표) | 핵심 산출 | 종료 조건 |
|--------|-----------|----------|-----------|
| **9 — Synth Core** | 2주 | `forge-core::synth` 6 연산자 + 4 validator + library | 신규 60 tests, `forge synth library list` 동작 |
| **10 — CLI & MCP** | 1주 | `forge synth *` 11 서브커맨드, MCP 서버 `forge-motion-synth`, provenance 기록 | end-to-end recipe 합성 → bin commit 가능 |
| **11 — SwiftUI Studio Synth Palette** | 1.5주 | Drag-and-drop 합성 UI, 3D preview 재사용, validator overlay | Persona A 시나리오 수동 검증 |
| **12 — Claude Integration & Hardening** | 1주 | `/synth` 슬래시, `motion-composer` 서브에이전트, prompt caching, 실기기 dry-run | Persona C 시나리오 시연 영상 (또는 GIF) |

### 11.1 Sprint 9 — 작업 분해

```
S9-1  module skeleton (mod.rs, error.rs, traits)
S9-2  library: load_bin, metadata inference (FR-LIB-1..5)
S9-3  ops::sequence + tests
S9-4  ops::layer + resample helper + tests
S9-5  ops::morph + tests
S9-6  ops::mutate + tests
S9-7  ops::mirror + ground truth tests (page 12↔13)
S9-8  ops::procedural + curve library
S9-9  validator::joint_limit + velocity
S9-10 validator::self_collision + static_stability
S9-11 provenance manifest
S9-12 integration: full pipeline test
```

### 11.2 Sprint 10 — CLI / MCP

```
S10-1 forge-cli: synth subcommand parsing
S10-2 11 subcommands wiring
S10-3 bin commit + backup
S10-4 simulate --format gif (rerun stub Sprint 7 viewer offline render)
S10-5 MCP server skeleton (stdio)
S10-6 MCP tools 1..9 wiring
S10-7 integration: recipe → MCP → bin
```

### 11.3 Sprint 11 — UI

```
S11-1 SynthPalette view skeleton
S11-2 Library browser
S11-3 Drag-drop canvas for sequence/layer
S11-4 Parameter inspector
S11-5 Validator report overlay
S11-6 3D preview re-use
```

### 11.4 Sprint 12 — Claude

```
S12-1 .claude/commands/synth.md
S12-2 .claude/agents/motion-composer.md
S12-3 MCP registration in project settings
S12-4 prompt caching wiring
S12-5 Persona scenarios E2E
S12-6 실기기 dry-run (optional)
S12-7 Sprint report + PROGRESS.md 갱신
```

---

## 12. 안전 / 라이선스 / 리스크

### 12.1 안전
- 모든 합성 결과는 4-stage validator를 통과해야만 디스크/기기 기록 가능 (FR-VAL).
- `commit` 작업은 항상 자동 백업.
- `motion_4096.bin`의 기존 페이지(1..91, 237..241 등)는 **read-only**로 마킹. 사용자 명시적 `--allow-overwrite` 플래그 없이 덮어쓰기 금지.
- Claude `commit`은 사용자 확인 단계 필수 (FR-CLAUDE-1).

### 12.2 라이선스
- ROBOTIS `Framework` 소스: GPL/특정 라이선스 확인 필요 (Phase 1 research에서 정리). 본 엔진은 **Framework 소스를 직접 포함하지 않는다** — 포맷 스펙만 참조.
- 합성 결과 페이지는 Darwin Forge의 Apache 2.0 라이선스 하에 배포.

### 12.3 리스크 (R) & 완화 (M)

| R | 리스크 | 영향 | M |
|---|--------|------|---|
| R1 | Validator V4 (static stability)의 질량 모델 부정확 → false PASS | 실기기 파손 | 보수적 safety margin, 실기기 첫 송출은 항상 torque off |
| R2 | Mirror 알고리즘의 좌우 부호 정의가 페이지마다 다를 수 있음 | 미러링이 깨짐 | page 12↔13, 70↔71을 ground truth로 회귀 테스트 |
| R3 | Claude의 자연어 의도 분해 실패 | 잘못된 모션 합성 | (a) 합성 결과 미리보기 강제 (b) validator로 명백한 실패 차단 (c) 사용자 확인 필수 |
| R4 | 빈 슬롯 기록 시 다른 도구와 충돌 | 데이터 손실 | 항상 자동 백업, `.bin` lock 파일 |
| R5 | `motion_4096.bin` vs `motion_1024.bin` 해상도 차이 | 합성 결과가 RX28 호환 안 됨 | 엔진은 4096 기준, 다운컨버터 별도 (Sprint 12 후보) |
| R6 | MCP 도구 권한 누수 | Claude가 의도치 않게 commit | 권한 설정에서 `commit`을 explicit ask로 강제 |

---

## 13. 미해결 질문 (Open Questions)

1. **Q1**: `slope[31]` (compliance) 값을 합성 시 어떻게 처리하는가?
   - 옵션 A: 모든 합성 페이지에 기본값 `0x55` 적용.
   - 옵션 B: 입력 페이지 평균.
   - 옵션 C: validator V2에서 동적 결정.
   - **결정 보류** — Sprint 9 진행 중 결정.

2. **Q2**: Procedural의 curve 라이브러리 범위?
   - 최소 `linear / ease / sin / bezier`로 시작.
   - 추가 후보: cubic spline, b-spline, perlin noise (랜덤 mutation용).
   - **결정 보류** — Sprint 9 후반 결정.

3. **Q3**: 실기기 검증을 Sprint 12에 묶는가, 별도 Sprint 13으로 빼는가?
   - 본 PRD는 optional로 포함. 하드웨어 확보 일정에 따름.

4. **Q4**: `/synth` 슬래시가 사용자에게 **언제 확인을 요구**하는가?
   - validator WARN: 옵션, 기본 자동 진행.
   - validator FAIL: 자동 재시도 1회 후 사용자에게 보고.
   - commit: 항상 요구.

5. **Q5**: 시뮬레이션 GIF의 렌더러 — Sprint 7 SwiftUI viewer를 헤드리스로 돌리는가, Rust + bevy로 별도?
   - **현재 잠정**: SwiftUI viewer 헤드리스. Bevy는 over-engineering.

---

## 14. 결정 사항 (Decisions, 즉시 적용)

| # | 결정 | 근거 |
|---|------|------|
| D1 | 본 PRD를 master spec으로 lock. 변경은 ADR-014+를 통해서만. | 합성 로직은 안전 결과에 직결 — drift 방지 |
| D2 | 신규 ADR: ADR-014 (Motion Synthesis architecture) Sprint 9 착수 시 작성 | 의사결정 추적 |
| D3 | 6 연산자 외 추가 연산자(예: 신경망 기반)는 v2로 보류 | v1 scope 보호 |
| D4 | Reference 데이터는 `motion_4096.bin` 기준 (1024는 다운컨버터 별도) | 단일 truth |
| D5 | Page metadata는 TOML sidecar (수동 + 자동 추론 병행) | YAML보다 commenting 좋고 사람이 편집 가능 |
| D6 | Synthesis Recipe도 TOML | 동일 |
| D7 | Provenance Manifest는 JSON (machine-readable, Claude가 쉽게 생성) | Claude 친화 |
| D8 | Claude CLI 통합은 3-track(slash, MCP, subagent) 모두 — 사용자 진입점 다양화 | 사용자가 어디서나 가능 |

---

## 15. 다음 액션 (Implementation Gating)

이 PRD는 **draft 상태**다. 사용자 승인 → Sprint 9 착수.

승인 절차:
1. 사용자가 본 문서를 검토.
2. §13 Open Questions에 대한 답변 또는 "Sprint 9 진행 중 결정 OK" 컨펌.
3. 사용자가 "구현 시작" 신호 → Sprint 9-1부터 자율 실행 (이전 ROADMAP 패턴).

승인 전 추가 검증 요청 시:
- (선택) `architect` 서브에이전트로 §6 아키텍처 review.
- (선택) `code-reviewer`로 §8 알고리즘 의사코드 review.
- (선택) `security-reviewer`로 §12.3 R6 (MCP 권한) review.

---

## 16. 참고 자료

- 본 워크트리: `app/core/forge-core/src/motion/*` (Sprint 3 기반 코드)
- 페이지 카탈로그: [`docs/motion-format/page-catalog-motion4096.md`](../motion-format/page-catalog-motion4096.md)
- 모션 포맷 명세: [`docs/motion-format/page-format.md`](../motion-format/page-format.md), [`mtn-format.md`](../motion-format/mtn-format.md)
- 관절 컨벤션: [`docs/architecture/joint-conventions.md`](../architecture/joint-conventions.md)
- 기존 ADR: `docs/decisions/ADR-001..013`
- ROBOTIS 원본: `DARwIn-OP_ROBOTIS_v1.6.0/Framework/{include,src/motion}/`

---

## 17. 외부 의존성 — 4b5672a 머지 통합 계획

> **2026-05-12 업데이트**: 병행 진행 중인 `claude/gracious-mahavira-74d8c2` /
> `claude/humanlike-motion-design` 두 worktree(동일 커밋 **4b5672a**)가 본 PRD의
> S9-2 / S9-10에서 만들 빌딩 블록을 **이미 구현했다**. 중복 작업을 막기 위해
> 본 절을 기준으로 우리 synth 레이어가 그 산출물을 **재사용**한다.

### 17.1 4b5672a가 제공하는 API (확인됨)

| 모듈 / 항목 | 경로 | 본 PRD에서 사용처 |
|-------------|------|---------------------|
| `motion::bin4096::RawPage` | `motion/bin4096.rs:30` | **S9-2** raw 로더 |
| `motion::bin4096::parse_bin4096` | 같은 파일 | S9-2 |
| `motion::bin4096::read_bin4096_file` | 같은 파일 | S9-2 |
| `motion::bin4096::write_bin4096` | 같은 파일 | S10-3 commit 단계 |
| `motion::bin4096::{PAGE_SIZE_BYTES, NUM_PAGES, FILE_SIZE_BYTES, NAME_LEN}` | 상수 | 검증·테스트 |
| `motion::OfficialCatalogEntry`, `OFFICIAL_CATALOG` | `motion/library.rs` | **S9-2** 메타데이터 자동 추론 단순화 |
| `motion::SafetyClass` | `motion/page.rs` | `synth::metadata::PageMetadata` 와 매핑 |
| `safety::self_collision::check_step`, `check_page`, `CollisionError` | `safety/self_collision.rs:59,136` | **S9-10 V3 validator의 본체** (thin wrapper만 작성) |
| `safety::torque_ramp::TorqueRampProfile`, `TorqueRamper` | `safety/torque_ramp.rs:28,84` | S10-3 commit 시 토크 ramp 적용 |
| `joint::{JointId, JointMap, JointMapKind, LegacyAnkleIds, position_to_radians}` | `joint/{mod,map}.rs` | 모든 ops + validator |

### 17.2 머지 후 적용할 import 매핑

각 스켈레톤 파일에 추가/수정될 use 절:

```rust
// synth/library.rs (S9-2 본구현)
use crate::motion::bin4096::{read_bin4096_file, RawPage};
use crate::motion::{OFFICIAL_CATALOG, OfficialCatalogEntry, SafetyClass};
// RawPage → MotionPage 의미 디코드 + sidecar 메타데이터 부착

// synth/validator/self_collision.rs (S9-10 본구현)
use crate::safety::self_collision::{check_page as safety_check_page, CollisionError};
// → ValidatorReport 로 매핑하는 thin wrapper

// synth/ops/mirror.rs (S9-7)
use crate::joint::JointId;   // 좌우 페어를 JointId enum 으로 재정의

// synth/validator/velocity.rs (S9-9)
// torque_ramp 와는 별도 — synth 단계 정적 검증, ramp 는 commit 단계 동적 검증
```

### 17.3 작업별 의존성 게이트

| Sprint 작업 | 4b5672a 필요? | 게이트 |
|------------|---------------|--------|
| S9-1 모듈 스켈레톤 | ❌ 무관 | ✅ 완료 (2026-05-12) |
| **S9-2** library 본구현 | ✅ **필수** | 머지 후 즉시 착수 가능 |
| S9-3 Sequence | ⚠️ 권장 (테스트에 RawPage 사용) | 머지 후 |
| S9-4 Layer | ⚠️ 권장 | 머지 후 |
| S9-5 Morph | ⚠️ 권장 | 머지 후 |
| S9-6 Mutate | ⚠️ 권장 | 머지 후 |
| **S9-7** Mirror | ✅ JointId 사용 | 머지 후 |
| S9-8 Procedural | ⚠️ 권장 | 머지 후 |
| S9-9 V1 / V2 | ⚠️ 권장 | 머지 후 |
| **S9-10 V3 / V4** | ✅ **필수** | 머지 후 (V3 = safety wrapper) |
| S9-11 provenance | ❌ 무관 | 언제든 |
| S9-12 integration | ✅ 필수 | 머지 후 |

### 17.4 PRD §5.3 V3 (Self-Collision) 명세 수정

원래 "v1은 단순 휴리스틱 (joint pair ranges)"이었으나, 4b5672a가 이미 5종
충돌 룰 (knee hyperextension, hip roll, shoulder roll, arm-head, hip+knee 조합)
을 구현했다. **본 PRD의 V3는 그것을 그대로 호출**하는 어댑터로 축소.

```rust
// synth/validator/self_collision.rs (post-merge)
impl Validator for SelfCollisionValidator {
    fn validate(&self, page: &MotionPage) -> Result<ValidatorReport> {
        match crate::safety::self_collision::check_page(page) {
            Ok(_) => Ok(ValidatorReport::Pass(self.stage())),
            Err(errs) => Ok(ValidatorReport::Fail(
                self.stage(),
                format!("{} collision rule(s) violated: {:?}", errs.len(), errs),
            )),
        }
    }
}
```

### 17.5 PRD §11.1 S9-2 작업 분해 수정

원래 S9-2는 "library: load_bin, metadata inference"였다. 4b5672a 후엔:

- S9-2a: `RawPage` → `MotionPage` 의미 디코드 함수 (`PAGEHEADER` offset 적용)
- S9-2b: `OFFICIAL_CATALOG` 와 cross-reference 해 `PageMetadata` 자동 생성
- S9-2c: `SafetyClass` → `PageMetadata.single_foot_ok` 등 매핑
- S9-2d: `PageLibrary` 의 in-memory 조회 / 태그 필터

작업 분량이 절반으로 감소.

### 17.6 머지 대기 / 진행 가능 작업

**머지 전 진행 가능한 작업** (4b5672a에 무관):
- S9-1 ✅ 완료
- S9-11 provenance manifest 본구현
- ADR-014 (Motion Synthesis architecture) 작성
- `forge-core::synth` 단위 테스트 인프라 (fixture 페이지를 hand-coded `MotionPage`로)

**머지 후 즉시 착수** (우선순위 순):
1. S9-2 (library — 4b5672a 활용으로 분량 절감)
2. S9-10 V3 (thin wrapper)
3. S9-7 (Mirror — JointId 재사용)
4. S9-3 ~ S9-8 나머지 ops
5. S9-9 V1 / V2 validator
6. S9-10 V4 (static stability)
7. S9-12 integration

### 17.7 충돌 회피 약속

- 본 worktree(`naughty-chebyshev-713072`) 는 `app/core/forge-core/src/synth/*` **새 디렉토리만** 추가한다.
- `lib.rs` 수정은 `pub mod synth;` **1줄 추가만** — 4b5672a 도 같은 파일을 수정했지만 추가-only 형태라 3-way merge 자동 해결 가능 (`pub mod safety;` 와 알파벳 인접).
- `motion/page.rs`, `motion/mod.rs`, `joint/*`, `safety/*` 는 **건드리지 않는다**.
- `docs/prd/`, `docs/motion-format/page-catalog-motion4096.md` 는 4b5672a 가 건드리지 않은 새 영역.

---

> **상태 요약 (한 줄)**: 분석·기획·검증·스켈레톤 완료. **4b5672a 머지 대기 중.**
> 머지되면 §17.6의 우선순위대로 S9-2 부터 자율 실행.
