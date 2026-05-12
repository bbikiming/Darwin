# Mac USB-Serial Driver Setup

> macOS Sequoia/Sonoma 기준 (2024+). Apple Silicon 우선.

## 칩셋별 드라이버

| 칩 | 어디 쓰임 | macOS 기본 | 권장 |
|----|-----------|-----------|------|
| **FTDI FT232RL/RG** | CM-730/CM-740 USB | Apple In-Kernel (Sequoia/Sonoma) | Apple In-Kernel 우선, 문제 시 FTDI VCP 공식 |
| **Silicon Labs CP210x** | U2D2 dongle 일부 | Apple In-Kernel (Sonoma+) | Apple In-Kernel |
| **WCH CH340** | 저가 USB-Serial | 없음 (Sequoia에서) | WCH 공식 드라이버 (kext 필요) |
| **Apple USB-C 변환기** | 일반 어댑터 | 자체 | 별도 설치 X |

## 점검 절차 (Mac에서)

```sh
# 1. 우리 스크립트
bash scripts/check-mac-drivers.sh

# 2. 디바이스 노드 직접 확인
ls /dev/cu.usbserial-* /dev/cu.usbmodem* /dev/cu.SLAB* 2>/dev/null

# 3. 시스템 USB 트리
system_profiler SPUSBDataType | grep -iB2 -A2 'ftdi\|robotis\|silicon'

# 4. 시스템 확장 (Sequoia+)
systemextensionsctl list
```

기대 출력:
```
/dev/cu.usbserial-A1B2C3D4
```

만약 `/dev/cu.usbserial-*` 가 안 보이면 트러블슈팅 4단계 시도.

## 트러블슈팅

### 1) "이 장치를 허용하시겠습니까?" 다이얼로그가 안 떴다

- 시스템 설정 → 개인 정보 보호 및 보안 → 시스템 확장 → 차단된 항목 확인
- 미허용 시스템 확장이 있으면 "허용" 클릭
- 재부팅 후 케이블 다시 연결

### 2) `/dev/cu.usbserial-*`가 등장하지 않음

```sh
# kernel log 확인
log stream --predicate 'sender == "AppleUSBHost"' --info --debug | head -50
```

USB enumeration 실패라면:
- 케이블 교체 (Mini-B 측 핀 손상 잦음)
- USB hub 거치는 경우 직접 연결로 변경

### 3) 디바이스는 보이는데 1 Mbps 응답 없음

FTDI latency timer 조정 (Apple In-Kernel 드라이버 한정 기본 16 ms → 1 ms):

```sh
# stty로 설정 (영구화는 LaunchDaemon 별도)
stty -f /dev/cu.usbserial-A1B2 1000000 cs8 -cstopb -parenb -ixon -ixoff
```

또는 FTDI 공식 VCP 드라이버 설치 후 시스템 환경설정에서 latency 1 ms.

### 4) `Operation not permitted` (권한)

```sh
# 사용자가 로그인한 GUI 세션에서 한 번 실행해 권한 다이얼로그 트리거
open /dev/cu.usbserial-A1B2C3D4
```

또는 Terminal에 "전체 디스크 접근" 권한 부여 (시스템 설정 → 개인 정보 보호 → 전체 디스크 접근).

## ROBOTIS 특이사항

- ROBOTIS는 FTDI VID 0x0403 / PID 0x6001을 그대로 사용 (커스텀 PID 아님). 따라서 **FTDI 드라이버가 동작하면 ROBOTIS도 동작**.
- 일부 OP1 unit은 CM-730 보드의 FTDI를 PL2303으로 교체한 사례가 있음 (보드 수리 흔적). 이 경우 PL2303 드라이버 필요.

## 권한 / 보안

macOS Sequoia(15.x) 기준 USB-Serial 디바이스는 sandbox app에서는 접근 불가:
- 우리 forge CLI는 sandbox 비활성 (entitlement)
- DarwinForge.app는 `com.apple.security.device.usb` entitlement 필요 (Sprint 1·2 사이에 설정)

## 출처

- Apple Developer — USB-Serial in macOS
- FTDI Chip — VCP driver guide
- NUbots OP2 Restoration Guide (Mac 측 셋업 사례)

---

## 이더넷 경로 (★ Sprint 9-13 신규)

### 필요 부품
- USB-C → Gigabit Ethernet 어댑터 (Anker A8312 또는 Apple MJ1M2AM/A)
- CAT 5e/6 패치 케이블, 2 m, 차폐

### macOS 측 IP 설정
시스템 설정 → 네트워크 → 새 어댑터:
```
IPv4 구성: 수동
IP 주소:   192.168.123.2 (또는 .3, .4 ...)
서브넷:    255.255.255.0
라우터:    (비워둠 — 직결 시)
```

### 검증
```sh
ping -c 3 192.168.123.1                          # 로봇 응답
nc -zv 192.168.123.1 5530                        # forge server 포트 열림
forge connect --tcp 192.168.123.1:5530           # 실 연결
```

### 트러블슈팅
- ping 실패: 케이블 / 어댑터 / 로봇 PC `forge server` 데몬 점검
- 포트 닫힘: 로봇 PC에서 `forge server --bind 0.0.0.0:5530` 시작
- 다중 로봇: TP-Link TL-SG105 스위치 + 각 로봇 다른 IP (.1 / .2)

→ 통합 가이드: [`../../docs/harness/v2-mac-ui-handoff.md`](../../docs/harness/v2-mac-ui-handoff.md)
