# 03-C — 소형 / 취미용 휴머노이드

DarwinForge 가 **운반 가능한 ~50 cm 급 휴머노이드** 를 다루기 때문에, 실제 사용자 페르소나 (학교 + 가정 + 메이커 + 연구실 보조) 와 가장 인접한 카테고리. 가격대가 $300–2000 사이로 OP/OP2 보다 한 단계 아래지만, **저작 UI 가 단순화되어 있어 차용 가치가 오히려 큼**.

---

## 19. TinyWave RoFi-Mini (사용자 언급 — 부분적 공개)

### 회사
TinyWave (확인 필요 — 한국/대만 소형 메이커 추정). RoFi-Mini 라는 이름의 소형 휴머노이드 키트 / 완제품을 내놓는다고 알려져 있으나, 공식 웹사이트 / 카탈로그가 명확히 검증되지 않음.

### 출시 시점
- **확인 필요.** 2023~2024 추정. CES / Maker Faire 류 이벤트에 등장한 흔적.

### 하드웨어 (추정)
- DOF ~16-20 (다수 소형 휴머노이드 표준 16, 17, 18, 20 중 하나 — **확인 필요**)
- 키 ~30 cm 내외, 무게 ~1 kg
- 액추에이터: 소형 디지털 서보 (LX-15D 또는 SCS 시리즈 추정), 일부 모델은 시리얼 버스 서보
- 메인 컨트롤러: ESP32 또는 Raspberry Pi Zero W 추정
- 센서: 카메라 1, 마이크, 일부 IMU

### SDK / API
- 공식 SDK 정보 미확인. **확인 필요.**
- 다수 소형 휴머노이드가 Arduino / MicroPython 기반인 점 고려하면 동일 패턴일 가능성.

### 모션 저작 UI/UX
- 공식 도구 미확인. 일반적으로 이 가격대는:
  - 모바일 앱 (BLE) 으로 슬라이더 + 미리 정의된 모션 재생
  - Scratch / Blockly 류 비주얼 코딩 (기관 / 학교 PoC 시)
  - 또는 단순 Python REPL

### LLM / AI 통합
- 공식 미확인. **확인 필요.**

### 라이선스
- 미확인.

### DarwinForge 차용 포인트
- 본 시점에서는 직접 차용 불가 (정보 부족). **사용자 측에서 RoFi-Mini 의 공식 자료를 추가로 제공해주면 별도 보고서 작성 가능.**

### 출처
- (공식 출처 미확인 — 사용자 추가 자료 필요)
- (참고) 유사 가격대 소형 휴머노이드 사례: https://www.kondo-robot.com/product-category/robot/khr

---

## 20. NAO 미니 / 소형 휴머노이드 류 (구체 모델 확인 필요)

NAO 자체에는 공식 "mini" 서브-제품이 없음. 다만 시장에서 "NAO 같은 소형 휴머노이드" 카테고리로 묶이는 모델이 다수.

### (a) Kondo KHR 시리즈 (일본 — Kondo Kagaku)

- **시점:** KHR-1 — 2004, KHR-3HV — 2008, KHR-5HV — 2024.
- **하드웨어:** 17 DOF (KHR-3HV), 키 ~40 cm, 무게 1.5 kg. KRS 시리즈 디지털 서보.
- **SDK:** HeartToHeart (자체 GUI) — Windows. 모션 = 프레임 시퀀스 + 사이클.
- **모션 저작 UI:** **HeartToHeart 4** — 가로 타임라인 형태. 각 행 = 모터, 각 열 = 프레임 (시간). 셀에 각도 입력. 한 페이지가 한 모션. 모션끼리 점프 / 분기 가능 (NAO Choregraphe 와 RoboPlus 의 중간).
- **LLM:** 없음.
- **라이선스:** 클로즈드.
- **DarwinForge 차용 포인트:** 셀 단위 프레임 표 = OP의 .mtn step 모델과 거의 동일. DarwinForge 가 이미 같은 모델 보유 → 신규 통찰은 적음. 다만 **모션 간 점프 / 분기 그래프** 패턴은 우리 `MotionLibraryView` 가 아직 갖지 않은 부분.
- **출처:** https://kondo-robot.com/product-category/robot/khr

### (b) UBTECH Alpha 1 / Alpha Mini

