# Robot Tools Overview — DarwinForge 차용 후보 일괄 검토

> 작성일: 2026-05-10
> 대상: ROBOTIS 공식 도구 (3~5번)와 산업·시뮬레이션 도구 (6~12번)
> 본 문서는 DarwinForge UI/UX 결정에 영향을 주는 인접 도구를 200~300단어 단위로 정리하고, 마지막에 비교표를 둔다.

---

## 3. ROBOTIS RoboPlus Action / Task

DARwIn-OP/OP2의 공식 1세대 모션 저작 도구 묶음. **RoboPlus Motion**(현 RoboPlus Action)이 모션, **RoboPlus Task**가 행동 로직을 담당한다. Windows 전용 (Wine으로 macOS 부분 동작 확인 필요). 현재 DarwinForge가 다루는 `.mtn` / `.tsk` 파일이 정확히 이 도구의 출력 포맷이라 **호환성 1순위**.

핵심 메타포는 **Page → Step → Pose**. 한 Page는 “인사하기” 같은 시나리오, 그 안에 여러 Step (시간 순), 각 Step은 16개 모터 목표각 + 시간(ms) + Pause(ms) + Speed. 자세한 내부 표현은 7-bit ASCII 텍스트로 모터별 한 줄, page header에 다음 page index (continue) / exit page index 가 포함되어 “Page 그래프”를 형성한다. 한 Page는 최대 7 step + 추가 “exit” step 1 — 즉, 단일 page 내 시퀀스가 짧고 page 간 jump로 긴 행동을 조립하는 디자인이다.

