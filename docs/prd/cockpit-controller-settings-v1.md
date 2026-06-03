# PRD — Cockpit 조종기 세팅 & 키매핑 고도화 (v1)

> 상태: **Draft (미구현, 승인 대기)** · 작성 2026-06-03 · 대상: DarwinForge Cockpit(조종 시뮬)
> 연계: `docs/reports/cockpit-controller-keymapping-design.md`(아키텍처 설계), `docs/reports/gamepad-direct-control-feasibility.md`(연결 타당성), `connection-modes.md`(보행↔관절편집 배타)
> 트리거: 사용자가 Anbernic **RG G01** 컨트롤러 구매 → "조종 시뮬에 연결 + 키매핑"을 최상급으로 고도화 요구. 현재 키매핑 GUI 품질/사용성 미흡.

---

## 1. 배경 & 문제

DarwinForge Cockpit은 현재 DJI FPV RC3 전용 바인딩(`CockpitDJIBindingProfile`)과 하드코딩된 GCController 버튼 매핑(`CockpitGameControllerWatcher`)만 갖는다. 한계:

- **범용성 부재**: DJI 외 컨트롤러(Xbox/DualSense/RG G01 등)는 재매핑 UI가 없고 버튼이 코드에 고정.
- **GUI 품질/사용성 미흡**: 시각적 컨트롤러 다이어그램·라이브 입력 확인·곡선/데드존 편집·conflict 경고·프리셋·캘리브레이션 등 업계 표준 기능 부재.
- **로봇 안전 미반영**: 데드맨(enable-hold), 연결 끊김 failsafe, E-Stop 잠금 등 텔레옵 안전 패턴이 키매핑 레벨에 없음.

이 PRD는 위를 업계 베스트 프랙티스(§3)와 macOS 네이티브 역량(§9)에 근거해 **"최상급 조종기 세팅"** 으로 재설계한다.

---

## 2. 목표 / 비목표

### 목표 (Goals)
- G1. **모든 표준 게임패드**(GCController 인식 + raw HID 폴백)를 Cockpit에 연결.
- G2. **세계 수준의 키매핑 UX**: 라이브 다이어그램, press-to-bind, 곡선/데드존 에디터, conflict 감지, 프리셋/프로파일.
- G3. **로봇 안전 1급 통합**: 데드맨 enable-hold, 연결 끊김 failsafe, E-Stop 잠금, 모드 전환 게이트, hold-to-confirm.
- G4. **PC 유무 양립**: 같은 의미 매핑(액션 추상화)을 Mac 경로·로봇 직결 경로 양쪽에서 일관 사용.
- G5. **배송 전 선구현**: 하드웨어 없이 가능한 부분(로직·UI·테스트)을 Mock/가상 컨트롤러로 미리 완성(§10).

### 비목표 (Non-Goals)
- N1. 커뮤니티 프로파일 온라인 공유(워크샵). (로컬 JSON import/export까지만)
- N2. 매크로 스크립팅 엔진(복잡 시퀀스). (P3 백로그)
- N3. 로봇 직결 온보드 조이스틱 리더 구현(별도 문서 §gamepad-direct §7 범위).
- N4. 자이로 기반 모션 조종(하드웨어 의존, 실기 검증 후 별도 결정).

---

## 3. 레퍼런스 종합 — "무엇을 훔치는가"

