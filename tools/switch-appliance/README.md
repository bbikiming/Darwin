# Darwin Switch Appliance (봉인 레이어)

> 한 줄 요약: 전원을 넣으면 **곧장 Darwin 조종석(cockpit)만 뜨는 전용 로봇 제어
> 단말**로 Switchroot L4T Ubuntu를 봉인하는 레이어. **Nintendo 펌웨어를 바꾸는
> 것이 아니다** — SD카드 위 Linux 부팅 경험만 봉인하고, SysNAND(정품)는 그대로
> 둔다.

이 디렉터리(`tools/switch-appliance/`)는 기존 에이전트 번들
[`tools/switch-pilot`](../switch-pilot) 위에 **부팅·봉인·런타임·안전/복구** 레이어를
덧입힌다. 새로 앱을 짜지 않고, 봉인 스크립트와 systemd 유닛으로 "공장 출하된 전용
기계"처럼 고정한다.

비유로: `switch-pilot` 이 "일반 노트북에 조종 앱을 설치한 상태"라면, 이 레이어는 그
노트북을 **켜면 한 화면만 뜨고, 잠들지 않고, 사용자가 실수로 못 깨뜨리며, 망가져도
정해진 길로 되돌아오는** 전용 단말로 바꾸는 작업이다.

설계 문서: [`docs/prd/darwin-switch-appliance-design.md`](../../docs/prd/darwin-switch-appliance-design.md)

---

## 4개 레이어

| 레이어 | 역할 | 핵심 파일 |
|---|---|---|
| **L1 — Boot** | 켜면 메뉴 없이 L4T Ubuntu(Darwin)로 자동 부팅. Vol- 탈출구 유지. | `boot/hekate_ipl.ini.example` |
| **L2 — Seal** | suspend/sleep 차단, 자동 로그인, SSH 잠금, kiosk 세션, 부팅 브랜딩. | `seal/`, `session/`, `branding/` |
| **L3 — Runtime** | cockpit 에이전트 + 첫 부팅 프로비저닝(setup) + systemd watchdog. | `tools/switch-pilot/` (재사용) |
| **L4 — Safety + Recovery** | 전원 버튼 → 로봇 STOP/ESTOP. Vol- 기반 복구. | `power-button-stop/`, `RECOVERY.md` |

L3 런타임은 이 디렉터리가 **새로 만들지 않는다** — `tools/switch-pilot` 의 에이전트
(cockpit `http://127.0.0.1:8765/`, `setup.html` 프로비저닝, systemd watchdog)를 그대로
설치해 쓴다. 이 레이어는 그 위에 봉인을 입힐 뿐이다.

---

## 파일 맵

```
tools/switch-appliance/
  apply-appliance.sh          # 마스터 설치기 (idempotent). sudo로 실행.
  VERSION                     # 어플라이언스 OS 버전 (현재 0.1.0)
  README.md                   # (이 문서)
  RECOVERY.md                 # 비전문가용 복구 가이드 (한국어)

  boot/                       # --- L1 BOOT ---
    hekate_ipl.ini.example    # Hekate autoboot 설정 예시 (SD /bootloader/로 복사)

  seal/                       # --- L2 SEAL ---
    no-sleep.sh               # sleep/suspend/hibernate 차단 (drop-in). root, idempotent.
    autologin.sh              # 'darwin' 사용자 생성 + tty1 자동 로그인 (drop-in). root.
    ssh-harden.sh             # 키-only SSH (키 있을 때만; anti-lockout). root.
    overlayroot.conf          # read-only rootfs 설정 내용
    overlayroot.sh            # OPT-IN read-only rootfs (--confirm 필요). root.

  session/                    # --- L2 SESSION ---
    darwin-kiosk.sh           # kiosk 진입점 (cage/openbox 공용) -> /usr/local/bin/
    darwin-kiosk.service      # PRIMARY: cage(Wayland) kiosk systemd 서비스
    openbox-autostart         # FALLBACK: openbox(X11) autostart 내용

  branding/                   # --- L2 BRANDING ---
    README.md                 # Plymouth 설치/검증/제거 가이드
    plymouth/darwin/
      darwin.plymouth         # 테마 디스크립터
      darwin.script           # 부팅 스플래시 스크립트 (logo.png는 사용자 제공)

  power-button-stop/          # --- L4 SAFETY ---
    darwin-power-stop.py      # 전원/슬립 버튼 -> cockpit /api/action STOP/ESTOP
    darwin-power-stop.service # systemd 서비스 (User=root)
```

---

## 적용 방법

기기(**Switchroot L4T Ubuntu가 이미 부팅되는 Switch**)에서, SSH 또는 로컬 터미널로:

```bash
cd tools/switch-appliance
sudo ./apply-appliance.sh
```

미리 보기(아무 것도 바꾸지 않음):

```bash
./apply-appliance.sh --dry-run
```

read-only rootfs 까지 함께 켜기 (post-MVP, 위험 이해 후):

```bash
sudo ./apply-appliance.sh --with-overlayroot
```

설치기가 하는 일 (모두 idempotent, 재실행 안전):

