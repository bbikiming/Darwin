# Darwin Switch Appliance 설계 (전용 봉인 펌웨어)

작성일: 2026-06-05
상태: Design draft (구현 전, 하드웨어 미검증)
대상: Nintendo Switch 1세대 + Switchroot L4T Ubuntu
선행 문서: [`darwin-switch-controller-prd.md`](darwin-switch-controller-prd.md),
[`2026-06-03-switch-ssh-robot-control-setup-plan.md`](../reports/2026-06-03-switch-ssh-robot-control-setup-plan.md),
[`2026-06-05-claude-switch-pilot-continuation-prompt.md`](../handoff/2026-06-05-claude-switch-pilot-continuation-prompt.md)

---

## 0. 결론

이 문서는 **"스위치를 켜면 곧장 Darwin 조종석만 뜨는 전용 단말"** 을 만드는 봉인(sealing)·
이미징 설계다. 사용자 선택은 **(1) Switchroot 어플라이언스 방식**, **(2) Darwin 전용 완전 봉인**
이다.

비유로 먼저: 지금까지 만든 `tools/switch-pilot` 번들은 "일반 노트북에 조종 앱을 설치한
상태"다. 이 문서가 설계하는 것은 그 노트북을 **공장 출하된 전용 기계처럼** 바꾸는 작업이다 —
전원을 넣으면 OS·데스크톱·로그인 화면 없이 Darwin 화면만 나오고, 잠들지 않고, 사용자가
실수로 깨뜨릴 수 없으며, 망가지면 정해진 복구 경로로 되돌릴 수 있는 상태.

핵심 판단:

- 이것은 **Nintendo 펌웨어 교체가 아니다.** SysNAND는 그대로 보존한다. 우리가 봉인하는 것은
  SD카드의 Switchroot Linux 파티션과 그 부팅 경험이다.
- "봉인"은 **경험의 봉인**이다: autoboot + 자동 로그인 + 전용 kiosk 세션 + suspend 차단 +
  (선택) read-only rootfs. 물리적으로 Nintendo OS를 지우는 것이 아니라, Vol+ 탈출구만 남기고
  나머지를 Darwin 전용으로 고정한다.
- 현재 번들에 **부팅·봉인·복구·이미징 레이어가 없다.** 이 4가지가 이 설계의 실제 산출물이다.

---

## 1. 범위 (확정된 결정)

| 항목 | 결정 | 영향 |
|---|---|---|
| 펌웨어 방식 | Switchroot L4T Ubuntu 어플라이언스 | native `.nro`는 후속. 지금은 Linux 봉인 |
| 봉인 수준 | Darwin 전용 완전 봉인 | 게임 미사용. 부팅 시 cockpit 강제. 데스크톱 숨김 |
| Nintendo OS | SysNAND 보존, 평소 미노출 | Vol+ → Hekate 만 탈출구로 유지 |
| 1차 연결 | Mac 경유(MobileRelay) | 로봇 직결 UDP는 후속 |
| 베이스 코드 | 기존 `tools/switch-pilot` 재사용 | 새로 짜지 않고 봉인 레이어를 덧입힘 |

비목표 (이 설계에서 하지 않는 것):

- Nintendo Horizon OS / SysNAND 수정
- Atmosphère CFW, native `.nro` 빌드
- 로봇 온보드 UDP 수신기 구현
- 멀티 로봇, 모션 편집, 온라인 서비스 접속

---

## 2. "펌웨어"의 정확한 정의

사용자가 말한 "커스터마이징 펌웨어"는 Switch 씬의 용어로는 두 가지로 갈린다. 이 설계가
만드는 것은 **A**이며, **B는 명시적으로 제외**한다.

| | A. Darwin Switch Appliance (이 설계) | B. CFW (제외) |
|---|---|---|
| 대상 | SD카드 위 Switchroot Linux | Nintendo SysNAND/Horizon OS |
| 결과물 | 부팅→cockpit 봉인 Linux 이미지 | Atmosphère + `.nro` |
| 위험 | 낮음 (SD만 건드림) | 높음 (NAND 손상 가능) |
| 되돌리기 | SD 재플래시 | NAND 복원 필요 |

이 문서에서 "appliance image" = "Darwin 전용으로 봉인된 Switchroot Linux 상태 + 그것을
재현 가능하게 만드는 빌드 산출물" 을 뜻한다.

