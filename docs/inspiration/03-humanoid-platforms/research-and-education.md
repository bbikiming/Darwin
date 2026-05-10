# 03-A — 연구 · 교육용 휴머노이드

DarwinForge가 운용하는 ROBOTIS DARwIn-OP / OP2 와 가장 직접 비교 가능한 카테고리. 하드웨어 규모, 가격대, 학교/연구실 워크플로우가 모두 인접하므로, **모션 저작 UI/UX 패턴이 DarwinForge 에 그대로 이식될 가능성**이 가장 높다.

---

## 1. Aldebaran NAO (★ 최우선 참고)

### 회사 · 연구소
Aldebaran Robotics (프랑스, 2005 창립) → SoftBank Robotics 인수 (2012) → United Robotics Group / RobotLAB 으로 분기 (2022~2024). 현재 NAO6 가 주력.

### 출시 · 발표 시점
- NAO 1.x (Académics 버전) — 2008 출시
- NAO V5 — 2014
- NAO6 (현행) — 2018 출시, 2024 SW 갱신 지속

### 하드웨어 규격
- 25 DOF (머리 2, 어깨/팔/손 각 5+1, 골반/다리 5+1, 손 1+1 — 모델별 미세 차이)
- 무게 5.4–5.6 kg, 키 57.4 cm
- 액추에이터: Maxon DC + 자체 기어박스. 위치 + 토크 피드백.
- 센서: 4×마이크, 2×HD 카메라, 9-axis IMU, 정전식 head sensor, sonar, FSR (발바닥 4점), 관절 각도 + 전류
- 메인 CPU: Intel Atom E3845 (NAO6) — 온보드 Linux

### 핵심 SDK / 미들웨어 / API
- **NAOqi 2.x / 2.8.x** — 자체 미들웨어. C++ + Python + JavaScript 바인딩. naoqi-services 형태로 ALMotion, ALTextToSpeech, ALMemory, ALAutonomousLife 모듈 제공.
- qiBullet — Bullet 기반 시뮬레이터 (오픈소스 보조)
- ROS bridge (naoqi_driver) — ROS1 / ROS2 부분 지원
- Choregraphe Suite (저작 도구, GUI)

### 모션 저작 도구의 UI/UX 패턴 (★ Choregraphe — 매우 상세)
NAO 와 Pepper 가 공유하는 통합 IDE. 휴머노이드 모션 저작 UX 의 gold standard.

1. **Flow Diagram (박스 기반 행동 그래프)**
   - 중앙 캔버스에 **Box** 노드를 드래그-드롭. 박스 = 하나의 행동 단위.
   - 각 박스는 **onStart / onStop / onLoad / onUnload** 이벤트 입력 단자와 **onStopped / 사용자 정의 출력** 단자를 가진다.
   - 박스끼리 출력 → 입력 단자를 케이블로 연결해 시퀀스 / 분기 / 병렬을 만든다.
   - 박스는 **Python 스크립트 박스**, **Timeline 박스**, **Diagram 박스 (중첩)**, **Behavior 박스**, **Dialog 박스** 의 5종.
2. **Timeline 박스 (키프레임 모션 편집기)**
   - 가로축 = 프레임 (FPS 25 기본), 세로축 = 관절 그룹.
   - 관절을 그룹별 (Head / LArm / LLeg / RArm / RLeg / Body) 트랙에 펼쳐 보여주고, **각 프레임에서 현재 NAO 자세를 캡처 → 키프레임 저장**.
   - 키프레임 사이는 자동 보간 (Linear / Bezier / Constant). 박스 우상단 곡선 편집기에서 보간 곡선을 직접 드래그.
   - **Stiffness 트랙**, **Behavior Layer 트랙** (Timeline 위에 추가 박스 뿌려 행동을 동기 호출) 가 별도 레이어로 존재.
3. **Behavior Box / Dialog Box**
   - Behavior Box = Flow Diagram 의 재귀 (박스 안에 또 다른 박스 그래프).
   - Dialog Box = QiChat 스크립트 (대화 트리 + 슬롯). `u:(hello) Hi there!` 같은 룰 기반 대화.
4. **Robot View (3D + Pose Library)**
   - 우측 패널에 NAO 3D 모델. 관절을 직접 드래그하면 실시간으로 실기에 반영 (또는 시뮬). **"Hold pose"** 버튼으로 현재 자세를 키프레임으로 저장.
   - **Pose Library** 패널에서 자주 쓰는 자세 (Stand, Sit, Crouch) 를 카드로 즐겨찾기.
