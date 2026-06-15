# ROG Ally — 다윈 메인 컨트롤 기기 전환 타당성 분석

- 작성일: 2026-06-12
- 근거 범위: 현재 저장소 소스코드·설계 문서·실기 검증 기록 (웹 리서치 미수행 — Ally 사양/가격은 대략치, 구매 전 확인 필요)
- 비교 대상: 현행 Nintendo Switch(Switchroot L4T) + `tools/switch-pilot` 체계

---

## 0. 한 줄 결론

**ROG Ally는 다윈 메인 컨트롤 기기로 전환 가능하며, 스위치 대비 명확한 업그레이드다.**
무선 데모 조종은 기존 switch-pilot 코드 ~80% 재사용으로 약 1~1.5주면 Windows에서 동작하고,
실시간 3D 자세 뷰도 구현 가능하다(맥 앱도 무선 모드에선 서보 실측이 아닌 합성 포즈를 쓴다 — 같은 방식 이식).
**유일한 조건부 항목은 카메라 실시간 뷰인데, 이것은 Ally·스위치·맥 공통의 로봇 펌웨어측 미해결 이슈**라서
기기 선택과 무관하게 로봇쪽 패치(워크플로 확립됨)가 선행돼야 한다.

## 1. 질문별 요약 답변

| 질문 | 답변 |
|---|---|
| Ally를 메인 컨트롤 기기로 활용 가능한가 | **가능.** 제어 채널(SSH+UDP)·텔레메트리(TEL2 30Hz UDP)·웹 콕핏이 전부 OS 중립이라 입력 백엔드만 교체하면 됨 |
| 스위치 대비 얼마나 좋은가 | 조종 레이턴시 자체는 **동급**(병목은 로봇측 무선 링크), 운영·화면·성능·확장성은 **전면 우위**, 무게·구축비용·이미 검증된 상태는 스위치 우위 |
| Windows에서 다윈포지급 마이그레이션 가능한가 | **단계적으로 가능.** forge-core(Rust)는 Windows에서 그대로 컴파일됨(C ABI 재사용). SwiftUI/SceneKit만 못 가져감 → UI는 웹 콕핏 강화 또는 Tauri/egui 신규 |
| 데모 무선 + 카메라 라이브뷰 + 3D 자세 뷰 | 무선 조종 ✅ (실기 검증된 경로 그대로) · 카메라 ⚠️ (로봇 펌웨어 패치 선행, 기기 무관) · 3D 자세 ✅ (TEL2 합성 포즈, 맥과 동일 방식) |

---

## 2. 기기 비교: ROG Ally vs Nintendo Switch

### 2.1 하드웨어·OS (대략치, 미검증)

| 항목 | Switch (현행) | ROG Ally (2023) | Ally X (2024) | ROG Xbox Ally / X (2025) |
|---|---|---|---|---|
| CPU | Tegra X1 (4×A57, ARM) | Ryzen Z1 Extreme (8C Zen4, x86) | Z1 Extreme | Z2 A / Z2 Extreme |
| RAM | 4GB | 16GB | 24GB | 16 / 24GB |
| 화면 | 6.2" 720p 60Hz | 7" 1080p 120Hz 터치 | 동일 | 동일 |
| 무선 | WiFi 5 | WiFi 6E | WiFi 6E | WiFi 6E |
| 배터리 | ~16Wh | 40Wh | 80Wh | 60 / 80Wh |
| 무게 | ~400g | 608g | 678g | ~670 / 715g |
| OS | L4T Ubuntu (해킹 필요) | **스톡 Windows 11** | 동일 | 동일 |
| 가격(추정) | 보유분 0원 | 중고/할인 ~$400대 | ~$700대 | ~$600 / $1,000 |

### 2.2 운영 관점 비교

