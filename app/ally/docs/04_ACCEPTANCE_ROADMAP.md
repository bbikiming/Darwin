# DARwIn FPV — 04 수용 기준·로드맵·실기 게이트

> 상태: **BINDING** (D1 Tauri 2 하이브리드 · D2 매핑 동결 · D4 제품명 — 사용자 승인 완료, 변경 금지)
> 작성: 2026-06-13 · 대상: app/ally/ (ROG Ally 전용 DARwIn-OP2 원격 조종 네이티브 앱, exe `darwin-fpv`)
> 기준: docs/design/README.md — "다른 세션이 추가 탐색 없이 착수 가능"
>
> 단일 진실원(재발명 금지):
> - 와이어 계약 = `docs/ssh-parity-contract.md` (§A.2-TEL2 텔레메트리 · §B/§G.2 E-STOP · §C/§G.3 명령 · §G.1 핸드셰이크 · §G.4 워치독)
> - 매핑 수치 = `firmware-patches/walklab-brokerage/GamepadPilot.h` (2026-06-13 실기 검증 동결 — D2)
> - 실기 사실 = `docs/reports/2026-06-13-rgg01-bringup.md` (F9 교훈·운용 노트·잔여 항목)
> - 자매 문서 = `app/ally/docs/01~03` (PRD·아키텍처·콕핏 UX — 병행 작성)

**TL;DR — 5웨이브 총 4.5~6주. W0(이번 커밋)은 로봇 불필요(골든 벡터 패리티만), W1부터
실기 게이트가 붙는다(유선→무선→보행→내구 순). 모든 게이트 판정은 ACK 가 아니라
물리 거동으로 한다(F9 교훈: ACK enabled=1 ≠ 서보 기록). 게이트 건너뛰기 금지.**

---

## §1 웨이브 총괄 표

| 웨이브 | 범위 | 산출물(핵심) | 게이트 종류 | 게이트 합격선(요약) | 기간 |
|---|---|---|---|---|---|
| **W0** | 골격·와이어 패리티 (이번 커밋) | Cargo workspace + `crates/df-wire`(순함수) + 골든 벡터 | **로봇 불필요** — macOS `cargo test` | Python(`tools/switch-pilot/src/darwin_switch_agent/df_udp.py`) ↔ Rust **바이트/캐노니컬 동일성 100%** | 이번 |
| **W1** | 제어 코어 헤드리스 | `ally-link` + `ally-input` + `ally-cli` | **유선 실기**(USB-C LAN → 192.168.123.1) | 20Hz 지속 eff_hz≥19 · E-STOP 와이어 송출 내부 ≤150ms · 정지 계약 ≤320ms · 패드 단절→zero+disarm | 1주 |
| **W2** | Tauri 콕핏 HUD + 카메라 | `darwin-fpv`(Tauri 2 bin) + `ui/`(WebView2 풀스크린) | **무선 실기**(192.168.0.33) | 보행 중 영상 8–15fps + HUD 60fps 동시 · 입력→송신 지터 ±5ms · 터치 E-STOP 병행 · 30분 soak | 1주 |
| **W3** | 3D 합성 포즈 + PIP | `ally-pose`(forge-core walk FK 직링크) + Three.js GLB 뷰어 | 무선 실기(보행) | 보행 위상 동기 Mac 앱 동등 · 영상+3D PIP 60fps | 1–1.5주 |
| **W4** | 게임화·내구·패키징 | 패키징(MSI/포터블) · 절전/포커스 핸들링 · 장애 주입 | **내구 실기** | 30분 연속 데모 무중단 · §3 매트릭스 전 항목 안전 수렴 · Armoury Crate 기동 · 절전 시 E-STOP 발화 | 1–2주 |

합계: **4.5~6주**. 의존은 직렬(W0→W1→W2→W3→W4)이되, W3 의 `ally-pose` 순수 FK 부분은
W2 와 병행 착수 가능(게이트만 직렬).

공유 불변식(전 웨이브 — docs/design/README.md §3 승계):
- **INV-1**: E-STOP 경로에 스로틀·배칭·코얼레싱·추가 비동기 홉 금지. B 버튼 rising-edge 즉시발화.
- **INV-2**: webview JS 는 표시 전용 — 이동 명령 생성·E-STOP 경로 비관여. 터치 E-STOP 포함
  모든 안전 동작은 Rust 백엔드가 발화하고 JS 는 invoke 트리거만.
