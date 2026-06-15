# 직결(Bus) 컨트롤러 조종 — 데모 업그레이드 설계 (Direct-Drive Teleop Upgrade)

> 2026-06-11 · 직결 경로(Mac → forge-bridge TCP5530/USB → Dynamixel 버스) 전수 독해 +
> git 이력 기준 최신 반영 상태 교차 검증. 온보드 경로는
> `docs/design/walklab-onboard-teleop-upgrade.md`, Mac 전송·계측 공통 인프라는
> `docs/design/cockpit-latency-hardening.md` 가 관장한다. 모든 사실 진술에 파일:줄/커밋 앵커.

## 0. 결론 요약

직결 모드에서는 로봇 demo 가 꺼지고(forge-bridge 가 ttyUSB0 점유) **Mac 이 게이트 생성·밸런스·
낙상복구·머리까지 전부 담당**한다. 온보드와 정반대 프로파일이다:

- **전송은 이미 빠르다**: SYNC_WRITE 일원화(L5)·burst read(J12)·E-STOP 락 선점(S4)·논블로킹
  drain(J11)·io-timeout 50ms 가 전부 커밋 완료(e0bb2cf·da495d6·7808fdb). SYNC_WRITE 는
  브로드캐스트(상태 응답 없음)라 송출 1회 ≈ 0.5ms — fire-and-forget.
- **병목은 게이트 해상도다**: 보행이 사이클당 **6개 키프레임**(`samplePhases`,
  `WalkMotionLibrary.swift:107`) 스트리밍 ≈ **10Hz 등가**이고, 자이로 밸런스 보정도 step
  경계(80–117ms)에서만 주입된다 — 온보드 125Hz 게이트+125Hz 자이로 P 대비 1/12 해상도.
- **핵심 발견**: 포즈 생성 함수 `robotisWalkingApproxPose(timeMs:)` 는 이미 **연속 시간
  함수**다(`WalkMotionLibrary.swift:113`). 즉 고밀도화는 새 알고리즘이 아니라 **같은 함수를
  더 자주 샘플링**하는 문제이고, 1Mbps 버스 예산상 50Hz 스트리밍+50Hz IMU 리드를 합쳐도
  점유 ~5% 다. 이것이 본 설계의 본체(Wave D1·D2)다.

Wave D0(잔여 결착+계측) → D1(50Hz 연속 스트리밍+래칭 의미론 정렬) → D2(밸런스 50Hz+FSR) →
D3(데모 운영 자동화). 완료 시 직결 모드는 **입력→서보 write p95 ≤60ms, 보정 루프 20ms**로
온보드보다 반응성·관측성 모두 우위인 "시연 기준 경로"가 된다.

## 1. 현재 직결 아키텍처 — 검증된 사실

### 1.1 경로와 책임

```
[Mac] CockpitState 30Hz (EMA α=0.25) → pilotApplyFreeform(stride/side/turn/period)
  → WalkLabSession freeform task: WalkMotionLibrary.freeformContinuousWalkPlan(tuning)
     └ makeContinuousPlan: samplePhases [0.03,0.18,0.42,0.52,0.68,0.92] × period
       → robotisWalkingApproxPose(timeMs:) — swap+move 합성+해석 IK (Walking.cpp 근사 Swift 구현)
       → 6 MotionStep, playMs = max(80, period/6)            WalkMotionLibrary.swift:105-129
  → runContinuousWalk: step마다 transformPose(밸런스) → changedJoints → SYNC_WRITE 1패킷
     + 하체 liveness PING 라운드로빈                          WalkLabSession+WalkCycleEngine.swift
[버스] socat TCP5530(유선 LAN) 또는 USB 직결 → CM-730/740 → MX-28 (1Mbps, 바이트 12µs)
```

- 사이클 시간: `playMs×6 ≈ period`, 단 `playMs ≥ 80ms` 하한 → **최소 사이클 480ms**.
- 튜닝 반영: freeform task 가 phase 경계마다 재읽기(레이턴시 문서 §1) — 래칭 규칙은
  온보드(Walking.cpp 의 PHASE1/3 래칭)와 **비일관**.

### 1.2 밸런스 보정 — 존재하나 저해상도 (에이전트 보고 정정)

