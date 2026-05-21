# DJI 조종기 통합 — Deferred Plan

- **작성일**: 2026-05-21
- **갱신일**: 2026-05-21 v2 (research-analyst 조사 + Tello SDK prototype 시작)
- **상태**: **Phase 4 첫 단계 시작됨** (Tello UDP prototype) — 실 hardware 없이 mock 으로 진행 가능
- **선행 작업**: Phase 1 (WalkTrial) ✅, Phase 1.5 (Apply-Scope Badge) ✅, Phase 2 (Recommender) ✅ — 모두 완료
- **트리거**: 사용자 요청 — "원격 조종은 DJI 조종기로" → "DJI 시뮬레이터 코드 조사 후 조종"

---

## 1. 결정 사항

기존 plan 의 **Phase 4 (원격 조종 GameController.framework)** 를 **DJI 조종기** 통합으로 대체.
"게임 캐릭터처럼 조종" 의 궁극 목표는 유지하되, 입력 device 가 일반 Xbox/PS 게임패드가 아닌
DJI 산업용 RC 조종기 (예: DJI RC, DJI Smart Controller, DJI RC Plus 등).

## 2. 차이점 (GameController vs DJI)

| 항목 | GameController.framework | DJI 조종기 |
|---|---|---|
| OS 통합 | macOS native (Bluetooth/USB) | DJI Mobile SDK / Onboard SDK (iOS/Android/Linux) |
| 입력 패턴 | dual stick + face buttons | 산업용 RC (4 채널 stick + scroll dial + 토글) |
| 통신 채널 | macOS HID | OcuSync / Lightbridge (RC link) + USB/Wi-Fi |
| Latency | <30ms typical | <50ms typical (OcuSync), ~100ms (Wi-Fi) |
| 안전 | OS 의 input event 큐 | DJI SDK 의 emergency stop + RC link loss 자동 home |
| 인증 | 무관 | DJI Developer 계정 + App Key 필요 |

## 3. macOS 앱과 DJI 조종기 통합 방법 (조사 필요)

DJI Mobile SDK 는 iOS/Android 전용. macOS 미지원. 따라서 macOS 앱과 DJI 조종기 사이에는
다음 중 하나의 bridge 필요:

### 옵션 A — iOS 앱 bridge
- DJI Mobile SDK 가 통합된 별도 iOS 앱이 RC 입력 → Wi-Fi/Bonjour 로 macOS 앱에 forward
- 장점: DJI SDK 공식 지원, latency 100ms 이내 가능
- 단점: iOS 앱 추가 개발 부담

### 옵션 B — USB HID emulation
- DJI 조종기 일부 (RC Plus 등) 가 USB-C HID 출력 지원 — macOS 가 일반 controller 로 인식
- macOS 의 `GameController.framework` 로 받을 수 있음 (GameController 와 같은 path)
- 장점: 추가 SDK 불필요, macOS 만으로 통합
- 단점: HID 노출 채널 제한적 (DJI 모델별 상이) — 사전 호환성 검증 필요

### 옵션 C — Raw RC PWM (Crazyflie 패턴)
- DJI 조종기 의 RC 출력을 별도 receiver 가 PWM 으로 변환
- macOS 가 USB-serial 로 PWM 값 read (Arduino 또는 Crazyflie radio dongle)
- 장점: DJI SDK 우회, 어떤 모델이든 동작
- 단점: 별도 hardware 필요, latency ↑

## 4. 사용자 선결 사항

- 사용자가 보유한 **정확한 DJI 조종기 모델명** 확인 (RC vs RC Plus vs Smart Controller)
- HID 출력 지원 여부 확인 (옵션 B 가능성)
- iOS bridge 앱 개발 의지 (옵션 A)

## 5. Phase 4 구현 시점

다음 phase 완료 후 진행:
- ✅ Phase 1 (Trial 데이터)
- ✅ Phase 1.5 (Apply-Scope Badge)
- ⏳ Phase 2 (Recommender)
- ⏳ Phase 3 (모션 catalog + blending)
- ⏸ Phase 4: DJI 조종기 통합 ← 본 문서

## 6. Phase 4 신규 모듈 후보

기존 plan 의 `PilotController` 를 DJI 대응으로 재설계:

```
WalkLab/Pilot/
  ├── DJIRemoteAdapter.swift          # 옵션 A/B/C 중 하나의 adapter 인터페이스
  ├── PilotIntent.swift                # 입력 정규화 (DJI / 키보드 / 기타)
  ├── PilotSafetyGate.swift           # 기존 — RC link loss 시 emergency 추가
  └── PilotHudExtension.swift         # DJI 신호 강도 / RC 채널 표시
```

## 7. 미해결 질문

- DJI 조종기 USB-C 연결 시 macOS 가 인식하는 device profile?
- DJI RC link loss 시 자동 emergency stop 우선순위 (Mac 측 emergency vs DJI 자체)?
- DJI 조종기 의 face buttons 가 macOS 단축키 매핑 가능?
- 한국 내 DJI 산업용 RC 사용 시 규제 (FAA/KCC 등) 영향?

## 8. 참조

- DJI Mobile SDK: https://developer.dji.com/mobile-sdk/
- DJI Onboard SDK: https://developer.dji.com/onboard-sdk/ (Linux only)
- macOS GameController.framework: 일반 HID 게임패드는 통합 — DJI HID 호환성 미검증

---

## 9. research-analyst 조사 결과 (2026-05-21 v2)