| 출처 | 가져올 강점 | 적용 |
|---|---|---|
| **Steam Input** | 액션 추상화 모델 + Action Set Layer | `CockpitAction` 기반, 모드별(보행/헤드/관절) 세트 + 전역 안전 레이어 |
| **reWASD** | Activator(single/long/double/start/release) + Shift Layer + toggle 1탭 해제 | 모드 전환·E-Stop을 activator로, 모드 고착 방지 |
| **DS4Windows** | Anti-Deadzone + Custom 곡선 그래픽 에디터 | 보행 스틱 반응성, 곡선 캔버스 |
| **AntiMicroX** | Deadzone+MaxZone+Diagonal 3슬라이더 (macOS 오픈소스) | 데드존 UI 단순성 |
| **Razer/G HUB** | 실물 SVG 다이어그램 + 클릭-투-바인드 | 다이어그램 중앙 배치 + 라벨 오버레이 |
| **Xbox Accessories** | "길게 눌러 즉시 재할당" 최소 마찰 | Listen 캡처 기본 플로우 |
| **Game Accessibility Guidelines / Xbox AG-107** | full remap, preset+custom, hold↔toggle, deadzone/sensitivity, 색맹안전 | 접근성 요구(§7 TIER) |
| **QGroundControl / Mission Planner** | 캘리브레이션 마법사(min/max/center), expo, failsafe 동작 선택 | 캘리브레이션·곡선·연결끊김 failsafe |
| **Betaflight Configurator** | Receiver 라이브 채널 모니터, Modes 범위 스위치, Rates 실시간 곡선 | 라이브 진단 패널, 모드 스위치, 곡선 프리뷰 |
| **ROS teleop_twist_joy** | **enable_button(데드맨)** — 누르는 동안만 명령, 떼면 즉시 0속도. turbo는 조합 | 핵심 안전 패턴 SAFE-01 |
| **ISO 10218 / Teach Pendant** | 3-포지션 enable, E-Stop 단독 트리거 금지, hold 다단계 | 안전 설계 철학(소프트 적용) |
| **차별화(업계 공백)** | 어떤 리매퍼도 "역방향 중복(같은 액션 2버튼)·미할당 안전액션"을 경고하지 않음 | **Conflict 감지 = DarwinForge 차별점** |

---

## 4. 페르소나 & 시나리오

- **P1 운영자(PC 있음)**: Mac 시뮬 화면 보며 RG G01로 로봇 조종. 첫 연결 시 자동 감지→기본 프리셋→필요시 재매핑.
- **P2 현장 운영자(PC 없음)**: 로봇에 2.4G 동글 직결. 같은 의미 매핑을 로봇 온보드에서 사용(매핑 프로파일 공유).
- **P3 세팅 빌더**: 정밀 조종을 위해 expo/데드존/감도를 튜닝하고 프로파일로 저장·공유(JSON).
- **시나리오 핵심**: ① 첫 연결 온보딩 ② press-to-bind 재매핑 ③ 캘리브레이션 ④ 곡선/데드존 튜닝 ⑤ 라이브 테스트 ⑥ 안전(데드맨/E-Stop/failsafe) ⑦ 프로파일 저장/복원.

---

## 5. 설계 원칙 (cross-cutting)

1. **액션 추상화**: 바인딩은 물리 입력이 아니라 의미 액션(`CockpitAction`)을 가리킨다. 컨트롤러 종류와 무관.
2. **안전 우선**: 안전 액션(E-Stop, 데드맨)은 일반 매핑보다 상위 규칙. 모드/레이어가 바뀌어도 항상 유효.
3. **불변성**: 바인딩 프로파일은 값 타입(Codable). 편집은 새 프로파일 반환(mutation 금지).
4. **라이브 피드백**: 모든 설정은 즉시 시각 반영(다이어그램 하이라이트, 곡선 프리뷰, 데드존 원).
5. **점진 공개**: 기본은 단순(프리셋+Listen), 고급(곡선/activator/conflict)은 펼침.
6. **접근성**: 색+형태 병행, 키보드만으로 편집, KO/EN.
7. **Mac 무변경 핵심**: `CockpitState` 주입 API(이미 source-agnostic)는 변경하지 않는다.

---

## 6. 기능 요구사항 (Functional Requirements)

> 우선순위: **P0 필수 / P1 강력권장 / P2 접근성·완성도 / P3 백로그**

### 6.1 연결 & 감지 (CONN)
| ID | P | 요구 |
|---|---|---|
| CONN-01 | P0 | GCController 우선 감지, 연결/해제 알림 구독, 다중 컨트롤러 목록. |
| CONN-02 | P0 | `productCategory`로 모델 식별(폴백 `vendorName`), HUD에 표시(`setController(name:)`). |
| CONN-03 | P1 | GCController 미인식 시 **IOKit raw HID 폴백** 경로(`DJIVirtualJoystickHIDClient` 일반화). |
| CONN-04 | P1 | 배터리 잔량 표시(`GCDeviceBattery`, 미지원 시 숨김). |
| CONN-05 | P0 | 첫 연결 **온보딩**: "컨트롤러 감지됨"→기본 프리셋 자동 적용→재매핑 안내. |

