# OpenCR + Arduino IDE — TurtleBot3 / OP3용 보드

## 한 줄 소개

ROBOTIS의 ARM Cortex-M7 보드 (STM32F746). DARwIn-OP의 CM-730/CM-740의
후속 같은 위치이지만 **DARwIn-OP에는 미해당**. TurtleBot3, OP3, 일부 학습
키트에 사용.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| MCU | STM32F746 (Cortex-M7 @ 216 MHz) |
| 라이선스 | Apache 2.0 (펌웨어), Arduino IDE는 GPL/LGPL |
| 호환 | TurtleBot3, ROBOTIS-OP3, OpenManipulator |
| **DARwIn-OP 호환** | ❌ — CM-730/CM-740이 별개 |

## 우리에게 의미

- **참고만** — DARwIn-OP/OP2는 CM-730/CM-740 사용. OpenCR로의 마이그레이션은
  ROBOTIS가 공식 지원하지 않음.
- **펌웨어 업로드 워크플로우** — Arduino IDE 통한 STM32 부트로더 활용. 우리
  CM-730/740 펌웨어 업로드도 같은 STM32 부트로더 패턴 (`docs/protocols/cm-730-740.md`
  §펌웨어 업로드 참조).

## 차용 우선순위

★ — 5순위. DARwIn-OP 직접 무관. 우리 펌웨어 업로드 기능 (만약 추가 시)에
패턴 참고.

## 출처

- OpenCR GitHub: https://github.com/ROBOTIS-GIT/OpenCR
- 매뉴얼: https://emanual.robotis.com/docs/en/parts/controller/opencr10/
- TurtleBot3 + OpenCR: https://emanual.robotis.com/docs/en/platform/turtlebot3/opencr_setup/
