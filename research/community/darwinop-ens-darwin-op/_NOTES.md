# research/community/darwinop-ens-darwin-op/_NOTES.md

> ENS (École Normale Supérieure) 가 ROBOTIS DARwIn-OP SourceForge 소스를 GitHub 으로 옮겨
> 자체 변경을 얹은 미러. **OP1 framework 의 가장 깔끔한 GitHub reference.** SourceForge zip 을
> 다시 받지 않고 이 저장소로 OP1 정본을 보존한다.

## 메타

| 항목 | 값 |
|------|----|
| Upstream | <https://github.com/darwinop-ens/darwin-op> |
| Commit | `fe301d0b77a9a537b4d88d2358c97864d3dd84ed` (2015-11-23) |
| Target | DARwIn-OP (CM-730, 1세대) — SourceForge v1.5/v1.6 베이스 |
| License | Apache 2.0 (ROBOTIS upstream 상속) |
| Repo size | ~4.2 MiB |
| 관련 저장소 | `darwinop-ens/simulink` (Matlab Simulink 연동) · `darwinop-ens/kinematics` (운동학/동역학) |
| Wiki | <https://github.com/darwinop-ens/darwin-op/wiki> (Hack guide / Installation guide) |
| ReleaseNote | `DARwIn-OP v1.6.1` (2014-01-07) 기점, ROBOTIS 공식 1.6 동기화 |

## 구조 (`/darwin/` 온로봇 레이아웃과 동일)

```
darwinop-ens-darwin-op/
├── readme.txt                          저장소 의도 (ENS 변경판)
├── ReleaseNote.txt                     v1.6.1 노트
├── Data/
│   ├── config.ini                      카메라/색 LUT/관절 오프셋
│   ├── motion_4096.bin                 OP1 정본 모션 (45 명명 페이지)
│   └── mp3/                            데모용 사운드
├── Framework/                          OS-independent C++ — **우리 1차 reference**
│   ├── doc/
│   ├── include/                        public 헤더 (아래 표)
│   └── src/
│       ├── math/                        Vector / Matrix / Plane / Point
│       ├── minIni/                      INI 파서
│       ├── motion/                      MotionManager + modules/{Walking,Head,Action,Kinematics}
│       └── vision/                      ImgProcess / BallTracker / BallFollower / ColorFinder
└── Linux/                              OS glue
    ├── include/                        LinuxCM730 / LinuxCamera / LinuxMotionTimer
    ├── lib/                            libdarwin.a build
    └── project/                        Linux 데모 + 도구 (아래 표)
```

### Framework/include — public 헤더 (전부 OP1 정본)

| 헤더 | 핵심 클래스 / 상수 | 우리 참고 |
|------|---------------------|-----------|
| `CM730.h` | Bulk_Read / Sync_Write / TxRx 프로토콜 1.0 래퍼 | ★★★ (Sprint 1 Rust 포팅 1차 reference) |
| `MX28.h` | 컨트롤 테이블 주소·단위 변환 | ★★★ |
| `FSR.h` | 발바닥 압력 센서 (ID 111/112) | ★★★ |
| `JointData.h` | `ID_R_SHOULDER_PITCH..ID_HEAD_TILT` 정본 — 우리는 런타임 vendored 헤더로 캡처 | ★★★ |
| `MotionManager.h` | 모션 모듈 컨테이너, 주기 루프 | ★★★ |
| `MotionModule.h` | 모션 모듈 베이스 클래스 (Walking/Head/Action 모두 상속) | ★★★ |
| `MotionStatus.h` | 글로벌 IMU + 모션 상태 (FB_GYRO 등) | ★★★ |
| `Walking.h` / `Walking.cpp` | LIPM 기반 ZMP 보행 — Sprint 5 walk-engine 1차 reference | ★★★ |
| `Action.h` | 페이지/스텝 구조 (PAGEHEADER, STEP, PAGE 512-byte) — `docs/motion-format/page-format.md` 의 ground truth | ★★★ |
| `Head.h` | 머리 트래커 | ★★ |
| `Kinematics.h` | OP1 링크 길이·DH 파라미터 — Sprint 5 IK 검증 | ★★★ |
| `BallTracker.h` / `BallFollower.h` | 사커 데모 — 우리 스코프 외 | ★ |
| `ColorFinder.h` / `Image.h` / `ImgProcess.h` | 컬러 트래킹 | ★ |
| `Camera.h` | V4L2 카메라 추상 | ★ |
| `Matrix.h` / `Vector.h` / `Plane.h` / `Point.h` | 수학 유틸 | ★ (우리 Rust 자체 구현) |
| `minIni.h` | INI 파서 | — |
| `DARwIn.h` | 통합 헤더 | ★ |

### Linux/project — 실 도구 (모두 ncurses CLI)

