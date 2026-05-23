import Foundation
import ForgeCore

/// **v1.22.x (2026-05-23) — 사이클 116 (W2.10 / P0-2): god method 분할 (tick)**.
///
/// `WalkLabSession.swift:1856` 의 `tick()` (169 line) 을 phase-named internal helper
/// 들로 분해. 원본 `tick()` 은 facade 로 단순화 — 외부 API 변경 0, 호출 site 변경 0.
///
/// # 비유
///
/// 비행기 fly-by-wire 의 10Hz 메인 루프 — 6단계 servoing 체크리스트. 1. cradle 상태
/// 감시 → 2. engine 위상 진행 + 발자국 트레일 → 3. 시뮬레이션 자세 시각화 →
/// 4. 센서 폴링 + 자세 상태 평가 → 5. 안전 파이프라인 (균형/L3 tilt/L4 thermal/
/// L0 voltage) → 6. 시계열 기록. 각 단계는 매뉴얼의 한 페이지.
///
/// # 분할 정책
///
/// - **logic 보존 100%**: 분해는 refactor only. 변수 capture / side effect 순서 /
///   early return 패턴 / mutation 순서 모두 원본 그대로 유지.
/// - **helper prefix `tick` (CamelCase)**: namespace 충돌 방지 (W2.3 `swc`, W2.5 `bc`,
///   W2.6 `safetySample`, W2.7 `start` 와 일관 패턴).
/// - **`@MainActor` 격리**: 본 extension 의 모든 helper 는 `WalkLabSession` 의 actor
///   격리를 상속. simTimer 10Hz callback 의 main-thread context 보존.
///
/// # Phase 매핑 (원본 line 번호 기준)
///
/// | Helper                              | Phase                                          | 원본 lines    |
/// |-------------------------------------|------------------------------------------------|---------------|
/// | `tickEnforceCradleOnDisconnect`     | 1. bus disconnect → cradleConfirmed 해제      | 1857-1869     |
/// | `tickAdvanceEngineAndFootTrail`     | 2. engine.tick + leftFoot/rightFoot + trail   | 1871-1892     |
/// | `tickUpdateVisualPose`              | 3. sim mode simWalkingPose → visualPose       | 1894-1924     |
/// | `tickPollSensorsAndBalanceState`    | 4. IMU/temp/fall prediction + balanceState    | 1926-1936     |
/// | `tickRunSafetyPipeline`             | 5. mitigation + auto stop + L3/L4/L0          | 1938-2021     |
/// | `tickRecordSafetySample`            | 6. 시계열 sample + 이벤트 전환                | 2023-2024     |
///
/// # 격상 (사이클 116)
///
/// - `lastSeenBusConnected` (private → internal): `tickEnforceCradleOnDisconnect` 가
///   read/write — bus 연결 상태 history (single cycle).
///
/// # 회귀
///
/// 1852 tests 회귀 0 — 외부 API 변경 0. `tick()` 호출 site (W2.7
/// `startScheduleTickLoop` 의 simTimer closure) 동일.
///
/// # 성능
///
/// 10Hz (100ms) tick — helper dispatch 비용 nanosecond 단위, 0.1ms 안전 마진 대비
/// 영향 무시 가능. W2.5 `applyBalanceCorrectionIfEnabled` 분해와 동일 패턴.
///
/// # 순서 보존 (CRITICAL)
///
/// 1. `lastSeenBusConnected` 갱신 — 이후 모든 connection state 판정 기준.
/// 2. `engine.tick(dtMs:)` — `foot` 값을 footTrail / visualPose 가 read.
/// 3. `updateImuFromRealOrSim()` — `imuRollDeg/imuPitchDeg` 가 balanceState /
///    L3 hard gate / appendSessionSampleIfLogging 의 read source.
/// 4. `updateMotorTempFromRealOrSim()` — `maxMotorTemp` 가 thermal gate 의 read source.
/// 5. `appendSessionSampleIfLogging()` — IMU 갱신 후 호출 (로깅 sample 의 freshness 보장).
/// 6. `autoFallPrevention` 분기 후 `applyBalanceMitigation()` — engine.setCommand 가
///    L3/L4/L0 emergency 보다 먼저 실행되어 정상 보행의 corrective 보정 우선.
/// 7. `recordSafetySampleAndEvents()` — 마지막. 모든 state mutation 완료 후 sample 캡처.
extension WalkLabSession {