| 관점 | Switch | ROG Ally | 판정 |
|---|---|---|---|
| 초기 구축 | RCM 익스플로잇 + Hekate + L4T 설치 + 봉인 스크립트(`tools/switch-appliance`) — 미패치 기기만 가능 | **해킹 불필요.** Python + OpenSSH(기본 내장) + 에이전트 설치 | **Ally** |
| 게임패드 | Joy-Con + joycond 데몬 의존 | 내장 XInput 패드(표준), pygame/SDL로 즉시 인식 | **Ally** |
| 제어 레이턴시 | UDP 20Hz, 입력→적용 ~50ms+WiFi RTT | 동일 경로·동일 수치 (병목 = 로봇 무선 링크) | 동급 |
| 영상·3D 처리 여력 | Tegra에서 키오스크 브라우저가 무거움 | x86 여력 충분: MJPEG 30fps 디코드 + 3D 동시 처리 무리 없음 | **Ally** |
| 유선 폴백 | 사실상 없음 | USB-C → LAN 어댑터로 로봇 이더넷 직결 가능 (~166배 빠른 유선 경로 확보 옵션) | **Ally** |
| 터치 E-STOP | 터치 있으나 키오스크 의존 | 터치 + 웹 콕핏 `/api/action` ESTOP 버튼 그대로 사용 | 동급~Ally |
| 봉인(전용기기화) | 스크립트 완비 (systemd 키오스크, overlayroot) | Windows 키오스크(Assigned Access)로 재구축 필요 — 선택 사항 | Switch |
| 무게·휴대성 | ~400g | 608g+ | **Switch** |
| 현재 상태 | **실기 검증 완료** (2026-06-07 SSH 브리지) | 미구축 (포팅 ~1.5주) | Switch |
| 유지보수 리스크 | L4T 커뮤니티 빌드 의존, 업데이트 단절 위험 | 정식 Windows — 단, 업데이트/드라이버 소음 관리 필요 | **Ally** |

**요약**: "얼마나 좋은가"에 대한 답 — **조종 품질(레이턴시)은 같고, 그 외 운영 전부가 좋아진다.**
특히 (1) 해킹·봉인 작업 제거, (2) 1080p 120Hz 터치 화면에서 영상+3D 동시 표시 여력,
(3) x86이라 forge-core(Rust)까지 올릴 수 있는 확장성이 결정적 차이다.
스위치가 이기는 항목은 무게, 이미 구축 완료된 상태, 추가 구매비 0원뿐이다.

---

## 3. 재사용 자산 분석 (소스코드 근거)

### 3.1 switch-pilot — 약 80% 그대로 감

`tools/switch-pilot`은 **외부 패키지 없이 표준 라이브러리만 쓰는 Python**이고, UI는 로컬 웹 콕핏
(`http://127.0.0.1:8765`, `cockpit.py`)이라 OS 중립이다. 모듈별 판정:

| 구분 | 모듈 | 판정 |
|---|---|---|
| 그대로 사용 | `df_udp.py`(TEL2 UDP 수신·DFCMD 송신), `mapping.py`, `safety.py`, `mac_relay_client.py`, `robot_udp_client.py`, `network_check.py`, `discovery.py`, `systemd_notify.py`(NOTIFY_SOCKET 없으면 무해 no-op), 웹 콕핏 정적 자산 | ✅ 포터블 |
| 경미한 심 필요 | `ssh_control_client.py`(`/tmp` 경로 상수), `config.py`(`/etc` 기본 경로 → `%APPDATA%`), `cockpit.py`(키오스크 브라우저 실행 명령 → Edge), `control_bus.py`(배터리 `/sys` 읽기 → WMI 또는 생략) | 🔧 1~2일 |
| 재작성 | `input_linux.py` — evdev(`/dev/input/event*`) + `fcntl.ioctl` 기반이라 Linux 전용. **pygame.joystick 또는 XInput으로 교체** (Ally 내장 패드는 표준 XInput로 잡힘) | 🔁 2~3일 |
| 생략 | `native_cockpit.py`(GTK), `tools/switch-appliance` 전체(Hekate/systemd/Plymouth — Windows 무관) | — |