- `startWalkCycle` 이 `transformPose: applyBalanceCorrectionIfEnabled` 를 실제로 전달
  (`WalkLabSession+StartCycle.swift:478`) — 보정은 **배선돼 있다**.
- IMU 는 `fc_bus_read_imu`(`forge-ffi/src/lib.rs:517` → `controller/cm.rs:253`) 폴 태스크가
  공급하며, **보행 중 50ms(20Hz)로 동적 증속**(`ConnectionStore.swift:296·2700-2703`).
- 그러나 적용 시점이 step 경계(80–117ms) → **실효 보정 주입률 ~10Hz**. 보정식은
  `docs/architecture/walking-algorithm-design.md` §8.2 (ROBOTIS internal_gain −0.3 ×
  hip-roll/knee/ankle 게인).

### 1.3 전송·안전 계층 반영 현황 (git 이력 기준)

| 항목 | 상태 | 커밋 |
|---|---|---|
| L5 보행 SYNC_WRITE + J12 burst read(addr 24..43 1왕복) | ✅ | e0bb2cf |
| S4 E-STOP 락 선점(`estop_flag: AtomicBool`, `EstopPreempted`) + J11 논블로킹 drain | ✅ | da495d6 (`dynamixel/bus.rs:19-66`, `serial/tcp.rs:79-122`) |
| io-timeout 보행 start/stop 배선(50ms) | ✅ | 7808fdb |
| J2 머리 SYNC_WRITE + detached coalesce (`writeHeadPose`, `ConnectionStore.swift:2156-2186`) | ✅ | c62d3af |
| L6/L7 MainActor 탈출, Wave 0(S1/S2/L3/J3), S3, J1, J9 | ✅ | 9dff323·a61afbc·66039c6·8139247·fe8d748·0153464 |
| **J13 FTDI latency timer(USB 직결만 해당, 기본 16ms 버퍼링)** | ⬜ 미적용 | `serial/posix.rs` 에 IOSSDATALAT 부재 확인 |
| **J4 sendStep deadline 타이밍**(고정 sleep → `Task.sleep(until:)`) | ⬜ 미적용 | 레이턴시 문서 §5.6 설계만 존재 |

### 1.4 낙상·머리·FSR

- 낙상: `WalkLabSession+AutoRecovery.swift` — accelY 30-샘플 이동평균 10Hz 감지 + getup
  (motion page 10/11) 재생. 게이트 5종(자동복구 ON·bus 연결·DXL 전원·크래들 아님·과열 60°C/
  저전압 9.5V). **직결 모드에 이미 존재** — 콕핏 기본값/HUD 결선이 미흡할 뿐(D3).
- 머리: SLO p95 ≤70ms(레이턴시 문서 §3 D 경로), 50ms 스로틀 + coalesce — 완료.
- FSR: 직결 모드 **미사용**. 버스 READ(ID 111/112)로 가능하나 폴링 미구현.

## 2. 온보드 vs 직결 — 구조 비교

| | 온보드(SSH/brokerage) | 직결(bus) 현재 | 직결 D-완료 후 |
|---|---|---|---|
| 게이트 생성 | 로봇 Walking 125Hz 사인 | Mac 6키프레임/사이클(~10Hz 등가) | Mac 연속 샘플링 **50Hz** |
| 밸런스 | 자이로 P @125Hz | @~10Hz 적용(센서 20Hz) | @50Hz 적용(센서 50Hz) |
| 명령 전송 | SSH/UDP(O1 후 20-30Hz) | SYNC_WRITE ~0.5ms 직접 | 동일 |
| E-STOP | 파일 폴 100ms(O1 후 ~5ms) | bus 직접+락 선점 ~50ms | 동일(≤60ms 검증) |
| 낙상 복구 | 로봇 auto-getup | Mac AutoRecovery(수동 게이트) | 콕핏 자동 결선 |
| RT 보장 | LinuxMotionTimer SCHED_RR | macOS 스케줄러(지터 미측정) | deadline 스케줄+지터 계측 |
| 취약점 | WiFi stall, 래칭+폴 지연 | 게이트 해상도, USB FTDI 16ms | 케이블 의존(시연 동선 제약) |

