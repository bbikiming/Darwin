# WalkLab Brokerage — robot 통합 절차 (v1.11.7)

이 patch 는 robot 측 `demo` (또는 `demo-pilot`) binary 에 WalkLab brokerage 모드를
추가합니다. Mac DarwinForge 의 ROBOTIS Onboard Walking 토글이 SSH 통해
`Walking::GetInstance()` 를 제어할 수 있게 됩니다.

## 적용 절차 (robot 측)

```bash
# 1) DarwinForge patch 파일들을 robot 으로 복사
#    Mac 에서:
scp -r firmware-patches/walklab-brokerage/ \
    darwin@<robot-ip>:~/walklab-brokerage/

# 2) robot SSH 접속
ssh darwin@<robot-ip>

# 3) 헤더 + 구현 파일 + 볼 트래킹 config 를 demo 폴더에 복사
#    (O1 WalkLabTransport + H1 GamepadPilot 포함 — 6파일 전부 필요)
cp ~/walklab-brokerage/WalkLabBrokerage.{h,cpp} \
   ~/walklab-brokerage/WalkLabTransport.{h,cpp} \
   ~/walklab-brokerage/GamepadPilot.{h,cpp} \
   ~/Framework/Linux/project/demo/
# balltrack.ini = 볼 트래킹 HSV 색 + 헤드 tilt 상한 + 카메라 조도.
# WalkLabBrokerage 가 런타임에 절대경로 /robotis/Linux/project/demo/balltrack.ini 로 읽음.
# 없으면 ColorFinder 기본값(공 색 불일치) + 카메라 미설정 → 볼 트래킹 실패.
cp ~/walklab-brokerage/balltrack.ini \
   /robotis/Linux/project/demo/    # ← BALLCOLOR_INI 절대경로. 튜닝본이 이미 있으면 보존(복사 생략).

# 4) main.cpp + Makefile patch 적용
cd ~/Framework/Linux/project/demo
patch -p3 < ~/walklab-brokerage/main.cpp.patch
patch -p3 < ~/walklab-brokerage/Makefile.patch

# 5) 빌드 (Framework 라이브러리도 먼저 빌드 필요할 수 있음)
make clean
make -C ../../build clean
make -C ../../build
make

# 6) 검증 — binary 실행 권한 + 첫 시작
sudo ./demo &
# /tmp/df-pilot-mode 미설정 → 기존 SOCCER 모드 (회귀 없음).

# 7) WalkLab brokerage 모드 검증
echo "walklab" > /tmp/df-pilot-mode
echo "1 20.00 0.00 0.00 700 35 13.00" > /tmp/df-walklab-cmd
chmod 0666 /tmp/df-walklab-cmd
sudo killall demo
sudo ./demo &
# → "[main] entering WalkLabBrokerage mode" + 보행 시작
```

## 결과 확인

```bash
# 명령 변경 → robot 반영 (~200ms 안에)
echo "1 28.00 0.00 0.00 600 40 13.00" > /tmp/df-walklab-cmd
# stride 28mm / period 600ms 로 갱신

# 정지
echo "0 0 0 0 0 0 13" > /tmp/df-walklab-cmd
# 또는
sudo killall demo
```

## Mac DarwinForge 측 사용 (이번 통합 이후)

1. WalkLab 우측 패널 → 보행 엔진 picker → **ROBOTIS onboard** 선택
2. **ROBOTIS 측 시작** 버튼 → SSH 자동 송출 → robot 측 demo 진입
3. **자동 명령 송출** 토글 ON (300ms debounce 자동 brokering)
4. preset / tuning 슬라이더 조정 → robot 가 ~200ms 안에 반영
5. **ROBOTIS 측 종료** 버튼 → demo 정지 + forge-bridge 복구

## F12 — 게임패드 킥 모션 (LB=왼발 page13 / RB=오른발 page12) 실기 브링업

> 설계·근거: `docs/design/gamepad-kick-motion.md`. 호스트 검출 로직은 213/0 통과.
> **온보드 실행(CheckAndExecuteKick)은 호스트 컴파일 불가** — 아래 8항을 실기에서
> 입회 검증해야 고토크 킥을 신뢰할 수 있다(요람 거치·다리 토크 차단 가능 상태에서).

선행(코딩 전제 — 실기 1회):
- [ ] **킥 자산**: `forge-cli motion play --slot 12 --dry-run --follow-chain` 및 `--slot 13`
      으로 온디바이스 `/robotis/Data/motion_4096.bin` 의 page 12=Right/13=Left 가
      이름·7스텝·체크섬 정상인지 확인(LoadPage 는 체크섬 실패 시 조용히 ResetPage→무동작).
- [ ] **motion_4096.bin** 128KB(256×512) 존재 확인.
- [ ] **evdev 코드**: 실패드에 `evtest`로 LB=`BTN_TL`(310)·RB=`BTN_TR`(311) 확인.

거동(요람 거치 → 다리 토크 OFF 시작):
- [ ] **킥 발화**: ARM(A) → LB → 좌측 page 13 / RB → 우측 page 12 재생. 콘솔
      `[WalkLabBrokerage] KICK LEFT/RIGHT — page N` 확인.
