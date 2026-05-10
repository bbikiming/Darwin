# micro-ROS — MCU에서 ROS2

## 한 줄 소개

STM32 / ESP32 / Arduino 같은 MCU에서 ROS2를 실행. CM-730/CM-740이
STM32F103RE 기반이므로 이론적으로 micro-ROS화 가능. 실용적 가치는 ?.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | Apache 2.0 |
| 호환 RTOS | FreeRTOS, Zephyr, NuttX |
| 통신 | XRCE-DDS (DDS의 MCU 친화 변형) |
| 메모리 | ~32~64 KB RAM 가능 |
| 호스트 측 | micro-ROS Agent (DDS와 브릿지) |

## CM-730/CM-740 적용 가능성

CM-730은 64 KB SRAM, 512 KB Flash. micro-ROS 최소 사양 충족.

상상 시나리오:
1. CM-730 ROBOTIS 펌웨어 → micro-ROS 펌웨어로 교체
2. CM이 직접 ROS2 토픽 publish (관절 / IMU)
3. DarwinForge는 ROS2 노드로 subscribe

장점: 직렬 프로토콜 추상화 → ROS2 표준
단점:
- **펌웨어 교체 = 벽돌 위험** ⚠️
- 부록 A 정책: 사용자 명시 확인 전 절대 펌웨어 업로드 금지
- ROBOTIS 호환성 깨짐 — RoboPlus 도구 사용 불가
- 워크 알고리즘이 CM 펌웨어에 의존하지 않음 (PC가 모터 직접 제어)이라
  큰 이득 없음

## 차용 우선순위

★ — 매우 낮음. 제어가 PC 측 (forge-core::walk)에 있으니 CM의 ROS2화는
효용 적음.

## 출처

- micro-ROS: https://micro.ros.org/
- micro-ROS for STM32: https://github.com/micro-ROS/micro_ros_stm32cubemx_utils
- XRCE-DDS: https://www.eprosima.com/products/micro-xrce-dds
