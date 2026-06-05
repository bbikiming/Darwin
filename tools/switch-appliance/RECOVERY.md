# Darwin Switch 복구 가이드 (RECOVERY)

> 한 줄 결론: **이 기기는 영구적으로 벽돌(brick)이 되지 않는다.** 부팅 때
> **Vol- (볼륨 아래)** 를 누르고 있으면 항상 Hekate 메뉴로 빠져나올 수 있고,
> Nintendo 정품(SysNAND)은 손대지 않았기 때문에 언제든 원래대로 되돌릴 수 있다.

이 문서는 비전문가도 따라할 수 있도록 단계별로 적었다. 어려운 영어 용어는
그대로 두되, 무엇을 누르고 무엇을 입력하는지는 한국어로 설명한다.

---

## 0. 가장 먼저 — 당황하지 말 것

Darwin Switch는 **SD카드 위의 Linux만 봉인**한 전용 단말이다. 우리가 바꾼 것은
SD카드 안의 부팅 경험뿐이고, Switch 본체 내부 저장소(eMMC = **SysNAND**)에 들어
있는 Nintendo 정품 OS는 **하나도 건드리지 않았다.**

그래서 최악의 경우라도 복구 경로는 항상 다음 4단계 중 하나다:

1. **Vol- 로 Hekate 메뉴 진입** (가장 흔한 복구)
2. **SSH로 접속해 설정만 고치기** (화면은 안 되는데 네트워크는 되는 경우)
3. **Hekate에서 Linux 재플래시** (Linux가 깨졌을 때 — NAND 건드리지 않음)
4. **정품(SysNAND)으로 완전 복귀** (전용 단말을 그만둘 때)

---

## 1. Vol- → Hekate 메뉴로 빠져나오기 (1차 복구)

화면이 안 나오거나, cockpit이 아닌 엉뚱한 화면이 뜨거나, 부팅이 이상할 때
**가장 먼저** 시도한다.

1. 기기를 **완전히 끈다.** (전원 버튼을 약 12초간 길게 눌러 강제 종료)
2. **Vol- (볼륨 아래 버튼)** 를 손가락으로 **누른 채로 유지**한다.
3. 그 상태에서 **전원 버튼**을 눌러 켠다.
4. Vol- 를 **Hekate(Nyx) 메뉴가 보일 때까지** 계속 누르고 있는다.

> 왜 되는가: 부팅 설정 파일(`/bootloader/hekate_ipl.ini`)의 `bootwait` 값이
> **3초 이상**으로 되어 있어, 그 3초 동안 Vol- 를 누르면 자동 부팅(autoboot)이
> 취소되고 메뉴가 뜬다. 이 창은 **절대 0으로 줄이지 않는다.** 이것이 보증된
> 탈출구다. (참고: `boot/hekate_ipl.ini.example`, hekate README "wait for VOL- to enter menu")

> ⚠️ **두 볼륨 키를 헷갈리지 말 것:**
> - **Vol- (볼륨 아래)** = 부팅 때 누르면 autoboot 취소 + Hekate 메뉴. ← 복구는 이것.
> - **Vol+ (볼륨 위) + 전원** = RCM jig로 PC에서 hekate payload를 *주입*할 때만.
>   이건 hekate를 처음 설치할 때 쓰는 별개 동작이고, 평소 복구에는 필요 없다.

Hekate 메뉴에 들어가면 할 수 있는 것:

- **Nintendo OS / SysNAND 실행** — 평소 게임기로 그대로 사용 가능.
- **L4T Ubuntu (Darwin)** 다시 선택해서 부팅.
- **Tools / Recovery** 진입 (아래 단계에서 사용).

---

## 2. SSH로 접속해 설정만 고치기 (화면은 깨졌지만 네트워크는 되는 경우)

cockpit 화면이 안 떠도 기기가 부팅은 되고 같은 네트워크에 있으면, 다른 컴퓨터에서
SSH로 들어가 설정만 고칠 수 있다. (재플래시 불필요)

다른 컴퓨터(맥/PC)의 터미널에서:

```bash
# 'darwin'은 봉인 단계에서 만든 전용 사용자. <스위치_IP>는 기기의 IP 주소.
ssh darwin@<스위치_IP>
```

> IP 주소를 모르면 공유기 관리 페이지의 접속 기기 목록에서 'darwin' 또는 그
> 호스트명을 찾는다. 유선 연결을 쓰는 경우 `192.168.123.1` 경로가 가장 빠르다.

접속한 뒤 자주 쓰는 복구 명령:

```bash
# 1) cockpit 에이전트 상태 확인
sudo systemctl status darwin-switch-agent

# 2) cockpit 설정 파일을 직접 고치기 (Mac 주소/포트/모드 등)
sudo nano /etc/darwin-switch-agent/config.json

# 3) 첫 부팅 설정 화면(setup.html)을 다시 띄우고 싶다면 provisioned 마커 삭제
sudo rm -f /etc/darwin-switch-agent/.provisioned

# 4) 에이전트와 kiosk 세션 재시작
sudo systemctl restart darwin-switch-agent
sudo systemctl restart darwin-kiosk    # cage 경로일 때. 없으면 무시.

# 5) 로그 확인 (무엇이 잘못됐는지)
journalctl -u darwin-switch-agent -n 100 --no-pager
journalctl -u darwin-power-stop -n 50 --no-pager
```

