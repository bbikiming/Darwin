# research/community/robot_personal_assistant_op2/_NOTES.md

> ROBOTIS-OP2 위에 구축한 책상 ergonomic 개인비서 시스템. ROS Noetic (PC) / ROS Indigo (Darwin)
> 분산 구조. 우리 프로젝트에서는 **OP2 라이브 모션 카탈로그** + **인터랙션 시나리오 디자인**
> 의 1차 reference.

## 메타

| 항목 | 값 |
|------|----|
| Upstream | <https://github.com/PersonalAssistantGradProject/robot_personal_assistant_op2> |
| Commit | `f6cfc3a77d49f75d439c4fd1857cc56babf5711b` (2023-11-01) |
| Target | DARwIn-OP2 (CM-740) |
| License | `package.xml` 에 `<license>TODO</license>` — **실질 미선언** |
| Repo size | ~5.2 MiB |

## 주요 파일

| 경로 | 역할 |
|------|------|
| `motion_4096.bin` (131 072 byte) | **OP2 라이브 모션 — 63 개 명명 페이지** (스톡 + ergonomic 100~108 + 인사 250~255) |
| `Project Documentation.pdf` (1.8 MiB) | 전체 설계 의도, 분산 노드 토폴로지, RL 보상 함수 정의 |
| `haarcascade_frontalface_default.xml` | OpenCV 얼굴 검출 cascade (OpenCV BSD 라이선스 산물) |
| `package.xml` | catkin 패키지 정의 (license=TODO) |
| `CMakeLists.txt` | catkin build 정의 |
| `launch/robot.launch` | Darwin 측 노드 entrypoint |
| `launch/laptop.launch` | PC 측 노드 entrypoint |
| `launch/action_initialize.launch` | 모션 페이지 슬롯 사전 로드 |
| `launch/functions_of_robot.launch` | 기능 노드 묶음 |
| `launch/rostopic_init.launch` | ROS topic 초기화 |
| `requirements_darwin.txt` | Darwin Python 2.7 deps |
| `requirements_pc.txt` | PC Python 3.8 deps |

### scripts/main/ (실 노드)

| 노드 | 역할 |
|------|------|
| `action_initialize.py` | 페이지 슬롯 초기화 |
| `action_sender.py` | 페이지 번호 → ROBOTIS Action 모듈 publisher |
| `audio_sender.py` / `audio_reciever_speech_recognizer.py` | 마이크 → PC STT |
| `audio_note_player.py` / `record_note.py` | 음성 메모 녹음·재생 |
| `bad_posture_detector.py` | MediaPipe 기반 자세 평가 (Web 링크: learnopencv.com posture analysis) |
| `command_handler.py` / `input_handler.py` | 사용자 명령 라우터 |
| `face_recognizer.py` | OpenCV LBPH face 인식 |
| `image_publisher.py` | Darwin 카메라 → PC frame publisher |
| `pain_handler.py` | RL 기반 통증 조언 — **page 100~108 트리거 핵심** |
| `search_web.py` / `search_wikipedia.py` / `word_finder.py` | 웹 검색 |
| `text_to_speech_publisher.py` / `text_to_speech_subscriber.py` | gTTS 기반 발화 |

### scripts/testing and others/ (실험·trash)

테스트 스크립트와 `trash/` (과거 버전). 우리 코어에는 미사용. 단, `tts_speed_test.py`, `print_test.py`
는 워크플로 검증 패턴 참고용.

## 페이지 하이라이트

자세한 카탈로그 → [`motions/external/_catalog/op2-personal-assistant.csv`](../../../motions/external/_catalog/op2-personal-assistant.csv)

### page 100~108 — **거북목/허리/팔 케어 (이 저장소 고유)**