### 6.2 입력 추상화 & 동적 열거 (INPUT)
| ID | P | 요구 |
|---|---|---|
| INPUT-01 | P0 | `CockpitControllerSource` 프로토콜로 GC/HID 통합, 정규화 `ControllerSnapshot`(axes[-1..1], buttons[bool]). |
| INPUT-02 | P1 | `GCPhysicalInputProfile`의 `buttons/axes/dpads` 딕셔너리 순회로 **하드코딩 없이 전체 입력 요소 열거**(macOS 11+). |
| INPUT-03 | P0 | 30Hz 폴링(`capture()`) + 이벤트(`valueChangedHandler`) 병행: 제어=폴링, 라이브 하이라이트=이벤트. |

### 6.3 바인딩 캡처 (BIND)
| ID | P | 요구 |
|---|---|---|
| BIND-01 | P0 | **Listen(press-to-bind)**: "캡처" 버튼→입력 누름→자동 할당. 최대 magnitude 축/버튼 우선(`ControllerBindingCapture`). |
| BIND-02 | P0 | **수동 드롭다운**: 축 인덱스/polarity/버튼 직접 선택(미연결·정밀용). |
| BIND-03 | P1 | **다이어그램 클릭-투-바인드**: 다이어그램 버튼 클릭→해당 입력 편집 패널. |
| BIND-04 | P0 | 액션당 1바인딩 기본 + 1입력 다중 액션 금지(swap). 안전 액션 unbound 거부. |

### 6.4 시각 컨트롤러 다이어그램 (DIAG)
| ID | P | 요구 |
|---|---|---|
| DIAG-01 | P0 | 모델별 SVG 다이어그램 자동 선택(Xbox레이아웃=RG G01, DualSense, Switch Pro). |
| DIAG-02 | P0 | **라이브 입력 하이라이트**: 누른 버튼/스틱 위치/트리거 비율 실시간 반영(네이티브 이벤트). |
| DIAG-03 | P1 | 현재 바인딩 라벨을 **양쪽 날개(wing callout)** 로 배치(라벨 충돌 회피). |
| DIAG-04 | P2 | 활성 강조는 **색+형태 병행**(테두리 굵기/크기), 색맹 안전. |

### 6.5 액션 모델 & 컨텍스트 세트 (ACT)
| ID | P | 요구 |
|---|---|---|
| ACT-01 | P0 | `CockpitAction`(이동/회전/머리/안전 13종) 재사용. |
| ACT-02 | P1 | **Action Set = 조종 모드**(예: 보행 / 헤드·카메라 / (해당시)관절편집). 세트 전환 시 다이어그램 라벨 갱신. |
| ACT-03 | P1 | **전역 안전 레이어**: E-Stop·데드맨은 모든 세트 공통, 세트 전환에 영향받지 않음. |
| ACT-04 | P2 | 오버라이드된 입력 vs 기본 입력을 시각 구분(Steam 레이어 그레이아웃 패턴). |

### 6.6 곡선·데드존·감도 (CURVE)
| ID | P | 요구 |
|---|---|---|
| CURVE-01 | P0 | 축별 **Inner Deadzone**(드리프트 차단) + **Anti-Deadzone**(데드존 직후 최소 출력) + **Max Zone**. |
| CURVE-02 | P0 | 축별 **Invert**(반전) 체크. |
| CURVE-03 | P1 | **Expo / 감도**: 중앙 둔감→미세조종, 끝단 최대. 프리셋(Linear/Quadratic/Cubic) + Custom 곡선 캔버스(베지에 핸들). |
| CURVE-04 | P0 | **라이브 프리뷰**: 2D XY 플롯에 현재 스틱 점 + 데드존 원 + 곡선 오버레이, 슬라이더 변경 즉시 반영. |
| CURVE-05 | P1 | 정밀/표준 **빠른 전환**(높은 expo↔낮은 expo). |