직결의 본질적 강점: 모션 연출·티칭과 같은 관절 단위 경로를 공유하므로 **보행↔포즈↔모션 재생을
한 세션에서 섞는 데모**가 가능하고, Mac 연산력으로 게이트를 임의로 실험할 수 있다(이 점이
`walking-algorithm-design.md` Phase A–F 의 실전 무대이기도 하다).

## 3. 갭 분석 (로봇공학·ROS 방법론)

| # | 갭 | 현재 | 관행 대조 | 영향 |
|---|---|---|---|---|
| DG1 | 게이트 해상도 | 6 waypoint/사이클, 서보 내부 P 가 사이를 점프 | JointTrajectory 류 조밀 waypoint 스트리밍 | 계단형 궤적 → 진동·미끄럼, 보정 주입 기회 ~10Hz |
| DG2 | 보정 위상 지연 | 센서 20Hz·적용 ~10Hz | 피드백은 가능한 최고 주기로(125Hz 온보드 대비 1/12) | 외란 회복력 저하 |
| DG3 | 래칭 의미론 비일관 | phase 재읽기(정의 모호) vs 온보드 PHASE1/3 래칭 | 동일 명령→동일 거동(트윈 일관성) | 모드 간 조종감 상이, 시뮬 정합 깨짐 |
| DG4 | USB FTDI 16ms | J13 미적용 | 시리얼 latency 1ms 설정 | USB 직결에서 read 왕복 +16ms — IMU 50Hz 불가 |
| DG5 | 타이밍 지터 | `Task.sleep` 누적(J4 미적용), 지터 미계측 | deadline 스케줄링+지터 SLO | cadence 흔들림 → 보행 품질 저하 |
| DG6 | FSR/관절 상태 미피드백 | write-only 핫루프 | 접지/CoP 관측, 지지다각형 | 안정 여유 관측 불가(3D 오버레이 공백) |
| DG7 | 데모 운영 수동 | 모드 전환·ARM·복구가 산재한 수동 단계 | 시연 시나리오의 단일 진입(lifecycle) | 시연 중 조작 부담·실수 여지 |

## 4. 업그레이드 로드맵 — 4 Wave

공통 원칙: 직렬화 락(v1.11)·E-STOP 무스로틀·크래들 게이트 등 레이턴시 문서 §7 불변식 승계.
모든 신규 주기/게인은 상수 1곳 집결(튜닝 단일 지점).

### Wave D0 — 잔여 결착 + 계측 (S)

1. **J4 deadline 타이밍**: `sendStep` 의 고정 sleep 을 `nextStepAt = max(nextStepAt+stepMs, now)`
   + `Task.sleep(until:)` 로 — 레이턴시 문서 §5.6 설계 그대로. write 소요·MainActor 홉이
   자동 보상. (D1 의 20ms 스텝은 이것 없이는 지터가 주기와 같은 자릿수가 된다 — 선행 필수.)
2. **J13 FTDI**: `serial/posix.rs` 에 macOS `IOSSDATALAT` ioctl(1ms, 미지원 어댑터 no-op) —
   USB 직결에서 IMU 50Hz 의 전제. TCP5530 경로는 무관.
3. **계측**: PilotLatencyTracer(레이턴시 문서 §6)에 bus 경로 마크 추가 — `stepScheduled →
   syncWriteDone → imuRead` + step 지터 히스토그램. HUD 디버그 1Hz 노출.
- (d) 검증: 10분 보행에서 step 지터 p95 ≤ ±10ms(현행 측정→개선 확인), IMU read 왕복
  USB p95 ≤ 3ms(J13 후). (e) 난이도 S / 리스크 낮음.

### Wave D1 — 50Hz 연속 스트리밍 + 래칭 의미론 정렬 (M) — "빠릿+부드러움"의 본체

1. **연속 샘플러**: `makeContinuousPlan` 의 6 키프레임 배열 경로와 별도로,
   `runContinuousWalk` 에 **시간 기반 모드** 신설 — 매 step 에서
   `robotisWalkingApproxPose(timeMs: tCycle)` 을 직접 평가, step 간격 **20ms 고정(50Hz)**,
   `tCycle = (now − cycleStart) mod period`. 같은 함수의 밀도만 올리므로 궤적 자체는 동일.
   `changedJoints` 필터 유지(20ms 간격이면 변화 관절 수가 줄어 패킷이 오히려 작아짐).