---

## 3. 아키텍처 — 4개 레이어

```text
┌─────────────────────────────────────────────────────────┐
│ L1 BOOT       Hekate autoboot → Switchroot L4T (메뉴 없음) │
│               Vol+ 홀드 = Hekate 메뉴 탈출구              │
├─────────────────────────────────────────────────────────┤
│ L2 OS SEAL    자동 로그인 → 전용 kiosk 세션 (데스크톱 없음)│
│               suspend/blank 차단 · Plymouth Darwin 스플래시│
│               (선택) overlayroot read-only · SSH key-only │
├─────────────────────────────────────────────────────────┤
│ L3 DARWIN     darwin-switch-agent (systemd, 기존 번들)    │
│   RUNTIME     cockpit 웹 UI :8765 · first-boot 프로비저닝 │
│               systemd watchdog · 카메라 SSH 터널          │
├─────────────────────────────────────────────────────────┤
│ L4 SAFETY &   sleep 버튼=STOP · heartbeat watchdog        │
│   RECOVERY    maintenance 부팅 엔트리 · SSH 복구 · 재이미징 │
└─────────────────────────────────────────────────────────┘
        ↓ Wi-Fi
   Mac DarwinForge MobileRelay → 로봇
```

각 레이어는 독립적으로 검증·롤백할 수 있게 분리한다. 하위 레이어가 실패해도 상위 레이어가
안전 상태로 떨어지도록 설계한다(fail-safe down).

---

## 4. 현재 보유 vs 추가 필요 (gap 분석)

> 정직성 원칙: "구현됨"은 Mac에서 문법/렌더만 검증된 상태이며, 실 Switch 하드웨어에서는
> 아무것도 검증되지 않았다.

### 4-1. 이미 있는 것 (Mac 로컬 검증만)

| 자산 | 위치 | 상태 |
|---|---|---|
| Python 조종 에이전트 | `tools/switch-pilot/src/darwin_switch_agent/` | compileall 통과 |
| cockpit 웹 UI (1280×720) | `tools/switch-pilot/web/` | 브라우저 렌더 OK |
| 설치 스크립트 | `tools/switch-pilot/install.sh` | bash -n 통과 |
| systemd 서비스 | `systemd/darwin-switch-agent.service` | `Restart=always` |
| kiosk 런처 | `bin/darwin-switch-cockpit` | xset/gsettings + firefox --kiosk |
| XDG autostart | `desktop/darwin-switch-cockpit.desktop` | 데스크톱 로그인 의존 |
| 카메라 터널 | `bin/darwin-switch-camera-tunnel` | 미검증 |
| 패키징 | `package.sh` → `dist/.../*.tar.gz` | 27KB |

### 4-2. 봉인 어플라이언스가 되려면 추가로 필요한 것

| # | 누락 항목 | 왜 필요한가 | 레이어 |
|---|---|---|---|
| 1 | Hekate autoboot 설정 | 켜면 메뉴 없이 바로 Darwin Linux | L1 |
| 2 | 자동 로그인 | 로그인 화면 = 봉인 깨짐. 사용자 비번 입력 불가 | L2 |
| 3 | 전용 kiosk 세션 | 현재는 "데스크톱+autostart". 데스크톱 자체를 없애야 전용감 | L2 |
| 4 | suspend/sleep **시스템 차단** | xset/gsettings는 세션 임시값. 조종 중 절전=안전사고 | L2/L4 |
| 5 | Plymouth Darwin 스플래시 | Ubuntu 로고 대신 Darwin 부팅 화면 = "기계" 정체성 | L2 |
| 6 | first-boot 프로비저닝 | 비전문가가 Wi-Fi/Mac IP를 화면에서 설정 | L3 |
| 7 | overlayroot read-only (선택) | 재부팅 시 초기화 = 손상 방지, 진짜 펌웨어 느낌 | L2 |
| 8 | SSH key-only 하드닝 | 봉인 단말의 유일한 외부 진입로 보호 | L2 |
| 9 | maintenance/복구 경로 | 봉인했으니 되돌리는 법이 반드시 명문화돼야 | L4 |
| 10 | appliance 빌드/이미징 스크립트 | 재현 가능한 "Darwin Switch OS x.y" 산출물 | 빌드 |
| 11 | systemd watchdog (sd_notify) | 에이전트 hang 시 자동 재시작 = 무인 신뢰성 | L3/L4 |
| 12 | 전원/슬립 버튼 → STOP 매핑 | 사용자가 버튼 눌러도 로봇이 폭주하지 않게 | L4 |