### 6.7 Activator / 활성화 모드 (ACTV)
| ID | P | 요구 |
|---|---|---|
| ACTV-01 | P0 | Single(누르는 동안) / Start(누름 순간) / Release(뗌 순간) / **Long Press**(임계 ms) / **Toggle**(1탭 해제) / Double. |
| ACTV-02 | P1 | Toggle로 켠 동작은 single 1탭으로 해제(reWASD 패턴). |
| ACTV-03 | P2 | Shift Layer(modifier hold) — 물리 버튼 논리 확장(P2/P3). |

### 6.8 안전 바인딩 (SAFE) — **최우선**
| ID | P | 요구 | 근거 |
|---|---|---|---|
| SAFE-01 | P0 | **데드맨 enable-hold**(옵션, 기본 ON 권장): 지정 버튼 누르는 동안만 이동 명령, **떼면 즉시 0속도**. | teleop_twist_joy, ISO 10218 |
| SAFE-02 | P0 | **E-Stop 전용 버튼**: 즉시 정지, 모든 모드/레이어 동일 위치, **unbound 불가(잠금)**. | Teach pendant |
| SAFE-03 | P0 | **연결 끊김 failsafe**: USB/BT 끊김 감지 **<1초** → E-Stop 동등(Freeze/Sit/SafeStop 선택). | ArduPilot/PX4 |
| SAFE-04 | P1 | **Arming 전제조건**: 캘리브레이션 완료 + 입력 중립 + 자세 정상일 때만 "활성화". | Betaflight |
| SAFE-05 | P1 | **모드 전환 게이트**: 정지 상태(speed<threshold)에서만 모드 전환 허용. 이동 중 차단. | Betaflight Modes, connection-modes.md |
| SAFE-06 | P1 | **위험 동작 Hold-to-Confirm**: 토크 활성화·모드 전환은 1~1.5초 홀드 + 진행 링 + 확인 토스트. | UE5/ISO 10218 |
| SAFE-07 | P1 | **Turbo는 조합 입력**: enable + turbo 동시에만 고속. 단일 버튼 turbo 금지. | teleop_twist_joy |
| SAFE-08 | P2 | 데드맨 60초+ 연속 눌림 감지 시 "고정 의심" 경고. | DENSO RC8 원칙 |
| SAFE-09 | P0 | 볼트래킹 ON 시 수동 헤드 입력 무시(자율 점유)를 HUD 명시. | gamepad-direct §6 |

### 6.9 캘리브레이션 마법사 (CAL)
| ID | P | 요구 |
|---|---|---|
| CAL-01 | P1 | 단계별 마법사: Start→각 축 최대/최소 이동→중립→완료. 각 단계 시각 지시. |
| CAL-02 | P1 | 축 min/max/center **자동 캡처**, 저가 패드 편차 보정. |
| CAL-03 | P1 | 축별 deadzone 드래그 조정 + 실시간 확인. |
| CAL-04 | P0 | **중복 바인딩 경고**: 같은 축/버튼 이중 할당, 같은 액션 다중 할당 즉시 경고. |
| CAL-05 | P1 | 저장 전 유효성 검사(모든 축 정상 범위). |

### 6.10 라이브 테스트 / 진단 (TEST)
| ID | P | 요구 |
|---|---|---|
| TEST-01 | P0 | 상시 라이브 입력 모니터: 스틱 2D XY + 수치, 트리거 바(0~1), 버튼 하이라이트. |
| TEST-02 | P1 | 데드존 원 오버레이로 현재 입력이 데드존 내/외 시각화. |
| TEST-03 | P1 | 연결 상태(녹/적) + 끊김 시 예상 failsafe 동작 안내. |
| TEST-04 | P2 | 햅틱 테스트 버튼(`GCDeviceHaptics`, 미지원 시 숨김), 입력→명령 지연 표시. |

