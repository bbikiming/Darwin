# WalkLab Brokerage — robot-side C++ patch

**Target**: ROBOTIS-OP2 `demo-pilot` binary (DarwinForge patched fork)
**Companion**: Mac DarwinForge v1.11.5+ — `WalkingEngine.robotisOnboard` 모드

## 동기

DarwinForge WalkLab 의 Mac sparse keyframe 보행 (~10Hz 등가) 은 architecture 한계로
실 robot 안정 보행 불가. Ball tracker 는 robot-side `Walking::GetInstance()` 의 8ms /
125Hz 루프 사용해 안정. WalkLab 도 **동일 robot-side 엔진을 사용**하되 Mac UI 의 명령
(stride / period / hipPitch / turn) 을 받아 적용하는 brokerage 모드 추가.

## 동작 흐름

```
[Mac DarwinForge]              [robot demo-pilot]
       │                              │
       ├── SSH ──► echo "walklab"     │
       │           > /tmp/df-pilot-   │
       │             mode             │
       │                              ├── main() startup
       │                              ├── read /tmp/df-pilot-mode
       │                              ├── if "walklab" → WalkLabBrokerageMode
       │                              │   (this patch 추가)
       │                              │
       ├── SSH ──► printf "..." \     │
       │           > /tmp/df-walklab- │
       │             cmd              │
       │                              ├── 5Hz polling loop:
       │                              │   ├── read /tmp/df-walklab-cmd
       │                              │   ├── sscanf 7필드
       │                              │   ├── Walking::GetInstance()->
       │                              │   │   X_MOVE_AMPLITUDE = x_mm
       │                              │   │   Y_MOVE_AMPLITUDE = y_mm
       │                              │   │   A_MOVE_AMPLITUDE = a_deg
       │                              │   │   PERIOD_TIME = period_ms
       │                              │   │   Z_MOVE_AMPLITUDE = foot_mm
       │                              │   │   HIP_PITCH_OFFSET = hip_pitch_deg
       │                              │   └── if enabled → Start() else Stop()
       │                              │
       └── SSH ──► killall demo-pilot │
                   rm /tmp/df-pilot-  │
                     mode             │
```

## 명령 line format (Mac → robot)

```
enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg
```

예: `1 28.00 0.00 0.00 600 40 13.00`

- **enabled** (int, 0 / 1): walking 활성/비활성. 0 → `Walking::Stop()`.
- **x_mm** (float): 전후 stride (mm/cycle). `X_MOVE_AMPLITUDE`.
- **y_mm** (float): 좌우 side step. `Y_MOVE_AMPLITUDE`.
- **a_deg** (float): yaw 회전 (°/cycle). `A_MOVE_AMPLITUDE`.
- **period_ms** (float, but int-like): 한 cycle 주기. `PERIOD_TIME`.
- **foot_mm** (float): 발 들기 높이. `Z_MOVE_AMPLITUDE`.
- **hip_pitch_deg** (float): hip pitch trim. `HIP_PITCH_OFFSET`. ROBOTIS 원본 13.0.

## Patch 적용 절차

```bash
# robot 측 SSH 접속 후
cd ~/Framework/Linux/project/demo
patch -p1 < walklab-brokerage.patch
# 볼 트래킹 config 설치 — WalkLabBrokerage 가 런타임에 절대경로로 읽음.
# 없으면 ColorFinder 기본값(공 색 불일치) + 카메라 미설정 → 볼 트래킹 실패.
# 이미 튜닝본이 있으면 보존(덮어쓰지 말 것).
cp balltrack.ini /robotis/Linux/project/demo/balltrack.ini   # = BALLCOLOR_INI
make clean && make
# /tmp 권한 확인 — sudo 없이 write 가능해야 함
ls -la /tmp/df-pilot-mode 2>/dev/null || true
```

> **권장**: 위 수동 patch 대신 `install-onboard.sh` 를 쓰면 main.cpp/Makefile patch +
> `balltrack.ini` 설치(튜닝본 보존)를 멱등하게 처리한다. 자세한 절차는 `INTEGRATION.md`.

## 검증

```bash
# robot 측에서
echo "walklab" > /tmp/df-pilot-mode
echo "1 20.00 0.00 0.00 700 35 13.00" > /tmp/df-walklab-cmd
sudo ./demo-pilot &
# → 로봇이 stride 20mm / period 700ms 로 보행 시작

# 정지
echo "0 0 0 0 0 0 13" > /tmp/df-walklab-cmd
# 또는
sudo killall demo-pilot
```

## 안전 고려

- **명령 파일 권한**: `/tmp/df-walklab-cmd` 가 0666 (Mac SSH user write 가능)
- **sscanf 실패 시**: 이전 명령 유지 (silent ignore — 잘못된 line 으로 robot 폭주 방지)
- **명령 stale**: Mac 측에서 5초 이상 명령 갱신 없으면 자동 stop (이 patch 가 timestamp 추적)
- **hip_pitch_deg clamp**: robot 측에서 `[0, 20]` 범위로 clamp 적용

## TODO (robot-side 실 적용 전 검증 필요)

- [ ] DARwIn-OP_ROBOTIS_v1.6.0 / Framework Walking.cpp 의 X/Y/A_MOVE_AMPLITUDE 실시간 변경 가능 여부 (period 중간 변경 시 cycle 불안정 가능)
- [ ] PERIOD_TIME 변경 시 walking phase 리셋 필요한가?
- [ ] HIP_PITCH_OFFSET 변경 시 즉시 적용 vs 다음 cycle?
- [ ] /tmp/df-walklab-cmd 동시 접근 (race condition) — flock 또는 atomic rename
- [ ] robot 측 user 권한 + sudo 필요 여부