핵심 와이어 프로토콜은 전부 이식 부담 제로:
- **명령**: UDP `DFCMD` 17374 (20Hz) + SSH 파일 폴백 `/tmp/df-walklab-cmd` (5Hz, 영구 보장)
- **E-STOP**: UDP 17372 3연발(0/50/100ms) + 파일 폴백 — 무선 E-STOP ≤320ms 계약 유지
- **텔레메트리**: TEL2 UDP 17371 30Hz + TEL v1 파일 폴백 (어댑티브 폴러 계약 §G.10)

### 3.2 Windows 포팅 시 주의점 2가지

1. **Windows OpenSSH는 ControlMaster(연결 멀티플렉싱) 미지원.**
   `ssh_control_client.py:84`가 `/tmp/df-cm-…` ControlPath로 웜 커넥션을 유지하는데, Win32-OpenSSH에는
   이 기능이 없다. 대안: (a) O1 UDP 경로가 이미 주 채널이므로 SSH는 세션 시작/정지·폴백용으로만 쓰고
   매 호출 새 연결 감수, (b) paramiko로 영속 세션 유지(전송부만 교체). 권장은 (b) — 로봇(Atom Z530)의
   SSH 핸드셰이크가 무겁기 때문(RSA, 수백 ms).
2. **매핑 설정이 evdev 키코드 기준** (`config.example.json`의 `deadman_key_codes: [312,313]` 등).
   XInput 버튼/축 → 역할(role) 추상 레이어를 한 겹 넣어야 한다. 데드맨=LT/RT 홀드, E-STOP=전용 버튼+터치
   병행이 자연스러운 매핑.

### 3.3 forge-core (Rust) — Windows에서 그대로 컴파일

의존성 감사 결과 macOS 전용 의존은 `cfg(target_os="macos")` libc(FTDI ioctl 레이턴시 튜닝)뿐이고,
`serialport 4.7`은 Windows를 지원한다. **x86_64-pc-windows-msvc 타깃으로 사실상 무수정 빌드 가능.**
- 순수 로직 모듈(walk 게이트 모델·synth·motion·dynamixel 코덱·control)은 전부 플랫폼 무관
- C ABI(cbindgen, `forge_core.h`)는 Swift 비종속 — **cdylib로 빌드하면 Python(ctypes)·Tauri·egui 어디서든 호출 가능**
- `fc_bus_open_tcp`(TCP 버스 전송)가 이미 존재 → 장기적으로 로봇측 serial→TCP 브리지를 세우면
  Ally에서 관절편집(Teach류) 모드까지 무선으로 여는 가능성 있음 (미검증, 장기 과제)

### 3.4 못 가져가는 것

- **SwiftUI/SceneKit 전체** — Mac 3D 뷰포트(`RobotScene3D.swift`, STL+URDF, Metal 30fps)는 macOS 전용.
  단, §4.3에서 보듯 *데이터 파이프라인*은 이식되고 렌더러만 새로 고르면 된다.
- Mac 앱의 Connection/Studio/Synth 등 상위 기능 — 메인 작업장은 계속 Mac, Ally는 "조종석" 역할 분담이 합리적.

---

## 4. 핵심 시나리오 판정

### 4.1 데모 무선 설정 + 조종 — ✅ 가능 (검증된 경로 그대로)

스위치에서 이미 실기 검증된(2026-06-07) 경로를 그대로 쓴다. Ally가 할 일은 동일:

1. 같은 AP에서 로봇 무선 IP `192.168.0.33`으로 SSH (identity 절대경로, `robot_ready.py`의 키 프로비저닝 헬퍼 재사용)
2. WalkLab 브로커리지 시작(데모 auto-mode 진입 경로) — `walkLabRobotisStart` 계약
3. 조종: UDP DFCMD 20Hz(핸드셰이크 성립 시) / SSH 파일 5Hz 폴백, 데드맨 홀드 + E-STOP 3중화

로봇 입장에서 클라이언트가 스위치인지 Ally인지 구분할 이유가 없다 — 와이어 계약(ssh-parity-contract)만 지키면 끝.

