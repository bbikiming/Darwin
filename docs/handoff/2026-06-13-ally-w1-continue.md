# ROG Ally 로컬 Claude Code — W1 이어가기 핸드오프 (2026-06-13)

> 이 문서를 ROG Ally 기기의 로컬 Claude Code 세션에 **그대로 붙여넣어** 이어서 진행한다.
> Mac 세션이 방금 W1 연결 계층(`ally-link`)을 구현·검증·푸시했다(커밋 `d00b8ca`).

---

## 너의 임무 (한 줄)

ROG Ally(Windows 11, `C:\dev\Darwin`)에서 방금 푸시된 `ally-link` W1 연결 계층을 **Windows에서
빌드·검증**하고, **실로봇 유선/무선 W1 게이트**(헤드리스 `ally-cli connect`)를 통과시킨 뒤, 남은
W1(입력 `ally-input` gilrs + 네이티브 `darwin-fpv` Tauri 골격)을 착수한다.

## 지금까지 (Mac 세션이 한 것 — 재발명 금지)

- **진단**: "Ally가 로봇에 연결 안 됨"의 원인은 네트워크가 아니라 `ally-link`가 **28줄 빈 스텁**
  (송신 코드 0)이었던 것. 로봇측(WalkLabBrokerage UDP :17374/:17372 + `/tmp/df-walklab-channel`
  핸드셰이크 + 5Hz 파일 폴백)은 이미 준비돼 대기 중. Mac의 `ally-cli probe`가 실로봇
  `192.168.0.33:22` 도달을 확인함.
- **구현 (`d00b8ca`, 푸시됨)**: 검증된 Switch 클라이언트(`tools/switch-pilot/.../df_udp.py`,
  `ssh_control_client.py`)를 Rust로 1:1 포팅.
  - `app/ally/crates/ally-link/src/`: `ssh.rs`(ssh_args 1:1·핸드셰이크·업링크·5Hz폴백·estop·rm철회) /
    `udp.rs`(DFCMD+ACK/TEL2+`local_ip_toward`) / `metrics.rs`(RTT EMA α=0.3·eff_hz 1s) /
    `session.rs`(경로·전송 결정) / `lib.rs`(TCP :22 프로브).
  - **외부 크레이트 0** — `subprocess-ssh`(시스템 `ssh`/Windows `ssh.exe`에 레거시 `+ssh-rsa`
    플래그) 채택. ssh2 미사용 → **OpenSSH 5.9 협상 리스크 없음**. Windows는 ControlMaster off(의도적).
  - `app/ally/crates/ally-cli/src/main.rs`: `selftest`(루프백) / `probe` / `connect`(§7 전체).
- **검증**(macOS): `cargo test --workspace` 그린(ally-link 20·df-wire 21), `clippy -D warnings` 0,
  `selftest` 40/40 ACK·eff_hz 20.0. 적대적 4차원 리뷰 반영(RAII 핸드셰이크 가드·단일세션 가드·
  estop 게이트·데드라인 스케줄·드레인 상한 64).

## 먼저 읽을 것

- `app/ally/docs/03_ARCHITECTURE.md` **§2(7스레드)·§7(세션 시퀀스)·§9(리스크)** — 설계 정본.
- `app/ally/docs/04_ACCEPTANCE_ROADMAP.md` §2(W1 게이트).
- `app/ally/crates/ally-link/src/*.rs` — 방금 구현된 코드. `cargo doc --open -p ally-link`도 가능.
- 매핑 동결: `app/ally/crates/ally-input/src/g01.rs`(수치 변경 금지 — 실기 재검증 사유).

---

## STEP 0 — 최신 받기 + Windows 빌드 검증 (로봇 불요)

```powershell
cd C:\dev\Darwin
git pull                       # d00b8ca 수신
cd app\ally
cargo test --workspace         # 기대: ally-link 20 · df-wire 21 그린
cargo clippy --workspace --all-targets -- -D warnings   # 0 경고
cargo run -p ally-cli -- selftest                       # 루프백: 40/40 ACK·eff_hz ~20·PASS
```

- macOS에서만 빌드했으므로 **Windows 첫 빌드에서 cfg 차이가 나올 수 있다**. 나오면 고친다
  (예: `ssh.rs`의 `cfg!(windows)` 분기, `std::process::id()`). `ssh.exe`(OpenSSH 클라이언트)가
  설치돼 있어야 한다(`Get-Command ssh`). 없으면 `Add-WindowsCapability -Online -Name OpenSSH.Client*`.
- 로봇에 보내는 명령(`cat`/`mv`/`rm`/`touch`)은 **로봇의 Linux**에서 실행되므로 Windows와 무관.
- **방화벽**: TEL2 수신(UDP, 동적 로컬 포트)이 막히면 "연결됐는데 텔레메트리 0"으로 보인다.
  inbound 규칙 추가: `New-NetFirewallRule -DisplayName "ally-cli UDP" -Direction Inbound -Action Allow -Protocol UDP -Profile Private` (또는 ally-cli.exe 프로그램 규칙).

## STEP 1 — 경로 프로브 (읽기 전용, 안전)

```powershell
cargo run -p ally-cli -- probe --prefer wireless
# 기대: "✓ 도달: wireless (192.168.0.33)"  (유선 USB-C LAN 어댑터 연결 시 --prefer wired → 192.168.123.1, ~166x)
```

## STEP 2 — SSH 키 확인/프로비저닝 (robotis@로봇)

