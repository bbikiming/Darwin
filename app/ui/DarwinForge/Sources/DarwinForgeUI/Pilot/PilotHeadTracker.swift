import ForgeCore
import Foundation
import SwiftUI

/// Mac 측 head tracking PD — Sprint 18 Phase D5 + Codex 잔여 1 보강.
///
/// **알고리즘 (Codex 권고)**: ROBOTIS BallTracker.cpp + Head::MoveTracking 패턴을 따름.
///   1. error = (0.5 - centroid_x) × FOV — 픽셀 → 각도 오차.
///   2. **PD** 제어: step = kp × err + kd × (err - lastErr). Integral 은 windup 위험으로 제외.
///   3. **Deadband**: |err| < deadbandDeg → 송출 skip (떨림 방지).
///   4. **Per-tick clamp**: |step| ≤ maxStepDeg.
///   5. **Lost-target hold**: 검출 없는 frame 이 lostTargetHoldFrames 미만이면 위치 유지.
///
/// **공식 FOV**: DARwIn-OP_ROBOTIS_v1.6.0/Framework/include/Camera.h 의 `Camera::VIEW_*_ANGLE`
/// 가 58° / 46° (Codex 검증). 이전 60/45° 는 근사값.
///
/// **동작 조건**:
///   - `enabled = true`
///   - bus 연결됨 (USB 또는 5530 forge-bridge — `.manualActive` 모드여야 함)
///   - PilotSafetyGate 가 armed (관절 토크 ON)
///   - `BallVision.Detection` 또는 `MultiColorVision.Detection` 의 centroid 입력
///
/// **안전**:
///   - bus 가 nil 이거나 gate.armed = false 면 자동 skip.
///   - ROBOTIS demo (`.ballFollowActive`) 모드면 demo 가 head 제어 — 자동 OFF.
@MainActor
public final class PilotHeadTracker: ObservableObject {
    /// 사용자가 토글 — 카메라 HUD 의 작은 스위치.
    @Published public var enabled: Bool = false

    /// 현재 추적 중인 pan/tilt 도(°) — UI 디버그.
    @Published public private(set) var currentPanDeg: Double = 0
    @Published public private(set) var currentTiltDeg: Double = 0
    /// 마지막 frame 의 처리 시각.
    @Published public private(set) var lastProcessedAt: Date?
    /// 마지막 에러 — bus 미연결 / unarmed / 송출 실패 사유.
    @Published public private(set) var lastSkipReason: String?

    /// 게인 — 사용자가 expert panel 에서 조정 가능 (Codex 권고: 노출).
    /// 기본값은 ROBOTIS-derived seed: 250ms 4Hz polling, FOV 58/46°, MX-28 응답속도 기반.
    /// 너무 세게 하면 진동 — 시작값은 보수적.
    @Published public var kp: Double = 0.32
    @Published public var kd: Double = 0.18

    /// Deadband — 화면 중앙 근처에서 head 떨림 방지. 픽셀 ratio 절대값 < 0.04 (≈ 2.3°) 면 skip.
    @Published public var deadbandNormalized: Double = 0.04

    /// 한 tick 당 max 각도 변화 — 급격한 head 이동 방지.
    @Published public var maxStepDeg: Double = 5.0

    /// 검출 없는 연속 frame 이 이 임계 미만이면 head 위치 유지 (lost-target hold).
    /// 4Hz × 3 = 약 0.75초간 유지. 너무 길면 사용자 인지 느림, 너무 짧으면 깜빡임.
    @Published public var lostTargetHoldFrames: Int = 3

    /// camera FOV — ROBOTIS 공식 Camera.h:17.
    public let fovHorizontalDeg: Double = 58.0
    public let fovVerticalDeg: Double = 46.0
    /// pan/tilt 한계 — ROBOTIS `BallTracker.h:NoBallMaxCount`/`TiltTopLimit`/`TiltBottomLimit`/`PanLimit`
    /// 정확 재현 (firmware-reference/05-vision-pipeline.md Section "Tuning parameters — BallTracker").
    /// 이전 v1.5 의 ±90° / -45°~+30° 보다 보수적 — 모터 부담 + 시야 효율 trade-off.
    public let panRangeDeg: ClosedRange<Double> = -65 ... 65
    public let tiltRangeDeg: ClosedRange<Double> = -12 ... 25

    /// PD 의 derivative term 을 위해 이전 error 보관.
    private var lastErrPanDeg: Double = 0
    private var lastErrTiltDeg: Double = 0
    /// 검출 안 된 연속 frame 카운터 (lost-target hold).
    private var lostFrameCount: Int = 0

    private weak var store: ConnectionStore?
    private weak var gate: PilotSafetyGate?

    public init() {}

    public func attach(store: ConnectionStore, gate: PilotSafetyGate) {
        self.store = store
        self.gate = gate
    }

    /// 토글 — UI 에서 호출. demo 모드에서 enable 호출하면 skip 사유 기록.
    public func setEnabled(_ on: Bool, demoActive: Bool) {
        if on && demoActive {
            lastSkipReason = "ROBOTIS demo 가 head 제어 중 — 수동 모드에서만 활성"
            return
        }
        enabled = on
        if !on {
            lastSkipReason = nil
        }
    }