- **INV-3**: 파일 폴백 영구 보존 — UDP 는 가산 채널 (`/tmp/df-walklab-cmd` 5Hz ·
  `/tmp/df-walklab-estop` flag · `/tmp/df-walklab-telemetry` TEL v1 5Hz).
- **INV-4**: D2 매핑 수치 동결 — 변경 시 실기 재검증 필수.
- **INV-5**: 로봇 측 거버너(O2)가 최종 클램프 소유 — 클라이언트 클램프(38/22/12)는 UX 레이어.

---

## §2 웨이브별 상세

### W0 — 골격·와이어 패리티 (이번 커밋)

**산출물**
- `app/ally/` Cargo workspace: `crates/{df-wire, ally-link, ally-input, ally-pose, darwin-fpv, ally-cli}` + `ui/` + `assets/` + `scripts/` (link/input/pose/fpv/cli 는 빈 스텁 허용)
- `crates/df-wire` — 와이어 **순함수**만(소켓·IO 없음):
  - 명령 직렬화: `DFCMD {token} {seq} {line}` — line = 14-token v1
    `{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable} {blevel} {pan} {tilt} {ball}` (계약 §C·§G.3)
  - E-STOP 데이터그램: `DF-ESTOP v1 {token} {ts}` (계약 §G.2)
  - 핸드셰이크 라인: `{token} {estop_port} {cmd_port}\n` — token 16 영숫자 (계약 §G.1)
  - TEL v1(≥11 토큰) / TEL2(가변 토큰 — FSR·CoP 그룹 `-` 처리) 파서 (계약 §A.2·§A.2-TEL2)
  - ACK 파서: `ACK {seq} {t_rx}` (계약 §G.3)
- `tests/fixtures/` 골든 벡터: Python `df_udp.py` 가 생성한 실제 바이트 캡처 + 계약 §A.2-TEL2 의
  예시 라인 2종(FSR 있음/없음) 포함

**수용 기준**
- [ ] 골든 벡터 패리티 100%: 직렬화 출력 바이트가 Python 산출과 동일, 파싱 결과 캐노니컬
      표현(필드별 비교)이 동일 — 1벡터라도 불일치 시 W0 미완료
- [ ] 경계 케이스: TEL2 FSR `-`/CoP `-`, risk `-`, 범위 밖 값 → `None`(드롭, 패닉 금지 —
      계약 §A.3 "out-of-range → return nil" 패리티)
- [ ] macOS `cargo test --manifest-path app/ally/Cargo.toml` 전부 통과 (증거: 통과 개수 제시)
- [ ] `cargo fmt --check` + `cargo clippy -D warnings` 통과

**선행 조건**: 없음(로봇·Windows 불필요). **리스크**: Python float 포맷(`%.2f`)과 Rust 포맷
불일치 — 골든 벡터가 바이트 단위라 즉시 검출됨.

---

### W1 — 제어 코어 헤드리스 (유선 실기 게이트 · 1주)

**산출물**
- `ally-link`: UDP 명령 TX 20Hz(:17374) · E-STOP ×3연발 0/50/100ms(:17372) + SSH
  `touch /tmp/df-walklab-estop` 병행 · TEL2 RX(기본 :17371, `/tmp/df-walklab-uplink` 에
  "ip:port" 등록) · ssh2 세션(핸드셰이크 `/tmp/df-walklab-channel` 기록, ACK 무수신 1.5s 시
  SSH 파일 폴백 5Hz)
- `ally-input`: gilrs 250Hz 폴링 + RG G01 검증 매핑 1:1(아래 동결 수치) + 안전 게이트
  (A=ARM 단일 게이트 · B=E-STOP rising-edge 즉시발화 · Y=복구 · failsafe 3티어:
  버튼 release 합성/장치 소실/이벤트 침묵 1500ms 슬루 정지)
- `ally-cli`: 헤드리스 수용시험 러너 — 핸드셰이크→20Hz 송신→TEL2 수신→E-STOP 의 각
  시나리오를 측정치와 함께 stdout 보고(W1 게이트의 측정 도구를 겸함)

**동결 매핑 수치** (`GamepadPilot.h` 실측 확정 — INV-4, 변경 금지):