### 6.11 프로파일 & 프리셋 (PROF)
| ID | P | 요구 |
|---|---|---|
| PROF-01 | P0 | 기본 프리셋 ≥3(Standard/Precision/Lefty) + 커스텀 슬롯(이름 지정). |
| PROF-02 | P0 | 프로파일별 **기본값 복원** 1클릭. |
| PROF-03 | P0 | UserDefaults 영속(`cockpit.controller.binding.profile.v1`) + JSON **import/export**(공유·PC↔로봇 이식). |
| PROF-04 | P1 | 연결 모델/로봇(OP1·OP2)에 따라 프로파일 자동 선택. |

### 6.12 햅틱/배터리/LED (DEV)
| ID | P | 요구 |
|---|---|---|
| DEV-01 | P2 | 햅틱 피드백(E-Stop·모드전환 확인 진동), 미지원 컨트롤러는 무음 폴백. |
| DEV-02 | P2 | LED 색(DualSense)으로 모드 상태 표시(미지원 시 무시). |
| DEV-03 | P3 | 자이로(`GCMotion`) — **실기 검증 후 조건부**(DualSense rotationRate=0 보고 있음). |

### 6.13 접근성 & i18n (A11Y)
| ID | P | 요구 |
|---|---|---|
| A11Y-01 | P2 | 키보드만으로 모든 바인딩 편집(Tab/Enter/Arrow). |
| A11Y-02 | P2 | 색맹 안전 하이라이트(색+형태), 하이라이트 색 사용자 선택. |
| A11Y-03 | P2 | VoiceOver 레이블, KO/EN 현지화. |

---

## 7. 비기능 요구사항 (NFR)
- **지연**: 입력→cockpit 주입 30Hz, 추가 지연 <16ms. 라이브 하이라이트 60fps 목표.
- **안정성**: 컨트롤러 끊김/재연결에 크래시 없이 failsafe. 빈/이상 스냅샷 방어.
- **테스트성**: 로직(매핑/곡선/conflict/캘리브레이션)은 순수 함수 + 단위테스트 80%+. `MockControllerSource`/`GCController.withExtendedGamepad()`로 하드웨어 없이 UI까지 검증.
- **영속/이식성**: JSON 스키마 버전드(`v1`), 마이그레이션 가능.
- **현지화**: 모든 사용자 문자열 KO/EN.

---

## 8. UX / 화면 설계

### 8.1 진입점
Cockpit 툴바 "🎮 컨트롤러" 버튼 → **컨트롤러 세팅 시트**(약 1100×760, 기존 DJI 시트 구조 확장).

### 8.2 레이아웃 (3-column, 기존 자산 재사용)
```
┌───────────────┬───────────────────────────┬──────────────────────┐
│ 액션 목록      │   컨트롤러 다이어그램(SVG)   │  Inspector            │
│ (그룹: 이동/   │   라이브 하이라이트 +      │  - 선택 입력의 바인딩  │
│  회전/머리/    │   wing callout 라벨        │  - Activator 선택     │
│  안전)         │   클릭→편집                │  - 곡선/데드존(2D프리뷰)│
│ 각 액션=바인딩 │   [모드 세트 탭]           │  - 감도/Invert        │
│ 카드           │                           │  - Listen / 수동       │
├───────────────┴───────────────────────────┴──────────────────────┤
│ 하단 바: 연결상태·배터리 | 프리셋▼ | 캘리브레이션 | 라이브테스트 | 복원/저장 │
└────────────────────────────────────────────────────────────────────┘
```

### 8.3 핵심 플로우
- **첫 연결**: 감지 토스트→기본 프리셋 적용→"원하면 재매핑" 안내(2단계).
- **재매핑**: 액션 카드 "Listen"→입력 누름→자동 할당→conflict 시 인라인 경고.
- **캘리브레이션**: 마법사 5~7단계(각 축 min/max/center/deadzone).
- **튜닝**: Inspector에서 데드존/anti-deadzone/expo 슬라이더→2D 플롯 실시간.
- **라이브 테스트**: 하단 "테스트" 패널 항상 접근, 스틱/트리거/버튼 실시간.
- **위험 동작**: 토크/모드 전환은 hold-to-confirm 진행 링.

---

## 9. macOS 구현 가능성 매트릭스 (근거)

