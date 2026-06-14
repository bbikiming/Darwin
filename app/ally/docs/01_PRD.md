# DARwIn FPV — ROG Ally 네이티브 원격 조종 앱 PRD

- **상태**: **Draft (사용자 승인 전 구현 금지 게이트)** — 단, **W0 골격(`crates/df-wire` —
  와이어 순함수 + 골든 벡터 패리티)은 승인된 플랜 범위로 기진행** 중이다(§11).
- 작성일: 2026-06-13
- 대상: ROG Ally (Windows 11 핸드헬드, 7" 1080p 120Hz 터치, 내장 XInput 패드,
  Ryzen Z1 Extreme / 16GB)
- 제품명: **DARwIn FPV** (실행 파일 `darwin-fpv.exe`, 폴더 `app/ally/`) — D5
- 작성 기준: 본 리포 `docs/design/README.md` 표준 — "다른 세션이 추가 탐색 없이 착수 가능"
- 섹션 번호는 `docs/prd/README.md` 작성 규칙(§0 TL;DR / §10 검증 / §11 단계 / §13 미해결 /
  §14 결정)을 따른다.

---

## 0. TL;DR (한 줄 결론)

**검증된 세 조상(Mac 콕핏 HUD 문법 · RG G01 실기 매핑 · Switch 웹 콕핏 자산)을 불변
와이어 계약(`docs/ssh-parity-contract.md`) 위에 재조립해, ROG Ally 한 대에서
"영상 보며 조종 + 3D 합성 자세 + 3중 E-STOP"이 성립하는 Tauri 2 네이티브 게임형
콕핏을 만든다 — 이동 명령 생성과 E-STOP은 Rust 백엔드 단독(INV-2), 와이어 재발명 금지.**

---

## 1. 배경 · 근거 문서

| 문서 | 역할 |
|---|---|
| [`00_PRODUCT_BRIEF.md`](00_PRODUCT_BRIEF.md) | 제품 비전·사용자 시나리오 (본 PRD의 상위 문서) |
| [`docs/reports/2026-06-12-rog-ally-main-controller-feasibility.md`](../../../docs/reports/2026-06-12-rog-ally-main-controller-feasibility.md) | 타당성 분석 — Ally 전환 가능 판정, 재사용 자산 80%, ControlMaster 부재 등 Windows 주의점 |
| [`docs/ssh-parity-contract.md`](../../../docs/ssh-parity-contract.md) | **불변 와이어 계약 단일 진실원** (§A.2-TEL2, §B/§G.2 E-STOP, §C/§G.8 명령, §G.1 핸드셰이크) |
| [`docs/HARDWARE_VERIFICATION_PROTOCOL.md`](../../../docs/HARDWARE_VERIFICATION_PROTOCOL.md) | 실기(H등급) 검증 절차의 기반 프로토콜 (§9에서 연계) |

### 검증된 세 조상 (전부 이 리포에서 실기 검증)

1. **Mac DarwinForge 콕핏(SwiftUI)** — HUD 문법의 원천.
   원본: `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/Cockpit/CockpitStyle.swift`
   (안전 버튼 44pt — `safetyButtonH: CGFloat = 44`),
   `Pilot/PilotTokens.swift` (3색 속도게이지 `speedSafe/Caution/Danger`),
   `Pilot/PilotArmSlider.swift` (`armThreshold: CGFloat = 0.80`).
   5줄 상태블록(Controller/Mac/Robot/DXL/ARM), 래치 인디케이터(명령 vs 적용값),
   E-STOP rising-edge 즉시발화 불변식, 스틱 readout 모노스페이스, 3D 체이스캠(TEL2
   phase 위상 동기).
2. **Anbernic RG G01 직결 파일럿** (2026-06-13 실기 브링업 완료) — 매핑 수치의 원천.
   원본: `firmware-patches/walklab-brokerage/GamepadPilot.h` / `.cpp`.
   전 수치는 부록 A에 동결 표로 수록 (D2 — 변경 시 실기 재검증 필수).
3. **Switch 웹 콕핏** (`tools/switch-pilot`, Python + HTML 1280×720) — 화면 자산의 원천.
   원본: `tools/switch-pilot/web/styles.css` — CSS 토큰 검증값: bg `#111315`, panel
   `#1a1d20`, cyan `#00d6ee`, red `#ff4a55`, green `#62dc8e`, amber `#ffd166`,
   4px 그리드(`--space-1: 4px`), 레이아웃 토큰 `--topbar-h: 64px` /
   `--readout-h: 156px` / `--dock-h: 74px`.
   Three.js GLB 뷰어(`web/assets/darwin.glb` 750,396B ≈ 733KB), `df_udp.py` 와이어 구현,
   카메라 라이브 시 3D pause 정책(Ally에선 D4로 대체).

---

## 2. 목표 · 비목표

### 2.1 목표 (측정 가능)

| # | 목표 | 측정 기준 |
|---|---|---|
| G1 | Ally 단일 기기에서 무선 데모 조종 성립 | 핸드셰이크 후 UDP 20Hz 유효 송신율 ≥19Hz (로봇 `eff_hz` 기준) |
| G2 | E-STOP 3중화 + 무선 정지 계약 준수 | 물리 B / 터치 / SSH 파일 — 무선 ≤320ms 정지 (계약 §B) |
| G3 | 영상 보며 조종 | 보행 중 MJPEG 8–15fps 표시 + HUD 60fps 동시 유지 |
| G4 | 3D 합성 자세 뷰 (Mac 동등) | TEL2 phase 위상 동기 — Mac `visualPose` 방식과 동일 합성, "합성" 정직 라벨 |
| G5 | 게임기 UX | Armoury Crate 1클릭 기동, 콜드 스타트 ≤5s, 터치 의존 0의 패드 완주 |
| G6 | 안전 불변식 기계적 보증 | §7 INV-1~5 전부 코드 구조로 강제 (리뷰 체크리스트 항목화) |

