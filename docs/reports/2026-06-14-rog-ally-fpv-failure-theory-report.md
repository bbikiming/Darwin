# ROG Ally FPV 실패 원인 이론 검토 보고서

> ⚠️ **SUPERSEDED (2026-06-17 해소됨)** — 이 보고서는 W0 시점(2026-06-14)의 스냅샷이다.
> 당시 "Ally 쪽 실제 앱이 없다"는 판정은 이후 W1/W2 구현으로 **무효화**되었다.
> 2026-06-17 실기에서 ROG Ally 무선 FPV 조종(보행·헤드·카메라)이 검증되었다.
> 현행 사실은 [`2026-06-17-ally-fpv-wireless-control-success.md`](2026-06-17-ally-fpv-wireless-control-success.md)
> 를 참조하라. 본 문서는 당시 병목 분석·수정 지시서의 **역사적 기록**으로만 보존한다.

- 작성일: 2026-06-14
- 대상: `app/ally/`, `tools/switch-pilot/`, Mac 런처 `AllyFpv/*`
- 목적: Nintendo Switch에서는 앱/카메라/조종이 성립했는데 ROG Ally에서는 왜 성립하지 않는지, 병목이 어디인지, 허위 구현 또는 오해를 부르는 GUI가 있는지 Claude가 확인 후 수정할 수 있게 구체화한다.
- 결론 요약: **ROG Ally가 저성능이라 안 되는 것이 아니다. 현재 저장소 기준 ROG Ally 쪽은 실제 앱이 아직 없다.** 완성된 것은 `df-wire` 와이어 순함수와 `ally-link`/`ally-cli`의 헤드리스 연결 골격이며, 사용자가 기대하는 카메라 FPV 화면, 내장 패드 입력, 안전 상태머신, Tauri/WebView2 UI, 3D 포즈는 구현 전 또는 자리표시 상태다.

---

## 1. 최종 판정

### 1.1 왜 Switch는 되고 Ally는 안 되는가

Switch는 성능이 낮아도 다음 계층이 실제로 존재한다.

1. Linux 입력 런타임이 `/dev/input/event*`를 읽고, 선택된 컨트롤러의 축/버튼을 상태로 만든다.
   - 근거: `tools/switch-pilot/README.md:11-21`, `tools/switch-pilot/src/darwin_switch_agent/input_linux.py:256-361`
2. 로봇 제어 경로가 SSH 파일 경로 + UDP 패스트패스 + E-STOP + TEL2 수신으로 구현되어 있다.
   - 근거: `tools/switch-pilot/README.md:17-21`, `tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py:19-27`, `ssh_control_client.py:270-380`
3. 로컬 웹 콕핏, setup, 상태 점검, 카메라 터널, service worker, kiosk launcher가 실제 자산으로 있다.
   - 근거: `tools/switch-pilot/README.md:22-81`
4. 카메라 경로는 로봇 펌웨어 C1 패치 후 walklab 중 8080 MJPEG 라이브뷰가 실기 검증된 것으로 진행 문서에 기록되어 있다.
   - 근거: `PROGRESS.md:24`

반면 ROG Ally는 다음 상태다.

1. `darwin-fpv` Tauri 앱은 README만 있고 실제 `Cargo.toml`, `src/main.rs`, `tauri.conf.json`, 웹 UI가 없다.
   - 근거: `app/ally/crates/darwin-fpv/README.md:1-16`, 실제 파일 목록은 `README.md` 1개뿐.
2. `app/ally/ui`도 README만 있다. 카메라 `<img>`, HUD DOM, JS 이벤트 구독, CSS, asset copy가 없다.
   - 근거: `app/ally/ui/README.md:1-18`, 실제 파일 목록은 `README.md` 1개뿐.
3. `ally-input`은 상수 모듈만 있고 `gilrs` 의존성, 폴링 루프, `InputFrame`, ARM/E-STOP 상태머신이 없다.
   - 근거: `app/ally/crates/ally-input/src/lib.rs:1-9`, `app/ally/crates/ally-input/Cargo.toml:8-9`
4. `ally-pose`는 주석뿐이고 forge-core 의존성도 아직 없다.
   - 근거: `app/ally/crates/ally-pose/src/lib.rs:1-10`, `app/ally/crates/ally-pose/Cargo.toml:8-12`
