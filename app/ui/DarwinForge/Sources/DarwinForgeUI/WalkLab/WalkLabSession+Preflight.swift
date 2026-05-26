import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 112: god object Phase 10 분할 (Preflight)**.
///
/// `WalkLabSession.swift` (2756 line) 의 `quickPreflight(for:)` (~67 line) 만 본
/// extension 으로 이동. 보행 시작 전 6단계 안전 검사 — side-effect 없는 validation.
///
/// # 비유
///
/// 비행기 이륙 전 조종사 checklist — 6단계 검사 (보행 active / cradle / risk /
/// advanced / caution preset / IMU / thermal cool-down). 모든 항목 통과해야 이륙.
///
/// # 분할 정책
///
/// - **method 1개 이동**: `quickPreflight(for:)`.
/// - 격상 0 — 모든 dependent property/method 이미 internal 이상 access.
/// - 호출 site `start(preset:)` 동일.
///
/// # 회귀
///
/// 1299 tests 회귀 0 — 외부 API 변경 0.
extension WalkLabSession {

    /// 보행 시작 가능 여부 — UI 가드 (start 버튼 disabled 결정용).
    /// `start(preset:)` 첫 줄에서 호출, 차단 시 startBlockedReason 설정 + 즉시 return.
    ///
    /// 차단 사유 (`WalkPreflightFailure.Cause`):
    /// 1. 다른 보행 active (walkCycleTask != nil 또는 isWalkActive)
    /// 2. cradle 미확인 (실 로봇 연결 시만 강제)
    /// 3. high risk 미확인 (requiresRiskConfirmation preset)
    /// 4. advanced && stabilityScore.category == .critical
    /// 5. caution preset && !enableBalanceCorrection
    /// 6. (실 robot 만) IMU unavailable / stale / plausibility 실패
    /// 7. thermal cool-down — 60°C 도달 후 50°C 미만까지 재시작 차단
    ///
    /// **side effect 없음** — 단순 검사. `preflightForWalkCycle(bus:)` 의 torque ON 같은
    /// state-mutating 검사는 startWalkCycle 안에서 실행 (bus guard 통과 후).
    ///
    /// idle preset 은 항상 통과 (정지 동작은 차단되면 안 됨).
    internal func quickPreflight(for preset: WalkLabPreset) -> WalkPreflightFailure? {
        if preset == .idle { return nil }

        // 1. 이미 다른 보행이 active.
        // **사이클 61 노트**: 본 site 는 `isActuallyWalking` 위임 안 함 — `current != .idle`
        // 까지 검사하면 preset 전환 (march → slowWalk 등) 까지 차단되어 UX 깨짐.
        // preset switch 는 cancelWalkCycle 이 cleanup 책임. 본 가드는 "실 motor task 또는
        // onboard 활성" 만 차단 (semantic 의도가 isActuallyWalking 과 다름).
        if isWalkActive || walkCycleTask != nil {
            let activeLabel = activeRobotPreset?.label ?? current.label
            return WalkPreflightFailure(cause: .alreadyWalking(
                activePresetLabel: activeLabel,
                requestedLabel: preset.label
            ))
        }

        // 2. cradle 미확인. **v1.14.7 (2026-05-21)** — 시뮬 모드 (bus 미연결) 면 skip.
        //    실 로봇 연결 시에만 cradle 강제. 시뮬에선 사용자가 보행 알고리즘 미리보기 가능.
        let needsCradle = (store?.bus != nil)
        if needsCradle && !cradleConfirmed {
            return WalkPreflightFailure(cause: .cradleNotConfirmed)
        }

        // 3. high risk 미확인.
        if preset.requiresRiskConfirmation && !riskAcknowledged {
            return WalkPreflightFailure(cause: .highRiskNotAcknowledged(presetLabel: preset.label))
        }

        // 4. advanced critical.
        if advanced && stabilityScore.category == .critical {
            return WalkPreflightFailure(cause: .advancedStabilityCritical)
        }

        // 5. caution preset 의 balance corrector 의무.
        if preset.safety == .caution && !enableBalanceCorrection {
            return WalkPreflightFailure(cause: .balanceCorrectorRequiredForCautionPreset(
                presetLabel: preset.label
            ))
        }

        // 6. 실 robot 연결 시에만 IMU 가드 — sim 모드는 통과 (preview 가능).
        if let store = self.store, store.bus != nil {
            if store.isImuUnavailable {
                return WalkPreflightFailure(cause: .imuUnavailable)
            }
            if store.isImuStale {
                return WalkPreflightFailure(cause: .imuStale)
            }
            if store.imuScaleSuspicion == .suspectedLegacy10Bit
                || store.imuScaleSuspicion == .outOfRange {
                return WalkPreflightFailure(cause: .imuPlausibilityFailed(
                    store.imuScaleSuspicion.rawValue
                ))
            }
        }

        // 7. v1.11.25 audit-D — thermal cool-down 강제.
        // 종전: banner "닫기" 누르면 즉시 thermalAlarm=false → 60°C 직후 1초 만에 재시작 가능.
        // motor 영구 손상 위험. 일단 60°C 도달했으면 cooldownExitTemp (50°C) 미만까지 차단.
        if thermalCoolDownRequired && maxMotorTemp >= Self.thermalCooldownExitTemp {
            return WalkPreflightFailure(cause: .motorTempCoolDownRequired(
                currentTempC: maxMotorTemp,
                exitTempC: Self.thermalCooldownExitTemp
            ))
        }

        // 8. **V288-4 (2026-05-24) — OC8 STPA**: LiPo 3S 배터리 최저 전압 L1 차단.
        //
        // 비유: 자동차 연료 0 = 시동 자체 불가. 10.5V 이하에서 보행 시작은 주행 중
        // 전원 차단 → 낙상 위험. override 불가 (안전 하드 게이트).
        //
        // - 실 로봇 연결 확인: `store.bus != nil` 또는 `_testOverrideBusConnected=true` (test hook).
        // - voltage source: `voltageForGate` — store telemetry 우선, test override 지원.
        // - nil voltage → 차단 안 함 (fail-safe: telemetry 미수신 중 보행 허용).
        // - 10.5V 이하 (≤) → 하드 차단 (경계값 포함).
        let busConnected: Bool = {
            if store?.bus != nil { return true }
            #if DEBUG
            if _testOverrideBusConnected == true { return true }
            #endif
            return false
        }()
        if busConnected, let v = voltageForGate, v <= Self.lowBatteryThreshold {
            return WalkPreflightFailure(cause: .lowBatteryStartBlocked(
                voltage: v,
                threshold: Self.lowBatteryThreshold
            ))
        }

        return nil
    }
}
