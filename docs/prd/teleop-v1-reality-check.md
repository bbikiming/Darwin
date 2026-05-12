# Critical Reality Check — Teleop v2 PRD 와 실제 코드의 격차

> **점검일**: 2026-05-12 (PRD v2 commit 944eaa5 기준)
> **태도**: 냉정. PR 머지 후 동작 안 할 risk 를 찾는다.
> **결론**: **PRD v2 는 동작하지 않는다.** 11개 critical / 7개 major / 5개 minor 격차 존재. Sprint 15 일정 7일 → **현실적 12~15일**.

---

## 0. 한 줄 결론

PRD v2 는 "공식 데모를 그대로 실행한다" 고 주장하지만, 그 주장이 성립하려면 **현재 코드에 없는 7 개의 API + 2개의 robot-side 데몬 + 1개의 IK 알고리즘** 이 먼저 존재해야 한다. 본 문서는 그 격차를 항목별로 적시한다.

---

## 1. 🔴 CRITICAL — 머지하면 동작 안 함 (11건)

### C1. `forge motion play` 가 라이브러리가 아니라 CLI 다

**PRD 주장** (§7.1): `TeleopChannel.send(.Motion(slot))` → `store.playMotionSlot(slot)` → 실 모터 송출
**현실**:
- `forge motion play` 는 **`app/core/forge-cli/src/motion_play.rs`** 에만 존재.
- forge-core 의 라이브러리 API 가 **아님**.
- Swift 에서 호출하려면 두 옵션:
  1. `Process` 로 별도 CLI 프로세스 spawn — 매번 USB port reopen, ~1s overhead, signal handling 깨짐
  2. **`motion_play.rs` 의 로직을 `forge-core::control` 로 추출 + `fc_motion_play` FFI 노출** — Sprint 15 안에 신규 작업
- `forge-ffi/src/lib.rs` 의 26개 export 중 `fc_motion_play` **없음**.
- `BusActor.swift` 에도 `playMotionSlot` **없음**.

**작업량**: forge-core 에 `MotionPlayer` 추출 + 4~5개 FFI + Swift 래퍼 = +1.5일

**현재 추정 Day 1 작업** 에 누락. 명시 필요.

---

### C2. CmController 에 IMU 읽기 함수 자체가 없다

**PRD 주장** (§6.5 / §7): Auto-Recovery 가 `imu.pitch > 50°` 자동 감지 → page 10/11
**현실**:
- `controller/mod.rs::cm_register` 에 GYRO_X/Y/Z (38/40/42), ACCEL_X/Y/Z (44/46/48) 상수 **정의는 있음**.
- 하지만 `CmController::snapshot()` 은 model/version/voltage/button 만 읽는다.
- **`fn read_imu()` 가 존재하지 않는다**. raw → degrees 변환도 없다.
- `walk::imu::ImuSample` 는 데이터 구조만, 보드 read 와 연결되어 있지 않음.
- `ConnectionStore.lastTelemetry` 는 `TelemetrySnapshot { board, joints }` 만 — IMU 필드 자체가 없음.
- v2 impl prompt Day 7 에 "ConnectionStore 보강" 한 줄로 처리됐지만, 실제로는:
  1. `forge-core::controller::cm::CmController::read_imu() -> ImuSample` 신규
  2. raw → rad/s, m/s² 변환 (gyro scale 2000 deg/s / 32767, accel scale 4g / 32767 추정)
  3. `ComplementaryFilter` 시간 적분 with proper dt
  4. `fc_bus_read_imu_filtered` FFI
  5. `ConnectionStore.lastImuRoll/Pitch` 노출 + telemetry 폴링 통합

**작업량**: +1.5일. CRITICAL 이유 = **이게 없으면 자동 복구가 작동 안 함** (PRD 의 가장 큰 자랑 중 하나).

---

### C3. **WalkLab 의 "로봇에 적용" 은 걷기가 아니다**

