# DDS — Data Distribution Service

## 한 줄 소개

OMG (Object Management Group) 표준 분산 통신. ROS2의 통신 백엔드.
publish-subscribe + QoS (지연·신뢰성·내구성) 보장.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 표준 | OMG DDS v1.4 |
| 구현 | Fast DDS (eProsima), Cyclone DDS (Eclipse), RTI Connext, OpenSplice |
| 라이선스 | Apache 2.0 (Cyclone, Fast 일부) / 상용 (RTI) |
| ROS2 기본 | Fast DDS (이전 RMW), Cyclone DDS (옵션) |

## DarwinForge에 직접

- ROS2 통합 시 자동 사용. 별도 코드 X.
- 단독으로 DDS만 쓰는 시나리오 — 산업 PLC와 직접 통신. 우리 스코프 외.

## 차용 우선순위

★ — ROS2 통합 시 부수적. 직접 채용 X.

## 출처

- OMG DDS 표준: https://www.omg.org/spec/DDS/
- Fast DDS: https://fast-dds.docs.eprosima.com/
- Cyclone DDS: https://cyclonedds.io/