### 2.2 비목표 (이번 범위 아님)

- **모션 저작·정밀 작업의 이주 금지** — Studio/Teach/Synth는 Mac 잔류 (타당성 보고서 §5).
- **관절각 실측 3D 금지** — TEL2 계약에 관절각이 없으므로(부록 A 타당성 보고서) 합성
  포즈가 계약상 상한. 계약 개정은 본 PRD 범위 밖.
- **와이어 계약 변경 금지** — 로봇 펌웨어·프로토콜 수정 없음. Ally는 순수 클라이언트.
- **G01 동글 직결 대체 아님** — Ally 내장 패드는 로봇 직결 불가. 최저 레이턴시 트랙
  (p95≤40ms)은 별도(handheld-direct-pilot-upgrade).
- **Windows 키오스크 봉인은 P2** (PKG-03) — 데모 성립 조건 아님.
- **음성·대화 기능 없음.**

---

## 3. 시스템 컨텍스트 (와이어 계약 — **계약 불변**, 재발명 금지)

단일 진실원: [`docs/ssh-parity-contract.md`](../../../docs/ssh-parity-contract.md).
아래 다이어그램의 모든 포맷·포트·주기는 그 계약의 **인용**이다. Ally 측에서 바꿀 수
있는 것은 없다 — 변경 필요 시 계약 문서에서 재협상한다.

```
┌─────────────────────── ROG Ally (darwin-fpv) ───────────────────────┐
│  Rust 백엔드 (안전·통신 전담 — INV-2)        WebView2 (표시 전용)     │
│  · 게임패드 250Hz 폴링 (ally-input)          · 1080p 풀스크린 게임 UI │
│  · 20Hz UDP TX / E-STOP 3연발 (ally-link)    · HUD·카메라·3D 렌더    │
│  · TEL2 수신 / ssh2 세션                     · 이동 명령 생성 비관여  │
└───────┬──────────────┬──────────────┬──────────────┬───────────────┘
        │ ①명령        │ ②E-STOP     │ ③텔레메트리  │ ④SSH (세션·폴백)
        ▼              ▼              ▲              ▼
   UDP :17374     UDP :17372     UDP (Ally가      SSH :22 (OpenSSH 5.9,
   "DFCMD {token}  "DF-ESTOP v1   /tmp/df-walklab- RSA only, user robotis)
   {seq} {line}"   {token} {ts}"  uplink 에        · 핸드셰이크: /tmp/df-walklab-
   20Hz, line =    ×3연발         "ip:port" 등록,    channel ← "TOKEN 17372 17374"
   14-token v1     (0/50/100ms)   기본 :17371)       (토큰 16 영숫자, 로봇 ≤1s 채택)
        │              │          TEL2 30Hz        · 폴백: /tmp/df-walklab-cmd
        │              │          (~140B≈4.2KB/s)    파일 5Hz (영구 보장)
        ▼              ▼              │            · E-STOP 폴백: touch
┌──────────────────────────────────────────────┐    /tmp/df-walklab-estop
│        DARwIn-OP2 온보드 브로커리지           │
│  (WalkLabBrokerage — 거버너·슬루·게이트 =     │  ⑤카메라: MJPEG
│   최종 클램프 소유. 워치독: 명령 신선도        │  http://robot:8080/?action=stream
│   600ms→제자리 슬루 / 2.5s→Stop / E-STOP만    │  320×240 JPEG q80, 보행 중
│   토크 컷)                                    │  ~8–15fps (C1 패치 실기 검증
└──────────────────────────────────────────────┘  2026-06-12)

접속 경로: 무선 192.168.0.33 / 유선 USB-C LAN → 192.168.123.1 (~166배 빠름)
```

핵심 인용 (계약 §):

- **명령 v1 14-token** (`§C`+`§G.8` — 영구):
  `{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable} {blevel} {pan} {tilt} {ball}`
- **E-STOP** (`§B`+`§G.2`): UDP 3연발 + SSH `touch /tmp/df-walklab-estop` + 로봇 워치독
  (명령 신선도) — 무선 ≤320ms 정지 계약. **이 경로에 스로틀·배칭·추가 홉 금지.**
- **TEL2** (`§A.2-TEL2`): `TEL2 {ts} {seq_applied} {phase} {x/y/a/period_lat} {IMU 6축}
  {FSR 8셀|-} {CoP|-} {fallen} {risk|-} {vdV} {active_source} {loop_ms}` —
  **관절각 없음** → 3D는 합성 포즈(phase 기반 FK + IMU 보정, Mac과 동일 방식).
- **핸드셰이크** (`§G.1`): ACK 무수신 1.5s → SSH 파일 5Hz 자동 폴백. 파일 경로는
  **영구 폴백** — UDP는 가산 채널.

---

## 4. 기능 요구사항

REQ-ID 체계: **CON**(연결) / **CPT**(콕핏) / **CTL**(조종) / **SAF**(안전) /
**TEL**(텔레메트리) / **CAM**(카메라) / **P3D**(3D) / **PKG**(패키징) /
**CFG**(설정) / **DBG**(디버그) / **SND**(사운드) / **REC**(레코더).

### 4.1 P0 — S1 데모 성립 조건

