# 10. 산업용 협동 로봇 (Cobot) + 안전 표준 + 티칭 UX

> DarwinForge는 ROBOTIS DARwIn-OP/OP2 (20-DOF 데스크탑 휴머노이드) 를
> macOS에서 자연어로 조종한다. 산업 현장의 협동 로봇 (Cobot) 은 십수 년
> 동안 "사람과 같은 공간에서 안전하게 움직이는 기계" 라는 매우 비슷한
> 문제를 풀어 왔으며, 그 결과물이 **ISO 10218-1/-2:2025 / ISO/TS 15066:2016 /
> ISO 13849-1:2023 / IEC 62061** 표준이다. DarwinForge의 5계층 안전 모델
> (L1 Refusal / L2 Whitelist / L3 Safety Clip / L4 HITL / L5 Hardware E-Stop)
> 을 이 표준에 비추어 보강하기 위한 자료.
>
> 출처 URL 필수, 미확인은 "확인 필요" 로 표기.

## 인덱스

| 파일 | 주제 | 분량 |
|------|------|------|
| [01-cobot-vendors.md](01-cobot-vendors.md) | 6대 협동 로봇 제조사 비교 (UR/FANUC CRX/ABB/KUKA/Yaskawa/Doosan) | ~1500 단어 |
| [02-safety-standards.md](02-safety-standards.md) | ISO 10218 / TS 15066 / 13849 / IEC 62061 / KOSHA, PL/SIL 등급 | ~1500 단어 |
| [03-ux-patterns.md](03-ux-patterns.md) | PolyScope / iPendant / FlexPendant / smartPAD / DART-Studio 비교 | ~1500 단어 |
| [04-darwinforge-applications.md](04-darwinforge-applications.md) | 우리 5계층 모델에 차용 후보 + 시연/교육/안전 점검 시나리오 | ~1500 단어 |

## 6대 제조사 + 안전 표준 매트릭스

| 제조사 | 대표 모델 | 자유도 | 가반하중 | 안전 등급 | 핵심 표준 | DarwinForge 차용도 |
|--------|-----------|:------:|:--------:|-----------|-----------|---------------------|
| **Universal Robots** | UR3e / UR5e / UR10e / UR16e / UR20 | 6 | 3-20 kg | PLd Cat 3 (ISO 13849-1) | ISO 10218-1, TS 15066 | ★★★ PolyScope 직관성 |
| **FANUC** | CRX-5iA / 10iA / 25iA | 6 | 5-30 kg | PLd Cat 3 (DCS) | ISO 10218, TS 15066 | ★★ 충돌 정지 강건함 |
| **ABB** | YuMi (IRB 14000) / GoFa CRB 15000 / SWIFTI CRB 1100 | 7+7 / 6 / 6 | 0.5-7 kg | PLd Cat 3 (SafeMove) | ISO 10218, TS 15066 | ★★ 양팔 동기 + 듀얼 암 |
| **KUKA** | LBR iiwa 7 R800 / 14 R820 (또한 LBR iisy) | 7 | 7-14 kg | PLd Cat 3 (HRC 인증) | ISO 10218, TS 15066 | ★★ 7-DOF 잉여 + 토크 센싱 |
| **Yaskawa** | Motoman HC10DTP / HC20DTP / HC30PL | 6 | 10-30 kg | PLd Cat 3 (FSU) | ISO 10218, TS 15066 | ★ 표준 충실, 보수적 |
| **Doosan Robotics** | M0609 / M1013 / H2017 / E0509 | 6 | 5-25 kg | PLd Cat 3 (TÜV SÜD) | ISO 10218, TS 15066, KOSHA M-91-2012 | ★★★ 한국 시장 정밀 + DART-Studio |

(출처: 각 제조사 공식 데이터시트 — 본문 `01-cobot-vendors.md` 인용)

## 안전 표준 — DarwinForge L1~L5 매핑 미리보기

| 우리 계층 | 산업 표준 매핑 후보 | 비고 |
|-----------|--------------------|------|
| **L1 Refusal** (Claude prompt) | (학술적 매핑 없음 — 새 영역) | LLM 단계의 "윤리 / 안전 거부", 산업 표준 미존재. ISO 11161 SIS 사상은 참고 |
| **L2 Whitelist** (tool 허용) | ISO 10218-2 §5.5 작업 영역 제한 (Restricted Space) | 가능한 동작 집합을 사전 정의 |
| **L3 Safety Clip** (속도/관절 제한) | ISO/TS 15066:2016 §5.5 PFL (Power & Force Limiting) | "충돌 시 임계 힘 이하" — 우리는 각도/속도 클램프로 근사 |
| **L4 HITL** (인간 승인) | ISO 10218-1:2025 §5.7.5 Manual High-Speed Mode + 3-position enabling switch | 시연/교육 모드 = 수동 모드 |
| **L5 E-Stop** (HW 정지) | ISO 13850:2015 + Cat-1 stop (이미 채택) | DarwinForge 좌상단 빨강 버튼 = 동등 |

