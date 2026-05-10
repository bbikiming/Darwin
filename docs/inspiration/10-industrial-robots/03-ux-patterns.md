# 03. 협동 로봇 UI / UX 패턴 — 티칭 펜던트와 시뮬레이터

> 6대 제조사의 티칭 펜던트 / 데스크탑 시뮬레이터를 비교 분석.
> Direct teaching 흐름이 DarwinForge "Pose Capture" 모드에 직결.
>
> 화면 캡처는 직접 못 봐도 공식 매뉴얼/유튜브 데모 기반 ASCII 분석.
> 출처 URL 필수, 미확인은 "확인 필요".

## 한 줄 비교

| 도구 | 디바이스 | OS / 엔진 | 입력 모달리티 | 프로그래밍 모델 | 우리 차용도 |
|------|----------|-----------|---------------|-----------------|--------------|
| **PolyScope X** (UR) | 12.1" 터치 펜던트 | Linux + 자체 Qt | Touch + Free-drive 버튼 | Waypoint 시퀀스 + URScript | ★★★ Pose Capture |
| **iPendant** (FANUC) | 10.4" 터치 펜던트 | VxWorks / 자체 | Touch + Hard 키 | TPP / KAREL | ★ |
| **FlexPendant** (ABB) | 8.4" 터치 펜던트 | Windows CE → Linux | Touch + 조이스틱 | RAPID 시퀀스 | ★★ 양팔 |
| **smartPAD** (KUKA) | 10" 터치 펜던트 | Windows Embedded | Touch + 6D Mouse + 인에이블 스위치 | KUKA Sunrise.Workbench (Java) | ★★★ 3-pos enabling |
| **DART-Studio** (Doosan) | 데스크탑 PC | Windows 10/11 | 마우스 + 키보드 + Direct teach 버튼 | DRL (Python) + Skill Block | ★★★ Skill Block 시각화 |
| **RoboGuide** (FANUC) | 데스크탑 PC | Windows | 마우스 (시뮬 전용) | 시뮬+TPP | ★ |
| **RobotStudio** (ABB) | 데스크탑 PC | Windows | 마우스 (시뮬 전용) | RAPID + 시뮬 | ★ |
| **KUKA.Sim** | 데스크탑 PC | Windows | 마우스 (시뮬) | 시뮬 + Sunrise | ★ |
| **RT ToolBox3** (Mitsubishi) | 데스크탑 PC | Windows | 마우스 | MELFA-BASIC V | ★ |

(출처: 각 도구 공식 매뉴얼 — 본문 인용)

---

## 1) PolyScope X (UR) — 직관성의 표준

### 화면 레이아웃

PolyScope X (5세대, 2024)는 이전 PolyScope (Java Swing) 을 Qt 기반 다크 테마 UI로 재설계.

```
┌──────────────────────────────────────────────────────────┐
│ [Run] [Stop] [E-Stop] | UR5e@workshop | Mode: Manual    │ ← 상단 항상 가시
├────────────┬─────────────────────────────────┬───────────┤
│            │                                 │           │
│ Program    │     3D 그래픽 시뮬 뷰포트       │ Variables │
│ Tree       │     (관절 색상 = 안전 상태)      │ Watcher   │
│            │                                 │           │
│ ├ MoveJ    │     [회색 = OK / 주황 = 한계]   │           │
│ │  └ wp1   │                                 │           │
│ ├ MoveL    │                                 │           │
│ │  └ wp2   │                                 │           │
│ └ Wait     │                                 │           │
├────────────┴─────────────────────────────────┴───────────┤
│ [Move tab][I/O tab][Log tab][Installation tab]            │ ← 탭 전환
└──────────────────────────────────────────────────────────┘
```

### Free-drive (Pose Capture) 흐름

UR이 cobot 시장 1위가 된 가장 결정적 UX:

1. 사용자가 펜던트 후면 **"Free-drive" 버튼** 누름 (dead-man switch).
2. 버튼 누르고 있는 동안에만 모터 토크 OFF + 중력 보상 ON.
3. 사용자가 로봇 팔을 잡고 원하는 자세로 끔.
4. 버튼 떼면 즉시 토크 ON + 그 자세 락.
5. 펜던트의 **"Add Waypoint"** 탭 → 현재 자세를 시퀀스에 저장.

핵심 알고리즘 (확인 필요 — UR 공개 매뉴얼 추정):
```
중력 보상: τ_motor = J^T(q) × M(q) × g
        + (사용자 외력에 의한 admittance term)
```

(출처: UR PolyScope X 사용자 매뉴얼 — https://www.universal-robots.com/articles/ur/polyscope/polyscope-5x/)

> ★ DarwinForge 적용:
> - **Dead-man 메타포** — DarwinForge에 "캡처 키 (Space) hold during pose capture" 추가. 키 떼면 자동 토크 ON. 산업 안전 표준 직접 수용.
> - **DARwIn-OP는 force-torque 없으나 토크 OFF 후 손으로 자세 잡기 가능** — `present_position` 폴링만 50 Hz로. 기존 모션 페이지 캡처 흐름이 이미 이걸 지원하니 UI에 "Free-drive" 라벨로 명확화.
> - **3D 뷰포트 관절 색상 = 안전 상태** — 우리 SwiftUI `RobotView3D`도 관절 한계 근접 시 주황 → 빨강 색상 변화 권장.

---

## 2) FANUC iPendant + ROBOGUIDE

### iPendant (현장 펜던트)

VGA 해상도 (640x480) 작은 화면 + 다수의 하드 키 + 다이얼. 세련된 UI보다 "20년 베테랑이 손에 익은" 패턴 우선.

```
┌─────────────────────────────────────┐
│ STATUS: AUTO  TP_ENABLE: ON         │
│ [PROGRAM]                            │
│                                      │
│  1: J P[1] 100% FINE                 │
│  2: L P[2] 250mm/s CNT100            │
│  3: WAIT 0.5sec                      │
│  4: J P[3] 100% FINE                 │
│                                      │
│ [POSN][I/O][SHIFT][PREV][NEXT]      │
└─────────────────────────────────────┘
```

### ROBOGUIDE (PC 시뮬)

3D 시뮬레이터 + TPP 디버거. TPP 프로그램을 시뮬에서 step 실행 → 실 로봇으로 그대로 download. **★ Cross-compilation 사상이 우리에게 직접 차용 가치** (Webots와 동일).

(출처: FANUC ROBOGUIDE — https://www.fanucamerica.com/products/robots/robot-simulation-software-roboguide ; iPendant 매뉴얼 — FANUC R-30iB Mate Plus Operator's Manual, 본 문서 회원 가입 필요. **확인 필요**: 공개 직링크 부재.)

> ★ DarwinForge 적용:
> - **시뮬-실기 교차 컴파일** — 이미 `01-simulation/webots.md`에서 Webots에 대해 동일 결론. iPendant + ROBOGUIDE의 사상이 cobot 표준.

---

## 3) ABB FlexPendant + RobotStudio

### FlexPendant

8.4" 터치 + 좌측 3-position 인에이블 스위치 + 6D 조이스틱 (작은 트랙볼).

ABB의 차별점은 **"QuickSet" 메뉴** — 화면 우측에 Speed / Increment / Coordinate System 토글이 항상 가시. 사용자가 "지금 어떤 좌표계에서 움직이는가" 즉답.

### RobotStudio (PC 시뮬)

Windows .NET 데스크탑 앱. Office Ribbon UI 전통적. RAPID 코드 에디터 + 3D 뷰포트 + Layout 디자이너 (셀 배치).

(출처: ABB RobotStudio — https://new.abb.com/products/robotics/robotstudio ; FlexPendant 매뉴얼 — https://library.abb.com/r?cid=9AAC100265 **확인 필요**: 공개 직링크)

> ★ DarwinForge 적용:
> - **QuickSet 메타포** — DarwinForge 우상단에 "현재 모드 / 현재 속도 / 현재 좌표계" 정보를 contextually 항상 표시. 토스 디자인 시스템의 "한 페이지 한 행위" 원칙과 충돌 없음.

---

## 4) KUKA smartPAD + KUKA.Sim

### smartPAD — 산업 표준 3-position enabling switch의 정석

```
┌──────────────────────────────────────┐
│              KUKA smartPAD            │
│                                       │
│   [E-Stop]      [Mode Selector]       │
│   (Mushroom)    T1 / T2 / AUT / EXT   │
│                                       │
│   ┌──────────────────────────┐       │
│   │                          │       │
│   │     10" Touch Display    │       │
│   │                          │       │
│   └──────────────────────────┘       │
│                                       │
│   [3-pos Enabling Switch — left]      │
│   [3-pos Enabling Switch — right]     │
│                                       │
│   [6D Mouse]                          │
└──────────────────────────────────────┘
```

**3-position enabling switch 동작:**
1. **놓음** → 모터 OFF (T1/T2 모드)
2. **중간 위치** → 모터 ON, 사용자 동의 활성
3. **꽉 누름** → 다시 OFF (panic grip 가정)

ISO 10218-1 §5.7.4 권장 — 사용자가 놀라서 손을 꽉 쥐어도 정지하도록 의도적 설계. 이 패턴이 **DarwinForge L4 HITL 메타포의 정수**.

### Mode Selector (T1 / T2 / AUT / EXT)

- **T1** Test Mode 1 = 250 mm/s 이하, 펜던트 인에이블 스위치 필수.
- **T2** Test Mode 2 = 풀 속도, 인에이블 필수.
- **AUT** Automatic = 풀 속도, 펜스 닫힘 필요.
- **EXT** External = 외부 PLC 제어.

(출처: KUKA smartPAD — https://www.kuka.com/en-de/products/robot-systems/software/system-software/kuka_smarthmi ; KUKA Sunrise.OS — https://www.kuka.com/en-de/products/robot-systems/software/application-and-base-technology-packages/kuka_sunriseos)

> ★ DarwinForge 적용 (★★★):
> - **Mode Selector 직접 차용** — DarwinForge 우상단에 "T1 시연 / T2 정상 / AUT 자동" 3단 모드 토글. 토스 한국어 UX는 "시연 / 정상 / 자동" 으로 번역.
> - **3-position enabling 키보드 매핑** — `⌘ + Shift` 동시 hold 시에만 Speed 100% 명령 디스패치. 이는 macOS 표준 modifier 조합이라 사용자 학습 부담 작음.

---

## 5) Doosan DART-Studio + DRL — ★ Skill Block 시각화

### DART-Studio 화면

Windows 데스크탑 IDE. Visual Studio Code 같은 패널 분할.

```
┌────────────────────────────────────────────────────────┐
│ File  Edit  Robot  Tools  View  Help                    │
├────────────┬────────────────────┬──────────────────────┤
│            │                    │                      │
│ Skill Tree │ 3D 뷰포트          │ Block Properties     │
│            │                    │                      │
│ ├ Move     │ [관절 시각화]      │ Velocity: 100 mm/s   │
│ ├ MoveJ    │                    │ Acceleration: 1000   │
│ ├ MoveL    │                    │ Tool: Default        │
│ ├ Pick     │                    │                      │
│ ├ Place    │                    │                      │
│ └ Wait     │                    │                      │
├────────────┴────────────────────┴──────────────────────┤
│ [DRL Code Editor — Python text]                         │
│   1: from doosan_drl import *                           │
│   2: movej([0, 0, 90, 0, 90, 0], v=30, a=60)           │
│   3: pick("part_A")                                     │
└────────────────────────────────────────────────────────┘
```

### Skill Block — 블록 코딩 + 텍스트 코드 동기화

DART-Studio의 가장 큰 차별점. 좌측 Skill Tree에서 블록을 드래그하면 자동으로 우하단 DRL Python 코드가 생성. 반대로 코드를 직접 수정하면 좌측 트리도 갱신 (양방향).

**산업 cobot 중에서 가장 LLM 친화적 패턴**. 자연어 명령 → LLM이 Skill Block JSON 출력 → DART-Studio 시각화 → 사용자 검토 후 실행.

(출처: Doosan DART-Studio — https://www.doosanrobotics.com/en/products/dart-suite ; DRL 매뉴얼 — https://manual.doosanrobotics.com/)

> ★ DarwinForge 적용 (★★★):
> - **Skill Block 시각화 = SwiftUI MotionTimeline 노드 표시** — 우리 `IntentDispatcher`가 Claude 의 tool_use 응답을 그대로 카드로 보여주는 대신, **Skill Block 시퀀스로 시각화** 하는 방향. 비전문가에게 더 직관적.
> - **양방향 동기화** = 사용자가 카드를 직접 편집하면 Claude의 다음 tool_use 입력에 반영. (현재 우리는 단방향 LLM → UI.)

---

## 6) Hand-guidance 알고리즘 (force-torque sensor + admittance control)

### 핵심 수식

KUKA / UR / Yaskawa 모두 비슷한 admittance control:

```
F_ext = M_d × ẍ_d + B_d × ẋ_d + K_d × x_d
                   (외력 측정)
            ↓
ẍ_d = M_d^{-1} × (F_ext - B_d × ẋ_d - K_d × x_d)
                   (가상 댐퍼·스프링 모델로 다음 가속도 계산)
            ↓
J^T × τ = M(q) × q̈ + C(q, q̇)
                   (관절 토크 계산)
```

- **M_d** = 가상 질량 (사용자가 느끼는 무게)
- **B_d** = 가상 댐퍼 (느린 움직임 유도)
- **K_d** = 가상 스프링 (보통 0 — 자유 이동)

KUKA LBR iiwa는 7축 모두 토크 센서 내장이라 직접 측정. UR은 베이스 force-torque 센서 + 모터 전류 추정.

(학술: Villani and De Schutter [Villani 2008] "Force Control", *Springer Handbook of Robotics*, https://doi.org/10.1007/978-3-540-30301-5_8 ; Albu-Schäffer et al. [AlbuSchaffer 2007] "The DLR lightweight robot — design and control concepts for robots in human environments", *Industrial Robot*, https://doi.org/10.1108/01439910710749653)

> ★ DarwinForge 적용:
> - **DARwIn-OP는 토크 센서 없음** — Dynamixel `present_load` (signed 11-bit, MX-28) 가 모터 전류 추정값. 노이즈 큼 (±10% 부하 분산). EWMA (지수 가중 이동 평균, α=0.3) 적용 후 외력 추정.
> - **단순 임피던스** — `K_d = 0` (스프링 없음), `B_d = 작음`, `M_d = 가상 질량 = 가벼움` 으로 사용자가 자유로이 끌 수 있게.
> - **확인 필요**: DARwIn-OP의 MX-28 `present_load` 노이즈 측정 학술 논문 — 우리가 직접 실측 필요.

---

## 7) Sequence Builder — 블록 코딩 vs 자연어

| 패턴 | 대표 | 장점 | 단점 |
|------|------|------|------|
| **블록 코딩** | Doosan DART, ABB Wizard, FANUC TP | 시각적, 비전문가 친화 | 복잡 시퀀스 표현력 한계 |
| **텍스트 코드** | URScript, KAREL, RAPID, DRL | 표현력 높음 | 학습 곡선 |
| **자연어** | DarwinForge ★ | 학습 곡선 0 | LLM 실수 가능 → 검증 필수 |

**우리 채택 = 자연어 + 검증 카드.** 산업 cobot은 자연어 채택이 아직 시기상조 (안전 인증 부담). DarwinForge는 데스크탑 휴머노이드라 인증 부담 작아 자연어 시도 가능.

(출처: Liang et al. [Liang 2023] "Code as Policies: Language Model Programs for Embodied Control", *IEEE ICRA*. https://doi.org/10.1109/ICRA48891.2023.10160591 ; Singh et al. [Singh 2023] "ProgPrompt: Generating Situated Robot Task Plans using Large Language Models", *IEEE ICRA*. https://doi.org/10.1109/ICRA48891.2023.10160591)

> ★ DarwinForge 적용:
> - **자연어 + Skill Block 하이브리드** — Claude의 tool_use 출력을 Skill Block 시퀀스로 시각화 후 사용자가 블록 단위로 편집 가능. 자연어의 학습 곡선 0 + 블록의 검증성을 결합.

---

## 8) 공통 UX 원칙 추출 (6대 cobot)

위 비교에서 공통적으로 발견되는 **산업 안전 UI 5원칙**:

1. **항상 가시** — E-Stop, Mode (Manual/Auto), Speed override 는 화면 어디서나 보이는 영역에 고정.
2. **3단계 활성화** — 의도적 입력 (인에이블 스위치 / Free-drive 버튼 / dead-man) 으로만 이동 가능.
3. **상태 컬러 코딩** — 관절·도구가 안전 상태에 따라 회색 / 주황 / 빨강.
4. **사후 로그 자동** — 모든 비상 정지 사건은 컨트롤러 측 black box 자동 저장.
5. **모드 명시** — 사용자가 "지금 어떤 모드?" 한 번 보면 즉답.

> ★ DarwinForge 5원칙 매핑:
> 1. ✅ E-Stop 좌상단 항상 (이미 채택). Mode/Battery 추가.
> 2. ⏳ ⌘+Shift dead-man (도입 예정).
> 3. ✅ KS 빨강 #FF3B30 (이미 채택). 관절 한계 시 주황 추가.
> 4. ⏳ L6 사후 분석 (도입 예정).
> 5. ⏳ "T1/T2/AUT" 모드 토글 (도입 예정).

---

## 학술 인용

- [AlbuSchaffer 2007] Albu-Schäffer et al. "The DLR lightweight robot — design and control concepts for robots in human environments", *Industrial Robot*. https://doi.org/10.1108/01439910710749653
- [Villani 2008] Villani and De Schutter "Force Control", *Springer Handbook of Robotics*.
- [Liang 2023] Liang et al. "Code as Policies", *IEEE ICRA*. https://doi.org/10.1109/ICRA48891.2023.10160591
- [Singh 2023] Singh et al. "ProgPrompt", *IEEE ICRA*.
- [Lasota 2017] Lasota et al. "A Survey of Methods for Safe Human-Robot Interaction", *Foundations and Trends in Robotics*. https://doi.org/10.1561/2300000052

## 출처 종합

- Universal Robots PolyScope X — https://www.universal-robots.com/articles/ur/polyscope/polyscope-5x/
- FANUC ROBOGUIDE — https://www.fanucamerica.com/products/robots/robot-simulation-software-roboguide
- ABB RobotStudio — https://new.abb.com/products/robotics/robotstudio
- KUKA smartPAD — https://www.kuka.com/en-de/products/robot-systems/software/system-software/kuka_smarthmi
- KUKA.Sim — https://www.kuka.com/en-de/products/robot-systems/software/simulation
- Doosan DART-Studio — https://www.doosanrobotics.com/en/products/dart-suite
- Mitsubishi RT ToolBox3 — https://www.mitsubishielectric.com/fa/products/rbt/robot/pmerit/rttoolbox/