| PRD 기능 | 판정 | 방법 / 비고 |
|---|---|---|
| 라이브 입력 하이라이트 | **A 네이티브** | `valueChangedHandler` (macOS 10.9+) |
| Press-to-bind 캡처 | **A 네이티브** | `physicalInputProfile.buttons` 순회 + `pressedChangedHandler` (macOS 11+) |
| 전체 입력 요소 동적 열거 | **A 네이티브** | `GCPhysicalInputProfile` 딕셔너리(macOS 11+). LiveInput 일관성 버그 주의 |
| 배터리 표시 | **A 네이티브** | `GCDeviceBattery`(Xbox 일부 nil → 숨김 폴백) |
| 모델명 | **A 네이티브** | `productCategory` 우선(`vendorName`은 nil 빈번) |
| 햅틱/LED | **A 네이티브** | `GCDeviceHaptics`/`GCDeviceLight`(macOS 11+, 기기 의존) |
| 곡선/데드존 변환 | **B 자체구현** | 순수 함수(API 없음) — 테스트 용이 |
| 앱 레벨 리매핑 | **B 자체구현** | macOS 시스템 리매핑 UI 없음 → 앱이 매핑 테이블 소유(당위) |
| 미인식 패드 폴백 | **B 자체구현** | IOKit IOHIDManager(Obj-C 브릿지) |
| 가상 컨트롤러 테스트 | **B 자체구현** | `GCVirtualController`는 iOS 전용 → macOS는 `GCController.withExtendedGamepad()` |
| 자이로 | **C 불확실** | `GCMotion` 존재하나 DualSense rotationRate=0 보고 → 실기 검증 |

→ **핵심 기능(연결·열거·캡처·하이라이트·배터리)은 전부 네이티브.** 곡선/리매핑/폴백/가상테스트는 자체구현이며 **하드웨어 없이 테스트 가능**.

---

## 10. 배송 전 선구현 가능 범위 (하드웨어 불요)

컨트롤러 도착 전 **거의 전부**를 Mock/가상 컨트롤러로 만들고 테스트할 수 있다:

| 선구현 항목 | 방법 | 하드웨어 필요? |
|---|---|---|
| 바인딩/프로파일/프리셋 데이터 모델 + Codable | 순수 값 타입 + 단위테스트 | ❌ |
| 곡선/데드존/anti-deadzone/expo/invert 변환 | 순수 함수 + 단위테스트(경계값) | ❌ |
| Conflict 감지 로직 | 순수 함수 + 테스트 | ❌ |
| 캘리브레이션 상태머신 | 순수 로직 + 테스트 | ❌ |
| `CockpitControllerSource` 프로토콜 + `MockControllerSource` | 프로토콜 + 목 구현 | ❌ |
| `GCControllerSource` | 실 구현(검증은 가상 컨트롤러) | ⚠️ `withExtendedGamepad()`로 가능 |
| 바인딩 시트 UI(다이어그램·Inspector·Listen·곡선 캔버스) | 가상 컨트롤러로 라이브 동작 | ⚠️ 가상으로 가능 |
| 안전 로직(데드맨 0속도, failsafe 타임아웃, hold-to-confirm) | 순수 로직 + 테스트 | ❌ |
| 기본 프리셋(Xbox/DualSense/SwitchPro 레이아웃) | 정적 데이터 | ❌ |
| 영속화 store | UserDefaults + 테스트 | ❌ |

**도착 후에만 가능**: ① RG G01이 GC로 잡히는지 실측(안 잡히면 HID 폴백+descriptor) ② 실기 지연/데드존 튜닝 ③ 햅틱/자이로 기기별 확인.

→ **배송 전 P0/P1의 ~85%를 구현·테스트 완료 가능.**

---

## 11. 단계별 마일스톤 & 수용 기준 (TDD)