5. Mac의 "FPV 조종" 탭은 Ally 앱이 아니라 **Ally로 SSH 명령을 보내는 런처/가이드 화면**이다.
   - 근거: `AllyFpvLauncherView.swift:4-11`, `AllyFpvCommands.swift:3-12`

따라서 현재 사용자가 Ally에서 "안 된다"고 느끼는 핵심 원인은 하드웨어 병목이 아니라 **제품 계층 미완성**이다. 더 정확히는 "Switch에서 검증된 개념을 Ally용으로 문서화하고 일부 Rust 통신 계층만 옮긴 상태"다.

### 1.2 ROG Ally 하드웨어는 병목인가

아니다. ASUS 공식 ROG Ally 페이지는 2023 ROG Ally 테스트 모델을 AMD Ryzen Z1 Extreme, 16GB RAM, Windows 11, 1920x1080 120Hz 디스플레이로 설명한다. Nintendo 공식 지원 문서는 Switch 휴대 모드 내장 화면의 최대 해상도를 720p로 설명한다. 즉 MJPEG 320x240, HUD 60fps, 3D GLB 733KB급 뷰어가 Ally에서 안 되는 것을 성능 부족으로 설명하기 어렵다.

하드웨어 관련 실제 병목 후보는 CPU/GPU가 아니라 다음이다.

1. Windows 방화벽/인바운드 UDP 허용.
2. Windows OpenSSH의 ControlMaster 부재로 인한 SSH 파일 폴백 지연.
3. Armoury Crate/Game Bar/절전/포커스 상실 같은 Windows 운용 이벤트.
4. WebView2의 장시간 MJPEG `<img>` 메모리 거동.

이들은 "성능"이 아니라 **운영체제 통합과 안전 루프 구현 문제**다.

---

## 2. 현재 구현 상태 표

| 계층 | Switch 현재 | Ally 현재 | 판정 |
|---|---|---|---|
| 입력 | evdev reader 구현. 컨트롤러 선택, axis normalize, deadman/arm/stop/estop role resolve 존재 | `ally-input`은 `g01` 상수만. `gilrs` 의존성 없음. 폴링/상태머신 없음 | **Ally 미구현** |
| 명령 와이어 | Python `df_udp.py` + `SshControlClient`가 UDP/SSH 운용 | `df-wire` 순함수 + `ally-link` UDP/SSH subprocess + `ally-cli` zero-stream | **부분 구현** |
| 실제 패드 조종 | Switch agent main loop에서 입력을 명령으로 연결 | `ally-cli connect`는 `MotionCommand::zero()`만 20Hz 송신. 패드 입력 미사용 | **조종 아님** |
| 카메라 UI | 로컬 cockpit, camera tunnel, MJPEG 표시 | `ui/README.md` 계획만 존재. `<img>` 없음 | **미구현** |
| Tauri 앱 | 해당 없음. Switch는 Chromium kiosk | `darwin-fpv` README만. workspace member 아님 | **미구현** |
| 3D 포즈 | Switch GLB viewer/model check 자산 존재 | `ally-pose` 주석뿐. forge-core link 없음 | **미구현** |
| Mac 런처 | Switch 연결 시트 실제 존재 | Ally 런처는 SSH 명령 트리거 + 준비 상태 확인 | **런처만 구현** |

---

## 3. "되는 것"과 "안 되는 것" 구분

### 3.1 현재 실제로 되는 것

1. `df-wire`의 명령/ACK/TEL2/E-STOP/handshake 순함수는 테스트된다.
2. `ally-link`의 UDP send/recv, SSH 명령 인자 구성, fallback 결정 로직은 단위 테스트된다.
3. `ally-cli selftest`는 로컬 루프백 에코 로봇으로 20Hz 송신과 ACK 메트릭을 검증한다.
   - 2026-06-14 로컬 실행 결과: 송신 40, ACK 40, `eff_hz 19.0`, PASS.
4. `ally-cli connect`는 실로봇에 대해 다음을 시도할 수 있다.
   - TCP :22 경로 프로브.
   - `/tmp/df-pilot-mode` 확인.
   - `/tmp/df-walklab-channel` handshake 기록.
   - UDP `DFCMD` 20Hz **영명령** 송신.
   - ACK/TEL2 drain.
   - ACK 침묵 시 SSH 파일 5Hz 폴백.
   - 선택 시 E-STOP burst + SSH touch.

### 3.2 현재 실제로 안 되는 것