로봇은 **OpenSSH 5.9, RSA only**(ed25519 불가). Ally에 robotis용 RSA identity가 필요하다.

```powershell
# 이미 있으면 그대로 사용. 없으면:
ssh-keygen -t rsa -b 2048 -f $HOME\.ssh\id_rsa_darwin -N '""'
# 공개키를 로봇 robotis 의 authorized_keys 에 등록 (Mac의 기존 접근 또는 직접):
type $HOME\.ssh\id_rsa_darwin.pub   # 이 줄을 로봇 ~robotis/.ssh/authorized_keys 에 추가
# 검증:
ssh -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa -i $HOME\.ssh\id_rsa_darwin robotis@192.168.0.33 "echo ok"
```

## STEP 3 — ⚠️ 단일 세션 확보 후 실기 연결 (W1 게이트)

**안전 전제(반드시)**:
1. **로봇을 요람(maintenance stand)에 거치**, 다리 토크 차단 가능 상태, 배터리 분리 손 닿는 곳.
2. **Mac DarwinForge 앱 종료** — 켜져 있으면 connect 시 데모를 재시작시켜 세션이 깨진다.
3. **한 번에 한 운영자** — Ally의 connect는 토큰을 회전시켜 Mac/Switch 세션을 끊는다.
4. 로봇이 **walklab 모드**여야 한다(DarwinForge "조종기 데모 시작" 또는 로봇에서
   `robot_ready start-walklab`). connect가 모드 미충족 시 graceful 에러로 안내한다.

```powershell
# 20Hz 영명령(무동작 — enabled=0) 스트림으로 연결·eff_hz 게이트 검증:
cargo run -p ally-cli -- connect --identity $HOME\.ssh\id_rsa_darwin --prefer wireless --seconds 10
# 기대: 핸드셰이크→업링크→20Hz→"✓ W1 게이트 통과 (eff_hz ≥19)"→핸드셰이크 철회

# E-STOP 와이어아웃 증명(로봇을 estop 래치시킴 — 명시 옵션):
cargo run -p ally-cli -- connect --identity $HOME\.ssh\id_rsa_darwin --prefer wireless --estop-test
# 0/50/100ms ×3 DF-ESTOP + SSH touch. 정지 후 복구(Y)/데모 재시작 필요.
```

- connect는 `MotionCommand::zero()`만 보낸다 → **로봇은 움직이지 않는다**(연결 검증 전용).
- 기존 활성 세션 감지 시 `--force` 없으면 중단한다(의도적). 단독 운영 확인 후에만 `--force`.
- W1 게이트 측정값(eff_hz·RTT·정지 레이턴시)을 `docs/reports/2026-06-..-ally-w1-bringup.md`에 기록.

## STEP 4 — W1 잔여 구현 (소프트웨어 → 실기)

1. **`ally-input`**(gilrs 250Hz): `g01.rs` 동결 상수로 데드존→곡선→부호→레이트 적분 매핑 +
   안전 게이트 상태머신(DISARMED→ARMED→ESTOP_LATCH→복구) + B rising→무손실 estop 채널 +
   InputFrame 신선도(>150ms→zero+disarm). 호스트 단위테스트(매핑 수치는 g01 동결값으로 검증).
2. **`darwin-fpv`**(Tauri 2 bin, §2의 7스레드): 입력·제어TX·E-STOP·UDP RX·SSH세션·수퍼바이저 +
   메인(WebView2 표시전용 INV-2). `ally-link`/`ally-input` 위에 올린다. 워크스페이스 멤버로 추가
   (현재 W0 골격에서 제외됨 — Cargo.toml `members`에 `crates/darwin-fpv` 추가).
3. 모든 PR 게이트: `cargo test --workspace` 그린 + `cargo clippy --workspace --all-targets -- -D warnings` 0.
   df-wire 골든 벡터 패리티 깨지면 **픽스처가 아니라 Rust를 고친다**(`scripts/gen-golden-vectors.py`로 재생성).

## 작업 규율 (이 프로젝트 헌법)

- **재발명 금지**: 검증된 세 조상(Mac 콕핏 안전로직 · G01 매핑 · Switch 전송)의 합집합. 와이어
  포맷·매핑 수치를 발명하지 마라 — 계약 위반 = 로봇 오동작.
- **로봇 펌웨어 변경 없음** — Ally는 순수 클라이언트. (킥(LB/RB)은 온보드 동글 전용이라 이
  네트워크 데모엔 안 온다 — df-wire 14토큰에 킥 필드 없음. Switch도 동일. 원하면 별도 `DFKICK`
  데이터그램 확장 작업.)
- **커밋**: `feat(ally)`/`fix(ally)`, 본문 한국어 OK. 푸시 전 워크스페이스 테스트+clippy 그린 확인.
- **단일 자원 경합**: 로봇·세션은 한 번에 하나. 실기 접근 전 Mac/Switch 세션과 조율.

---

## 빠른 체크리스트

- [ ] STEP0: `git pull` + Windows `cargo test`/`clippy`/`selftest` 그린
- [ ] STEP1: `probe` 로 로봇 도달 확인
- [ ] STEP2: robotis RSA 키로 `ssh ... echo ok` 통과
- [ ] STEP3: `connect` eff_hz ≥19 게이트 통과 + `--estop-test` 정지 증명 (요람·Mac앱off·단독)
- [ ] STEP4: `ally-input`(gilrs) → `darwin-fpv`(Tauri) 골격 → 실기 W2(카메라·HUD)