화면 상단에 16관절 슬라이더(0..1023, 직접 펄스 단위), 우측에 OP 3D 미리보기, 하단에 Step 시퀀스 strip. 각 모터에 “Compliance Slope” 4단계 슬라이더(8 / 16 / 32 / 64)가 있어 부드러움 / 강성 조절 — 이는 MX-28의 P-gain만 표현하는 게 아니라 CW/CCW slope 둘 다 노출한다는 점에서 모터 학습 효과가 큼 (출처: https://emanual.robotis.com/docs/en/software/rplus1/motion/).

**Task** 쪽은 if/else/while/load motion/play motion 같은 블록 기반 절차형 언어. ROBOTIS 자체 “R+ Task script” (.tsk 텍스트). DarwinForge에서 .tsk 파서를 지원하면 사용자 기존 자산을 그대로 가져올 수 있다. .tsk는 들여쓰기 기반 if/while + 함수(SUB) 정의 + 모션 페이지 호출(MOTION_PAGE_INDEX = N) + 직접 컨트롤 테이블 read/write (예: `Sensor Value[1]`)을 지원하는 사실상 BASIC급 절차 언어. 사용자가 학습 도구로 사용하기에 진입 장벽이 낮음.

> ★ 차용: `.mtn` 16-pose × N-step 모델을 우리 1차 데이터 모델로 유지하되, 페이지 그래프 (next / exit page)를 §1 문서의 Behavior Box로 그래프화. Compliance slope를 모션 키프레임의 “interp 보강 파라미터”로 노출. SwiftUI에서 `MotionPageGraphView`를 만들고 각 page를 카드로, next/exit를 화살표로 표시하면 RoboPlus 사용자가 즉시 친숙.

(출처: https://emanual.robotis.com/docs/en/platform/op2/motion_software/, https://emanual.robotis.com/docs/en/software/rplus1/motion/)

---

## 4. ROBOTIS R+ Motion (모바일 / 웹 후속)

ROBOTIS가 RoboPlus 1.x 라인을 정리하면서 2020년대 들어 R+ Motion / R+ Task / R+ Manager 시리즈를 모바일 위주로 출시. iOS / Android (Bluetooth BT-410 기준), 그리고 일부 웹 버전. DARwIn-OP/OP2 직접 지원은 부분적 — 주 타겟은 ROBOTIS DREAM, BIOLOID, MINI, OpenCM. (출처: https://www.robotis.com/service/download.php?ca_id=70)

UI는 1세대보다 단순화 — 모바일이라 Step strip이 횡스크롤 카드, 모터 슬라이더는 “bone” 단위로 묶임 (예: 왼팔 = shoulder + elbow 한 화면). Compliance / Speed는 expert 모드에서만 노출. 라이브러리는 ROBOTIS 클라우드에서 동기화되며, JSON 직렬화 형태이지만 명세는 비공개 — “확인 필요”.

DarwinForge 차용 가치는 낮음 (포맷 비공개, OP 호환 약함). 다만 **모바일 슬라이더 “bone grouping”** UX는 데스크톱에서도 유효하다 — 16관절을 다 노출하지 않고 “좌상지 / 우상지 / 좌하지 / 우하지 / 머리” 5 그룹 토글이 가능하면 초보자 진입 장벽이 낮아진다.

> ★ 차용: SwiftUI `JointControlView`에 `BoneGroup` enum + `Picker`를 추가해 “전체 / 그룹별” 노출 모드 토글.

추가로 R+ Manager는 **Wizard 형 onboarding** — 첫 연결 시 “모터 ID가 충돌합니까?” / “펌웨어 버전이 일치합니까?” 같은 단계별 점검을 자동 진행한다. DarwinForge 첫 실행 시 같은 wizard를 채용하면 “USB 잡혔는데 응답 없음” 류 사용자 좌절을 크게 줄일 수 있다.

---

## 5. ROBOTIS Dynamixel Wizard 2.0

모터 진단 / 펌웨어 업데이트 / EEPROM 편집 전용 도구. macOS 네이티브 빌드 존재. DarwinForge가 사용자 모터 깨짐 진단을 제공하려면 이 도구의 UX를 **모듈로 흡수**할 가치가 있다.

화면 좌측에 Dynamixel ID 트리 (검색된 모터 ID 1..253), 우측에 선택 모터의 Control Table (130+ 항목)을 “property grid” 형태로 모두 노출. 항목별 read/write 가능 여부에 따라 색상 구분, 단위가 자동 변환됨 (raw 0..1023 ↔ degree, raw 0..1023 ↔ rpm 등).

Firmware Recovery는 “Bootloader 진입 → fblk 전송 → CRC 확인” 시퀀스를 progress bar로 시각화. 사용자가 모터 ID 충돌(다중 모터가 같은 ID로 응답) 발견 시 자동으로 ID reassignment GUI로 안내한다 (출처: https://emanual.robotis.com/docs/en/software/dynamixel/dynamixel_wizard2/).

> ★ 차용: DarwinForge `BoardStatusView` + `ConnectionView`를 합쳐 “Diagnostics” 탭에 Control Table grid를 노출. CM-740 BulkRead로 일부 항목만 (Goal Position, Present Position, Present Voltage, Present Temperature, Moving) 폴링하고, 사용자 더블클릭 시 모터 한 개 풀 control table을 inspect.

특히 **Status Packet error byte 시각화**는 우리도 차용 가치가 큼. Dynamixel 1.0 프로토콜의 status error는 6 bit (Voltage / Angle Limit / Overheat / Range / Checksum / Overload)인데, Wizard는 이를 6개 lamp로 노출 → 전압 부족인지 과열인지 즉시 판단 가능. 우리 `BoardStatusView`에 `MotorErrorLamps` 컴포넌트를 추가하면 동일 효과.

---

## 6. Visual Components (산업)

Finland 회사. 산업 로봇(KUKA, Fanuc, ABB, UR) 시각 시뮬레이션 + offline programming. **3D viewport 우선**, timeline은 부차. 휴머노이드는 주력 아니지만 “digital twin” 패턴 참조.

특히 **Component Catalog**가 주목할 만하다 — 좌측 카탈로그에서 부품을 드래그하면 작업 셀에 즉시 배치되고, “Connect” 모드에서 컨베이어 끝과 픽업 포인트를 잇는다. 신호(Boolean / Integer)가 컴포넌트 간 메시지로 흐른다. (출처: https://www.visualcomponents.com/products/visual-components/)

“Process Modelling” 모듈은 작업 흐름을 “Statement” 노드 시퀀스 (`Need`, `Transport`, `Process`, `Feed`)로 표현 — 일반 노드 그래프가 아니라 **시간순 statement list**. 이는 우리 .mtn step strip과 정확히 같은 추상화이며 “산업 자동화에서도 step 시퀀스가 1차 메타포”라는 시사점을 준다.

가격이 매우 비싸 (수만 USD/seat) 일반 사용자 차용 가능성은 낮으나 **Component graph + Signal wire** 패턴은 NAO Choregraphe Behavior Box와 동일 정신.

> ★ 차용: 우리 Strategy FSM 그래프에 “Signal wire = bool / int 메시지” 개념 명시적 도입. 단순 transition 화살표보다 풍부. SwiftUI에서 wire의 hover tooltip으로 “현재 값” live preview를 표시하면 디버깅 가치 매우 큼.

---

## 7. RoboDK

크로스 플랫폼 (Windows / macOS / Linux), 멀티 브랜드 로봇 offline programming. Python API 강력, GUI는 산업 표준 (트리 좌측 + 3D 뷰포트 + 하단 콘솔). 무료 티어 + 상용 라이선스 (출처: https://robodk.com/).

가치는 “RoboDK Add-In” 패턴 — Python으로 사용자가 GUI 패널을 추가할 수 있다 (PySide). DarwinForge는 macOS 네이티브 SwiftUI라 직접 차용 불가지만 “플러그인 = 사용자 정의 박스”를 NAO Choregraphe + RoboDK 모두 지원한다는 점이 메시지다 — **장기적으로 우리도 박스 외부 정의가 필요**.

좌측 트리: World → Cell → Robot → Reference → Target → Program. 이 위계는 우리 `.forge` 프로젝트 트리에 적용 가능. 단 우리 단일 로봇이라 World/Cell은 생략, Reference (origin frame) 정도만 의미.

> ★ 차용: 프로젝트 사이드바에 “Targets” 섹션. Target = (joint angles, label) 또는 (Cartesian xyz/rpy + IK solver). 자주 쓰는 자세를 named target으로 저장하면 모션 키프레임이 self-documenting.

---

## 8. CoppeliaSim (V-REP)

Czech 기반 (현 Coppelia Robotics). 휴머노이드 / 모바일 / 산업 모두 지원. **Embedded scripting** (Lua) + ZeroMQ remote API + ROS bridge. 무료 educational 라이선스. (출처: https://www.coppeliarobotics.com/)

UI 특이점:

- 좌측 Scene Hierarchy (Blender 흐름과 유사).
- 우측 “Properties” 항목은 카테고리 탭 (Common / Position / Orientation / Object special / ...).
- 하단 Status Bar에 “Simulation time / Step size / Real-time factor”.
- **Custom UI (CUI)**: Lua로 사용자가 simulation 재생 중 떠 있는 패널을 만들 수 있다. 실험 파라미터 슬라이더를 사용자가 즉석 추가.

DARwIn-OP 모델이 CoppeliaSim 기본 라이브러리에 포함되어 있어 DarwinForge가 “Export to CoppeliaSim” 버튼을 가지면 원격 실행 가능 — 단 “확인 필요”, 모델 버전이 OP1만이면 OP2 fbx 차이 발생.

> ★ 차용: 사용자 정의 CUI = Custom slider panel. 우리도 “Live Tweak” 패널: 모션 재생 중 step_height, sway_amp 등을 실시간 조정. Combine `@Published`로 단순 구현 가능.

CoppeliaSim의 또 다른 학습 가치는 **Threaded vs Non-threaded script** 분리 노출이다. 노드별 “threaded” 토글이 GUI에 명시적으로 있어 사용자가 “블로킹 작업이면 threaded”를 선택하게 한다. 우리도 박스의 “async/await” 여부를 GUI에 표시하면 디버깅이 쉽다.

---

## 9. NVIDIA Isaac Lab (Sim-to-Real)

GPU 가속 다체계 시뮬레이션 + 강화학습 워크플로우. Omniverse / USD 위에 구축. 휴머노이드 워킹/매니퓰레이션 RL 학습 → 실 로봇 정책 배포. (출처: https://developer.nvidia.com/isaac/lab)

UI는 사실상 **Omniverse Composer** 호스트. Layer 기반 USD scene, “Sequence Editor”와 “Action Graph”가 별도 창. Action Graph는 Omniverse Kit의 OmniGraph로 노드 기반.

DarwinForge 직접 차용은 어렵지만 — 휴머노이드 RL이 점점 표준화되는 흐름에서 **policy = behavior box** 라는 비유가 통한다. 즉, 우리 Behavior Box 노드 중 하나가 “RL 정책 .pt 파일을 실행하는 박스”가 될 수 있다. 향후 LLM + 학습 정책 둘 다 동일 박스 추상화 위에 통합 가능.

> ★ 차용: 박스 타입에 `.script(Python)`, `.timeline(Animation)`, `.fsm(SubGraph)` 외 `.policy(MLModel)`을 추가. CoreML / ONNX 둘 다 받게.

---

## 10. Apptronik Apollo IDE

Apptronik (텍사스 오스틴) 휴머노이드 Apollo. 자체 “Apollo IDE” / Behavior Authoring tool 존재 — 하지만 공식 문서가 거의 비공개. 외부에 공개된 정보는 “task graph + skill library + LLM 자연어 입력” 정도. 화면 캡처는 Mercedes-Benz / GXO 산업 데모 영상에서 단편적으로 보이는 정도.

“확인 필요” — 본 문서는 공개 자료가 부족하여 추측 영역. 다만 **자연어 → task graph 자동 생성**은 우리 `Conversation` 영역이 이미 일부 다루는 패턴. Claude로 “문 두드리고 인사해” → behavior box 자동 배치 → 사용자가 수정 → 실행, 같은 흐름이 차세대 표준이 될 가능성.

> ★ 차용: `Conversation` 탭에서 “Generate Behavior Graph” 명령. Claude가 출력한 JSON을 Strategy 그래프로 import. 검증은 사용자에게.

---

## 11. V-Sido OS (일본)

吉崎航 (Kō Yoshizaki) 개발, 휴머노이드 미들웨어. KUMOTEK / 유명한 “쿠라타스” 거대로봇에서 사용. C++ 코어 + GUI는 단순. 주요 가치는 **realtime motion blending** — 여러 모션이 동시에 입력되어도 weight 기반으로 합성.

(출처: https://www.asratec.co.jp/v-sido-edu/, 영어 자료는 IEEE 논문 “V-Sido: Servo Network Middleware…” 2014)

화면은 좌측 모션 명령 큐, 우측 3D 미리보기, 하단 servo state grid. 사용자는 “모션 1 = 손 흔들기, 모션 2 = 보행”을 동시에 큐잉하면 V-Sido가 실시간 blending. 우리 Choregraphe Layer 모델과 본질적으로 같다.

> ★ 차용: motion blending = layer alpha-blend. SwiftUI에서 layer slider (0..1)을 도입하고 forge-core에 weighted joint sum 함수 추가.

---

## 12. Choreonoid (AIST)

일본 산업기술종합연구소 오픈 소스. C++/Qt. 휴머노이드 (HRP, JAXON 등) 시뮬레이션 + 모션 편집. (출처: https://choreonoid.org/en/)

UI 특징:

- 좌측 Item Tree (씬 그래프 + 모션 데이터 + body 모델).
- 중앙 3D viewer.
- “Pose Roll Edit View”가 핵심 — 시간축에 키프레임을 “롤”로 표현, 일본식 도프 시트 변형.
- ZMP, CoM, 지지 다각형 시각화.

라이선스 LGPL-3.0. C++ 코드를 우리가 직접 link 하긴 어렵지만 **CnoidBody (.body) 모델 포맷**은 DARwIn-OP 모델 포함 가능성 — 검증 필요.

> ★ 차용: ZMP / CoM 시각화 패턴. 3D viewer에 “Stability View” 토글로 지지 다각형(2족 standing polygon) + CoM 점 + ZMP 점 동시 표시. SceneKit `SCNNode`로 단순 구현.

또한 Choreonoid의 **Pose Roll**은 “고정 시간 grid가 아닌 자유 시간 위에 키프레임을 둔 후 사용자가 수동으로 정렬”이라는 점에서 NAO의 frame 그리드와 차이가 있다. 자유 시간 모델은 모션 캡처 후 후처리에 유리하고, frame 그리드는 정밀 동기화에 유리하다. DarwinForge는 두 모드 토글이 합리적 — `enum TimeMode { case grid(fps: Int); case free }`.

---

## 비교표

| # | 도구 | 라이선스 | 플랫폼 | 모션 저장 단위 | 파일 포맷 | DarwinForge 호환 |
|---|------|---------|--------|----------------|-----------|------------------|
| 1 | NAO Choregraphe | proprietary, 무료 SDK | Win/Mac/Linux | Animation Box (timeline) + Behavior Box | `.crg` (zip), `.xar`, `.bxl` | 패턴 차용 (1순위) |
| 2 | Spot Choreographer | proprietary, SDK 무료 | Win/Mac/Linux | Move Instance × Track | `.csq` (proto text) | BPM 패턴 차용 |
| 3 | RoboPlus Action/Task | freeware | Windows | Page → Step → Pose | `.mtn`, `.tsk` (ASCII) | 직접 호환 (이미 지원) |
| 4 | R+ Motion | freeware | iOS/Android/Web | (비공개) | (비공개 JSON) | 미정 (확인 필요) |
| 5 | Dynamixel Wizard 2.0 | freeware | Win/Mac/Linux | N/A (모터 진단) | N/A | 모듈로 흡수 |
| 6 | Visual Components | $$$ commercial | Windows | Robot Program | `.vcmx` (proprietary) | 패턴만 |
| 7 | RoboDK | freemium | Win/Mac/Linux | Program (Python or RDK Tag) | `.rdk`, Python | 플러그인 패턴 |
| 8 | CoppeliaSim | edu free / commercial | Win/Mac/Linux | Lua threaded script | `.ttt`, `.ttm` | 모델 호환 (확인 필요) |
| 9 | Isaac Lab | NVIDIA EULA, free | Linux + RTX GPU | USD scene + RL policy | `.usd`, `.usdc` | 정책 박스 |
|10 | Apptronik Apollo IDE | proprietary, 비공개 | (확인 필요) | task graph | (확인 필요) | LLM 패턴만 |
|11 | V-Sido OS | proprietary | (Linux/Win) | motion blend command | (비공개) | blending 차용 |
|12 | Choreonoid | LGPL-3.0 | Linux/Win/Mac | Pose-Roll keyframe | `.cnoid`, `.body`, `.yaml` | 모델 호환 가능 |

---

## 결론 — DarwinForge 단계별 흡수 전략

1. **즉시**: `.mtn` / `.tsk` 호환 강화 (#3) — 이미 코덱 존재, UI만 보강.
2. **단기 (1분기)**: Dynamixel Wizard 2.0 패턴(#5) Diagnostics 탭 흡수.
3. **중기 (2분기)**: NAO Choregraphe Behavior Box 그래프 (#1).
4. **중기 (2분기)**: Spot BPM sync (#2) — `WalkSimView` 확장.
5. **장기**: Isaac Lab 정책 박스 (#9), Choreonoid ZMP 시각화 (#12).
6. **선택**: V-Sido motion blending (#11) 레이어 alpha.

특히 (#1, #2, #5)가 사용자 가치 대비 구현 비용이 낮아 ROI 우수. (#9, #10)은 미래형, 학습 정책 / LLM 통합 시점에 재평가.

---

## 부록 A — 하드웨어 호환성 행렬

DarwinForge의 1차 타겟은 OP/OP2지만, 본 문서에서 다룬 도구의 호환 범위가 향후 결정에 영향을 준다.

| 도구 | DARwIn-OP | DARwIn-OP2 | OpenCM | OP3 (CM-740 후속) | NAO | Spot |
|------|-----------|------------|--------|------------------|-----|------|
| RoboPlus Action | O (1.x) | O (1.x) | △ (R+ Motion 2 권장) | △ | X | X |
| R+ Motion (모바일) | △ | △ | O | △ | X | X |
| Dynamixel Wizard 2.0 | O (직접 모터 액세스) | O | O | O | X | X |
| NAO Choregraphe | X | X | X | X | O | X |
| Spot Choreographer | X | X | X | X | X | O |
| CoppeliaSim | △ (모델만) | △ | X | △ | △ | △ |
| Choreonoid | △ (모델만) | △ | X | △ | △ | X |

“△”는 “모델만 호환 / 시뮬만 호환 / 부분 호환”을 의미. DARwIn-OP/OP2 직접 호환은 RoboPlus + Dynamixel Wizard 2.0 두 도구에 국한된다. 그래서 우리 SwiftUI 앱이 macOS에서 두 도구 기능을 통합하면 사실상 “OP 사용자 유일한 macOS 네이티브 옵션”이 된다.

## 부록 B — 모션 단위 변환 표

도구 간 모션을 옮길 때 가장 자주 부딪히는 단위 차이.

| 항목 | RoboPlus | NAO Choregraphe | Spot Choreographer | DarwinForge 권장 |
|------|----------|------------------|--------------------|-----------------|
| 시간 | ms (절대) | frame (25 fps default) | slice (1/4 beat) | dual: ms + slice |
| 각도 | 0..1023 (raw) | rad | rad | rad (내부) + raw (FFI) |
| 속도 | 0..1023 (raw) | rad/s | (자동) | rad/s |
| 보간 | linear (속도 ramp) | bezier / smooth | curve from move type | bezier |
| 모터 식별 | ID 1..20 | JointName string | leg/arm tag | JointID enum |

이 표를 import/export 코덱에 명시적으로 두는 것이 사용자 디버깅 가치 높음.

---

(전체 출처는 각 단락 끝의 URL과: https://www.robotis.com, https://www.bostondynamics.com, http://doc.aldebaran.com, https://emanual.robotis.com 도메인 위주.)