봉인 레이어를 다시 한 번 깔끔하게 적용하고 싶으면 (안전, 재실행 가능):

```bash
cd /opt/darwin-switch-agent/appliance
sudo ./apply-appliance.sh           # 미리 보기는 ./apply-appliance.sh --dry-run
```

> 안전 장치 주의: `darwin-power-stop` 서비스(전원 버튼 → 로봇 STOP)는 복구
> 과정에서도 **끄지 말 것.** 로봇이 움직이는 상태에서 화면만 고장났을 때 전원
> 버튼이 곧 비상 정지 버튼이 되어 준다.

---

## 3. Hekate에서 Linux 재플래시 (Linux가 깨졌을 때, NAND는 그대로)

SD카드의 Linux가 부팅조차 안 되거나 손상되었을 때. **이 단계는 SD카드의 Linux만
다시 설치할 뿐, Nintendo SysNAND는 전혀 건드리지 않는다.**

1. **1번 단계**대로 Vol- 를 눌러 Hekate(Nyx) 메뉴로 들어간다.
2. Switchroot의 **"Flash Linux" / L4T 설치** 경로를 따른다 (SD파티션 Linux 재설치).
   - Switchroot L4T Ubuntu 공식 설치 절차를 그대로 사용한다.
   - 이 과정은 SD카드의 Linux 파티션만 다시 쓴다.
3. Linux가 다시 부팅되면, 다른 컴퓨터에서 SSH로 들어가 봉인 레이어를 재적용한다:

```bash
# Darwin 저장소를 기기로 가져온 뒤 (또는 SD에 복사해 둔 뒤)
cd <Darwin_repo>/tools/switch-appliance
sudo ./apply-appliance.sh
sudo reboot
```

> 핵심: Linux를 몇 번을 다시 깔아도 Switch 본체의 정품 게임 기능은 안전하다.
> SD카드만 다루기 때문이다.

---

## 4. 골든 이미지로 재이미징 (예정 — 미래 기능)

향후에는 **검증된 Darwin Switch 상태를 통째로 떠 둔 "golden image"** 를 SD카드에
한 번에 복원하는 경로를 제공할 예정이다. (현재 미구현)

예정 흐름 (참고용):

1. 다른 컴퓨터에서 golden image 파일을 SD카드(또는 Linux 파티션)에 기록한다.
2. SD카드를 다시 끼우고 부팅하면 봉인된 Darwin 상태가 즉시 재현된다.
3. `apply-appliance.sh` 재실행 없이 곧장 cockpit으로 부팅.

> 이 기능이 준비되면 본 문서와 `README.md`에 정확한 명령을 추가한다. 그 전까지는
> **3번(재플래시) + apply-appliance.sh** 가 표준 복구 경로다.

---

## 5. 최악의 경우 — 정품(스톡)으로 완전 복귀

전용 단말 사용을 그만두고 평범한 Nintendo Switch로 되돌리고 싶을 때.

- **부팅마다 메뉴를 보이게 하기 (봉인 해제):** SD카드의
  `/bootloader/hekate_ipl.ini` 에서 `[config]` 의 `autoboot=0` 으로 바꾼다.
  그러면 매 부팅 때 Hekate 메뉴가 떠서 직접 Nintendo OS를 고를 수 있다.
  (또는 Vol- 로 Nyx에 들어가 **Options → Auto Boot** 를 끈다.)
- **Nintendo OS 그대로 사용:** SysNAND는 보존되어 있으므로, 메뉴에서 Nintendo OS를
  선택하면 처음 그대로의 게임기로 동작한다. 별도 NAND 복원이 필요 없다.
- **Linux 흔적까지 지우기 (선택):** SD카드를 다른 컴퓨터에서 포맷/재구성하면 된다.
  본체 내부 저장소(SysNAND)는 영향받지 않는다.

---

## 6. 왜 영구 고장이 불가능한가 (안심 요약)

- **Vol- 탈출구가 항상 열려 있다.** `bootwait >= 3` 을 유지하므로, 자동 부팅 대상이
  망가져도 사람은 늘 메뉴로 들어갈 시간이 있다. (`bootwait=0` 은 절대 금지)
- **SysNAND는 손대지 않았다.** Nintendo 정품 OS는 그대로라, 메뉴에서 고르기만 하면
  원래 게임기로 돌아간다.
- **우리가 바꾼 건 SD카드뿐이다.** SD Linux가 깨지면 재플래시하면 그만이고, 그
  과정도 본체를 위협하지 않는다.

정말 부팅이 전혀 안 되는 단 하나의 경우는 SD카드 자체가 물리적으로 고장 났을 때인데,
그때는 **새 SD카드에 Linux를 다시 설치**하면 된다 — 역시 본체는 멀쩡하다.

---

관련 문서:
- 부팅 설정: [`boot/hekate_ipl.ini.example`](boot/hekate_ipl.ini.example)
- 봉인 레이어 개요: [`README.md`](README.md)
- 설계 문서: [`docs/prd/darwin-switch-appliance-design.md`](../../docs/prd/darwin-switch-appliance-design.md)
