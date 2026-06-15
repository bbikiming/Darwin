# Darwin Switch Appliance — 증거 기반 최고-성공확률 아키텍처

> 작성일: 2026-06-05 · 대상: Nintendo Switch v1 (Erista / Tegra X1, unpatched/RCM-capable) + Switchroot L4T Ubuntu
> 범위: `tools/switch-appliance/` (sealing layer) + `tools/switch-pilot/` (cockpit agent)
> 상태: **하드웨어 미검증** (RCM jig 없음). 첫 부팅 전, 코드 변경의 근거 문서.

---

## 1. 결론 (Conclusion First)

**가장 성공확률 높은 스택은 "Switchroot가 실제로 빌드/테스트하는 경로"에 정렬하는 것이다.** 즉 (1) hekate 6.0.6+ 로 Noble 24.04(ubuntu-unity) 를 autoboot 하되 `id`/escape 키 오류를 고치고, (2) Joy-Con 입력은 raw `/dev/input/event*` 하드코딩을 버리고 **in-kernel `hid-nintendo` + `joycond` 가상 결합 디바이스를 이름으로 선택 + 코드 런타임 발견**, (3) 키오스크는 **cage(Wayland)를 버리고 X11+openbox+Firefox 를 PRIMARY** 로 뒤집고(Tegra 에 wlroots GBM 경로가 없음), (4) 텔레op 안전 모델(deadman edge-stop + receiver watchdog)은 유지하되 `robot_udp` 의 두 안전 leg 와 cockpit watchdog 표기를 고치고, (5) 카메라는 robot-side(mjpg_streamer)는 그대로 두고 **viewer 의 `<img>` 주기 재로드 + 자동 재시도 + autossh 터널** 을 추가, (6) seal 레이어는 견고하나 cage fallback 경로·시계(RTC)·machine-id/journald 를 보강한다. 가장 큰 단일 위험은 **cage 가 Tegra 에서 첫 부팅 시 블랙스크린** 이 될 가능성(operator 부재 상태에서 복구 불가)이며, 이는 코드가 현재 cage 를 PRIMARY 로 강제하기 때문에 최우선 수정 대상이다.

### 권장 스택 요약 (per layer)

