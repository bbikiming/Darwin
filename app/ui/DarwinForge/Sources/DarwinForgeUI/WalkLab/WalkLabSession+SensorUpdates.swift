import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 91: god object Phase 3 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` 의 sensor update method 묶음 (~168 line) 를 본 extension 으로
/// 이동. tick() 매 cycle 호출되는 voltage / IMU / motor thermal 의 real-or-sim 분기 +
/// sim model evolution 5개 method 가 대상.
///
/// # 비유
///
/// 큰 발전소의 "센서 계측실" 하나만 별도 부속실로 이전. 계측 카운터 (state) 는 본
/// 발전소 제어실에 잔존, 계측 절차 (method) 만 이전. 계측자는 제어실 카운터에 internal
/// access 로 갱신.
///
/// # 분할 정책
///
/// - **stored property 본체 잔존** (Swift 제약): `voltageDroopConsecutiveSamples` /
///   `l3HardGateConsecutiveSamples`. tick() 안에서 직접 read/write 도 함께 잔존.
/// - 본 cycle 에서 stored 의 `private` → `internal` 격상 — extension 에서 read/write 필요.
///   외부 module 은 default access 도 visible 하지 않음 (class 가 internal 이거나
///   property 가 internal 이면 module 내부만 접근).
/// - `private static let voltageDroopTriggerCount` → `internal static let` — extension 의
///   `updateVoltageDroopTracking` 가 reset 후 본체 tick() 의 trigger gate 와 정합 위해
///   본체에 잔존, 본 method 도 read.
/// - `staleTelemetryThresholdSec` 은 이미 `public static let` — 변경 0.
/// - method 5개 이동: `updateVoltageDroopTracking()` / `updateImuFromRealOrSim()` /
///   `updateSimIMU()` / `updateMotorTempFromRealOrSim()` / `updateSimThermal()`.
///
/// # tick() 호출 site 보존
///
/// tick() 의 호출 순서:
///   1. `updateImuFromRealOrSim()` — IMU real/stale/sim 분기
///   2. `updateMotorTempFromRealOrSim()` — motor temp real/stale/sim 분기
///   3. `updateVoltageDroopTracking()` — voltage droop 연속 sample 카운트
/// 본 phase 이동 후에도 호출 순서 / argument 동일. extension 도 같은 `@MainActor` /
/// 같은 module 의 같은 actor 격리 — race 없음.
///
/// # 회귀
///
/// 1262 tests 회귀 0 — 외부 API 변경 0 (read 시 동일, write 는 module 내부만).
extension WalkLabSession {

    // MARK: - L0 voltage droop tracking

    /// L0 voltage droop tracking — tick() 안에서 호출.
    /// `voltageDroopConsecutiveSamples` 가 임계 `voltageDroopTriggerCount` 도달 시
    /// tick() 의 본체 가드에서 emergency 발화. 본 method 는 카운터만 증감.
    internal func updateVoltageDroopTracking() {
        guard let s = store, s.bus != nil,
              let v = s.lastTelemetry?.board?.voltageVolts,
              v > 0   // sensor 미응답 (0) 가드
        else {
            voltageDroopConsecutiveSamples = 0
            return
        }
        if v < 9.5 {
            voltageDroopConsecutiveSamples += 1
        } else {
            // 회복 — 카운터 리셋. 한 sample 만 droop 했다 회복하면 즉시 false-positive 차단.
            voltageDroopConsecutiveSamples = 0
        }
    }

    // MARK: - IMU real / sim 분기

    /// **Stage 1 (v1.1 fall prevention)**: 실 robot 연결 시 `ConnectionStore.imuFilter`
    /// 의 실 IMU 값 사용 (5Hz polling 자동 갱신). 미연결·stale 시 sim 모델 fallback.
    ///
    /// L3 자동 정지 게이트 (`|roll/pitch| > 50°` × 3 연속 sample) 는 동일하게 작동 —
    /// 실 IMU 가 50° 도달하면 emergency (v1.11.19 정합).
    internal func updateImuFromRealOrSim() {
        // 2026-05-17 v1.7 정정 (사용자 보고 "실 데이터 안 보임"): bus 연결됐으면 무조건
        // real 시도. 종전 suspicion 기반 sim fallback (suspectedLegacy10Bit/outOfRange)
        // 은 chip variant 다양성 못 cover → 사용자가 robot 연결했는데도 sim 표시되는
        // 케이스 발생. 진단 chip (imuScaleWarningChip) 으로 plausibility 경고만 표시.
        //
        // bus == nil → sim fallback (미연결 자동 시뮬).
        // bus != nil + sample 있음 → real (suspicion 무관 - chip variant 신뢰).
        // bus != nil + stale → stale.

        // 1) 실 robot 연결 + IMU 신선도 확인 — suspicion 무관 real 신뢰.
        if let s = store, s.bus != nil, !s.imuFilter.isStale() {
            imuRollDeg = s.imuFilter.rollDeg
            imuPitchDeg = s.imuFilter.pitchDeg
            imuSource = .real
            return
        }
        // 2) IMU stale (5초+ 갱신 없음) → 안전 가드. UI 에 노출.
        if let s = store, s.bus != nil, s.imuFilter.isStale() {
            let wasStale = (imuSource == .stale)
            imuSource = .stale
            // 2026-05-17 C4 fix: stale IMU 로 balance corrector 가 outdated 데이터 기반
            // 으로 잘못 보정하는 위험 차단. 자동 OFF + 이벤트 로그 (사용자에게 안내).
            if enableBalanceCorrection {
                enableBalanceCorrection = false
                logSafetyEvent(
                    kind: .imuSourceChange,
                    message: "IMU 지연 — 자세 보정 자동 OFF (outdated 데이터 위험)"
                )
            }
            // 2026-05-17 chaos audit HIGH #4: stale 진입 시 마지막 값 |≥25°| 면
            // L3 hard gate (50°, v1.11.19) 가 frozen 값으로 잘못 emergency trigger 또는
            // false sense of safety 위험. 안전 측에서 보수적으로 0 으로 reset —
            // fall predictor 도 stale gate (직전 commit) 로 차단되므로 정합.
            // 값 freeze 유지의 이유 (UI 컨텍스트 보존) 와 위험 (frozen 가까운 50° 평가)
            // 사이 trade-off 에서 안전 우선.
            if !wasStale {
                let frozenMax = max(abs(imuRollDeg), abs(imuPitchDeg))
                if frozenMax >= 25 {
                    logSafetyEvent(
                        kind: .imuSourceChange,
                        message: "IMU 지연 — 직전 기울기 \(Int(frozenMax))° 위험 영역, 안전상 0으로 재설정"
                    )
                    imuRollDeg = 0
                    imuPitchDeg = 0
                }
            }
            return
        }
        // 3) 그 외 (미연결 / 테스트) → 기존 sim 모델 fallback.
        updateSimIMU()
        imuSource = .sim
    }

    /// Sim IMU — 워킹 중 본체 흔들림 모델.
    /// roll ≈ 4° 피크 (좌우), pitch ≈ 2° 피크 (전후), 속도 ↑ → 진폭 ↑.
    /// idle 일 때는 0 으로 수렴 (지수 디케이).
    internal func updateSimIMU() {
        let cmd = effectiveCommand
        let periodMs = max(effectivePeriodMs, 200.0)
        let omega = 2.0 * .pi / (periodMs / 1000.0)
        simSwayPhase += omega * tickDtSec

        if cmd.enabled {
            // 속도 비례 보정 — x_amplitude 가 0.04 이면 +50% 진폭.
            let speedFactor = 1.0 + min(abs(cmd.x) / 0.04, 1.0) * 0.5
            let baseRoll = 4.0 * speedFactor
            let basePitch = 2.0 * speedFactor
            imuRollDeg = baseRoll * sin(simSwayPhase + .pi / 2)
            imuPitchDeg = basePitch * sin(simSwayPhase * 2)
        } else {
            // 자연 감쇠 — 한 tick 에 15% 감소.
            imuRollDeg *= 0.85
            imuPitchDeg *= 0.85
            if abs(imuRollDeg) < 0.05 { imuRollDeg = 0 }
            if abs(imuPitchDeg) < 0.05 { imuPitchDeg = 0 }
        }
    }

    // MARK: - 모터 온도 real / sim 분기

    /// **모터 온도 — 실 robot / sim 자동 분기 (2026-05-16)**.
    ///
    /// 이전 버그: `tick()` 이 항상 `updateSimThermal()` 만 호출 → 실 robot 연결 시에도
    /// dashboard 의 L6 Thermal 이 시뮬 값만 표시. 60°C 임계 자동 정지 게이트가 sim
    /// 모델로만 트리거 → 실 모터가 60°C 넘어도 정지 안 됨 (P0).
    ///
    /// 정정: ConnectionStore 의 `lastTelemetry?.joints` 중 max `presentTemperature`
    /// 사용. cadence == .essentials (default) 시 4 sample joints (headPan/Tilt/
    /// rShoulderPitch/rKnee) 중 max. cadence == .full 시 20 관절 모두 중 max.
    ///
    /// 단계:
    /// 1. 실 robot 연결 + telemetry fresh (< 5초) + joints 비어있지 않음 → 실 데이터.
    /// 2. 실 robot 연결 됐으나 telemetry stale (≥ 5초) → 마지막 값 hold, source = .stale.
    /// 3. 그 외 (미연결 / 테스트) → sim model fallback.
    ///
    /// **freshness 임계**: 5초 — ConnectionStore.isImuStale 과 정합.
    internal func updateMotorTempFromRealOrSim() {
        // 1) 실 robot 연결 + telemetry 신선도 확인.
        // 2026-05-17 통일: 하드코딩 5.0 → staleTelemetryThresholdSec.
        // ImuFilter.isStale() 의 5초 임계와 동일 상수 — IMU/motor chimera state 차단.
        if let s = store, s.bus != nil,
           let snap = s.lastTelemetry,
           Date().timeIntervalSince(snap.timestamp) < Self.staleTelemetryThresholdSec,
           let hottest = snap.hottestJoint?.1 {
            // 실 robot — joint 의 max present_temperature 사용.
            maxMotorTemp = Double(hottest.presentTemperature)
            motorTempSource = .real
            return
        }
        // 2) Telemetry stale (5초+ 갱신 없음) → 마지막 값 hold.
        if let s = store, s.bus != nil {
            motorTempSource = .stale
            // 값 유지 (마지막 알려진) — sim 덮어쓰기 회피.
            return
        }
        // 3) 그 외 → sim 모델.
        motorTempSource = .sim
        updateSimThermal()
    }

    /// Sim thermal — 워킹 중 모터 발열 + idle 시 자연 냉각.
    /// 단조 증가/감소. 자동정지(60°C) 게이트 검증을 위한 시뮬.
    internal func updateSimThermal() {
        let cmd = effectiveCommand
        if cmd.enabled {
            maxMotorTemp += motorHeatRate * tickDtSec
        } else if maxMotorTemp > motorAmbientTemp {
            maxMotorTemp -= motorCoolRate * tickDtSec
            if maxMotorTemp < motorAmbientTemp {
                maxMotorTemp = motorAmbientTemp
            }
        }
    }
}