| ID | 요구 | 핵심 수치 | 근거 (조상 코드 경로) |
|---|---|---|---|
| CON-01 | 커넥트 화면: 무선 자동 탐색 + 직접 IP 입력 + SSH 키 상태 표시 | 자동 탐색 타임아웃 5s; 무선 기본 192.168.0.33 | `tools/switch-pilot/src/darwin_switch_agent/discovery.py`, `robot_ready.py` 키 프로비저닝 |
| CON-02 | 세션 시작 시퀀스: SSH 브로커리지 기동 → pilot-mode walklab 마커 → 핸드셰이크 → UDP 20Hz; ACK 무수신 시 자동 폴백 | ACK 무수신 1.5s → SSH 파일 5Hz 폴백; 핸드셰이크 토큰 16 영숫자, 로봇 ≤1s 채택 | 계약 §G.1·§D.4 (`walkLabRobotisStart`/`walkLabPersistMode`), `df_udp.py` |
| CTL-01 | G01 이동·헤드·턴 매핑 1:1 (수치 동결 — D2) | 부록 A 전체: 데드존 0.10, 곡선 1.35/1.7, 헤드 레이트 150/85°/s, 트리거 데드존 0.02, 턴 곡선 0.65, 터보 ×1.3, intensity^0.7 스케줄 | `firmware-patches/walklab-brokerage/GamepadPilot.h` (상수 전수), `.cpp` |
| CTL-02 | A=ARM / B=E-STOP / Y=복구 / X=볼트랙 (콕핏 컨텍스트 한정 — D3) | B는 rising edge 즉시; Y 복구 = 소프트 토크 램프 300→600→900→1023, 150ms 간격 (~0.6s) | `GamepadPilot.h` GP_BTN_*, `WalkLabTransport.h:208` `SG_SOFT_RAMP_VALUES` |
| SAF-01 | E-STOP 3중화: 물리 B(rising edge) + 터치 버튼 상시 + SSH 파일 — 전 경로 무지연 (INV-1) | 터치 타깃 200×200px 상시 표시; UDP ×3연발 0/50/100ms; 무선 ≤320ms | 계약 §B·§G.2; Mac `CockpitStyle.swift` 안전 위계 |
| SAF-02 | ARM 의식: 프리플라이트 자동 점검 → RT+A 0.8s 홀드 게이지 → 토크 램프 진행 표시; 미ARM 시 이동 명령 `enabled=0` 고정 | 홀드 0.8s; Mac 조상 = 슬라이더 80% 임계(`armThreshold 0.80`)·버튼 44pt | `Pilot/PilotArmSlider.swift:17`, `CockpitStyle.swift:47` |
| SAF-03 | failsafe UX: 패드 분리 / 앱 정지 / TEL 침묵 각각의 구분된 화면 상태 + "로봇은 자동 정지 중 (온보드 워치독)" 정직 고지 (INV-3·5) | 워치독 티어: 600ms 제자리 슬루 / 2.5s Stop (계약 §G.4); 이벤트 침묵 슬루 1500ms (G01 조상) | 계약 §G.4, `GamepadPilot.h` GP_SILENCE_SLEW_MS·3티어 failsafe |
| CAM-01 | 풀블리드 MJPEG 뷰: 4:3 fill-height + 프레임 age 표시 + 스톨 시 정직 표시 | 1080p에서 1440×1080 fill-height; 스톨 >1s → 흑백 freeze + 배지; 소스 320×240 q80, 보행 중 ~8–15fps | 타당성 보고서 §4.2 (C1 실기 검증 2026-06-12), `cockpit.py` CameraFrameProxy |
| TEL-01 | HUD 코어: 5줄 상태블록(Pad/Link/Robot/Source/ARM — Mac 문법 이식) + 래치 인디케이터(명령 vs 적용값) + 3색 속도게이지 + 스틱 readout(모노스페이스) + 전압 + RTT + eff_hz | TEL2 30Hz 소비; `x/y/a/period_lat`=적용값, 송신값과 병기; 3색 = safe/caution/danger | `CockpitStyle.swift`, `PilotTokens.swift`(speedSafe/Caution/Danger), 계약 §A.2-TEL2 |
| PKG-01 | Armoury Crate 등록 가능한 단일 exe + 박스아트 + 풀스크린 borderless | 단일 `darwin-fpv.exe`; 1080p borderless 풀스크린 기본 | Tauri 2 번들 (D1) |
| PKG-02 | 절전 차단 + 알림 억제 안내 | `SetThreadExecutionState(ES_CONTINUOUS\|ES_DISPLAY_REQUIRED)` 세션 중 유지; Focus Assist 안내 1회 | 타당성 보고서 §7-6 |
| CPT-01 | 게임패드 포커스 내비: 전 화면 패드만으로 완주 | 포커스 링 명시; 버튼 글리프 푸터; 터치 의존 0 (터치는 가산) | Switch 콕핏 키오스크 내비, Mac 콜아웃 패턴 |

보충:

- **CON-02 시퀀스 상세**: ① ssh2로 브로커리지 생존 확인(`walkLabVerifyMode` 계약 출력
  `DF_WALKLAB=active|idle|missing` 파싱) → ② 필요 시 기동 + E-STOP 플래그
  `rm -f`(재무장 계약 §B) → ③ `/tmp/df-walklab-channel`에 `"{token} 17372 17374"` 원자
  기록 → ④ `/tmp/df-walklab-uplink`에 Ally `"ip port\n"` **공백 구분** 등록(TEL2 수신,
  로봇 `fscanf("%63s %d")` — 콜론 금지 §G.1a, `WalkLabBrokerage.cpp:76 UPLINK_PATH`) →
  ⑤ DFCMD 20Hz 개시. 세션 종료 시 채널+업링크 `rm -f` 필수 — 계약 §G.1/§G.1a.
- **CTL-02 컨텍스트 분리 (D3)**: B=E-STOP은 **콕핏(조종) 화면 한정**. 메뉴·커넥트
  화면에서 B=뒤로(Windows 게임 관례). 콕핏 진입 중 오발 = 불필요한 정지 = 안전측
  오류라 허용.