---

## 5. 레이어별 상세 설계

### L1 — 부팅 (Hekate autoboot + 탈출구)

목표: 전원 ON → 사용자 조작 0회 → Switchroot L4T Ubuntu 진입.

`bootloader/hekate_ipl.ini` (SD FAT32) 설계:

```ini
[config]
autoboot=1        ; 첫 부팅 엔트리로 자동 진입
autoboot_list=0
bootwait=3        ; Vol+ 탈출용 최소 대기(초). 0으로 두면 복구 불가 위험
backlight=100

[L4T Ubuntu]      ; Switchroot가 Flash Linux 시 생성하는 엔트리를 1번에 배치
; (Switchroot 설치가 채우는 l4t.ini/ini 엔트리를 그대로 사용)
```

탈출구 원칙 (사용자가 비전문가이므로 반드시 유지):

- **Vol+ 홀드 부팅** → Hekate 메뉴 진입 → Nintendo OS / 복구 선택 가능.
- `bootwait`를 0으로 만들지 않는다. 0이면 잘못된 autoboot를 되돌릴 창이 사라진다.
- Nintendo OS 엔트리를 **삭제하지 않고** 메뉴 뒤로 숨긴다(autoboot가 Linux를 먼저 잡으므로
  평소엔 안 보임 = "전용 봉인"의 체감, SysNAND는 보존 = 안전).

산출물: `tools/switch-appliance/boot/hekate_ipl.ini.example` + 적용 가이드.
(Switchroot가 생성하는 Linux 엔트리 이름에 맞춰 마지막에 사용자가 1줄 확인)

### L2 — OS 봉인

#### 2-1. 자동 로그인

전용 사용자 `darwin`을 만들고 로그인 화면을 건너뛴다.

- display manager가 있으면(LightDM/GDM): `autologin-user=darwin`.
- DM 없는 최소 구성이면: `getty@tty1` autologin override + `.bash_profile`에서 kiosk
  세션 `exec`.

#### 2-2. 전용 kiosk 세션 (데스크톱 제거가 핵심)

현재 방식(전체 Ubuntu Unity 데스크톱 + XDG autostart)은 "봉인"이 아니다. 두 가지 후보:

| 후보 | 구성 | 장점 | 단점 |
|---|---|---|---|
| **A. cage/weston kiosk** (권장) | Wayland 단일 앱 컴포지터가 브라우저만 fullscreen | 데스크톱 자체가 없음 = 가장 봉인적, 가벼움 | Switchroot GPU/Wayland 실기 검증 필요 |
| B. openbox + chromium --kiosk | X11 최소 WM + 브라우저 | 자료 많음, 안정적 | 데스크톱 잔재(WM) 존재 |
| C. 기존 Unity + autostart 하드닝 | 지금 구조 유지 + 패널/단축키 봉인 | 추가 패키지 0 | 데스크톱 노출 위험, 봉인감 약함 |

권장: **A 우선, 실기에서 Wayland 불안정하면 B로 폴백.** 둘 다 `bin/darwin-switch-cockpit`
런처를 재사용 가능(브라우저 실행 로직 이미 있음). kiosk 세션은 그 런처를 `exec`만 하면 된다.

#### 2-3. suspend / 화면 절전 **시스템 차단** (안전 직결)

조종 중 Switch가 절전에 들어가면 명령이 끊긴다. 세션 레벨(xset/gsettings)만으로는 부족하다.
systemd 레벨에서 막는다:

```bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# /etc/systemd/logind.conf:
#   HandleSuspendKey=ignore   (전원/슬립 버튼은 L4에서 STOP으로 가로챔)
#   HandleLidSwitch=ignore
#   IdleAction=ignore
```

기존 런처의 `xset -dpms` / `gsettings idle-delay 0`은 화면 백라이트용으로 **유지**(중복
방어). 시스템 mask는 커널 절전 자체를 막는 1차 방어.

#### 2-4. 부팅 스플래시 (정체성)

