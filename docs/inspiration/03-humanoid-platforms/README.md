# 03 — Humanoid Platforms (카테고리 인덱스)

DarwinForge가 운용 중인 ROBOTIS DARwIn-OP / OP2 (20 DOF, ~3 kg, 45 cm) 의 미래 고도화 방향을 잡기 위해, 동시대의 휴머노이드 / 사족 / 소형 플랫폼들의 **하드웨어 규격 · SDK · 모션 저작 UI/UX 패턴 · LLM 통합 여부**를 정리한 인덱스이다.

세부 보고서는 다음 4개 파일로 분리된다.

| 파일 | 다루는 플랫폼 |
| --- | --- |
| `research-and-education.md` | NAO, Pepper, iCub, Poppy, HUBO, ROBOTIS OP3 |
| `commercial-industrial.md` | Atlas, Spot (Choreographer), Apollo, Figure 02, NEO, Optimus, Phoenix, Digit, Unitree G1/H1, Fourier GR-1, UBTECH Walker S, XPENG Iron |
| `hobbyist-small.md` | TinyWave RoFi-Mini, Bioloid, NAO mini류 |
| `key-takeaways-for-darwinforge.md` | DarwinForge SwiftUI 뷰별 직접 차용 제안 |

---

## 카테고리 비교표 (요약)

가격은 공개된 자료 기준이며, 환율 / 옵션에 따라 변동. "확인 필요" 표시는 출처가 비공식이거나 미공개인 항목.

### 가) 연구 · 교육용

| 플랫폼 | DOF | 키 / 무게 | 가격 (USD, 정가) | 대표 SDK / 미들웨어 | 모션 저작 도구 | LLM 통합 |
| --- | --- | --- | --- | --- | --- | --- |
| Aldebaran NAO6 | 25 | 58 cm / 5.5 kg | ~$9,000 (학교 프로그램) ~ $14,000+ | NAOqi 2.x, qiBullet, Python/C++ SDK | **Choregraphe** (박스 그래프 + 키프레임 타임라인) | NAOqi LLM Bridge (실험), Pepper-LLM 등 서드파티 |
| Aldebaran Pepper | 20 | 120 cm / 28 kg | ~$25,000+ (단종, 중고 시장 위주) | NAOqi (NAO와 공유) | Choregraphe | 동일 |
| iCub3 | 53 (총 53, 일부 모델 차이) | 100 cm / 33 kg | ~€250,000 (full kit) | YARP, ROS bridge, iCub-main | YARP modules + Gazebo, 일부 GUI (확인 필요) | 별도 연구 (LLM teleoperation) |
| Poppy Humanoid | 25 | 84 cm / 3.5 kg | ~€8,000 (3D printed) | **Pypot** (Python), V-REP/CoppeliaSim | Web GUI + Jupyter notebook | 외부 |
| KAIST DRC-HUBO+ | 32 | 168 cm / 80 kg | 비공개 (연구 전용) | Hubo-Ach, ROS bridge | 자체 (확인 필요) | 외부 |
| ROBOTIS OP3 | 20 | 51 cm / 3.5 kg | ~$11,500 | **ROS / ROS2 humanoid_op3** + Dynamixel SDK | RoboPlus, Action Editor, web GUI | 외부 |

### 나) 상용 / 산업

| 플랫폼 | DOF | 키 / 무게 | 가격 (USD) | SDK | 모션 저작 도구 | LLM/VLA |
| --- | --- | --- | --- | --- | --- | --- |
| Boston Dynamics Atlas (Electric, 2024) | 28+ (확인 필요) | ~150 cm / 89 kg | 미판매 (산업 파트너) | API 미공개 (자체) | 자체 (Choreographer 연동 가능, Spot 기반) | 별도 (Hyundai 연구) |
| Boston Dynamics Spot (참고) | 12 (4족) | 84 cm / 32 kg | $74,500 | Spot SDK (gRPC, Python) | **Choreographer** (음악 기반 댄스 타임라인) | Spot + ChatGPT 데모 (BD 자체) |
| Apptronik Apollo | 비공개 (~28-30 추정) | 173 cm / 73 kg | 비공개 (판매가 ~$50K target 보도) | Apptronik API (비공개) | 비공개 | NVIDIA GR00T 통합 발표 |
| Figure 02 | ~30+ | 168 cm / 70 kg | 비공개 | Figure proprietary | 비공개 | **Helix** VLA (자체) |
| 1X NEO | 비공개 (확인 필요) | 167 cm / 30 kg | $20,000 / $499 sub (announced) | NEO SDK (TBD) | 비공개 | 자체 World Model |
| Tesla Optimus Gen 2/3 | 28 (Gen 2) | 173 cm / 57 kg (Gen 2) | 미판매 (~$20-30K target) | 비공개 | 비공개 | xAI 통합 가능성 (확인 필요) |
| Sanctuary AI Phoenix | 20+ (양손 21 DOF / 손) | 170 cm / 70 kg | 비공개 | Carbon AI control system | 비공개 | Carbon (자체 cognitive) |
| Agility Robotics Digit | 20 | 175 cm / 65 kg | $250K+ (RaaS / lease) | Agility SDK (REST + LCM) | 자체 task editor (확인 필요) | NVIDIA Isaac 통합 |
| Unitree G1 | 23 (옵션 43 EDU) | 130 cm / 35 kg | $16,000+ (basic) | **Unitree SDK2** (오픈소스 부분), unitree_ros | RL 기반 + URDF + MJCF | 외부 통합 |
| Unitree H1 | 19 | 180 cm / 47 kg | $90,000+ | 동일 | 동일 | 외부 |
| Fourier Intelligence GR-1 | 40+ (모델별 상이) | 165 cm / 55 kg | ~$150,000 (확인 필요) | Fourier SDK (Python) | 비공개 | 자체 + 파트너 |
| UBTECH Walker S | 41 | 130 cm / 63 kg (S1) | 비공개 (산업 파트너) | UBTECH ROSA | 비공개 | 자체 + Baidu ERNIE 통합 (보도) |
| XPENG Iron | 60+ | 173 cm / 70 kg | 비공개 (자동차 공장 적용) | XPENG 자체 | 비공개 | XPENG Brain (자체) |