- **SAF-02 프리플라이트 자동 점검 항목**: SSH 도달성, 브로커리지 생존, 핸드셰이크 채택
  (ACK), TEL2 수신, 전압 datum 존재, E-STOP 플래그 부재. 전 항목 녹색이어야 ARM 게이지
  활성.
- **SAF-03 3상태 구분**: (a) 패드 분리 → 즉시 zero 주입 + auto-disarm + "패드 분리"
  전면 배너, (b) 앱/백엔드 정지 → 로봇 워치독이 정지(클라이언트는 표시 불가 — 재기동
  화면에서 사후 고지), (c) TEL 침묵 → HUD 탈채도 + "텔레메트리 두절 — 로봇은 자동 정지
  중(온보드 워치독)" 배지. 셋 다 "로봇이 알아서 멈춘다"는 이중 방어 사실(INV-5)을
  화면에 명시.

### 4.2 P1 — 데모 품질

| ID | 요구 | 핵심 수치 | 근거 |
|---|---|---|---|
| P3D-01 | 3D 합성 포즈: TEL2 phase → forge-core walk FK + IMU 틸트 보정 + FSR/CoP 지지다각형 오버레이 + **"합성 포즈" 정직 라벨** | TEL2 30Hz; Mac `visualPose`와 동일 방식(타당성 §4.3); GLB 조상 `darwin.glb` ≈733KB | `WalkLab/WalkLabSession+Tick.swift:154`, `tools/switch-pilot/web/assets/` |
| P3D-02 | 뷰 사이클: CAM / 3D / PIP — View 버튼 1키 순환 | 전환 ≤200ms; PIP = 카메라+3D 동시 렌더 (D4) | Switch pause 정책의 상위 호환 (D4) |
| CON-03 | 유선 직결: USB-C LAN 자동 감지 + WIRED 배지 + 유선 우선 정렬 | 유선 192.168.123.1 (~166배 빠름); 탐색 목록 최상단 | CLAUDE.md 연결 모드, 타당성 §6 |
| CFG-01 | 매핑 화면: Mac controller-mapping-uiux의 콜아웃 + "눌러서 선택" 패턴 이식 — **수치 편집은 잠금 (D2)** | 읽기 전용 수치 표 + 실기 검증일 표기 | `docs/design/controller-mapping-uiux.md` |
| SND-01 | 사운드·햅틱 풀셋: ARM/disarm/E-STOP/복구/단절/래치 도달 | E-STOP 사운드는 발화 **후** 재생 (INV-1 — 경로 비차단) | Mac 콕핏 사운드 문법 |
| DBG-01 | 디버그 화면: loop_ms·패킷 통계(송신/ACK/드랍)·원시 TEL2·active_source | 토글 진입; 오버헤드 < 1ms/frame | 계약 §A.2-TEL2 `loop_ms`·`active_source` |

### 4.3 P2 — 후속

| ID | 요구 | 핵심 수치 | 근거 |
|---|---|---|---|
| PKG-03 | Windows 키오스크 (Assigned Access) 봉인 | 부팅 → darwin-fpv 단독 | Switch `tools/switch-appliance` 등가물 |
| CTL-03 | 백패들 M1/M2 E-STOP 보조 바인딩 | rising edge, B와 동일 경로 | Ally 백패들 하드웨어 |
| REC-01 | 파일럿 레코더: 입력+TEL2 타임라인 기록·재생 | 세션당 ≤50MB | Mac `CockpitPilotRecorder.swift` |
| CPT-02 | 120Hz 모드 (HUD/3D 120fps) | 전력 P1 예산과 트레이드오프 표기 | Ally 7" 120Hz 패널 |
| CON-04 | 멀티 로봇 브라우저 | 탐색 목록 n대 + 최근 연결 | discovery 확장 |

---

## 5. 비기능 요구 (NFR)

| ID | 항목 | 목표 | 측정 방법 |
|---|---|---|---|
| NFR-L1 | 입력→로봇 적용 (무선) | **p95 ≤ 400ms** | 로봇 `seq_applied` 에코 — 송신 타임스탬프 대조 (W1 게이트) |
| NFR-L2 | E-STOP → 로봇 정지 (무선) | **≤ 320ms** (계약 §B) | B 누름 → `Walking::Stop()` 로그 타임스탬프 |
| NFR-L3 | 내부: 패드 이벤트 → UDP 송신 | **p95 ≤ 10ms** | Rust 백엔드 계측 (ally-cli 벤치) |
| NFR-L4 | 카메라 glass-to-glass | **≤ 350ms 목표** (로봇 인코드 포함 — 실측 후 보정) | 로봇 앞 타이머 촬영 비교 |
| NFR-F1 | HUD 프레임레이트 | 60fps, 드랍 < 1% | WebView2 rAF 계측 (DBG-01) |
| NFR-P1 | 전력 | ≤ 15W 평균 · 배터리 ≥ 2.5h (40Wh 기준) | Windows 전력 카운터, 30분 시연 외삽 |
| NFR-P2 | 자원 | CPU < 25% · RAM < 500MB | 작업 관리자 / ETW |
| NFR-S1 | 콜드 스타트 | 실행 → 커넥트 화면 ≤ 5s | 스톱워치 실측 |

---

## 6. 아키텍처 · 폴더 구조 (참조)

`app/ally/` = **독립 Cargo workspace** (Mac 빌드 파이프라인과 비간섭):