Plymouth 테마를 Darwin 브랜딩으로 교체 → 부팅 중 Ubuntu 로고 대신 "DARWIN" 화면.
산출물: `tools/switch-appliance/branding/plymouth/darwin/` (로고는 앱 아이콘 자산 재사용 —
단, 앱 아이콘 파일 자체는 변경 금지 메모리 준수, 복사만).

#### 2-5. (선택) read-only rootfs

`overlayroot`로 루트를 read-only + tmpfs overlay화 → 재부팅 시 깨끗한 상태로 복원.
설정(`/etc/darwin-switch-agent/config.json`)과 로그만 별도 쓰기 파티션에 둔다.

- 장점: 사용자가 실수로 시스템을 깨도 재부팅이면 복구. 진짜 "펌웨어" 동작.
- 단점: 업데이트/디버깅 시 명시적 read-write 전환 필요. **MVP 이후 적용 권장**(개발 중엔 rw).

#### 2-6. SSH 하드닝

PRD는 개발 중 SSH 항상 허용(12-A). 봉인 단말이므로:

- SSH 유지하되 **key-only**(`PasswordAuthentication no`), Mac 공개키 사전 등록.
- cockpit diagnostics에 IP/hostname 노출(기존 설계 유지) → 접속 편의.

### L3 — Darwin 런타임 (기존 번들 + 하드닝)

기존 `darwin-switch-agent`를 그대로 쓰되 무인 신뢰성 보강:

- **systemd watchdog**: 서비스에 `WatchdogSec=10`, 에이전트 메인 루프가 `sd_notify
  WATCHDOG=1` 주기 전송. hang 시 systemd가 재시작. (현재 `Restart=always`만 있어 hang은
  못 잡음 — crash만 잡음.)
- 서비스 순서: cockpit이 떠야 kiosk가 의미 있음. `darwin-switch-agent.service`를
  kiosk 세션보다 먼저 ready 되도록 ordering, 런처는 이미 :8765 readiness를 60초 폴링(있음).
- **first-boot 프로비저닝**: 첫 부팅에 설정이 기본값이면 cockpit이 "설정 모드"로 떠서
  Wi-Fi 선택 / 모드(mac_relay) / Mac IP·pairing code 입력을 받는다. 비전문가가 SSH 없이
  화면만으로 초기화 가능해야 함. (현재는 `nano config.json` 수동 — 봉인 단말엔 부적합.)
- 입력 매핑은 실기 `evtest` 전까지 **잠정**. 기본값(ZL=312 등)은 추정이며 확정 아님.

### L4 — 안전 & 복구

#### 4-1. 전원/슬립 버튼 가로채기

L2에서 logind가 슬립 버튼을 ignore하므로, 그 키 이벤트를 에이전트가 받아 **즉시 STOP 송신**
후 사용자에게 "조종 일시정지" 표시. 무음 절전 금지.

#### 4-2. 다층 안전 (기존 정책 유지)

deadman(ZL hold), 100ms heartbeat, 500ms watchdog stop, 화면 E-stop, deadman release stop.
**봉인 단말이어도 Mac/로봇 측 독립 stop·물리 전원 차단을 항상 유지**(화면 E-stop 단일 의존
금지 — PRD 안전 보완 조건).

#### 4-3. 복구 경로 (봉인의 필수 짝)

| 시나리오 | 복구 |
|---|---|
| cockpit이 안 뜸 | Vol+ 부팅 → Hekate → (후속) maintenance 엔트리 또는 Nintendo OS |
| 설정 꼬임 | SSH 접속 → `config.json` 수정 / 서비스 재시작 |
| Linux 손상 | SD에서 Hekate → Flash Linux 재설치 (NAND 무관) |
| 전체 복구 | SD 재이미징(아래 빌드 파이프라인 산출물로) |
| 최악 | SysNAND 보존되어 있으므로 순정 스위치로 복귀 가능 |

산출물: `tools/switch-appliance/RECOVERY.md` — 비전문가용 그림 포함 복구 절차.

---

## 6. 빌드 / 이미징 파이프라인

"펌웨어"의 재현성을 위해 봉인 상태를 **스크립트로 산출**한다. 2단계.

### 단계 1 — 프로비저닝 오버레이 (지금 가능, RCM 불필요)

