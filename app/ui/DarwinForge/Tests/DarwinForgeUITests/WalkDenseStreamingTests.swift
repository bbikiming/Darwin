import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **Wave D1 (2026-06-12, bus-direct-teleop-upgrade §4)** — 시간 기반 50Hz 연속
/// 스트리밍 + 진폭 래칭의 단위 검증.
///
/// 핵심 보장:
/// 1. **동치(궤적 회귀 0)** — 같은 tuning·같은 시각에서 6 키프레임 모드 포즈와 시간
///    기반 모드 포즈가 비트 단위로 일치(같은 연속 함수의 밀도만 다름).
/// 2. **래칭 경계 의미론** — 진폭은 스윙 중간(0.25/0.75), period 는 DSP 경계(wrap)에서만
///    채택. "경계 전 변경이 경계 후 반영"을 결정적으로 증명.
/// 3. **슬루 한계 O2 패리티** — SLEW_*_MAX 값이 `WalkLabTransport.h` 와 동일.
final class WalkDenseStreamingTests: XCTestCase {

    /// `makeContinuousPlan` 과 동일한 6 sample phase (소스 단일 정의의 복제 — 계약 고정).
    private let samplePhases: [Double] = [0.03, 0.18, 0.42, 0.52, 0.68, 0.92]

    // MARK: - ① 동치 테스트 (궤적 회귀 0)

    func testDensePoseMatchesKeyframePosesForAllPresets() {
        let presets: [WalkLabPreset] = [.march, .slowWalk, .normalWalk, .fastWalk, .turnLeft, .turnRight]
        for preset in presets {
            guard let plan = WalkMotionLibrary.continuousWalkPlan(for: preset) else {
                XCTFail("\(preset) continuousWalkPlan 누락"); continue
            }
            let resolved = WalkMotionLibrary.resolvedPresetTuning(for: preset)
            let period = resolved.periodMs
            XCTAssertGreaterThanOrEqual(period, WalkDenseStreaming.denseMinPeriodMs,
                "\(preset) 프리셋 period 가 440 이상이어야 시간/키프레임 모드가 분기 없이 일치")
            XCTAssertEqual(plan.cycle.count, samplePhases.count, "\(preset) cycle 키프레임 수")

            for (i, phase) in samplePhases.enumerated() {
                let keyframePose = plan.cycle[i].toPose()
                let tCycle = WalkDenseStreaming.cycleTimeMs(elapsedMs: phase * period, periodMs: period)
                let densePose = WalkDenseStreaming.pose(atCycleMs: tCycle, tuning: resolved)
                for joint in JointID.allCases {
                    XCTAssertEqual(
                        densePose.raw(joint), keyframePose.raw(joint),
                        "\(preset) phase[\(i)]=\(phase) \(joint.name): 시간 기반 ≠ 키프레임 (궤적 회귀)")
                }
            }
        }
    }