### 4.2 카메라 실시간 뷰 — ⚠️ 조건부 (로봇 펌웨어측 선결, 기기와 무관) — **근본 원인 코드로 특정됨**

**현상 (실기 확인)**: `demo` 바이너리가 `/dev/video0`과 포트 8080을 점유한 채, 제어(walklab) 모드에서는
프레임을 내보내지 않는다. **Ally를 사도 이 문제는 그대로다. 스위치·맥·Ally 공통의 로봇측 문제다.**

**근본 원인 (2026-06-12 코드 추적으로 확정)**: 미스터리가 아니라 우리 패치의 구조적 결과다.

1. 원본 demo `main.cpp`: L63 `LinuxCamera::Initialize(0)` → L67 `new mjpg_streamer(...)`(8080 httpd
   스레드 기동) → 메인 루프에서 L159 `CaptureFrame()` + L249 `streamer->send_image(rgb_output)`.
2. 우리 `main.cpp.patch`는 그 메인 루프 **진입 직전**에 `WalkLabBrokerage().Run(&cm730)`으로 분기한다.
   → 카메라와 8080 서버는 이미 켜진 상태로 남고(점유 현상 일치), **프레임을 밀어 넣는 펌프 루프만 영원히
   실행되지 않는다**(프레임 미출력 일치). 클라이언트는 접속은 되지만 프레임을 기다리다 멈춘다.
3. 결정적으로, `WalkLabBrokerage.cpp` L303은 **볼트래킹용으로 이미 `CaptureFrame()`을 ~30fps로 호출**하고
   있다(L846 주석: 캡처가 루프를 카메라 페이스로 끌고 감). 빠진 것은 `send_image()` 연결 단 하나다.
   `streamer` 포인터가 main()의 지역 변수라 브로커리지에 전달되지 않았을 뿐.

**해결 경로** (펌웨어 패치 워크플로는 TEL2 패치 daa2550으로 이미 확립):

| 안 | 내용 | 평가 |
|---|---|---|
| C1 (권장) | `Run(&cm730, streamer)`로 포인터 전달 + 프레임 펌프: 볼트랙 중엔 기존 캡처에 `send_image()`만 추가(추가 캡처 비용 0), 평시엔 별도 pthread 또는 10~15fps 레이트캡 펌프 | **수십 줄 수준의 최소 패치.** 기존 리빌드 워크플로(install-onboard.sh) 그대로. 보행 루프 영향은 TEL2 `loop_ms` 필드로 실측 검증 가능(계기판 이미 내장) |
| C2 | walklab 모드에서 카메라 init 자체를 건너뛰고 독립 `camera_tutorial` 데몬 병행 | 프로세스 분리로 안전하나 **볼트래킹(X버튼, 실소비 중인 기능)을 잃거나 복잡해짐** — C1이 상위호환 |
| C3 | V4L2 loopback 등 커널 모듈 | 커널 3.x에 모듈 추가 — 비현실적, 기각 |

**CPU 여력 증거**: 원본 SOCCER 모드는 같은 Atom Z530에서 캡처+컬러파인더 4개+보행+JPEG 인코드+8080
스트리밍을 **동시에** 수행한다(원본 main.cpp L159~249). C1의 부하는 그보다 가볍거나 같다.

**대역폭**: 320×240 JPEG q80 ≈ 10~25KB/프레임 → 15fps ≈ 1.2~3Mbps. 로봇 무선 링크에서 감당 가능한
수준이나 실기 확인 항목. 부족하면 10fps 캡 또는 직접 8080 접속(SSH 암호화 비용 제거)으로 조정.

> **추가 (2026-06-12 당일): C1 구현·실기 검증 완료.** walklab 제어 모드 중 스냅샷·스트림(로컬 ~8fps/
> 220kbps, 어두운 실내 기준)·원격 8080·SSH 터널(18080) 모두 동작, 클라이언트 강제 끊김 2회 생존,
> supervisor loop_ms 101 무영향(E-STOP 유휴 기준). 구현 중 함정 2개 발견·해결: send_image 무조건
> 호출(missed-wakeup 회복 경로), SIGPIPE SIG_IGN(끊긴 스트림 소켓 write 가 데모 전체를 죽이던 공장
> 취약점). 잔여 확인: 보행 중 스트리밍의 loop_ms 영향(사용자 입회 측정). 스위치 콕핏은 코드 수정
> 없이 호환(터널 헬퍼 헬스체크 통과 → 터널만 개통, CameraFrameProxy 스냅샷 폴링 그대로).