**PRD 주장** (§부록 A 매핑): `WalkLab` 의 walk→실 로봇 적용 로직을 `ConnectionStore.applyWalkPreset(_:)` 공유 헬퍼로 추출
**현실** (`WalkLab.swift:286-297`):

```swift
private func walkPoseFromSample(_ s: FootTargets) -> RobotPose {
    let phaseT = s.elapsedMs / 1000.0
    let swing = sin(phaseT * 2.0 * .pi) * 0.15
    var p = RobotPose.walkReady.positions
    p[.lHipPitch] = lHipPitchBase + Int(swing * 2048.0 / .pi)
    p[.rHipPitch] = rHipPitchBase - Int(swing * 2048.0 / .pi)
    return RobotPose(positions: p)
}
```

이건 **걷기가 아니다**. walkReady 자세 위에 hip pitch 만 ±8.6° sin파 흔들림. 발을 들지도 않고 (`foot_height=0.04m` 무시), 무릎/발목도 변화 없고, x/y/a amplitude 도 무시.

**결과**:
- PRD 의 `WalkPreset 5종 실송출` 은 사실상 **제자리 무릎-굽혔다-펴기**. 진짜 보행 X.
- "전진" 클릭 → 로봇이 앞으로 안 감. 그냥 무릎만 흔든다.
- BLOCKER C3 (실 IK 부재) 가 v1 PRD 에 명시되어 있었지만, v2 부록 A 가 이를 "재사용 헬퍼" 로 격하시킴.

**현실적 옵션**:
- **옵션 A (정직)**: PRD §3.2 비목표 에 **"WalkPreset 실송출 — 실 IK 완성 후 v2"** 추가. Sprint 15 의 D-pad 는 **sim 미리보기만** 동작. 실 모터 송출은 Action Bar 페이지 트리거만.
- **옵션 B (대담)**: Sprint 15 안에 ROBOTIS-OP2 `op2_walking_module` 의 IK 알고리즘 Rust 포팅 (3D vector geometry + 6-DOF leg IK). 추정 **+5일**, BLOCKER C3 해결.
- **옵션 C (영리)**: 로봇 측 ROBOTIS framework 의 `walk_tuner` 또는 Linux/project/walk_demo 를 우리가 TCP 로 호출. 즉 IK 는 robot 이 하고, 우리는 X/Y/A 만 보냄. 단, robot 측 데몬 셋업 필요 + 별도 protocol.

**권고**: 옵션 A + 추후 옵션 C. CRITICAL 표시 이유: "D-pad 누르면 로봇이 안 걷는다" 는 사용자 신뢰 파괴.

---

### C4. `vision_demo` 가 HTTP MJPEG 서버가 아니다

**PRD 주장** (§7.1 / impl prompt §16): `URLSession` 으로 `http://<host>:8080/?action=snapshot` GET
**현실**:
- ROBOTIS framework `Linux/project/vision_demo` 는 **데스크탑 GUI 애플리케이션** (LinuxFrameBuffer/X11). HTTP 서버가 **아님**.
- `:8080` endpoint 는 **mjpg-streamer** 또는 별도 데몬 (사용자가 별도 설치한 경우만).
- 우리 `RemoteShellView.QuickActions` 의 `vision-start` 가 호출하는 명령:
  ```
  cd ~/Framework/Linux/project/vision_demo && sudo ./vision_demo &
  ```
- 이 명령은 데스크탑 창 띄움 — 우리 Mac UI 는 그 창을 볼 수 없음.
- 즉 PRD 의 카메라 view 는 **사전 셋업 안 된 endpoint** 를 가정.

**옵션**:
- **옵션 A**: `mjpg-streamer` 셋업 가이드 + QuickAction 추가 (`apt-get install mjpg-streamer && mjpg_streamer -i "input_uvc.so -d /dev/video0" -o "output_http.so -p 8080"`)
- **옵션 B**: 우리가 robot 측에 작은 HTTP/MJPEG bridge 설치 (Python `picamera` or v4l2 + Flask) — 추가 데몬
- **옵션 C**: VNC 화면 캡처 (5900) — 화질·지연 나쁨

