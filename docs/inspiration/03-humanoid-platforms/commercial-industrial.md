# 03-B — 상용 / 산업 휴머노이드

DarwinForge 의 OP/OP2 와는 규모, 가격, 자율성 모두 한 단계 위. **하지만 모션 저작 UI 와 LLM 통합 패턴은 그대로 차용 가능한 부분이 많다**. 특히 Spot Choreographer 의 음악-동기 다중 트랙 타임라인은 별도 절로 매우 상세히 분석.

---

## 7. Boston Dynamics Atlas (Electric, 2024)

### 회사 / 시점
Boston Dynamics. 유압식 Atlas 는 2024-04-16 공식 은퇴, **All-electric Atlas** 새 버전 발표 (2024-04-17). Hyundai Motor Group 모회사.

### 하드웨어 규격
- DOF: 28 + 다관절 이상 추정 (정확치 비공개 — **확인 필요**). 무릎/엉덩이가 360° 회전 가능한 새 디자인.
- 키 ~150 cm, 무게 89 kg (이전 유압식 기준; 전기식 사양은 비공개).
- 액추에이터: 자체 BLDC + 유성기어 + 일부 반사 구동.
- 센서: stereo + ToF, 다관절 토크 센싱.

### SDK / API
- **외부에 미공개** (산업 파트너 전용 — Hyundai 자동차 라인 대상).
- 학계는 영상 + 논문만 접근.

### 모션 저작 UI/UX
- 비공개. 다만 Spot 의 **Choreographer** 와 같은 Boston Dynamics 모션 저작 도구가 Atlas 로 확장될 가능성이 높음 (BD blog 댄스 영상).
- 댄스 영상 ("Do You Love Me", 2020) 은 Choreographer 로 저작되었다고 BD 공식 발언.

### LLM / VLA
- BD 본사가 Hyundai NVIDIA 협력으로 GR00T-style 통합 가능성 (확인 필요). 공식 발표 없음.

### 라이선스
- 클로즈드 + 상업 라이선스만.

### DarwinForge 차용 포인트
- 직접 차용 어려움. 다만 **유압→전기 전환** 트렌드 자체가 DarwinForge 의 BLDC 액추에이터 미래 지원에 시사점.

### 출처
- https://bostondynamics.com/atlas/
- https://bostondynamics.com/blog/electric-new-era-for-atlas/
- (영상) https://www.youtube.com/watch?v=29ECwExc-_M

---

## 8. Boston Dynamics Spot — Choreographer (★ 매우 상세)

### 회사 · 시점
Boston Dynamics. Spot 자체는 4족이지만 **Choreographer** 댄스 저작 SW 가 우리 모션 라이브러리의 직접 참고 대상.

### 하드웨어 (참고)
- 12 DOF (다리 4×3), 키 84 cm, 무게 32 kg, 가격 $74,500.
- Spot SDK (gRPC + Python) 가 공개되어 있어 댄스 / 텔레오퍼레이션 / payload 통합 가능.

### Choreographer UI/UX 구조

1. **다중 트랙 타임라인**
   - 가로축 = 시간 (초 또는 BPM 비트). 세로축은 각 **track**.
   - 트랙 종류: **Body track** (몸체 자세 / pitch / roll / yaw / height), **Legs track** (다리 모드 — step, kneel, hop), **Arm track** (Spot Arm 옵션 시), **LED / lights track**, **Audio track**, **Animation track** (사전 녹화 모션).
   - 각 트랙 안에 **MoveBlock** 이라는 직사각 블록을 드래그-드롭. 블록 길이 = 지속 시간.
2. **Move 라이브러리 (좌측 패널)**
   - 미리 정의된 100+ Moves: "step", "trot", "kneel-leg-move", "twerk", "chicken-head", "nod", "pose", "torso-pitch" 등.
   - 카테고리별 (Body / Legs / Stepping / Arm / Lights) 탭. 검색바.
   - 각 Move 는 클릭 시 **inspector 패널** 에서 파라미터 (amplitude, speed, easing) 슬라이더로 튜닝.
