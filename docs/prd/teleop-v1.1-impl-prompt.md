# Sprint 16 — Remote Pilot v1.1 구현 요청 프롬프트

> **목표**: `PilotFeatureFlags.active = .v1_1` 활성화 조건 전부 충족.
> IMU 텔레메트리 파이프라인 + 인공수평선 HUD + 자동 낙상 복구 + 머리 추적 PID.
> 사전 조건: Sprint 15 v1.0 PR #4 머지 완료 + 342 Rust / ≥70 Swift 테스트 GREEN.

---

## 구현 요청 프롬프트

```
다음 명세대로 DarwinForge 앱에 Remote Pilot v1.1 (Sprint 16) 을 구현해 줘.
전체 설계: docs/prd/teleop-v1.md (v3). 본 단계의 추가 가치:
"IMU roll/pitch 실시간 HUD + 낙상 자동 복구 + 머리 추적 PID 3개 기능 동시 활성".

── 핵심 원칙 ─────────────────────────────────────────────────────────────────

1. ComplementaryFilter (forge-core/src/walk/imu.rs) 를 그대로 재사용 — 재구현 금지.
2. motion_4096.bin 데이터는 단 1 byte 도 수정 금지 (byte-identical).
3. 낙상 복구 자동 트리거는 사용자 토글 OFF 시 절대 작동 금지.
4. emergencyStop (⌘⇧.) 은 낙상 복구 재생 중에도 즉시 취소 — 예외 없음.
5. HeadTracker PID 는 모터 명령 전에 JointLimits 체크 필수 (HeadPan ±90°, HeadTilt ±45°).
6. 기존 342 Rust + 70 Swift 테스트 회귀 0.

── 배경: 이미 존재하는 것 (건드리지 말 것) ───────────────────────────────────

- forge-core/src/walk/imu.rs — ComplementaryFilter + ImuSample (테스트 2개)
- cm_register: GYRO_{Z,Y,X} = {38,40,42}, ACCEL_{X,Y,Z} = {44,46,48}
- JointId::HeadPan = 19, JointId::HeadTilt = 20 (Official 매핑 그대로)
- JointLimits::for_joint(HeadPan) = ±90°, for_joint(HeadTilt) = ±45°
- PilotFeatureFlags — imuTelemetry / autoRecovery / headTracking { active >= .v1_1 }
- PilotHudStrip — imuHorizonWidget + autoRecoveryToggle (.comingSoon 제거 대상)
- MotionCatalog — page 10 "앞 일어서기" (Safe), page 11 "뒤 일어서기" (Safe)
- TeleopChannel.emergencyStop() — 항상 작동, 이 함수를 낙상 복구에서도 재사용

── Day 1: forge-core — CmController::read_imu() ────────────────────────────

1. forge-core/src/controller/cm.rs 에 추가

   pub struct ImuRaw {
       pub gyro:  [i16; 3],   // gyro  [Z, Y, X] raw ADC, center=512
       pub accel: [i16; 3],   // accel [X, Y, Z] raw ADC, center=512
   }

   impl ImuRaw {
       /// ADC raw → ImuSample (SI 단위).
       /// ROBOTIS CM-730 스펙:
       ///   Gyro  ±500 dps / 512 count → rad/s: (raw-512)*(500/512)*(π/180)
       ///   Accel ±4g   / 512 count → m/s²: (raw-512)*(4*9.81/512)
       pub fn to_sample(&self) -> ImuSample { ... }
   }

   impl<'a, P: SerialPort> CmController<'a, P> {
       /// 6개 레지스터 2-byte × 6 = BULK_READ 1회 → ImuRaw → ImuSample.
       /// 레지스터 시작: GYRO_Z (38), 연속 12 byte.
       pub fn read_imu(&mut self) -> Result<ImuSample> { ... }
   }

   단위 테스트 4개:
   - raw_zero_gives_zero_imu — (raw=512) → gyro/accel 모두 0 근사
   - gyro_scale_500dps — raw=1023 → gyro ≈ 8.56 rad/s
   - accel_scale_4g   — raw=1023 → accel ≈ 76.6 m/s²  (1023-512)*4*9.81/512
   - read_imu_integration — MockBus 로 레지스터 값 주입 → ImuSample 정합 확인

2. forge-core/src/walk/imu.rs — 변경 없음. (이미 존재)

── Day 2: forge-ffi — IMU FFI 공개 ─────────────────────────────────────────

3. forge-ffi/src/lib.rs 에 추가

   #[repr(C)]
   pub struct FcImuSample {
       pub gyro_x: f64, pub gyro_y: f64, pub gyro_z: f64,   // rad/s
       pub accel_x: f64, pub accel_y: f64, pub accel_z: f64, // m/s²
   }

   #[repr(C)]
   pub struct FcImuAttitude {
       pub roll:  f64,  // rad
       pub pitch: f64,  // rad
   }

   FcBus 에 추가:
     imu_filter: ComplementaryFilter,
     imu_last_tick: std::time::Instant,

   /// 보드에서 즉시 1샘플 읽기.
   pub unsafe extern "C" fn fc_imu_read(
       handle: *mut FcBus,
       out: *mut FcImuSample,
   ) -> c_int

   /// 내장 ComplementaryFilter 를 한 step 갱신 + 현재 roll/pitch 반환.
   /// dt 는 마지막 호출 이후 경과 시간 (내부 Instant 사용).
   pub unsafe extern "C" fn fc_imu_get_attitude(
       handle: *mut FcBus,
       out: *mut FcImuAttitude,
   ) -> c_int

   cbindgen 헤더 자동 재생성 (build.rs 변경 없음).

   FFI 통합 테스트 3개:
   - null_handle_returns_error
   - attitude_zeroed_at_rest — MockBus 레지스터 512 고정 → roll/pitch ≈ 0
   - attitude_accumulates_gyro — 10 step gyro_x=1 rad/s, dt=10ms → roll ≈ 0.1 rad

── Day 3: Swift — IMU 텔레메트리 파이프라인 ─────────────────────────────────

4. ForgeCore/ImuTelemetry.swift (신규)

   public struct ImuAttitude: Sendable, Equatable {
       public let roll:  Double   // rad, CCW 양수
       public let pitch: Double   // rad, 앞숙임 양수
       public let timestamp: Date
   }

   public actor ImuPoller {
       public func start(bus: BusActor) -> AsyncStream<ImuAttitude>
       // 20 ms 폴링 (50 Hz). fc_imu_get_attitude 호출. BusActor.bus 위임.
       public func stop()
   }

   BusActor.swift 에 추가:
     public func imuGetAttitude() throws -> ImuAttitude

   단위 테스트 2개:
   - attitude_is_equatable
   - attitude_timestamp_advances

5. ConnectionStore.swift 에 추가 (@Published)

   @Published public private(set) var lastImu: ImuAttitude? = nil
   @Published public private(set) var rollHistory:  [Double] = []   // 최대 100개
   @Published public private(set) var pitchHistory: [Double] = []

   imuPoller: ImuPoller (lazy init, bus 연결 후 start)
   // 기존 LiveTelemetry loop 와 별도 Task (imuLoop)
   // bus == nil 이면 lastImu = nil

   ConnectionStore 기존 API 변경 없음 — 추가만.

   단위 테스트 2개:
   - imu_published_after_start
   - imu_nil_on_disconnect

── Day 4: Swift — PilotHudStrip 실 구현 ────────────────────────────────────

6. Remote/ArtificialHorizon.swift (신규) — 인공수평선 Canvas 컴포넌트

   struct ArtificialHorizon: View {
       let roll:  Double   // rad
       let pitch: Double   // rad
       var body: some View {
           Canvas { ... }
           // 40×20 pt 뷰.
           // 지평선 라인: roll 각도로 회전, pitch 로 상하 이동 (±10pt/rad 정도).
           // 하늘(파란색 반), 땅(갈색 반) + 중앙 십자선.
           // pitch clip: ±0.52 rad (30°) 내에서만 이동.
       }
   }

7. PilotHudStrip.swift 수정

   - `imuHorizonWidget` — `.comingSoon(...)` 제거, ArtificialHorizon(roll:pitch:) 로 교체
     - store.lastImu 가 nil 이면 기존 placeholder 유지 (+ 희미한 "연결 안 됨" 텍스트)
   - `autoRecoveryToggle` — `.comingSoon(...)` 제거, 실 토글 연결
     - @State private var autoRecovery: Bool = false
     - FallRecoveryCoordinator.shared.enabled = autoRecovery

   조건부 활성화:
     if flags.imuTelemetry { /* 실 위젯 */ } else { /* comingSoon 유지 */ }

── Day 5: Swift — FallRecoveryCoordinator ──────────────────────────────────

8. Remote/FallRecoveryCoordinator.swift (신규)

   /// 낙상 감지 → 자동 복구 모션 트리거.
   @MainActor
   public final class FallRecoveryCoordinator: ObservableObject {
       public static let shared = FallRecoveryCoordinator()

       @Published public var enabled: Bool = false
       @Published public var state: RecoveryState = .normal

       public enum RecoveryState {
           case normal
           case detected(direction: FallDirection)
           case recovering(slot: UInt8)
       }

       public enum FallDirection { case forward, backward, left, right }

       // 임계값 (ROBOTIS walking_controller 참고)
       private let pitchThreshold = 0.52  // ~30° — 앞/뒤 낙상
       private let rollThreshold  = 0.52  // ~30° — 좌/우 낙상

       public func update(attitude: ImuAttitude, channel: TeleopChannel) async
       // - enabled == false → 즉시 리턴
       // - state == .recovering → 리턴 (재진입 방지)
       // - |pitch| > pitchThreshold → forward (pitch>0) / backward
       //   → page 10 (앞 일어서기) / page 11 (뒤 일어서기) 선택
       // - |roll| > rollThreshold → 더 기울어진 방향으로 page 11 선택 (보수적)
       // - await channel.sendMotion(slot: ..., confirmRisk: false)
       // - state 전이: .detected → .recovering → .normal (모션 완료 후)
   }

   RemotePilotView 또는 TeleopChannel 에서 store.lastImu sink:
     .onReceive(store.$lastImu) { imu in
         guard let imu else { return }
         Task { await coordinator.update(attitude: imu, channel: channel) }
     }

   단위 테스트 5개:
   - disabled_coordinator_ignores_fall
   - forward_fall_triggers_page_10  — pitch=0.6 → slot 10
   - backward_fall_triggers_page_11 — pitch=-0.6 → slot 11
   - lateral_fall_triggers_page_11  — roll=0.6 → slot 11 (보수적)
   - no_reentry_during_recovery     — recovering 중 새 imu → 재진입 없음

── Day 6: Swift — HeadTracker PID ──────────────────────────────────────────

9. Remote/HeadTracker.swift (신규)

   /// 목표 머리 방향 → JointId.HeadPan / HeadTilt 모터 명령.
   @MainActor
   public final class HeadTracker: ObservableObject {
       @Published public var enabled: Bool = false
       @Published public var targetPan:  Double = 0.0  // 도
       @Published public var targetTilt: Double = 0.0  // 도

       // PID 게인 초기값 (실 robot 튜닝 전 보수 설정)
       var kp: Double = 8.0   // 비례
       var ki: Double = 0.05  // 적분
       var kd: Double = 1.5   // 미분
       var integralClamp: Double = 20.0  // 와인드업 방지

       private var prevErrPan:  Double = 0
       private var prevErrTilt: Double = 0
       private var integralPan:  Double = 0
       private var integralTilt: Double = 0
       private var lastTick: Date = Date()

       // dt 기반 PID 1 step. JointLimits 체크 후 BusActor 발행.
       public func tick(bus: BusActor?) async
       // - enabled == false → 리턴
       // - dt = 최소 8ms, 최대 500ms (클립)
       // - output_pan  = kp*err + ki*integral + kd*derivative
       // - output_tilt = ...
       // - JointLimits 체크: HeadPan ±90°, HeadTilt ±45° 초과 시 클램프
       // - bus?.setJoint(HeadPan, raw: ...) // JointController 변환 사용
   }

   v1.1 UI 에서 headTracking 활성화 방법:
   - PilotDpad 에 머리 방향 조이스틱 영역 추가 (우상단 20×20pt 미니 패드):
     - 드래그 delta → targetPan / targetTilt 갱신
     - 릴리즈 → target 천천히 0° 으로 복귀 (spring, 0.8s)
   - 기존 dpad 레이아웃 변경 최소 (머리 미니패드만 추가)
   - flags.headTracking 이 false 이면 미니패드 숨김

   단위 테스트 4개:
   - pid_zero_error_zero_output
   - pid_proportional_response — err=10° → output ≈ kp*10
   - clamp_head_pan_to_limits  — target=100° → 클램프 90°
   - integral_windup_clamp     — 100 tick 누적 후 |integral| <= integralClamp

── Day 7: 통합 + 회귀 확인 ─────────────────────────────────────────────────

10. RemotePilotView.swift 에 v1.1 연결

    @StateObject private var coordinator = FallRecoveryCoordinator.shared
    @StateObject private var headTracker = HeadTracker()

    // IMU 수신 → coordinator 업데이트
    .onReceive(store.$lastImu.compactMap { $0 }) { imu in
        Task { await coordinator.update(attitude: imu, channel: channel) }
    }

    // HeadTracker 주기 tick (60fps timer 또는 IMU 수신마다)
    .onReceive(store.$lastImu.compactMap { $0 }) { _ in
        Task { await headTracker.tick(bus: store.busActor) }
    }

    // v1.1 기능 플래그 적용
    let flags = PilotFeatureFlags(active: .v1_1)
    // imuHorizonWidget, autoRecoveryToggle, headMiniPad → 활성

11. PilotFeatureFlags.swift — default 업데이트
    public static let `default` = PilotFeatureFlags(active: .v1_1)

12. 회귀 확인
    - cargo test --workspace — 342 + 신규 ≥16 = ≥358 pass, 0 failed
    - swift test — 70 + 신규 ≥16 = ≥86 pass
    - cargo clippy / fmt GREEN
    - swift build Universal GREEN

── HIL 시나리오 (실기기, 크래들 필수) ────────────────────────────────────────

13. 시나리오 5건:
    1. ARM → HUD 인공수평선이 roll/pitch 변화 표시 (수동으로 기울이기)
    2. 로봇 앞으로 기울임 (30°+) + 자동복구 ON → page 10 자동 재생
    3. 로봇 뒤로 기울임 (30°+) + 자동복구 ON → page 11 자동 재생
    4. 복구 재생 중 ⌘⇧. → 즉시 토크 OFF (복구 중단)
    5. 머리 미니패드 드래그 → HeadPan/Tilt 모터 실 추적
    각 시나리오 결과 docs/handoff/teleop-v1.1-hil.md 에 캡처

── 완료 기준 ──────────────────────────────────────────────────────────────────

✓ cargo test --workspace ≥ 358 pass
✓ swift build Universal 성공, swift test ≥ 86 pass
✓ PilotFeatureFlags.default = .v1_1 (comingSoon 배지 2개 사라짐)
✓ store.lastImu 폴링 20ms — HUD roll/pitch 숫자 갱신 확인 (print 로도 가능)
✓ ArtificialHorizon 지평선이 실 roll 에 비례해 회전
✓ autoRecoveryToggle 이 FallRecoveryCoordinator.enabled 와 양방향 바인딩
✓ pitch > 30° 시 올바른 page (10 / 11) 자동 트리거
✓ HeadPan ±90° / HeadTilt ±45° 초과 clamp 동작
✓ 자동복구 OFF 상태에서 낙상 감지 시 모션 송출 0
✓ 기존 v1.0 기능 (ARM / Action Bar 7 / E-Stop) 회귀 없음

── 안전 주의 ──────────────────────────────────────────────────────────────────

- emergencyStop 은 FallRecoveryCoordinator 재생 중에도 즉시 취소.
- 자동복구 재진입 방지 필수 (RecoveryState.recovering 체크).
- HeadTracker 출력은 반드시 JointLimits 클램프 후 발행.
- IMU 노이즈로 인한 오감지 방지: 임계값 초과 후 최소 300ms 지속 시에만 복구 트리거
  (debounce: 연속 15 샘플 @ 20ms = 300ms).
- 낙상 복구 페이지 (10, 11) 는 SafetyClass.Safe — confirm_risk 불필요.
- v1.1 에서도 BLOCKER C3 유지: D-pad 실 모터 송출 없음.

── 명시적 v1.1 비목표 (v1.5+ 로 미룸) ────────────────────────────────────────

- 카메라 뷰 + AVFoundation 통합 (v1.5)
- 볼 따라가기 Ball-Follow (v1.5 — 카메라 필요)
- HSV 튜닝 UI (v1.5)
- + 더 보기 9 페이지 (v1.5)
- mp3 동기 재생 (v2)
- D-pad 실 보행 IK (v2, BLOCKER C3)
- 칼만 필터 고도화 (G3 실측 후)

── 참고 파일 ──────────────────────────────────────────────────────────────────

필수:
- forge-core/src/walk/imu.rs                  — ComplementaryFilter (재사용)
- forge-core/src/controller/cm.rs             — CmController, cm_register
- forge-core/src/joint/state.rs               — JointLimits::for_joint
- forge-ffi/src/lib.rs                        — FcBus 구조체 추가 위치
- ForgeCore/Bus.swift + BusActor.swift        — Swift FFI 래퍼 추가 위치
- ForgeCore/ConnectionStore.swift             — lastImu 추가 위치
- Remote/PilotHudStrip.swift                  — imuHorizonWidget, autoRecoveryToggle
- Remote/PilotDpad.swift                      — 머리 미니패드 추가 위치
- Remote/PilotFeatureFlags.swift              — default .v1_1 로 업데이트
- docs/motion-format/page-metadata-motion4096.toml — page 10/11 duration 확인

참고:
- ROBOTIS CM-730 Control Table (gyro/accel 레지스터 spec): docs/protocols/cm730.md
- ROBOTIS OP2 walking_controller pitch threshold ≈ 0.52 rad (30°)
- ROBOTIS Official page 10: "앞 일어서기", page 11: "뒤 일어서기" (둘 다 Safe)

Sprint 16 v1.1 시작. 7일 추정. PR 본문에 HIL 시나리오 5 결과 + 신규 테스트 수 +
회귀 0 확인 + ArtificialHorizon 스크린샷 포함.

v1.5 (카메라 + Ball-Follow) 는 별도 PR.
```