**권고**: 옵션 A + RemoteShellView 의 vision-start QuickAction 수정. **+0.5일**.

---

### C5. forge-bridge (TCP 5530) 데몬이 robot 측에 존재하지 않는다

**PRD 주장** (§2.1): 연결 `TCP 5530` ✅ 완성
**현실**:
- `docs/harness/v2-mac-ui-handoff.md`: "robot onboard PC에 `forge server` 데몬 설치 필요 (별도 가이드 — 미작성)"
- 즉 **셋업 가이드 자체가 존재하지 않음**.
- `scripts/harness/probe.sh` 는 5530 reachable 여부만 체크.
- `RemoteShellView.QuickActions` 의 `forge-bridge-restart` 가 `/etc/init.d/forge-bridge` 를 가정 — 이 init 스크립트는 **누가, 언제 robot 에 깔았는가?**
- **결론**: TCP 5530 endpoint 는 **수동 셋업 안 된 사용자에게는 작동 안 함**. PRD 가 이 사전 조건을 명시 안 함.

**작업량**: robot-side setup 스크립트 + 한국어 가이드 = +1일

---

### C6. 공식 BallFollower 의 정확한 상수가 우리 PRD 에 추정값

**PRD 주장** (§6.2): kick_tilt_threshold_deg = 30.0, kick_pan_deadzone_deg = 5.0, MIN_KICK_SIZE = pixel_count > 1000, K_a = 0.10/90°, K_x = 0.025 * ((30 - tilt)/30)
**현실**:
- 본 repo 에 `BallFollower.cpp` 소스 **없음**. 우리는 표준 패턴만 인용.
- 공식 코드의 실제 상수는 (공개된 ROBOTIS-OP3 ball tracker 기준):
  - `m_FollowMaxFBStep = 30.0` (mm/step) → 0.030 m
  - `m_KickBallSize = 50.0` (pixel diameter) — 우리의 pixel_count > 1000 와 단위 다름
  - `m_KickTopAngle = -65.0` (head tilt deg, downward) — **음수**. 우리 +30 (upward) 와 부호 뒤집힘
  - `m_KickRightAngle = -30.0` (pan deg, 우측), `m_KickLeftAngle = +30.0` — 우리 ±5° 와 큰 차이
  - `m_FollowAimAngle = 60.0` (deg/sec turn gain) — 우리 0.10/90° 와 다른 단위
- **즉 우리 상수는 모두 우리가 추측한 값**. "공식 패턴 충실 재현" 이 아니라 "공식 패턴 영감 받음".

**작업량**: ROBOTIS-OP3 ball tracker 또는 DARwIn-OP soccer 코드 한 번 더 인용 → 상수 정확 매핑 = +0.5일. PRD 의 "충실 재현" 주장의 정직성 회복.

---

### C7. `precheck_motion` 호출 흐름이 PRD 와 어긋남

**PRD 주장** (§7.3): Auto-Recovery 가 `Motion(slot: 10, confirmRisk: true)` 자동
**현실**:
- `control/mod.rs:186` 의 `precheck_motion` 시그니처:
  ```rust
  pub fn precheck_motion(&self, page: &MotionPage, options: ExecuteOptions) -> Result<()>
  ```
- 입력은 **`MotionPage` (이미 디코딩된 페이지 객체)** + ExecuteOptions. slot ID 만으로 호출 불가.
- 즉 호출 측은 먼저 `motion_4096.bin` 디스크에서 slot N 의 page 디코딩 + ExecuteOptions 생성 + precheck → 실 송출.
- 이 흐름이 **forge-cli motion_play.rs 안에만 구현**. forge-core 라이브러리 표면에 정돈된 `play_motion_slot(slot, opts)` 가 없음.
- **결과**: `TeleopChannel.send(.Motion(slot: 10))` 호출이 어떤 코드 경로를 통과하는지 PRD 가 명세 못 함.