5. **Memory / Variable Inspector**
   - ALMemory 변수 (예: `BatteryChargeChanged`) 를 박스의 입력으로 끌어다 연결 → 이벤트 기반 행동.
6. **Compile & Send**
   - 좌상단 ▶ 버튼으로 즉시 실기 전송. 박스 그래프 전체가 `.crg` (XML) 패키지로 저장.

### LLM / AI 통합 여부
- 공식: NAOqi 2.8 LLM Bridge (실험적, 2024 발표). Aldebaran 측은 OpenAI / Anthropic API 와 직접 연결 가능한 connector 를 데모.
- 비공식: Pepper-LLM (Cornell, 2023), NaoGPT 등 다수 학계 프로젝트.

### 라이선스 / 오픈소스
- NAOqi: 클로즈드. 라이선스 + 시리얼 묶임.
- Choregraphe: 무료 다운로드, 단 NAO 본체와 페어링되어야 동작.
- naoqi-libqi (저수준 통신 라이브러리): BSD 일부 공개.

### DarwinForge 차용 포인트
1. **Flow Diagram 박스 그래프** → DarwinForge `StrategyView` 또는 신설 `BehaviorGraphView` 에 직접 차용. SwiftUI 의 `Canvas` + `gestures` 로 구현 가능.
2. **Timeline 박스 키프레임 캡처** → `MotionLibraryView` 의 모션 편집 모달로. "현재 실기 자세 캡처 → 키프레임" 버튼은 우리 Bus 의 `PresentPosition` 응답을 그대로 묶으면 1주일 내 가능.
3. **Pose Library 즐겨찾기** → DarwinForge 의 `MotionGalleryGridView` 가 이미 비슷한 레이아웃이지만, "현재 자세를 새 카드로 저장" 가속 키 (`⌘+S`) 가 빠져 있음.

### 출처 URL
- https://www.aldebaran.com/en/nao
- http://doc.aldebaran.com/2-8/software/choregraphe/index.html
- http://doc.aldebaran.com/2-8/naoqi/index.html
- https://github.com/aldebaran/libqi
- https://emir-munoz.github.io/uploads/papers/2018-NAOqi-overview.pdf

---

## 2. Aldebaran / SoftBank Pepper

### 회사 · 출시
Aldebaran + SoftBank Robotics. 2014년 일본 발표, 2015 일반 판매 시작. 2021년 양산 중단 → 2024 RaaS 형태로 부분 부활 (United Robotics).

### 하드웨어 규격
- 20 DOF (다리 없음, 기단 휠 베이스 + 상체 17 + 머리 2 + 손 1)
- 키 120 cm, 무게 28 kg
- 가슴에 10.1" 태블릿 (Android), 3D 카메라 (Asus Xtion 기반), 4×마이크, 다수 sonar / laser / bumper.
- 액추에이터: NAO 와 동급 Maxon + 일부 BLDC.

### SDK / 미들웨어
- NAO 와 동일한 NAOqi (서비스 모듈 일부 다름 — ALTabletService 추가).
- Choregraphe 동일 (Pepper 모드).

### 모션 저작 UI/UX
- Choregraphe (NAO 항목 참조) — Pepper 의 다리 없는 운동학을 위해 Timeline 박스에서 골반/다리 트랙 대신 **Hip Pitch / Knee Pitch / Wheel velocity** 트랙이 노출.
- Pepper 전용으로는 **Tablet Editor** (HTML/CSS 페이지를 시각적으로 편집해 가슴 태블릿 UI 만들기) 가 추가 — 이는 우리 conversational UI 와 직결되는 설계.

### LLM 통합
- 같은 NAOqi LLM Bridge. Pepper-LLM 데모 (CES 2024) 에서 ChatGPT-3.5 연결.

### 라이선스
NAO와 동일 (클로즈드 + 무료 IDE).

### DarwinForge 차용 포인트
- **Tablet Editor** = 로봇 화면용 conversational UI 를 별도 IDE 로 분리한다는 발상. DarwinForge 가 macOS 앱과 별개로 "DARwIn 위에 띄울 미니 UI" 를 만든다면 직접 모방 가능.

### 출처
- https://www.aldebaran.com/en/pepper
- http://doc.aldebaran.com/2-5/family/pepper_technical/index_pep.html

---

## 3. iCub (IIT Genova)

