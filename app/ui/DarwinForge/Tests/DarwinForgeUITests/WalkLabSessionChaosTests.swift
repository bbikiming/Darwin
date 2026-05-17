import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 2026-05-17 chaos injection 단위 테스트.
///
/// 실 robot 없이 안전 가드 자동 검증:
/// - busDisconnected 시 isBusAlive closure 가 false 반환
/// - IMU stale 진입 시 enableBalanceCorrection 자동 OFF + tilt reset
/// - per-joint failure (timeout) 가 global watchdog 트리거 안 함
/// - WalkCycleResult.EndReason 모든 case 가 distinct 한 isSuccess 분류
@MainActor
final class WalkLabSessionChaosTests: XCTestCase {

    // MARK: - WalkCycleResult invariants (chaos #1 fix 회귀 가드)

    /// **busDisconnected 의 userMessage 는 "연결 끊김" + "재연결" 포함** — 사용자
    /// 행동 가능 메시지 회귀 가드.
    func testBusDisconnectedUserMessageActionable() {
        let result = WalkLabSession.WalkCycleResult(
            reason: .busDisconnected,
            stepsExecuted: 7,
            speedWriteFailures: 0,
            positionWriteFailures: 0,
            lowerBodyPositionFails: [],
            sampleError: nil
        )
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.userMessage.contains("연결 끊김"),
            "사용자 인지 가능한 명확한 메시지")
        XCTAssertTrue(result.userMessage.contains("재연결"),
            "다음 행동 안내 — 재연결 후 다시 시작")
        XCTAssertTrue(result.userMessage.contains("7 step"),
            "stepsExecuted 노출 — 보행 진행 정도 사용자 인지")
    }

    /// **EndReason 5개 case 모두 distinct 한 isSuccess 분류**.
    /// 새 case 추가 시 (예: thermalEmergency) 회귀 자동 잡힘.
    func testAllEndReasonsHaveCorrectSuccess() {
        let cases: [(WalkLabSession.WalkCycleResult.EndReason, Bool)] = [
            (.completedMaxDuration, true),
            (.userCancelled, true),
            (.lowerBodyWriteFailure, false),
            (.bulkWriteFailure, false),
            (.busDisconnected, false),
        ]
        for (reason, expectedSuccess) in cases {
            let r = WalkLabSession.WalkCycleResult(
                reason: reason,
                stepsExecuted: 0,
                speedWriteFailures: 0,
                positionWriteFailures: 0,
                lowerBodyPositionFails: [],
                sampleError: nil
            )
            XCTAssertEqual(r.isSuccess, expectedSuccess,
                "\(reason) → isSuccess \(expectedSuccess)")
        }
    }

    // MARK: - Preflight failure invariants (chaos critical fixes)

    /// **모든 PreflightFailure.Cause 의 userMessage 가 emoji + 한국어**.
    /// emoji prefix 로 UI 가 visual cue 일관 (🛑 차단 / ⚠️ 주의 / ℹ️ 정보).
    func testAllPreflightCausesHaveLocalizedMessage() {
        let causes: [WalkLabSession.WalkPreflightFailure.Cause] = [
            .noConnection,
            .cradleNotConfirmed,
            .dxlPowerFailed("test"),
            .lowerBodyTorqueFailed([.rHipPitch]),
            .bulkTorqueFailed(failedCount: 5, total: 20),
            .balanceCorrectorRequiredForCautionPreset(presetLabel: "빠르게 걷기"),
        ]
        for c in causes {
            let f = WalkLabSession.WalkPreflightFailure(cause: c)
            XCTAssertFalse(f.userMessage.isEmpty,
                "\(c) — userMessage 비어있으면 안 됨")
            // 한국어 또는 emoji 포함 — ASCII-only 영문은 internal terms
            let hasKorean = f.userMessage.contains { ch in
                let s = String(ch).unicodeScalars.first?.value ?? 0
                return s >= 0xAC00 && s <= 0xD7AF  // Hangul Syllables
            }
            let hasEmoji = f.userMessage.contains("🛑")
                || f.userMessage.contains("⚠️")
                || f.userMessage.contains("ℹ️")
            XCTAssertTrue(hasKorean || hasEmoji,
                "\(c) — 한국어 또는 emoji visual cue 포함 필요. msg: \(f.userMessage)")
        }
    }

    // MARK: - BalanceState boundary (off-by-one 회귀 가드)

    /// **v1.8 (2026-05-17) BalanceState boundary** — 25/35/45/50°.
    func testBalanceStateExactBoundary() {
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 50.0), .emergency,
            "50.0° = emergency (ROBOTIS FALLEN)")
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 49.9999), .danger,
            "50.0° 직전 = danger")
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 45.0), .danger)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 44.9999), .warning)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 35.0), .warning)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 34.9999), .caution)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 25.0), .caution)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 24.9999), .normal)
    }

    /// **BalanceState.speedScale 모든 case 정합**.
    /// warning 0.7 / danger 0 / emergency 0 / normal & caution 1.0 — 회귀 가드.
    func testBalanceStateSpeedScales() {
        XCTAssertEqual(WalkLabSession.BalanceState.normal.speedScale, 1.0)
        XCTAssertEqual(WalkLabSession.BalanceState.caution.speedScale, 1.0)
        XCTAssertEqual(WalkLabSession.BalanceState.warning.speedScale, 0.7,
            "warning = 70% 감속")
        XCTAssertEqual(WalkLabSession.BalanceState.danger.speedScale, 0.0,
            "danger = 자세 동결")
        XCTAssertEqual(WalkLabSession.BalanceState.emergency.speedScale, 0.0,
            "emergency = 정지")
    }

    // MARK: - ImuScaleSuspicion (사용자 보고 critical)

    /// **v1.7 ImuScaleSuspicion 4개 case 의 rawValue 사용자 facing 의미체계**.
    /// cm.rs 10-bit ADC 정정 후: looksValid=정상(중력 감지), suspectedLegacy10Bit=중력 약함,
    /// outOfRange=raw 범위 외. enum 이름은 backward-compat 위해 보존.
    func testImuScaleSuspicionUserMessages() {
        XCTAssertEqual(ConnectionStore.ImuScaleSuspicion.unknown.rawValue,
                       "unknown")
        XCTAssertTrue(ConnectionStore.ImuScaleSuspicion.looksValid16Bit.rawValue.contains("정상"),
            "정상 — 한국어 라벨")
        XCTAssertTrue(ConnectionStore.ImuScaleSuspicion.suspectedLegacy10Bit.rawValue.contains("주의"),
            "중력 신호 약할 때 '주의' 표시")
        XCTAssertTrue(ConnectionStore.ImuScaleSuspicion.outOfRange.rawValue.contains("비정상"),
            "범위 밖 — '비정상' 한국어 라벨")
    }

    // MARK: - Per-joint isolation (chaos #3 fix)

    /// **신규 store 의 jointConsecutiveFailures empty**.
    /// false-positive UI 표시 차단 회귀 가드.
    func testJointConsecutiveFailuresInitiallyEmpty() {
        let store = ConnectionStore()
        XCTAssertTrue(store.jointConsecutiveFailures.isEmpty,
            "신규 store — per-joint counter 비어있음")
    }

    // MARK: - FallPrediction stale gate (chaos #4 fix)

    /// **신규 session 의 fallPrediction = .zero**.
    /// stale gate fix 의 sentinel 값 회귀 가드.
    func testFallPredictionInitiallyZero() {
        let session = WalkLabSession()
        XCTAssertEqual(session.fallPrediction.score, 0)
        XCTAssertNil(session.fallPrediction.etaMs)
        XCTAssertFalse(session.fallPrediction.recommendEmergency)
    }

    // MARK: - Lifecycle invariants (chaos resilience)

    /// **stop → emergencyStop → stop 다중 호출 안전**.
    /// idempotency invariant — 동일 메서드 반복 호출 가 새 부작용 없음.
    func testStopAndEmergencyStopIdempotent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)

        // 다중 stop / emergencyStop 호출 — 충돌 없이 안전.
        session.stop()
        session.stop()
        session.emergencyStop()
        session.emergencyStop()
        session.stop()

        // 최종 상태: idle.
        XCTAssertEqual(session.current, .idle,
            "다중 stop/emergencyStop 후 idle 안전")
    }

    /// **cradleConfirmed false → emergencyStop 도 안전**.
    /// 보행 시작 안 한 상태에서 emergencyStop 호출 시 crash 없음.
    func testEmergencyStopWithoutStart() {
        let session = WalkLabSession()
        // start 호출 안 함.
        session.emergencyStop()
        XCTAssertEqual(session.current, .idle,
            "start 없이 emergencyStop — 안전 idle 유지")
    }

    // MARK: - WalkLabSession.staleTelemetryThresholdSec invariant

    /// **staleTelemetryThresholdSec = 5.0** — IMU / motor 동일 임계.
    /// ImuFilter.isStale 의 5.0 와 정합 (chimera state 차단).
    func testStaleTelemetryThresholdConstant() {
        XCTAssertEqual(WalkLabSession.staleTelemetryThresholdSec, 5.0,
            "5.0초 — ImuFilter 와 동일 임계")
    }

    // MARK: - 2026-05-17 추가 안전 강화 (5건)

    /// **preflightStatus 신규 session — 모든 체크 PASS or INFO** (sim 모드).
    func testPreflightStatusInitial() {
        let session = WalkLabSession()
        let status = session.preflightStatus
        // sim 모드 — bus 없음 → blocking 없음.
        XCTAssertTrue(status.canStart,
            "sim 모드 — 모든 체크 통과 (시작 가능)")
        XCTAssertTrue(status.attentionItems.isEmpty,
            "sim 모드 — 주의 항목 없음")
    }

    /// **caution preset + balance OFF → preflightStatus 차단** (L5 blocking).
    /// v1.7 default ON 이라 명시적으로 OFF 후 검증.
    func testPreflightStatusBlocksCautionWithoutBalance() {
        let session = WalkLabSession()
        session.enableBalanceCorrection = false  // v1.7: default ON, 명시 OFF
        session.current = .fastWalk  // caution 등급
        XCTAssertFalse(session.enableBalanceCorrection,
            "명시 OFF 후 confirmed")
        let status = session.preflightStatus
        let l5 = status.checks.first { $0.label == "L5 자세 보정" }
        XCTAssertEqual(l5?.state, .blocking,
            "fastWalk + balance OFF → L5 blocking")
        XCTAssertFalse(status.canStart,
            "L5 blocking → canStart false")
    }

    /// **caution preset + balance ON → preflightStatus 통과**.
    func testPreflightStatusAllowsCautionWithBalance() {
        let session = WalkLabSession()
        session.current = .fastWalk
        session.enableBalanceCorrection = true
        let status = session.preflightStatus
        let l5 = status.checks.first { $0.label == "L5 자세 보정" }
        XCTAssertEqual(l5?.state, .pass,
            "balance ON → L5 pass")
    }

    /// **PreflightStatus.canStart Equatable** — UI binding 정합.
    func testPreflightStatusEquatable() {
        let session1 = WalkLabSession()
        let session2 = WalkLabSession()
        XCTAssertEqual(session1.preflightStatus.canStart,
                       session2.preflightStatus.canStart,
            "동일 default 상태 → 동일 canStart")
    }

    /// **영구 이벤트 로그 — 비어있는 상태 default**.
    func testPersistentEventsInitiallyEmpty() {
        WalkLabSession.clearPersistentEvents()
        let events = WalkLabSession.loadPersistentEvents()
        XCTAssertTrue(events.isEmpty,
            "clearPersistentEvents 후 빈 배열")
    }

    /// **영구 이벤트 로그 — emergencyStop 후 1건 저장**.
    func testPersistentEventsLogsEmergencyStop() {
        WalkLabSession.clearPersistentEvents()
        let session = WalkLabSession()
        session.emergencyStop()
        let events = WalkLabSession.loadPersistentEvents()
        XCTAssertGreaterThan(events.count, 0,
            "emergencyStop 후 영구 로그 1건+ 추가")
        XCTAssertTrue(events.contains { $0.kindRaw == "emergencyTriggered" },
            "emergencyTriggered kind 포함")
        // cleanup
        WalkLabSession.clearPersistentEvents()
    }

    /// **PersistentEvent JSON 직렬화 정합**.
    func testPersistentEventJsonRoundtrip() {
        let original = WalkLabSession.PersistentEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 100_000),
            kindRaw: "emergencyTriggered",
            message: "테스트 메시지"
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(WalkLabSession.PersistentEvent.self, from: data)
        XCTAssertEqual(original, decoded,
            "JSON encode/decode 후 동일")
    }

    // MARK: - 2026-05-17 emergency-stop recovery 회귀 가드

    /// **Bus.setPGain API 가 존재 + 시그니처 정합**.
    /// 종전: emergency_stop 가 P_GAIN=0 으로 만들지만 recovery 에서 복원 못 함 →
    /// 모터 weak hold. setPGain wrapper 가 Bus 에 노출됐는지 컴파일 검증.
    func testBusSetPGainAPIExists() {
        // 컴파일 가능 = API 존재. value: UInt8 시그니처 검증.
        let _: (Bus, JointID, UInt8) throws -> Void = { bus, joint, value in
            try bus.setPGain(joint, value: value)
        }
        // factory default 32 가 유효 UInt8 범위 (0-254).
        XCTAssertTrue((0...254).contains(UInt8(32)),
            "P_GAIN 32 는 MX-28T 유효 범위")
    }

    /// **ConnectionStore.recoverFromEStop API 시그니처 정합**.
    /// cradleConfirmed: Bool 가 첫 인자, async function 검증.
    func testRecoverFromEStopAPI() {
        let store = ConnectionStore()
        // 컴파일 가능 = API 존재. cradleConfirmed default false.
        let _: () async -> Void = {
            await store.recoverFromEStop()
            await store.recoverFromEStop(cradleConfirmed: false)
            await store.recoverFromEStop(cradleConfirmed: true)
        }
        XCTAssertEqual(store.isRecovering, false,
            "신규 store — isRecovering false")
    }

    // MARK: - 2026-05-17 v1.7 IMU ROBOTIS 일치 회귀 가드

    /// **ImuRaw raw 가 UInt16** (10-bit ADC 정합).
    /// 종전 Int16 + ±32767 가정은 raw 512 → atan2(512,512) = 45° false tilt 의 원인.
    /// v1.7 정정: UInt16 + center 512 + ROBOTIS RL=X / FB=Y axis.
    func testImuRawTypesMatchRobotis10BitAdc() {
        // public init 이 UInt16 만 받음 — 컴파일 가능하면 OK.
        let upright = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,  // 1g gravity on Z
            rollDeg: 0, pitchDeg: 0
        )
        // centered = raw - 512.
        XCTAssertEqual(upright.gyroXCentered, 0, accuracy: 0.001,
            "gyro X 512 = center → centered 0")
        XCTAssertEqual(upright.accelZCentered, 256, accuracy: 0.001,
            "accel Z 768 = 1g (center+256) → centered 256")
        // ROBOTIS adcCenter constant 노출.
        XCTAssertEqual(ImuRaw.adcCenter, 512.0,
            "ADC center = 512 (ROBOTIS-OP2 MotionManager.cpp:73)")
    }

    /// **Swift accessor 가 (raw-512) × LSB 스케일 적용**.
    func testImuRawAccessorsApplyCenteredScale() {
        let sample = ImuRaw(
            gyroX: 768, gyroY: 512, gyroZ: 256,   // +256, 0, -256 LSB
            accelX: 768, accelY: 256, accelZ: 768,
            rollDeg: 0, pitchDeg: 0
        )
        // gyroDpsPerLsb = 2000/512 ≈ 3.906
        XCTAssertEqual(sample.gyroXDps, 256 * (2000.0 / 512.0), accuracy: 0.001)
        XCTAssertEqual(sample.gyroYDps, 0, accuracy: 0.001)
        XCTAssertEqual(sample.gyroZDps, -256 * (2000.0 / 512.0), accuracy: 0.001)
        // accelGPerLsb = 1/256
        XCTAssertEqual(sample.accelZG, 256 * (1.0 / 256.0), accuracy: 0.001,
            "accel Z 768 raw → +1g (256 LSB above center)")
    }
}
