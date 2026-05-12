# MQTT — IoT pubsub

## 한 줄 소개

가벼운 publish-subscribe 메시징. IoT 표준. ROS2보다 훨씬 단순. 다중 로봇
또는 DarwinForge 인스턴스 간 lightweight 통신에 적합.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 표준 | OASIS MQTT v5 |
| 라이선스 | 무료 표준, 구현체 다양 |
| 브로커 | Mosquitto (오픈), HiveMQ, AWS IoT Core, Azure IoT Hub |
| 클라이언트 | Rust (`rumqttc`), Swift (`CocoaMQTT`) |

## DarwinForge 시나리오 — 다중 로봇 동기

사용자가 OP1과 OP2 두 대를 동시 제어 (예: 듀엣 댄스):

```
DarwinForge (OP1 연결) ─┐
                        ├─→ MQTT broker (localhost:1883)
DarwinForge (OP2 연결) ─┘                ↓
                                    "/darwin/op1/walk-start"
                                    "/darwin/op2/walk-start"
                                    동시 발행 → 동기 시작
```

## 차용 우선순위

★ — 4순위. 단일 로봇 시나리오에는 과함. 듀엣 시연 / 다중 로봇 학원
환경에서 의미.

## 출처

- MQTT v5: https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html
- Mosquitto: https://mosquitto.org/
- rumqttc: https://crates.io/crates/rumqttc
- CocoaMQTT: https://github.com/emqx/CocoaMQTT