(출처: ISO 10218-1:2025 — https://www.iso.org/standard/73933.html ; ISO/TS 15066:2016 — https://www.iso.org/standard/62996.html ; ISO 13850:2015 — https://www.iso.org/standard/59970.html)

## DarwinForge가 채택할 만한 항목 — 우선순위

### ★★★ 1순위 (즉시 적용 가능)

1. **PL (Performance Level) 표시 UI 뱃지** — UI 우상단에 현재 안전 등급 (PLd 등) 뱃지 추가. 사용자가 "지금 어느 단계 안전 모드?" 즉답 가능. UR의 Safety Configuration과 동등.
2. **Hand-guidance 차용 → "Pose Capture" 모드 강화** — DARwIn-OP에 force-torque sensor는 없으나, 토크 OFF 후 Dynamixel `present_load` (Protocol 2.0 Reg 126, MX-28) 로 외력 추정 가능. 사용자가 로봇 팔을 직접 잡고 자세 잡으면 자동 캡처.
3. **3-position enabling switch 메타포** — UI에 "비활성 / 활성 (저속) / 정상" 3단 상태 토글. 키보드 동시 눌림 (예: ⌘+Shift hold) 시에만 정상 속도. 산업 안전 표준 직접 수용.

### ★★ 2순위 (다음 분기)

4. **Safety-rated monitored stop (SS1/SS2, IEC 61800-5-2)** — 정지 시 모터 전원은 유지하되 자세 보존. DARwIn-OP에 "정지 후 자세 풀림" 문제 (gravity-induced fall) 해결.
5. **SSM (Speed and Separation Monitoring) 비유** — macOS Vision API로 사람 손 검출 시 자동 감속 (현재 DarwinForge에 비전 없음, 향후 적용).
6. **DART-Studio Skill Block** — Doosan의 블록 코딩 패턴. 자연어 → Skill Block 변환 후 검토 UI 제공.

### ★ 3순위 (장기)

7. **ISO 13855 안전 거리 계산식** — 사람-로봇 최소 거리 = (속도 × 반응시간 K) + C. DarwinForge 가상 안전 영역 (Safety Bubble) 시각화에 적용.
8. **IEC 62061 SIL 등급 동등 설계** — DarwinForge는 SW only 이므로 SIL 직접 인증 어려움. 그러나 "SIL 2 동등 설계 원칙" (이중 채널, 진단 커버리지) 채택 가능.
9. **L0 (전원 차단) + L6 (사후 분석) 추가** — `02-safety-standards.md` §4 참조. L0 = 물리 USB 분리 metaphor (앱 강제 종료 시), L6 = `~/Library/Logs/DarwinForge/` 구조화 사후 로그.

## 우리 현재 위치 (2026-05 기준)

이미 채택:
- ✅ **ISO 13850 Cat-1 e-stop** (L5, 좌상단 56pt 빨강+노랑)
- ✅ **HITL approve/edit/reject** (L4, LangGraph 패턴)
- ✅ **Tool whitelist** (L2, Anthropic strict tool_use)
- ✅ **Safety Clip 클램프** (L3, walk x/y/a 범위 + joint [1024, 3072])
- ✅ **Constitutional refusal** (L1, Claude system prompt)

후속 (이 카테고리에서 도출):
- ⏳ PL 등급 UI 뱃지
- ⏳ Hand-guidance 모드 (모터 `present_load` 기반)
- ⏳ 3-position enabling 메타포
- ⏳ L0 / L6 보강 — `02-safety-standards.md` §4
- ⏳ Safety Bubble 시각화 (ISO 13855)

## 사용 방법

이 디렉토리는 다음 순서로 읽으면 자연스럽다.

1. **01-cobot-vendors.md** — "산업 현장이 어떤 로봇을 쓰나" 기준선
2. **02-safety-standards.md** — "그들이 따르는 표준은 무엇인가"
3. **03-ux-patterns.md** — "그 로봇을 사람이 어떻게 가르치나"
4. **04-darwinforge-applications.md** — "그 중 우리에게 옮길 것"

## 출처

- ISO 10218-1:2025 — https://www.iso.org/standard/73933.html
- ISO 10218-2:2025 — https://www.iso.org/standard/73934.html
- ISO/TS 15066:2016 — https://www.iso.org/standard/62996.html
- ISO 13849-1:2023 — https://www.iso.org/standard/85931.html
- ISO 13850:2015 — https://www.iso.org/standard/59970.html
- ISO 13855:2010 — https://www.iso.org/standard/42205.html
- IEC 62061:2021 — https://webstore.iec.ch/publication/59927
- KOSHA Guide M-91-2012 — https://www.kosha.or.kr/ (한국산업안전보건공단)
- 본 README 작성 — 본 보고서, 2026-05-10