3. **BPM Sync (음악 기반 타이밍)**
   - 상단에 **음악 파일 로드** (.wav/.mp3). Choreographer 가 BPM 을 자동 감지 (또는 수동 입력).
   - 타임라인 눈금이 **BPM 비트 격자** 로 변경 가능 — MoveBlock 이 비트에 자동 스냅.
   - 트랙 위에 음악 파형 (waveform) 가 표시 → MoveBlock 시작/끝을 비트와 시각적으로 정렬.
4. **Playback 컨트롤**
   - 재생 / 일시정지 / 루프 / 트림. **Onscreen scrubber** 로 임의 시점 점프. 재생 시 Spot 미리보기 (3D simulation 또는 실기 직접) 동기 재생.
5. **Sequence Editor (병렬 시퀀스)**
   - 한 타임라인 = 한 시퀀스. 시퀀스를 **Sequence Library** 에 저장 → 다른 시퀀스에서 import 가능.
6. **Realtime tweak**
   - 재생 중 슬라이더를 움직이면 다음 frame 부터 즉시 반영. iteration 속도 매우 빠름.

### SDK / API
- **Spot SDK** (Python, gRPC) — 오픈소스 클라이언트. 자체 부트스트랩 인증 (자격 증명 필요).
- choreography_sequence_pb2 (protobuf 정의) — Choreographer 가 만든 sequence 를 코드에서 그대로 빌드 가능. **결정적 — 우리 .mtn JSON 포맷의 모범**.

### LLM
- 2023 BD 공식 데모 — Spot + ChatGPT (관광 가이드 페르소나). Foundry 단계.

### 라이선스
- Spot SDK: Apache 2.0 (클라이언트 측). 본체 OS 는 클로즈드.

### DarwinForge 차용 포인트 (★)
1. **다중 트랙 타임라인** — DarwinForge `MotionLibraryView` 의 모션 편집 모달을 single-track 에서 다중 트랙 (Head / Arms / Legs / 발화 / LED) 로 확장하면 표현력 폭증.
2. **BPM 스냅** — DarwinForge 도 음악 파일 로드 시 BPM 자동 감지 → 키프레임을 비트에 스냅 → 댄스 모션 저작 UX 차별화. SwiftUI 의 `Timeline` + `ScrollView` 위에 격자 오버레이.
3. **Move 라이브러리 inspector 패널** — 카드를 클릭하면 우측에 슬라이더가 뜨는 패턴은 이미 우리 `MotionGalleryGridView` 의 자연스러운 확장.

### 출처
- https://dev.bostondynamics.com/docs/concepts/choreography/readme
- https://github.com/boston-dynamics/spot-sdk/tree/master/python/examples/choreography_examples
- https://www.bostondynamics.com/products/spot

---

## 9. Apptronik Apollo

### 회사 · 시점
Apptronik (Austin, TX), 2016 NASA Valkyrie 알룸나이 설립. Apollo 발표 2023-08, Mercedes-Benz 협업 2024.

### 하드웨어
- DOF 비공개 (~28-30 추정, **확인 필요**). 키 173 cm, 무게 73 kg, payload 25 kg. 4시간 가동 (배터리 핫스왑).
- 자체 BLDC + planetary, **force-sensing 액추에이터** (low impedance) 가 Apptronik 핵심 IP.

### SDK / API
- 비공개. 산업 파트너 전용. NVIDIA Project GR00T 채택 발표 (2024-03 GTC).

### 모션 저작 UI/UX
- 비공개. NVIDIA Isaac Sim + Omniverse 통합 가능성 (GR00T 발표 맥락).

### LLM / VLA
- NVIDIA GR00T 통합 발표. 자체 LLM 연구 트랙도 있음 (확인 필요).

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- **NVIDIA Isaac Sim 호환** = 우리 시뮬레이션 포트 미래 우선순위.

### 출처
- https://apptronik.com/
- https://nvidianews.nvidia.com/news/foundation-model-isaac-robotics-platform

---

