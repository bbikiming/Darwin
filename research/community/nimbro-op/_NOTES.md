# research/community/nimbro-op/_NOTES.md

> Bonn 대학 AIS 그룹의 NimbRo-OP TeenSize 휴머노이드 — DARwIn-OP 1.5.0 + CM-730 firmware v0x13
> 위에 적용하는 **25 개 패치 세트** (essential 16 + optional 9). 우리 프로젝트에서는 **OP1 보행
> 튜닝·낙상 보호·MotionManager 토크 관리** 의 1차 알고리즘 reference.

## 메타

| 항목 | 값 |
|------|----|
| Upstream | <https://github.com/NimbRo/nimbro-op> |
| Commit | `5572d413eda0b53b8c4417d32efabdffff0a2904` (2012-10-30) |
| Target | NimbRo-OP (TeenSize, OP1 기반) |
| License | BSD-3-Clause (software/) · CC BY-NC-SA 3.0 (hardware/CAD) |
| Repo size | ~76 MiB (대부분 hardware/CAD) |
| Upstream paper | <https://nimbro.net/OP>, RoboCup Humanoid League |

## 구조

```
nimbro-op/
├── README.md
├── LICENSE                              BSD-3-Clause (software)
├── HARDWARE LICENSE…CC BY-NC-SA 3.0.txt CAD 라이선스
├── fetch_and_patch.sh                   SourceForge DARwIn-OP_v1.5.0.zip + CM730 fw v0x13 다운 → patch -p1 적용
├── software/
│   ├── motion_4096.bin                  TeenSize 캡처 모션 (45 명명 페이지)
│   ├── patches-essential/               16 개 — boot 에 필수
│   └── patches-optional/                 9 개 — joystick·UDP·beeper 등 옵션 기능
└── hardware/
    └── CAD/
        ├── IGS 3D/                      IGES 형식
        └── STEP 3D/                     STEP 형식
```

## patches-essential (16개) — 우리 참고 우선순위

| # | 파일 | 변경 영역 | 핵심 의미 | 우리 참고 |
|--:|------|-----------|-----------|-----------|
| 01 | `0001-CM730-merge-uninitialized-value-fix-from-robotis-SVN.patch` | `Framework/hardware/CM730.cpp` | ROBOTIS SVN 후속 버그 fix 머지 | ★ |
| 02 | `0002-added-deploy-script.patch` | (top-level) | NimbRo 전용 배포 스크립트 | — |
| 03 | `0003-fixes-for-precise.patch` | build | Ubuntu Precise GCC 호환 | — |
| 04 | `0004-Point-implement-operators-properly.patch` | `Framework/math/Point` | 연산자 오버로딩 | ★ |
| 05 | `0005-CM730-firmware-changes-for-NimbRo-OP.patch` | CM730 펌웨어 | NimbRo HW 전용 | — |
| 06 | `0006-Improved-joint-configuration.patch` | `JointData` / `MotionManager` | joint enable/disable API 개선 | ★★ |
| **07** | `0007-MotionManager-torque-management.patch` | `Framework/include/MotionManager.h`, `Framework/src/motion/MotionManager.cpp` | **모션 실행 중 동적 토크 ON/OFF API** — 페이지 단위 torque mask | ★★★ |
| 08 | `0008-dxl_monitor-custom-settings-for-NimbRo-OP-actuators.patch` | `Linux/project/dxl_monitor` | NimbRo 액추에이터별 설정 | — |
| **09** | `0009-LinuxMotionTimer-improved-performance.patch` | `Linux/build/LinuxMotionTimer.cpp` | **실시간 타이머 jitter 축소** — POSIX timer + signal 핸들러 재설계 | ★★★ |
| **10** | `0010-Simple-angle-estimator.patch` | `Framework/include/AngleEstimator.h` (신규) | **자이로 + 가속도 단순 융합** (complementary filter) — fall_protection 의 기반 | ★★★ |
| 11 | `0011-vision-adapted-for-NimbRo-OP-camera-system.patch` | `Framework/vision` | NimbRo 카메라 어댑터 | — |
| **12** | `0012-Walking-tuned-for-NimbRo-OP.patch` | `Data/config.ini`, `Framework/include/MotionState.h` (신규), `QuadraticStateTransform.h` (신규), `Walking.h`, `Walking.cpp`, `walk_tuner` | **보행 파라미터 + smooth start + spline pitch balance** — 가장 큰 패치 (522 라인) | ★★★ |
| 13 | `0013-BallFollower-changes-for-NimbRo-OP.patch` | `Framework/vision/BallFollower.{h,cpp}` | 공 추적 (사커) | ★ |
| 14 | `0014-demo-wait-for-motion-stop-before-doing-critical-stuf.patch` | `Linux/project/demo` | 데모 안정화 | ★ |
| 15 | `0015-BallTracker-Added-Offset-to-fix-Ball-position.patch` | `Framework/vision/BallTracker` | 카메라 오프셋 | — |
| **16** | `0016-Fall-protection-implementation.patch` | `Framework/include/MotionManager.h`, `MotionStatus.h`, `MotionManager.cpp` | **자세 임계값 초과 시 자동 fall-recovery 페이지 호출** | ★★★ |

## patches-optional (9개)