- **시점:** Alpha 1 — 2014, Alpha Mini — 2018.
- **하드웨어:** Alpha 1 = 16 DOF, 키 39.5 cm, 무게 1.65 kg. Alpha Mini = 14 DOF, 키 24.5 cm.
- **SDK:** UBTECH 자체 BLE + 모바일 앱.
- **모션 저작 UI:** **Alpha 1 PC Suite** — 가로 타임라인 + 액션 그룹. 모터를 손으로 잡고 자세를 만든 뒤 **티칭 (Pose Capture)** 버튼으로 키프레임 저장 (★ Poppy 와 같은 패턴). Alpha Mini 는 **JIMU Blockly** 라는 블록 코딩.
- **LLM:** Alpha Mini 클라우드 서비스에 음성 인식 + 챗봇 (Baidu DuerOS 류 — 확인 필요).
- **라이선스:** 클로즈드.
- **DarwinForge 차용 포인트:**
  1. **Pose Capture 버튼** = NAO 의 Hold Pose, Poppy 의 Move Recorder 와 같은 패턴. 우리 `MotionLibraryView` 도입 0순위.
  2. **JIMU Blockly** = NAO Choregraphe 의 단순화 버전. 어린 사용자 대상 모드 — DarwinForge 의 "쉬움 모드" 미래 제안.
- **출처:** https://www.ubtrobot.com/products/alpha1pro , https://www.jimurobot.com/

### (c) EZ-Robot JD Humanoid

- **시점:** 2014, 캐나다.
- **하드웨어:** 18 DOF, 키 30 cm. EZ-Bit 자석식 모듈 + 자체 서보.
- **SDK:** **EZ-Builder** (Windows / 클라우드). 후속 ARC (Autonomous Robotics Control).
- **모션 저작 UI:** **Auto Position** 모듈 — 가로 타임라인 + 행 = 서보. 각 frame 의 각도 입력 + delay. Pose 라이브러리.
  - **Skill Store** — 박스 / 플러그인 마켓. 음성 인식, 비전, 자율 이동 등을 박스로 끌어다 쓰는 형태.
- **LLM:** ARC 가 OpenAI / Microsoft 음성 통합 (확인 필요).
- **라이선스:** 클로즈드 (커뮤니티 + 학교 라이선스).
- **DarwinForge 차용 포인트:**
  1. **Skill Store 마켓플레이스** = 우리가 향후 모션 라이브러리를 사용자가 공유하게 할 때의 모범. macOS App Store 또는 GitHub Gist 연동.
  2. **EZ-Bit 모듈식 하드웨어** = 우리 OP/OP2 가 정해진 폼팩터인 점과 대비되지만, 미래 옵션 확장 (그리퍼 / 카메라 헤드 등) 시 참고.
- **출처:** https://www.ez-robot.com/ , https://synthiam.com/

---

### (d) Hovis Lite / Eco Plus (DST Robot, 한국)

- **시점:** Hovis Lite — 2010, Hovis Genie — 2013.
- **하드웨어:** 16~20 DOF, 키 41 cm, 무게 1.6 kg. DST 자체 디지털 서보 (DRS-0101). 가격 $1,200~1,800.
- **SDK:** **DR-Visual Logic** (Windows) — 블록 코딩 + 자체 모션 캡처 도구.
- **모션 저작 UI:**
  - **DR-Sim** + **Hovis Action** — 3D 미리보기 + 모터 슬라이더 그리드 + 가로 타임라인 (포즈 사이 보간 시간 + 가속도 곡선 선택).
  - **모션 캡처** — Hovis 표준 모션 약 50종 동봉 (Stand, Squat, Wave, Bow, Kick, Jump). 사용자 직접 캡처도 가능.
  - **DR-Visual Logic** — Scratch 류 블록 코딩으로 모션 호출 / 센서 분기.
- **LLM:** 없음.
- **라이선스:** 클로즈드. DST Robot 한국 시장 중심.
- **DarwinForge 차용 포인트:**
  1. **모션 50종 표준 동봉** = 한국 사용자 / 학교 워크숍 시작 비용 인하의 결정적 포인트. DarwinForge 가 OP2 표준 모션 50선을 기본 라이브러리로 동봉하면 첫 사용 5분 내 시연 가능.
  2. **블록 코딩 + 모션 호출 콤보** = 사용자가 자연어 또는 박스 그래프 외에도 빠르게 시도해볼 수 있는 entry-level 옵션.
- **출처:**
  - https://www.dstrobot.com/eng/product/hovis-lite (URL 확인 필요)
  - https://www.robotsource.org/Hovis (커뮤니티)

---

## 21. ROBOTIS Bioloid (구세대 — DarwinForge 의 직계 조부)

### 회사 · 시점
ROBOTIS. Bioloid Comprehensive — 2007. **Bioloid Premium** — 2010 (DARwIn-OP 출시 직전 동일 사용자 층 대상 제품).