| Layer | 권장 (adversarial 검증 후) | Fallback | 증거 강도 (Switch/Tegra L4T 특정) |
|---|---|---|---|
| **Boot** | Switchroot L4T Ubuntu **Noble 24.04 v5.1.2 (ubuntu-unity)** + hekate **≥6.0.6**, `autoboot_list=1` → `/bootloader/ini/` 엔트리 (ASCII 순서, Nyx 에서 1회 검증) | Jammy 22.04 (동일 메커니즘) / `autoboot=0` + Nyx 메뉴 표시 (un-brick safe mode) | **STRONG / Switch-specific** (Switchroot wiki + hekate README 직접 인용) |
| **Input** | in-kernel `hid-nintendo` + `joycond` → **"Nintendo Switch Combined Joy-Cons"** 가상 evdev, 이름 필터(+`(IMU)` 제외) + **런타임 코드 발견** | raw per-controller evdev 노드 + driver 버튼 테이블 (열등) / SDL2 (가장 약함) | **VERY STRONG / Switch-specific** (CTCaer kernel `CONFIG_HID_NINTENDO=y`, joycond 소스 라인 확인) |
| **Kiosk** | **X11 + openbox + Firefox `--kiosk`** (PRIMARY) | 동일 X11 세션 하 Chromium `--kiosk` / Wayland 필수 시 **Weston kiosk-shell `--use-egldevice`** (cage 아님) | **STRONG (mechanism) / 직접 Switch 검증 없음** (meta-tegra #1209 = Jetson Tegra; 메커니즘 전이) |
| **Teleop safety** | deadman edge-stop + **receiver-side timeout watchdog** (두 leg) + evdev-in-agent (browser Gamepad API 비신뢰) | `robot_udp` 에 explicit zero-datagram + 500ms receiver watchdog 추가 / 전송 교체 시 rosbridge_suite | **STRONG (pattern, generic ROS) / Gamepad·Tegra 미검증** |
| **Camera** | robot=mjpg_streamer 유지 + viewer **주기 `<img>.src` 재로드 + 자동 재시도** + **autossh** 터널 | snapshot polling (`?action=snapshot`) / robot-side `ustreamer` (저-CPU) | **MIXED**: 누수·autossh=generic-confirmed; **viewer on Tegra = 미검증(최대 잔여 위험)** |
| **Hardening (seal)** | X11-primary 세션 flip + sleep mask 유지 + sd_notify watchdog 유지 + **machine-id/journald/timesync 보강** (overlayroot 전) | cage 유지 시 공식 cage@.service 레시피 채택 / 최후: hekate VOL- escape | sleep·watchdog=**검증 OK**; session flip=**STRONG**; overlayroot=generic; RTC=**Switch-specific confirmed** |

---

## 2. 방법론 (Methodology)

**도출 방식.** 각 레이어를 "실제로 동작이 보고된 오픈소스/GitHub 프로젝트 + 1차 문서(Switchroot wiki, hekate README, 커널/joycond 소스, NVIDIA L4T 문서)"에 근거시킨 뒤, **adversarial verifier** 가 각 load-bearing 주장을 1차 출처로 반박 시도(curl/WebSearch)했다. verdict 는 `supported` / `partly-supported` 로 표기되며, 추천을 바꾼 정정은 각 도메인 섹션에 명시한다.

**정직성 caveat (CRITICAL).** **현재 RCM jig 가 없어 그 어떤 것도 실제 하드웨어에서 첫-부팅 검증되지 않았다.** 가장 강한 증거조차 일부는 "다른 Tegra SoC(Jetson Xavier/T194)" 또는 "generic ARM(Raspberry Pi)" 에서 온 것이므로, 메커니즘이 전이되지만 직접 Switch v1(T210) 관측은 아니다. 따라서:

- 모든 autoboot index, cage 렌더링, Tegra browser 멀티시간 안정성은 **첫 부팅 시 Nyx/evtest 로 검증할 때까지 "likely"** 로 취급한다.
- 문서화된 **un-brick safe mode (`autoboot=0` / Nyx 메뉴 / `bootwait>=3`)** 가 모든 추천의 guardrail 이다.

**증거 강도 라벨.** `confirmed` = 1차 출처에서 직접 확인(가능하면 Switch/Tegra 특정). `likely` = 메커니즘은 강하나 동일 하드웨어 직접 관측 아님(generic ARM/다른 Tegra). `unknown` = 동작 미확인.

---

## 3. 도메인별 분석

### 3.1 BOOT — Switchroot 설치 + hekate autoboot

**Verdict: `supported`.** 추천(Noble 24.04 v5.1.2 ubuntu-unity + hekate ≥6.0.6 + `autoboot_list=1`)은 1차 출처로 확정. 4개 정정은 모두 추론 다듬기(추천/파일 수정은 6개 모두 적용)이며, **autoboot index 만 하드웨어에서만 검증 가능**.

**권장 스택.** hekate ≥6.0.6 으로 Switchroot L4T Ubuntu Noble 24.04 v5.1.2 (ubuntu-unity) 설치 → 설치기가 `/bootloader/ini/L4T-XXXXXXX.ini` 에 디바이스-정확 엔트리 생성 → `autoboot_list=1` + ASCII 순서 index(Nyx 에서 VOL- 눌러 1회 검증). **Fallback:** Jammy 22.04(동일 메커니즘) / `autoboot=0` + Nyx 표시(un-brick safe mode).

| Project / Doc | URL | 왜 중요한가 | Switch-L4T | Signal |
|---|---|---|---|---|
| Switchroot Wiki — Noble 24.04 Install | https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide | 정확한 타깃 설치 절차; v5.1.2, hekate 6.0.6+ MANDATORY, Joy-Con BT dump 필수 | confirmed | 유지보수 theofficialgman; 이미지 2025-08-16 live |
| CTCaer/hekate README + template | https://github.com/CTCaer/hekate/blob/master/README.md | autoboot 의미론: VOL- escape(line 86), `id` max 7 chars(line 134), `autoboot_list` ASCII(lines 48,85) | confirmed | 8.4k stars; v6.5.2 (2026-03); 유일 유지 부트로더 |
| Switchroot Wiki — Boot Config (.ini keys) | https://wiki.switchroot.org/wiki/linux/linux-boot-configuration | `l4t=1`, `boot_prefixes`(Mandatory), `id=SWR-UBU`(FS label), `;`만 주석, key 사이 빈 줄 금지 | confirmed | 유지보수 작성; 키는 Jammy/Noble 안정 |
| Switchroot Wiki — Distributions / 다운로드 인덱스 | https://wiki.switchroot.org/wiki/linux/linux-distributions | SD 레이아웃: `/bootloader/ini/L4T-*.ini` = 생성 엔트리; `/switchroot/ubuntu/` 커널 | confirmed | 다운로드 인덱스 = canonical 이미지 소스 |
| Switchroot FAQ (v1 vs Mariko) | https://wiki.switchroot.org/wiki/faq | L4T 는 Erista(v1, fusee-gelee) 만 native; Mariko 는 modchip 필요 → v1+RCM jig 가 최대 지원 경로 | confirmed | FAQ + NH guide 교차 확인 |

**Switch-specific 위험.**
- **BRICK-RISK(최고 심각도): escape 키가 틀림.** 현재 파일은 "HOLD VOL+" 라 하나, hekate bootwait escape 는 **VOL- (Volume DOWN)** 다. (RCM *injection* 은 VOL+ + POWER — 별개 동작이므로 혼동 금지.)
- `id=SWITCHROOT_UBUNTU`(17자)는 hekate 7자 cap 위반 → `id=SWR-UBU`. (hekate per-entry id 와 L4T FS-label id 는 *다른 역할*이나 SWR-UBU 가 둘 다 만족.)
- autoboot index drift: `/bootloader/ini/` 엔트리는 ASCII 정렬 → `autoboot_list=1` 이어야 하며 index 는 **하드웨어 Nyx 검증 전까지 신뢰 불가**.
- `bootwait=0` = escape 창 + bootlogo 제거 = soft-brick. (현재 `>=3` 유지 — OK, max 20.)
- hekate 버전 결합: Noble 5.1.2 는 hekate 6.0.6+ 필수.
- Joy-Con BT dump(Nyx Options) 미수행 시 첫 부팅에 컨트롤러 입력 없음.

**DELTA — `tools/switch-appliance/boot/hekate_ipl.ini.example`** (현재 확인된 라인):
- **[CHANGE] (P0)** VOL+ → **VOL-** 전역 교체: header note (a) lines 18-20, 35-36, revert note line 42, bootwait note line 83. RCM(VOL+ + POWER)과 구별하는 1줄 추가.
- **[CHANGE] (P1)** line 143 `id=SWITCHROOT_UBUNTU` → `id=SWR-UBU`; line 142 주석 정정(7자 cap + FS-label 두 역할 분리 서술).
- **[CHANGE] (P1)** line 152 `;boot_prefixes=/switchroot/ubuntu/` 주석 해제(MANDATORY). `r2p_action=self` 는 "installer-matching nicety"로만 추가(부트 필수 아님).
- **[CHANGE] (P1)** lines 70/79: `autoboot=1` 유지하되 `autoboot_list=0`→`1`, 주석을 ASCII-순서/Nyx 검증으로 재서술. "VOL- 눌러 More-Configs 순서 1회 검증"을 **MANDATORY** 단계로 명시.
- **[ADD] (P1)** header 에 prerequisite 핀: "Requires hekate ≥6.0.6 + Noble 5.1.2 (ubuntu-unity); Switch v1/Erista unpatched + RCM jig only."
- **[KEEP]** `bootwait=3`(>=3, max 20), `autoboot=0` safe-mode 문서화, `;` 주석 규칙(키 사이 빈 줄 없음).
- **[ADD]** Joy-Con BT dump 를 provisioning prerequisite 로 문서화.

---

### 3.2 INPUT — Joy-Con / Pro Controller evdev

**Verdict: `supported`** (high confidence, adversarial 통과). 핵심 정정은 raw 코드 하드코딩이 *틀렸다*는 것(취약이 아니라 오류)과 device-selection 버그.

**권장 스택.** in-kernel `hid-nintendo` + `joycond` → 단일 가상 evdev **"Nintendo Switch Combined Joy-Cons"** 를 이름 우선순위로 선택, 버튼/축은 `EVIOCGBIT`/python-evdev 로 **런타임 발견**(raw int 하드코딩 금지). **Fallback:** raw per-controller 노드 + driver 버튼 테이블(combined 손실, 열등) / 최후 SDL2(Tegra 증거 약함).

| Project | URL | 왜 중요한가 | Switch-L4T | Signal |
|---|---|---|---|---|
| DanielOgorchock/joycond | https://github.com/DanielOgorchock/joycond | 단일 가상 디바이스 "Nintendo Switch Combined Joy-Cons"(virt_ctlr_combined.cpp:251), ABS ±32767. 이름으로 타깃 | confirmed | 514 stars; push 2026-02-01; not archived |
| CTCaer/switch-l4t-kernel-4.9 | https://github.com/CTCaer/switch-l4t-kernel-4.9 | Switchroot 실제 커널: `CONFIG_HID_NINTENDO=y` + `NINTENDO_FF=y` **built-in** (tegra_linux_defconfig @ linux-5.1.2) → DKMS 불필요 | confirmed | 공식 커널; tags up to 5.1.2 |
| torvalds/linux hid-nintendo.c | https://github.com/torvalds/linux/blob/master/drivers/hid/hid-nintendo.c | 버튼 테이블: **BTN_SOUTH=B(304), BTN_EAST=A(305)** (A/B 스왑); ZL/ZR=BTN_TL2/TR2; IMU 는 별도 `<base> (IMU)` 디바이스(line 2075) | confirmed | mainline ~5.16+; 동일 코드 |
| marcobaldo/rpi-joycon-guide | https://github.com/marcobaldo/rpi-joycon-guide | ARM(aarch64)에서 hid-nintendo+joycond+python-evdev 파이프라인 확인; "combined 매핑 다름 → 런타임 발견" | likely | RPi 4(Tegra 아님); 디바이스 이름은 "Joycon (Combined)"로 *다름* → 이름 리스트 매칭 근거 |
| Switchroot Wiki — Linux Features | https://wiki.switchroot.org/Linux/FeaturesAndPrograms | "Full Joy-Con Support" + rail/BT-dump/combine 제스처 → joycond 존재 강하게 함의 | confirmed (함의) | 현재 페이지에 "joycond" 문자열 부재 → install.sh 가 enable 해야 |
| emilyst/hid-nx-dkms | https://github.com/emilyst/hid-nx-dkms | 커스텀 커널 시 DKMS fallback (stock 이미지엔 불필요) | likely | 49 stars; **ARCHIVED** (2025-07); nicman23 도 archived(2022) |

**Switch-specific 위험.**
- **단일 RIGHT Joy-Con 에는 ZL(312)이 없다.** 현재 `deadman=[312]` → right rail joy-con 단독이면 로봇이 영원히 못 움직임. → `[312,313]`(ZL OR ZR) 또는 combined 강제.
- **Nintendo A/B 스왑:** 현재 `arm=304`(실제 B), `stop=305`(실제 A) → 역전됨. → `arm=[305]`, `stop=[304]`.
- joycond combined 디바이스는 **두 트리거 동시 누름(combine 제스처) 후에만** 생성 → 첫 부팅 onboarding 필요.
- `input_linux.py` 가 모든 `/dev/input/event*` 를 열고 `prefer_names` 무시(IMU/터치/전원키까지 바인딩, IMU 의 stray ABS 가 스틱축으로 오인). naive substring 필터는 **`(IMU)` 노드도 매칭** → 명시적 제외 필요.
- 구버전 이미지의 rumble 단절(L4T 5.0.0 fix). blind FF 금지.

**DELTA — `tools/switch-pilot/`:**
- **[CHANGE] (P0)** `src/darwin_switch_agent/input_linux.py` `_open_devices()`: `prefer_names` 적용해 **정확히 하나** 선택(우선순위 `["Nintendo Switch Combined Joy-Cons","Pro Controller","Joy-Con (R)","Joy-Con (L)","Nintendo"]`), **이름이 `(IMU)`로 끝나면 제외**.
- **[CHANGE] (P0)** `input_linux.py`: 하드코딩 코드 제거 → `EVIOCGBIT(EV_KEY)/EV_ABS` 로 런타임 발견, 역할을 evdev **이름**(BTN_TL2/ZL, BTN_TR2/ZR, BTN_EAST/A, BTN_SOUTH/B …)에 매핑. (python-evdev 권장; BTN_Z 309-vs-277 모호성 회피.)
- **[CHANGE] (P1)** `config.example.json` 기본값 정정: `deadman_key_codes:[312,313]`, `arm_key_codes:[305]`, `stop_key_codes:[304]`, `estop` 예: `[316]`(Home) 또는 +/- chord. 축은 유지(`0/1/3/4` confirmed). "런타임 발견이 우선"임을 문서화.
- **[ADD] (P1)** `install.sh`: `systemctl enable --now joycond`, agent user 를 `input` group 에 추가, 시작 시 선택 디바이스명 + 발견 코드 로깅.
- **[ADD] (P2)** `setup.html`/README: "양 Joy-Con 트리거 눌러 combine → evtest 로 확인" onboarding + Hekate BT-dump prerequisite.

---

### 3.3 KIOSK — boot-to-fullscreen browser compositor

**Verdict: `supported`** — cage→X11 flip 추천이 adversarial 검증을 통과(오히려 강화). 결정적 증거는 wlroots 가 NVIDIA Tegra DRM/GBM 경로에서 깨진다는 것.

**권장 스택.** **X11 + openbox + Firefox `--kiosk` 를 PRIMARY**, cage 는 하드웨어 검증된 opt-in 으로 강등. **Fallback:** 동일 X11 하 Chromium `--kiosk` / Wayland 필수 시 **Weston kiosk-shell `--use-egldevice`** (socket `wayland-0`, `tegra-udrm modeset=1`).

| Project / Doc | URL | 왜 중요한가 | Switch-L4T | Signal |
|---|---|---|---|---|
| cage-kiosk/cage | https://github.com/cage-kiosk/cage | 현재 PRIMARY; wlroots 기반 → GBM 하드 요구 상속. NVIDIA proprietary 에서 렌더 실패 이슈 존재 | **no** | v0.3.0 (2026-04); ~1.9k stars; 아키텍처 blocker(유지보수 무관) |
| OE4T/meta-tegra #1209 | https://github.com/OE4T/meta-tegra/issues/1209 | wlroots(phoc)가 Tegra 에서 `undefined symbol: drmIsKMS` → `PRIME export not supported` → allocator 실패. cage 와 동일 스택 | **likely** (메커니즘 전이) | **Jetson Xavier/T194, R32.7** — TX1 직접 아님 |
| NVIDIA Jetson — Weston/Wayland | https://docs.nvidia.com/jetson/archives/r35.5.0/DeveloperGuide/SD/WindowingSystems/WestonWayland.html | Tegra 지원 Wayland = Weston `--use-egldevice`(GBM swapchain 비활성, EGLStream). wlroots 가 못 타는 경로 | likely | 권위 NVIDIA L4T 문서 |
| OE4T/meta-tegra Wiki — Weston on TX1 | https://github.com/OE4T/meta-tegra/wiki/Wayland-Weston-support-on-TX1-TX2-Xavier-Nano | TX1(=Switch v1 SoC)에서 Weston 유지 경로 = `tegra-udrm modeset=1` + custom libdrm | likely | TX1 명시 |
| Switchroot Wiki — Linux Features | https://wiki.switchroot.org/wiki/linux/linux-features | GPU API = Vulkan/GL/GLES/EGL/CUDA(Wayland/GBM 미언급); Firefox(PPA) HW accel+Widevine, **Chromium EOL(>v126), buildscript deprecated**; snap 은 GPU accel 없음 | confirmed | 공식 wiki; Firefox-first 근거 |
| Switchroot Wiki — Noble Install | https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide | 실제 셸: KDE(Kubuntu)/Unity; GNOME-Wayland 지연 | confirmed | 플랫폼은 사실상 X11-first |
| RPi/digital-signage kiosk 가이드 | https://pimylifeup.com/raspberry-pi-kiosk/ | 지배적 ARM kiosk 패턴: autologin→startx→openbox→browser `--kiosk` + `xset s off/-dpms` | likely | ARM(Broadcom) — 패턴 전이, GPU 경로는 아님 |
| HA frontend #21006 (browser MJPEG leak) | https://github.com/home-assistant/frontend/issues/21006 | 장시간 MJPEG 시 Chromium/Firefox 모두 GPU/proc 메모리 증가 → reload watchdog 필요 | likely | generic, 모든 kiosk 적용 |

**Switch-specific 위험.**
- **cage/wlroots 는 Tegra 에 GBM 없음 → 첫 부팅 블랙스크린 가능(최대 위험).** 정정: L4T 에 Wayland 자체는 있음(Weston via NVGBM); **깨지는 것은 wlroots 경로**. 또한 Switchroot Noble KDE 는 Plasma 6 가 *기본 Wayland* — "X11 만 출하"는 부정확하나 X11 이 *신뢰 가능* 경로인 결론은 유효.
- Switchroot Chromium EOL(>v126); Firefox PPA 가 유지 경로.
- **snap/flatpak 은 L4T 에서 GPU accel 없음** → native .deb/PPA 강제.
- 장시간 MJPEG → OOM 위험(브라우저 무관) → reload watchdog.

**DELTA — `tools/switch-appliance/` + `tools/switch-pilot/`:**
- **[CHANGE] (P0)** `apply-appliance.sh` lines 160-201: 현재 `command -v cage` 성공 시 cage 서비스 enable + `set-default graphical.target`, 실패 시에만 openbox 설치하는 if/else 를 **반전**. openbox fallback + `~darwin/.bash_profile` 의 `[ "$(tty)" = /dev/tty1 ] && exec startx` 를 **cage 유무와 무관하게 항상 설치**. `darwin-kiosk.service`(cage)는 **실제 cage 세션 smoke-test 통과 시에만** enable(바이너리 존재로는 불충분).
- **[CHANGE] (P1)** `session/darwin-kiosk.service` 헤더 + README(line ~58, "cage PRIMARY"): cage/wlroots 가 Tegra 미지원(no GBM), 기본 비활성으로 수정.
- **[CHANGE] (P2)** `tools/switch-pilot/bin/darwin-switch-cockpit`: Firefox-first 유지. Firefox 전용 kiosk profile(스크린세이버 off) + chromium 분기에 `--noerrdialogs --disable-infobars --disable-features=Translate`.
- **[ADD] (P1)** browser memory watchdog(주기 reload/restart) — MJPEG GPU-mem 증가 bound.
- **[ADD] (P1)** apply-appliance.sh/README: browser 는 native .deb/PPA, snap 금지 명시.
- **[KEEP]** `openbox-autostart`, `darwin-kiosk.sh` 로직(기본 경로 선택/flag 만 변경).

---

### 3.4 COCKPIT + TELEOP SAFETY

**Verdict: `partly-supported`** — 코어 split-safety 모델은 검증되어 유지하나, **joycond device-selection 결함이 최대 첫-부팅 위험**이며 `robot_udp` 가 두 안전 leg 를 모두 결여. confidence 는 #1 수정 + 실하드웨어 evdev 캡처 전까지 **medium**.

**권장 스택.** deadman edge-stop + **receiver-side timeout watchdog**(두 leg 필수) + motion 은 evdev-in-agent(browser Gamepad API 비신뢰). **Fallback transport:** rosbridge_suite + roslibjs (foxglove/ws-protocol 은 archived → 의존 금지).

| Project / Doc | URL | 왜 중요한가 | Switch-L4T | Signal |
|---|---|---|---|---|
| ros-teleop/teleop_twist_joy | https://github.com/ros-teleop/teleop_twist_joy | canonical deadman: enable-button + release 시 단일 no-motion 명령. switch-pilot 와 1:1 | likely (pattern) | ros2 fork push 2025-07 |
| teleop_tools #45 "Deadman not sending stop" | https://github.com/ros-teleop/teleop_tools/issues/45 | edge-only stop 의 실패 모드 → receiver timeout 필수 증명. `robot_udp` 에 결여 | likely | 실사용 안전 버그 |
| Articulated Robotics — Teleop guide | https://articulatedrobotics.xyz/tutorials/mobile-robot/applications/teleop/ | cmd_vel 20-50Hz + ~0.5s timeout. switch-pilot 20Hz/100ms/500ms = proven band | likely | twist_mux 0.5s 와 일치 |
| MDN — Gamepad API | https://developer.mozilla.org/en-US/docs/Web/API/Gamepad_API/Using_the_Gamepad_API | getGamepads() user-gesture 필요; unfocused 탭 flat-0 → kiosk 안전경로로 부적합 | confirmed (generic) | **cage/openbox/Tegra 미검증** |
| W3C Gamepad spec | https://www.w3.org/TR/gamepad/ | Firefox 백그라운드 폴링 차단; rAF 폴링 입력 누락/지연 | confirmed (generic) | Windows 측정치 |
| RobotWebTools/rosbridge_suite + roslibjs | https://github.com/RobotWebTools/rosbridge_suite | JSON-over-WS browser↔robot de-facto 표준 = fallback transport | likely | 1.2k stars, push 2026-05; roslibjs push 2026-06 |
| foxglove/ws-protocol | https://github.com/foxglove/ws-protocol | 아키텍처 참고만; **ARCHIVED(2025-08), deprecated** → 의존 금지 | unknown | dead-end |

**Switch-specific 위험.**
- **joycond device-selection 결함이 최대 위험**(3.2 참조): raw hid-nintendo + 가상 디바이스 이벤트 병합 → phantom 입력.
- `robot_udp` 는 **receiver watchdog 도, release-edge explicit stop datagram 도 없음**(현재 무조건 20Hz 송신, deadman release 는 로그만). Wi-Fi stall 시 정지 안 됨.
- cockpit watchdog 표기(`app.js` `setText('watchdog','500 ms')`)는 하드코딩 — 실제 enforced timeout 아님(false confidence).
- kiosk focus 상실 시 browser gamepad B=stop/estop(`app.js` edge(1)/edge(9))이 조용히 죽음 → evdev agent 가 유일 STOP/ESTOP 권위여야.
- Mac 경로 watchdog 은 실제 enforced(`MobileRelayServer.swift` watchdogTask + `watchdogTimeoutMs=500`).

**DELTA — `tools/switch-pilot/`:**
- **[CHANGE] (P0)** (3.2 와 동일) `input_linux.py` device-selection + 런타임 코드 발견 — teleop 안전의 선결 조건.
- **[ADD] (P0)** `main.py` `robot_udp`: deadman-release edge 에 **explicit zero/stop datagram 즉시 송신** + receiver-side ~500ms no-fresh-command→zero-twist watchdog. receiver contract(DEADMAN flag + seq/timestamp staleness) 명시.
- **[CHANGE] (P1)** `web/app.js`: 하드코딩 `setText('watchdog','500 ms')` → 활성 모드의 실제 enforced timeout 표시(`robot_udp` 는 "no agent-side timeout" until #2).
- **[KEEP]** deadman edge-stop, 20Hz/100ms/500ms, evdev-in-agent, Mac watchdog. browser gamepad 버튼은 non-authoritative 로 문서화.

---

### 3.5 CAMERA — robot head-camera → Switch browser (MJPEG/SSH)

**Verdict: `partly-supported`** — 코어(robot 인코더 그대로, viewer+transport 보강)는 유효·오히려 더 중요. **타깃 오류: Firefox 가 기본 존재한다고 가정** — Switchroot 는 Chromium 이 preinstalled, Firefox 는 PPA 필요.

**권장 스택.** robot=mjpg_streamer 유지 + viewer **주기 `<img>.src` cache-bust 재로드 + error 자동 재시도(backoff)** + transport=**autossh**. **Fallback:** snapshot polling(`?action=snapshot`, GC-reclaimable) / robot-side ustreamer(저-CPU, 동일 `<img>` 계약).

| Project / Doc | URL | 왜 중요한가 | Switch-L4T | Signal |
|---|---|---|---|---|
| pikvm/ustreamer | https://github.com/pikvm/ustreamer | browser-MJPEG-kiosk 장시간 viability 의 실세계 증거(PiKVM 코어); mjpg-streamer 저-CPU 대체 | likely | ~2k stars; aarch64; robot-side 옵션 |
| jacksonliam/mjpg-streamer | https://github.com/jacksonliam/mjpg-streamer | 현재 robot-side 인코더; 동작하나 유지보수 약함 → robot-side 투자 말 것 | confirmed (robot-side, generic) | 필드 광범위 배포; main ~2021 정체 |
| Chromium #470851 + Mozilla #1280351/#662195 | https://bugs.chromium.org/p/chromium/issues/detail?id=470851 | `<img src>` MJPEG 누수(엔진-레벨, 해상도 의존) → 주기 reload + 저해상도 + Firefox 선호. **Firefox 도 면역 아님** | confirmed (engine-level) | Tegra 빌드에도 적용 |
| OctoPrint webcam memory thread | https://community.octoprint.org/t/browser-memory-problem-with-webcam-stream/13190 | 가장 가까운 analog: 동일 완화책(주기 reset, snapshot, Firefox) + autossh 합의 | likely | 2024-2026 가이드 수렴 |
| PiKVM/uStreamer perf update | https://pikvm.github.io/pikvm/blog/2024/03/06/kvmd-ustreamer-performance-update/ | MJPEG "just works" baseline; WebRTC 는 single-LAN 카메라엔 overkill | likely | RPi HW(Tegra 아님) |

**Switch-specific 위험.**
- **Firefox 미가정:** Switchroot 는 **Chromium preinstalled**, Firefox = PPA. 런처는 `if command -v firefox` 라서 stock 이미지에서 **조용히 chromium 으로 fall-through**(장시간 MJPEG 에 더 나쁜 브라우저).
- Tegra GPU browser 의 MJPEG 디코드/GPU-proc RAM 증가 — 실하드웨어 미검증(최대 잔여 위험).
- Switch v1 Wi-Fi 가 약점; 현재 plain `ssh -L`(keepalive/reconnect 없음) → 한 번의 blip 이 카메라 사망 → **autossh 필수**.
- DARwIn-OP CPU tight → robot fps/res 보수적(≤640×480).

**DELTA — `tools/switch-pilot/`:**
- **[ADD] (P1)** `web/app.js` `renderCamera()`: (1) 주기(3-5분) `img.src` cache-bust 재로드(누수 bound), (2) latch-to-"CAMERA LOST" 를 **auto-retry+backoff** 로 교체. config `camera.snapshot_url` 를 선택형 render 경로로.
- **[CHANGE] (P1)** `bin/darwin-switch-camera-tunnel`: plain `exec ssh -N -L` → `autossh -M 0 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -N -L …`, systemd `Restart=always`.
- **[ADD] (P1)** `install.sh` 에 **preflight 생성**(현재 dependency check 전무): `autossh` 설치/검증, 없으면 fail-loud. (autossh 는 universe — installable, not present.)
- **[CHANGE] (P1)** browser: Firefox 를 provisioning 단계에서 **설치+검증, 없으면 fail-loud**(조용히 chromium 금지). 또는 chromium 을 realistic primary 로 보고 viewer-side 완화에 의존. browser 선택은 *2차* 방어.
- **[ADD] (P2)** robot mjpg_streamer res ≤640×480 핀(README/config). ustreamer 를 저-CPU swap 으로 문서화.

---

### 3.6 APPLIANCE HARDENING — sealed single-purpose Linux

**Verdict: `partly-supported`** — session flip(X11-primary) 추천은 통과·강화. 단 rationale 의 두 사실 정정: (1) L4T 에 Wayland *자체는 있음*(Weston via NVGBM) — 깨지는 건 wlroots; (2) Switchroot Noble KDE 는 Plasma 6 *기본 Wayland*(X11 만 출하는 아님, 그러나 X11 이 신뢰 경로).

**권장 스택.** multi-user.target + getty@tty1 autologin + `exec startx` + openbox + browser restart loop. cage 는 verified-only opt-in. sleep mask + sd_notify watchdog 유지. **Fallback:** cage 유지 시 공식 cage@.service 레시피 / 최후 hekate VOL- escape.

| Project / Doc | URL | 왜 중요한가 | Switch-L4T | Signal |
|---|---|---|---|---|
| cage systemd 공식 레시피 | https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot-with-systemd | 현 unit 은 `/etc/pam.d/cage`(pam_systemd), dbus/logind Wants/After, plymouth-quit-wait, `ConditionPathExists=/dev/tty0`, Utmp*, `StandardInput=tty-fail` 결여 | unknown | cage v0.3.0; #423 firefox --kiosk 확인 |
| Switchroot Wiki — Linux Features | https://wiki.switchroot.org/wiki/linux/linux-features | GPU API 목록(Wayland 미언급); 컨트롤러 매핑 `/usr/share/X11/xorg.conf.d/50-joystick.conf` = X11 경로 | confirmed | X11 corroboration(약한 신호) |
| OE4T/meta-tegra #1209 | https://github.com/OE4T/meta-tegra/issues/1209 | wlroots Tegra DRM 실패(load-bearing) — cage 위험의 1차 증거 | likely (Jetson) | T194/R32.7 — TX1 직접 아님 |
| freedesktop sd_notify(3) | https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html | watchdog 정석: READY=1 먼저, WatchdogSec/2 마다 pet, 유효 kill = ×2/3. 현 코드(15s 하 5s pet) 정확 | likely | 권위 man page |
| overlayroot (AtomicObject) + Bootlin | https://spin.atomicobject.com/protecting-ubuntu-root-filesystem/ | ro-root 가 machine-id 재생성/journald RAM-only/config revert 유발 → persistent mount·static machine-id·`Storage=volatile` 필요 | likely (generic ARM) | RPi ro-root 가이드 재현 |
| RPi kiosk + read-only overlay | https://www.raspberrypi.com/tutorials/how-to-use-a-raspberry-pi-in-kiosk-mode/ | getty autologin + GUI from login + `--kiosk` + overlay = X11-primary 패턴 검증 | likely | ARM(Broadcom), 패턴-강·드라이버-약 |
| Switch L4T RTC 문제 (GBAtemp/NX-ntpc) | https://gbatemp.net/threads/l4t-ubuntu-a-fully-featured-linux-on-your-switch.537301/ | Switch 는 Linux 용 RTC sync 불가 → 전원 후 시계 ~19년 오차 → TLS/journald/시간기반 로직 파손 | confirmed (Switch-specific) | NX-ntpc/QuickNTP 가 존재하는 이유 |

**Switch-specific 위험.**
- **cage 가 Tegra 첫 부팅에 안 뜰 수 있음(최고 위험).** 현재 openbox fallback 은 cage 부재 시에만 설치 → **cage 존재하나 broken 이면 fallback 미발동 = 블랙스크린**.
- `darwin-kiosk.service` 가 공식 레시피의 PAM/dbus/logind/VT 하드닝 결여(`StandardInput=tty` ≠ `tty-fail`).
- **Switch RTC 시계 garbage** → overlayroot 와 결합 시 매 부팅 발생. timesync 미설정.
- overlayroot ro-root 가 first-boot provisioning(`config.json` + `.provisioned`)을 조용히 revert; machine-id 매 부팅 재생성; journald RAM-only.
- Plymouth branding(`-R` initramfs rebuild)은 ro-root seal *이전*에.

**DELTA — `tools/switch-appliance/`:**
- **[CHANGE] (P0)** `apply-appliance.sh` lines 160-201: X11(getty autologin + openbox + `exec startx`)을 기본 PRIMARY 로, openbox + `.bash_profile` startx 줄을 항상 설치, cage 는 **세션 smoke-test** 통과 시에만 enable. (3.3 와 동일 변경.)
- **[CHANGE] (P2)** cage 유지 시 `session/darwin-kiosk.service` 를 공식 cage@.service 로: `/etc/pam.d/cage`(pam_systemd) + `PAMName=cage` + dbus/logind Wants/After + `After=plymouth-quit-wait.service` + `ConditionPathExists=/dev/tty0` + Utmp* + `TTYReset/TTYVHangup/TTYVTDisallocate` + `StandardInput=tty-fail`.
- **[CHANGE] (P2)** `main.py` `watchdog_interval=5.0`(line ~67) → `WATCHDOG_USEC` 파생(`usec/1e6/2`, unset 시 5.0 fallback). (안전 개선, 정확성 결함 아님.)
- **[ADD] (P1)** overlayroot enable 전: (a) `/etc/darwin-switch-agent` + log/data 의 persistent fstab mount 생성/검증, (b) static `/etc/machine-id` pre-seed, (c) journald `Storage=volatile` drop-in(또는 `/var/log` bind-mount), (d) `RECOVERY.md` 에 `overlayroot=disabled` kernel arg.
- **[ADD] (P1)** time sync(`systemd-timesyncd` 또는 chrony) 활성 + agent/cockpit 이 invalid clock 에 startup 허용(시계로 cockpit gate 금지). TLS 주장은 TLS-bearing relay leg 에만 한정(robot_udp 는 plaintext).
- **[ADD] (P2)** Plymouth branding 을 ro-root seal *이전* 실행 보장.
- **[KEEP]** `no-sleep.sh`, `autologin.sh`, `ssh-harden.sh`, sd_notify watchdog(`systemd_notify.py`), `READY=1`-first 패턴.

---

## 4. 통합 변경 요약 (Prioritized Deltas)

> **P0 = 첫 부팅 전 필수**(블랙스크린/브릭/입력없음/로봇 안전). **P1 = 첫 부팅 신뢰성·안정성**. **P2 = 폴리시·장기 운영**.

| # | Pri | 파일 | 변경 | 종류 |
|---|---|---|---|---|
| 1 | **P0** | `switch-appliance/boot/hekate_ipl.ini.example` | escape 키 VOL+ → **VOL-** 전역(lines 18-20, 35-36, 42, 83) + RCM 구별 1줄 | CHANGE |
| 2 | **P0** | `switch-appliance/apply-appliance.sh` (160-201) | session flip: **X11+openbox+Firefox PRIMARY**, openbox+startx 항상 설치, cage 는 smoke-test 후에만 | CHANGE |
| 3 | **P0** | `switch-pilot/src/.../input_linux.py` | `prefer_names` 단일 디바이스 선택(`(IMU)` 제외) + 런타임 코드 발견 | CHANGE |
| 4 | **P0** | `switch-pilot/src/.../main.py` (robot_udp) | release-edge explicit zero datagram + receiver ~500ms watchdog | ADD |
| 5 | P1 | `switch-appliance/boot/hekate_ipl.ini.example` | `id=SWR-UBU`, `boot_prefixes` 주석해제, `autoboot_list=1`+Nyx 검증, hekate≥6.0.6 핀 | CHANGE |
| 6 | P1 | `switch-pilot/config.example.json` | `deadman=[312,313]`, `arm=[305]`, `stop=[304]`, estop 추가 | CHANGE |
| 7 | P1 | `switch-pilot/install.sh` | preflight 생성: joycond enable, `input` group, autossh 설치/검증 fail-loud | ADD |
| 8 | P1 | `switch-pilot/web/app.js` | 카메라 주기 `<img>.src` 재로드 + auto-retry; watchdog 표기 실측화 | CHANGE/ADD |
| 9 | P1 | `switch-pilot/bin/darwin-switch-camera-tunnel` | `ssh -L` → **autossh** + systemd `Restart=always` | CHANGE |
| 10 | P1 | `switch-appliance/apply-appliance.sh` + README | browser native .deb/PPA 강제(snap 금지); Firefox 설치+검증 fail-loud | CHANGE/ADD |
| 11 | P1 | `switch-appliance/seal/overlayroot.*` | persistent mount + static machine-id + journald volatile + `overlayroot=disabled` 문서 | ADD |
| 12 | P1 | `switch-appliance` time sync | timesyncd/chrony 활성 + invalid-clock 허용 | ADD |
| 13 | P2 | `switch-appliance/session/darwin-kiosk.service` | (cage 유지 시) 공식 cage@.service 레시피 채택 | CHANGE |
| 14 | P2 | `switch-pilot/src/.../main.py` | watchdog interval = `WATCHDOG_USEC/2` | CHANGE |
| 15 | P2 | `switch-pilot/bin/darwin-switch-cockpit` | Firefox kiosk profile + chromium 하드닝 flags | CHANGE |
| 16 | P2 | `switch-pilot/web/setup.html` + README | combine 제스처 + evtest onboarding; BT-dump prerequisite | ADD |
| 17 | P2 | `switch-appliance/apply-appliance.sh` | Plymouth branding 을 ro-root seal 이전 실행 | CHANGE |

**P0 카운트: 4** (#1 escape 키, #2 session flip, #3 input device-selection, #4 robot_udp 안전).

> **적용 상태 (2026-06-05):** P0 #1~#4 **적용 완료** (+ 정확성상 필요한 P1 #6 config 기본값 동반 적용).
> hekate README 1차 출처로 VOL- 직접 확인. 검증: `compileall` 통과, config 코드 단언 통과,
> input/robot_udp 단위 스모크 통과, `bash -n` + `--dry-run` 통과. **여전히 하드웨어 미검증.**
> P1·P2(13개)는 미적용 — §5 첫 부팅 브링업에서 단계적으로.

---

## 5. 첫 부팅 검증 순서 (Evidence-Informed Bring-Up)

> 성공확률 최대화 순서. 각 단계 **go/no-go**. RCM jig 확보 후 실행.

**0. 사전 provisioning (PC/HOS 측)**
- hekate **≥6.0.6** payload, Noble 5.1.2 (ubuntu-unity) 이미지 확인.
- HOS 에서 양 Joy-Con 페어링 → **Nyx Options > Dump Joy-Con BT**(Lite 라도 factory calibration dump).
- **go/no-go:** BT dump 산출물 존재 → go. 없으면 첫 부팅에 컨트롤러 입력 없음 → no-go.

**1. 부트 (autoboot 신뢰 전, 안전 모드)**
- 첫 부팅은 `autoboot=0` 또는 **VOL- 누른 채** 전원 → Nyx **More Configs** 진입.
- 엔트리 ASCII 순서를 눈으로 확인하고 "L4T Ubuntu" 위치를 기록 → 그 index 로 `autoboot_list=1` 설정.
- **go/no-go:** Nyx 가 뜨고 L4T 엔트리 보임 → go. 안 뜨면 VOL- 재시도/SD PC 재플래시.

**2. 데스크톱/세션 도달**
- L4T 부팅 후 X11 세션(openbox 또는 KDE-X11) 도달 확인. cage 는 아직 활성화하지 않음.
- 확인: `echo $XDG_SESSION_TYPE` (x11 기대), `loginctl show-session $XDG_SESSION_ID -p Type`.
- **go/no-go:** 그래픽 표시 → go. 블랙스크린 → no-go(cage 활성화 금지 확인).

**3. 입력 디바이스 발견 (코드 하드코딩 검증)**
- combine: 양 Joy-Con 트리거 동시 누름 → 가상 디바이스 생성.
- `cat /proc/bus/input/devices | grep -i -A5 nintendo` 로 이름/handler 확인.
- 정확한 evdev 노드를 evtest 로 코드 확인:
  ```sh
  ls -l /dev/input/by-id/ ; sudo evtest        # 디바이스 선택 → 버튼/축 누르며 코드 관찰
  # 또는 python-evdev:
  python3 -c "import evdev;[print(d.path,d.name) for d in map(evdev.InputDevice,evdev.list_devices())]"
  ```
- 기대: "Nintendo Switch Combined Joy-Cons", A=BTN_EAST(305), B=BTN_SOUTH(304), ZL=312/ZR=313. `(IMU)` 노드는 무시.
- **go/no-go:** combined 디바이스 + 코드 일치 → go. 불일치 → config 갱신/런타임 발견 로직 확인.

**4. joycond 서비스 / 권한**
- `systemctl status joycond` (active), `groups darwin | grep input`.
- **go/no-go:** joycond active + input group → go.

**5. agent + cockpit (dry_run)**
- `mode: dry_run` 으로 agent 기동, 시작 로그에 선택 디바이스명 + 발견 코드 출력 확인.
- cockpit `127.0.0.1:8765` 에서 deadman(ZL/ZR hold)→arm→스틱 입력이 정확한 버튼으로 매핑되는지 확인.
- **go/no-go:** deadman release 가 stop 을 트리거하고, A/B 가 올바른 물리 버튼 → go.

**6. 카메라 경로**
- robot mjpg_streamer ≤640×480 기동, autossh 터널 up 확인(`ss -tlnp | grep 18080`).
- cockpit MJPEG 표시 → Wi-Fi 잠깐 끊고 auto-retry 복구 확인.
- **go/no-go:** 영상 표시 + 끊김 후 자동 복구 → go.

**7. 안전 leg (mac_relay / robot_udp)**
- mac_relay: Mac watchdog stop(heartbeat 끊고 ≤500ms 내 `watchdog.stop`) 확인.
- robot_udp: release-edge explicit stop datagram + receiver 500ms watchdog 동작 확인(#4 적용 후).
- **go/no-go:** 두 모드 모두 stall 시 정지 → go. **여기 통과 전 로봇 torque engage 금지.**

**8. seal 활성화 (마지막)**
- autoboot index 확정, X11 kiosk 정상 후에만 sleep mask/autologin/ssh-harden 적용. overlayroot 는 persistent mount/machine-id/timesync 보강 후 opt-in.
- **go/no-go:** 재부팅 후 cockpit 자동 도달 + provisioning 유지 → go.

---

## 6. 참고자료 (Consolidated Citations)

**Boot / hekate / Switchroot**
- https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- https://github.com/CTCaer/hekate/blob/master/README.md
- https://github.com/CTCaer/hekate/blob/master/res/hekate_ipl_template.ini
- https://wiki.switchroot.org/wiki/linux/linux-boot-configuration
- https://wiki.switchroot.org/wiki/linux/linux-distributions
- https://wiki.switchroot.org/wiki/faq
- https://download.switchroot.org/ubuntu-noble/

**Input / Joy-Con**
- https://github.com/DanielOgorchock/joycond
- https://github.com/DanielOgorchock/joycond/issues/85
- https://github.com/CTCaer/switch-l4t-kernel-4.9
- https://github.com/torvalds/linux/blob/master/drivers/hid/hid-nintendo.c
- https://github.com/marcobaldo/rpi-joycon-guide
- https://wiki.switchroot.org/Linux/FeaturesAndPrograms
- https://github.com/emilyst/hid-nx-dkms

**Kiosk / Tegra graphics**
- https://github.com/cage-kiosk/cage
- https://github.com/cage-kiosk/cage/wiki/Starting-Cage-on-boot-with-systemd
- https://github.com/OE4T/meta-tegra/issues/1209
- https://github.com/OE4T/meta-tegra/issues/236
- https://github.com/OE4T/meta-tegra/wiki/Wayland-Weston-support-on-TX1-TX2-Xavier-Nano
- https://docs.nvidia.com/jetson/archives/r35.5.0/DeveloperGuide/SD/WindowingSystems/WestonWayland.html
- https://github.com/NVIDIA/open-gpu-kernel-modules/issues/318
- https://wiki.switchroot.org/wiki/linux/linux-features
- https://pimylifeup.com/raspberry-pi-kiosk/

**Teleop safety**
- https://github.com/ros-teleop/teleop_twist_joy
- https://docs.ros.org/en/rolling/p/teleop_twist_joy/__README.html
- https://github.com/ros-teleop/teleop_tools/issues/45
- https://articulatedrobotics.xyz/tutorials/mobile-robot/applications/teleop/
- https://developer.mozilla.org/en-US/docs/Web/API/Gamepad_API/Using_the_Gamepad_API
- https://www.w3.org/TR/gamepad/
- https://github.com/RobotWebTools/rosbridge_suite
- https://github.com/foxglove/ws-protocol

**Camera / MJPEG / SSH**
- https://github.com/pikvm/ustreamer
- https://github.com/pikvm/ustreamer/issues/113
- https://github.com/pikvm/ustreamer/issues/30
- https://github.com/pikvm/ustreamer/issues/246
- https://github.com/jacksonliam/mjpg-streamer
- https://bugs.chromium.org/p/chromium/issues/detail?id=470851
- https://bugzilla.mozilla.org/show_bug.cgi?id=1280351
- https://bugzilla.mozilla.org/show_bug.cgi?id=662195
- https://github.com/home-assistant/frontend/issues/21006
- https://community.octoprint.org/t/browser-memory-problem-with-webcam-stream/13190
- https://pikvm.github.io/pikvm/blog/2024/03/06/kvmd-ustreamer-performance-update/
- https://tecadmin.net/keep-the-ssh-tunnels-alive-with-autossh/

**Hardening / watchdog / RTC**
- https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
- https://spin.atomicobject.com/protecting-ubuntu-root-filesystem/
- https://www.raspberrypi.com/tutorials/how-to-use-a-raspberry-pi-in-kiosk-mode/
- https://gbatemp.net/threads/l4t-ubuntu-a-fully-featured-linux-on-your-switch.537301/

---

> **잔여 위험 (정직한 마감):** RCM jig 부재로 그 어떤 것도 첫-부팅 검증되지 않았다. 가장 강한 Tegra 증거(meta-tegra #1209)도 Jetson Tegra 이며 Switch v1(T210) 직접 관측이 아니다. 위 추천은 *증거로 첫-부팅 성공확률을 최대화*할 뿐, 실제 부팅만이 확정한다. un-brick safe mode(`autoboot=0`/Nyx/`bootwait>=3`)와 §5 의 go/no-go 가 신뢰 전 guardrail 이다.