| # | 파일 | 의미 | 우리 참고 |
|--:|------|------|-----------|
| 17 | `0017-Walking-joystick-support.patch` | 조이스틱 보행 | ★ |
| 18 | `0018-Framework-add-UDP-state-publisher.patch` | UDP 텔레메트리 publisher — Sprint 11 텔레메트리 패턴 | ★★ |
| 19 | `0019-demo-tweaked-for-IROS.patch` | IROS 2012 데모 | — |
| 20 | `0020-cm730-allow-beeper-access.patch` | CM-730 beeper 접근 | ★ |
| 21 | `0021-Walking-beep-on-IK-error.patch` | IK 실패 시 비프 | ★★ (디버깅 UX) |
| 22 | `0022-offset_tuner-use-current-pose-as-init-pose.patch` | offset 캘리브레이션 UX | ★★ |
| 23 | `0023-dxl_monitor-show-error-byte-on-Write.patch` | dxl_monitor 에러 표시 | ★ |
| **24** | `0024-ActionEditor-added-fuction-to-apply-mirrored-pages.patch` | **Action Editor 에 좌우 미러 페이지 자동 생성 기능** — Sprint 9~13 모션 합성 좌우 미러의 사실상 prior art | ★★★ |
| 25 | `0025-demo-mark-ball-position-with-blue-rectangle.patch` | 시각화 | — |

## Walking 튜닝 (patch 12) — 핵심 값

`Data/config.ini` 의 `[Walking Config]` 블록 (TeenSize 튜닝, 그대로 적용 X) — `docs/walk-lab/V1_DESIGN.md`
파라미터와 비교용:

```ini
[Walking Config]
x_offset=-8.000000
y_offset=55.000000
z_offset=10.000000
roll_offset=10.000000
pitch_offset=-1.700000
yaw_offset=0.000000
hip_pitch_offset=2.500000
period_time=900.000000            ; 스톡 OP 600ms 대비 50% 느림 (TeenSize)
dsp_ratio=0.100000                ; double-support phase ratio
step_forward_back_ratio=0.260000
foot_height=12.000000             ; mm, lift height per step
swing_right_left=1.400000
swing_top_down=0.000000
pelvis_offset=0.000000
arm_swing_gain=1.500000
balance_knee_gain=-0.000000       ; 무릎 보정 비활성
balance_ankle_pitch_gain=0.000000
balance_hip_roll_gain=0.000000
balance_ankle_roll_gain=0.000000
lean_fb_gain=5.000000             ; pitch 기울임 게인
lean_fb_accel_gain=0.000000
lean_turn_gain=2.000000
p_gain=50
i_gain=0
d_gain=0
start_step_factor=1.000000
balance_angle_smooth_gain=0.910000  ; ★ 보행 중 IMU 각도 LPF (signature 신규 도입)
balance_angle_gain=0.100000         ; ★ smoothed angle → pitch correction
```

**우리 OP1/OP2 튜닝에 그대로 옮기지 말 것.** `period_time`, `foot_height`, `y_offset` 모두 TeenSize 보정.
**구조적 변화 — smooth start, balance_angle_smooth_gain, lean_fb_gain — 는 그대로 가치 있음.**

## 모션 페이지 차이

자세한 카탈로그 → [`motions/external/_catalog/nimbro-op.csv`](../../motions/external/_catalog/nimbro-op.csv).

스톡 ROBOTIS 와의 **유일한 의미 있는 차이**:

| # | 스톡 | NimbRo | 변경 의미 |
|--:|------|--------|-----------|
| 9 | walkready (1 step) | **walkready (3 step, speed=50)** | TeenSize 큰 관성을 다루기 위해 진입 단계화 |
| 10 | f up | **up f** | 이름 표기 정정 |
| 11 | b up | **up b** | 이름 표기 정정 |

> NimbRo motion 자체는 페이지 컨텐츠가 크게 바뀌지 않음. 핵심은 **패치 (보행 + 토크 + 낙상)** 쪽.

## 우리 프로젝트에서의 활용

| 분야 | 참고 방식 |
|------|-----------|
| Sprint 5 walk-engine | patch 12 `Walking.cpp` 의 smooth-start, balance_angle_smooth_gain (LPF 융합), `QuadraticStateTransform` 로직을 Rust 로 재구현 |
| Sprint 5 walk-engine | patch 10 `AngleEstimator` 의 complementary filter 를 forge-core IMU 융합의 1차 reference |
| Sprint 6 fall-protection | patch 16 의 IMU pitch/roll 임계값 트리거 → fall-recovery 페이지 호출 로직 |
| MotionManager (Rust) | patch 07 의 dynamic torque mask API — 페이지 단위 enable/disable 인터페이스 |
| 모션 합성 (Sprint 9~13) | patch 24 의 ActionEditor 미러 기능 — 우리 `forge-cli synth mirror` 의 사실상 prior art |
| 텔레메트리 (Sprint 11) | patch 18 의 UDP state publisher 패킷 포맷 |
| 디버깅 UX | patch 21 의 IK 에러 시 비프 — Mac UI 에서는 사운드 큐로 매핑 |

## 주의

1. **TeenSize 모션 그대로 실행 금지** — `software/motion_4096.bin` 을 OP1/OP2 에 덮어쓰면 무게중심 차이로 넘어짐.
2. **CC BY-NC-SA hardware** — `hardware/CAD/*.IGS|*.STP` 는 비상업 + ShareAlike. 우리 데이터베이스에는 포함하지만 forge-core 에 임베드하지 않음.
3. **BSD-3 software** — 코드 인용 시 LICENSE 파일의 저작권 텍스트를 `vendor/LICENSES.md` 에 명시.
4. **upstream 마지막 커밋 2012-10-30** — 14 년간 정체. 코드가 ROBOTIS 1.5.0 / CM730 fw v0x13 에만 맞음. 우리는 알고리즘 추출만.