**클라이언트 쪽은 이미 끝나 있다**: 로봇이 프레임만 내보내면
- 웹 콕핏의 `CameraFrameProxy`(cockpit.py, MJPEG 프록시+레이트 제한)와 설정 키(`camera.stream_url`, SSH 터널 18080→8080)가 그대로 동작
- 브라우저 `<img src=".../?action=stream">` 한 줄로 MJPEG 표시 (맥의 `MjpegStreamingClient.swift`가 검증한 파싱을 브라우저가 네이티브로 해줌)
- 스트림 사양: 320×240 @ 최대 30fps, JPEG q80 — Ally에선 디코드 부하가 사실상 0

### 4.3 현재 자세 3D 모델 뷰 — ✅ 가능 (맥과 동일한 '합성 포즈' 방식)

**중요 사실**: 무선 모드에서는 **맥 앱도 서보 실측 각도를 쓰지 않는다.**
- TEL2 계약상 무선 텔레메트리에 관절각이 없다 — BULK_READ 범위가 CM-730 RAM+FSR뿐 (per-joint 위치 제외)
- 맥 3D 뷰포트의 보행 모드 포즈는 `WalkLabSession.visualPose` = **워크 엔진이 위상으로 합성**한 포즈이고,
  IMU roll/pitch만 실측으로 보정한다 (`WalkLabSession+Tick.swift:154`, `RobotScene3D.swift:41`)
- 서보 실측 포즈는 관절편집(bus) 모드의 Teach에서만 쓴다 (200ms 폴링 시리얼 리드백)

따라서 Ally에서도 같은 데이터로 같은 품질의 자세 뷰가 나온다:

```
TEL2 30Hz (phase, x/y/a/period 래치, IMU, FSR/CoP)
   → 워크 엔진 순기구학 합성 (forge-core walk 모듈, Rust)
   → 20관절 각도 → 3D 렌더
```

**구현 옵션**:

| 안 | 합성 계산 | 렌더 | 평가 |
|---|---|---|---|
| V1 (권장) | forge-core walk → **wasm** (순수 Rust라 wasm-bindgen 직행) | 웹 콕핏 + Three.js, 관절 분리 GLB | 단일 진실원(Rust 게이트 모델) 유지, 콕핏에 그대로 합류. switch-pilot에 이미 GLB 뷰어(`/model-check.html`)와 GLB 가공 스크립트(`assets/`) 존재 |
| V2 | forge-core cdylib + Python ctypes → 포즈 JSON을 콕핏 WebSocket으로 30Hz 푸시 | 동일 | wasm 빌드가 막히면 차선 |
| V3 | JS로 게이트 기구학 재구현 | 동일 | 기각 — Rust 원본과 드리프트 |

추가 작업: 현재 GLB가 단일 데시메이트 메쉬라면 링크별 분리 메쉬로 재추출(맥의 STL/URDF 세트에서 생성,
가공 스크립트 재사용) + Three.js 조인트 트리 리깅. FSR/CoP 지지 다각형 오버레이도 같은 TEL2 필드로 재현 가능.

**한계 고지**: 합성 포즈는 "지령 기준 + IMU 보정" 근사다. 낙상·미끄러짐 순간의 실제 관절각과는 다를 수 있다
— 이는 맥 앱도 동일한 한계이며, 무선 계약(TEL2)이 관절각을 싣지 않는 한 어떤 기기로도 못 넘는 선이다.

---

## 5. 마이그레이션 경로 3안

