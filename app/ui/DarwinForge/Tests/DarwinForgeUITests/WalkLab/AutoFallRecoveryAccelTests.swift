import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **ROBOTIS 공식 가속도계 기반 낙하 감지 유닛 테스트**.
///
/// # 검증 항목
/// - `detectFallFromAccel`: 380→.forward(page 10), 600→.backward(page 11), 500→nil
/// - `detectFallFromAccel`: 경계값 390/580 포함/미만/초과
/// - `isFallenAccelSustained`: 평균이 임계 초과 → direction
/// - `isFallenAccelSustained`: 혼합/중립 샘플 → nil (스파이크 억제)
/// - `isFallenAccelSustained`: 빈 배열 → nil
///
/// # 공식 근거
/// ROBOTIS-OP2 `StatusCheck.cpp:27-43`:
/// - `FALLEN_F_LIMIT = 390`: accelY < 390 → face-down (FORWARD → page 10)
/// - `FALLEN_B_LIMIT = 580`: accelY > 580 → face-up (BACKWARD → page 11)
/// ADC center = 512 (10-bit, ±128 LSB ≈ 1g 기준).
final class AutoFallRecoveryAccelTests: XCTestCase {

    // MARK: - detectFallFromAccel: 단일 샘플

    func testDetectFallFromAccel_forward_belowForwardLimit() {
        // 380 < 390 (FALLEN_F_LIMIT) → face-down → .forward → get-up page 10
        let result = AutoFallRecovery.detectFallFromAccel(accelYRaw: 380)
        XCTAssertEqual(result, .forward,
            "accelY=380 < 390(FALLEN_F_LIMIT) → face-down → .forward")
        XCTAssertEqual(result?.getUpPage, 10,
            "forward fall get-up 은 ROBOTIS 공식 page 10 ('f up')")
    }

    func testDetectFallFromAccel_backward_aboveBackwardLimit() {
        // 600 > 580 (FALLEN_B_LIMIT) → face-up → .backward → get-up page 11
        let result = AutoFallRecovery.detectFallFromAccel(accelYRaw: 600)
        XCTAssertEqual(result, .backward,
            "accelY=600 > 580(FALLEN_B_LIMIT) → face-up → .backward")
        XCTAssertEqual(result?.getUpPage, 11,
            "backward fall get-up 은 ROBOTIS 공식 page 11 ('b up')")
    }

    func testDetectFallFromAccel_standing_midrange() {
        // 500 — 512 중립 근방, 390..580 내부 → 직립
        let result = AutoFallRecovery.detectFallFromAccel(accelYRaw: 500)
        XCTAssertNil(result,
            "accelY=500 은 중립 구간(390..580) → 낙하 아님")
    }

    func testDetectFallFromAccel_neutral_center() {
        // 512 = ADC center (1g 직립)
        XCTAssertNil(AutoFallRecovery.detectFallFromAccel(accelYRaw: 512),
            "accelY=512 (ADC center, 직립) → nil")
    }

    // MARK: - detectFallFromAccel: 경계값 (ROBOTIS 공식 임계)

    func testDetectFallFromAccel_boundary_exactForwardLimit_notFallen() {
        // 390 는 포함 안 됨 (< 390 만 forward) → nil
        XCTAssertNil(AutoFallRecovery.detectFallFromAccel(accelYRaw: 390),
            "accelY=390 은 FALLEN_F_LIMIT 경계 — '< 390' 이므로 nil (포함 안 됨)")
    }

    func testDetectFallFromAccel_boundary_justBelowForwardLimit() {
        // 389 < 390 → .forward
        XCTAssertEqual(AutoFallRecovery.detectFallFromAccel(accelYRaw: 389), .forward,
            "accelY=389 < 390 → .forward")
    }

    func testDetectFallFromAccel_boundary_exactBackwardLimit_notFallen() {
        // 580 는 포함 안 됨 (> 580 만 backward) → nil
        XCTAssertNil(AutoFallRecovery.detectFallFromAccel(accelYRaw: 580),
            "accelY=580 은 FALLEN_B_LIMIT 경계 — '> 580' 이므로 nil (포함 안 됨)")
    }