## 10. Figure 02 + Helix (HW/SDK 측면만)

### 회사 · 시점
Figure AI (Sunnyvale, CA), 2022 설립. Figure 01 — 2024-02 발표. Figure 02 — 2024-08 발표. Helix VLA 발표 — 2025-02.

### 하드웨어 (Figure 02)
- DOF ~30+ (정확 수치 비공개). 키 168 cm, 무게 70 kg. 21 DoF 손 (커스텀).
- 자체 액추에이터 (BLDC + planetary). 6×RGB 카메라.
- **온보드 GPU** — Helix 추론을 클라우드 없이 실행.

### SDK / API
- **비공개 / 자체.** OpenAI 와의 초기 파트너십 종료 후 자체 모델 (Helix) 로 전환.
- 외부 개발자에 SDK 미제공.

### 모션 저작 UI/UX
- 알려진 GUI 없음. **Helix 가 자연어 → 액션 직접 매핑** 하므로 키프레임 저작 자체가 줄어드는 패러다임 (확인 필요).

### LLM / VLA
- **Helix** — 7B parameter VLA, 200Hz upper-body / 7-9 Hz reasoning 듀얼 시스템 (System 1 / System 2). 다른 보고서에서 상세 다룸.

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트 (HW/SDK 한정)
1. **온보드 GPU** = DarwinForge 가 향후 OP3 후속에 Jetson 류를 탑재한다면 동등 패턴.
2. **저작 도구 없음 = LLM 으로 대체** 라는 가설 자체가 DarwinForge `ConversationView` 의 비전과 일치 — 단, 우리는 안전한 의도-스키마 중간 계층을 둔다.

### 출처
- https://www.figure.ai/
- https://www.figure.ai/news/helix
- https://x.com/figure_robot

---

## 11. 1X NEO

### 회사 · 시점
1X Technologies (노르웨이/캘리포니아). NEO Beta 발표 — 2024-08. 가정용 베타 출하 — 2025 예정.

### 하드웨어
- DOF 비공개 (확인 필요). 키 167 cm, 무게 30 kg (가벼운 편 — 가정 안전성 강조).
- **Tendon-driven** 액추에이터 (저소음 + 컴플라이언스).
- 가격: $20,000 일시불 또는 $499/월 구독 (announced).

### SDK
- 1X NEO SDK 발표 예고만 있음. 공식 공개는 미정 (확인 필요).

### 모션 저작 UI/UX
- 비공개. 1X 의 World Model (자체 비전 모델) 이 핵심.

### LLM
- 자체 World Model + 텔레오퍼레이션 데이터로 학습.

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- **Tendon-driven 저소음** = 가정 / 교실 친화. OP/OP2 의 큰 모터 소음에 대한 미래 답변.

### 출처
- https://www.1x.tech/neo
- https://www.1x.tech/discover

---

## 12. Tesla Optimus Gen 2 / Gen 3

### 회사 · 시점
Tesla. Gen 1 — 2022, Gen 2 — 2023-12, Gen 3 — 2025 (확인 필요, AI Day 2025 발표).

### 하드웨어 (Gen 2)
- 28 DOF, 키 173 cm, 무게 57 kg. 11 DOF 손.
- 자체 BLDC + harmonic, Tesla 공장 인하우스 제작.

### SDK
- 외부 비공개.

### 모션 저작 UI/UX
- 비공개. Tesla 자체 시뮬레이터 (영상 분석 기준 — 확인 필요).

### LLM / VLA
- xAI Grok 통합 가능성 보도되었으나 공식은 아님 (확인 필요). Optimus 자체 정책 모델은 vision 기반 imitation learning 데모.

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- 직접 적음. 다만 **Imitation learning 기반 데모** 흐름은 Poppy Move Recorder 의 산업판.

### 출처
- https://www.tesla.com/AI
- https://twitter.com/Tesla_Optimus

---

## 13. Sanctuary AI Phoenix

### 회사 · 시점
Sanctuary AI (Vancouver, 캐나다). Phoenix Gen 6 — 2023, Gen 7 — 2024.