| 단계 | 산출 | 수용 기준(증거) |
|---|---|---|
| M1 코어 로직 ✅ | 바인딩/프로파일/곡선/conflict/캘리브레이션 순수 로직 | **완료 2026-06-03** — 6 소스 + 4 테스트 파일, `swift build` 성공, **59 tests GREEN**, 스펙 리뷰 통과 |
| M2 입력 추상화 | `CockpitControllerSource`+`Mock`+`GCControllerSource` | 가상 컨트롤러로 snapshot→cockpit 주입 검증 |
| M3 안전 | 데드맨/failsafe/hold-confirm/E-Stop 잠금 | "떼면 0속도", "끊김<1초 정지" 테스트 통과 |
| M4 UI | 바인딩 시트(다이어그램/Inspector/Listen/곡선/테스트) | 가상 컨트롤러로 라이브 하이라이트·바인딩·곡선 프리뷰 동작 |
| M5 프로파일 | 프리셋/저장/복원/JSON I/O | 라운드트립 직렬화 테스트 |
| M6 실기(도착 후) | RG G01 인식 경로 확정, 튜닝, (필요시)HID 폴백 | 실기 조종 영상 + 지연 측정 |
| M7 리뷰 | code-reviewer/security + 스펙 리뷰 | CRITICAL/HIGH 0 |

---

## 12. 리스크 / 오픈 이슈
- RG G01의 macOS 인식 경로(GC vs HID) **실기 전 불확실** → M6에서 확정, HID 폴백은 조건부.
- 모델명 "RG001"은 RG G01 **추정** — 실물 모델명 확인 필요.
- 자이로/햅틱은 기기 의존 → 조건부 기능.
- 데드맨 enable-hold 기본 ON 여부는 사용성 vs 안전 트레이드오프 → 기본 ON + 사용자 해제 가능 제안(결정 필요).
- macOS GCPhysicalInputProfile/LiveInput 일관성 버그 보고 → 폴링 경로로 회피.

---

## 13. 결정 완료 (2026-06-03, 사용자 승인)
1. **데드맨 enable-hold 기본값** → **ON** (안전 우선). 사용자 설정에서 해제 가능.
2. **연결 끊김 failsafe 기본 동작** → **Freeze** (보행 즉시정지 + 현 자세 유지).
3. **Action Set(모드) 범위** → **보행 + 헤드/카메라** (관절편집은 추후 확장).
4. **선구현 착수** → **M1~M5 즉시 시작** (TDD, 하드웨어 없이 가상 컨트롤러로 검증).

---

## 14. 출처 (대표)
- Steam Input: [Action Set Layers](https://partner.steamgames.com/doc/features/steam_controller/action_set_layers), [Activators](https://partner.steamgames.com/doc/features/steam_controller/activators)
- [reWASD Activators](https://help.rewasd.com/basic-functions/activators.html) · [DS4Windows Deadzone](https://ds4-windows.com/controller-deadzone/) · [AntiMicroX](https://antimicrox.net/blog/configuration-guide.html)
- [Game Accessibility Guidelines — Remapping](https://gameaccessibilityguidelines.com/allow-controls-to-be-remapped-reconfigured/) · [Xbox AG-107](https://learn.microsoft.com/en-us/gaming/accessibility/xbox-accessibility-guidelines/107)
- [QGC Joystick Setup](https://docs.qgroundcontrol.com/master/en/qgc-user-guide/setup_view/joystick.html) · [ArduPilot GCS Failsafe](https://ardupilot.org/copter/docs/gcs-failsafe.html) · [Betaflight Rates](https://oscarliang.com/rates/)
- [ROS teleop_twist_joy(enable_button)](https://docs.ros.org/en/iron/p/teleop_twist_joy/) · [Deadman Switch](https://www.robots.com/articles/why-the-deadman-switch-is-important)
- macOS: [GCPhysicalInputProfile/elements](https://developer.apple.com/documentation/gamecontroller/gccontrollerelement/aliases) · [GCDeviceHaptics](https://developer.apple.com/documentation/gamecontroller/gcdevicehaptics) · [WWDC21 10081](https://developer.apple.com/videos/play/wwdc2021/10081/)
- 코드 근거: `CockpitDJIBindingProfile.swift`, `CockpitGameControllerWatcher.swift`, `CockpitState.swift`, `VirtualJoystickMapper.swift`, `CockpitDJIBindingSheet.swift`, `DJIVirtualJoystickHIDClient.swift`