### 연구소
Istituto Italiano di Tecnologia (IIT), 제노바. 2004 EU RobotCub 컨소시엄 시작.

### 출시 시점
- iCub 1 — 2008
- iCub 2 — 2014
- iCub 3 — 2022 (텔레오퍼레이션 + 향상된 손)

### 하드웨어
- 53 DOF (iCub 3): 머리 6, 양팔 16 (손 9 포함), 양다리 12, 허리 3, 손가락 추가
- 키 100 cm, 무게 33 kg
- BLDC + 하모닉 드라이브, full-body force/torque (양 어깨, 양 다리, 양 발목), 양안 카메라, 4-mic, 분산 임베디드 컨트롤러 (ETHernet/CAN)

### SDK / 미들웨어
- **YARP (Yet Another Robot Platform)** — 자체 미들웨어. 포트 기반 메시지 (publish/subscribe) + RPC. C++/Python/Java 바인딩.
- iCub-main (자체 모듈군), Gazebo plugin, Mujoco-iCub
- ROS bridge 가능 (yarp-ros)

### 모션 저작 UI/UX
- **YarpManager + yarpmotorgui** — 관절 슬라이더 GUI. 키프레임 기반은 약함.
- Cartesian Solver + iKin 라이브러리로 IK 풀이. 저작은 **코드 중심** (Python/C++).
- 학생들은 보통 Jupyter + yarp.js 로 인터랙티브 개발.
- 별도 **iCub-OASIS** 같은 BCI 인터페이스 GUI 도 존재 (확인 필요).

### LLM
- 학계 다수 — 예: ergoCub LLM teleoperation (2024) 등. 공식 통합은 아님.

### 라이선스
- iCub-main, YARP, all software: BSD-3 / LGPL — **풀 오픈소스**. 하드웨어 도면 (CAD) 도 상당 부분 공개.

### DarwinForge 차용 포인트
1. **YARP 의 포트 기반 추상화** = 우리 `Bus` 와 거의 같은 발상. 향후 멀티-로봇 또는 시뮬-실기 동시 연결 시 YARP-스타일 named port 모델을 참고.
2. **풀 오픈소스 정책** = 교육 시장에서의 신뢰. DarwinForge 의 라이선스 정책에 영향.

### 출처
- https://icub.iit.it/
- https://github.com/robotology/yarp
- https://github.com/robotology/icub-main

---

## 4. Poppy Humanoid (Inria)

### 연구소
Inria FLOWERS (Bordeaux), 이후 Poppy Project 비영리. 2014 발표.

### 하드웨어
- 25 DOF, Dynamixel **MX/AX 시리즈** 사용 (DARwIn-OP 와 같은 ROBOTIS 모터 — ★ DarwinForge 와 직접 호환 가능)
- 무게 ~3.5 kg, 키 84 cm
- 본체 80% 가 3D 프린트 가능 (PLA / ABS). Raspberry Pi 또는 Odroid 가 메인 CPU.

### SDK
- **Pypot** — Python 기반. Dynamixel SDK 위에 얹은 high-level 라이브러리. `robot.l_arm.shoulder_pitch.goal_position = 30` 같이 객체.속성 접근.
- REST API (`pypot.server.rest`), V-REP / CoppeliaSim / Gazebo 시뮬 plugin.

### 모션 저작 UI/UX
- **Poppy Web Interface** — 브라우저 기반. 관절 카드 그리드 + 실시간 슬라이더, **Move Recorder** (드래그-티칭: 모터를 손으로 움직이면 위치 기록 → 재생).
- **Jupyter 노트북** — 공식 튜토리얼이 노트북. 코드 셀 안에 IPython widget 슬라이더 / 그래프.
- "What you see is what you get" 직접 조작 + 코드 셀의 hybrid.

### LLM
- 외부. Inria 측 일부 BCI / NLP 실험 (확인 필요).

### 라이선스
- 소프트웨어: GPLv3 / CC-BY-SA. **하드웨어 CAD 전부 공개**.

### DarwinForge 차용 포인트
1. **드래그 티칭 (Move Recorder)** = DarwinForge `MotionLibraryView` 에 즉시 도입할 가치. CM-740 의 torque off → 사용자가 손으로 자세 만듦 → ⌘+R 로 키프레임 기록 → 라이브러리에 저장.
2. **Jupyter 셀 = 코드 = 즉시 실행** 사상 = DarwinForge 의 자연어 → 의도 → 실행 흐름의 다른 표현.