2. **버스 예산**(1Mbps, 바이트 12µs — `07-servo-config.md:244`):

   | 트래픽 | 크기 | 시간 | 50Hz 점유 |
   |---|---|---|---|
   | SYNC_WRITE 12관절(pos) | 8+12×3 = 44B | 0.53ms | 2.7% |
   | IMU burst READ(왕복) | TX 8B + RX 18B | 0.31ms | 1.6% |
   | liveness PING(시간 기준 1Hz 로 변경) | 14B | 0.17ms | 0.02% |
   | **합** | | | **~4.3%** — 여유 |

3. **래칭 의미론 정렬(DG3)**: tuning 을 래치 객체로 감싸 **X/Y/A 진폭은 스윙 중간 경계,
   period 는 DSP 경계에서만** 채택 — Walking.cpp(391·415행) 및 온보드 O2 와 동일 규칙.
   콕핏 EMA 완화(α 0.25→0.5)는 온보드 O2 와 동일 커밋으로(양 모드 동시 적용).
   슬루 한계도 O2 표와 동일 상수 공유(`WalkMotionLibrary` 에 단일 정의).
4. **phase floor 재정의**: `playMs ≥ 80ms` 하한은 키프레임 모드 전용으로 남기고, 시간 기반
   모드는 **period ≥ 440ms 클램프**(기존 cockpit 범위)로 대체 — 의미가 명확해짐.
- (a) 변경: `WalkLabSession+WalkCycleEngine.swift`(시간 기반 루프), `WalkMotionLibrary.swift`
  (래치 객체+상수), 기능 플래그 `df.walklab.denseStreaming`(기본 off → 검증 후 on).
- (d) 검증: ① **동치 테스트** — 같은 tuning·같은 시각에서 키프레임 모드의 6 포즈와 시간 기반
  모드의 해당 시각 포즈가 일치(회귀 0 증명), ② 래칭 단위 테스트(경계 전 변경이 경계 후
  반영), ③ 실기: 직진 5m yaw 드리프트·발 미끄럼 전후 비교, 서보 온도 10분 추이(50Hz 부하 확인).
- (e) 난이도 M / 리스크 중 — 최대 리스크는 MX-28 가 20ms 간격 목표를 따라가며 생기는 진동
  (P=32 고정). 완화: 실기에서 진동 시 step 30ms(33Hz)로 후퇴 가능하게 상수화.

### Wave D2 — 밸런스 50Hz + FSR 관측 (M) — "안정"의 본체

1. **보정 주입률 상향**: IMU 폴을 보행 중 50ms→**20ms**(`ConnectionStore.swift:2700` 의 동적
   증속 분기 확장 — 버스 예산 §4-D1 표 내), `applyBalanceCorrectionIfEnabled` 를 step(20ms)
   마다 적용 — 위상 지연 1/5. 게인은 §8.2 설계값 유지, 기존 UI 슬라이더로 튜닝.
2. **자이로 LPF**: 온보드 O3-2 와 동일 1차 LPF(fc≈15Hz)를 Swift 보정 입력에 — 50Hz 적용 시
   raw ADC 노이즈 증폭 방지. 상수 공유(온보드 패치와 같은 값).
3. **FSR 폴(관측 전용)**: 10Hz READ(ID 111/112, 왕복 2×~0.6ms = 1.2% 추가) →
   `FsrReading` 으로 3D 오버레이(`3d-viewport-enhancement.md` Wave 3)와 콕핏 HUD 에 공급.
   **제어 미개입**(접지 판정·CoP 표시만) — 제어 개입은 온보드 O3-3 실증 후 별도 판단.
4. **낙상 감지 보강**: 50Hz IMU 로 fallMonitorTick 의 감지 지연 단축(30-샘플 MA 윈도 재계산).
- (d) 검증: 크래들 → March 에서 보정 on/off 자세 분산 비교 → 기울임판 외란 회복(수동 푸시
  금지). FSR 표시값 vs 실제 접지 육안 대조. (e) 난이도 M / 리스크 중(USB 는 J13 전제).

### Wave D3 — 데모 운영 자동화 (M) — "시연 품질"

1. **원클릭 직결 데모 플로**: 연결→모드 전환(기존 툴바 스위처 재사용)→walk-ready→ARM 까지
   단일 가이드 시퀀스(체크리스트 HUD). 기존 PilotSafetyGate/ARM 로직 무변경 — 순서만 묶음.