    // MARK: - Phase 1 — Cradle Disconnect Enforcement

    /// 2026-05-17 안전 강화: bus disconnect 감지 시 cradleConfirmed 자동 해제.
    ///
    /// 종전: bus 끊김 → 재연결 후 사용자 명시 cradle 거치 확인 없이 보행 시작 가능
    /// → wake / disconnect 사이 robot 자세 변화 인지 못 한 채 송출 = 낙상 위험.
    ///
    /// 신규: 한 번이라도 bus = nil 관찰되면 cradleConfirmed 자동 false. 사용자가
    /// "정비 스탠드에 거치됨" 토글 다시 체크해야 보행 가능.
    ///
    /// **순서**: tick() 진입 직후 — 이후 모든 helper 가 lastSeenBusConnected 의
    /// 갱신된 값을 신뢰할 수 있도록.
    internal func tickEnforceCradleOnDisconnect() {
        let currentlyConnected = store?.bus != nil
        if lastSeenBusConnected && !currentlyConnected {
            // 연결 끊김 감지 — cradleConfirmed 강제 해제 + 이벤트 로그.
            if cradleConfirmed {
                cradleConfirmed = false
                logSafetyEvent(
                    kind: .preflightFailure,
                    message: "로봇 연결 끊김 — 거치 확인 자동 해제 (재연결 후 다시 확인 필요)"
                )
            }
        }
        lastSeenBusConnected = currentlyConnected
    }

    // MARK: - Phase 2 — Engine Tick + Foot Trail

    /// engine 위상을 dtMs=tickDtSec*1000 만큼 진행 + leftFoot/rightFoot/elapsedMs/
    /// phaseLabel 갱신 + footTrail/footTrailLefts append (200 sample 상한).
    ///
    /// **v1.14.8.2 (2026-05-21) — code-reviewer CRITICAL fix**:
    /// 종전 hard-coded 50ms. v1.14.8 Fix #2 가 tickDtSec 50→100ms 로 바꾼 후에도
    /// 이 값이 그대로 남아 engine 내부 phase 가 wall-clock 의 절반 속도로 진행 →
    /// 모든 preset 의 시각 보행 cadence 50% slow 회귀.
    /// 신규: tickDtSec 와 정합 — 단일 source of truth.
    ///
    /// **v1.14.8.1 (2026-05-21) perf**: footTrailLefts 캐시 parallel update.
    /// RobotScene3D 가 직접 read — body 마다 .map alloc 차단.
    ///
    /// 반환값 `foot` 는 다음 phase (tickUpdateVisualPose) 의 elapsedMs read 가
    /// 동일 cycle 의 갱신값을 사용하도록 self.elapsedMs 에 이미 반영됨.
    internal func tickAdvanceEngineAndFootTrail() {
        let foot = engine.tick(dtMs: UInt32(tickDtSec * 1000))
        leftFoot = foot.leftXYZ
        rightFoot = foot.rightXYZ
        elapsedMs = UInt32(foot.elapsedMs)
        phaseLabel = foot.phase.label

        // foot trail 누적
        footTrail.append(FootTrailPoint(
            t: Date(),
            left: foot.leftXYZ,
            right: foot.rightXYZ
        ))
        if footTrail.count > 200 { footTrail.removeFirst(footTrail.count - 200) }
        footTrailLefts.append(foot.leftXYZ)
        if footTrailLefts.count > 200 { footTrailLefts.removeFirst(footTrailLefts.count - 200) }
    }

    // MARK: - Phase 3 — Visual Pose (Sim Mode)

