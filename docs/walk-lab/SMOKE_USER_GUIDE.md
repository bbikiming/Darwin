# 실 robot smoke test — 사용자 협업 가이드

> **목적**: `scripts/smoke/*.sh` 자동화 + 사용자 manual 검증을 결합한 첫
> 실 robot 통합 smoke test 절차서. 본 가이드대로 따라가면 **DARwIn-OP2 실
> robot 1대 + Mac 1대** 환경에서 자동 + 수동 모든 단계를 한 번에 완수
> 한다.
>
> **연관 docs**:
> - [SMOKE_TEST_CHECKLIST.md](SMOKE_TEST_CHECKLIST.md) — 수동 감각 검증 (A-H 8 섹션)
> - [USER_PILOT_GUIDE.md](USER_PILOT_GUIDE.md) — 5 입력 source / 일반 사용법
> - [../harness/real-robot-verification.md](../harness/real-robot-verification.md) — 텔레메트리 검증 원본 절차
> - [../harness/walklab-gyro-smoke-test-2026-05-23.md](../harness/walklab-gyro-smoke-test-2026-05-23.md) — gyro / 9번째 필드 시나리오
>
> **사이클 281 (V281-4)**: dry-run 검증 완료 + 사용자 협업 단계 명확 분리.

---

## 비유

새 차 인수 절차 — 영업소에서 시동을 걸기 전에 **타이어 공기압 / 워셔액 /
연료** 를 점검하고 (사전 준비), 짧은 **시운전 코스** 를 돌면서 (자동
script), 운전자 본인이 **핸들 떨림 / 브레이크 감 / 엔진 소음** 을 느껴봐야
(수동 checklist) 비로소 인수가 완료된다. 본 가이드 = 영업소 직원이 옆에
서서 차근차근 안내하는 매뉴얼.

## 결론 한 줄

**4 단계 자동 script + 1 통합 script + 8 섹션 수동 checklist 를 본 순서대로
실행**. 자동 script 가 GREEN 떨어진다 → 그 다음 수동 검증으로 사람 감각
detector 활성. 총 소요 ~25 분 (자동 ~15 + 수동 ~10).

---

## 0. 사전 준비 (5 step, 약 5 분)

### 0.1 H/W 점검

다음을 사용자가 직접 확인:

- [ ] DARwIn-OP2 전원 ON (CM-740 LED 점등)
- [ ] **USB OTG** (CM-740 ↔ Mac) 또는 **이더넷** 연결 (LAN cable / Wi-Fi)
- [ ] robot 이 **정비 스탠드** 위에 거치 — 발이 지면에 닿지 않음
- [ ] 비상정지 키 (Space) 또는 H/W 버튼이 손이 닿는 거리에 있음
- [ ] 충돌 가능 물체가 robot 반경 50cm 이내에 없음

자세한 안전 항목은 `SMOKE_TEST_CHECKLIST.md` §A 참고.

### 0.2 IP 확인

robot 의 IP 를 알아낸다 (3 가지 방법 중 하나):

```bash
# 방법 1 — robot 콘솔에 직접 접속해서 확인
ssh robotis@<known-ip>
ip addr show eth0   # 또는 wlan0

# 방법 2 — Mac 에서 ARP 스캔 (USB OTG 인 경우)
arp -a | grep -i robotis

# 방법 3 — DHCP 라우터의 client list 에서 'darwin-op' / 'robotis' 검색
```

표준값: `192.168.123.1` (USB OTG 직결 시 default).

### 0.3 SSH key 등록 (1 회만, 권장)

password 인증 대신 key 인증을 쓰면 자동 script 가 password prompt 없이
실행된다.

```bash
# (1) Mac 에서 key 생성 (이미 있으면 skip)
ssh-keygen -t ed25519 -C "darwin-op smoke test"

# (2) robot 에 public key 등록
ssh-copy-id robotis@192.168.123.1
# 처음 한 번만 password 입력

# (3) password 없이 접속되는지 확인
ssh robotis@192.168.123.1 'echo OK'
# OK 출력되면 성공
```

### 0.4 ENV 설정

shell 에 다음 환경변수 export (한 번만, `.zshrc` / `.bashrc` 에 저장 권장):

```bash
export ROBOTIS_HOST=192.168.123.1            # 0.2 에서 확인한 IP
export ROBOTIS_USER=robotis                  # e-Manual 기본 user
export ROBOTIS_SSH_KEY=~/.ssh/id_ed25519     # (선택) 비표준 key path 인 경우만
export ROBOTIS_SSH_PORT=22                   # (선택) 비표준 포트인 경우만
```

