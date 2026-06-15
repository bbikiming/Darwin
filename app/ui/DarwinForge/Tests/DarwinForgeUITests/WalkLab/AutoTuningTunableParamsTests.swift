import XCTest
@testable import DarwinForgeUI

/// **데이터 기반 자동 튜닝 (2026-05-30)**: 안정성 파라미터(baseline tau · 자이로 D항)
/// 튜닝 가능화 — plumbing 검증.
///
/// # Coverage (7 tests)
/// 1. makeCorrector 가 base(gainProfile) 의 derivativeTimeSec 전달 — **잠복 버그 수정**:
///    종전 makeCorrector 는 init 에 derivativeTimeSec 미전달 → init 기본 0.05 silent 사용.
///    robotisOriginal 의 강화된 0.12 가 실 corrector 에 도달하지 못했음.
/// 2. makeCorrector derivativeTimeSec override (튜닝값 주입).
/// 3. makeCorrector P-only override (0.0 → rate 무시 안전 fallback).
/// 4. 세션 기본값: baselineTauSec=5.0, derivativeTimeSec=0.12 (회귀 0).
/// 4b. 세션 초기 corrector 가 0.12 D항 보유 (init makeCorrector 전달 확인).
/// 5. 세션 derivativeTimeSec 변경 → corrector 재빌드 (튜닝값이 live corrector 반영, C1).
/// 5b. baselineTauSec 변경 저장 확인 (직접 read 경로).
@MainActor
final class AutoTuningTunableParamsTests: XCTestCase {

    // MARK: - makeCorrector D-term forwarding (잠복 버그 수정)

    /// 1. nil → base.derivativeTimeSec (robotisOriginal=0.12) 전달.
    func test_makeCorrector_forwardsBaseDerivativeTimeSec() {
        let c = WalkLabSession.makeCorrector(level: 2, gainProfile: .robotisOriginal)
        XCTAssertEqual(c.derivativeTimeSec, 0.12, accuracy: 1e-12,
            "makeCorrector must forward robotisOriginal.derivativeTimeSec (0.12), not init default 0.05")
    }

    /// 2. explicit override → 그 값.
    func test_makeCorrector_overridesDerivativeTimeSec() {
        let c = WalkLabSession.makeCorrector(level: 2, gainProfile: .robotisOriginal,
                                             derivativeTimeSec: 0.20)
        XCTAssertEqual(c.derivativeTimeSec, 0.20, accuracy: 1e-12,
            "explicit derivativeTimeSec must override base profile value")
    }

    /// 3. 0.0 → P-only (rate 무시) 안전 fallback.
    func test_makeCorrector_pOnlyOverride() {
        let c = WalkLabSession.makeCorrector(level: 2, derivativeTimeSec: 0.0)
        XCTAssertEqual(c.derivativeTimeSec, 0.0, accuracy: 1e-12,
            "derivativeTimeSec=0 must yield pure-P corrector (safe fallback)")
    }

    /// 3b. (MEDIUM-1 리뷰) 극단 D항 → 모델 상한 0.5 로 구조적 클램프.
    func test_makeCorrector_clampsExtremeDTerm() {
        let c = WalkLabSession.makeCorrector(level: 2, derivativeTimeSec: 1.0)
        XCTAssertEqual(c.derivativeTimeSec, 0.5, accuracy: 1e-12,
            "극단 D항은 BalanceCorrector.init 상한 0.5 로 클램프 (모델 계층 불변식)")
    }

    // MARK: - Session tunable defaults (회귀 0)

    /// 4. 세션 기본값 = 종전 값.
    func test_session_defaultTunables() {
        let session = WalkLabSession()
        XCTAssertEqual(session.baselineTauSec, 5.0, accuracy: 1e-12,
            "baselineTauSec default must be 5.0 (regression guard)")
        XCTAssertEqual(session.derivativeTimeSec, 0.12, accuracy: 1e-12,
            "derivativeTimeSec default must be 0.12 (strengthened D-term, regression guard)")
    }

    /// 4b. 세션 초기 corrector 가 0.12 D항 보유 (init makeCorrector 전달 확인).
    func test_session_initialCorrectorHasStrengthenedDTerm() {
        let session = WalkLabSession()
        XCTAssertEqual(session.balanceCorrector.derivativeTimeSec, 0.12, accuracy: 1e-12,
            "live corrector built at init must carry 0.12 D-term (latent bug fix)")
    }

    // MARK: - Session derivativeTimeSec didSet rebuilds corrector (C1)

    /// 5. derivativeTimeSec 변경 → corrector 재빌드, 튜닝값 반영.
    func test_session_derivativeTimeSecChange_rebuildsCorrector() {
        let session = WalkLabSession()
        session.derivativeTimeSec = 0.18
        XCTAssertEqual(session.balanceCorrector.derivativeTimeSec, 0.18, accuracy: 1e-12,
            "changing session.derivativeTimeSec must rebuild corrector with new D-term (reaches live motor path)")
    }

    /// 5b. baselineTauSec 변경 저장 확인 (직접 read 경로 — corrector 무관).
    func test_session_baselineTauSecChange_stored() {
        let session = WalkLabSession()
        session.baselineTauSec = 3.0
        XCTAssertEqual(session.baselineTauSec, 3.0, accuracy: 1e-12,
            "baselineTauSec must be a tunable stored property")
    }
}
