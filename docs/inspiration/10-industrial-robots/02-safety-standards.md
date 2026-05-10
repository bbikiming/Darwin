# 02. 산업 로봇 안전 표준 (Safety Standards)

> ISO 10218 / ISO/TS 15066 / ISO 13849 / IEC 62061 / KOSHA 가이드 등
> 산업 로봇 안전 표준 정리. DarwinForge 5계층 모델 (L1~L5) 매핑과
> 확장 후보 (L0 / L6) 제안.
>
> 출처 URL 필수, 미확인은 "확인 필요". 학술 인용 [Author Year].

## 표준 계층

```
규제 계층:
  ┌────────────────────────────────────────────┐
  │ EU Machinery Directive 2006/42/EC (CE)     │  ← 법
  │   ↓ 적합성 명시                             │
  │ ISO 12100  (위험 평가 일반)                 │  ← 상위 표준 A
  │   ↓                                         │
  │ ISO 10218-1/-2  (산업 로봇)                 │  ← B 표준
  │   ├─ ISO/TS 15066 (협동 로봇 추가)          │
  │   └─ ISO 13855 (안전 거리)                  │
  │   ↓                                         │
  │ ISO 13849-1 / IEC 62061 (제어 안전)         │  ← B 표준 (PL/SIL)
  │   └─ ISO 13850 (E-Stop)                     │
  │   ↓                                         │
  │ 제조사 자체 인증 (TÜV / DGUV / KOSHA)        │  ← C 인증
  └────────────────────────────────────────────┘
```