2. **낙상 자동 복구의 콕핏 결선**: AutoRecovery 게이트의 콕핏 프로파일 기본 ON + HUD
   카운트다운("3초 후 기상")+취소 버튼. 복구 중 입력 차단은 기존 `autoRecoveryPhase` 게이트.
3. **데모 안전 프리셋**: 시연용 고정 슬롯(stride 30·side 16·turn 8·period 550, 거버너 강화) —
   매핑 프로파일 슬롯(f088628) 위에 1개 추가.
4. **헤드 룩 결합**: 스틱 헤드 조종 + 무입력 2s 시 정면 자동 복귀(기존 writeHeadPose 경유,
   50ms 스로틀 유지).
5. **HUD 계측 표시**: 스트림 Hz·step 지터·보정량 게이지(D0 tracer 소비) — 시연 중 상태 가시화.
- (d) 검증: 시연 리허설 시나리오 문서(연결→보행→낙상→자동복구→재보행) 1회 무개입 통과.
- (e) 난이도 M / 리스크 낮음(기존 부품 조립 성격).

## 5. SLO·검증 종합

| 경로 | 현재(추정) | D-완료 목표 |
|---|---|---|
| 입력→서보 write(인-페이즈 파라미터·머리) | ~100–150ms | **p95 ≤ 60ms** |
| 입력→진폭 래치 | 사이클 단위(≤600ms) | **≤ 반주기+33ms** (온보드와 동일 하한) |
| step 지터 | 미계측 | p95 ≤ ±5ms (D0 deadline 후) |
| 밸런스 루프(센서→보정 적용) | 50–117ms | **20ms** |
| E-STOP→torque-off (bus) | ~50ms (S4 적용) | 회귀 검증 p95 ≤ 60ms 유지 |
| 보행 품질 | 기준선 측정 | 직진 5m yaw 드리프트·미끄럼 D1 전후 개선 수치화 |

실기 게이트(공통): 크래들+다리 토크 해제+배터리 차단 → March → 평지 저속 → 콕핏 일상.
모든 단계 E-STOP 리허설 선행. Swift 테스트 serial 실행 전제.

## 6. 타 문서와의 분담·합류

| 주제 | 본 문서(직결) | 관련 문서 |
|---|---|---|
| 전송·계측 인프라 | D0 이 소비 | cockpit-latency-hardening §5–6 (J4·J13 은 그 설계의 집행) |
| 래칭·슬루·거버너 규칙 | D1 — 동일 상수 공유 | walklab-onboard-teleop-upgrade O2 (양 모드 패리티) |
| 게이트 엔진 장기 단일화 | D1 은 Swift 경로 우선 | walking-algorithm-design.md Phase A–F (Rust 엔진 — D1 의 시간 기반 모드가 Phase B·C 의 실전 검증대) |
| FSR/CoP 시각화 | D2 가 데이터 공급 | 3d-viewport-enhancement Wave 3 (오버레이 소비) |
| 밸런스 LPF·게인 | D2 — 상수 공유 | onboard O3-2 (동일 필터 설계) |

권장 순서: **D0 → D1 → D2 → D3**. D0 은 즉시 가능(설계 기존재), D1·D2 는 한 릴리스로 묶는
것이 검증 효율상 유리(같은 실기 세션), D3 은 독립.

## 7. 착수 가이드

```sh
make doctor && bash scripts/build-mac.sh --swift
swift test --package-path app/ui/DarwinForge          # serial 필수
cargo test -p forge-core --manifest-path app/core/Cargo.toml   # J13 변경 시
# FFI 시그니처 변경 시: make headers
```

- 핵심 진입점: `WalkLabSession+StartCycle.swift:537`(태스크 기동),
  `WalkLabSession+WalkCycleEngine.swift`(핫루프), `WalkMotionLibrary.swift:105-129`(플랜),
  `ConnectionStore.swift:2700`(IMU 동적 폴).
- 기능 플래그: `df.walklab.denseStreaming`(D1) — UserDefaults 키 신설 시 테스트 직렬 실행
  주의(CLAUDE.md).
- 실기 전 안전 수칙: 크래들 거치 + 다리 토크 해제 + 배터리 차단 스위치(CLAUDE.md).
