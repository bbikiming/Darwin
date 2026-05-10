# 01. 6대 협동 로봇 (Cobot) 제조사 비교

> "산업 현장이 어떤 로봇을 쓰는가"의 기준선. DarwinForge가 데스크탑
> 휴머노이드용임에도 산업 cobot의 사양·SDK·티칭 방식은 직접 차용
> 가능한 곳이 많다. 각 단락 끝 출처 URL 필수, 미확인 항목은 "확인
> 필요" 표기.

## 한눈 비교표

| 항목 | UR (UR5e 기준) | FANUC CRX-10iA | ABB GoFa CRB 15000 | KUKA LBR iiwa 14 R820 | Yaskawa HC10DTP | Doosan M0609 |
|------|:--------------:|:--------------:|:------------------:|:---------------------:|:----------------:|:------------:|
| 자유도 | 6 | 6 | 6 | **7** | 6 | 6 |
| 가반하중 (kg) | 5 | 10 | 5 | 14 | 10 | 6 |
| 도달거리 (mm) | 850 | 1249 | 950 | 820 | 1200 | 900 |
| 반복 정확도 (mm) | ±0.03 | ±0.04 | ±0.05 | ±0.10 | ±0.03 | ±0.03 |
| 안전 등급 | PLd Cat 3 | PLd Cat 3 | PLd Cat 3 | PLd Cat 3 (HRC 4) | PLd Cat 3 | PLd Cat 3 |
| 티칭 방식 | PolyScope GUI + Free-drive | iPendant + Direct teach | FlexPendant + Lead-through | smartPAD + Hand-guiding | Smart Pendant + Easy Teach | DART-Studio + Direct teach |
| SDK | URScript / RTDE / ROS-Industrial | KAREL / iRPC / FANUC PCDK | RAPID / RWS / ABB SDK | KUKA Sunrise.OS (Java) / FRI | MotoPlus C++ / Yaskawa SDK | DRL (Python) / DART API |
| 무게 (kg) | 20.6 | 40 | 27 | 29.9 | 47 | 27 |

(출처: 각 제조사 공식 데이터시트 — 본문 단락별 인용)

---

## 1) Universal Robots (UR3e / UR5e / UR10e / UR16e / UR20)

**덴마크 Odense, 2005 창립.** 협동 로봇 시장 점유율 1위 (2024 IFR 추정 ~50%).

### 핵심 사양 (UR5e 대표)

- **자유도**: 6
- **가반하중**: 5 kg (UR3e 3 kg / UR10e 12.5 kg / UR16e 16 kg / UR20 20 kg)
- **도달**: 850 mm
- **반복도**: ±0.03 mm
- **TCP 속도**: 1 m/s 기본, **PFL 모드에서 250 mm/s** (ISO 10218-1 §5.10.5 핸드 가이드 한계와 동일)
- **무게**: 20.6 kg

### 안전 등급

- **ISO 13849-1 PLd, Category 3** — 안전 입출력 17개 기능 인증 (TÜV NORD).
- **ISO/TS 15066** PFL 적합 — Force/Torque 임계값 사용자 조정 가능.
- **컨트롤러 안전 회로 이중화**, 주 컨트롤러 다운 시 SS1 (Safe Stop 1) 강제.

### 티칭 방식