(출처: ISO 12100:2010 https://www.iso.org/standard/51528.html ; EU Machinery Regulation 2023/1230 https://eur-lex.europa.eu/eli/reg/2023/1230)

---

## 1) ISO 10218-1:2025 / -2:2025 — 산업 로봇 안전

### ISO 10218-1 (로봇 자체)

2025년 1월 개정판이 가장 최신. 2011 판을 14년 만에 통합 개정 (TS 15066를 일부 흡수).

**핵심 조항:**

- **§5.4** Operating Modes — Manual / Automatic 분리.
- **§5.7.5** Manual High-Speed Mode — 250 mm/s 이하 + 3-position enabling switch + 사용자 의도적 활성.
- **§5.10** Collaborative Operation — 4가지 모드:
  1. **Safety-rated monitored stop (SRMS)** — 인간 진입 시 즉시 정지, 진입 해제 후 자동 재가동.
  2. **Hand-guiding** — 인간이 로봇을 직접 손으로 끌어 가르침. 250 mm/s 이하.
  3. **Speed and Separation Monitoring (SSM)** — 거리 기반 속도 자동 조정 (ISO 13855 활용).
  4. **Power and Force Limiting (PFL)** — 충돌 시 임계 힘·압력 이하. **TS 15066이 임계값 표 제공**.

(출처: ISO 10218-1:2025 — https://www.iso.org/standard/73933.html)

### ISO 10218-2 (시스템·셀)

로봇 + 도구 + 안전 펜스 + HMI 통합 설계. **§5.5 Restricted Space** 개념이 우리 L2 Whitelist에 매핑.

(출처: ISO 10218-2:2025 — https://www.iso.org/standard/73934.html)

> ★ DarwinForge 적용:
> - **Operating Modes 분리** — DarwinForge에 Auto / Manual 2 모드 추가 검토. Auto = LLM이 직접 실행, Manual = 사용자가 수동 자세 잡기. 현재 우리는 Auto 우선이지만 Manual 모드 보강이 산업 표준 부합.
> - **§5.10.4 PFL** — 우리 L3 Safety Clip이 PFL의 정신적 등가. 단, 임계 "힘"이 아니라 "각도/속도 클램프" — 임피던스 의식.

---

## 2) ISO/TS 15066:2016 — 협동 로봇 추가 안전

ISO 10218 보완 기술 사양. 2016 발행 후 ISO 10218-1:2025에 일부 흡수되었으나 **임계 힘·압력 표 (Annex A)** 는 여전히 표준 참조 문서.

### 핵심 — Annex A 임계값 표

신체 부위별 **준-정적 충돌 (Quasi-static)** 과 **순간 충돌 (Transient)** 임계 힘 (단위: N) / 압력 (단위: N/cm²):

| 신체 부위 | 준-정적 압력 (N/cm²) | 준-정적 힘 (N) | 순간 압력 (N/cm²) | 순간 힘 (N) |
|-----------|:--------------------:|:---------------:|:------------------:|:------------:|
| 이마 | 130 | 130 | 175 | 175 |
| 후두부 | 110 | 130 | 195 | 175 |
| 어깨 관절 | 160 | 210 | 320 | 420 |
| 손바닥 | 260 | 140 | 540 | 280 |
| 손가락 | 220 | 140 | 460 | 280 |
| 등 | 180 | 210 | 360 | 420 |

(출처: ISO/TS 15066:2016 Annex A; Saenz et al. [Saenz 2018] "Methods for considering safety in design of robotics applications featuring human-robot collaboration", *Int J Adv Manuf Technol*. https://doi.org/10.1007/s00170-018-2022-x)

> ★ DarwinForge 적용:
> - **DARwIn-OP는 0.45 m, 2.9 kg, 모터 토크 ~2.5 N·m** — 최대 EE 속도 ~0.5 m/s 추정. PFL 임계값을 모두 만족 (어떤 신체 부위 충돌도 안전 영역 내). 그러나 **눈 (cornea)** 임계는 표 없음 — TS 15066 미커버, 추가 보호 필요.
> - **확인 필요**: DARwIn-OP 손목 압력 측정 실험 데이터 학술 논문 인용 가능 여부.

(출처: ISO/TS 15066:2016 — https://www.iso.org/standard/62996.html)

---

## 3) ISO 13849-1:2023 — Performance Level (PL)

안전 관련 제어 시스템 부품 요구사항. **PL = Performance Level a~e (5 단계, e가 최고).**

### PL 결정 매트릭스

위험 평가 입력:
- **S** Severity (가벼움 S1 / 중상 S2)
- **F** Frequency (드뭄 F1 / 자주 F2)
- **P** Possibility of avoidance (가능 P1 / 어려움 P2)

→ 조합으로 PLr (Required PL) 결정.

```
              F1            F2
       ┌──────────┬──────────┐
   P1  │  S1: a   │  S1: a   │
       │  S2: c   │  S2: d   │
       ├──────────┼──────────┤
   P2  │  S1: b   │  S1: b   │
       │  S2: d   │  S2: e   │
       └──────────┴──────────┘
```

(예: 협동 로봇은 S2 + F2 + P2 → **PLe** 권장이지만, 산업 cobot 대다수는 PLd로 인증.)

### PL ≈ 평균 위험한 고장률 (PFH_d)

| PL | PFH_d (시간당 위험한 고장 확률) | 산업 사례 |
|----|---------------------------------|-----------|
| a | 10⁻⁵ ~ 10⁻⁴ | 단순 가드 |
| b | 3×10⁻⁶ ~ 10⁻⁵ | 일반 인터록 |
| c | 10⁻⁶ ~ 3×10⁻⁶ | 안전 PLC |
| **d** | **10⁻⁷ ~ 10⁻⁶** | **협동 로봇 (UR/FANUC/ABB/KUKA/Yaskawa/Doosan)** |
| e | 10⁻⁸ ~ 10⁻⁷ | 자동차 에어백, 의료 |

(출처: ISO 13849-1:2023 §4.5.2 — https://www.iso.org/standard/85931.html)

### Category (구조 등급)

- **B / 1** — 단일 채널, 진단 없음.
- **2** — 단일 채널 + 주기 진단.
- **3** — 이중 채널 (이중화) + 부분 진단.
- **4** — 이중 채널 + 완전 진단 + 단일 고장 안전 유지.

협동 로봇은 거의 모두 **Cat 3**.

> ★ DarwinForge 적용:
> - **DarwinForge는 SW only — PL 인증 직접 어려움** (인증 비용 ~수억 원, 그리고 우리는 모터 안전 회로 직접 제어 안 함). 그러나 "PLd 동등 설계 원칙" — 즉 **이중 채널 + 진단 + Cat 3 구조** 를 흉내 가능. 예: walk 명령을 1) Claude 도구 호출 + 2) Swift `SafetyGate` 검증 두 채널을 병렬로 통과시키고 둘 중 하나라도 거부하면 정지.
> - **PL 등급 UI 뱃지** — 사용자가 "지금 시뮬 모드 = PLd 동등 / 실 로봇 = PLc 동등" 자기 선언 표시.

---

## 4) IEC 62061:2021 — SIL (Safety Integrity Level)

IEC 측 안전 표준. **SIL 1~3 (4는 IEC 61508 영역).** ISO 13849-1과 대응:

| SIL | PL 대응 | PFH_d |
|-----|:-------:|:------:|
| 1 | b/c | 10⁻⁶ ~ 10⁻⁵ |
| 2 | d | 10⁻⁷ ~ 10⁻⁶ |
| 3 | e | 10⁻⁸ ~ 10⁻⁷ |

(출처: IEC 62061:2021 §6 — https://webstore.iec.ch/publication/59927)

> ★ DarwinForge 적용:
> - **SIL 2 동등** = PLd 동등. 위 §3에서 동일 결론. **확인 필요**: macOS App Sandbox 자체가 SIL 등급 인정에 영향?

---

## 5) ISO 13850:2015 — Emergency Stop

(이미 채택, 본 문서 §6 안전 모델에서 인용) **Cat-1 stop** = "동력 유지하면서 감속 후 정지". DarwinForge `fc_emergency_stop` = 모든 토크 OFF SYNC_WRITE → 자세 풀려서 무릎 꿇음 (DARwIn-OP 정적 안정성 활용).

색상 표준:
- **Actuator** = RAL 3000 빨강 (#BF1E2E)
- **Background** = RAL 1023 노랑 (#FAD201)
- **Mushroom head 직경** ≥ 40 mm
- **사용자 손 위치 0.6~1.7 m**

DarwinForge SwiftUI 색상:
- `state.danger.light` = #FF3B30 (Apple 시스템 빨강)
- 노랑 외곽 = #FFCC00

(출처: ISO 13850:2015 — https://www.iso.org/standard/59970.html ; GT-Engineering EN ISO 13850 §4.4 — https://www.gt-engineering.it/en/technical-standards/en-iso-standards/emergency-sto-en-13850/4-4-emergency-stop-device/)

---

## 6) ISO 13855:2010 — 안전 거리 / 손 도달 속도

`S = (K × T) + C`

- **S** = 안전 거리 (mm)
- **K** = 손 도달 속도 = **2000 mm/s** (사람 손이 펜스 통과 시 표준 가정)
- **T** = 시스템 반응 시간 (s) = 감지 + 정지
- **C** = 침입 보정 (mm) — 광커튼 분해능 등.

예: 우리가 50 ms (Claude 응답 + Swift 디스패치) 반응이라면 `S = 2000 × 0.050 + 0 = 100 mm`. 즉 사람이 100 mm 이내로 들어오면 충돌 가능 영역. **DARwIn-OP는 가반하중 < 1 kg / 속도 < 0.5 m/s 라 사실상 무시 가능하나, 시연 시 VR 안전 영역 시각화 차용**.

(출처: ISO 13855:2010 — https://www.iso.org/standard/42205.html)

---

## 7) KOSHA Guide M-91-2012 — 한국 협동 로봇 안전

**한국산업안전보건공단 (KOSHA)** 발행. ISO 10218 + TS 15066 기반의 한국어 가이드라인.

핵심 조항:
- **§3** 위험 평가 의무 (ISO 12100 절차)
- **§4** 안전 작업 영역 표시 (바닥 노란선)
- **§5** 비상 정지 — 작업 위치 1 m 이내 (ISO 13850과 거의 동일)
- **§6** 작업자 교육 의무 (4시간 이상)
- **§7** 정기 점검 체크리스트

(출처: KOSHA Guide M-91-2012 — https://www.kosha.or.kr/ — 메인 페이지에서 "안전보건자료실 → KOSHA Guide" 검색. **확인 필요**: 정확한 직링크 URL 변경 가능성)

> ★ DarwinForge 적용:
> - **§7 정기 점검 체크리스트** — DarwinForge "안전 점검 모드" 시나리오 (`04-darwinforge-applications.md` §3) 직접 차용. 사용자가 매주 1회 모터/배터리/통신 점검.

---

## 8) DarwinForge 5계층 ↔ 산업 표준 매핑

| 우리 계층 | 매핑 표준 / 조항 | 우리 구현 | 산업 등가 |
|-----------|------------------|-----------|-----------|
| **L1 Refusal** | (학술 영역 — Constitutional AI [Bai 2022]) | Claude system prompt | 산업 표준 미존재. ISO 11161 SIS 사상 참고 |
| **L2 Whitelist** | ISO 10218-2 §5.5 Restricted Space | Swift IntentDispatcher (9 도구) | 산업 cobot의 Cartesian Zone 한정 |
| **L3 Safety Clip** | ISO/TS 15066 §5.5 PFL + ISO 10218-1 §5.10.5 속도 한계 | Swift SafetyGate (각도/속도 클램프) | UR PolyScope Safety Configuration |
| **L4 HITL** | ISO 10218-1:2025 §5.7.5 Manual High-Speed Mode + 3-position enabling | SwiftUI ToolCallCard | KUKA smartPAD 인에이블 스위치 (3-pos) |
| **L5 E-Stop** | ISO 13850:2015 Cat-1 controlled stop | EStopButton + ESC + ⌘. | UR / FANUC / ABB / KUKA / Yaskawa / Doosan 모두 동등 |

학술 [Inam 2018] "Towards safety analysis of interactions between human users and automated driving systems using STPA" — STPA (System-Theoretic Process Analysis) 가 우리 5계층 모델 검증 도구로 적합. (출처 https://doi.org/10.1109/ITSC.2018.8569410)

---

## 9) 확장 제안 — L0 / L6 추가 후보

현재 5계층 외에 **사전·사후 보강** 제안.

### L0 — Power Cut-off (전원 차단)

DarwinForge가 macOS 앱이라 직접 USB 전원 차단 불가. 그러나:

- **소프트 L0** = 앱 강제 종료 시 OS 측 USB 핫 플러그 → CM-740 `present_torque_enable` = 0 자동.
- **하드 L0** = USB 케이블 물리 분리 — 여전히 가장 확실. UI에 "케이블 위치" 안내 라벨 표시.
- **문서적 L0** = 사용자 매뉴얼에 "1순위 비상 = 케이블 분리" 명시.

매핑 표준: ISO 13850 §5.4 — "Mains disconnection" — 본 표준은 펜스 없이도 동력 완전 차단 1차 수단으로 권장.

### L6 — Post-mortem Analysis (사후 분석)

산업 cobot은 **Black Box** 기능 (UR `dashboard server`, FANUC `iRPickTool` 로그) 가 표준. 충돌·정지 사건 후 12시간 텔레메트리 자동 보존.

DarwinForge 제안:
- **사건 자동 캡처** — `~/Library/Logs/DarwinForge/incidents/<timestamp>/`
  - `telemetry.csv` (직전 60 s, 50 Hz)
  - `command_history.json` (직전 50 Claude 호출)
  - `system_state.json` (배터리 / 모터 상태 / FW 버전)
- **사용자 동의 후 익명 분석** — Sentry-style crash report opt-in.

매핑 표준: IEC 62443-3-3 SR 6.2 (감사 로그 보존) — **확인 필요**: 산업 보안 표준이 산업 안전 직접 매핑은 아니지만 사고 분석 의무는 동일 정신.

(출처: STPA 학술 — Leveson [Leveson 2011] *Engineering a Safer World*. https://mitpress.mit.edu/9780262533690/engineering-a-safer-world/ ; UR Dashboard Server — https://www.universal-robots.com/articles/ur/dashboard-server-cb-series-port-29999/)

---

---

## 10) OSHA 1910 Subpart O — 미국 산업 안전 관점

미국은 ISO 표준이 직접 법적 효력 없고 **OSHA (Occupational Safety and Health Administration)** 1910 Subpart O (Machinery and Machine Guarding) 가 적용. ISO 10218 / TS 15066 적합은 OSHA 일반 의무 (General Duty Clause §5(a)(1)) 충족의 한 방법.

ANSI/RIA R15.06-2012 → 2025 ANSI/RIA R15.06 개정 진행 중 (확인 필요). ISO 10218-1:2025를 기반으로 미국 시장 적합화.

(출처: OSHA 1910 Subpart O — https://www.osha.gov/laws-regs/regulations/standardnumber/1910/1910SubpartO ; ANSI/RIA R15.06 — https://www.automate.org/industry-insights/ria-r15-06-the-american-national-standard-for-industrial-robots-and-robot-systems-safety-requirements **확인 필요**)

> ★ DarwinForge 적용:
> - **미국 시장 출시 시 검토** — DARwIn-OP는 교육·연구용이라 OSHA 직접 적용 대상 아님. 그러나 학교·박물관 시연 시 General Duty Clause 적용 가능.

---

## 11) EN 775 (구식) — 점검

EN 775:1992 "Safety of industrial robots" — 1992 발행 후 **2008년 ISO 10218-1:2006 발행과 함께 EU에서 폐지**. 현재는 인용 가치 없으나 옛 매뉴얼·논문에 등장 시:

- EN 775 §6 = 현재 ISO 10218-1 §5에 해당
- EN 775 §7.3 = 현재 ISO 10218-1 §5.7 (Modes of Operation)

(출처: EN 775:1992 (폐지) — Wikipedia 또는 BSI 아카이브 ; CEN 조회 https://standards.cencenelec.eu/dyn/www/f?p=CEN:6:::NO:::)

> ★ DarwinForge 적용:
> - **인용 시 항상 "구 표준 (1992 폐지, ISO 10218 대체)" 명시**.

---

## 12) HRC Levels (Human-Robot Collaboration 1~4) — DGUV 분류

독일 직업조합 (Deutsche Gesetzliche Unfallversicherung, DGUV) 가 HRC 4단계 정의. 각 cobot 인증 시 "HRC 레벨 N 인증" 표시:

| HRC 레벨 | 정의 | 사례 |
|----------|------|------|
| 1 | 분리 작업 (펜스 분리) | 전통 산업 로봇 |
| 2 | 시퀀스 협업 (사람·로봇 다른 시간) | 컨베이어 + 인간 검수 |
| 3 | 공간 공유 (같은 공간, 다른 작업) | UR 5e + 작업자 옆 |
| 4 | 직접 협업 (같은 작업) | KUKA LBR iiwa hand-guiding |

(출처: DGUV Information 209-074 — https://publikationen.dguv.de/regelwerk/dguv-informationen/3499/kollaborierende-robotersysteme **확인 필요** ; Saenz et al. [Saenz 2018] 인용)

> ★ DarwinForge 적용:
> - **DARwIn-OP는 HRC 4 등급 동등** — 사용자가 직접 잡고 자세 잡기 (Pose Capture). 이를 UI에 표시: "HRC 4 동등 (직접 협업)".

---

## 학술 인용

- [Bai 2022] Bai et al. "Constitutional AI: Harmlessness from AI Feedback", *arXiv:2212.08073*. https://arxiv.org/abs/2212.08073
- [Saenz 2018] Saenz et al. "Methods for considering safety in design of robotics applications featuring human-robot collaboration", *Int J Adv Manuf Technol*. https://doi.org/10.1007/s00170-018-2022-x
- [Inam 2018] Inam et al. "Towards safety analysis of interactions between human users and automated driving systems using STPA", *IEEE ITSC*. https://doi.org/10.1109/ITSC.2018.8569410
- [Leveson 2011] Leveson "Engineering a Safer World", MIT Press.
- [Vasic 2013] Vasic and Billard "Safety issues in human-robot interactions", *IEEE ICRA*. https://doi.org/10.1109/ICRA.2013.6630576

## 출처 종합

- ISO 10218-1:2025 — https://www.iso.org/standard/73933.html
- ISO 10218-2:2025 — https://www.iso.org/standard/73934.html
- ISO/TS 15066:2016 — https://www.iso.org/standard/62996.html
- ISO 13849-1:2023 — https://www.iso.org/standard/85931.html
- ISO 13850:2015 — https://www.iso.org/standard/59970.html
- ISO 13855:2010 — https://www.iso.org/standard/42205.html
- IEC 62061:2021 — https://webstore.iec.ch/publication/59927
- ISO 12100:2010 — https://www.iso.org/standard/51528.html
- EU Machinery Regulation 2023/1230 — https://eur-lex.europa.eu/eli/reg/2023/1230
- KOSHA — https://www.kosha.or.kr/
- EN 775 (구식) — 1992 발행, **현재 폐지 (ISO 10218 대체)**. 참조 시 항상 "구 표준" 명시.