`.env` 파일 사용 시 `source .env` 로 load.

### 0.5 도구 점검 (Mac 측)

```bash
# 필수
swift --version           # Apple Swift 5.9+ (Xcode + CLT 필요)
which ping ssh            # macOS 표준

# 권장 (없으면 일부 검증이 grep fallback 으로 약화)
brew install jq
```

---

## 1. 첫 실행 — 4 phase 개별 (약 13 분)

> 처음 도입하는 사용자는 **단계별 개별 실행** 권장. 각 phase 끝에서
> 결과를 보고 다음 phase 로 넘어갈지 결정.

### 1.1 preflight-check.sh (~2 분)

```bash
bash scripts/smoke/preflight-check.sh
```

자동 검사:
1. 환경변수 검증
2. 네트워크 reachability (ping + SSH banner)
3. 배터리 전압 (10.5 V 미만 = FAIL, 11.1 V 미만 = WARN)
4. dxlPower / sub-controller 활성
5. IMU 디바이스 (`/dev/i2c-*` / sysfs)
6. ROBOTIS demon 경로 (`/tmp/walking_engine_command`)
7. 수동 안전 체크리스트 (4 항목 prompt)

종료 코드:
- `0` 모두 통과 → 다음 phase 진행
- `1` 한 가지 이상 실패 → 다음 phase **금지**, 실패 항목 해결 후 재시도
- `2` env 누락 → §0.4 다시 확인

### 1.2 deploy-and-verify.sh (~5 분)

```bash
bash scripts/smoke/deploy-and-verify.sh
```

자동 작업:
1. orphan 하네스 세션 archive 트리거
2. `swift build` → `/Applications/DarwinForge.app` 설치
3. 앱 시동 + 8 초 대기
4. 하네스 세션 디렉토리 생성 검증
5. `events.jsonl` 첫 이벤트 `app.launch` 확인
6. `meta.json` eventCount >= 1 확인
7. **(반자동)** UI 에서 "Auto Connect" (단축키 `⌘⇧C`) 클릭 prompt →
   `connection.attempt` 이벤트 도달 검증

옵션:
- `SMOKE_DEPLOY_SKIP_BUILD=1` — 기존 설치 재사용 (개발 중 반복 실행 시)
- `SMOKE_NONINTERACTIVE=1` — step 7 의 UI 동작 skip

### 1.3 walk-cycle-smoke.sh (~3 분)

> **주의**: robot 이 정비 스탠드 위 + 발이 지면에 닿지 않는 상태인지
> 다시 확인. 본 script 의 prompt 가 발화되면 **실제 motor 가 움직인다.**

```bash
bash scripts/smoke/walk-cycle-smoke.sh
```

자동 검사:
1. `/tmp/walking_engine_command` 존재 + 읽기 가능
2. Brokerage daemon schema 감지 (v1 7-field vs v2 10-field)
3. **(반자동)** WalkLab UI → Engine=`robotisOnboard` + preset=`march` →
   Start prompt → command 파일 업데이트 확인
4. **(반자동)** balance ON + gain 변경 → 8/9/10 번 필드 변화 확인
5. 수동 감각 검증 (hip/knee 부드러움, 모터음 정상, balance 보정 동작)

v1 daemon 인 경우: WARN + OnboardHealthIndicator banner 안내 (FAIL 아님).

### 1.4 recovery-smoke.sh (~3 분)

```bash
bash scripts/smoke/recovery-smoke.sh
```

자동 검사:
1. 활성 하네스 세션 위치
2. baseline 이벤트 카운트 캡쳐
3. **(반자동)** Space 키 → `bus.e_stop` 이벤트 도달 검증
4. (SSH 있으면) `/tmp/walking_engine_command` idle 상태 확인
5. **(반자동)** R 키 / START 버튼 → 복구 신규 이벤트 검증
6. 수동 감각 검증 (torque release click, 팔다리 free swing, 복구 후 명령
   반응)

---

## 2. 통합 실행 — run-all-smoke.sh (~15 분)

4 단계가 한 번씩 모두 통과 (= 환경 안정) 한 뒤부터는 통합 script 권장.

```bash
bash scripts/smoke/run-all-smoke.sh
```

또는 비대화형 (CI / 로그 캡쳐 용):