5 옵션 매트릭스 (macOS 호환성):

| 옵션 | macOS 호환 | 시뮬 지원 | 코드 채널 | Swift | 신뢰도 |
|---|---|---|---|---|---|
| **(A) Tello SDK** | ✅ Native | ⚠️ Hardware 필요 (mock 자체 작성 가능) | UDP text 8889 | ⭐⭐⭐⭐⭐ Network.framework | **확정 ← 선택** |
| (B) DJI Mobile SDK | ❌ iOS/Android | ✅ DJISimulator class | iOS bridge | ⭐⭐ | 확정 |
| (C) DJI Onboard SDK | ❌ Linux | ❌ | CAN/Serial | ⭐ | 확정 |
| (D) DJI Assistant 2 | ⚠️ macOS 빌드 | ✅ USB | 미공개 protocol | ❌ | 추정 |
| (E) DJI RC USB HID | ⚠️ 일부 RC | ❌ | IOKit HIDManager | ⭐⭐⭐ 미문서 | 추정 |

**선택 이유**: macOS native + 외부 SDK 의존 0 + Tello EDU hardware 저렴 (~₩150k) + Phase 1+2 시스템과 깔끔하게 통합 가능.

## 10. Tello SDK 명령 프로토콜

- **Command port**: UDP `192.168.10.1:8889` (Tello = AP)
- **State port**: UDP `0.0.0.0:8890` (Tello → host, 100ms 주기)
- **Text 명령 (ASCII)**:
  - `command` — SDK 모드 진입 (모든 명령 전 1회)
  - `takeoff` / `land` (드론 전용, robot 무관)
  - `rc <lr> <fb> <ud> <yaw>` — stick 4채널, 각 `-100..100`
  - `emergency` — 즉시 모터 정지

## 11. 매핑 설계 (Tello stick → DARwIn-OP2)

| Tello | DARwIn | scale (default) | 한도 |
|---|---|---|---|
| `fb` 전후 | `X_MOVE_AMPLITUDE` (strideMm) | 0.4 | ±40 mm |
| `lr` 좌우 | `Y_MOVE_AMPLITUDE` (sideMm) | 0.3 | ±25 mm |
| `yaw` 회전 | `A_MOVE_AMPLITUDE` (turnDeg) | 0.2 | ±20° |
| `ud` 상하 | ❌ 무시 (drone 전용) | — | — |
| deadzone | `|stick| < 5` → 0 (drift 차단) | — | — |

## 12. 구현 진행 상황 (2026-05-21)

**Phase 4 첫 단계 — 4 신규 파일**:
- `Sources/DarwinForgeUI/WalkLab/Pilot/Tello/TelloLink.swift` — UDP NWConnection 구현 + `TelloLinkProtocol` 추상화
- `Sources/DarwinForgeUI/WalkLab/Pilot/Tello/MockTelloLink.swift` — XCTest 용 in-memory mock (UDP socket 없음)
- `Sources/DarwinForgeUI/WalkLab/Pilot/Tello/TelloRCMapper.swift` — 순수 함수 매핑 + clamp + deadzone
- `Tests/DarwinForgeUITests/Pilot/TelloRCMapperTests.swift` — 13 tests (mapper 9 + mock 4)

**테스트 통과**: 867/867 (854 기존 + 13 신규)

## 13. 다음 단계 (구현 우선순위)

1. **WalkLabRCBridge.swift** — Tello stick → Walking module amplitude 송출 (Bus.setPosition 또는 onboard daemon 명령)
2. **PilotIntent 통합** — keyboard/Tello 모두 `PilotIntent` 정규화 (verification §7.1)
3. **Pilot HUD 확장** — Tello signal 강도 + lastRC stick 표시 + emergency 버튼
4. **WalkTrialStore 연계** — Tello stick 입력 자체를 trial parameter 로 기록 → Recommender 가 "사용자 선호 amplitude" 학습
5. **Mock E2E test** — MockTelloLink 로 stick → robot 명령 → trial 저장 end-to-end (실 hardware 없이)
6. **실 hardware 검증** — Tello EDU 구매 후 30분 prototype

## 14. 사용자 결정 항목

| 결정 | 옵션 | 권장 |
|---|---|---|
| Hardware | Tello / Tello EDU / 다른 DJI RC | **Tello EDU (~₩150k)** — SDK 안정 + swarm 지원 |
| 시뮬 우선? | Mock UDP / 실 hardware | **Mock 먼저** (이미 구현됨) — Phase 1+ 통합 검증 후 hardware |
| iOS bridge? | DJI 정식 RC 시 필수 | **불필요** (Tello 선택) |
| DJI 계정? | Mobile SDK 시 필요 | **불필요** (Tello 선택) |

## 15. 예상 latency

- Mock UDP localhost: <1ms
- 실 Tello Wi-Fi: 20-50ms
- Walking module amplitude 적용: 10ms
- **합계 30-60ms** — 사용자 조작 감지 한계 (100ms) 이내

## 16. 검증 출처 (research-analyst)

- https://www.ryzerobotics.com/tello/downloads (Tello SDK 2.0 PDF)
- https://github.com/dji-sdk/Tello-Python (공식 Python sample)
- https://github.com/damiafuentes/DJITelloPy (커뮤니티 wrapper)
- https://developer.dji.com/mobile-sdk/documentation/ (참고)
- https://developer.apple.com/documentation/network/nwconnection (Swift Network.framework)