기존 `install.sh`(앱 설치) 위에 **봉인 적용 스크립트**를 추가:

```text
tools/switch-appliance/apply-appliance.sh
  ├─ darwin 사용자 + 자동 로그인 설정
  ├─ kiosk 세션 설치 (cage 또는 openbox)
  ├─ sleep/suspend systemd mask + logind.conf
  ├─ Plymouth Darwin 테마 설치
  ├─ SSH key-only 적용
  ├─ tools/switch-pilot/install.sh 호출 (앱 본체)
  └─ (선택) overlayroot 활성화
```

실 Switchroot에서 1회 실행 → 봉인 완료. Mac에서는 `bash -n`/shellcheck로만 검증 가능
(실 적용은 실기 필요).

### 단계 2 — SD 이미지 캡처 (RCM/실기 확보 후)

봉인 완료된 Switch의 Linux 파티션을 **재배포 가능한 이미지로 캡처**:

- Hekate `Backup eMMC`가 아니라 **SD Linux 파티션 dump** → 압축 → `darwin-switch-os-x.y.img`.
- 새 Switch엔 Hekate Flash + 이미지 복원으로 동일 단말 복제.
- ARM64 L4T 이미지를 Mac에서 from-scratch 빌드는 비현실적(qemu/실기 필요) → **"설정된 1대를
  골든 이미지로 캡처"** 방식이 현실적.

### 버전닝

`/etc/darwin-switch-os-release` 에 `DARWIN_SWITCH_OS=0.1.0` 기록, cockpit 하단에 표시.
업데이트는 (a) `git pull` + `apply-appliance.sh` 재실행 또는 (b) 골든 이미지 재플래시.

---

## 7. 제안 디렉터리 구조

기존 `tools/switch-pilot`(앱 본체)는 그대로 두고, **봉인 레이어를 별도 디렉터리**로 분리
(관심사 분리, 작은 파일 원칙):

```text
tools/
  switch-pilot/              # L3 앱 본체 (기존, 변경 최소)
  switch-appliance/          # 신규: L1·L2·L4 봉인 레이어
    apply-appliance.sh       # 봉인 적용 오케스트레이터
    boot/
      hekate_ipl.ini.example # L1 autoboot
    session/
      darwin-kiosk.sh        # kiosk 세션 진입점 (런처 재사용)
      cage-darwin.service    # 또는 openbox autostart
    seal/
      no-sleep.sh            # systemd mask + logind.conf
      ssh-harden.sh
      autologin.sh
      overlayroot.conf       # (선택, MVP 후)
    branding/
      plymouth/darwin/       # 부팅 스플래시
    power-button-stop/       # 슬립버튼→STOP 핸들러
    RECOVERY.md
    README.md
```

L3 보강(watchdog, first-boot)은 `switch-pilot` 안에서 처리.

---

## 8. 구현 단계 (RCM jig 확보 여부로 게이팅)

> 현재 RCM jig 없음 → Phase 0 전까지는 **Mac에서 작성·문법검증만** 가능.

| Phase | 내용 | RCM 필요 | 산출물 |
|---|---|---|---|
| **A. 사전작성** | `switch-appliance/` 스크립트·설정·문서 작성, `bash -n`/shellcheck | ❌ | 봉인 스크립트 일체 (미적용) |
| **A2. L3 하드닝** | systemd watchdog + sd_notify, first-boot 프로비저닝 UI | ❌ | 앱 보강 |
| **0. Switch Linux** | RCM→Hekate→NAND백업→Switchroot 설치→SSH | ✅ | 부팅되는 Ubuntu |
| **1. 입력 프로파일** | `evtest`로 실 이벤트코드 수집 → mapping 확정 | ✅ | 검증된 config |
| **2. 봉인 적용** | `apply-appliance.sh` 실행, autoboot·kiosk·no-sleep 검증 | ✅ | 봉인된 단말 |
| **3. Mac relay** | mode=mac_relay, Arm/heartbeat/stop/estop 실연동 | ✅ | 조종 동작 |
| **4. 카메라/복구** | SSH 터널 카메라, 복구 절차 실검증 | ✅ | 카메라 HUD + RECOVERY |
| **5. 골든 이미지** | 봉인 단말 SD 이미지 캡처·버전닝 | ✅ | `darwin-switch-os-x.y.img` |
| **6. read-only** | overlayroot 봉인 (선택) | ✅ | 초기화-안전 단말 |