### 다) 소형 / 취미

| 플랫폼 | DOF | 키 / 무게 | 가격 (USD) | SDK | 모션 저작 도구 | LLM |
| --- | --- | --- | --- | --- | --- | --- |
| TinyWave RoFi-Mini | ~16-20 (확인 필요) | ~30 cm 내외 | 비공식 (kit ~$1-2K 추정, 확인 필요) | TBD | 자체 (확인 필요) | TBD |
| ROBOTIS Bioloid Premium | 18 | 39.7 cm / 1.7 kg | ~$1,500 (단종 / 후속 STEM) | RoboPlus (구) | RoboPlus Motion / Behavior | X |
| Generic mini humanoid (e.g. EZ-Robot JD) | 16-19 | 30-35 cm | $300-1,500 | EZ-Builder | Block-based + timeline | 일부 클라우드 음성 |

---

## 빠른 인사이트 (자세한 분석은 `key-takeaways-for-darwinforge.md` 참조)

1. **Choregraphe (NAO/Pepper)** 의 박스 기반 행동 그래프 + 키프레임 타임라인은 25년 가까이 이어진 휴머노이드 모션 저작 UX의 gold standard. DarwinForge 의 `MotionLibraryView` 와 `StrategyView` 양쪽에 직접 영향.
2. **Spot Choreographer** 의 음악 기반 다중 트랙 (legs / body / lights / audio) 타임라인은 BPM 동기화와 timeline scrubbing 패턴을 제공. DarwinForge 의 모션 라이브러리 preview UI 에 그대로 차용 가능.
3. **Pypot (Poppy)** 의 IPython / Jupyter 우선 워크플로우는 "코드 = 행동" 등호를 살린 hackable 접근. DarwinForge 의 자연어 명령 결과를 즉시 실행 가능한 코드 스냅으로 보여주는 설계와 호응.
4. **Unitree SDK2** 의 단순한 Python / C++ low-level API + URDF/MJCF 동봉은 오픈소스 시뮬-실기 통합의 모범. DarwinForge 의 `WalkSimView` 와 `Bus` 추상화가 닮은 구조를 가질 수 있다.
5. **Figure Helix** 의 자연어 → 행동 매핑은 DarwinForge 가 이미 가진 `ClaudeCommander` + `IntentDispatcher` 와 같은 계층을 시사한다. 하지만 Helix 는 vision-language-action (VLA) 모델로 직접 토크 컨트롤까지 내려가는 반면 DarwinForge 는 (현 단계에서) 의도-스키마 변환이라는 안전한 중간 단계를 둔다.
6. **Apptronik Apollo + NVIDIA GR00T** 흐름은 휴머노이드 → 시뮬레이션 → RL → 실기 라는 파이프라인이 표준화되고 있다는 신호. DarwinForge 의 향후 simulation/learning 포트 확장 시 NVIDIA Isaac 호환을 우선순위로 둘 가치.
7. **OP3 (ROBOTIS)** 가 이미 ROS2 / Dynamixel SDK 정렬을 마쳤기 때문에, DARwIn-OP/OP2 → OP3 마이그레이션 경로를 DarwinForge 가 (CM-740 ↔ Dynamixel Workbench 어댑터 형태로) 미리 그려둘 가치가 있다.

---

## 출처 (인덱스 · 일반)

- Aldebaran (United Robotics Group) NAO 공식: https://www.aldebaran.com/en/nao
- Aldebaran Pepper: https://www.aldebaran.com/en/pepper
- IIT iCub: https://icub.iit.it/ , https://github.com/robotology/icub-main
- Poppy Project: https://www.poppy-project.org/ , https://github.com/poppy-project/pypot
- KAIST HUBO Lab: http://hubolab.kaist.ac.kr/
- ROBOTIS OP3: https://emanual.robotis.com/docs/en/platform/op3/introduction/
- Boston Dynamics Atlas (Electric): https://bostondynamics.com/atlas/
- Boston Dynamics Spot Choreographer: https://dev.bostondynamics.com/docs/concepts/choreography/readme
- Apptronik Apollo: https://apptronik.com/
- Figure: https://www.figure.ai/
- 1X Technologies NEO: https://www.1x.tech/neo
- Tesla Optimus: https://www.tesla.com/AI
- Sanctuary AI Phoenix: https://www.sanctuary.ai/
- Agility Robotics Digit: https://agilityrobotics.com/products/digit
- Unitree Robotics G1/H1: https://www.unitree.com/g1 , https://www.unitree.com/h1 , https://github.com/unitreerobotics
- Fourier Intelligence GR-1: https://www.fftai.com/
- UBTECH Walker S: https://www.ubtrobot.com/
- XPENG Iron: https://www.xpeng.com/news
- ROBOTIS Bioloid: https://emanual.robotis.com/docs/en/edu/bioloid/premium/