**작업량**: C1 과 함께 처리.

---

### C8. page 10/11 (Get Up) 은 `Caution` 인데 PRD 가 `confirmRisk: true` 자동 호출

**PRD 주장** (§7.2): `Action::Play(pitch > 0 ? 10 : 11)` (낙상 자동 복구), v2 impl prompt §14: `confirmRisk: true 자동 — 낙상은 즉시 복구 필요`
**현실**:
- `motion/library.rs:195-203`: page 10/11 의 `SafetyClass = Caution`, **NOT HighRisk**.
- `precheck_motion` 는 HighRisk + !confirm_risk 만 거부. Caution 은 confirm_risk 무관하게 통과.
- 즉 `confirm_risk: true` 를 줘도 의미 없음 (이미 통과). 단, 우리 PRD 의 "낙상은 즉시 복구 — confirm 자동" 의도는 맞음.
- 문제: **PRD §13 의 L2 게이트가 "HighRisk + !confirmRisk → Alert"**. 우리 fall recovery 는 HighRisk 가 아니므로 L2 미발동. 그러나 자동 복구 시 사용자 의사 확인 우회 — 안전 게이트 우회 가능성.
- 더 큰 문제: 자동 복구 도중 `ARM` 가 OFF 상태일 수도 있음. L1 (NotArmed) 게이트 우회해야 하나?
- **PRD 결정 누락**: 낙상 복구는 ARM 우회 가능? deadman 우회? L1/L3 게이트 정책 명세 없음.

**권고**: PRD §13 에 "Fall Recovery exemption" 명시 — L1 (armed) / L3 (deadman) 모두 우회, L0 (E-stop) 만 차단. 코멘트 + 토스트로 사용자 인지.

---

### C9. Head joint write 시 leg walk 와 bus 경쟁

**PRD 주장**: BallFollow loop 가 매 100ms head SYNC_WRITE + walk SYNC_WRITE
**현실**:
- `BusActor` 가 actor 라 직렬화 됨 ✅ — race 자체는 없음.
- 하지만 dynamixel bus 는 **half-duplex 1Mbps**. 매 100ms 에:
  - head 2 joints SYNC_WRITE: ~12 byte = 0.1 ms
  - leg 12 joints SYNC_WRITE (현재 stub 도 다 발행): ~50 byte = 0.5 ms
  - 응답 없는 SYNC_WRITE 라 OK 지만, 별도로 IMU read (~ 1 ms) + voltage poll (~0.5 ms) = 합 ~ 2 ms / cycle
- 100 ms 주기에 2 ms 사용 = 2% bus 부담. 문제 없음 ✅.
- 단, ManualPilot 에서 D-pad 누르며 동시에 Ball-Follow auto-walk 가 활성된 경우 (race 가능). PRD 의 모드 전환 race 방지 (1 프레임 Stop) 가 이를 해결.

**평가**: 실제로는 문제 없을 가능성 높음. PRD 명시 안 됐지만 우려할 수준 아님. Major 가 아니라 Minor 로 강등.

---

### C10. ARM 시퀀스의 walkready 호출이 모터 토크 ON 안 됨

**PRD 주장** (§8.2): ARM 완료 → walkready (page 9) 자동 호출 → 1초 대기 → 준비 완료
**현실**:
- `RobotPose.walkReady` 적용은 `forge motion play --slot 9 --engage` 와 동일 경로.
- 하지만 ARM 시점에 **모터 토크가 OFF 일 수 있다** (사용자가 sit 후 disarm 했다가 재arm).
- `precheck_motion` 은 토크 상태 안 봄.
- 실 송출 시 첫 set_position 명령에 모터가 떨림 / 무동작.
- **TorqueRamper** (Phase A) 가 P_GAIN 0→8→16→32 ramp 으로 보호하지만, ARM 시퀀스가 ramp 를 호출하는지 PRD 미명시.