1. `tools/switch-pilot/install.sh` 로 cockpit 에이전트 설치.
2. 이 디렉터리를 `/opt/darwin-switch-agent/appliance/` 로 복사(전원 버튼 서비스가
   그 경로의 스크립트를 가리킴).
3. `seal/` 의 no-sleep / autologin / ssh-harden 적용.
4. kiosk 세션 설치 — `cage` 가 있으면 `darwin-kiosk.service`(Wayland), 없으면
   openbox(X11) autostart 로 폴백. `darwin-kiosk.sh` 는 양쪽 모두 설치.
5. `darwin-power-stop.service` 설치·활성화 (전원 버튼 안전 정지).
6. Plymouth `darwin` 부팅 테마 설치 (Plymouth가 있을 때만, 비치명적).
7. `/etc/darwin-switch-os-release` 에 버전 기록 후 `systemctl daemon-reload`.

L1 부팅(autoboot)은 SD카드 `/bootloader/hekate_ipl.ini` 수정이 필요하므로
**설치기가 자동으로 바꾸지 않는다.** `boot/hekate_ipl.ini.example` 를 보고 직접
복사·검증한다(특히 `bootwait>=3` 유지).

---

## 사전 조건 (prerequisites)

- **Switchroot L4T Ubuntu가 이미 부팅되는 상태.** 이 레이어는 설치된 Linux 위에
  봉인을 입힐 뿐, Linux 자체를 설치하지 않는다(설치는 Switchroot 공식 절차).
- **SSH 접근 가능** (또는 기기에서 직접 터미널 사용). 헤드리스 봉인을 위해 SSH는
  사실상 필수다. `ssh-harden.sh` 는 키가 있을 때만 비밀번호 로그인을 끈다(잠김 방지).
- `sudo` 권한(설치기는 root 필요; `--dry-run` 은 root 없이도 미리 보기 가능).
- 선택: `cage`(Wayland kiosk). 없으면 openbox 폴백. `plymouth`(부팅 브랜딩, 선택).

---

## 하드웨어 검증 상태 (정직하게)

> **현재 하드웨어에서 검증된 것은 없다.** 이 레이어 전체가 아직 실제 Switch에서
> 돌려본 적 없는 상태다.

- **검증됨(코드 레벨):** 모든 bash 스크립트 `bash -n` 통과, Python `py_compile`
  통과, idempotent/EUID 가드/anti-lockout 로직이 코드상 구현됨.
- **검증 안 됨(하드웨어):**
  - Switch 실기에서의 autoboot → cockpit 부팅 흐름.
  - `cage`/`openbox` kiosk 세션이 Switch GPU 드라이버에서 뜨는지.
  - 전원 버튼이 `/dev/input/event*` 로 KEY_POWER 를 실제로 올리는지(기기마다 다름).
  - Plymouth 스플래시가 L4T initramfs 에서 표시되는지.
  - read-only rootfs 와 영속 마운트의 실제 동작.
- **RCM 지그(jig) 미보유.** 페이로드 주입/RCM 진입을 직접 시험할 장비가 없어, L1
  부팅 경로는 문서 기반 설계 단계다.

따라서 첫 실기 적용 시에는 반드시 **Vol- 탈출구**(`RECOVERY.md`)를 손에 쥔 채로,
단계별로 검증하며 진행할 것.

---

## `tools/switch-pilot` 와의 관계

- **`switch-pilot` = 런타임(L3) 본체.** cockpit 웹서버(:8765), `/api/state`,
  `/api/action`, `setup.html` 프로비저닝, systemd watchdog 등 "앱"이 거기 있다.
- **`switch-appliance` = 그 위의 봉인 껍데기(L1/L2/L4).** 앱을 다시 짜지 않고,
  부팅·자동로그인·kiosk·안전정지·복구를 덧입힌다.
- `apply-appliance.sh` 는 먼저 `switch-pilot/install.sh` 를 호출한 뒤 봉인을 입히므로,
  **이 디렉터리의 설치기 하나만 실행하면 둘 다 적용**된다.

---

## 안전 원칙 (절대 약화 금지)

이 단말은 **실제 로봇을 구동**한다. 어떤 변경도 deadman / STOP / ESTOP / watchdog
동작을 약하게 만들면 안 된다.

- `darwin-power-stop.service` 는 복구 중에도 끄지 않는다 — 화면이 죽어도 전원
  버튼이 곧 비상 정지다(단일 누름=STOP, 1.5초 내 두 번=ESTOP).
- `no-sleep.sh` 는 전원 키를 일부러 무시(ignore)로 둔다 — 그래야 전원 버튼이
  시스템 종료가 아니라 로봇 STOP 핸들러로 전달된다.
- systemd watchdog(에이전트 15초)·`Restart=always` 로 에이전트가 멈추면 자동
  재기동된다.

관련:
- 복구 절차: [`RECOVERY.md`](RECOVERY.md)
- 부팅 브랜딩: [`branding/README.md`](branding/README.md)
- 설계 문서: [`docs/prd/darwin-switch-appliance-design.md`](../../docs/prd/darwin-switch-appliance-design.md)
