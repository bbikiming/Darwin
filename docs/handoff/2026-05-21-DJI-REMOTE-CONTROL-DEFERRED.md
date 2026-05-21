# DJI 조종기 통합 — Deferred Plan

- **작성일**: 2026-05-21
- **상태**: Deferred (추후 구현)
- **선행 작업**: Phase 1 (WalkTrial), Phase 1.5 (Apply-Scope Badge), Phase 2 (Recommender) 완료 후
- **트리거**: 사용자 요청 — "원격 조종은 DJI 조종기로"

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