    /// sim mode 에서 3D 모델 보행 시각화 (Phase G11/G12).
    ///
    /// **Phase G11 (2026-05-15)**: 실 로봇 연결 안 됐을 때 (또는 ARM 안 된 상태)
    /// `isRobotWalking == false` 라 `runContinuousWalk` 의 onPose 가 호출되지 않음.
    /// sim tick 으로 phase 보간 후 visualPose 갱신해서 모델이 보행 따라 움직이도록.
    ///
    /// 실 로봇 송출 중 (`isRobotWalking == true`) 이면 onPose 가 권한 — sim 덮어쓰기 회피.
    ///
    /// **Phase G12 (Codex audit 4th pass, 2026-05-15)**: 이전 sim mode 가
    /// `(strideMm: 25, sideMm: 0, turnDeg: 0)` 하드코드 → preset 무시 → 모든 preset 이
    /// 동일 보행 자세로 시각화됐던 P0 버그. `defaultTuning(for: current)` 로 정정해서
    /// march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight 가 각각 다른 보행 자세.
    ///
    /// **Stage 4 (v1.1 fall prevention)**: sim mode 에서도 corrector 적용 →
    /// 시각화에 보정 효과 미리보기 (실 robot 미연결 상태에서도 검증).
    internal func tickUpdateVisualPose() {
        if !isRobotWalking, current != .idle {
            let effectiveTuning: WalkMotionLibrary.AdvancedTuning = advanced
                ? WalkMotionLibrary.AdvancedTuning(
                    strideMm: strideMm, sideMm: sideMm, turnDeg: turnDeg,
                    periodMs: customPeriodMs, footHeightMm: footHeightMm, balanceGain: balanceGain
                  )
                : WalkMotionLibrary.defaultTuning(for: current)
            let period = effectiveTuning.periodMs
            let phaseFraction = (Double(elapsedMs).truncatingRemainder(dividingBy: period)) / period
            let phasedTimeMs = phaseFraction * period
            if let pose = WalkMotionLibrary.simWalkingPose(timeMs: phasedTimeMs, tuning: effectiveTuning) {
                visualPose = applyBalanceCorrectionIfEnabled(to: pose)
            }
        } else if current == .idle, !isRobotWalking {
            // idle 상태 → walkReady 로 부드럽게 복귀 (sim).
            visualPose = .walkReady
        }
    }

    // MARK: - Phase 4 — Sensor Poll + Balance State

    /// IMU/모터 온도/낙상 예측 갱신 + balanceState 분류 + 세션 sample 로깅.
    ///
    /// **Stage 2 (v1.1 fall prevention)**: 다단계 임계 분기.
    /// `autoFallPrevention = false` 면 emergency (30°) 만 작동 — 기존 동작 보존.
    ///
    /// **v1.9 (사용자 요청)**: 보행 중 매 tick 데이터 logging.
    ///
    /// **순서 의존성**:
    /// - `updateImuFromRealOrSim()` 이 `imuRollDeg/imuPitchDeg` 갱신 →
    ///   `balanceState` 계산이 신선한 값을 read.
    /// - `appendSessionSampleIfLogging()` 은 IMU 갱신 후 호출되어야 sample 의
    ///   freshness 보장.
    internal func tickPollSensorsAndBalanceState() {
        updateImuFromRealOrSim()
        updateMotorTempFromRealOrSim()
        updateFallPrediction()

        let maxTilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        balanceState = BalanceState.from(maxTilt: maxTilt)

        appendSessionSampleIfLogging()
    }

    // MARK: - Phase 5 — Safety Pipeline (Mitigation + L3/L4/L0)