```bash
SMOKE_NONINTERACTIVE=1 bash scripts/smoke/run-all-smoke.sh 2>&1 | tee smoke-$(date +%Y%m%d-%H%M).log
```

옵션:
- `SMOKE_STOP_ON_FAIL=1` — 첫 phase 실패 시 chain 중단
- `SMOKE_NONINTERACTIVE=1` — 모든 prompt skip (manual 항목은 WARN 처리)

종료 시 4 phase 의 PASS/FAIL 종합 표 출력.

---

## 3. 수동 검증 (~10 분)

자동 script 가 GREEN 떨어졌다고 끝이 아니다. 사람 감각이 detector 인
항목은 `SMOKE_TEST_CHECKLIST.md` §A-H 의 **8 섹션 ~50 항목** 을 직접
확인:

- **A.** 사전 안전 (스탠드 / 발 / 비상정지 / 케이블)
- **B.** 앱 시동 + 연결 (창 / 아이콘 / 메뉴 / 응답성)
- **C.** 첫 자세 (standing) — hip/knee/ankle 정확성, 모터음, 좌우 대칭
- **D.** WalkLab Mac sparse 모드 (march / slowWalk / 외력 보정 / IMU stale)
- **E.** WalkLab Onboard 모드 (OnboardHealthIndicator / v1 banner / preset 즉시성)
- **F.** 비상정지 + 복구 (torque release, 동시 OFF, 복구 후 응답)
- **G.** UI 인터랙션 (텔레메트리 탭 / Live tail / HUD 5↔20Hz / 에러 카운터)
- **H.** 종료 절차 (안전 자세 / silent torque-off / 세션 archive)

각 항목 `[ ]` 옆에 ✓/✗/? 기입. **단 1개라도 ✗** 면 robot 사용 중단.

---

## 4. 트러블슈팅

### 4.1 SSH 연결 실패 (`SSH 연결 실패` 메시지)

```bash
# (a) 네트워크 자체 확인
ping -c 3 $ROBOTIS_HOST

# (b) sshd 가 robot 에 떠 있는지 (콘솔 또는 다른 접속)
sudo systemctl status sshd

# (c) key 인증 디버그
ssh -v $ROBOTIS_USER@$ROBOTIS_HOST

# (d) 한 번도 등록 안 된 key 면
ssh-copy-id $ROBOTIS_USER@$ROBOTIS_HOST
```

흔한 원인:
- `~/.ssh/authorized_keys` 권한 (`chmod 600`)
- `BatchMode=yes` 인데 key 누락 → password 가 안 떠 그냥 실패
- `ROBOTIS_SSH_PORT` 가 비표준 (예: 2222)

### 4.2 배터리 voltage 낮음 (`< 10.5V` FAIL)

- 즉시 robot 종료 → 충전기 연결
- 충전 중에는 보행 script 실행 금지 (전류 부족)
- 11.1 V 이상 회복 후 재시도

### 4.3 dxlPower OFF (`dxlPower LOW`)

```bash
# robot 콘솔에서
sudo /darwin/Linux/project/walking_demo/walking_demo &
# 또는
sudo systemctl start robotis-walking
```

원인: 시동 daemon 미실행. e-Manual §dxl_power_ctrl 참고.

### 4.4 IMU 응답 없음 (`IMU 디바이스 발견 못함`)

```bash
# robot 측에서
dmesg | grep -iE 'i2c|iio|imu' | tail -20
lsmod | grep -i imu
```

흔한 원인:
- IMU 케이블 단선 (육안 확인)
- 커널 모듈 미로드 (`sudo modprobe <module>`)
- sysfs path 변경 (`/sys/bus/iio/devices/iio:device*` 확인)

### 4.5 walking_engine_command 송출 실패 (`command 변경 없음`)

자동 script 가 reading 은 OK 인데 UI 의 Start 버튼이 command file 을
업데이트 안 하는 경우:

```bash
# (a) DarwinForge 앱이 robot 에 실제로 연결되어 있는지 (사이드바 상태)
# (b) WalkLab Engine 이 'robotisOnboard' 인지 (Mac sparse 가 아닌)
# (c) autoOnboardBrokering 토글이 ON 인지
# (d) preset 선택 후 실제 'Start' 버튼 클릭했는지 (autoStart 아님)
```

또는 robot 측에서 직접 watch:

```bash
ssh $ROBOTIS_USER@$ROBOTIS_HOST 'watch -n 0.5 cat /tmp/walking_engine_command'
```