지금 바로 진행 가능한 것은 **Phase A / A2** (코드·문서 작성, Mac 문법검증).

---

## 9. 리스크

| 리스크 | 영향 | 대응 |
|---|---|---|
| autoboot 후 복구 불가 | 단말 벽돌화 체감 | `bootwait≥3`, Vol+ 탈출 필수, NAND 보존 |
| Wayland(cage) Switchroot 불안정 | kiosk 안 뜸 | openbox+X11 폴백 경로 준비 |
| 자동로그인+SSH key-only 충돌 | 접근 불가 | 봉인 전 SSH key 등록·접속 확인을 게이트로 |
| suspend 차단 누락 | 조종 중 절전 사고 | systemd mask + logind + xset 3중 방어 |
| overlayroot 적용 중 설정 유실 | config 날아감 | config/로그를 쓰기 파티션 분리, MVP 후 적용 |
| 입력 코드 추정 오류 | 매핑 오동작 | 실기 evtest 전까지 "잠정" 명시, 확정 금지 |
| 골든 이미지 ARM 빌드 난도 | 재현 어려움 | from-scratch 대신 실기 캡처 방식 |

---

## 10. 하드웨어 미검증 항목 (정직성)

다음은 **전부 미검증**이며, 이 설계는 가설이다:

- RCM/Hekate/Switchroot 부팅 (RCM jig 없음)
- autoboot가 메뉴 없이 Linux를 잡는지
- cage/openbox kiosk가 Switchroot에서 뜨는지
- systemd suspend mask가 Switch 전원관리에서 실제로 절전을 막는지
- Joy-Con/Pro 실 이벤트 코드
- Plymouth 테마 렌더
- overlayroot 동작
- Mac relay end-to-end, 카메라 터널, 로봇 동작

→ "구현됨"이라고 쓸 수 있는 것은 Phase 2 이후 실기 검증 결과뿐이다.

---

## 11. MVP 성공 기준 (봉인 단말 기준)

- 전원 ON → 사용자 조작 없이 Darwin cockpit fullscreen 까지 도달.
- 부팅 중 Ubuntu가 아닌 Darwin 스플래시 표시.
- 데스크톱/로그인 화면이 일절 노출되지 않음.
- 10분 방치해도 절전/화면꺼짐 없음.
- Vol+ 부팅으로 Hekate 메뉴(복구)에 진입 가능.
- SSH(key)로 접속해 로그 확인 가능.
- cockpit에서 Wi-Fi·Mac IP를 화면으로 설정 가능(SSH 없이).
- 에이전트 강제 종료 시 watchdog로 자동 재기동.
- ZL 미입력 시 로봇 무동작, release 시 500ms 내 stop, 화면 E-stop 즉시 반영.

---

## 12. 열린 질문

1. kiosk 컴포지터를 cage(Wayland)로 갈지 openbox(X11)로 갈지는 **실기 GPU 검증** 후 확정.
2. overlayroot read-only를 MVP에 포함할지, 안정화 후 적용할지.
3. first-boot 프로비저닝을 cockpit 내 설정 페이지로 만들지, 별도 setup 페이지로 분리할지.
4. 골든 이미지 배포 형식(전체 SD .img vs Linux 파티션 tar) 결정.
5. 전원 버튼 동작: 짧게=STOP+화면유지, 길게=정상 종료 로 분리할지.
6. Nintendo OS 엔트리를 Hekate 메뉴에 남길지(되돌리기 쉬움) 완전히 숨길지(봉인감 ↑).

---

## 부록 A — 현재 번들과의 연결점

봉인 레이어가 호출/재사용하는 기존 자산:

- `tools/switch-pilot/install.sh` — L3 앱 설치 (apply-appliance.sh가 호출)
- `tools/switch-pilot/bin/darwin-switch-cockpit` — 브라우저 kiosk 실행 (세션이 exec)
- `tools/switch-pilot/systemd/darwin-switch-agent.service` — watchdog 보강 대상
- `tools/switch-pilot/bin/darwin-switch-camera-tunnel` — Phase 4 카메라
- `app/ui/DarwinForge/.../MobileRelay/*` — Phase 3 Mac relay 상대 프로토콜