    func testDetectFallFromAccel_boundary_justAboveBackwardLimit() {
        // 581 > 580 → .backward
        XCTAssertEqual(AutoFallRecovery.detectFallFromAccel(accelYRaw: 581), .backward,
            "accelY=581 > 580 → .backward")
    }

    func testDetectFallFromAccel_constants_match_limits() {
        // 상수 명시적 검증 — 코드 리팩토링 시 실수로 바뀌지 않도록.
        XCTAssertEqual(AutoFallRecovery.fallenAccelForwardLimit, 390,
            "FALLEN_F_LIMIT = 390 (ROBOTIS StatusCheck.cpp:27)")
        XCTAssertEqual(AutoFallRecovery.fallenAccelBackwardLimit, 580,
            "FALLEN_B_LIMIT = 580 (ROBOTIS StatusCheck.cpp:28)")
    }

    // MARK: - isFallenAccelSustained: 이동 평균 기반 감지

    func testIsFallenAccelSustained_allForward_returnsForward() {
        // 10개 샘플 모두 380 → 평균 380 < 390 → .forward
        let samples = Array(repeating: 380, count: 10)
        let result = AutoFallRecovery.isFallenAccelSustained(samples: samples)
        XCTAssertEqual(result, .forward,
            "10개 샘플 평균 380 < 390 → .forward")
    }

    func testIsFallenAccelSustained_allBackward_returnsBackward() {
        // 10개 샘플 모두 600 → 평균 600 > 580 → .backward
        let samples = Array(repeating: 600, count: 10)
        let result = AutoFallRecovery.isFallenAccelSustained(samples: samples)
        XCTAssertEqual(result, .backward,
            "10개 샘플 평균 600 > 580 → .backward")
    }

    func testIsFallenAccelSustained_allNeutral_returnsNil() {
        // 10개 샘플 모두 512 → 평균 512 → nil
        let samples = Array(repeating: 512, count: 10)
        XCTAssertNil(AutoFallRecovery.isFallenAccelSustained(samples: samples),
            "중립 샘플 평균 → nil")
    }

    func testIsFallenAccelSustained_spikeWithNeutral_returnsNil() {
        // 보행 중 순간 스파이크 억제: 1개 낮은값 + 29개 중립 → 평균은 중립 구간 내
        // 1 * 380 + 29 * 512 = 380 + 14848 = 15228. 15228/30 ≈ 507.6 → nil
        var samples = Array(repeating: 512, count: 29)
        samples.append(380)
        let result = AutoFallRecovery.isFallenAccelSustained(samples: samples)
        XCTAssertNil(result,
            "1개 스파이크 + 29개 중립: 평균 ≈ 507 → nil (스파이크 억제 동작 확인)")
    }

    func testIsFallenAccelSustained_mostlyFallen_returnsDirection() {
        // 25개 낙하값(380) + 5개 중립(512) → 평균 ≈ 403.6
        // 25*380 + 5*512 = 9500 + 2560 = 12060. 12060/30 = 402 < 390 → NO, wait:
        // 402 > 390, but < 390 is the trigger... let's use 300 for fallen samples
        // 25*300 + 5*512 = 7500 + 2560 = 10060. 10060/30 ≈ 335.3 < 390 → .forward
        var samples = Array(repeating: 300, count: 25)
        samples.append(contentsOf: Array(repeating: 512, count: 5))
        let result = AutoFallRecovery.isFallenAccelSustained(samples: samples)
        XCTAssertEqual(result, .forward,
            "대부분 낙하값(300) + 5개 중립: 평균 ≈ 335 < 390 → .forward")
    }

    func testIsFallenAccelSustained_singleSample_forward() {
        // 링 버퍼 초기 채움 구간 — 단일 샘플도 허용
        let result = AutoFallRecovery.isFallenAccelSustained(samples: [380])
        XCTAssertEqual(result, .forward,
            "단일 샘플 380 < 390 → .forward (초기 채움 구간 허용)")
    }

    func testIsFallenAccelSustained_empty_returnsNil() {
        // 빈 배열 → nil (연결 직후 초기 구간, 샘플 없음)
        XCTAssertNil(AutoFallRecovery.isFallenAccelSustained(samples: []),
            "빈 샘플 배열 → nil (초기 구간 오판 방지)")
    }