| # | name | steps | repeat | next | 추정 의미 |
|--:|------|------:|-------:|-----:|-----------|
| 100 | robot_initial_ | 1 | 1 | 0 | base pose (모든 ergonomic 페이지의 복귀 지점) |
| 101 | neck_1 | 4 | 1 | **100** | 목 좌우 회전 |
| 102 | neck_2 | 4 | 1 | **100** | 목 끄덕임 |
| 103 | arm_1 | 1 | 1 | **100** | 팔 스트레치 (단일 step) |
| 104 | back_1 | 3 | 1 | **100** | 허리 트위스트 |
| 105 | leg_1 | 7 | 1 | **100** | 다리 스트레치 — 7 step 풀 시퀀스 |
| 106 | back_2 | 2 | **3** | **100** | 허리 단순 동작 × 3 반복 |
| 107 | arm_2 | 2 | **3** | **100** | 팔 단순 동작 × 3 반복 |
| 108 | sit_down | 1 | 1 | 0 | 안전 종료 |

> 패턴: **모든 ergonomic 페이지가 `next=100` 으로 base pose 복귀** → 호출 측은
> 임의 시점에 다음 페이지를 트리거할 수 있다.

### page 150~152 — 추가 sit/init 변주

| # | name | steps | speed | 비고 |
|--:|------|------:|------:|------|
| 150 | sit down | 4 | 32 | 4-step 변주 (스톡 1-step 보다 부드러움) |
| 151 | gomwqf | 2 | 32 | 오타 추정 (good morning?) |
| 152 | robot_initial_ | 2 | **40** | 100 의 빠른 버전 |

### page 250~255 — **인사·환영·작별 set (이 저장소 고유)**

| # | name | steps | speed | next | 의미 |
|--:|------|------:|------:|-----:|------|
| 250 | init_pose | 1 | 32 | 0 | base pose (인사 set 복귀 지점) |
| 251 | welcome | 2 | 32 | **250** | 사용자 등장 감지 시 |
| 252 | ok | 5 | 32 | **250** | 음성 명령 수락 (스톡 page 2 와 별개) |
| 253 | bye | 5 | **30** | **250** | 작별 (약간 느린 속도) |
| 254 | Go | 5 | 32 | **250** | 명령 실행 신호 |
| 255 | test | 5 | 32 | **250** | 데모 |

> 패턴: 250 = base, 251~255 = 인사 종류, 모두 `next=250` 으로 복귀. **우리 라이브러리도
> 동일 패턴 권장** (예: 슬롯 200 = base, 201~210 = 표정/제스처 set).

## 우리 프로젝트에서의 활용

| 분야 | 참고 방식 |
|------|-----------|
| 모션 라이브러리 구조 | "base + next-loop" 패턴 — page 100/250 모델을 따른다 |
| 인터랙티브 시나리오 | `pain_handler.py` ↔ page 100~108 트리거 매핑 = **음성 명령 → 모션 페이지 dispatch** 디자인 |
| ROS bridge 설계 | PC ↔ Darwin 분산은 우리 SwiftUI ↔ Rust 코어 ↔ USB CM-730 모델과 다름. 토픽 네이밍만 참고 |
| 코드 직접 임포트 | **❌** — license=TODO 이므로 보류. 페이지 메타·아이디어 인용만 OK |
| 모션 페이지 추출 | `motion_4096.bin` 의 page 100~108 / 250~255 만 우리 라이브러리에 슬롯-매핑 가능 (단, 실기체 검증 필수) |

## 주의

1. **라이선스 미선언** — README/PDF 인용 OK, 그러나 `motion_4096.bin` 의 페이지 데이터를
   forge-core 에 패키징하려면 저자에게 명시적 허가 필요. 우선은 페이지 이름/구조 정보만 인용.
2. **OP2 전용** — CM-740 + MX-28 (구형 펌웨어 가정). OP1 (CM-730) 에 그대로 적용 시
   compliance/torque 매핑 차이로 진동 가능. 백업 + offset_tuner 재실행 권장.
3. **저장소가 졸업 프로젝트 1회성** — 추가 유지보수 기대 X. 핵심 자료만 캡처해서 우리
   문서에 흡수.