| 크레이트 | 책임 | 비고 |
|---|---|---|
| `crates/df-wire` | 와이어 순함수 (DFCMD/DF-ESTOP/TEL2 인코드·디코드) + **골든 벡터 패리티** | **W0 — 기진행** |
| `crates/ally-link` | UDP TX/RX · ssh2 영속 세션 · 폴백 전환기 | E-STOP 송신 소유 |
| `crates/ally-input` | gilrs 250Hz 폴링 + G01 동결 매핑 + 안전 게이트(ARM/settle/failsafe) | 부록 A 수치 1:1 |
| `crates/ally-pose` | forge-core walk FK **직링크** (phase → 20관절 합성 포즈) | Rust-to-Rust, wasm 불요 |
| `crates/darwin-fpv` | Tauri 2 bin — 백엔드 조립 + WebView2 호스팅 | 단일 exe (PKG-01) |
| `crates/ally-cli` | 헤드리스 수용시험 (목 로봇 / 실기 벤치) | W1 게이트 도구 |
| `ui/` | 웹 프론트 (Switch 콕핏 자산 1080p 스케일업) — **표시 전용** | INV-2 |
| `assets/`, `scripts/` | GLB·박스아트 / 방화벽·전원 설정 스크립트 | §8 |

데이터 흐름 (한 방향): `ally-input → df-wire 인코드 → ally-link 송신`,
`ally-link 수신 → df-wire 디코드 → (ally-pose) → Tauri 이벤트 → ui 표시`.
**ui → 백엔드 방향은 메뉴 내비·설정·터치 E-STOP 트리거만** — 터치 E-STOP도 트리거일
뿐, 발화 경로(3연발+SSH)는 Rust가 소유한다.

---

## 7. 안전 불변식 (협상 불가)

| ID | 불변식 | 구현 강제 방법 |
|---|---|---|
| **INV-1** | **E-STOP 경로 무지연** — 디바운스·스로틀·컨플레이션·확인 다이얼로그·애니메이션 대기 일절 금지. rising edge 즉시 발화 | E-STOP 발화 함수에 await 지점 금지(동기 송신); 코드 리뷰 체크리스트 항목; Mac 불변식(`cockpit-latency-hardening` §S1) 승계 |
| **INV-2** | **이동 명령 생성은 Rust 단독** — webview 프리즈·크래시·JS 예외가 명령 안전에 영향 불가 | ui/는 명령 빌더 API 자체가 없음(타입 수준 차단); webview 사망 감지 시 백엔드는 무영향 지속 |
| **INV-3** | **패드 단절 = 즉시 zero 주입 + auto-disarm** | gilrs 단절 이벤트 → 같은 틱에 `enabled=0` 라인 송신 + ARM 해제 (G01 조상: ForceCommit + disarm + 정지 라인 Offer) |
| **INV-4** | **메뉴/일시정지 진입 = 이동 0 합성 동시** | 화면 상태 전이 함수가 zero 명령 송신과 원자적으로 묶임 — 전이 후 송신이 아니라 전이 = 송신 |
| **INV-5** | **클라이언트 사망 시 로봇 워치독이 정지(이중 방어)를 UI에 명시** | SAF-03 문구 고정: "로봇은 자동 정지 중 (온보드 워치독 600ms/2.5s)" — 과장 금지·생략 금지 |

E-STOP 의미론 추가 고정: E-STOP은 **모든 게이트(ARM·데드맨·컨텍스트)를 무시**하고
발화한다 — G01 조상의 "B rising, 데드맨 무시" + settle 규칙(같은 틱에서 E-STOP이
ARM/복구를 이긴다, `SettleArmed`)을 1:1 승계.

---

## 8. Windows 제약 · 대응

| 제약 | 영향 | 대응 |
|---|---|---|
| Win32-OpenSSH **ControlMaster 부재** | 매 SSH 호출 신규 핸드셰이크 — 로봇(Atom Z530, OpenSSH 5.9 RSA)은 수백 ms로 무거움 | **ssh2 crate 영속 세션** (W1 최우선 검증 — Q4). 실패 시 폴백: russh → plink 상주 프로세스 |
| 방화벽이 TEL2 인바운드 차단 | 텔레메트리 0 수신 | 설치/첫 실행 시 인바운드 규칙 자동 등록 (`scripts/`, netsh advfirewall — UDP 17371 또는 동적 포트) + 실패 시 안내 화면 |
| WiFi 어댑터 절전 | 무선 RTT 스파이크·폴백 빈발 | `scripts/`에 어댑터 절전 해제(전원 관리 체크 해제) 스크립트 + 세션 시작 시 상태 검사 |
| Windows Update 재부팅 | 데모 중 강제 중단 | 활성 시간(Active Hours) 설정 안내 + 데모 모드 진입 시 잔여 업데이트 경고 |
| Game Bar / 캡처 오버레이 | 풀스크린 포커스 탈취·프레임 드랍 | borderless(전용 풀스크린 아님)로 회피 + Game Bar 비활성 안내 |
| WebView2 런타임 의존 | 미설치 시 기동 불가 | Win11 기본 내장 — 부재 시 Evergreen Bootstrapper 안내 (오프라인 설치 옵션 P2) |
| 절전·화면 꺼짐 | 조종 중 화면 소등 | PKG-02: `SetThreadExecutionState` 세션 스코프 유지 |

---

## 9. 수용 기준 (AC)

형식: `AC-{REQ}-{n}` · Given/When/Then · 측정치 · 검증등급 **[U 단위 / I 통합 / H 실기]**.

**H등급 절차 연계**: 실기 AC는
[`docs/HARDWARE_VERIFICATION_PROTOCOL.md`](../../../docs/HARDWARE_VERIFICATION_PROTOCOL.md)
(v1, 2026-05-12 — 모션 합성용 3게이트 프로토콜)의 절차를 **준용**한다: G2 사전 점검
항목(CM 보드 응답·배터리 ≥11V·모터 온도 ≤50°C)과 G3 안전 사전 점검(주변 0.5m 장애물
제거·매트·e-stop 즉시 가용·카메라 녹화·손은 swing 범위 밖) + **게이트 간 사용자 명시
동의("실행 OK") — 게이트 건너뛰기 금지**. 본 PRD의 H 게이트는 거기에 "크래들 +
다리 토크 해제 + 배터리 차단 대기"(CLAUDE.md 하드웨어 안전)를 추가한다.