| 항목 | 값 | 원본 상수 |
|---|---|---|
| 스틱 데드존 / 이동 곡선 / 헤드 곡선 | 0.10 / 1.35 / 1.7 | `GP_DEADZONE`·`GP_DRIVE_CURVE`·`GP_HEAD_CURVE` |
| 헤드 레이트 (pan/tilt) | 150°/s / 85°/s, 클램프 ±70°/±35°, dt 상한 200ms | `GP_HEAD_PAN_RATE_DPS`·`GP_HEAD_TILT_RATE_DPS`·`GP_MAX_HEAD_*`·`GP_MAP_DT_MAX_MS` |
| LT/RT 차분 턴 | 트리거 데드존 0.02, 저압 부스트 \|d\|^0.65 | `GP_TRIGGER_DEADZONE`·`GP_TURN_CURVE` |
| 터보(RB) | ×1.3 | `GP_TURBO_SCALE` |
| UI 클램프 (stride/side/turn) | 38mm / 22mm / 12° | `GP_MAX_*` (최종 클램프는 로봇 거버너 — INV-5) |
| 강도 스케줄 | intensity^0.7 → period 700→560ms, foot 18→40mm | `GamepadPilot.cpp:211`·`GP_GAIT_*` |
| 데드맨 | **해제**(이동 게이트는 ARM 단일) | `GP_DEADMAN_REQUIRED=false` (실기 F10b) |
| 침묵 임계 | 1500ms | `GP_SILENCE_SLEW_MS` |
| 부호 5종 | STRIDE/SIDE/TURN/TILT/PAN 전부 −1.0 | `GP_SIGN_*` (브링업 라운드4 실측 확정) |

주의: 원본은 evdev(스틱 ±32767·트리거 0..255), Ally 는 XInput(gilrs) — **정규화 후 [-1,1]
공간에서 위 수치가 1:1** 이어야 한다. 축 원시 범위 차이는 어댑터 레이어에서 흡수하고,
정규화 이후 곡선·데드존·레이트 수치는 바이트 단위 동결.

**수용 기준(측정치)**
- 60초 연속 송신에서 eff_hz ≥ 19 (ally-cli 가 송신 타임스탬프로 산출)
- ACK RTT p50/p95 기록(판정선 없음 — W2 지터 기준의 베이스라인)
- B 입력 이벤트 수신 → DF-ESTOP 데이터그램 socket write 까지 내부 ≤150ms
  (실측 기대 ~수 ms — 150ms 는 회귀 가드 상한)
- 패드 단절(동글 뽑기) → 다음 틱 내 zero 명령 + disarm 상태 전이 로그
- 로봇 정지 계약: E-STOP 발화→물리 정지 ≤320ms (계약 §B — UDP 경로는 로봇 수신 즉시
  Walking::Stop ~1–5ms, 320ms 는 SSH+파일 폴백 최악치. 측정 방법 §4)

**유선 실기 게이트 체크리스트** (사전: 크래들 + 다리 토크 해제 + 배터리 차단 — §4 G2급)
- [ ] 핸드셰이크: `/tmp/df-walklab-channel` 기록 → 로봇 ≤1s 내 UDP 채택(ACK 수신 시작)
- [ ] 20Hz 지속: 60초 eff_hz ≥ 19 · ACK RTT p50/p95 기록
- [ ] B 버튼 → DF-ESTOP 와이어 송출 내부 ≤150ms (ally-cli 측정 로그)
- [ ] E-STOP 정지 계약 ≤320ms: flag mtime + ACK 동결 + 물리 거동 입회 (§4 절차)
- [ ] 로봇 워치독: 송신 강제 중단 → 600ms 진폭 슬루→0 / 2.5s Stop(토크 유지) 트립 확인
      (계약 §G.4 — 스트림 소스 전용 티어)
- [ ] 패드 분리 → zero + disarm (gilrs 단절 이벤트 경로)
- [ ] ssh2 ↔ 로봇 OpenSSH 5.9(RSA only, user robotis) 접속 성공 —
      **실패 시 이 게이트에서 russh/plink 분기 결정**(아래 리스크)
- [ ] Windows 방화벽: TEL2 인바운드(UDP :17371) 허용 규칙 생성·수신 확인
      (`scripts/` 의 설치 스크립트가 규칙을 만드는지 포함)
- [ ] SSH 파일 폴백: 핸드셰이크 제거(`rm /tmp/df-walklab-channel`) 후 5Hz 파일 경로로
      조종 지속 (INV-3)

**선행 조건**: W0 머지 · 로봇 세션 예약(§4 경합 규칙) · **측정 중 Mac DarwinForge 앱 종료**
(브링업 §6 — `connectOnboard` 가 verify≠active 면 estop flag rm + demo 재기동으로 시험
상태를 파괴. FallPreventionMonitor 자동 재기동 동일).