### 출처
- https://www.poppy-project.org/
- https://github.com/poppy-project/pypot
- https://docs.poppy-project.org/en/

---

## 5. KAIST HUBO / DRC-HUBO+

### 연구소
KAIST Humanoid Robot Research Center (오준호 교수 팀). 2002 KHR-1 시작 → DRC-HUBO+ (2015 DARPA Robotics Challenge 우승).

### 하드웨어
- DRC-HUBO+: 32 DOF, 키 168 cm, 무게 80 kg (배터리 포함). 무릎 변형 휠 모드.
- BLDC + 하모닉, 분산 EtherCAT 컨트롤.
- HUBO-2 (교육용) 은 별도로 더 작음 (확인 필요).

### SDK
- **Hubo-Ach** — 자체 RT 통신 미들웨어 (Ach IPC).
- ROS bridge, OpenHubo 시뮬.
- Choreonoid 연동 일부.

### 모션 저작 UI/UX
- 자체 GUI 가 일부 있으나 **공개 정도 낮음 (확인 필요)**. DRC 영상에 등장하는 monitoring 콘솔은 ROS rqt 기반 추정.
- 모션은 주로 C++ + Choreonoid 또는 OpenHubo 에서 trajectory 짜는 식.

### LLM
- 외부. KAIST 측 별도 연구 트랙.

### 라이선스
- Hubo-Ach: BSD. 일부 모듈은 비공개.
- 하드웨어: 비공개 / 라이선스 기반 (Rainbow Robotics 가 상용화 — KAIST 분사).

### DarwinForge 차용 포인트
1. **EtherCAT 분산 컨트롤** = OP/OP2 가 단일 CM-740 에 의존하는 구조보다 확장적. 향후 OP3 → 자체 보드 확장 시 참고.
2. 직접적 UI 패턴 차용은 적음.

### 출처
- http://hubolab.kaist.ac.kr/
- https://github.com/golems/hubo-ach

---

## 6. ROBOTIS OP3 (★ DarwinForge 직접 후속)

### 회사
ROBOTIS (한국). DARwIn-OP → OP2 → OP3 (2017) 계보.

### 하드웨어
- 20 DOF, Dynamixel XM/XH-430 시리즈 (전자 OP/OP2 의 MX-28 대비 더 강한 토크 + 프로토콜 2.0)
- 키 51 cm, 무게 3.5 kg
- Intel NUC i3 + USB2Dynamixel + 미니 IMU
- 풀-바디 ROS 2 reference 제공

### SDK
- **ROS / ROS2 humanoid_op3** 메타패키지 — 공식 GitHub.
- **Dynamixel SDK** + **DynamixelWorkbench** (C/C++/Python).
- robotis_controller, op3_walking_module, op3_action_module 등.

### 모션 저작 UI/UX
- **Action Editor (구 RoboPlus)** — Windows 전용 GUI. 페이지 = 모션 시퀀스. 페이지 안에 **스텝 (step)** 들이 그리드로 나열, 각 스텝에 모터별 목표값 + 시간 + pause + next.
- **op3_action_editor** ROS 노드 — 터미널 기반.
- 일부 **web UI** (op3_web_setting_tool) 가 있어 IP / 캘리브레이션 관리.
- DARwIn-OP 시절의 .mtn 포맷이 OP3 에서도 호환 (★ DarwinForge 핵심 자산).

### LLM
- 공식 통합 없음. 외부 연구 다수 (예: KAIST 학생 프로젝트).

### 라이선스
- ROS 패키지 전부 Apache 2.0 / BSD. 풀 오픈소스.
- 하드웨어 CAD 일부 공개 (OP2 시절보다 더 개방).

### DarwinForge 차용 포인트
1. **OP3 의 ROS2 정렬** = DarwinForge 가 OP/OP2 를 ROS2 로 끌어올릴 때, op3 패키지의 walking_module + action_module 인터페이스를 직접 모방하면 마이그레이션 코스트 감소.
2. **op3_action_editor 의 페이지/스텝 모델** = DARwIn .mtn 포맷의 직계 후손. DarwinForge `MotionLibraryView` 가 이미 같은 모델을 공유.

### 출처
- https://emanual.robotis.com/docs/en/platform/op3/introduction/
- https://github.com/ROBOTIS-GIT/ROBOTIS-OP3
- https://github.com/ROBOTIS-GIT/DynamixelSDK
