# DARwIn FPV — ROG Ally 무선 조종 성공 보고서

**일자**: 2026-06-17 (실기 입회 검증)
**대상**: ROG Ally(`192.168.0.30`, kus19) ↔ DARwIn-OP(`192.168.0.33`, robotis)
**브랜치**: `claude/ally-w1-core`
**결과**: ✅ 무선 FPV 조종 완성 — 보행(왼스틱)·헤드(우스틱) 정상, UDP ~12ms

---

## 1. 목표

ROG Ally(Windows UMPC)에서 `darwin-fpv-native` 네이티브 콕핏으로 DARwIn-OP를 **무선
FPV 조종**한다. 콕핏은 단일 `.exe`: 로컬 HTTP 서버(`127.0.0.1:8765`)가 임베드된 스위치
콕핏 웹을 서빙하고, Edge `--app`으로 렌더, gilrs로 게임패드를 읽어 ally-link(UDP/SSH)로
로봇 walklab 브로커리지에 명령을 보낸다.

## 2. 최종 검증 결과 (증거)

| 항목 | 측정값 |
|---|---|
| 연결 | `connected=true`, `transport=udp`, `target=robotis@192.168.0.33`(무선 wlan0) |
| 레이턴시 | 6~15ms (평균 ~12ms), 단발 최저 5.7ms |
| 패킷 손실 | 대부분 0% (가끔 5%) |
| IMU 텔레메트리 | `source=robot`, accel 실시간 갱신 |
| 카메라 | 로봇 8080 스냅샷 프록시 ~8fps (실시간 표시) |
| 게임패드 | 왼스틱→stride 38mm(전진)·side·turn 정상, 우스틱→head pan/tilt 정상 |
| 보행 실기 | 사용자 입회 "잘 걷고 헤드도 잘 움직였어" |

연결 경로: **Ally Wi-Fi(192.168.0.30, 5GHz) → 공유기 → 로봇 wlan0(192.168.0.33)**. 라우트
`InterfaceAlias=Wi-Fi` 로 확정 — 유선(이더넷2 123.107 ↔ 로봇 eth0 123.1)은 제어 경로 미사용.

## 3. 해결한 결함 (시간순)

### F1. SSH 키 미등록 (연결 자체)
콕핏 `control.rs::do_connect`는 SSH(BatchMode·키전용)로 walklab 게이트(`/tmp/df-pilot-progress
== walklab-active`)를 확인한다. 로봇 `~robotis/.ssh/authorized_keys`에 **Ally 공개키
(`ally-darwin`, Mac `darwin-robot`와 별개 키페어)** 가 없어 첫 SSH부터 실패 → `connected:false`.
사용자가 1회 등록(분류기가 에이전트 키주입 차단)으로 해소. **재부팅 후에도 키 유지됨 확인.**
- 비자명: ally-link ssh는 `-o IdentitiesOnly=yes`라 CLI 테스트 시 `-i id_rsa_darwin
  -o IdentitiesOnly=yes` 필수(없으면 다른 키 먼저 제시→MaxAuthTries→오탐 "Permission denied").

### F2. SshFile UDP 일방통행 트랩 (connected:false)
키 등록 후에도 `connected:false`·텔레메트리 0. **UDP 경로는 정상**이었으나(별도 PowerShell
DFCMD로 robot→Ally ACK 수신 확인), `darwin-fpv/runtime.rs` control-tx가 `decide_transport`
=SshFile일 때 UDP를 **전혀 안 보냄**(파일만 5Hz) → `last_ack` 영원히 미갱신 → SshFile 영구
고착. 재연결 시 채널 재읽기(1s) vs ACK_PROBE_MS(1.5s) 토큰채택 레이스로 초기 프로브 1회만
실패해도 회복 불가.
- **수정(2b3e1a0)**: SshFile 모드에서도 ~1Hz(UDP_REPROBE_TICKS=20틱@20Hz) UDP 재프로브 →
  경로 회복 시 ACK 도착 → last_ack 갱신 → 다음 틱 UDP 승격(self-heal, ~1s).

### F3. 카메라 — 로봇 MJPEG 스트림 0fps
콕핏이 `?action=stream`(멀티파트 MJPEG) 우선이었는데, 이 로봇 mjpg-streamer는 스트림
연결만 200 되고 **프레임을 0으로 굶김**(실측 3초 0바이트). `?action=snapshot`은 매번 새
JPEG 정상(카메라 캡처 살아있음). 추가로 `renderCameraLive`의 갱신 분류가 프록시 URL을 4분
주기로 오분류해 스냅샷조차 정지.
- **수정(1906f71)**: displayUrl을 snapshot 프록시 우선으로 복원 + 프록시 URL도 빠른 폴링
  분류 + 페이스 상향(CAMERA_SNAPSHOT_REFRESH_MS 180→120, RATE_MS 200→120, ~8fps).