### 하드웨어
- 키 170 cm, 무게 70 kg, payload 25 kg. 손 21 DOF (양손).
- 자체 액추에이터.

### SDK
- **Carbon AI control system** — 자체. 외부 SDK 미공개.

### 모션 저작 UI/UX
- 비공개. Carbon 이 인지 / 의도 / 액션의 통합 시스템.

### LLM / VLA
- Carbon 자체 (하이브리드 인지 + LLM).

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- **Carbon 의 인지-의도-액션 layered architecture** = DarwinForge 의 `IntentDispatcher` 분리 사상과 닮음.

### 출처
- https://www.sanctuary.ai/
- https://www.sanctuary.ai/blog

---

## 14. Agility Robotics Digit

### 회사 · 시점
Agility Robotics (Oregon). Cassie (이족) 2017 → Digit V1 (2019) → V4 (2024).

### 하드웨어
- 20 DOF (4×다리 6 + 양팔 + 머리), 키 175 cm, 무게 65 kg.
- BLDC + 유성기어. **Bird-leg style** 후방 무릎.
- ToF + RGB 카메라 헤드.

### SDK
- **Agility SDK** — REST + LCM (Lightweight Communications and Marshalling). Python / C++.
- ROS bridge 일부.

### 모션 저작 UI/UX
- **Operator console** (Agility Arc cloud) — 작업 흐름 정의 UI 가 있다고 보도. 그래프 + 단계 (확인 필요, 비공개 일부).
- NVIDIA Isaac Sim 통합 (NVIDIA GTC 2024 발표).

### LLM
- NVIDIA GR00T 채택. 자체 자연어 → 작업 매핑 데모.

### 라이선스
- SDK 일부 제한적 공개. 본체 클로즈드.

### DarwinForge 차용 포인트
- **Agility Arc 같은 cloud operator console** = DarwinForge 가 향후 다중 OP 군집을 다룰 때 분리할 가치 있는 컴포넌트.

### 출처
- https://agilityrobotics.com/products/digit
- https://docs.agilityrobotics.com/

---

## 15. Unitree G1 + H1 (★ 오픈소스 SDK 부분)

### 회사 · 시점
Unitree Robotics (중국 항저우). H1 발표 — 2023-08, G1 — 2024-05.

### 하드웨어
- **H1**: 19 DOF, 키 180 cm, 무게 47 kg, 가격 $90,000+ (~).
- **G1**: 23 DOF (옵션 EDU 43 DOF), 키 130 cm, 무게 35 kg, 가격 $16,000부터 (★ DarwinForge 가격대와 가장 가까움).
- 자체 BLDC + planetary. Force-sensing.

### SDK / 미들웨어
- **unitree_sdk2** — C++ + Python. **오픈소스 (BSD)**. 저수준 모터 명령 + IMU + odom 직접 접근.
- **unitree_ros / unitree_ros2** — 공개. URDF + MJCF (MuJoCo) 동봉.
- **unitree_rl_gym** — Isaac Gym 기반 RL 환경 공개.

### 모션 저작 UI/UX
- 별도 GUI 저작 도구는 약함. **RL 정책 / 코드 중심**.
- Unitree app (모바일) 으로 텔레오퍼레이션 + 미리 정의된 시퀀스 재생 정도.

### LLM
- 외부 통합. Unitree 자체 LLM 발표 없음.

### 라이선스
- SDK / ROS / sim env: BSD / Apache 2.0. **부분 오픈소스 — 우리 정책 모델로 가장 가까움.**

### DarwinForge 차용 포인트 (★)
1. **unitree_sdk2 의 단순 저수준 API 패턴** — DarwinForge `Bus` 가 Dynamixel SDK 위에 얹는 추상화와 닮은 구조. 우리 `BusV2` 가 이런 식으로 정리되면 외부 개발자가 쉽게 코드 수준 개입.
2. **MJCF 동봉** — 우리 `WalkSimView` 가 향후 MuJoCo 또는 Isaac 으로 갈 때 URDF + MJCF 동시 제공이 표준.