**권고**: ARM 시퀀스 보강:
```
ARM 완료
  ↓
[1] CM_REGISTER::DXL_POWER = 1 (Dynamixel power gate ON)
[2] TorqueRamper gentle (P_GAIN 0→8→16→32) 모든 관절
[3] Toast "보행 자세로 전환 중…"
[4] forge motion play --slot 9 --engage
[5] duration_ms 대기
[6] Toast "준비 완료"
```

**작업량**: +0.5일.

---

### C11. emergencyStop() 중 motion 진행 시 모터 재활성화 race

**PRD 주장** (§13 L0): ⌘⇧. → `bus.emergencyStop()` 즉시
**현실**:
- `control/mod.rs:211` `emergency_stop()`: 모든 관절 토크 OFF + P_GAIN 0.
- 하지만 motion play loop 는 step 별로 set_position 을 발행. set_position 은 토크 OFF 상태에서도 goal_position 만 set — 다음 step 에서 다시 토크 ON 권유.
- 즉 E-stop 후 motion loop 가 계속 step 진행 → 모터 재활성화 위험.
- **PRD 가 motion cancellation 메커니즘 명시 안 함**.

**권고**: `TeleopChannel.emergencyStop()` 가 다음을 모두 수행:
1. 진행 중인 motion play task `Task.cancel()`
2. `bus.emergencyStop()` 토크 OFF
3. 모든 actor 의 `currentCmd = .Stop` 강제 갱신
4. `dispatcher.mode = .simulation` 로 변경 (실 송출 안전 격리)

**작업량**: +0.5일.

---

## 2. 🟠 MAJOR — 동작은 하지만 신뢰 떨어짐 (7건)

### M1. mp3 동기 — UI 라벨만, 실제 재생 X

**PRD §12.4**: "v1 은 mp3 재생 비활성. UI 에 라벨만 표시."
**현실**: 사용자 기대 — `Right kick.mp3` 표기 보면 "차기 할 때 mp3 가 재생되겠지" 라고 가정. PRD 가 작은 글씨로 비활성 안내했지만 사용자 인지 어려움.
**권고**: UI tooltip 옆에 `(v1 미재생)` 명시. 또는 robot 측 mp3 player 호출 옵션 (SSH 로 `aplay Data/mp3/Right\ kick.mp3 &`) 을 QuickAction 으로 노출.

### M2. page chain 자동 재생 — forge-cli 기본 ON 인데 PRD v1 비활성

**PRD §5.3**: "page chain 자동 재생 (next != 0): page 24→25, 38→39 등. v1 에서는 첫 페이지만 재생. v1.1 에서 chain 지원"
**현실**: `motion_play.rs:67` `follow_chain: bool` 기본 = true. CLI 호출 시 chain 따라감. PRD 가 v1 에서 chain 끄려면 명시적으로 `--follow-chain false` 필요.
**권고**: 양자택일.
- PRD 변경: chain ON 으로. page 24→25 = "Wow" 풀 시퀀스 재생.
- 코드 변경: TeleopChannel 이 chain OFF 로 호출.

### M3. HSV 튜닝 — 사용자 정의 저장만, 실시간 미리보기 비싸다

**PRD §9.1**: "[실시간 미리보기: blob 매칭 표시]"
**현실**: 매 frame 에 대해 매칭 픽셀을 따로 색칠 → CGImage 마스킹 = 100 ms 마다 비용. 작업이 큼.
**권고**: 미리보기는 1 Hz 만. 또는 빨간 outline 한 사각형 (blob bbox) 만 표시.

### M4. LookingForBall scan — head + body 동시 회전 충돌

**PRD §6.3**: "head scan 좌→우 sweep + body 천천히 좌회전 (a_amp=0.10)"
**현실**: head 가 빠르게 흔드는 동안 body 도 천천히 돌면 사용자 시야에서 어지러움. 또한 카메라 회전이 head + body 합쳐져 FOV 가 헷갈림.
**권고**: scanning 중에는 body 회전 OFF. head 만 sweep. 5초 안에 못 찾으면 그때 body 1회 turn (45°) 후 다시 head scan.