1. ROG Ally 내장 패드로 로봇을 움직이는 것.
   - 이유: `ally-input`에 `gilrs`도 없고 폴링 루프도 없다.
   - `ally-cli connect`는 `MotionCommand::zero()`만 만든다. `app/ally/crates/ally-cli/src/main.rs:341-355`
2. ROG Ally 화면에 FPV 카메라를 띄우는 것.
   - 이유: Tauri 앱과 web UI가 없다.
   - `ui/README.md`에는 카메라 `<img>` 이관 계획이 있지만 실제 HTML/JS/CSS 파일이 없다. `app/ally/ui/README.md:8-18`
3. 터치 E-STOP.
   - 이유: `touch_estop` Tauri command와 Rust estop channel이 없다.
   - 설계 문서에는 필요 이벤트/커맨드가 정의되어 있으나 `darwin-fpv` 구현이 없다. `app/ally/docs/03_ARCHITECTURE.md:150-161`
4. ROG Ally에서 3D 합성 포즈를 보는 것.
   - 이유: `ally-pose`는 W3 구현 예정 주석뿐이다.
5. Armoury Crate 게임처럼 실행되는 단일 exe.
   - 이유: `darwin-fpv.exe` 산출 경로는 Mac 런처가 추정하지만, 실제 빌드 타깃이 없다. `AllyFpvCommands.swift:31-32`, `AllyFpvCommands.swift:94-103`

---

## 4. 병목 분석

### 병목 A: 구현 계층 부재

가장 큰 병목은 성능이 아니라 **실행 파일 자체 부재**다.

- `app/ally/Cargo.toml`은 `darwin-fpv`를 workspace member에 넣지 않는다. 주석으로 W2에서 추가한다고 명시한다. `app/ally/Cargo.toml:8-19`
- `crates/darwin-fpv/README.md`는 W0에서 의도적으로 비어 있다고 말한다. `app/ally/crates/darwin-fpv/README.md:3-5`
- `app/ally/ui/README.md`는 UI 이관 계획만 말한다. `app/ally/ui/README.md:1-18`

이 상태에서는 ROG Ally에서 "앱이 켜지지 않는다"가 정상이다. `target/release/darwin-fpv.exe`가 있을 수 없고, Mac 런처의 `fpvReadyProbe`는 `MISSING`이어야 한다.

### 병목 B: 입력 경로 부재

설계상 입력은 다음이어야 한다.

- `gilrs` 250Hz 폴링.
- `InputFrame` triple-buffer/latest-wins.
- B rising edge는 mapping/gate를 거치지 않고 estop channel로 즉시 발화.
- TX 20Hz 스레드는 input freshness >150ms면 zero+disarm.
- A=ARM, B=E-STOP, Y=복구 상태머신.

근거: `app/ally/docs/03_ARCHITECTURE.md:55-101`, `app/ally/docs/04_ACCEPTANCE_ROADMAP.md:74-110`

현재 구현은 다음뿐이다.

- `ally-input/src/lib.rs`가 `pub mod g01;`만 노출한다.
- `ally-input/Cargo.toml`에 `gilrs` 의존성이 없다.
- `g01.rs`는 매핑 상수일 뿐 입력을 읽지 않는다.

따라서 "Ally 내장 패드가 안 먹는다"는 문제가 있다면 원인은 드라이버가 아니라 **그 드라이버를 읽는 코드가 아직 없다**는 것이다.

### 병목 C: `ally-cli connect`를 조종으로 착각하는 문제

`ally-cli connect`는 헤드리스 수용시험 도구다. 실제 패드 조종 앱이 아니다.

증거:

- 파일 주석은 `selftest`, `probe`, `connect`를 "헤드리스 수용시험"으로 설명한다. `app/ally/crates/ally-cli/src/main.rs:1-9`
- `connect` 루프는 `MotionCommand::zero()`를 만들고 20Hz 송신한다. `app/ally/crates/ally-cli/src/main.rs:341-355`
- 패드 입력, stick axis, ARM 상태, B 버튼 이벤트가 `ally-cli`에 없다.

따라서 `ally-cli connect`가 성공해도 로봇이 움직이지 않는 것은 정상이다. 그것은 "조종 성공"이 아니라 "통신 경로가 영명령으로 살아 있음"의 증거다.

### 병목 D: SSH fallback 성능

Ally `ally-link`는 실제 네이티브 `ssh2` 세션이 아니라 시스템 `ssh` subprocess를 쓴다. 코드 주석은 OpenSSH 5.9 호환성 때문에 의도적으로 subprocess-ssh를 채택했다고 설명한다. `app/ally/crates/ally-link/src/ssh.rs:1-6`

