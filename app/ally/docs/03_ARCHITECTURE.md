# DARwIn FPV — 기술 아키텍처 (Tauri 2 적용판)

> 상태: **확정** (D1 스택·D2 매핑·D4 제품명 — 사용자 승인 완료, 변경 금지)
> 작성: 2026-06-13 · 대상: ROG Ally (Windows 11, 7" 1080p 120Hz 터치, 내장 XInput 패드, Ryzen Z1E/16GB)
> 기준: docs/design/README.md — "다른 세션이 추가 탐색 없이 착수 가능". W1 착수 전 §10부터 읽을 것.
>
> 단일 진실원(재발명 금지):
> - 와이어 계약 전체 = **[docs/ssh-parity-contract.md](../../../docs/ssh-parity-contract.md)** (§A.2-TEL2·§B·§C·§G)
> - RG G01 매핑 수치 = **firmware-patches/walklab-brokerage/GamepadPilot.h** (2026-06-13 실기 검증 동결)
> - 파이썬 와이어 참조 구현 = tools/switch-pilot/src/darwin_switch_agent/df_udp.py

---

## §1 스택 결정 요약

**결론: Tauri 2 하이브리드 (D1, 사용자 승인 완료).** Rust 백엔드가 안전·통신을 전담하고
(게임패드 입력 250Hz 폴링 · 20Hz UDP TX · E-STOP 3연발 · TEL2 수신 · SSH 세션),
WebView2 풀스크린 게임 UI가 Switch 웹 콕핏 자산(tools/switch-pilot/web — 1280×720)을
1080p로 스케일업해 표시한다.

### 비교했던 대안

| 후보 | 입력→송신 레이턴시 | MJPEG 경로 | 게임패드 | forge-core 재사용 | 60fps UI | 공수 | 유지보수 | 판정 (1줄) |
|---|---|---|---|---|---|---|---|---|
| **Tauri 2** | Rust 스레드 직결 — webview 비경유 | `<img>` 직결, 디코더 내장 | gilrs (Rust) | path 의존 직링크 | WebView2 GPU 합성 충분 | 낮음 (웹 콕핏 자산 재사용) | Rust+웹, 팀 기존 역량 | **채택 — 안전은 Rust, 표시는 검증된 웹 자산** |
| Bevy | ECS 프레임 틱에 묶임 (60Hz 프레임 ≠ 250Hz 입력) | MJPEG 디코더 수작업 (image crate 프레임별) | gilrs 동일 | 직링크 가능 | 게임엔진이라 과잉 | 높음 (HUD 전부 신규) | ECS 러닝커브 | 기각 — UI 전면 재작성 비용이 이득을 상회 |
| egui (eframe) | immediate-mode 루프와 입력 스레드 분리 가능 | 수작업 디코더 + 텍스처 업로드 | gilrs 동일 | 직링크 가능 | immediate-mode 게임풍 HUD 한계 | 중간 | 단일 바이너리 단순 | 기각 — Switch 콕핏 CSS/Three.js 자산 전부 폐기됨 |
| Godot | GDExtension 경유 — Rust 안전 코어와 경계 모호 | VideoStream 비표준, 수작업 | Godot 입력계 (XInput OK) | GDExtension 바인딩 비용 | 충분 | 높음 | 엔진 메이저 업그레이드 리스크 | 기각 — 안전 경로가 엔진 런타임에 종속됨 |

**선정 근거 (3줄):**
1. 안전 경로(입력→E-STOP·입력→TX)가 **순수 Rust 스레드**로 격리되어 UI 프레임워크 생명주기와 완전 무관 — 세 조상 중 Mac 콕핏의 "E-STOP 즉시발화" 불변식을 가장 깨끗하게 보존.
2. Switch 웹 콕핏(실기 검증된 레이아웃·CSS 토큰·Three.js GLB 뷰어)을 거의 그대로 재사용 — UI 공수가 4안 중 최소.
3. forge-core walk FK를 cross-workspace path 의존으로 직링크 — wasm 빌드·바인딩 계층 없이 단일 진실원 유지.

### 핵심 불변식 — INV-2: webview는 어떤 안전 경로에도 없다

게임패드 입력(gilrs) · G01 매핑 · E-STOP · UDP 송수신 · SSH — **전부 Rust 코어 프로세스의
스레드에서 수행**한다. webview JS는 표시 전용이며 이동 명령 생성·E-STOP 경로에 비관여한다.
webview가 행에 걸리거나 크래시해도 로봇 제어·정지는 영향 없다 (§2 수퍼바이저가 오히려
webview 이상을 E-STOP 트리거로 사용). 터치 E-STOP 버튼은 **보조** 경로다 — §3 참조.

이는 리포 공유 불변식(docs/design/README.md §3) "E-STOP 경로에 스로틀·배칭·추가 홉 금지"의
Ally 구현이다.

---

## §2 프로세스·스레드 모델

단일 프로세스(darwin-fpv.exe), 스레드 7종. 메인 스레드는 Tauri 이벤트 루프 + WebView2이며
**표시 전용** — 나머지 6개 스레드는 메인과 독립적으로 산다.

```
┌─────────────────────────────── darwin-fpv.exe ────────────────────────────────┐
│                                                                                │
│  [입력 스레드 250Hz]            [제어 TX 스레드 20Hz 고정틱]                   │
│   gilrs 폴링(4ms)                 InputFrame 신선도 검사(>150ms→zero+disarm)   │
│   ├─ InputFrame ──────────────▶   → G01 매핑(GamepadPilot.h 동결 상수)        │
│   │   (triple-buffer 최신승)      → 안전 게이트(EMA α=0.5·snap-to-zero·ARM)   │
│   └─ B rising ──┐                 → 14-token line → DFCMD {token} {seq++}     │
│                 │                 → UDP :17374 ──────────────────▶ 로봇       │
│                 ▼                 └─ 틱마다 하트비트 갱신 ──┐                  │
│  [E-STOP 전용 스레드]                                       │                  │
│   평시 park (무손실 채널 대기)                              │                  │
│   수신 즉시: UDP "DF-ESTOP v1" ×3 (0/50/100ms) → :17372     │                  │
│             + SSH touch /tmp/df-walklab-estop (병행)        │                  │
│                 ▲                                           │                  │
│                 │ estop 채널(무손실 mpsc — 디바운스·스로틀·컨플레이션 금지)    │
│                 │                                           ▼                  │
│  [수퍼바이저 스레드]                                  하트비트 레지스터        │
│   패드 단절(gilrs Disconnected) ────────┐                                      │
│   webview 포커스 상실(Tauri 이벤트) ────┼──▶ estop 채널 송신                  │
│   WM_POWERBROADCAST 절전(PBT_APMSUSPEND)┤                                      │
│   TX 틱 하트비트 침묵 >300ms ───────────┘                                      │
│                                                                                │
│  [UDP RX 스레드]                          [SSH 세션 스레드]                    │
│   blocking recv (단일 소켓)                ssh2: 접속·재접속 상태기계          │
│   "ACK {seq} {t_rx}" → RTT EMA·eff_hz      브로커리지 기동 확인                │
│   "TEL2 …" 30Hz → StateHub(RwLock) 갱신    핸드셰이크/uplink 파일 기록(SFTP)   │
│         │                                  ACK 1.5s 무수신 → 파일 폴백 5Hz     │
│         ▼                                                                      │
│  ┌──────────────── StateHub (RwLock 스냅샷 — 단일 쓰기, 다중 읽기) ─────────┐  │
│  │ 텔레메트리·RTT·eff_hz·연결상태·ARM/ESTOP 래치·패드 상태                 │  │
│  └──────────────┬───────────────────────────────────────────────────────────┘  │
│                 │ Tauri 이벤트 30Hz(상태) + 60Hz(스틱 오버레이)                │
│                 ▼                                                              │
│  [메인 스레드 = Tauri + WebView2]  ◀── Tauri 커맨드(connect/터치E-STOP 등)    │
│   표시 전용 — 명령 생성·안전 경로 비관여 (INV-2)                              │
└────────────────────────────────────────────────────────────────────────────────┘
```

### 스레드별 책임 (요약)

| 스레드 | 주기 | 책임 | 안전 관여 |
|---|---|---|---|
| 입력 | 250Hz (4ms) | gilrs 폴링 → `InputFrame{축·버튼·ts}` 최신승 발행. **B rising edge 감지 → estop 채널 즉시 송신** (매핑·게이트 비경유) | E-STOP 발원 (1차) |
| 제어 TX | 20Hz 고정틱 | InputFrame 신선도 >150ms → zero 명령+disarm. 신선하면 G01 매핑 → 안전 게이트(EMA α=0.5, snap-to-zero, ARM 게이트) → df-wire 14-token 빌드 → `DFCMD {token} {seq++} {line}` UDP 송신. 틱마다 하트비트 갱신 | 이동 명령의 유일한 발원 |
| E-STOP | 이벤트 구동 (park) | estop 채널 수신 즉시 UDP `DF-ESTOP v1 {token} {ts}` ×3연발(0/50/100ms) → :17372 + SSH `touch /tmp/df-walklab-estop` 병행. 무선 ≤320ms 정지 계약(ssh-parity-contract §B·§G.2) | E-STOP 발화 전담 |
| UDP RX | blocking recv | ACK → RTT EMA·effective_hz 산출, TEL2 → 파싱(df-wire) → StateHub 갱신 | 텔레메트리 신선도가 HUD 정직성의 근거 |
| SSH 세션 | 상태기계 | ssh2 세션 수립·유지·재접속, 브로커리지 기동 확인, 핸드셰이크·uplink 파일 SFTP 기록, ACK 1.5s 무수신 시 명령 파일 폴백 5Hz (`/tmp/df-walklab-cmd`) | 폴백 경로 + E-STOP 파일 병행 경로 |
| 수퍼바이저 | 100ms | 패드 단절·webview 포커스 상실·`WM_POWERBROADCAST`(PBT_APMSUSPEND) 절전 진입 → estop 채널. **TX 틱 하트비트 침묵 >300ms → estop 채널** (제어 루프 자체의 행 감시) | E-STOP 발원 (2차) |
| 메인 | Tauri 루프 | WebView2 셸·이벤트 발행·커맨드 수신. 표시 전용 | 없음 (INV-2) |

### 채널 규율

- **estop 채널**: 무손실(unbounded mpsc). Mac 콕핏의 불변식 그대로 — **디바운스·스로틀·컨플레이션 금지**, rising edge 즉시발화.
- **InputFrame**: triple-buffer/`watch` 최신승 — TX 틱은 항상 최신 프레임만 본다 (백프레셔 없음).
- **StateHub**: `RwLock<Snapshot>` — RX 스레드 단일 쓰기, 메인·수퍼바이저 읽기.

**불변식: 렌더·webview가 죽어도 입력→E-STOP·입력→TX는 동작한다.** 입력·TX·E-STOP 스레드는
Tauri 런타임 객체를 일절 참조하지 않는다 (이벤트 발행 핸들은 메인 쪽에서만 소유).

---

## §3 Rust ⇄ UI 계약

### Rust → UI: Tauri 이벤트 (push)

| 이벤트 | 주기 | 용도 |
|---|---|---|
| `state` | 30Hz (TEL2 케이던스) | HUD 상태 스냅샷 전체 |
| `stick` | 60Hz (경량 별도) | 스틱·트리거 readout 오버레이 — 표시 지연감 제거 |
| `pose` | 30Hz | 3D 합성 포즈 관절각 20종 (§5) |

`state` 페이로드 스키마 (필드 단위):

| 필드 | 타입 | 출처 | 의미 |
|---|---|---|---|
| `conn.path` | `"wired" \| "wireless" \| "none"` | SSH 스레드 | 123.1 유선 / 0.33 무선 |
| `conn.transport` | `"udp" \| "ssh_file"` | ACK 신선도 | 활성 명령 경로 (폴백 표시) |
| `conn.rtt_ms` | f64 | ACK RTT EMA | 왕복 지연 |
| `conn.eff_hz` | f64 | ACK 수신율 | 유효 명령 도달율 |
| `safety.armed` | bool | ally-input 상태기계 | ARM 래치 |
| `safety.estop_latched` | bool | 〃 | E-STOP 래치 (Y 복구 전까지) |
| `safety.recovering` | bool | 〃 | 소프트 토크 램프 진행 중 (~0.6s) |
| `cmd.x / y / a` | f64 | TX 스레드 | **명령값** (mm/mm/deg) |
| `tel.x_lat / y_lat / a_lat / period_lat` | f64 | TEL2 | **적용값** (로봇 성형 후 래치) — 래치 인디케이터의 "명령 vs 적용" 쌍 |
| `tel.phase` | i32 (0..3, −1=unknown) | TEL2 | 보행 위상 (3D 위상 동기) |
| `tel.seq_applied` | i64 | TEL2 | 마지막 적용 seq (루프 클로저) |
| `tel.imu` | [u16; 6] | TEL2 | gyro/accel raw 10-bit ADC (중심 512) |
| `tel.fsr` | `[u16; 8] \| null` | TEL2 | FSR 8셀 (`-` 그룹이면 null) |
| `tel.cop` | `[i32; 2] \| null` | TEL2 | 전신 CoP |
| `tel.fallen` | i32 (−1/0/1) | TEL2 | 낙상 |
| `tel.voltage_v` | `f64 \| null` | TEL2 vdV (0=unknown→null) | 전압 |
| `tel.active_source` | `"udp" \| "file" \| "local"` | TEL2 | 로봇이 적용 중인 명령 소스 |
| `tel.age_ms` | i64 | RX 스레드 | 마지막 TEL2 경과 — **>1500ms면 UI 채도 저하(stale 정직성)** |
| `pad.connected` | bool | 입력 스레드 | 패드 존재 |
| `pad.turbo` | bool | 〃 | RB 터보 활성 |
| `cam.healthy` | bool | Rust 헬스체크 (§4) | 카메라 스트림 생존 |

### UI → Rust: Tauri 커맨드 (invoke)

| 커맨드 | 인자 | 처리 |
|---|---|---|
| `connect` | `{prefer: "wired" \| "wireless"}` | SSH 스레드에 세션 시퀀스(§7) 개시 지시 |
| `disconnect` | — | §7-⑦ 정리 후 종료 |
| `set_settings` | 설정 구조체 | 비안전 설정만 (HUD 토글 등). **매핑 수치는 D2 동결 — 설정 항목 아님** |
| `touch_estop` | — | **보조 경로** — 도착 즉시 estop 채널에 합류 (E-STOP 스레드가 동일하게 처리). 물리 B 버튼이 주 경로 |

터치 E-STOP은 webview를 경유하므로 INV-2의 예외가 아니라 **추가 발원**이다: 물리 B(입력
스레드)·수퍼바이저·터치 3계가 같은 무손실 estop 채널로 수렴하며, webview 죽음은 터치 경로만
잃는다 (물리 경로 무손상).

---

## §4 카메라 경로

**webview `<img src="http://robot:8080/?action=stream">` 직결.** MJPEG(320×240 JPEG q80,
보행 중 ~8–15fps — C1 패치 실기 검증 2026-06-12)을 WebView2 내장 디코더가 소화한다.
Rust 프록시 불필요 — 카메라는 안전 경로가 아니므로 INV-2 위반이 아니다.

- **mixed content 없음**: Tauri Windows 기본 origin이 http(`useHttpsScheme=false` 기본값 확인됨)이므로 http MJPEG를 직접 로드 가능. 단 W2에서 실빌드 origin 재확인을 게이트 항목으로 둔다.
- **CSP**: `img-src`에 로봇 IP 대역(`http://192.168.123.1:8080 http://192.168.0.33:8080`) 명시 허용 필요 (tauri.conf.json).
- **스톨 감지 이중화**:
  1. JS 프레임 이벤트 — `<img>` load 진행 감시(프레임 갱신 타임스탬프), 정체 시 UI에 "카메라 끊김" 배지 + `<img>` src 재설정(재접속).
  2. Rust 헬스체크 — HTTP HEAD(:8080) 또는 TEL2 age 연동으로 `cam.healthy` 판정 → JS가 죽어도 상태는 정직.
- **장시간 메모리 거동**: WebView2의 무한 MJPEG `<img>` 스트림 메모리 누수 여부는 **W2 30분 soak 게이트 항목** (§9 리스크).

---

## §5 3D 합성 포즈

**Three.js + darwin.glb 재사용** (tools/switch-pilot/web/assets/darwin.glb — 733KB·30k tri,
실파일 750,396B 확인). 뷰어 코드는 switch-pilot `robot3d.js`/`robot3d-rig.js` 계열을 출발점으로
한다.

- **관절각 계산은 Rust(ally-pose)**: TEL2에는 **관절각이 없다** (와이어 계약 §A.2-TEL2). 따라서 TEL2 `phase`(0..3) + 래치 진폭(x/y/a/period_lat)을 **forge-core walk FK 직링크**(path 의존 `../../core/forge-core`)에 넣어 20관절 각도를 합성하고, 30Hz `pose` 이벤트로 webview에 푸시한다. Mac 콕핏 walkAnimator의 위상 동기 방식과 동일.
- **wasm 불필요** — FK는 Rust 한 곳에서만 돌고 JS는 본 메시 회전만 적용. 단일 진실원(Rust 게이트 모델) 유지.
- **IMU 보정**: TEL2 gyro/accel raw에서 roll/pitch 추정 → 몸통 루트에 적용 (Mac과 동일 방식).
- **"합성 포즈" 라벨은 UI 불변 표기** — 실측 관절각이 아님을 항상 명시 (Mac 콕핏의 정직 라벨 문법 계승). 카메라 라이브 시 3D pause 정책(Switch 콕핏 검증)도 그대로 적용해 GPU 경합을 피한다.

---

## §6 크레이트 경계

`app/ally/` = **독립 Cargo workspace** (app/core 오염 금지 — forge-core는 cross-workspace
path 의존으로만 끌어온다. lock 파일 이중화는 의도된 격리 — §9).

| 크레이트 | 책임 | 의존 |
|---|---|---|
| **df-wire** | 와이어 계약 순함수 전부: 토큰 생성(16 영숫자)·핸드셰이크 본문(`"TOKEN 17372 17374\n"`)·DFCMD/DF-ESTOP 데이터그램 조립·ACK 파싱·TEL2 파싱(FSR/CoP `-` 그룹)·14-token line 빌더+게이트 보간(EMA·snap-to-zero·intensity^0.7 스케줄). **골든 벡터 패리티 테스트** — df_udp.py·WalkLabTransport.cpp와 동일 입력→동일 바이트 검증. **W0 구현 완료** | **0** (std만) |
| ally-link | UDP 소켓(단일 소켓 송수신)·seq 단조·RTT EMA·effective_hz·E-STOP ×3 버스트 타이밍·ssh2 세션·핸드셰이크/uplink 파일 교환·유선(123.1)/무선(0.33) 듀얼 경로 프로브 | df-wire, ssh2 |
| ally-input | gilrs 폴링·**G01 동결 매핑 상수(GamepadPilot.h 1:1 — 상수 모듈 W0 수록)**·ARM/ESTOP_LATCH/RECOVER 상태머신·EMA(α=0.5)·snap-to-zero | df-wire, gilrs |
| ally-pose | TEL2 phase+래치 → forge-core walk FK → 20관절각 + IMU roll/pitch 보정 | forge-core (path: `../../core/forge-core`) |
| darwin-fpv | Tauri bin: 셸·씬 상태머신(타이틀→접속→콕핏)·전원 관리(`SetThreadExecutionState`·WM_POWERBROADCAST)·StateHub·스레드 기동·이벤트/커맨드 배선 | 위 전부, tauri 2 |
| ally-cli | 헤드리스 수용시험: 핸드셰이크→20Hz 영명령→E-STOP→메트릭 덤프(RTT·eff_hz·정지 시간). **W1 실기 게이트 도구** — UI 없이 와이어·안전 코어만 검증 | df-wire, ally-link, ally-input |

+ `ui/` (웹 프론트 — Switch 콕핏 자산 이식: styles.css 토큰 bg `#111315`·panel `#1a1d20`·cyan
`#00d6ee`·red `#ff4a55`·green `#62dc8e`·amber `#ffd166`·4px 그리드), `assets/`(darwin.glb 등),
`scripts/`(빌드·방화벽 규칙 설치).

### G01 동결 매핑 상수 (D2 — GamepadPilot.h 실기 검증 수치, 변경 시 실기 재검증 필수)

| 상수 | 값 | 의미 |
|---|---|---|
| 스틱 데드존 | 0.10 | 잔여 재스케일·부호 보존 |
| 이동 곡선 | 1.35 | drive curve |
| 헤드 곡선 | 1.7 | 헤드 전용 (F10b) |
| 터보(RB) | ×1.3 | 정규화 후 ±1 클램프 |
| 최대 stride/side/turn | 38mm / 22mm / 12° | UI 클램프 — 최종은 로봇 거버너(O2) |
| 헤드 레이트 | pan 150°/s · tilt 85°/s | 오른스틱 = **레이트 제어**, 놓으면 유지 |
| 헤드 클램프 | pan ±70° · tilt ±35° | |
| 트리거 데드존 | 0.02 | LT/RT 차분 = 아날로그 턴 |
| 턴 저압 부스트 | \|d\|^0.65 | 풀프레스 1 불변 |
| 게이트 스케줄 | intensity^0.7 → period 700→560ms·foot 18→40mm | hip 13° 고정 |
| 버튼 | A=ARM · B=E-STOP(rising) · Y=복구(소프트 토크 램프 300→600→900→1023, 150ms 간격 ~0.6s) · X=볼트랙 토글 · RB=터보 | 데드맨 없음 (F10 — ARM만 게이트) |
| failsafe 3티어 | ①버튼 release 합성 ②장치 소실(단절) ③이벤트 침묵 1500ms→슬루 정지 | Ally에서는 ①②를 gilrs 단절 이벤트로, ③을 InputFrame 신선도 150ms(TX) + 수퍼바이저로 흡수 |

---

## §7 세션 시퀀스

1. **경로 프로브** — 유선 `192.168.123.1` 우선(TCP :22 connect 시도, ~166배 빠름), 실패 시 무선 `192.168.0.33`.
2. **ssh2 수립** — user `robotis`, RSA only. 로봇은 **OpenSSH 5.9 레거시 kex** — ssh2 협상 가능 여부가 **W1 최우선 검증 항목** (§9 리스크·폴백 분기).
3. **브로커리지 기동 확인** — `/tmp/df-pilot-mode` = `walklab` 확인, 아니면 기동 절차 수행.
4. **핸드셰이크** — 토큰 생성(16 영숫자) → SFTP로 `/tmp/df-walklab-channel`에 `"TOKEN 17372 17374\n"` 원자 기록(tmp+mv). 로봇 `RefreshHandshake`가 ≤1s 내 채택.
5. **TEL2 수신 개시** — UDP bind → `local_ip_toward` (connected-UDP `getsockname` 트릭 — df_udp.py 검증 구현)로 로봇이 볼 내 IP 산출 → `/tmp/df-walklab-uplink`에 `"ip:port"` 기록(기본 :17371) → TEL2 30Hz 수신 시작.
6. **DFCMD 20Hz 개시** — ACK 1.5s 무수신 → **SSH 파일 폴백 5Hz**(`/tmp/df-walklab-cmd`) 전환 + 핸드셰이크 철회(로봇 UDP 리스너 정리). UI에 `transport: ssh_file` 정직 표기.
7. **종료** — 핸드셰이크 파일 제거(`rm -f /tmp/df-walklab-channel`) — **스테일 토큰 금지** (계약 §G.1 MUST).

**유선↔무선 전환 = 세션 재시작**: disarm → 토큰 폐기 → 재핸드셰이크. uplink IP가 바뀌므로
무중단 전환은 시도하지 않는다 — UI에 명시적 "재접속" 동작으로 노출.

---

## §8 안전 계층

| 위협 | 대응 | 경로 독립성 |
|---|---|---|
| E-STOP 지연/유실 | UDP ×3연발(0/50/100ms) + SSH 파일 병행 — 선착 승. 로봇 워치독(명령 신선도 600ms 슬루/2500ms 정지)이 최후방 | UDP·SSH·로봇측 3계 독립. 무선 ≤320ms 계약 |
| 입력 소스 상실(패드 단절) | gilrs Disconnected → 수퍼바이저 → E-STOP. TX는 InputFrame 신선도 >150ms에서 zero+disarm (이중) | 입력 스레드와 수퍼바이저 독립 감지 |
| 포커스 상실 · Game Bar 오버레이 | webview blur 이벤트 → 수퍼바이저 → E-STOP (의도 불명 상태에서 보행 지속 금지) | webview는 트리거만 — 발화는 Rust |
| 절전 진입 | `WM_POWERBROADCAST` PBT_APMSUSPEND → E-STOP 후 정리. 세션 중 `SetThreadExecutionState`로 절전 억제 | OS 메시지 → Rust 직접 |
| 렌더/webview 행 | 영향 없음(INV-2) + TX 틱 하트비트 워치독 >300ms → E-STOP (제어 루프 자체 행 감시) | 수퍼바이저가 TX와 독립 |
| 방화벽이 TEL2 인바운드 차단 | 설치 스크립트가 darwin-fpv.exe 인바운드 UDP 허용 규칙 등록 (`scripts/`) — 미허용 시 TEL2 침묵 = stale 표시로 정직 강등 | 텔레메트리 상실은 표시 강등일 뿐 명령·E-STOP 송신(아웃바운드)은 무관 |

---

## §9 리스크

| 리스크 | 심각도 | 완화 |
|---|---|---|
| ssh2 ↔ OpenSSH 5.9 레거시 kex 협상 실패 | **높음 — W1 최우선** | W1 첫 작업으로 실기 협상 검증. 실패 시 폴백 분기: russh(kex 커스텀) → plink 서브프로세스 |
| Windows 방화벽 TEL2 인바운드 차단 | 중 | 설치 스크립트 규칙 + 첫 실행 진단(TEL2 0수신 시 안내) |
| WebView2 MJPEG `<img>` 장시간 메모리 누수 | 중 | **W2 30분 soak 게이트** — 누수 시 주기적 src 재설정 또는 fetch+blob 회전으로 대체 |
| NIC 절전으로 RTT 스파이크 | 중 | 어댑터 절전 해제(설치 스크립트/안내) + RTT EMA HUD로 가시화 |
| 카메라 fps 기대치 오해 | 낮음 | 로봇측 한계(보행 중 ~8–15fps)를 UI·문서에 명시 — Ally측 최적화 대상 아님 |
| cross-workspace path 의존(forge-core) lock 이중화 | 낮음 | **의도된 격리로 허용** — app/ally 독립 workspace 결정의 비용. forge-core API 변경 시 ally 빌드로 즉시 검출 |

---

## §10 착수 가이드 (W1 시작 세션 필독)

W1(제어 코어 헤드리스 — 유선 실기 게이트, 1주)을 시작하는 세션은 다음을 순서대로 읽는다:

1. **이 문서** — 특히 §2(스레드 모델)·§6(크레이트 경계)·§7(세션 시퀀스).
2. **`app/ally/crates/df-wire/`** — W0 구현된 와이어 순함수·골든 벡터 테스트. ally-link/ally-input은 이 위에 쌓는다.
3. **`docs/ssh-parity-contract.md` §G** (G.1 핸드셰이크·G.2 E-STOP·G.3 명령·G.4 워치독·G.7 포트) + §A.2-TEL2 — 와이어의 단일 진실원. 재발명 금지.
4. **`tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py`** — SSH 세션·브로커리지 기동·파일 폴백의 검증된 참조 구현 (`_gait_params` = intensity 스케줄 원본).
5. 보조: `df_udp.py`(UDP 참조 구현·`local_ip_toward`) · `firmware-patches/walklab-brokerage/GamepadPilot.h`(매핑 상수 원본) · `WalkLabTransport.h`(로봇측 워치독·소프트 램프 상수).

W1 완료 게이트 = **ally-cli 헤드리스 수용시험을 유선 실기에서 통과**: 핸드셰이크 채택 ≤1s ·
20Hz 영명령 eff_hz ≥ 19 · E-STOP 발화→TEL2 정지 확인 · 메트릭 덤프. 실기 작업 시 리포 안전
수칙(크래들 + 다리 토크 해제 + 배터리 차단 인접) 준수.