    /// Detection 1 개 처리 — PilotCameraView 가 새 detection 마다 호출.
    ///
    /// **흐름** (Codex 권고 잔여 1):
    ///   1. 안전 가드 (enabled / demo / bus / armed) — 실패하면 skip.
    ///   2. detection nil 또는 isDetected=false → lost-target hold (count 증가, threshold 미만이면 그대로 유지).
    ///   3. detection 있음 → error 계산 (FOV 단위) → deadband 체크.
    ///   4. PD: step = kp × err + kd × (err - lastErr). per-tick clamp.
    ///   5. 새 pan/tilt clamp + setPosition.
    public func process(detection: BallVision.Detection?, demoActive: Bool) {
        guard enabled else { lastSkipReason = nil; return }
        if demoActive {
            lastSkipReason = "demo active — skip"
            return
        }
        guard let store, let bus = store.bus else {
            lastSkipReason = "bus 미연결 — skip"
            return
        }
        guard let gate, gate.armed else {
            lastSkipReason = "ARM 필요 — 수동 모드에서 ARM 후 활성"
            return
        }

        // detection nil 또는 검출 안 됨 → lost-target hold.
        guard let det = detection, det.isDetected else {
            lostFrameCount &+= 1
            if lostFrameCount >= lostTargetHoldFrames {
                // hold timeout — error 누적 초기화 + 사용자에게 표시.
                lastErrPanDeg = 0
                lastErrTiltDeg = 0
                lastSkipReason = "공 검출 안 됨 (\(lostFrameCount) frame)"
            } else {
                lastSkipReason = nil   // hold 중 — 위치 유지.
            }
            return
        }
        // 검출 됨 — lost counter 리셋.
        lostFrameCount = 0

        // 오차 = (0.5 - centroid_x) × FOV. screen 중앙 (0.5) 이 head 정면이라 가정.
        // centroid_x > 0.5 (공이 화면 오른쪽) → err 음수 → pan += negative → 머리 우향?
        // 일반적: head pan + 가 좌측을 향한다고 가정 (DARwIn-OP 우측 회전 = head pan negative)
        // → centroid_x > 0.5 면 err = (0.5 - 0.6) × 58 = -5.8° → pan adjust 음수 → 머리 오른쪽 ✓
        let errPanDeg = (0.5 - Double(det.centroidNormalized.x)) * fovHorizontalDeg
        let errTiltDeg = (0.5 - Double(det.centroidNormalized.y)) * fovVerticalDeg

        // Deadband — 화면 중앙 근처는 무시 (head 떨림 방지).
        let deadbandDegX = deadbandNormalized * fovHorizontalDeg
        let deadbandDegY = deadbandNormalized * fovVerticalDeg
        let skipPan = abs(errPanDeg) < deadbandDegX
        let skipTilt = abs(errTiltDeg) < deadbandDegY

        // PD: kp × err + kd × (err - lastErr).
        let dPan = errPanDeg - lastErrPanDeg
        let dTilt = errTiltDeg - lastErrTiltDeg
        let stepPan = kp * errPanDeg + kd * dPan
        let stepTilt = kp * errTiltDeg + kd * dTilt

        let panAdjust = skipPan ? 0 : clamp(stepPan, -maxStepDeg, maxStepDeg)
        let tiltAdjust = skipTilt ? 0 : clamp(stepTilt, -maxStepDeg, maxStepDeg)

        lastErrPanDeg = errPanDeg
        lastErrTiltDeg = errTiltDeg

        let newPan = clamp(currentPanDeg + panAdjust, panRangeDeg.lowerBound, panRangeDeg.upperBound)
        let newTilt = clamp(currentTiltDeg + tiltAdjust, tiltRangeDeg.lowerBound, tiltRangeDeg.upperBound)

        // 양쪽 다 deadband 안이면 송출 skip — bus traffic 절감.
        if skipPan && skipTilt {
            lastSkipReason = "중앙 근접 — deadband"
            return
        }

        currentPanDeg = newPan
        currentTiltDeg = newTilt
        lastProcessedAt = Date()

        let panRaw = UInt16(clamping: Kinematics.raw(fromDegrees: newPan))
        let tiltRaw = UInt16(clamping: Kinematics.raw(fromDegrees: newTilt))
        do {
            if !skipPan { _ = try bus.setPosition(.headPan, raw: panRaw) }
            if !skipTilt { _ = try bus.setPosition(.headTilt, raw: tiltRaw) }
            lastSkipReason = nil
        } catch {
            lastSkipReason = "송출 실패: \(error.localizedDescription)"
        }
    }

    /// 초기화 — 카메라 시작/모드 전환 시 호출 권장.
    public func reset() {
        currentPanDeg = 0
        currentTiltDeg = 0
        lastErrPanDeg = 0
        lastErrTiltDeg = 0
        lostFrameCount = 0
        lastProcessedAt = nil
        lastSkipReason = nil
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }
}