| | A안: switch-pilot 포팅 | B안: A + 웹 콕핏 강화 (권장 목표) | C안: 다윈포지급 네이티브 |
|---|---|---|---|
| 내용 | 입력 백엔드 교체 + 경로 심 + SSH 전송부 paramiko화 | A + 카메라 뷰(로봇 패치 C1 선행) + 3D 자세 뷰(V1 wasm) | Tauri 2(Rust 백엔드 = forge-core 직링크) 신규 콕핏, 장기적으로 TCP 버스 Teach까지 |
| 공수 | **1~1.5주** | **+2~3주** (로봇 패치 ~1주 + 3D ~1.5주 병행 가능) | 4~8주 |
| 결과물 | 스위치와 동등한 무선 조종 | **사용자가 요구한 풀 시나리오** (무선 데모 + 영상 + 3D 자세) | 맥 앱 기능 상당수의 Windows 이주 |
| 리스크 | 낮음 (와이어 계약 불변) | 중간 (로봇 펌웨어 패치 실기 검증 필요) | 높음 (범위 큼, 당장 불필요) |

**권장**: A → B 순차 진행. C는 B 운용 후 필요성이 증명되면. 맥은 모션 저작·정밀 작업(Studio/Teach/Synth)의
메인 작업장으로 유지하고, Ally는 "현장 조종석"으로 역할을 나누는 구도가 현재 아키텍처(원장: 로봇 온보드
브로커리지가 제어권, 클라이언트는 지령+표시)와 정확히 맞는다.

## 6. 레이턴시·안전 분석

- **입력→적용**: Ally 내장 패드(내부 USB HID, ~ms급) → UDP 20Hz → 온보드 셰이핑(거버너/슬루/게이트) 적용.
  스위치와 동일 클래스(~50ms + WiFi RTT). 병목은 클라이언트가 아니라 **로봇의 무선 링크**이므로 기기 교체로
  더 줄진 않는다. 최저 레이턴시가 필요하면 별도 트랙인 G01 동글 직결안(H0~H3, p95≤40ms 목표)이 정답이며,
  Ally 내장 패드는 로봇에 직결할 수 없으므로 그 영역을 대체하지 않는다.
- **E-STOP 3중화 유지**: UDP 3연발(0/50/100ms) + SSH 파일 + 로봇측 워치독(명령 신선도). 무선 ≤320ms 계약.
  Ally에서는 전용 버튼 + 화면 상시 터치 ESTOP(`/api/action`)을 병행 배치할 것. E-STOP 경로에
  디바운스/스로틀/컨플레이션 금지 불변식(cockpit-latency-hardening §S1)은 포팅 시에도 그대로 적용.
- **데드맨**: LT/RT 홀드 유지. 입력 소스 상실(패드 분리·앱 정지) 시 throttle-to-zero는 로봇측 명령 신선도
  워치독이 최종 방어선이므로 클라이언트 OS와 무관하게 성립.
- **유선 옵션**: USB-C LAN 어댑터로 로봇 이더넷 직결 시 ~166배 빠른 유선 경로(123.1 계열)를 Ally도 확보
  가능 — 텔레메트리 고착 시 폴백으로 가치 있음.

## 7. 리스크 및 미확인 사항

1. **카메라 — 원인은 확정, 실기 검증만 남음.** 프레임 미출력의 근본 원인은 코드로 특정됐고(§4.2) C1 패치는
   수십 줄 규모다. 남은 변수는 보행 중 인코드 부하(TEL2 loop_ms로 실측)·무선 대역폭·캡처 스레드 배타 처리
   3가지로, 모두 실기 1회 검증으로 판정 가능. 기기 구매와 독립적 — Ally를 사기 전에 스위치/맥으로 검증 가능.
2. Windows OpenSSH ControlMaster 부재 — paramiko 전환분의 테스트 필요 (전송부 추상화는 이미 돼 있어 국소적).
3. Ally 내장 패드의 트리거(LT/RT)가 XInput 축으로 잡히므로 데드맨 "홀드" 판정 임계 설계 필요 (기존 키코드
   홀드와 의미 동일하게).