### 하드웨어
- **Bioloid Premium**: 18 DOF (인간형 구성 시), Dynamixel **AX-12A** 모터, 키 39.7 cm, 무게 1.7 kg.
- 모듈식 — 다리 4족, 거미, 휴머노이드 등 변형 가능.
- 컨트롤러: CM-510 / CM-530 (마이크로컨트롤러 ATmega2561).
- 센서: 적외선, 거리, gyro 옵션.
- 가격: $1,500 정도 (단종, 후속 STEM Kit 으로).

### SDK / 미들웨어
- **RoboPlus** (Windows 전용) — Task / Motion / Manager 의 3종 GUI.
- BIOL Schedule, embedded C 가능 (CM-530 펌웨어 작성).

### 모션 저작 UI/UX (★ DarwinForge 의 직계)

1. **RoboPlus Motion**
   - 좌측 패널: **모션 페이지 트리** (모션 = 페이지, 페이지마다 0~7 step).
   - 중앙 캔버스: **3D Bioloid 모델** + 관절 슬라이더 그리드 (모터 ID 별).
   - 하단 타임라인: 페이지의 step 들이 가로로 나열. 각 step 에 시간 + pause + 다음 페이지 ID.
   - 페이지 → 페이지 점프 (next, exit), repeat count, real-time playback.
   - **현재 자세 캡처** 버튼이 핵심 — 모터 torque off → 사용자가 손으로 자세 → "캡처" 버튼 → step 저장.

2. **RoboPlus Task**
   - 좌측: 명령어 라이브러리 (if / while / set / motion play / sensor read / I/O).
   - 중앙: 들여쓰기 기반 의사 코드 트리 (BASIC 같은 행 단위 + 들여쓰기로 블록 표현).
   - **박스 그래프 가 아닌 행 단위 트리** — NAO Choregraphe 와는 다른 길.

3. **RoboPlus Manager**
   - 모터 ID 변경, 모터 진단, 펌웨어 업데이트.

### LLM
- 없음.

### 라이선스
- 클로즈드 (RoboPlus). 모터는 ROBOTIS 표준.

### DarwinForge 차용 포인트 (★)

1. **RoboPlus Motion 의 페이지 / step 모델** = OP/OP2 의 **.mtn 파일이 거의 동일한 구조**. DarwinForge 의 `MotionLibrary` 는 이미 이를 일급 시민으로 다룸 — 검증.
2. **현재 자세 캡처 버튼** = Bioloid 시절부터 ROBOTIS 사용자가 익숙한 패턴. DarwinForge 의 모션 저작 모달에서 ⌘+K (Capture) 단축키로 즉시 도입할 가치.
3. **RoboPlus Manager 의 모터 진단** = DarwinForge 가 자체 진단 뷰 (`HardwareDiagnosticsView` 또는 유사) 를 둔다면 모터별 status (전압, 온도, 부하, 위치 오차) 카드 그리드가 모범.
4. **RoboPlus Task 의 행 단위 트리** = 박스 그래프와 함께 옵션으로 제공할 가치. SwiftUI 의 `OutlineGroup` 으로 구현 자연스러움.

### 출처
- https://emanual.robotis.com/docs/en/edu/bioloid/premium/
- https://emanual.robotis.com/docs/en/software/rplus2/motion/
- https://emanual.robotis.com/docs/en/software/rplus2/task/

---

## 종합 패턴 (이 카테고리 내)

1. 가격대 $300~2000 의 소형 휴머노이드는 거의 전부 **타임라인 + 페이지 / step + 자세 캡처** 라는 RoboPlus 류 모델을 변형해서 사용. → DarwinForge 가 이 패턴을 **계승하면서 SwiftUI 의 모던한 UX (스무드 애니메이션 + 카드 + 자연어 명령) 로 갱신** 하는 것이 가장 바람직한 차별화.
2. **블록 코딩 (Blockly / Scratch)** 이 어린 사용자 / 학교 시장의 사실상 표준. DarwinForge 가 향후 K-12 시장을 노린다면 별도 "쉬움 모드" 로 Blockly 임베드 (또는 Apple Swift Playgrounds 호환) 를 검토.
3. **Skill / Plugin 마켓** (EZ-Robot Skill Store) = 사용자 커뮤니티 형성을 가속하는 결정적 패턴. DarwinForge 가 모션 라이브러리 + 의도 스크립트를 사용자가 공유 / 내려받을 수 있는 구조를 미리 설계하면, OP/OP2 사용자 군의 작은 시장에서도 네트워크 효과 가능.
4. **Pose Capture (자세 캡처)** = 가격 / 규모를 막론하고 모든 휴머노이드 저작 도구에 공통. **DarwinForge 가 아직 없다면 즉시 도입 0순위.**