| 디렉토리 | 역할 | 우리 참고 |
|----------|------|-----------|
| `action_editor` | **모션 페이지 편집 — RoboPlus Action 의 CLI 등가물** | ★★★ (Sprint 9~13 합성기 UX prior art) |
| `arm_copy` | 한 팔의 자세를 다른 팔에 미러 (teleop) | ★★ (모션 합성 미러 prior art) |
| `demo` | 사커 + 비전 통합 데모 | ★ |
| `dxl_monitor` | 모터 raw 컨트롤 테이블 진단 | ★★★ (Sprint 1 forge-cli ping 의 1차 reference) |
| `firmware_installer` | CM-730 fw 업데이트 | ★★ |
| `instrumentation` | 시리얼 latency 측정 | ★★ |
| `offset_tuner` | 관절 zero-offset 캘리브레이션 GUI | ★★★ |
| `roboplus` | Windows RoboPlus 브리지 | ★ |
| `tutorial` | 단계별 학습 코드 | ★★ |
| `vertical` | 수직 자세 튜닝 (스탠드용) | ★ |
| `walk_tuner` | **보행 파라미터 실시간 튜닝 — `Walking::GetInstance()->X_OFFSET` 등 직접 조정** | ★★★ (Sprint 5) |

## 페이지 카탈로그

자세히 → [`motions/external/_catalog/darwinop-ens.csv`](../../../motions/external/_catalog/darwinop-ens.csv)

**OP1 스톡 ROBOTIS 카탈로그의 정본** — 45 명명 페이지:
- 1..6: init/ok/no/hi/??/talk1 (인사·인터랙션)
- 9: walkready (1 step)
- 10,11: f up / b up (낙상 복구)
- 12,13: rk / lk (킥)
- 15,16: sit down / stand up
- 17~19: mul1→mul2→mul3 (체이닝 데모)
- 23~31, 41~47: d1~d4 / talk2 변주 (시연용)
- 54~58: int (체이닝 인사)
- 70,71: rPASS / lPASS (사커 패스)
- 90,91: lie down / lie up
- 237~241: sit down repeat 변주

## Walking 실 코드 위치

| 파일 | 역할 |
|------|------|
| `Framework/src/motion/modules/Walking.cpp` | LIPM ZMP 보행 핵심 — **우리 Sprint 5 walk-engine 의 1차 reference** |
| `Framework/include/Walking.h` | 파라미터 인터페이스 (`X_OFFSET, Y_OFFSET, Z_OFFSET, PERIOD_TIME, …`) |
| `Linux/project/walk_tuner/cmd_process.cpp` | 파라미터 인터랙티브 튜닝 |
| `Data/config.ini` | `[Walking Config]` 블록 — 스톡 OP1 값 |

## 우리 프로젝트에서의 활용

| 분야 | 참고 방식 |
|------|-----------|
| Sprint 1 forge-cli (Rust) | `CM730.{h,cpp}`, `Linux/include/LinuxCM730.{h,cpp}` 의 Protocol 1.0 packet builder/parser 직역 |
| Sprint 3 motion 파서 | `Framework/include/Action.h` 의 PAGE/STEP 구조 — `docs/motion-format/page-format.md` 의 ground truth |
| Sprint 4 motion editor | `Linux/project/action_editor` 의 키 바인딩·페이지 네비게이션 UX 패턴 (ncurses → SwiftUI 매핑) |
| Sprint 5 walk-engine | `Framework/src/motion/modules/Walking.cpp` 직역 + `Kinematics.h` 의 링크 길이 검증 |
| Sprint 7 3D pose | `Framework/include/JointData.h` 의 ID 매핑 — vendored 헤더로 캡처 (현재 `research/robotis-official/ROBOTIS-Framework/robotis_device/` 에 동일 내용 있음) |
| Sprint 9~13 모션 합성 | page 12 (rk) / 13 (lk) 의 step 시퀀스를 좌우 미러 검증의 reference로 |
| 모션 페이지 백업 | `Data/motion_4096.bin` 자체가 OP1 정본 — 우리 출하 시 fall-back 모션 후보 |

## 주의

1. **OP1 전용** — `Data/motion_4096.bin` 은 OP1 (CM-730 + 1세대 MX-28) 기준. OP2 (CM-740) 에는 그대로 적용 가능하나 compliance/torque 차이 검증 필요.
2. **upstream 마지막 커밋 2015-11** — 10 년간 정체. ROBOTIS 가 SourceForge 도 동결. ENS 가 사실상 archive.
3. **Simulink/Kinematics 분리 저장소** — 본 저장소에는 포함 X. Phase 2 운동학 검증 필요 시 `darwinop-ens/kinematics` 추가 클론.
4. **Apache 2.0** — 코드 직접 인용·재배포 OK. 헤더에 ROBOTIS 저작권 라인 보존.