4. GLB 아티큘레이션 상태 미확인 — 현재 콕핏 GLB가 관절 분리돼 있는지 확인 필요, 아니면 STL에서 재추출.
5. Ally 사양·가격은 본 보고서에서 웹 미검증 대략치. 구매 시점에 모델(무게·배터리 차이 큼: Ally 40Wh vs
   Ally X 80Wh)을 실측 확인할 것. 장시간 현장 운용이면 80Wh급(X 계열)이 안전.
6. Windows 절전/업데이트가 조종 중 끼어들지 않도록 운용 프로파일(전원 설정, 알림 차단, 선택적 키오스크화)
   구성 필요 — 스위치 봉인 스크립트의 Windows 등가물은 새로 만들어야 함(선택 사항).

## 8. 권장 로드맵

| 웨이브 | 내용 | 산출물 | 공수 |
|---|---|---|---|
| RA0 | 로봇 카메라 패치 C1 + 실기 검증 (기기 무관, 스위치/맥으로 검증) | 제어 모드 중 MJPEG 10~15fps 송출 | ~1주 |
| RA1 | switch-pilot Windows 포팅 (입력 XInput, 경로 심, paramiko, 콕핏 키오스크) | Ally에서 무선 데모 조종 + 기존 콕핏 HUD | 1~1.5주 |
| RA2 | 콕핏 카메라 패널 활성 (RA0 결과물 + 기존 CameraFrameProxy) | 영상 보며 조종 | 2~3일 |
| RA3 | 3D 자세 뷰 (forge-core walk wasm + 관절 GLB + Three.js, FSR/CoP 오버레이) | 실시간 자세 모델링 표시 | 1~2주 |
| RA4(선택) | Tauri/egui 네이티브 콕핏, TCP 버스 실험 | 다윈포지급 확장 | 4~8주 |

RA0과 RA1은 의존성이 없어 병행 가능. RA0~RA3 완료 시 사용자가 정의한 풀 시나리오
(무선 데모 + 실시간 영상 + 3D 자세 + 조종)가 Ally 단일 기기에서 성립한다. 총 공수 약 3~4주.

---

## 부록 A. TEL2 필드 (무선 30Hz UDP, 포트 17371)

```
TEL2 {ts} {seq_applied} {phase} {x_lat} {y_lat} {a_lat} {period_lat}
     {gx} {gy} {gz} {ax} {ay} {az}
     {fsr: l1..l4 r1..r4 | -} {cop: copx copy | -}
     {fallen} {risk|-} {vdV} {active_source} {loop_ms}
```

3D 자세 합성에 쓰는 필드: `phase`(보행 위상 0..3), `x/y/a/period_lat`(셰이핑 적용된 실제 보행 진폭),
`gx..az`(IMU 틸트 보정), `fsr/cop`(지지 다각형 오버레이). **관절각 없음** — 합성 포즈가 계약상 상한.

## 부록 B. 주요 근거

- 와이어 계약: `docs/ssh-parity-contract.md` (§A.2-TEL2, §C 명령 14토큰, §G UDP/어댑티브 폴러)
- 이식성 감사 대상: `tools/switch-pilot/src/darwin_switch_agent/` (특히 `input_linux.py`=유일한 Linux 전용 코어,
  `df_udp.py`=완전 포터블, `cockpit.py` 웹 콕핏+CameraFrameProxy)
- 카메라 이슈: `docs/firmware-reference/05-vision-pipeline.md`,
  `docs/reports/2026-06-04-switch-robot-camera-hud-feasibility.md`, 실기 메모(2026-06, 미해결)
- 3D 포즈 소스: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:862`(visualPose),
  `WalkLab/WalkLabSession+Tick.swift:154`, `Visualization/RobotScene3D.swift:41`
- Rust 이식성: `app/core/*/Cargo.toml` (macOS 전용 의존 = cfg-gated libc 단 1건), `forge-ffi` cdylib + cbindgen
- 동글 직결 설계(별도 트랙): `docs/design/handheld-direct-pilot-upgrade.md` (H0~H3, 미착수)