### M5. 카메라 view head 십자선 위치 계산이 비자명

**PRD §11.3**: "현재 joint 19/20 각도 → 카메라 frame 의 가상 시선 위치"
**현실**: head pan/tilt 각도 → 카메라 frame 좌표 매핑은 **카메라 intrinsic + extrinsic** 필요.
- 카메라 FOV ≈ 60° horizontal, 45° vertical (DARwIn camera datasheet)
- 매핑: `x = (pan_deg / FOV_h) * W + W/2`
- 단, head 가 회전했을 때 카메라가 절대 좌표에서 어디를 보는지 그릴 게 아니라, "현재 추적 목표 위치" 이므로 frame 중앙 = 추적 목표 — 즉 head 십자선은 항상 중앙. **PRD 의 의미가 명확하지 않음**.
**권고**: PRD 가 "head 십자선" 이 무엇을 표현하는지 재정의.
- 옵션 A: 항상 frame 중앙 (= "head 가 보는 곳") 라면 의미 X — 그냥 카메라 원점 표시
- 옵션 B: blob 위치를 head 가 따라잡으려는 목표 위치 — 즉 PID 의 target. PID 가 수렴하면 blob 십자선과 head 십자선 합쳐짐 ← 이 의미면 두 점이 다른 게 정상
- 의도 = B 라면 명세 보강 필요

### M6. Sprint 15 일정 7일 — 신규 작업 정산 안 됨

PRD §16 의 7일 분해는 신규 ffi (C1), IMU read (C2), 카메라 셋업 가이드 (C4), bridge 셋업 (C5), motion cancellation (C11), ARM ramp (C10), HSV 미리보기 (M3) 등을 정산하지 않음.
**현실적 추정**: 7일 → **12~15일**. 한 단계씩 다시:
- Day 1: Rust teleop + pid + head_tracker
- Day 2: Rust ballfollow + IMU read (CmController 보강) + motion play 라이브러리 추출
- Day 3: forge-ffi 신규 9개 노출
- Day 4: Swift MotionCatalog + HeadJointController + TeleopChannel + FallRecoveryCoordinator
- Day 5: PilotSafetyGate (IMU 통합) + BallFollowEngine v2 + MjpegSnapshot + 카메라 셋업 가이드 / 데몬
- Day 6: forge-bridge 셋업 스크립트 + 한국어 가이드 + RemoteShell QuickAction 갱신
- Day 7: ARM 시퀀스 + 토크 ramp 통합 + emergencyStop cancellation
- Day 8: PilotArmSlider + PilotModePicker + PilotDpad + PilotSpeedGauge
- Day 9: PilotActionBar + + 더보기 시트 + tooltip
- Day 10: PilotCameraView (head 십자선 의미 결정 후) + TargetReticle + HsvTuningPanel
- Day 11: PilotHudStrip + RemotePilotView 통합 + RootView ⌘8
- Day 12-13: HIL 6 시나리오 + 회귀 fix
- Day 14-15: BLOCKER C3 보강 (옵션 A 면 비목표 처리만, 옵션 B/C 면 별도)

### M7. Sprint 15 가 BLOCKER C3 결정 없이 시작될 수 없음

**PRD §17 OQ-1**: "BLOCKER C3 해결 후 슬라이더 풀-스윙 허용 — Sprint 14 walk-lab 후"
**현실**: Sprint 14 walk-lab 실험은 안 됐다 (PROGRESS.md 마지막은 Sprint 13). C3 미해결 상태로 v2 진입 = D-pad 누르면 hip 만 흔드는 가짜 walk.
**권고**: PRD 가 D-pad 모드를 **2단계로 분리**:
- v1a (sim only): D-pad 시각화 + sim WalkEngine. 실 모터 송출 X. 사용자가 "느낌 익히기" 모드.
- v1b (real, C3 후): 실 IK 완성 후 unlock.
또는 **WalkPreset 실송출을 forge-cli 의 별도 명령으로 분리**해 명시적 opt-in (안전 인지).