이 선택은 UDP가 정상일 때는 괜찮다. SSH는 handshake/uplink/cleanup과 fallback에만 쓰인다. 그러나 UDP ACK가 안 오거나 Windows 방화벽/업링크 문제가 있으면 `select_transport`가 SSH 파일 폴백으로 전환한다. 그때 Windows에서는 ControlMaster가 꺼진다.

- Windows에서는 `SshClient::new`가 `control_path=None`을 둔다. `app/ally/crates/ally-link/src/ssh.rs:111-123`
- fallback은 `write_cmd_file`을 호출한다. `app/ally/crates/ally-link/src/ssh.rs:218-220`
- `ally-cli`는 fallback에서 `seq.is_multiple_of(4)`일 때만 파일을 쓴다. 20Hz 기준 약 5Hz다. `app/ally/crates/ally-cli/src/main.rs:366-377`

문제는 Windows `ssh.exe` 새 프로세스/새 연결이 로봇 OpenSSH 5.9와 매번 협상하면 5Hz도 안정적이지 않을 수 있다는 점이다. Switch는 Linux에서 ControlMaster 재사용을 했다. `tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py:76-84`

따라서 Ally에서 UDP가 죽으면 "부드러운 조종"이 아니라 "느리고 불안정한 생존 폴백"으로 봐야 한다. 실전 조종은 반드시 UDP ACK가 살아 있어야 한다.

### 병목 E: Windows 방화벽/업링크/TEL2

Ally의 UDP 수신은 `UdpControlTransport::bind("0.0.0.0:0")`로 동적 포트를 열고, 그 포트를 `/tmp/df-walklab-uplink`에 기록한다. `app/ally/crates/ally-link/src/udp.rs:43-64`, `app/ally/crates/ally-cli/src/main.rs:325-336`

Windows 방화벽이 `darwin-fpv.exe` 또는 `ally-cli.exe`의 UDP inbound를 막으면 TEL2와 ACK가 들어오지 않는다. 그러면 다음 현상이 난다.

1. `connect`가 첫 1.5초 probe 동안 UDP를 보냄.
2. ACK가 없어서 SSH fallback으로 전환.
3. `eff_hz < 19`가 되어 W1 게이트 실패.

`build-windows.ps1`의 방화벽 규칙은 아직 절차 주석뿐이다. `app/ally/scripts/build-windows.ps1:1-24`

### 병목 F: 카메라는 로봇 쪽은 해결됐지만 Ally UI가 없다

과거 타당성 보고서에서는 카메라가 로봇 펌웨어 문제였다고 정리했고, 같은 문서 안에 2026-06-12 C1 구현/실기 검증 완료 메모가 있다. 진행 문서도 walklab 중 8080 MJPEG 라이브뷰 실기검증을 완료로 기록한다. `PROGRESS.md:24`

하지만 Ally 쪽에서는 그 스트림을 표시하는 앱이 없다.

설계상 필요한 것은:

- Tauri `useHttpsScheme=false`.
- CSP `img-src`에 `http://192.168.123.1:8080`와 `http://192.168.0.33:8080` 허용.
- WebView2 `<img src="http://robot:8080/?action=stream">`.
- JS stall 감지와 Rust health check.
- 30분 soak.

근거: `app/ally/docs/03_ARCHITECTURE.md:165-176`

현재는 `ui/README.md`의 계획뿐이다. `app/ally/ui/README.md:16`

---

## 5. 허위 구현 또는 오해를 부르는 GUI/문서 점검

### 5.1 명백한 허위 구현은 아니다

코드와 문서 대부분은 "자리", "W2 구현", "W3 구현 예정"이라고 비교적 솔직하게 써 있다.

- `darwin-fpv` README: "의도적으로 비어 있다". `app/ally/crates/darwin-fpv/README.md:3-5`
- `ui` README: "웹 프론트 자리". `app/ally/ui/README.md:1`
- `ally-input`: "W1 구현 예정". `app/ally/crates/ally-input/src/lib.rs:1`
- `ally-pose`: "W3 구현 예정". `app/ally/crates/ally-pose/src/lib.rs:1`
- Mac 런처는 `fpvReady`가 false일 때 W2 앱 미빌드를 안내한다. `AllyFpvLauncherView.swift:282-294`