UI 에서 Start 누를 때 값이 바뀌는지 실시간 관찰.

### 4.6 v1 daemon banner 가 사라지지 않음

WalkLab 의 OnboardHealthIndicator 의 "v2 확인" 버튼 클릭으로 사용자가
명시적 ACK 해야 한다. v1 daemon 자체는 정상 — balance 필드만 silent
ignore 됨. v2 업그레이드 권장 (별도 절차).

### 4.7 비상정지 후 motor 미해제

```bash
# 최후 수단: 배터리 분리
# 그 전에:
# (a) DarwinForge 의 비상정지 배너가 떴는지 화면 확인
# (b) Inspector → 텔레메트리 → 'bus.e_stop' 이벤트 검색
# (c) bus.write_fail 이벤트 다수 발생 시 dxl bus 자체 hang 의심
```

`docs/diagnosis/` 의 최근 e_stop 이슈 RCA 참고.

### 4.8 하네스 세션 (`current-*`) 생성 안 됨

```bash
ls -la ~/Library/Application\ Support/DarwinForge/Harness/

# (a) DarwinForge 가 실제로 실행 중인지 (Activity Monitor)
# (b) Application Support 쓰기 권한 (Sandbox 차단 가능)
# (c) 이전 crash 흔적 (Console.app → DarwinForge)
```

### 4.9 jq 미설치로 일부 검증 약화

```bash
brew install jq
```

deploy-and-verify.sh §5 의 JSON parsing 이 grep fallback 보다 정확.

### 4.10 perl alarm 으로도 timeout 안 됨

극히 일부 SSH hang 시나리오 (TCP keepalive 없음 + ConnectTimeout 무시):

```bash
# 강제 종료
pkill -f preflight-check.sh
# StrictHostKeyChecking 캐시 초기화
ssh-keygen -R $ROBOTIS_HOST
```

---

## 5. 결과 기록

권장 저장 경로:

```
docs/harness/smoke-test-results-YYYY-MM-DD.md
```

template:

```markdown
# Smoke test 결과 — 2026-MM-DD

- 사용자: <name>
- 빌드: $(git rev-parse --short HEAD)
- robot: DARwIn-OP2 #SN
- 환경: macOS X.Y, Swift X.Y

## 자동 phase 결과

- preflight: PASS / FAIL(<exit>)
- deploy: PASS / FAIL(<exit>)
- walk: PASS / FAIL(<exit>)
- recovery: PASS / FAIL(<exit>)

## 수동 checklist (SMOKE_TEST_CHECKLIST.md)

A: ✓✓✓✓✓✓✓  B: ✓✓✓✓✓✓✓  C: ✓✓✓✓  D: ✓✓✓✓✓✓✓
E: ✓✓✓✓✓     F: ✓✓✓✓✓✓     G: ✓✓✓✓✓  H: ✓✓✓

## 노트

- (자유 기록: 이상 증상 / 우회 / 다음 액션)
```

---

## 6. 한계 (실 robot 없이 검증 불가능)

V281-4 dry-run 으로 확인된 부분 = bash syntax / ENV 검증 / 네트워크
실패 처리 / 종합 표 출력. **실 robot 1대 + 사용자 1명** 이 있어야만
검증 가능한 부분:

1. **SSH 연결 + 인증** 의 실제 동작 (RSA/ed25519 / port 22)
2. **배터리 전압 probe** 의 실제 출력 패턴 (dxlmon vs sysfs)
3. **dxlPower sysfs** 의 실제 path (CM-740 모델별 차이)
4. **IMU 디바이스** 의 실제 위치 (i2c-1 / iio:device0 / etc.)
5. **Brokerage daemon** 의 실제 schema (v1 vs v2 sscanf 패턴)
6. **`/tmp/walking_engine_command`** 실시간 업데이트 (UI Start ↔ daemon
   read 사이클)
7. **motor torque release** 의 audible click 타이밍
8. **balance 보정** 의 방향 부호 (rollInputConvention)
9. **모터 진동 / 좌우 대칭** (사람 감각 detector)
10. **세션 archive cycle** (앱 종료 → 다음 시동 시 current-* → UUID
    rename)

본 가이드 + script 는 위 1-7 까지 **자동 검출** + 8-10 의 **수동
prompt** 를 제공. 사용자가 수동 확인을 건너뛰면 사실상 검증 안 된 것.
