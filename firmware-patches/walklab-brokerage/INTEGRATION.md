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
cp ~/walklab-brokerage/WalkLabBrokerage.h \
   ~/Framework/Linux/project/demo/
cp ~/walklab-brokerage/WalkLabBrokerage.cpp \
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