즉 저장소 안에 "완성된 것처럼 속이는 더미 앱"은 없다.

### 5.2 그러나 사용자 경험상 오해 위험은 크다

Mac 탭 제목과 개요 문구는 사용자 입장에서 "이미 FPV 조종 앱이 있는 것"처럼 읽힐 수 있다.

- 제목: "ROG Ally FPV 조종". `AllyFpvLauncherView.swift:38-39`
- 개요: "카메라 영상을 띄우고, 패드로 로봇을 1인칭 시점으로 조종합니다." `AllyFpvLauncherView.swift:82-87`

아래에서 `darwin-fpv(W2) 앱이 아직 빌드되지 않았다`고 안내하므로 완전한 허위는 아니지만, UX 계층에서는 기대를 먼저 만들고 나중에 제한을 말한다. 이 프로젝트의 "정직한 표시" 원칙을 적용하면 다음처럼 바꾸는 것이 안전하다.

- 현재 제목: `ROG Ally FPV 조종`
- 제안 제목: `ROG Ally FPV 준비/연결 게이트`
- 현재 개요: `패드로 로봇을 1인칭 시점으로 조종합니다`
- 제안 개요: `현재는 Ally 통신 게이트와 앱 준비 상태를 점검합니다. 실제 FPV 앱은 W2 구현 전입니다.`
- 현재 버튼: `연결 게이트 실연 (ally-cli connect)`
- 제안 버튼: `영명령 통신 게이트 실행 (조종 아님)`

### 5.3 문서/코드 불일치가 Claude를 잘못 유도할 수 있음

1. W1 수용 기준은 `ally-input`까지 포함하지만 실제 W1 구현은 `ally-link` 위주다.
   - 수용 기준: `app/ally/docs/04_ACCEPTANCE_ROADMAP.md:72-83`
   - 실제: `ally-input`은 상수만.
2. 일부 문서에는 `ssh2` 세션이라고 되어 있지만 실제 코드는 subprocess-ssh다.
   - 설계 문서: `app/ally/docs/03_ARCHITECTURE.md:75-79`, `03_ARCHITECTURE.md:201`
   - 실제 코드: `app/ally/crates/ally-link/src/ssh.rs:1-6`
3. 업링크 포맷 주석 불일치가 있다.
   - `ssh.rs` 상단 주석은 `UPLINK_PATH`를 `"ip:port"`라고 적지만, 바로 아래 함수와 설명은 `"<ip> <port>\n"` 공백 구분을 구현한다. `app/ally/crates/ally-link/src/ssh.rs:14-28`
   - 실제 로봇 계약상 공백 구분이 맞다. Claude가 "ip:port" 주석을 따라가면 TEL2가 죽을 수 있다.

Claude 수정 지시에는 **코드의 `uplink_value(ip, port)` 공백 구분을 단일 진실원으로 유지**하라고 명시해야 한다.

---

## 6. 실패 시나리오별 원인 지도

### 6.1 "Ally에서 FPV 앱 실행이 안 됨"

가능 원인:

1. `darwin-fpv.exe`가 없음. 현재 정상 상태.
2. `crates/darwin-fpv`가 workspace member가 아님. `app/ally/Cargo.toml:13-19`
3. Tauri 프로젝트가 init되지 않음. `tauri.conf.json` 없음.

판정 방법:

```powershell
cd C:\dev\Darwin\app\ally
Test-Path .\target\release\darwin-fpv.exe
Get-ChildItem .\crates\darwin-fpv
```

기대:

- 현재는 `MISSING`.
- `README.md` 외 파일이 없으면 구현 전.

### 6.2 "Ally에서 조종이 안 됨"

가능 원인:

1. 실제 패드 입력 코드 없음. 현재 최우선 원인.
2. `ally-cli connect`는 zero command만 보냄.
3. 로봇 `/tmp/df-pilot-mode`가 `walklab`이 아니면 `connect`가 중단됨. `app/ally/crates/ally-cli/src/main.rs:270-283`
4. 기존 Mac/Switch 세션이 있으면 handshake 경쟁 또는 channel 회전이 발생. `app/ally/crates/ally-cli/src/main.rs:285-323`
5. UDP ACK가 오지 않으면 SSH 파일 폴백으로 가며 W1 게이트 실패. `app/ally/crates/ally-cli/src/main.rs:356-377`, `app/ally/crates/ally-cli/src/main.rs:445-450`

판정 방법:

```powershell
cd C:\dev\Darwin\app\ally
cargo run -p ally-cli -- selftest
cargo run -p ally-cli -- probe --prefer wired
cargo run -p ally-cli -- connect --identity ~/.ssh/id_rsa_darwin --prefer wired --seconds 5
```

해석:

- `selftest` 성공: 로컬 UDP/메트릭 코드가 산다.
- `probe` 실패: 네트워크/로봇 SSH 도달성 문제.
- `connect`가 `df-pilot-mode 없음`: 로봇 walklab 데모 미실행.
- `connect`가 `eff_hz < 19`: ACK/TEL2/방화벽/토큰/업링크 문제.
- `connect` 성공: **영명령 통신 성공**이지 패드 조종 성공이 아니다.

### 6.3 "카메라가 안 뜸"

가능 원인:

1. Ally UI가 없음. 현재 최우선 원인.
2. 로봇 8080이 안 열림.
3. WebView2 CSP/mixed content 미설정. 아직 Tauri app이 없으므로 미적용.
4. Windows 방화벽/네트워크 경로가 로봇 8080에 접근 불가.

판정 방법:

```powershell
curl.exe http://192.168.123.1:8080/?action=snapshot --output frame.jpg
curl.exe http://192.168.0.33:8080/?action=snapshot --output frame.jpg
```

카메라 포트가 열리더라도 Ally 앱이 없으면 화면은 뜨지 않는다.

### 6.4 "Mac에서는 FPV 탭이 있는데 실제로는 아무것도 안 됨"

가능 원인:

1. Mac 탭은 실행 앱이 아니라 Ally로 명령을 보내는 런처다.
2. Ally IP/계정이 없으면 SSH 명령 자체가 실행되지 않는다.
3. `fpvReadyProbe`가 `MISSING`이면 W2 앱이 아직 없다.

판정:

- 이것은 Mac UI 버그라기보다 제품 단계 표시 문제다.
- 다만 UI copy를 "앱 실행" 중심에서 "준비 상태 점검" 중심으로 낮춰야 한다.

---

## 7. Claude 수정 지시서

### 7.1 절대 하지 말 것

1. ROG Ally 성능 최적화부터 하지 말 것. 현재 병목은 성능이 아니라 미구현이다.
2. UI만 먼저 만들어 조종되는 것처럼 보이게 하지 말 것.
3. `ally-cli connect`를 "조종 기능"으로 포장하지 말 것. 이것은 zero-stream 통신 게이트다.
4. 업링크 포맷을 `ip:port`로 바꾸지 말 것. `"<ip> <port>\n"` 공백 구분을 유지할 것.
5. WebView/JS에서 이동 명령을 만들지 말 것. 설계상 안전 경로는 Rust다.
6. 터치 E-STOP만 구현하고 물리 B 버튼 경로를 생략하지 말 것.

### 7.2 1순위: UX 정직성 패치

