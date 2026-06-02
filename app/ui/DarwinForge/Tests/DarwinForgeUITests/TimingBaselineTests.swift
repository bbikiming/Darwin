/// **사이클 265 (V265-1) — ADR-002 timing baseline 인프라**.
///
/// 검증 III critic 3차 발견 대응: ADR-002 의 "actor 추출 phase 진입 전 50Hz baseline
/// 측정 필수" gate 를 napkin math 가 아닌 실측 envelope 으로 충족.
///
/// # 비유
///
/// 비행기 fly-by-wire 의 sensor latency 측정에 stopwatch 를 끼우는 것과 같다.
/// `measure {}` block 은 다중 iteration 의 wall-clock time 분포를 자동 계산 →
/// regression smoke (envelope 가 N 배 늘면 즉시 발견).
///
/// # 측정 대상
///
/// | Method | Phase | 의의 |
/// |--------|-------|------|
/// | `_testForceTick(rollDeg:pitchDeg:)` | `tickRunSafetyPipeline` 만 호출 | W2.10 분해된 safety pipeline 의 envelope |
/// | `tick()` 전체 | 6 phase facade | W2.10 분해 전후 비교용 |
///
/// # 한계 (반드시 인지)
///
/// 1. **CI absolute number 불안정**: GitHub Actions / Xcode Cloud 의 CPU 부하 / thermal
///    throttling 으로 absolute timing 은 ± 50% 변동 가능. 본 measure 는 envelope smoke 용.
/// 2. **P50/P95/P99 별도 산출 X**: `XCTest.measure {}` 는 average + stddev. P99 같은
///    tail percentile 은 Instruments 의 `os_signpost` capture 가 권한.
/// 3. **ADR-002 의 5ms threshold gate**: `docs/architecture/timing-baseline.md` 의
///    Instruments 수동 측정 절차가 진본. 본 test 는 CI smoke 보조.
///
/// # 향후 (W4.1.4 / W4.2.3 진입 전)
///
/// 1. Release build + Instruments capture (위 docs 참조).
/// 2. baseline P50/P95/P99 → `docs/architecture/baselines/walk_tick_<date>.json`.
/// 3. actor 추출 후 동일 measurement → P99 < 5ms 확인.
/// 4. 본 measure tests 의 absolute envelope 비교 (sanity check).
// V288-5: `#if DEBUG` wrap — _testForceTick 는 DEBUG-only.
#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

@MainActor
final class TimingBaselineTests: XCTestCase {

    // MARK: - WalkLabSession tick() pipeline envelope

    /// **`tick()` 6 phase facade — full pipeline envelope**.
    ///
    /// 사이클 116 (W2.10) 의 god method 분해 (169줄 → 6 helper) 후 dispatch overhead
    /// 가 simTimer 10Hz tick budget (100ms) 안에 머무르는지 smoke 검증.
    ///
    /// **방식**:
    /// - store=nil 환경에서 `_testForceTick(rollDeg:pitchDeg:)` 호출 (sim IMU 경로).
    /// - safety pipeline (L0/L3/L4) 만 실행 — bus polling / engine.tick 우회.
    /// - 1000 iteration 의 wall-clock envelope 측정.
    ///
    /// **expected envelope**: 1000 iter 의 평균 < 100ms (= 100µs/iter 안전 마진).
    /// 실측은 macOS dev machine 에서 ~10-50µs/iter 예상 (XCTest measure stddev 포함).
    func testTickSafetyPipelineEnvelope() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        measure {
            for _ in 0..<1000 {
                // 정상 tilt (0°) — L3 hard gate counter 증가 X, emergency 미발화 path.
                session._testForceTick(rollDeg: 0, pitchDeg: 0)
            }
        }
    }

    /// **L3 hard gate triggered path — emergency 발화 시 분기 envelope**.
    ///
    /// 정상 path (0° tilt) 와 비교해서 emergency 발화 분기의 추가 비용 measurement.
    /// `logSafetyEvent` + `emergencyStop(trigger:)` 의 dispatch 가 envelope 안에 머무는지.
    ///
    /// **방식**: 3 연속 55° → L3 gate 충족 → emergency 발화 → counter reset → 반복.
    /// 매 3 iter 마다 emergency cycle.
    func testTickL3EmergencyPathEnvelope() {
        measure {
            // 매 iteration 마다 새 session — emergencyStop 후 state pollution 회피.
            let session = WalkLabSession()
            session.cradleConfirmed = true
            for _ in 0..<100 {
                session._testForceTick(rollDeg: 55, pitchDeg: 0)
                session._testForceTick(rollDeg: 55, pitchDeg: 0)
                session._testForceTick(rollDeg: 55, pitchDeg: 0)
            }
        }
    }

    // MARK: - ConnectionStore helper dispatch envelope (W2.12)

    /// **`ConnectionStore` 인스턴스화 envelope**.
    ///
    /// W2.12 의 runImuLoop 분해는 async loop 안에 있어 직접 measure 어려움. 본 test 는
    /// store 의 instantiation cost 가 envelope 안에 머무는지 smoke — `imuLoopReadOnce` /
    /// `imuLoopHandleSuccess` 같은 helper 의 dispatch overhead 는 `runImuLoop` 안에서
    /// 직접 호출되어 micro-benchmark 어려움 (bus / Task.detached 의존).
    ///
    /// **CI smoke 의도**: store 생성 비용 envelope 가 polynomial 하게 늘어나면 (Wave 4
    /// 진행 중 의존성 증가로) 즉시 발견.
    func testConnectionStoreInstantiationEnvelope() {
        measure {
            for _ in 0..<100 {
                _ = ConnectionStore()
            }
        }
    }
}
#endif