---

## 3. 🟡 MINOR — 정직성·완성도 손해 (5건)

### m1. WalkEngine.set_command 가 sim only 라는 사실 — Action Bar 와 별개

PRD 가 Action Bar (모션 페이지) 와 D-pad (걷기) 의 동작 차이를 사용자에게 충분히 설명 안 함. 두 모두 "조종" 으로 묶이는데:
- Action Bar: 진짜 실 모터 명령 (16 페이지 모두 검증됨)
- D-pad: 가짜 (BLOCKER C3 까지)

**권고**: PRD §3 에 "v1 capability matrix" 명시.

### m2. SafetyClass 자동 변환 — TOML sidecar 와 Rust library.rs 가 일치하는지

`page-metadata-motion4096.toml` (page 10/11 = Caution) 와 `library.rs:195-203` (page 10/11 = Caution) **일치** ✅. page 12/13 (HighRisk) 도 일치 ✅. 검증 OK.

단, `page.17 mul1` 의 safety_class:
- sidecar = "HighRisk" (toml:130)
- library.rs:217 = SafetyClass::HighRisk ✅
일치 ✅.

### m3. v1 비목표 "Page chain 자동 재생" — 실제로 forge-cli 가 기본 ON

§M2 와 중복. minor 로 기록.

### m4. 한국어 UX 문구 — KoreanUX 모듈과 일관성 부족

PRD 의 일부 토스트 ("기울어짐 감지 — 정지" 등) 가 `KoreanUX.Safety` 의 기존 문구 (`nearFall = "로봇이 30° 넘게 기울었어요. 손으로 잡아주세요."`) 와 다른 톤.
**권고**: 모든 PRD 토스트를 `KoreanUX.Safety/Motion/Connection` 으로 routing.

### m5. HSV 4 preset 의 RED_CARD wrap-around

PRD §9.2 의 `RED_CARD (h: 350~10 wrap, s 0.5, v 0.4)`. `HsvRange::contains` 가 wrap-around 지원함 ✅ (segmentation.rs:43). 동작 가능. 단 사용자 슬라이더 UI 에서 wrap 표현이 어려움 (slider 두 개를 합쳐 wrap 표시 — UX 복잡). v1 에서는 4 preset 안의 RED 만 hardcoded wrap, 사용자 정의는 wrap 비지원.

---

## 4. 종합 평가 — PRD v2 의 정직성 다이얼로그

### 4.1 PRD v2 가 정직했던 부분 ✅

- BLOCKER C3 (실 IK 부재) 를 §4 C1 에 명시
- audit 결과 12 PATCH 통합 정직 표기
- 공식 sidecar `display_name` 채택 (slot 1/4 라벨 정정)
- `motion_4096.bin` byte-identical 보존 원칙 명시

### 4.2 PRD v2 가 과장한 부분 ❌

| 주장 | 현실 |
|---|---|
| "공식 BallFollower 충실 재현" | 상수가 추정값. 정확 매핑 안 됨 (C6) |
| "공식 StatusCheck 자동 복구" | IMU read 함수 자체 없음 (C2) |
| "WalkPreset 5종 실송출" | 가짜 walk (C3) |
| "vision_demo MJPEG :8080 ✅ 로봇 측" | 데몬 셋업 가이드 자체 없음 (C4) |
| "TCP 5530 forge-bridge ✅ 완성" | robot-side 데몬 미설치 (C5) |
| "Sprint 5일 → 7일 재추정" | 현실 12~15일 (M6) |

### 4.3 격차 종합