**리스크**
- **ssh2 크레이트 ↔ OpenSSH 5.9**: 구식 서버(ssh-rsa SHA-1)라 최신 클라이언트가 거부할 수
  있음. 게이트 항목으로 못 박고, 실패 시 (a) russh + 레거시 알고리즘 활성 (b) 시스템
  `plink`/`ssh.exe` 서브프로세스 분기 중 하나를 **이 게이트에서 결정**해 02 문서에 기록.
- XInput 트리거가 gilrs 에서 버튼/축 어느 쪽으로 오는지 기기 편차 — ally-cli 에 축 덤프
  모드를 넣어 게이트 현장에서 즉시 확인.
- Ally 내장 패드의 절전/Armoury Crate 모드 전환이 장치 소실로 보일 수 있음 — failsafe
  ②티어가 흡수하는지 게이트에서 관찰(판정은 W4 매트릭스).

---

### W2 — Tauri 콕핏 HUD + 카메라 (무선 실기 게이트 · 1주)

**산출물**
- `darwin-fpv`(Tauri 2): Rust 백엔드가 W1 코어를 소유(입력 250Hz·TX 20Hz·E-STOP·TEL2·SSH),
  WebView2 풀스크린 1080p — Switch 웹 콕핏 자산(`tools/switch-pilot/web/` — 1280×720
  레이아웃: 상단바 56px+스테이지+readout 320px+도크 88px, CSS 토큰 bg #111315·panel
  #1a1d20·cyan #00d6ee·red #ff4a55·green #62dc8e·amber #ffd166·4px 그리드) 1080p 스케일업
- HUD 문법(Mac 콕핏 조상 — `CockpitStyle.swift`·`PilotTokens.swift` 패리티):
  5줄 상태블록(Controller/Mac→Ally/Robot/DXL/ARM) · 래치 인디케이터(명령 vs TEL2
  `x/y/a/period_latch` 적용값) · 3색 속도게이지 · ARM 슬라이더 80% 임계·44pt 터치 타깃 ·
  스틱 readout 모노스페이스
- 카메라: MJPEG `<img src="http://robot:8080/?action=stream">` (320×240 q80, 보행 중
  ~8–15fps — C1 패치 실기 검증 2026-06-12)
- 터치 E-STOP: JS 는 `invoke("estop")` 만 — 발화·3연발·SSH 병행은 전부 Rust (INV-2)

**수용 기준(측정치)**
- 보행 중 영상 8–15fps 와 HUD 60fps(WebView2 rAF 기준) **동시** 유지
- 입력 이벤트→UDP 송신 지터 ±5ms (Rust 백엔드 타임스탬프 히스토그램, W1 베이스라인 대비)
- 터치 E-STOP 와 패드 B 가 **병행 유효**(어느 쪽이든 즉시발화, 상호 간섭 없음)
- 30분 `<img>` 스트림 soak: 메모리 증가 없음(작업 관리자 Private Bytes 플랫)

**무선 실기 게이트 체크리스트** (192.168.0.33 · 보행 포함 → §4 G3급 안전 점검 선행)
- [ ] 보행 중 영상 8–15fps + HUD 60fps 동시 (화면 녹화 + 프레임 카운터 로그)
- [ ] 입력→송신 지터 ±5ms (10분 분포, p95)
- [ ] 터치 E-STOP 병행: 패드 B / 터치 각 3회, 전부 물리 정지 + flag mtime 기록
- [ ] 30분 soak 메모리 안정 (시작/종료 Private Bytes 기록)
- [ ] HUD 래치 인디케이터가 TEL2 적용값과 일치(명령 풀스틱 시 거버너 스케일다운이 보임)
- [ ] 무선 TEL2 30Hz 수신율 ≥ 90% (seq 갭 카운트)

**선행 조건**: W1 게이트 통과. **리스크**: WebView2 의 MJPEG `<img>` 메모리 릭(soak 으로
검출, 대안 = fetch+blob 수동 펌프) · 120Hz 패널에서 rAF 120 으로 도는 경우 HUD 측정
기준을 60fps 하한으로 명시.

---

### W3 — 3D 합성 포즈 + PIP (무선 실기 · 1–1.5주)

**산출물**
- `ally-pose`: forge-core walk FK **직링크**(Rust→Rust, FFI 불필요) — TEL2 에 **관절각이
  없으므로**(계약 §A.2-TEL2) phase 기반 FK + IMU 보정 **합성 포즈**. Mac 앱과 동일 방식.
- Three.js GLB 뷰어(`darwin.glb` 733KB·30k tri — Switch 자산 재사용) + 체이스캠(TEL2
  phase 위상 동기 — Mac 콕핏 조상) + 영상 PIP 전환
- **"합성" 정직 라벨**: 3D 포즈가 실측 관절각이 아님을 HUD 에 상시 표기
- 카메라 라이브 시 3D pause 정책(Switch 콕핏 조상) 또는 PIP 동시 — 60fps 유지가 판정 기준

**무선 실기 게이트 체크리스트**
- [ ] 보행 위상 동기가 Mac 앱과 동등: 동일 보행을 두 클라이언트로 관찰(육안) + phase 로그
      교차 비교(TEL2 phase 0..3 전이 타이밍)
- [ ] 영상 + 3D PIP 동시 60fps (프레임 타임 로그)
- [ ] IMU 보정 반영: 로봇 기울임 → 3D 모델 기울임 추종(육안)
- [ ] "합성" 라벨 상시 노출

**선행 조건**: W2 게이트 통과(순수 FK 모듈은 병행 가능). **리스크**: WebView2 에서
Three.js + MJPEG 동시 GPU 부하 — pause 정책이 폴백.

---

### W4 — 게임화·내구·패키징 (내구 실기 게이트 · 1–2주)

**산출물**
- 패키징: `darwin-fpv.exe` 단일 배포(Tauri bundler — MSI 또는 포터블), Armoury Crate
  게임 등록 메타데이터, 풀스크린 기동·커서 자동 숨김
- 절전/전원 이벤트 핸들링: suspend 통지 수신 → **절전 허용 전 E-STOP 발화**(Rust 백엔드,
  INV-1 경로)
- 포커스 상실 정책: 포커스 잃으면 즉시 zero + disarm (E-STOP 입력은 계속 유효)
- 게임화 마감: 패드 럼블 피드백(E-STOP·낙상 시), 사운드 큐, 시작 시 프리플라이트
  체크 화면(로봇 도달성·방화벽·배터리)
- §3 장애 주입 매트릭스 전 항목 실측 보고서(`docs/reports/`)

**내구 실기 게이트 체크리스트**
- [ ] 30분 연속 데모 무중단 (조종+영상+3D, 크래시·메모리·발열 기록 — loop/프레임 분포 첨부)
- [ ] §3 장애 주입 매트릭스 **전 항목** 안전 수렴 (각 행 판정 기준 충족)
- [ ] Armoury Crate 에서 게임으로 기동 · 풀스크린 · 마우스 커서 비노출
- [ ] 절전 진입 이벤트 시 E-STOP 발화 확인 (절전 직전 로그 + 로봇 flag mtime)
- [ ] 패키지 클린 설치: 새 Windows 계정에서 설치→방화벽 규칙→첫 연결까지 무문서 성공

**선행 조건**: W3 게이트 통과. **리스크**: Windows 절전 통지 타이밍(통지→실제 suspend
사이 시간이 짧음 — E-STOP 3연발은 UDP 라 ~100ms 내 완료, SSH 병행은 미보장이어도
로봇 워치독이 백스톱) · Game Bar 오버레이 중 XInput 점유 여부 기기 확인.

---

## §3 장애 주입 매트릭스 (W4 실측 표)

전제: 크래들 위 제자리 보행 중 주입(브링업 §5-1 과 동일 조건). 판정은 **물리 거동 +
로봇측 로그**(ACK 단독 판정 금지 — F9 교훈). 로봇측 방어선은 계약 §G.4 워치독
(스트림 소스: 침묵 600ms → 진폭 슬루→0 / 2.5s → Walking::Stop, 토크 유지)과
E-STOP flag latch(§B).

| # | 시나리오 | 주입 방법 | 기대 — 클라이언트(Ally) | 기대 — 로봇 | 판정 기준 |
|---|---|---|---|---|---|
| 1 | 패드 단절 | 내장 패드 USB 리셋(장치 관리자 비활성/활성) | gilrs 단절 이벤트 → 즉시 zero 송신 + disarm, HUD Controller=LOST | zero 수신으로 정지(스트림 자체는 유지) | 단절→zero 송신 ≤1틱(50ms) 로그 + 물리 정지, 재 ARM 요구 |
| 2 | WiFi 단절 | AP 전원 차단(또는 Ally WiFi off) | TX 실패·TEL2 침묵 → HUD Robot=STALE, 자동 재핸드셰이크 루프 | 워치독: 600ms 슬루→0 → 2.5s Stop(토크 유지) | 차단→물리 정지 ≤2.5s+1틱, 재연결 후 재 ARM 전 이동 0 |
| 3 | 로봇 전원 OFF | 로봇 배터리 스위치 OFF | TEL2/ACK 소실 → HUD Robot=OFFLINE, 송신 무해(블랙홀), 크래시 없음 | — (전원 없음) | 앱 무크래시 + OFFLINE 표시 ≤2s, 전원 복구 후 핸드셰이크 재수립 |
| 4 | 앱 강제 종료 | 작업 관리자 kill `darwin-fpv.exe` | 보호 불가(의도) | **워치독이 유일 방어**: 600ms 슬루→0 / 2.5s Stop | kill→물리 정지 ≤2.5s+α, estop flag 미생성(재시작 시 재 ARM 으로 충분) |
| 5 | 절전 진입 | 전원 버튼 짧게 / 덮개 정책 | suspend 통지 → **E-STOP 3연발+SSH flag 발화 후** 절전 허용 | flag latch → 정지 + 재무장 대기 | 절전 직전 클라이언트 로그의 ESTOP 발화 + 로봇 flag mtime, 복귀 후 복구(Y/UI)→재 ARM 필요 |
| 6 | 포커스 상실 | Game Bar(Win+G) / Alt-Tab | 즉시 zero + disarm (백그라운드 XInput 입력 무시), E-STOP 입력은 유효 유지 | zero 수신 정지 | 오버레이 중 스틱 입력이 로봇에 미도달(ACK x/y/a=0), 복귀 후 재 ARM |
| 7 | 배터리 임계 | Ally 배터리 임계 알림(시뮬 이벤트 주입 허용) | 경고 HUD(amber) → 임계(OS 절전 직전) 시 E-STOP+disarm | flag latch 정지 | 임계 이벤트→ESTOP 발화 로그. 로봇 전압은 별도: TEL2 `vdV` 저전압 시 HUD 경고(발화 아님) |

**브링업 보고서 잔여와 교차** (`docs/reports/2026-06-13-rgg01-bringup.md` §5-1 —
온보드 GamepadPilot 미실측 단절 매트릭스 4종: 전원 OFF·거리 이탈·배터리 탈락·동글 뽑기):
관할이 다르다(그쪽은 로봇 USB 동글 직결 파일럿, 이쪽은 네트워크 클라이언트). 단,
**로봇측 방어 거동(워치독 티어·flag latch)은 공유**이므로 W4 매트릭스 실측을 위한 로봇
세션에서 4종을 같이 소화하면 세션 1회가 절약된다 — W4 게이트 실행 계획에 교차 항목으로
표기하고, 결과는 양쪽 문서(본 문서 §3 + 브링업 후속 보고서)에 동시 기록할 것.
(#1 패드 단절은 그쪽 "동글 뽑기"와, #3 로봇 전원 OFF 는 그쪽 동명 항목과 물리적으로 동일
조건이 되도록 크래들 제자리 보행 중으로 통일했다.)

---

## §4 실기 검증 절차 연계

### 4.1 게이트 규율 — HARDWARE_VERIFICATION_PROTOCOL.md 승계

`docs/HARDWARE_VERIFICATION_PROTOCOL.md`(v1, 2026-05-12 — 모션 합성용 3게이트)가 존재한다.
대상은 다르지만 **게이트 규율을 그대로 승계**한다:
- 게이트 사이 **사용자 명시 승인** 필수, **게이트 건너뛰기 금지**.
- W1 유선 게이트 = **G2급** 사전 조건: 크래들 고정 + 다리 토크 해제 + 배터리 차단 가능
  위치 + 배터리 ≥ 11V.
- W2 이후 보행 게이트 = **G3급** 안전 점검: 주변 0.5m 장애물 제거 · 매트 · e-stop 즉시
  가용(패드 B + 터치 + Mac 폴백 중 2계통 이상) · **카메라 녹화**(사고 분석 + 위상 동기
  판정에 재사용) · 사용자 손은 스윙 범위 밖.
- 낙상 시 사용자 직접 회수 + 전원 OFF, 모터 과열(>60°C) 시 토크 OFF + 10분 휴식.

### 4.2 E-STOP ≤320ms 측정 (기존 계약 검증 절차 재실행)

계약 근거(`docs/ssh-parity-contract.md` §B): 최악치 = SSH 왕복 50–120ms + 파일 폴 ≤200ms
≈ **≤320ms**. UDP 경로(§G.2)는 수신 즉시 `Walking::Stop()` ~1–5ms 라 통상 수십 ms 내 —
320ms 는 폴백 포함 계약 상한이다. 측정은 브링업 §2-② 방식 재실행:
1. 클라이언트 B 입력 타임스탬프(Rust 백엔드 로그 — 라인버퍼 필수, 브링업 F9 관측성 교훈)
2. 로봇 `/tmp/df-walklab-estop` flag **mtime**
3. ACK 스트림 동결 시점(flag ON 구간 ACK 0줄 — 게이트 구조 검증)
4. **물리 거동 입회** — 가능하면 고속 영상. 브링업 §5-4 의 "물리 정지 완료 타임스탬프
   미계측" 잔여를 이 측정에서 함께 해소(서보 위치 로그 또는 고속 영상).
주의: "1-2ms 통과" 류의 flag 생성 지연 단독 측정을 정지 시간으로 보고하지 말 것(브링업
§2-② 정정 이력). 판정은 항상 물리 거동.

### 4.3 레이턴시 측정 — TEL2 seq_applied 에코

- 클라이언트가 `DFCMD … {seq} …` 에 단조 seq + 송신 시각을 기록 → 로봇이 적용한 마지막
  seq 를 TEL2 `seq_applied`(30Hz)로 에코(계약 §A.2-TEL2) → **입력→적용 RTT** = TEL2 수신
  시각 − 해당 seq 송신 시각(상한 추정치, TEL2 주기 33ms 양자화 포함).
- ACK `{seq} {t_rx}` 의 로봇 시각으로 클럭 오프셋 EWMA 보정(Mac 측 `RobotClockSync` 와
  동일 기법 — Connection/RobotClockSync.swift 참조) 후 단방향 추정 가능.
- 보고 형식: p50/p95 + 히스토그램, 유선/무선 각각. W1 에서 베이스라인, W2 에서 지터
  ±5ms 판정, W4 30분 분포(브링업 §5-2 의 10분 분포 잔여와 같은 형식으로).

### 4.4 로봇 세션 경합 규칙 (필수 준수)

- **로봇 접근은 한 번에 한 세션** — 로봇·워크트리는 단일 공유 자원. 게이트 실행 전
  코디네이터(사용자)에게 소유권을 지정받는다.
- **측정 중 Mac DarwinForge 앱 종료** — 브링업 §6 실증: 연결 시 `connectOnboard` 가
  verify≠active 면 자동으로 estop flag rm + demo 재기동(시험 상태 파괴, 라운드6 사후 분석
  오염 실사고). FallPreventionMonitor 자동 재기동도 동일.
- **핸드셰이크 경합**: Ally 가 `/tmp/df-walklab-channel` 을 쓰면 mtime 변경 → 로봇이 UDP
  transport 를 **새 토큰으로 재시작**(계약 §G.1) → 기존 Mac/Switch 세션의 UDP 가 즉사한다.
  같은 이유로 세션 종료 시 핸드셰이크 파일을 지워(`rm -f`) 로봇을 파일 폴백으로 되돌릴 것.
- 접속 경로: 유선 USB-C LAN → 192.168.123.1(무선 대비 ~166배 빠름, W1 게이트 기본) /
  무선 192.168.0.33(W2+). 로봇 SSH = OpenSSH 5.9 · RSA only · user robotis.

---

## §5 W1 착수 프롬프트

> `docs/design/implementation-prompts.md` 형식. W0 머지 후 새 세션에 그대로 붙여넣는다.
> 완료 시 체크박스 갱신 + 본 문서 §2 W1 체크리스트에 증거 기입.

## [ ] A-W1 — DARwIn FPV 제어 코어 헤드리스 (ally-link·ally-input·ally-cli) · 전제 W0 머지 · 유선 실기 게이트

```
app/ally/docs/04_ACCEPTANCE_ROADMAP.md 의 W1(제어 코어 헤드리스)을 구현해줘.

컨텍스트: DARwIn FPV = ROG Ally(Windows 11, 내장 XInput 패드)용 DARwIn-OP2 원격 조종
네이티브 앱. app/ally/ 는 독립 Cargo workspace 이고 W0 에서 crates/df-wire(와이어 순함수
+ Python df_udp.py 골든 벡터 패리티)가 머지됨. 와이어 계약의 단일 진실원은
docs/ssh-parity-contract.md — 재발명 금지. 매핑 수치는 RG G01 실기 검증값 1:1 동결(D2,
firmware-patches/walklab-brokerage/GamepadPilot.h) — 변경 시 실기 재검증이 강제되므로
절대 변경 금지. JS/UI 는 이번 범위가 아님(헤드리스만).

할 일:
1. crates/ally-link — UDP 명령 TX 20Hz(:17374, df-wire 의 DFCMD 직렬화 사용) ·
   E-STOP "DF-ESTOP v1 {token} {ts}" ×3연발 0/50/100ms(:17372) + SSH
   "touch /tmp/df-walklab-estop" 병행 · TEL2 30Hz RX(/tmp/df-walklab-uplink 에
   "ip:port" 등록, 기본 :17371) · SSH 세션(ssh2 크레이트 — 로봇은 OpenSSH 5.9 RSA only
   user robotis, 접속 실패 시 멈추고 russh/plink 분기를 사용자와 결정) · 핸드셰이크
   /tmp/df-walklab-channel "{token16} 17372 17374" 기록(계약 §G.1) · ACK 무수신 1.5s 시
   SSH 파일 폴백 5Hz(/tmp/df-walklab-cmd — 영구 보존).
2. crates/ally-input — gilrs 250Hz 폴링 + G01 동결 매핑(GamepadPilot.h 의 GP_* 수치를
   정규화 [-1,1] 공간에서 1:1: 데드존 0.10·이동 곡선 1.35·헤드 곡선 1.7·헤드 레이트
   150/85°/s 클램프 ±70/±35·LT/RT 차분 턴 데드존 0.02 부스트 ^0.65·터보 1.3·
   intensity^0.7 스케줄 period 700→560 foot 18→40·부호 5종 −1.0) + 안전 게이트:
   A=ARM(이동 단일 게이트)·B=E-STOP rising-edge 즉시발화(스로틀·디바운스·컨플레이션
   금지 — INV-1)·Y=복구·failsafe 3티어(release 합성/장치 소실→zero+disarm/이벤트 침묵
   1500ms 슬루 정지).
3. crates/ally-cli — 헤드리스 수용시험 러너: 핸드셰이크→60s 20Hz 송신(eff_hz 산출)→
   TEL2 수신율→ACK RTT p50/p95→B E-STOP(입력→소켓 write 내부 지연 측정)→패드 단절
   시나리오를 측정치와 함께 stdout 보고. 축 덤프 모드 포함(XInput 트리거 매핑 현장 확인용).

게이트(유선 실기 — USB-C LAN 192.168.123.1, 크래들+다리 토크 해제+배터리 차단,
측정 중 Mac DarwinForge 앱 종료 필수): 04 문서 §2 W1 체크리스트 9항목 전부. 합격선:
eff_hz≥19 · E-STOP 내부 ≤150ms · 정지 계약 ≤320ms(§4.2 절차 — 판정은 ACK 가 아닌 물리
거동, "ACK enabled=1 ≠ 서보 기록") · 워치독 600ms/2.5s 트립 · Windows 방화벽 UDP :17371
인바운드 확인.

읽을 파일: app/ally/docs/04_ACCEPTANCE_ROADMAP.md(§2 W1·§4) ·
docs/ssh-parity-contract.md(§A.2-TEL2·§B·§C·§G 전체) ·
firmware-patches/walklab-brokerage/GamepadPilot.h(매핑 동결 수치) ·
docs/reports/2026-06-13-rgg01-bringup.md(§2 게이트 선례·§6 운용 노트) ·
tools/switch-pilot/src/darwin_switch_agent/df_udp.py(패리티 원본) ·
app/ally/docs/01~03(PRD·아키텍처·UX).

제약: E-STOP 경로 무스로틀·무배칭(INV-1) · 파일 폴백 영구 보존(INV-3) · 매핑 수치 변경
금지(INV-4) · 클라이언트 클램프는 UX 레이어, 최종 클램프는 로봇 거버너(INV-5) ·
핸드셰이크 파일은 세션 종료 시 rm(타 세션 UDP 즉사 방지, 04 §4.4) · 실기 게이트 단계
전에 멈추고 사용자에게 절차 보고(코드·단위 테스트까지가 자율 범위). cargo test 결과를
증거로 제시. 완료 시 04 문서 §1 표·§2 W1 체크박스 갱신.
커밋: feat(ally) 스코프, 웨이브 내 분할 자유.
```