수정 대상:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/AllyFpv/AllyFpvLauncherView.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/AllyFpv/AllyFpvCommands.swift`

수정 내용:

1. 제목/개요를 "실제 조종 앱"처럼 읽히지 않게 바꾼다.
2. `ally-cli connect` 버튼을 "통신 게이트"로 명확히 표기한다.
3. `fpvReady == false`일 때 화면 상단에도 "W2 앱 미구현" 상태를 표시한다.
4. `w0Smoke` 주석의 "기대: 21 passed"는 현재 47개 테스트로 드리프트가 있으므로 "통과 여부" 중심으로 수정한다.

검증:

```sh
swift test --package-path app/ui/DarwinForge --filter AllyFpvCommandsTests
```

### 7.3 2순위: W1을 진짜 W1으로 완성

수정 대상:

- `app/ally/crates/ally-input/Cargo.toml`
- `app/ally/crates/ally-input/src/lib.rs`
- 새 파일: `input_frame.rs`, `state.rs`, `mapper.rs`, `poller.rs` 등
- `app/ally/crates/ally-cli/src/main.rs`

필수 구현:

1. `gilrs` 의존성 추가.
2. `InputFrame` 구조체:
   - normalized axes: left_x, left_y, right_x, right_y, lt, rt
   - buttons: A/B/X/Y/LB/RB/Menu 등
   - timestamp monotonic ms
   - connected flag
3. `InputPoller`:
   - 250Hz 목표.
   - device connected/disconnected 이벤트 반영.
   - B rising edge를 별도 `EstopEvent`로 즉시 발행.
4. `G01Mapper`:
   - `g01.rs` 상수를 사용.
   - deadzone, curve, trigger differential, head rate integration 구현.
   - output은 `df_wire::MotionCommand` 또는 그에 준하는 내부 command.
5. 안전 상태머신:
   - DISARMED -> ARMED(A)
   - B -> ESTOP_LATCH
   - Y -> recovering/armed 복구
   - stale >150ms -> zero+disarm
   - disconnected -> zero+disarm + estop 또는 최소 stop 정책 명확화
6. `ally-cli input-dump`:
   - Ally 현장에서 XInput 축/버튼 번호를 바로 확인.
   - raw + normalized + mapped command 출력.
7. `ally-cli drive-test --duration N --max-x ...`:
   - 크래들에서 실제 패드 입력을 읽어 zero가 아닌 명령을 보낼 수 있는 별도 명령.
   - 기본은 안전하게 ARM 필요, `--estop-test`는 명시 옵션 유지.

테스트:

```sh
cargo test --manifest-path app/ally/Cargo.toml -p ally-input
cargo test --manifest-path app/ally/Cargo.toml
cargo clippy --manifest-path app/ally/Cargo.toml --all-targets -- -D warnings
cd app/ally && cargo fmt --all --check
```

실기 게이트:

- `ally-cli input-dump`에서 A/B/Y/LT/RT/스틱 매핑 확인.
- B press -> 내부 estop event timestamp 로그.
- 패드 끊김 -> 다음 TX tick에서 zero+disarm 로그.
- 60초 eff_hz >= 19.

### 7.4 3순위: Tauri 앱 스캐폴딩

수정 대상:

- `app/ally/crates/darwin-fpv/`
- `app/ally/Cargo.toml`
- `app/ally/ui/`

필수 구현:

1. `crates/darwin-fpv/Cargo.toml` 추가.
2. `src/main.rs`에서 Tauri builder 전에 Rust control core thread를 시작할 수 있는 구조 작성.
3. `tauri.conf.json`:
   - fullscreen/borderless.
   - CSP `img-src`에 로봇 IP 8080 허용.
   - `useHttpsScheme=false` 확인.
4. UI 최소 파일:
   - `index.html`
   - `styles.css`
   - `app.js`
5. Rust -> UI event:
   - `state` 30Hz
   - `stick` 60Hz
6. UI -> Rust command:
   - `connect`
   - `disconnect`
   - `touch_estop`
7. `touch_estop`은 JS에서 안전을 처리하지 말고 Rust estop channel에 넣기만 한다.

최소 완료 정의:

- 앱이 켜진다.
- 연결 전 상태가 명확히 보인다.
- 카메라 이미지가 없는 상태를 정직하게 표시한다.
- `state` mock이 아니라 실제 `ally-link` snapshot에서 온 값을 보여준다.
- 패드 입력이 없으면 "패드 없음"으로 표시한다.

### 7.5 4순위: 카메라

필수 구현:

1. `<img id="fpv" src="http://192.168.123.1:8080/?action=stream">` 또는 selected path 기반 URL.
2. wired/wireless path에 따라 `192.168.123.1` / `192.168.0.33` 선택.
3. JS stall timer:
   - 최근 load/frame 진행 없음 -> `STALE`.
   - 일정 시간 후 src reset.
4. Rust health check:
   - 8080 TCP/HTTP 접근 가능 여부.
   - UI의 `cam.healthy`는 JS 단독 판단이 아니라 Rust 상태와 병합.
5. 30분 soak.

검증:

- direct camera URL 접속.
- 앱 내 표시.
- 카메라 끊김/복구.
- 보행 중 loop_ms/TEL2 age와 영상 fps 기록.

### 7.6 5순위: 3D 포즈

필수 구현:

1. `ally-pose`에 forge-core path dependency 추가.
2. TEL2 phase/x/y/a/period/IMU -> synthetic pose.
3. UI에는 반드시 "합성 포즈" 라벨 표시.
4. camera live 중 GPU 부하가 높으면 3D pause 또는 PIP 축소.

주의:

- TEL2에는 관절각이 없다. 실측 관절각처럼 표시하면 허위 GUI다.
- `ally-pose/src/lib.rs:3-6`의 정직성 원칙을 유지할 것.

---

## 8. 수정 우선순위

### P0: 사용자 오해 방지

- Mac 런처 copy 수정.
- `ally-cli connect`를 조종이 아닌 "zero command 통신 게이트"로 표기.
- 문서의 W1/W2/W3 상태를 현재 코드와 맞춘다.

### P1: 조종 핵심

- `ally-input` 실제 구현.
- `ally-cli input-dump`.
- `ally-cli drive-test`.
- `connect`와 drive-test를 분리해서 안전하게 유지.

### P2: 앱 핵심

- Tauri 스캐폴딩.
- Rust state hub.
- event bridge.
- 카메라 최소 표시.

### P3: 운영 안정성

- Windows firewall rule 실제 스크립트화.
- Windows power/focus supervisor.
- 30분 soak.

### P4: 3D/게임화

- `ally-pose`.
- Three.js PIP.
- Armoury Crate 등록/패키징.

---

## 9. 현재 검증 로그

2026-06-14 로컬 macOS에서 실행:

```sh
cargo test --manifest-path app/ally/Cargo.toml
```

결과:

- `ally-link`: 26 passed
- `df-wire`: 14 passed
- `df-wire parity`: 7 passed
- `ally-input`: 0 tests
- `ally-pose`: 0 tests
- `ally-cli` unit: 0 tests
- 총 의미 있는 통과: 47 tests

```sh
cd app/ally && cargo fmt --all --check
cargo clippy --manifest-path app/ally/Cargo.toml --all-targets -- -D warnings
```

결과:

- fmt check 통과
- clippy 통과

```sh
cargo run --manifest-path app/ally/Cargo.toml -p ally-cli -- selftest
```

결과:

- 송신 40
- ACK 40
- `eff_hz 19.0`
- selftest PASS

중요 해석:

- 이 검증은 와이어/루프백 검증이다.
- 실제 Ally 패드, WebView2, 카메라, 로봇 보행은 검증하지 않았다.

---

## 10. 보고서 결론

ROG Ally가 Nintendo Switch보다 성능이 높음에도 안 되는 이유는 단순하다.

**Switch는 낮은 성능 위에 완성된 런타임을 얹었고, Ally는 높은 성능 위에 아직 런타임이 없다.**

현재 ROG Ally 경로에서 신뢰할 수 있는 구현은 `df-wire`, `ally-link`, `ally-cli selftest/connect`의 헤드리스 통신 골격까지다. 사용자가 말하는 "앱", "카메라", "조종 연동"은 아래 순서로 아직 비어 있다.

1. 실제 앱 실행 파일 없음.
2. 실제 UI 없음.
3. 실제 패드 입력 없음.
4. 실제 카메라 표시 없음.
5. 실제 3D 합성 포즈 없음.

Claude가 다음에 고칠 때는 "ROG Ally 최적화"가 아니라 **미구현 계층을 순서대로 채우고, Mac 런처의 표현을 정직하게 낮추는 것**이 먼저다. 이 순서를 지키지 않으면 GUI는 그럴듯하지만 실제 조종과 안전 경로가 없는 허위 제품이 된다.

---

## 11. 참고 출처

### 로컬 코드/문서

- `app/ally/Cargo.toml`
- `app/ally/crates/darwin-fpv/README.md`
- `app/ally/ui/README.md`
- `app/ally/crates/ally-input/src/lib.rs`
- `app/ally/crates/ally-input/Cargo.toml`
- `app/ally/crates/ally-pose/src/lib.rs`
- `app/ally/crates/ally-link/src/ssh.rs`
- `app/ally/crates/ally-link/src/udp.rs`
- `app/ally/crates/ally-cli/src/main.rs`
- `app/ally/docs/03_ARCHITECTURE.md`
- `app/ally/docs/04_ACCEPTANCE_ROADMAP.md`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/AllyFpv/AllyFpvLauncherView.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/AllyFpv/AllyFpvCommands.swift`
- `tools/switch-pilot/README.md`
- `tools/switch-pilot/src/darwin_switch_agent/input_linux.py`
- `tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py`
- `tools/switch-pilot/src/darwin_switch_agent/control_bus.py`
- `PROGRESS.md`

### 외부 하드웨어 사양 확인

- ASUS ROG Ally 공식 페이지: https://rog.asus.com/us/gaming-handhelds/rog-ally/rog-ally-2023/
- Nintendo Support, YouTube for Nintendo Switch FAQ: https://en-americas-support.nintendo.com/app/answers/detail/a_id/42550/~/youtube-for-nintendo-switch-faq