    func testIsFallenAccelSustained_averageCrossesBoundaryExactly_forwardNotTriggered() {
        // 평균이 정확히 390 → '< 390' 미충족 → nil
        // sum = 390 * n → avg = 390 → detectFallFromAccel(390) = nil
        let samples = Array(repeating: 390, count: 10)
        XCTAssertNil(AutoFallRecovery.isFallenAccelSustained(samples: samples),
            "평균 정확히 390 → '<390' 미충족 → nil (경계 정밀도)")
    }

    // MARK: - get-up page 확인 (이 테스트는 삭제하면 안 됨 — 안전 검증)

    func testAccelDetection_forwardAlwaysPage10() {
        let dir = AutoFallRecovery.detectFallFromAccel(accelYRaw: 200)
        XCTAssertEqual(dir?.getUpPage, 10,
            "가속도계 기반 forward 낙하도 동일하게 page 10 ('f up') 사용")
    }

    func testAccelDetection_backwardAlwaysPage11() {
        let dir = AutoFallRecovery.detectFallFromAccel(accelYRaw: 700)
        XCTAssertEqual(dir?.getUpPage, 11,
            "가속도계 기반 backward 낙하도 동일하게 page 11 ('b up') 사용")
    }

    func testAccelDetection_neverKickPages() {
        let fwd = AutoFallRecovery.detectFallFromAccel(accelYRaw: 200)
        let bwd = AutoFallRecovery.detectFallFromAccel(accelYRaw: 700)
        XCTAssertNotEqual(fwd?.getUpPage, 12, "kick page 12 절대 사용 금지")
        XCTAssertNotEqual(fwd?.getUpPage, 13, "kick page 13 절대 사용 금지")
        XCTAssertNotEqual(bwd?.getUpPage, 12, "kick page 12 절대 사용 금지")
        XCTAssertNotEqual(bwd?.getUpPage, 13, "kick page 13 절대 사용 금지")
    }
}

// MARK: - Monitor Gate Tests (WalkLabSession level)

/// **fall monitor gate 테스트** — bus 없음 / cradle / dxlPower off 조건.
@MainActor
final class AutoFallRecoveryMonitorGateTests: XCTestCase {

    /// WalkLabSession + ConnectionStore 기본 setup 헬퍼.
    private func makeSession(
        bus: (any BusInterface)? = nil,
        dxlPowerOn: Bool = true
    ) -> (session: WalkLabSession, store: ConnectionStore) {
        let session = WalkLabSession()
        let store = ConnectionStore()
        if let b = bus {
            store.bus = b
        }
        if dxlPowerOn {
            store._setDxlPowerState(true)
        }
        session.attach(store: store)
        return (session, store)
    }