### F4. 게임패드 축 0.00 ★ 결정타 — gilrs WGI 포커스 창 요구
XInput·연결·카메라 다 되는데 **스틱을 끝까지 잡아도 controller 축 8초간 0.00**(연결은 인식).
- **근본 원인(gilrs 공식 문서 확인)**: gilrs 0.11의 Windows 기본 백엔드는 **WGI(Windows.
  Gaming.Input)**. WGI는 *"프로세스가 포커스된 창을 소유"* 해야 패드 입력을 전달한다(터미널/
  창없는 앱은 입력 0). 콕핏은 gilrs를 **창 없는 tiny_http 서버 프로세스**에서 돌리고 Edge는
  별도 프로세스라, 포커스 창이 없어 WGI가 입력을 0으로 굶겼다. 열거는 되니 "연결됨"으로
  보이나 축·이벤트 0 → AxisChanged 미발생이라 active-추종 보정도 무력.
- **수정(7bfa8fd)**: `ally-input` Cargo.toml `gilrs = { version="0.11", default-features=false,
  features=["xinput"] }`. XInput은 포커스 무관 백그라운드 폴링(XInputGetState)이라 창 없는
  서버에서 동작. 부수효과로 XInput 슬롯만 열거 → 더미 "HID-compliant game controller"
  (DirectInput) 자동 무시.

### F-x. (배제) "안베르닉 데모 충돌" 아님
브로커리지엔 `local_control = m_gamepad.HasControl()`(온보드 패드 최근 1s 이벤트면 true) 게이트가
있어 true 면 Ally walk 명령을 폐기한다(WalkLabBrokerage.cpp:1068/1098). 그러나 실기에서 로봇
USB 동글 `1a34:f517`은 **`/proc/bus/input/devices`에 입력 핸들러가 없어**(전원/슬립버튼·오디오·
카메라만 존재) GamepadPilot가 읽을 evdev가 없음 → 이벤트 0 → `local_control` 항상 false →
Ally 명령 미차단. **충돌 아님으로 확정.**

## 4. 무선 레이턴시 프로파일 & 병목

- transport=UDP, 레이턴시 6~15ms, 손실 대부분 0%.
- 밴드 구조: **Ally=5GHz(`yukk_yeager_5G`)** 이나 **로봇 WiFi=Ralink RT3070(lsusb `148f:3070`)
  =2.4GHz 전용**. 통신은 `Ally —5GHz→ 공유기 —2.4GHz→ 로봇`. **레이턴시 바닥은 로봇 2.4GHz
  구간**이 결정.
- UDP 20Hz latest-wins 패스트레인이 지터·손실을 흡수 → 체감 반응성 양호.
- 안정 유지: 로봇·Ally를 공유기 가까이, 2.4GHz 혼잡 회피(채널 1/6/11). 더 낮추려면 로봇에
  5GHz USB WiFi 어댑터 교체가 유일한 HW 개선책.

## 5. 커밋

| 커밋 | 내용 |
|---|---|
| `2b3e1a0` | SshFile UDP 재프로브 self-heal |
| `1906f71` | 카메라 스냅샷 폴링 복원(~8fps) |
| `b4b7914` | 게임패드 active 입력패드 추종(더미 HID) |
| `a630706` | source.rs match 가드 정리(clippy clean) |
| `7bfa8fd` | **gilrs XInput 백엔드 강제 (결정타)** |

## 6. 재현 절차 (다음에 띄울 때)

1. 로봇 부팅 → 카메라 8080·`/tmp/df-pilot-progress=walklab-active` 확인.
2. Ally에서 콕핏 실행(데스크톱 세션 필수 — gilrs는 세션0에서 크래시, GUI 런처 SSH 불가).
3. 콕핏 자동연결(UDP) → 카메라 라이브 → 우스틱 헤드·복구(Y)→ARM(A)→왼스틱 보행.

> 주의: 콕핏의 gilrs는 데스크톱 세션에서만 동작(WGI든 XInput이든 세션0 헤드리스는 불가).
> 게임패드 조작은 사용자 직접.