### 9.1 P0 수용 기준

| AC | Given / When / Then | 측정치 | 등급 |
|---|---|---|---|
| AC-CON-01-1 | Given 로봇과 같은 AP / When 커넥트 화면 진입 / Then 5s 내 로봇 발견 또는 타임아웃 후 직접 IP 입력 폼 + SSH 키 상태(있음/없음/권한오류) 표시 | 탐색 ≤5s | I |
| AC-CON-02-1 | Given SSH 도달 가능 / When 세션 시작 / Then 핸드셰이크 기록 후 ACK 수신 시 UDP 20Hz 개시, 로봇 `active_source=udp` | eff ≥19Hz | H |
| AC-CON-02-2 | Given UDP 차단(방화벽 시뮬) / When ACK 1.5s 무수신 / Then SSH 파일 5Hz 폴백 자동 전환 + HUD에 "FILE 5Hz" 정직 배지 | 전환 ≤2s | I |
| AC-CTL-01-1 | Given 동결 매핑 골든 벡터(부록 A에서 생성) / When ally-input 매핑 함수에 스틱·트리거 샘플 주입 / Then GamepadPilot.cpp 동일 입력 대비 출력 편차 0 (전 구간) | 편차 = 0 | U |
| AC-CTL-01-2 | Given ARM 상태 실기 / When 왼스틱 풀 전진 + RB 터보 / Then 로봇 `x_lat`가 거버너 클램프 내 최대치 도달, period 700→560ms 스케줄 관측 | TEL2 래치 확인 | H |
| AC-CTL-02-1 | Given 콕핏 화면 / When Y 누름(estop 플래그 존재 상태) / Then 복구 시퀀스 = 플래그 해제 + 토크 램프 300→600→900→1023 (150ms 간격) 진행 표시 | ~0.6s 램프 | H |
| AC-SAF-01-1 | Given 보행 중 / When 물리 B rising / Then DF-ESTOP 3연발(0/50/100ms) + SSH touch 병행 발화, 로봇 정지 | ≤320ms | H |
| AC-SAF-01-2 | Given 보행 중 / When 터치 E-STOP 탭 / Then 물리 B와 동일 경로(Rust 발화)로 동작 — JS 경유 지연 없음 | ≤320ms + 터치 타깃 200×200px | H |
| AC-SAF-01-3 | Given E-STOP 발화 코드 경로 / When 정적 검사 / Then 디바운스·스로틀·await·다이얼로그 부재 (INV-1) | 리뷰 체크리스트 통과 | U |
| AC-SAF-02-1 | Given 미ARM / When 스틱 입력 / Then 송신 라인 `enabled=0` 고정 + HUD에 LOCKED 표시 | 100% (목 로봇 캡처) | I |
| AC-SAF-02-2 | Given 프리플라이트 전 항목 녹색 / When RT+A 0.8s 홀드 / Then 게이지 충전 완료 시점에 ARM — 0.79s 릴리스는 미ARM | 0.8s ± 50ms | I |
| AC-SAF-03-1 | Given ARM + 보행 중 / When 패드 강제 분리 / Then 같은 틱 zero 주입 + auto-disarm + 전면 배너 (INV-3) | zero 송신 ≤1 프레임 | H |
| AC-SAF-03-2 | Given 송신 중단(백엔드 kill 시뮬) / When 600ms / 2.5s 경과 / Then 목 로봇 워치독 티어 판정 재현 + 재기동 화면에 워치독 고지 | 티어 600/2500ms | I |
| AC-CAM-01-1 | Given C1 패치 로봇 보행 중 / When 카메라 뷰 / Then 1440×1080 fill-height 표시 + 프레임 age 갱신 | 8–15fps 유지 | H |
| AC-CAM-01-2 | Given 스트림 스톨 / When 1s 경과 / Then 마지막 프레임 흑백 freeze + "STALL" 배지 (위장 금지) | 전환 ≤1.2s | I |
| AC-TEL-01-1 | Given TEL2 30Hz 수신 / When HUD 표시 / Then 상태블록 5줄 + 명령vs적용 래치 병기 + 3색 게이지 + 전압·RTT·eff_hz 전부 갱신 | 30Hz 소비, 드랍 무누적 | I |
| AC-TEL-01-2 | Given TEL2 골든 벡터(계약 §A.2-TEL2 예시 2종 포함) / When df-wire 파서 / Then FSR `-`/값, CoP `-`/값, risk `-` 전 분기 정확 파싱 | 파싱 일치 100% | U |
| AC-PKG-01-1 | Given Armoury Crate에 darwin-fpv 등록 / When 패드로 기동 / Then 박스아트 표시 + 풀스크린 borderless 진입 | 기동 ≤5s (NFR-S1) | H |
| AC-PKG-02-1 | Given 세션 활성 / When 화면 꺼짐 대기시간 경과 / Then 화면 유지 (`SetThreadExecutionState` 동작) | 10분 무소등 | I |
| AC-CPT-01-1 | Given 패드만(터치 금지) / When 커넥트→ARM→조종→E-STOP→복구→종료 전 흐름 / Then 전 화면 완주, 포커스 링 항상 식별 가능 | 터치 0회 | I |

### 9.2 P1 수용 기준 (대표)

| AC | Given / When / Then | 측정치 | 등급 |
|---|---|---|---|
| AC-P3D-01-1 | Given TEL2 phase 시퀀스 녹화분 / When ally-pose FK / Then Mac `visualPose` 동일 입력 대비 관절각 일치 (합성 동일성) | 편차 ≤0.1° | U |
| AC-P3D-01-2 | Given 실기 보행 / When 3D 뷰 / Then 발 디딤이 TEL2 phase와 위상 동기(Mac 동등) + "합성 포즈" 라벨 상시 | 육안 + phase 로그 | H |
| AC-P3D-02-1 | Given 카메라+3D / When PIP 모드 / Then 동시 렌더 60fps 유지 (D4) | 드랍 <1% | I |
| AC-CON-03-1 | Given USB-C LAN 연결 / When 탐색 / Then 192.168.123.1 자동 감지 + WIRED 배지 + 목록 최상단 | 감지 ≤3s | H |

