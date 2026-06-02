import Foundation
import ForgeCore

/// **A (2026-05-31) — 정지 상태 IMU 영점 자동 캡처**.
///
/// `fallMonitorTick`(always-on, 10Hz)에서 매 틱 호출된다. 로봇이 walkReady 로 충분히
/// 오래(≈3초) 가만히 서 있으면 그 구간의 IMU pitch/roll 평균을 "영점"으로 캡처해
/// 영속·로깅한다.
///
/// # 동작 변경 없음 (안전)
///
/// 본 로직은 **읽기 + 저장 + 로깅만** 한다. 모터 명령/안전 게이트/보정기에는 일절 관여하지
/// 않는다. 캡처된 영점의 control 적용은 별도 단계(B·D)에서 검증 후 도입한다.
@MainActor
extension WalkLabSession {

    /// 정지 판정 자이로 임계 — 이 값보다 각속도가 작아야 "정지" 로 본다(°/s).
    private static var imuZeroStillGyroDps: Double { 3.0 }
    /// 영점 캡처에 필요한 연속 정지 샘플 수 (10Hz × 30 = 3초).
    private static var imuZeroRequiredSamples: Int { 30 }
    /// 재캡처 임계 — 기존 영점과 이만큼(deg) 이상 차이 날 때만 갱신(로그 스팸 방지).
    private static var imuZeroRecaptureDriftDeg: Double { 2.0 }

    /// 연결 직후 1회: 영속된 영점을 로드해 헤더/UI 가 참조하도록 준비 + 세션별 캡처 throttle 리셋.
    internal func primeImuZeroForConnection() {
        if lastImuZero == nil {
            lastImuZero = imuZeroStore.load()
        }
        imuZeroCapturedThisConnection = false
        imuZeroStillSamples.removeAll(keepingCapacity: true)
    }

    /// 정지 상태 자동 캡처 — `fallMonitorTick` 에서 매 틱 호출.
    /// 정지가 아니거나 전제 조건 미충족이면 누적을 비우고 즉시 반환(부작용 없음).
    ///
    /// **게이트 완화 (2026-05-31, B)**: 영점 캡처는 IMU 읽기 전용이라 cradle(정비 스탠드)
    /// 위에서 하는 것이 오히려 더 안정적·안전하다. 따라서 종전의 `!cradleConfirmed` /
    /// `isDxlPowerOn == true` 전제를 제거한다. 남은 전제는 "정적인 자세를 보장" 하는 최소
    /// 조건(보행 아님 / 복구 아님 / 연결됨)만이다.
    internal func updateImuZeroAutoCapture() {
        // 전제: 연결 + 비보행(static) + 비복구 상태. cradle/torque 무관(읽기 전용).
        guard store?.bus != nil,
              store?.isRecovering != true,
              current == .idle,
              autoRecoveryPhase == .idle else {
            imuZeroStillSamples.removeAll(keepingCapacity: true)
            return
        }
        guard let raw = store?.lastImuRaw else {
            imuZeroStillSamples.removeAll(keepingCapacity: true)
            return
        }

        // 정지 판정 — pitch/roll 축 각속도(gyroX/Y)가 모두 작아야 한다.
        let gyroMag = max(abs(raw.gyroXDps), abs(raw.gyroYDps))
        guard gyroMag < Self.imuZeroStillGyroDps else {
            // 움직임 감지 — 누적 리셋 (정지가 "연속" 이어야 유효).
            imuZeroStillSamples.removeAll(keepingCapacity: true)
            return
        }

        imuZeroStillSamples.append((pitch: imuPitchDeg, roll: imuRollDeg))
        guard imuZeroStillSamples.count >= Self.imuZeroRequiredSamples else { return }

        // 충분히 정지 — 평균으로 영점 산출.
        let n = Double(imuZeroStillSamples.count)
        let pitchZero = imuZeroStillSamples.reduce(0.0) { $0 + $1.pitch } / n
        let rollZero  = imuZeroStillSamples.reduce(0.0) { $0 + $1.roll } / n
        let sampleCount = imuZeroStillSamples.count
        imuZeroStillSamples.removeAll(keepingCapacity: true)

        // throttle: 이번 연결에서 이미 캡처했고 drift 가 작으면 갱신 안 함.
        if imuZeroCapturedThisConnection, let prev = lastImuZero {
            let drift = max(abs(pitchZero - prev.pitchZeroDeg), abs(rollZero - prev.rollZeroDeg))
            if drift < Self.imuZeroRecaptureDriftDeg { return }
        }

        commitImuZero(pitchZero: pitchZero, rollZero: rollZero,
                      sampleCount: sampleCount, source: "auto_stillness")
    }

    /// 사용자 수동 캡처 — 현재 누적된 정지 샘플(있으면)로 즉시 영점 잡기.
    /// 누적이 비어 있으면 현재 단일 IMU 값으로라도 캡처(사용자 명시 의도).
    internal func captureImuZeroManually() {
        let samples = imuZeroStillSamples.isEmpty
            ? [(pitch: imuPitchDeg, roll: imuRollDeg)]
            : imuZeroStillSamples
        let n = Double(samples.count)
        let pitchZero = samples.reduce(0.0) { $0 + $1.pitch } / n
        let rollZero  = samples.reduce(0.0) { $0 + $1.roll } / n
        imuZeroStillSamples.removeAll(keepingCapacity: true)
        commitImuZero(pitchZero: pitchZero, rollZero: rollZero,
                      sampleCount: samples.count, source: "manual")
    }

    /// 영점 확정 — 영속 저장 + lastImuZero 갱신 + harness 로깅(명확 저장 보장).
    private func commitImuZero(pitchZero: Double, rollZero: Double, sampleCount: Int, source: String) {
        let calibration = ImuZeroCalibration(
            pitchZeroDeg: pitchZero,
            rollZeroDeg: rollZero,
            capturedAtISO: ISO8601DateFormatter().string(from: Date()),
            sampleCount: sampleCount,
            source: source
        )
        imuZeroStore.save(calibration)
        lastImuZero = calibration
        imuZeroCapturedThisConnection = true

        harness.record(
            .imuZeroCaptured, level: .notice, actor: .robot,
            data: [
                "pitch_zero_deg": AnyCodable((pitchZero * 100).rounded() / 100),
                "roll_zero_deg": AnyCodable((rollZero * 100).rounded() / 100),
                "sample_count": AnyCodable(sampleCount),
                "source": AnyCodable(source)
            ]
        )
        logSafetyEvent(
            kind: .preflightFailure,
            message: String(format: "IMU 영점 캡처 — pitch %+.1f° roll %+.1f° (%@, %d샘플). 분석용 기록(동작 미적용)",
                            pitchZero, rollZero, source, sampleCount)
        )
    }
}