- [ ] **미ARM 거부**: disarmed 에서 LB/RB → 무동작(콜백 게이트).
- [ ] **STANDUP 게이트**: 저속 보행이 STANDUP 으로 읽혀 정당 킥을 막지 않는지 / 킥
      와인드업이 FALLEN 으로 오독되지 않는지 실측(`MotionStatus::FALLEN`).
- [ ] **E-STOP 중 킥**: 킥 모션 중 B → Action 즉시 중단 + body 토크 OFF(≤~10ms,
      reader 즉시 + supervisor 8ms 백스톱). 1~2s 잔여 모션 없어야.
- [ ] **킥↔보행 전이**: 보행 중 LB → 보행 정지(IsRunning false 수렴 <1s) → 킥 →
      완료 후 idle → 스틱 재입력 시 보행 재개(F9 ACK≠서보 행 없이 정상 재무장).
- [ ] **낙상 비간섭**: 킥 직후 착지 transient 가 auto-getup 오발 안 함(m_fall_count 리셋).

## 모션 페이지 감속 — 킥(12/13) + 패스(70/71) ★재셋업 시 필수★ (B1/B2, 2026-06-15)

> 공장 `motion_4096.bin` 의 다리스윙 페이지는 스냅 스텝이 ~72ms(play_time=9)로 너무
> 빨라, 개루프 Action 재생(킥/패스 중 자이로 밸런스 불가)에서 반동을 못 잡고 넘어질 수
> 있다. `retime-kick.py` 가 킥(12=rk/13=lk: 스텝 2,3,4)과 패스(70=rPASS/71=lPASS:
> 스텝 1,2,3,4,6)의 스냅을 144ms 로 감속하고 페이지 체크섬을 재계산한다.

```sh
# 공장/현행 bin → 감속본 생성 (대상 외 페이지 byte-identical, 체크섬 ≡0xFF 자동검증)
python3 retime-kick.py <factory_motion_4096.bin> motion_retimed.bin
# 원본 백업 후 배포 + 데모 재기동
scp motion_retimed.bin <user@host>:/robotis/Data/motion_4096.bin
```

- ⚠️ **감속본(retimed `motion_4096.bin`)은 git 에 보존되지 않는다(B2).** 공장초기화·SD
  재이미징·새 로봇 셋업 시 이 단계를 **반드시 재실행**해야 킥·패스 감속이 유지된다.
  안 하면 페이지가 공장 72ms 스냅으로 되돌아가 낙상 위험이 복귀한다.
- 검증: `forge-cli motion play --slot 70 --dry-run` 등으로 page 70/71 가 7스텝·체크섬
  정상인지 확인. 요람 거치 상태에서 패스 1회 재생해 스냅 안정성 실측(입회 게이트).

## 단일동작 상호배타 안전 수정 (리뷰 2026-06-15) — 실기 검증 대기

> 코드리뷰(86-에이전트 적대검증)에서 확정된 단일동작(킥/앉기/일어서기/패스) 안전 결함을
> 수정했다. **전부 호스트 빌드 불가 경로(brokerage.cpp) — 아래 입회 검증 필요.**

- [ ] **D1 앉음+볼추종**: SIT 후 볼-추종(START) 명령 → 앉은 채 보행 시작 안 함(정지 유지).
- [ ] **C2 동작후 자동재보행**: 볼-추종 ON 중 킥/D-패드 → 동작 후 자동 보행 재개 안 함
      (재개하려면 START 재토글). getup 후에도 동일.
- [ ] **C1/C5 stale 보행라인**: 스틱 앞으로 민 채 킥/동작 → 동작 직후 의도치 않은 보행 없음.
- [ ] **F1 getup 인계**: 킥 정지 중 실제 낙상 → 다음 poll 즉시 getup(≤~100ms, 종전 ~600ms).
- [ ] **B1 패스 감속**: rPASS/lPASS 스냅 144ms 로 재생(요람 거치 안정성 실측).

## 회귀 위험

- **patch 적용 안 한 robot 에 Mac 측 ROBOTIS onboard 시작** → `demo-pilot` 가
  `/tmp/df-pilot-mode` 무시 → 자동 SOCCER 모드 (ball tracker). Mac SSH 명령은
  무시됨. Mac UI 가 명시 경고 표시.
- **빌드 실패 시 fallback** — 원본 `demo` binary 유지. brokerage 미설치
  상태로 사용 가능.

## TODO (sprint 후 검증)

- [ ] DARwIn-OP_ROBOTIS_v1.6.0 / Framework Walking.cpp 의 X/Y/A_MOVE_AMPLITUDE
      실시간 변경 가능 여부 (cycle 중간 변경 시 안정성)
- [ ] PERIOD_TIME 변경 시 walking phase 리셋 필요한가?
- [ ] HIP_PITCH_OFFSET 변경 시 즉시 적용 vs 다음 cycle?
- [ ] /tmp/df-walklab-cmd race condition — atomic write 적용 (Mac 측 v1.11.7 fix).