| 영역 | PRD 주장 | 실제 격차 |
|---|---|---|
| 모션 페이지 재생 (Action Bar) | 90% | 75% (C1, C7, C8, C10, C11) |
| 걷기 명령 (D-pad) | 95% | **30%** (C3 가 결정타) |
| Ball-Follow (head PID + walk + 좌/우 차기) | 95% | 50% (C2, C6) |
| 낙상 자동 복구 | 90% | 40% (C2 + C8) |
| 카메라 view | 80% | 30% (C4) |
| 안전 게이트 (4-layer) | 95% | 75% (C8, C11) |
| **종합** | **94%** | **57%** |

PRD v2 가 자신의 충실도를 94% 라 주장 — 현실은 57%.

---

## 5. 권고 — Sprint 15 진입 전 의사결정

### 5.1 옵션 A: 정직한 v1.5 (권장)

PRD v2 를 v1.5 로 재명명. 본 audit 의 11 CRITICAL + 7 MAJOR 모두 반영:

1. **D-pad sim only** — 실 송출 비활성. 사용자에게 "느낌 익히기 모드" 명시. BLOCKER C3 해결 후 v2 에서 unlock.
2. **Action Bar 실 송출** — 16 페이지 모두 가능. C1/C7/C10/C11 보강 후.
3. **Ball-Follow** — head 추적은 가능 (joint 19/20 SYNC_WRITE 는 작동). walk 자동 송출은 OFF (또는 sim 만). 차기 (page 12/13) 는 실 송출 가능.
4. **자동 복구** — IMU read 추가 (C2) 후 가능. ARM 우회 정책 명시 (C8).
5. **카메라** — robot-side mjpg-streamer 셋업 가이드 + RemoteShell QuickAction 갱신.
6. **bridge** — forge-bridge 셋업 스크립트 신규 + 가이드.

작업량: 12~15 일. 정직성 우선.

### 5.2 옵션 B: 점진적 v1.0 → v1.1 → v2

- **v1.0 (3일)**: Action Bar 7 페이지 (1, 4, 9, 15, 23, 12, 13) 실 송출. C1/C7/C10/C11 만. D-pad / Ball-Follow / 자동복구 모두 비활성.
- **v1.1 (3일)**: IMU read (C2) + 자동 복구 + Ball-Follow head 추적만 (walk 자동 X).
- **v1.5 (5일)**: Ball-Follow walk 자동 (sim only, BLOCKER C3 까지) + 카메라 셋업 (C4) + bridge (C5) + UI 모든 컴포넌트.
- **v2 (BLOCKER C3 후, ?일)**: D-pad 실 송출 + Ball-Follow walk 실 송출.

작업량: 11 일 + α. 점진적 가치 인도.

### 5.3 옵션 C: BLOCKER C3 먼저 해결 후 v1

ROBOTIS-OP2 `op2_walking_module` IK Rust 포팅 5일 → 그 후 Sprint 15 진입 12일. 총 17일.

작업량 가장 큼. 완성도 최대.

---

## 6. 결론

PRD v2 는 **머지하면 동작 안 한다**. 11개 CRITICAL 격차 중 **C1, C2, C3, C4, C5 가 동작 자체를 막는다** (motion play 라이브러리 X, IMU read X, walk = 가짜, 카메라 endpoint X, bridge 데몬 X). 5개 모두 Sprint 15 안에 동시 해결해야 하나, 그 추가 작업이 일정 7일 → 12~15일로 늘어남.

**가장 위험한 격차** = **C3 (가짜 walk)**. 사용자가 "전진" 클릭 → 로봇이 무릎만 흔드는 것을 보면 신뢰가 무너진다. BLOCKER C3 결정 없이 Sprint 15 진입 = 사용자 신뢰 도박.

**권고**: 옵션 B (점진적 v1.0 → v1.1 → v2). v1.0 (3일) 으로 빨리 Action Bar 7 페이지 만이라도 작동하는 화면을 만들고, 그 다음 단계적으로 확장. PRD v2 는 v1.5 로 격하, "v2 는 BLOCKER C3 후" 라 명시.

다음 단계로 어떤 옵션을 택할지 사용자 결정 필요.