- **PolyScope GUI** (12.1" 터치 펜던트) — Linux 기반, 5세대 (2024) 출시.
- **Free-drive 모드** — 펜던트 후면 버튼 누른 상태에서 로봇 팔을 손으로 끌면 그 자리에 자세 캡처. **★ DarwinForge Pose Capture 직결**.
- **Waypoint 기반 모션** — `MoveJ` (관절 보간) / `MoveL` (직선) / `MoveP` (블렌드 직선).
- **URScript** — Python 유사 텍스트 스크립트 언어. PolyScope에서 GUI로 만든 시퀀스가 URScript로 export 됨.

### SDK / 자동화

- **RTDE (Real-Time Data Exchange)** — TCP 30004 포트, 125 Hz 업데이트, 모터·관절 텔레메트리 외부 노출. ★ DarwinForge가 차용할 만한 패턴.
- **URCap** — Java 기반 PolyScope 플러그인 시스템.
- **ROS-Industrial** 표준 드라이버 (`Universal_Robots_ROS2_Driver`).

(출처: UR 공식 사이트 https://www.universal-robots.com/products/ ; UR5e 데이터시트 https://www.universal-robots.com/media/1808656/ur5e-spec-sheet.pdf ; URScript 매뉴얼 https://www.universal-robots.com/articles/ur/release-notes/urscript-manual/ ; RTDE 가이드 https://www.universal-robots.com/articles/ur/interface-communication/real-time-data-exchange-rtde-guide/)

> ★ DarwinForge 적용:
> - **Free-drive UX** — DARwIn-OP는 force-torque 센서 없으나 토크 OFF + `present_load` 기반 근사 가능. `03-ux-patterns.md` §1 참조.
> - **RTDE 125 Hz 텔레메트리 패턴** — DarwinForge `forge-core::telemetry`도 50 Hz tick으로 SwiftUI에 push 중. RTDE의 sub_index/output 패턴 차용 가치.

---

## 2) FANUC CRX 시리즈 (CRX-5iA / 10iA / 25iA)

**일본 야마나시, 1972 창립.** 산업 로봇 시장 1위 (전통 6축 매니퓰레이터 포함). CRX는 협동 로봇 라인 (2019 출시).

### 핵심 사양 (CRX-10iA)

- **자유도**: 6
- **가반하중**: 10 kg
- **도달**: 1249 mm — 동급 cobot 중 최장
- **반복도**: ±0.04 mm
- **무게**: 40 kg
- **수명**: 평균고장간격 8년 무유지보수 표방 (FANUC 공식)

### 안전 등급

- **PLd Cat 3** (ISO 13849-1)
- **DCS (Dual Check Safety)** — FANUC 자체 이중화 안전 회로. 영역·속도 모니터링.
- **충돌 감지** — 모터 전류 기반, 중지 시간 100 ms 미만 (확인 필요).

### 티칭 방식

- **iPendant** — FANUC 표준 티칭 펜던트 (CRX는 태블릿형 변형).
- **Direct teach** — 로봇 팔 옆 버튼 누르고 손으로 끌기.
- **TP Programs** — KAREL 또는 TPP (Teach Pendant Program) 텍스트.
- **CRX 전용 모바일 앱** — iOS/Android에서 시퀀스 편집 가능.

### SDK

- **KAREL** — FANUC 자체 PASCAL-유사 언어 (ROBOGUIDE 시뮬에서 디버깅).
- **iRPC** — Industrial Robot Procedure Call (TCP 기반 RPC).
- **PCDK** (PC Developer Kit) — Windows .NET 라이브러리.

(출처: FANUC CRX 페이지 https://www.fanucamerica.com/products/robots/series/collaborative-robot ; CRX 데이터시트 https://www.fanuc.eu/eu/en/robots/robot-filter-page/collaborative-robots/collaborative-crx-series ; KAREL Reference R-30iB+ — 사용자 매뉴얼 (FANUC 회원가입 필요, 확인 필요))

> ★ DarwinForge 적용:
> - **충돌 감지 = 모터 전류 임계값** — Dynamixel `present_current` (Reg 126/144) 로 동등 구현 가능. 우리 `forge-core::safety::collision_detect` 신설 제안.

---

## 3) ABB Cobot 라인 (YuMi IRB 14000 / GoFa CRB 15000 / SWIFTI CRB 1100)

**스위스 Zürich, 1988 ABB AB 합병 창립.** YuMi는 듀얼 암 (양팔) 협동 로봇으로 2015 출시 — cobot의 양팔 표준.

### 핵심 사양 (YuMi IRB 14000)

- **자유도**: 7+7 (좌우 각 7-DOF)
- **가반하중**: 0.5 kg (각 팔)
- **도달**: 559 mm (각 팔)
- **반복도**: ±0.02 mm — cobot 중 최고 정밀
- **무게**: 38 kg (베이스 포함)

### 안전 등급

- **PLd Cat 3** (ISO 13849-1)
- **SafeMove 4** — ABB 자체 안전 SW. 가상 fence (Zone) / 속도 / Tool 자세 모니터링.
- **충돌 시 정지 거리 ≤ 5 cm** (ISO/TS 15066 PFL Annex A 임계값 만족).

### 티칭 방식

- **FlexPendant** — 8.4" 터치, ABB 표준.
- **Lead-through** — YuMi는 그립 위 버튼 누르고 손으로 끌면 캡처.
- **RobotStudio** — Windows 데스크탑 시뮬레이터 (PC 측).

### SDK

- **RAPID** — ABB 고유 언어 (Pascal 유사). RobotStudio에서 작성·디버깅.
- **RWS (Robot Web Services)** — REST/JSON, 컨트롤러 상태 외부 노출.
- **ABB SDK for .NET** — Windows 클라이언트.

(출처: ABB YuMi 페이지 https://new.abb.com/products/robotics/robots/collaborative-robots/yumi/irb-14000 ; GoFa CRB 15000 https://new.abb.com/products/robotics/robots/collaborative-robots/crb-15000 ; SafeMove 4 https://new.abb.com/products/robotics/controllers/safemove)

> ★ DarwinForge 적용:
> - **양팔 동기 제어 패턴** — DARwIn-OP도 좌우 팔 4 모터씩 8개 (ID 1/3/5/7 좌, 2/4/6/8 우). YuMi의 `MoveSync` (양팔 동시 도착) 개념을 우리 `motion` 도구에 추가 가능.
> - **SafeMove Zone** — 가상 cuboid 영역 침범 시 정지. DarwinForge "Safety Bubble" 시각화 차용.

---

## 4) KUKA LBR iiwa (Lightweight Intelligent Industrial Work Assistant)

**독일 Augsburg, 1973 창립.** LBR iiwa는 7축 협동 로봇 (2013 출시), 토크 센서 내장이 특징.

### 핵심 사양 (LBR iiwa 14 R820)

- **자유도**: **7** (잉여 자유도 — 같은 EE 위치 유지하며 팔꿈치 회전 가능)
- **가반하중**: 14 kg
- **도달**: 820 mm
- **반복도**: ±0.10 mm
- **무게**: 29.9 kg
- **각 관절에 토크 센서** — 외력·임피던스 제어 직접 가능

### 안전 등격

- **PLd Cat 3** (ISO 13849-1)
- **HRC 4 (Human-Robot Collaboration Level 4)** — DGUV 인증, 즉 "공유 작업 공간에서 인간과 직접 접촉 가능".
- **Cartesian Impedance Control** — 위치 대신 가상 스프링·댐퍼 모델.

### 티칭 방식

- **smartPAD** — 10" 터치 펜던트.
- **Hand-guiding mode** — 7-DOF 잉여를 활용해 진짜 부드러움. 토크 센서 + admittance control.
- **KUKA Sunrise.Workbench** — Eclipse 기반 IDE.

### SDK

- **KUKA Sunrise.OS** — Java 기반 (Eclipse RCP)
- **FRI (Fast Research Interface)** — UDP 1 kHz, 학술 연구용. ★ 모델 차용 가치.

(출처: KUKA LBR iiwa 페이지 https://www.kuka.com/en-de/products/robot-systems/industrial-robots/lbr-iiwa ; FRI 정보 https://github.com/lbr-stack/lbr_fri_ros2_stack)

> ★ DarwinForge 적용:
> - **각 관절 토크 센싱** = Dynamixel `present_load` (signed 10-bit, 0~+1023 = 0~100% 부하). 외력 추정 가능.
> - **FRI 1 kHz UDP**가 너무 빠르다면 우리는 50 Hz로도 충분 (DARwIn-OP CM-740 USB latency 5~10 ms).

---

## 5) Yaskawa Motoman HC 시리즈 (HC10DTP / HC20DTP / HC30PL)

**일본 키타큐슈, 1915 창립.** "Motoman" 라인은 1989, HC (Human Collaborative) 협동 라인은 2017.

### 핵심 사양 (HC10DTP)

- **자유도**: 6
- **가반하중**: 10 kg
- **도달**: 1200 mm
- **반복도**: ±0.03 mm
- **무게**: 47 kg — 동급 중 가장 무거움

### 안전 등급

- **PLd Cat 3**
- **FSU (Functional Safety Unit)** — Yaskawa 자체 안전 컨트롤러. Cubic Zone, Speed Limit, Tool Angle 모니터.
- **6축 모두 충돌 토크 센서 내장** (HC 라인의 차별점).

### 티칭 방식

- **Smart Pendant** — Yaskawa 신규 펜던트, 8.5" 터치.
- **Easy Teach** — Direct teach 모드.
- **INFORM III** — Yaskawa 고유 언어.

### SDK

- **MotoPlus** — C++ 기반 컨트롤러 측 확장.
- **Yaskawa High Speed Ethernet (HSE)** — UDP 250 Hz.

(출처: Yaskawa HC https://www.motoman.com/en-us/products/robots/industrial/assembly-handling/hc-series ; HC10DTP 데이터시트 https://www.motoman.com/getmedia/3D707E8F-8C2D-4AAF-B83D-32125DCE32C0/HC10DTP.pdf)

> ★ DarwinForge 적용:
> - **6축 모두 충돌 토크 센서** — DARwIn-OP의 20개 Dynamixel 모두 `present_load` 읽기 가능. 단, MX-28 부하는 노이즈 큼 — 저역 필터링 필수.

---

## 6) Doosan Robotics M / H / E 시리즈 (★ 한국)

**한국 수원, 2015 두산그룹 협동 로봇 자회사 분리.** 2024 한국거래소 (KRX) 상장.

### 핵심 사양 (M0609)

- **자유도**: 6
- **가반하중**: 6 kg
- **도달**: 900 mm
- **반복도**: ±0.03 mm
- **무게**: 27 kg

### 안전 등급

- **PLd Cat 3** (ISO 13849-1)
- **TÜV SÜD 인증** — 2017년 Doosan M 시리즈 최초 인증.
- **KOSHA Guide M-91-2012** 한국 협동 로봇 안전 가이드 자체 적합.
- **충돌 감지 토크 센서** 6축 내장.

### 티칭 방식

- **DART-Studio** — Doosan 자체 데스크탑 IDE (Windows). ★ DarwinForge 가장 가까운 비유.
- **Direct teach** — 로봇 단말 버튼.
- **Skill Block 시스템** — 블록 코딩, Pick & Place / Move / Loop 등 사전 정의 블록 드래그.

### SDK

- **DRL (Doosan Robot Language)** — Python 기반 스크립트.
- **DART-Platform** — REST API.
- **DART API** (Python C 래핑).

(출처: Doosan Robotics https://www.doosanrobotics.com/en/products/series ; DART-Studio https://www.doosanrobotics.com/en/products/dart-suite ; DRL 매뉴얼 https://manual.doosanrobotics.com/)

> ★ DarwinForge 적용 (★★★):
> - **DART-Studio Skill Block 패턴** — 자연어 명령을 LLM이 Skill Block 시퀀스로 변환 후 사용자가 검토하는 UX. 우리 `IntentDispatcher`가 이미 비슷하지만 시각화 부족. SwiftUI `MotionTimeline`에 Skill Block 노드로 표시 가능.
> - **DRL Python 임베드** — DARwIn-OP는 PyBullet 환경에서 DRL 일부 (Move/Wait) 차용 가능. 하지만 DRL은 산업 매니퓰레이터 전용 (J1~J6 명령), 휴머노이드는 직접 매핑 어려움 — **확인 필요**.
> - **TÜV + KOSHA 동시 인증 사상** — DarwinForge가 한국 시장 출시 시 KOSHA Guide M-91 자체 적합 가능.

---

---

## 7) 비-협동 (전통) 산업 로봇 — 보강 메모

DarwinForge는 cobot에 가깝지만 비-협동 산업 라인의 **컨트롤러 사상**도 차용 가치가 있어 짧게 정리.

### FANUC R-30iB Plus 컨트롤러

산업 6축 매니퓰레이터 (M-710iC / R-2000iC 등) 의 표준 컨트롤러. 별도 펜던트 (iPendant) 와 통신. Tool Center Point (TCP) 보정 / Calibration 절차 / 좌표계 (World / User / Tool) 분리가 표준.

(출처: FANUC R-30iB+ 컨트롤러 — https://www.fanucamerica.com/products/robots/robot-controllers ; **확인 필요**: 정확한 하드웨어 사양 매뉴얼 직링크 부재)

> ★ DarwinForge 적용:
> - **좌표계 분리 = World / Robot / Joint** — 우리는 현재 Joint 좌표만 다루는데, "World 좌표계 (책상 위 절대 위치)" 추가 시 자세 재현성 향상.

### ABB RobotStudio (시뮬레이터)

PC Office Ribbon UI. **VirtualController** — 실 IRC5 컨트롤러를 PC에서 동일 펌웨어로 시뮬. 시뮬 결과를 그대로 실 로봇에 download. **★ 우리 Webots 차용 사상과 동일.**

(출처: ABB RobotStudio — https://new.abb.com/products/robotics/robotstudio)

### KUKA.Sim (시뮬레이터)

3DEXPERIENCE / Visual Components 기반 PC 시뮬레이터. KUKA.OfficeLite (가상 컨트롤러) 와 통합. KUKA.Sim 4.x 부터 cloud 협업 추가.

(출처: KUKA.Sim — https://www.kuka.com/en-de/products/robot-systems/software/simulation)

### Mitsubishi RT ToolBox3

MELFA 시리즈 산업 로봇용 PC 시뮬·프로그래밍 도구. MELFA-BASIC V (BASIC 유사) 언어. 일본 자동차 부품 라인에서 우세. 학습 곡선 가파르고 UI 보수적.

(출처: Mitsubishi RT ToolBox3 — https://www.mitsubishielectric.com/fa/products/rbt/robot/pmerit/rttoolbox/)

> ★ DarwinForge 적용:
> - **이들 4개 시뮬레이터의 공통 사상 = 시뮬 ↔ 실기 동일 펌웨어 / 동일 코드** — 우리도 forge-core가 Webots controller 로 컴파일되도록 (`01-simulation/webots.md` §Step 1) 구현하면 동일 가치.

---

## 8) IFR 시장 통계 — 우리가 어디에 위치하나

International Federation of Robotics (IFR) 2024 World Robotics 보고서:

- **신규 산업 로봇 설치 (2023)**: 540,000 대 (전세계).
- **협동 로봇 비중**: ~10% (54,000 대), 매년 30%+ 성장.
- **시장 점유율 (cobot)**: UR ~50%, Techman/Doosan/FANUC/ABB ~10% 각, 기타.
- **휴머노이드 cobot**: < 1% (Apptronik, Figure, Agility 등 신규 진입).

DarwinForge는 **데스크탑 휴머노이드 (DARwIn-OP)** 라 cobot 시장에 직접 들어가지 않으나, Apptronik Apollo / Figure 02 같은 산업용 휴머노이드 cobot 진입 시 동일 안전 표준 (ISO 10218 + TS 15066) 가 적용 예상.

(출처: IFR World Robotics 2024 — https://ifr.org/worldrobotics ; Apptronik Apollo — https://apptronik.com/apollo ; Figure AI — https://www.figure.ai/)

> ★ DarwinForge 적용:
> - **장기 (Q4+)**: DarwinForge 안전 모델이 산업용 휴머노이드 cobot 진입 시 그대로 전이 가능한 설계로 갖추는 것이 가치.

---

## 학술 인용

- Aaltonen et al. [Aaltonen 2018] "Refining levels of collaboration to support the design and evaluation of human-robot interaction in the manufacturing industry", *Procedia CIRP*. (출처 https://doi.org/10.1016/j.procir.2018.03.214)
- Vicentini [Vicentini 2021] "Collaborative Robotics: A Survey", *Journal of Mechanical Design*. (출처 https://doi.org/10.1115/1.4046238)
- Kruger et al. [Kruger 2009] "Cooperation of human and machines in assembly lines", *CIRP Annals*. (출처 https://doi.org/10.1016/j.cirp.2009.09.009)
- Bauer et al. [Bauer 2008] "Human-robot collaboration: a survey", *Int. J. of Humanoid Robotics*. https://doi.org/10.1142/S0219843608001303
- Villani et al. [Villani 2018] "Survey on human-robot collaboration in industrial settings: Safety, intuitive interfaces and applications", *Mechatronics*. https://doi.org/10.1016/j.mechatronics.2018.02.009

## 출처 종합

- IFR World Robotics Report 2024 — https://ifr.org/worldrobotics
- Universal Robots — https://www.universal-robots.com/
- FANUC CRX — https://www.fanucamerica.com/products/robots/series/collaborative-robot
- ABB Robotics — https://new.abb.com/products/robotics
- KUKA LBR iiwa — https://www.kuka.com/en-de/products/robot-systems/industrial-robots/lbr-iiwa
- Yaskawa Motoman HC — https://www.motoman.com/en-us/products/robots/industrial/assembly-handling/hc-series
- Doosan Robotics — https://www.doosanrobotics.com/