---

## 10. 검증 계획

| 등급 | 수단 | 범위 |
|---|---|---|
| **U (단위)** | `cargo test` (workspace) | df-wire **골든 벡터 패리티**(DFCMD/DF-ESTOP/TEL2 — 계약 예시 문자열 + GamepadPilot.cpp/switch-pilot 캡처 산출물과 바이트 일치), ally-input 매핑 순함수(부록 A 전 상수 경계값), settle/failsafe 판정, ally-pose FK 동일성 |
| **I (통합)** | `ally-cli` + **루프백 UDP 목 로봇** | 목 로봇 = 핸드셰이크 채택·ACK·seq 단조 드랍·워치독 티어(600/2500ms)·TEL2 30Hz 송출을 재현하는 로컬 프로세스. 폴백 전환, ARM 게이트, 프레임 스톨, 헤드리스 수용시험 전 시나리오 |
| **H (실기)** | 웨이브별 실기 게이트 (§11) | §9 머리의 HARDWARE_VERIFICATION_PROTOCOL 준용 절차 + 사용자 입회. 측정 중 Mac 앱 종료(세션 경합 규칙 — 로봇은 단일 공유 자원) |

원칙: **H로만 검증 가능한 것을 U/I로 위장하지 않는다** (예: 무선 RTT 분포, 보행 중
카메라 fps). 역으로 U/I로 가능한 것을 실기로 미루지 않는다 (예: 매핑 패리티는 U).

---

## 11. 구현 단계 (웨이브)

| 웨이브 | 산출물 | 실기 게이트 (H) | 공수 |
|---|---|---|---|
| **W0** (기진행 — 이번 커밋) | `app/ally/` 골격 + `df-wire` 와이어 순함수 + 골든 벡터 패리티 테스트 | 없음 (U 전용) | 완료 처리 중 |
| **W1** 제어 코어 헤드리스 | ally-input(매핑+게이트) + ally-link(UDP/ssh2) + ally-cli 수용시험 + 목 로봇 | **유선 직결**: 핸드셰이크 채택 → 20Hz eff ≥19Hz · B→DF-ESTOP 발화 ≤150ms(유선) · 패드 분리 zero+disarm · 워치독 티어 트립 재현 · **ssh2 ↔ OpenSSH 5.9 접속 확인(Q4)** · 방화벽 규칙 자동 등록 동작 | 1주 |
| **W2** 콕핏 HUD + 카메라 | Tauri 셸 + 커넥트/콕핏 화면 + TEL-01 HUD + CAM-01 + SAF-01~03 UX + PKG-02 | **무선**: 보행 중 카메라 8–15fps + HUD 60fps 동시 · 터치 E-STOP ≤320ms · 폴백 전환 시연 | 1주 |
| **W3** 3D 합성 포즈 + PIP | ally-pose(forge-core 직링크) + GLB 리깅 + P3D-01/02 + CON-03 | Mac과 **동등 위상 동기** 확인 · 영상+3D PIP 60fps | 1–1.5주 |
| **W4** 게임화·내구·패키징 | PKG-01(박스아트·Armoury Crate) + SND-01 + CFG-01 + DBG-01 + 내구 | **30분 무중단 시연** · 장애 주입 매트릭스 전 항목 안전 수렴(패드 분리/UDP 차단/SSH 단절/webview kill/스톨) · Armoury Crate 1클릭 기동 · NFR-P1/P2 실측 | 1–2주 |

게이트 규칙: 각 웨이브의 H 게이트 통과 + 증거(측정 로그/영상) 기록 전에는 다음
웨이브 착수 금지. W1 게이트는 **유선 우선**(변수 격리 — 무선 링크 분산을 W2로 분리).

---

## 12. 리스크 요약

| 리스크 | 확률 | 완화 |
|---|---|---|
| ssh2 ↔ OpenSSH 5.9(RSA only) kex/hostkey 비호환 (Q4) | 중 | W1 첫 작업으로 검증; 폴백 사다리 russh → plink 상주 |
| 무선 링크 분산으로 NFR-L1 p95 초과 | 중 | 병목은 로봇 무선(타당성 §6) — 유선 경로(CON-03)와 분리 측정, 임계 재협상은 실측 후 |
| WebView2 렌더 부하로 60fps 미달 (PIP) | 저 | Ally x86 여력 충분(타당성 §2) — 미달 시 Switch pause 정책을 저전력 폴백으로 (D4) |
| Windows 환경 소음 (업데이트·오버레이·절전) | 중 | §8 대응표 + W4 30분 내구 게이트에서 검출 |
| 로봇 측 잔여 확인(보행 중 스트리밍 loop_ms 영향) | 저 | 기기 무관 항목 — W2 게이트에서 TEL2 `loop_ms`로 동시 실측 |

---

## 13. 미해결 질문 (Open Questions)