    /// freeform(라이브 조종) 경로도 동일 — `freeformResolvedTuning` 으로 동치.
    func testDensePoseMatchesFreeformKeyframes() {
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 30, sideMm: 10, turnDeg: 6, periodMs: 600,
            footHeightMm: 35, balanceGain: 1.0)
        guard let plan = WalkMotionLibrary.freeformContinuousWalkPlan(tuning: tuning) else {
            XCTFail("freeform plan 누락"); return
        }
        let resolved = WalkMotionLibrary.freeformResolvedTuning(tuning)
        let period = resolved.periodMs
        for (i, phase) in samplePhases.enumerated() {
            let keyframePose = plan.cycle[i].toPose()
            let tCycle = WalkDenseStreaming.cycleTimeMs(elapsedMs: phase * period, periodMs: period)
            let densePose = WalkDenseStreaming.pose(atCycleMs: tCycle, tuning: resolved)
            for joint in JointID.allCases {
                XCTAssertEqual(densePose.raw(joint), keyframePose.raw(joint),
                    "freeform phase[\(i)] \(joint.name): 시간 기반 ≠ 키프레임")
            }
        }
    }

    // MARK: - ② 래칭 경계 단위 테스트

    /// 경계 전(0.1) 변경은 미반영, 스윙 중간(0.25) 통과 후 슬루로 반영.
    func testAmplitudeLatchesAtSwingMidpointWithSlew() {
        let t0 = tuning(stride: 0, side: 0, turn: 0, period: 600)
        let target = tuning(stride: 30, side: 20, turn: 12, period: 600)
        var latch = WalkAmplitudeLatch(initial: t0)
        let period = 600.0

        // frac=0.1 — 어떤 진폭/주기 경계도 미통과 → committed 불변.
        latch.advance(elapsedMs: 0.1 * period, target: target)
        XCTAssertEqual(latch.committed.strideMm, 0, "경계 전: stride 미반영")
        XCTAssertEqual(latch.committed.sideMm, 0, "경계 전: side 미반영")
        XCTAssertEqual(latch.committed.turnDeg, 0, "경계 전: turn 미반영")

        // frac=0.3 — 0.25(좌 스윙 중간) 통과 → 축당 SLEW_*_MAX 만큼만 전진.
        latch.advance(elapsedMs: 0.3 * period, target: target)
        XCTAssertEqual(latch.committed.strideMm, WalkDenseStreaming.slewDxMaxMm, accuracy: 1e-9,
            "경계 후: stride 가 SLEW_DX_MAX(8) 만큼 슬루")
        XCTAssertEqual(latch.committed.sideMm, WalkDenseStreaming.slewDyMaxMm, accuracy: 1e-9,
            "경계 후: side 가 SLEW_DY_MAX(6) 만큼 슬루")
        XCTAssertEqual(latch.committed.turnDeg, WalkDenseStreaming.slewDaMaxDeg, accuracy: 1e-9,
            "경계 후: turn 가 SLEW_DA_MAX(4) 만큼 슬루")

        // frac=0.8 — 0.75(우 스윙 중간) 통과 → 한 번 더 전진.
        latch.advance(elapsedMs: 0.8 * period, target: target)
        XCTAssertEqual(latch.committed.strideMm, 2 * WalkDenseStreaming.slewDxMaxMm, accuracy: 1e-9,
            "두 번째 스윙 중간: stride 16")
    }

    /// period 는 진폭 경계가 아니라 DSP 경계(wrap)에서만 슬루로 채택.
    func testPeriodLatchesAtDspBoundaryOnly() {
        let t0 = tuning(stride: 0, side: 0, turn: 0, period: 600)
        let target = tuning(stride: 0, side: 0, turn: 0, period: 500)
        var latch = WalkAmplitudeLatch(initial: t0)

        // 0.1 → 0.3 (스윙 중간 통과) 이지만 wrap 없음 → period 불변.
        latch.advance(elapsedMs: 0.1 * 600, target: target)
        latch.advance(elapsedMs: 0.3 * 600, target: target)
        XCTAssertEqual(latch.committed.periodMs, 600, "DSP 경계 전: period 불변")

        // wrap (frac 0.3 → 0.1, elapsed 660 → 660 mod 600 = 60 → 0.1) → DSP 경계 통과.
        latch.advance(elapsedMs: 660, target: target)
        XCTAssertEqual(latch.committed.periodMs, 600 - WalkDenseStreaming.slewDPeriodMaxMs, accuracy: 1e-9,
            "DSP 경계: period 가 SLEW_DPERIOD_MAX(60) 만큼 슬루 (600→540)")
    }

    /// 첫 advance(valid=false) 는 슬루 없이 target 즉시 수용 (O2 와 동일).
    func testUninitializedLatchAcceptsTargetImmediately() {
        var latch = WalkAmplitudeLatch()  // 미초기화.
        let target = tuning(stride: 40, side: 20, turn: 10, period: 520)
        latch.advance(elapsedMs: 1234, target: target)
        XCTAssertEqual(latch.committed.strideMm, 40, "미초기화 첫 수용: 슬루 없음")
        XCTAssertEqual(latch.committed.periodMs, 520)
    }

    // MARK: - ③ 순수 helper / 상수 패리티

    func testSlewClampsPerAxis() {
        XCTAssertEqual(WalkAmplitudeLatch.slew(0, 30, 8), 8, accuracy: 1e-9, "상향 클램프")
        XCTAssertEqual(WalkAmplitudeLatch.slew(30, 0, 8), 22, accuracy: 1e-9, "하향 클램프")
        XCTAssertEqual(WalkAmplitudeLatch.slew(0, 5, 8), 5, accuracy: 1e-9, "한계 내: target 도달")
    }

    func testCrossedHandlesWrap() {
        XCTAssertTrue(WalkAmplitudeLatch.crossed(boundary: 0.25, prev: 0.1, cur: 0.3), "정상 통과")
        XCTAssertFalse(WalkAmplitudeLatch.crossed(boundary: 0.25, prev: 0.3, cur: 0.4), "미통과")
        XCTAssertTrue(WalkAmplitudeLatch.crossed(boundary: 0.0, prev: 0.8, cur: 0.1), "wrap: DSP 경계 발화")
        XCTAssertFalse(WalkAmplitudeLatch.crossed(boundary: 0.5, prev: 0.8, cur: 0.1), "wrap: 비경계 미발화")
    }

    func testCycleTimeMsClampsPeriodFloor() {
        // period 400 → 440 클램프 → 500 mod 440 = 60.
        XCTAssertEqual(WalkDenseStreaming.cycleTimeMs(elapsedMs: 500, periodMs: 400), 60, accuracy: 1e-9)
        XCTAssertEqual(WalkDenseStreaming.cycleTimeMs(elapsedMs: 100, periodMs: 600), 100, accuracy: 1e-9)
    }

    /// 슬루 한계가 O2 `WalkLabTransport.h` SLEW_*_MAX 와 동일 — 패리티 회귀 가드.
    func testSlewConstantsMatchO2Parity() {
        XCTAssertEqual(WalkDenseStreaming.slewDxMaxMm, 8.0)
        XCTAssertEqual(WalkDenseStreaming.slewDyMaxMm, 6.0)
        XCTAssertEqual(WalkDenseStreaming.slewDaMaxDeg, 4.0)
        XCTAssertEqual(WalkDenseStreaming.slewDPeriodMaxMs, 60.0)
    }

    func testDenseConstants() {
        XCTAssertEqual(WalkDenseStreaming.denseStepMs, 20, "50Hz")
        XCTAssertEqual(WalkDenseStreaming.denseStepFallbackMs, 30, "진동 후퇴 33Hz")
        XCTAssertEqual(WalkDenseStreaming.denseMinPeriodMs, 440)
        XCTAssertEqual(WalkDenseStreaming.denseLivenessPingIntervalMs, 1000, "liveness 1Hz")
    }

    /// 기능 플래그 기본 off — 격리 suite 로 process-global 오염 회피.
    func testDenseStreamingFlagDefaultsOff() {
        let suite = "df.test.dense.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WalkDenseStreaming.denseStreamingEnabled(defaults), "기본 off")
        XCTAssertEqual(WalkDenseStreaming.effectiveStepMs(defaults), 20, "후퇴 플래그 미설정 → 20ms")
        defaults.set(true, forKey: WalkDenseStreaming.denseStepFallbackDefaultsKey)
        XCTAssertEqual(WalkDenseStreaming.effectiveStepMs(defaults), 30, "후퇴 플래그 → 30ms")
    }

    // MARK: - helpers

    private func tuning(stride: Double, side: Double, turn: Double, period: Double)
        -> WalkMotionLibrary.AdvancedTuning {
        WalkMotionLibrary.AdvancedTuning(
            strideMm: stride, sideMm: side, turnDeg: turn, periodMs: period,
            footHeightMm: 35, balanceGain: 1.0)
    }
}
