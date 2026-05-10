# 02. ROBOTIS 자체 SW 스택

> ROBOTIS의 공식 도구들. DarwinForge가 호환·대체해야 할 기존 워크플로우.
> 사용자가 이미 익숙한 도구일 가능성이 높으므로, 우리 UX를 "뭔가 새로
> 배워야 함"이 아닌 "익숙한 것 + 더 나음"으로 포지셔닝하기 위한 출발점.

## 인덱스

| 도구 | 플랫폼 | 라이선스 | DarwinForge에 차용 |
|------|--------|----------|---------------------|
| [RoboPlus Action](roboplus-action.md) | Windows | 독점 (무료) | 모션 페이지/스텝 메타포 (이미 차용) |
| [RoboPlus Task](roboplus-task.md) | Windows | 독점 (무료) | 행동 시각 프로그래밍 → 자연어로 대체 |
| [RoboPlus Manager](roboplus-manager.md) | Windows | 독점 (무료) | 펌웨어 관리 (현재 미구현, 미래 옵션) |
| [Dynamixel Wizard 2.0](dynamixel-wizard.md) | Win / macOS | 독점 (무료) | 모터 진단 / ID 변경 / EEPROM 편집 (★ 차용) |
| [DYNAMIXEL SDK](dynamixel-sdk.md) | All | Apache 2.0 | 우리가 Rust로 포팅 (forge-core::dynamixel) |
| [R+ Motion (Mobile)](r-plus-motion.md) | iOS/Android | 독점 (무료) | 터치 기반 모션 편집 — Mac 트랙패드 응용 |
| [R+ Task (Mobile)](r-plus-task.md) | iOS/Android | 독점 (무료) | 블록 코딩 모바일 |
| [OpenCR + Arduino IDE](opencr.md) | All | Apache 2.0 / GPL | OP3 / TurtleBot3용 — DARwIn-OP 미해당 |

## DarwinForge가 ROBOTIS 도구를 대체·보완하는 매트릭스

| 영역 | ROBOTIS 도구 (Windows) | DarwinForge (macOS 네이티브) |
|------|------------------------|------------------------------|
| 모션 저작 | RoboPlus Action | `MotionLibraryView` + 자연어 대화 |
| 행동 프로그래밍 | RoboPlus Task | 자연어 (Claude) + Strategy FSM |
| 모터 진단 | Dynamixel Wizard | `JointControlView` + `BoardStatusView` |
| 펌웨어 관리 | RoboPlus Manager | (미구현 — 위험성 때문에 후속 결정) |
| Walk 튜닝 | walk_tuner (CLI on robot) | `WalkSimView` + 향후 실기기 통합 |

## 핵심 채용 포인트 — 이미 적용된 것

1. **Page / Step 메타포** — `forge-core::motion` 모듈이 그대로 채용.
   - `MotionPage` (id, name, compliance[31], play_param, steps[1..7])
   - `MotionStep` (positions[31], pause_time, play_time)
   - `.mtn` 텍스트 포맷 round-trip 무손실
2. **Compliance per joint (0~7)** — ROBOTIS의 P-gain 매핑 패턴 그대로.
3. **20관절 ID 매핑** — `JointData.h`의 enum과 동일.

## 채용 검토 — 미적용 / 후보

1. **Dynamixel Wizard의 EEPROM 직접 편집 UI** — `JointControlView`에
   "고급" 토글로 추가. CW/CCW Angle Limit, Max Torque, Return Delay 같은
   EEPROM 레지스터를 사용자가 직접 변경 가능. 단, 위험하므로 HITL 필요.
2. **Action Editor의 "현재 자세 캡처" → 키프레임** — 토크 OFF 상태에서
   사람이 손으로 자세 잡고 캡처. 우리 모션 에디터에 추가 가치 매우 큼.
3. **Walk Tuner의 IMU 그래프** — 실시간 roll/pitch 표시 + 게인 조절.

## 우선순위

- ★★★ Action Editor pose-capture 흐름 — Sprint 4 후속에서 추가
- ★★ Dynamixel Wizard EEPROM 편집 — Sprint 7? 별도 모드
- ★ Walk Tuner IMU 그래프 — Walk loop 실 활성화 후

## 출처

- ROBOTIS e-Manual: https://emanual.robotis.com/
- DYNAMIXEL SDK: https://github.com/ROBOTIS-GIT/DynamixelSDK
- RoboPlus 다운로드: https://www.robotis.us/robotplus/
- Dynamixel Wizard 2.0: https://emanual.robotis.com/docs/en/software/dynamixel/dynamixel_wizard2/