    /// 안전 파이프라인: balance mitigation → 자동 정지 (시간 초과) → L3 tilt →
    /// L4 thermal → L0 voltage. 각 layer 는 독립적으로 emergencyStop 트리거 가능.
    ///
    /// **2026-05-17 v1.7**: IMU plausibility 통과 시만 L3 hard gate + predictor 작동.
    /// `.looksValid16Bit` (enum 이름 보존, 의미는 "1g 중력 정상 감지") 또는 sim 모드
    /// 또는 아직 unknown 일 때 trust.
    ///
    /// **L3 hysteresis (v1.8, 2026-05-17)**: 30° → 50° (ROBOTIS FALLEN 수준).
    /// 한 sample 만 충족해도 즉시 trigger 던 종전 → 3 연속 sample (600ms @ 5Hz)
    /// 충족 시만 trigger. 정상 보행의 순간적 spike 노이즈 흡수.
    ///
    /// **v1.11.25 audit-D** (L4): 60°C 도달 시점부터 50°C 미만 도달까지 모든 preset
    /// 차단. 종전: banner "닫기" 즉시 풀림 → 1초 후 재시작 가능.
    ///
    /// **L0 voltage (2026-05-17)**: 종전 단일 sample < 9.5V 가 transient droop
    /// (보행 시작 시 모터 일제 활성화) 에 false-positive trigger. 연속 N tick 동안
    /// 지속 시만 trigger. ROBOTIS-OP2 LiPo 11.1V nominal, 10.5V cutoff. 9.5V 이하 =
    /// critical (모터 brown-out 위험, 배터리 영구 손상).
    ///
    /// **v1.8 (2026-05-17) 정정**: predictor emergency 비활성화 — 사용자 보고
    /// "조금만 기울어도 중단". score 60 임계가 정상 보행 (5-15° 흔들림) 에서도
    /// 자주 트리거. 진짜 fall (실제 30°+ 누적) 은 L3 hard gate (50°) 가 잡음.
    /// 향후 score 가중치 보정 후 재활성 — 현재는 정보용 표시만.
    internal func tickRunSafetyPipeline() {
        let imuTrustedForEmergency = (imuScaleSuspicion == .looksValid16Bit
                                      || imuScaleSuspicion == .unknown  // 아직 진단 X — 보수적 trust
                                      || imuSource == .sim)             // sim 모드는 항상 신뢰

        if autoFallPrevention {
            applyBalanceMitigation()
        }

        // 자동 stop (시간 초과)
        if let start = startTime {
            let secs = Date().timeIntervalSince(start)
            if current.maxDurationSec > 0 && Int(secs) >= current.maxDurationSec {
                stop()
            }
        }

        // L3 — 균형 손실 (실 IMU 또는 sim 둘 다 동일 임계).
        let l3MaxTilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        if imuTrustedForEmergency, l3MaxTilt >= 50 {
            l3HardGateConsecutiveSamples += 1
        } else {
            l3HardGateConsecutiveSamples = 0
        }
        if l3HardGateConsecutiveSamples >= 3 {
            balanceLost = true
            logSafetyEvent(
                kind: .emergencyTriggered,
                message: String(format: "L3 hard gate — tilt R%+.1f° P%+.1f° 3샘플 연속 ≥50° → 정지",
                                imuRollDeg, imuPitchDeg)
            )
            emergencyStop(trigger: .balanceLostL3)
            l3HardGateConsecutiveSamples = 0
        }

        // L4 — 온도 임계
        if maxMotorTemp >= 60 {
            thermalAlarm = true
            // cool-down gate 활성. 60°C 도달 시점부터 50°C 미만 도달까지 모든 preset 차단.
            thermalCoolDownRequired = true
            logSafetyEvent(
                kind: .thermalAlarm,
                message: String(format: "모터 %.1f°C — 60°C 임계 도달 → 정지 + cool-down %.0f°C 대기",
                                maxMotorTemp, Self.thermalCooldownExitTemp)
            )
            emergencyStop(trigger: .thermalOverheat)
        } else if thermalCoolDownRequired && maxMotorTemp < Self.thermalCooldownExitTemp {
            // cool-down 완료. 50°C 미만 도달 시 gate 해제.
            thermalCoolDownRequired = false
            logSafetyEvent(
                kind: .thermalAlarm,
                message: String(format: "모터 %.1f°C — cool-down 완료 (%.0f°C 미만)",
                                maxMotorTemp, Self.thermalCooldownExitTemp)
            )
        }

        // L0 voltage layer (under-volt 자동 정지).
        updateVoltageDroopTracking()
        if voltageDroopConsecutiveSamples >= Self.voltageDroopTriggerCount,
           let v = store?.lastTelemetry?.board?.voltageVolts {
            // v1.11.25 audit log-D — voltageDroop dedicated case (kind 재사용 제거).
            logSafetyEvent(
                kind: .voltageDroop,
                message: String(format: "L0 배터리 %.1fV — %d 연속 sample critical → 정지",
                                v, Self.voltageDroopTriggerCount)
            )
            emergencyStop(trigger: .voltageDroop)
            voltageDroopConsecutiveSamples = 0   // 리셋
        }
    }

    // MARK: - Phase 6 — Safety Sample Recording

    /// Monitoring dashboard — 시계열 sample 기록 + 이벤트 전환 감지.
    /// `recordSafetySampleAndEvents()` (WalkLabSession+SafetySampling.swift) 위임.
    ///
    /// **순서**: tick() 의 마지막 — 모든 state mutation (engine/foot/visual/IMU/
    /// balance/safety) 완료 후 sample 캡처해야 dashboard 가 일관된 snapshot 관찰.
    internal func tickRecordSafetySample() {
        recordSafetySampleAndEvents()
    }
}