| Q | 질문 | 보류 사유 |
|---|---|---|
| Q1 | **데드맨 재도입 여부** — G01 실기 F10에서 LB 데드맨 해제(`GP_DEADMAN_REQUIRED=false`, 이동 게이트는 ARM만). 데모 관중 환경(아이 접근 등)에선 홀드형 데드맨 재고 여지 | 실기 조종감 트레이드오프라 책상 결정 불가 — W2 무선 실기에서 운용자 판단. 코드상 상수 1개 복원으로 토글 가능하게 설계 |
| Q2 | **Ally 내장 자이로로 헤드 보조 조준** (기기 기울임 → 헤드 미세 조정) | P2 후보 — 핵심 시나리오 비의존, 멀미·오발 위험 미평가. W4 이후 프로토타입으로만 |
| Q3 | **배터리 전압 경고 임계** — HUD 전압 게이지의 경고/위험 단계 값 | Mac L0 전압 게이트 임계값 확인 필요(`ConnectionStore` 안전 게이트) — Mac과 동일 임계 채택이 원칙이므로 값 확인 전 임의 결정 금지 |
| Q4 | **ssh2 crate ↔ 로봇 OpenSSH 5.9 호환** — 구식 kex/RSA-only 핸드셰이크 성립 여부 | Windows 실물 + 로봇 실기 조합에서만 확정 가능 — **W1 게이트 1번 항목** |

---

## 14. 결정 사항 (Decisions)

| D# | 결정 | 근거 / 비고 |
|---|---|---|
| **D1** | 기술 스택 = **Tauri 2 하이브리드** — Rust 백엔드가 안전·통신 전담(패드 250Hz 폴링·20Hz UDP TX·E-STOP 3연발·TEL2 수신·ssh2 세션), WebView2 풀스크린 게임 UI(Switch 웹 콕핏 자산 1080p 스케일업). webview JS는 표시 전용(INV-2) | **사용자 승인 2026-06-13.** 대안 비교: **egui** — 순수 Rust로 INV-2 자연 충족하나 Switch 웹 콕핏 자산(HTML/CSS/Three.js) 전량 폐기·재작성 비용. **Bevy** — 게임 룩 최강이나 콕핏 HUD엔 과체급, 학습·공수 최대 |
| **D2** | **RG G01 실기 검증 매핑 수치 1:1 동결** (부록 A) — 변경 시 실기 재검증 필수. CFG-01 매핑 화면은 읽기 전용 | 2026-06-13 실기 브링업에서 확정된 조종감 — 수치는 코드가 아니라 실기의 산물 |
| **D3** | **콕핏 B=E-STOP · 메뉴 B=뒤로** (컨텍스트 분리) | 콕핏 오발 = 불필요한 정지 = 안전측 오류라 허용. 단일 전역 바인딩보다 게임 관례(메뉴 뒤로) 유지가 CPT-01에 유리 |
| **D4** | **카메라 + 3D PIP 동시 렌더** — Switch의 "카메라 라이브 시 3D pause" 정책은 저전력 폴백으로 강등 | Ally x86 성능 근거(타당성 §2.2 — MJPEG 디코드+3D 동시 처리 무리 없음). 미달 실측 시 폴백 자동 전환 |
| **D5** | 제품명 **DARwIn FPV** (exe `darwin-fpv`, 폴더 `app/ally/`) | 사용자 선택 |

---

## 부록 A. RG G01 동결 매핑 표 (D2 — 단일 출처 `GamepadPilot.h`, 2026-06-13 실기 확정)

| 구분 | 항목 | 동결 수치 |
|---|---|---|
| 이동 | 왼스틱 = 전후(`x`)/횡(`y`) | 데드존 0.10 (잔여 재스케일·부호 보존), 곡선 1.35 |
| 이동 한계 (UI 클램프) | stride / side / turn | 38mm / 22mm / 12° — **최종 클램프는 로봇 거버너(O2)** |
| 턴 | LT/RT 차분 아날로그 (`RT−LT`) | 트리거 데드존 0.02, 저압 부스트 \|d\|^0.65, RT=우회전 |
| 헤드 | 오른스틱 = **레이트 제어** (놓으면 유지) | pan 150°/s · tilt 85°/s (풀스틱), 곡선 1.7, 클램프 pan ±70° / tilt ±35°, 적분 dt 상한 200ms |
| 버튼 | A=ARM · B=E-STOP(rising, 게이트 무시) · Y=복구 · X=볼트랙 토글 · RB=터보 ×1.3 · LB=미사용(데드맨 해제, Q1) | settle: 같은 틱에서 E-STOP이 ARM/복구를 이김 |
| 복구(Y) | 소프트 토크 램프 | 300→600→900→1023, 150ms 간격 (~0.6s) — `WalkLabTransport.h SG_SOFT_RAMP_VALUES` |
| 게이트 스케줄 | intensity^0.7 | period 700→560ms, foot 18→40mm (정지 시 default 600/40), hip 13° 고정 |
| failsafe | 3티어 | ① 버튼 release 합성(이벤트 경로) ② 장치 소실(ENODEV) → 강제 커밋+disarm+정지 라인 ③ 이벤트 침묵 ≥1500ms → 제자리 슬루 (Stop은 로봇 워치독 2.5s 인계) |
| 신선도 | local 우선권 / 재공급 | 마지막 이벤트 ≤1s / 보유 상태 50ms 재공급 |

부호 계약 (로봇 좌표: X+=전진, Y+=좌횡, A+=좌회전, pan+=좌, tilt+=상):
`GP_SIGN_STRIDE/SIDE/TURN/TILT/PAN = −1` (XInput raw 부호 → 로봇 부호 변환 — 실측 확정).
Ally의 gilrs 축 부호가 evdev raw와 다를 수 있으므로 **ally-input은 "로봇 부호 기준
출력"을 골든 벡터로 패리티 검증**한다 (AC-CTL-01-1).

## 부록 B. 화면 인벤토리 (참조)

커넥트(CON-01) → 프리플라이트+ARM(SAF-02) → 콕핏(CAM/3D/PIP + HUD, CTL/SAF/TEL) →
일시정지 메뉴(INV-4) → 설정(CFG-01, 읽기 전용 매핑) → 디버그(DBG-01).
전 화면 패드 완주(CPT-01), 콕핏 한정 B=E-STOP(D3).