    func testFallMonitorTick_dxlPowerOff_doesNotTrigger() {
        // DXL 전원 OFF → auto get-up 금지 (정비/충전 상태)
        let (session, store) = makeSession(bus: MockBus(), dxlPowerOn: false)
        _ = store  // strong ref

        // ring 에 낙하값 주입
        session.accelYRing = Array(repeating: 300, count: 20)  // 평균 300 < 390 → 낙하

        session.fallMonitorTick()

        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "DXL 전원 OFF 시 fall monitor 는 recovery 를 시작해서는 안 됨")
        XCTAssertNil(session.autoRecoveryTask,
            "DXL 전원 OFF 시 recovery task 가 spawn 되면 안 됨")
    }

    func testFallMonitorTick_cradleConfirmed_stillTriggers() {
        // **정책 변경 (2026-05-31 사용자 결정 "바닥 낙상이면 항상 일어나기")**:
        // cradle 모드는 더 이상 auto get-up 을 원천 차단하지 않는다 (GATE 3 제거).
        // 1차 안전 조건은 isFallenAccelSustained(명확한 바닥 낙상 가속도), 2차 안전장치는
        // runRecovery 의 waitForSettle(자이로 정지 대기) — 스탠드를 움직이는 중이면 settle
        // 대기로 getup 이 지연되어 안전. 따라서 명확한 낙상 가속도가 지속되면 cradle 여부와
        // 무관하게 recovery 가 시작돼야 한다.
        let (session, store) = makeSession(bus: MockBus(), dxlPowerOn: true)
        _ = store
        session.cradleConfirmed = true

        session.accelYRing = Array(repeating: 300, count: 20)

        session.fallMonitorTick()

        XCTAssertNotEqual(session.autoRecoveryPhase, .idle,
            "cradle 확인 상태라도 명확한 바닥 낙상이면 recovery 가 시작돼야 함 (settle 대기가 안전장치)")
    }

    func testFallMonitorTick_busNil_doesNotTrigger() {
        // bus 연결 없음 → 감지 불가
        let session = WalkLabSession()
        let store = ConnectionStore()
        store._setDxlPowerState(true)
        session.attach(store: store)  // bus = nil

        session.accelYRing = Array(repeating: 300, count: 20)

        session.fallMonitorTick()

        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "bus nil 상태에서 fall monitor 는 recovery 를 시작해서는 안 됨")
    }

    func testFallMonitorTick_enableAutoGetUpFalse_doesNotTrigger() {
        // enableAutoGetUp=false → 비활성
        let (session, store) = makeSession(bus: MockBus(), dxlPowerOn: true)
        _ = store
        session.enableAutoGetUp = false

        session.accelYRing = Array(repeating: 300, count: 20)

        session.fallMonitorTick()

        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "enableAutoGetUp=false 시 fall monitor 는 비활성")
    }

    func testFallMonitorTick_standingAccel_doesNotTrigger() {
        // 중립 가속도 (직립) → 낙하 아님
        let (session, store) = makeSession(bus: MockBus(), dxlPowerOn: true)
        _ = store

        session.accelYRing = Array(repeating: 512, count: 20)  // 중립

        session.fallMonitorTick()

        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "직립 accelY(512) → fall monitor 낙하 미감지")
    }

    func testFallMonitorTick_emptyRing_doesNotTrigger() {
        // 링 비어있음 (연결 직후) → 오판 방지
        let (session, store) = makeSession(bus: MockBus(), dxlPowerOn: true)
        _ = store
        session.accelYRing = []

        session.fallMonitorTick()

        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "빈 accelYRing → nil (초기 구간 오판 방지)")
    }

    func testFallMonitorTick_alreadyRecovering_doesNotSpawnDuplicate() {
        // 이미 진행 중 → 중복 spawn 금지
        let (session, store) = makeSession(bus: MockBus(), dxlPowerOn: true)
        _ = store

        // 기존 recovery 진행 중 시뮬레이션
        session.autoRecoveryPhase = .settling

        session.accelYRing = Array(repeating: 300, count: 20)

        session.fallMonitorTick()

        XCTAssertEqual(session.autoRecoveryPhase, .settling,
            "이미 settling 중 — phase 변경 없음 (중복 spawn 방지)")
    }

    func testFallMonitorAccelRingCapacity_capped() {
        // ring 이 30개 상한을 초과하면 앞에서 제거
        let (session, store) = makeSession()
        _ = store

        let many = Array(0..<50).map { _ in 512 }  // 50개 중립
        session.accelYRing = many
        // 강제로 initRing → fallMonitorTick 내부의 trim 로직 테스트
        // tick 에서 한 샘플 추가 후 trim 됨을 확인하려면 실제 ImuRaw 가 필요.
        // 여기서는 단순히 링 제한 상수만 검증.
        XCTAssertEqual(WalkLabSession.accelRingCapacity, 30,
            "accelY ring 최대 30 샘플 (ROBOTIS 공식 30-sample 평균 기반)")
    }

    // MARK: - Verify fallMonitorTimer starts on attach

    func testAttach_startsFallMonitor() {
        let session = WalkLabSession()
        XCTAssertNil(session.fallMonitorTimer,
            "attach 전에는 fallMonitorTimer nil")

        let store = ConnectionStore()
        session.attach(store: store)

        XCTAssertNotNil(session.fallMonitorTimer,
            "attach 후 fallMonitorTimer 가 생성됨")
    }

    func testStopFallMonitor_invalidatesTimer() {
        let (session, store) = makeSession()
        _ = store
        XCTAssertNotNil(session.fallMonitorTimer,
            "attach 후 timer 활성")

        session.stopFallMonitor()

        XCTAssertNil(session.fallMonitorTimer,
            "stopFallMonitor() 후 timer nil")
    }
}