### 출처
- https://www.unitree.com/g1
- https://www.unitree.com/h1
- https://github.com/unitreerobotics/unitree_sdk2
- https://github.com/unitreerobotics/unitree_rl_gym

---

## 16. Fourier Intelligence GR-1

### 회사 · 시점
Fourier Intelligence (상해). GR-1 발표 — 2023-07. GR-2 — 2024-09.

### 하드웨어
- 40+ DOF (모델별 상이), 키 165 cm, 무게 55 kg.
- 자체 액추에이터 (Fourier 는 재활 로봇 출신).

### SDK
- **Fourier SDK** — Python. 비공개 일부 + 파트너 NDA.

### 모션 저작 UI/UX
- 비공개 (확인 필요).

### LLM
- 자체 + 파트너 (확인 필요).

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- 직접 적음.

### 출처
- https://www.fftai.com/
- https://www.fftai.com/products-gr1

---

## 17. UBTECH Walker S

### 회사 · 시점
UBTECH (선전). Walker — 2018, Walker S1 — 2024-04.

### 하드웨어
- Walker S1: 41 DOF, 키 130 cm (모델 상이), 무게 63 kg.
- 자체 서보 + harmonic.

### SDK
- **UBTECH ROSA** — 자체 OS / 미들웨어. 외부 미공개.

### 모션 저작 UI/UX
- 비공개. UBTECH 의 STEM 시리즈 (Jimu Robot) 는 블록 코딩 (Scratch like) UI 가 있으나 Walker S 는 산업 전용.

### LLM
- **Baidu ERNIE Bot 통합** 보도 (2024). 자동차 공장 시연 (BYD, Geely).

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- **STEM 라인의 블록 코딩 UI** (UBTECH Blockly) = 박스 그래프의 또 다른 변형.

### 출처
- https://www.ubtrobot.com/
- https://www.ubtrobot.com/products/walker

---

## 18. XPENG Iron

### 회사 · 시점
XPENG Motors (자동차 회사). Iron 발표 — 2024-11.

### 하드웨어
- 60+ DOF (XPENG 발표). 키 173 cm, 무게 70 kg. 손 11 DOF.
- XPENG 자체 액추에이터.

### SDK
- 비공개. 자동차 공장 (P7, X9 라인) 적용.

### 모션 저작 UI/UX
- 비공개.

### LLM / VLA
- **XPENG Brain** (자체 자율주행 + 로봇 통합 모델). XGPT 와 연결 (확인 필요).

### 라이선스
- 클로즈드.

### DarwinForge 차용 포인트
- 자동차 회사가 만드는 통합 OS 패턴 — **다른 제품군 (자동차) 과 코드 공유**. DarwinForge 가 다중 폼팩터 (OP/OP2 + 미니 + 시뮬) 를 한 앱에 두는 사상과 미세하게 호응.

### 출처
- https://www.xpeng.com/news
- https://en.xiaopeng.com/

---

## 종합 패턴 (이 카테고리 내)

1. **공식 GUI 저작 도구 공개 정도는 Boston Dynamics (Choreographer) > Unitree (코드 중심) > 나머지 (비공개)** 순.
2. **NVIDIA Isaac / GR00T 채택**이 빠르게 표준이 되어가는 중 (Apptronik, Agility, Figure 일부, Unitree).
3. **자체 VLA 모델 (Helix, World Model, Carbon, XPENG Brain)** 이 자연어 저작 도구를 일부 대체하려는 흐름. 하지만 안전성 / 디버깅 측면에서 **명시적 키프레임 + 박스 그래프** 는 여전히 학교 / 시연 / 의료 등에서 강세.
4. DarwinForge 가 OP/OP2 라는 작은 폼팩터에서 출발했기에, **Spot Choreographer 의 다중 트랙 타임라인** + **NAO Choregraphe 의 박스 그래프** + **Pypot 의 드래그 티칭** 의 교집합이 가장 바람직한 진화 경로다.
