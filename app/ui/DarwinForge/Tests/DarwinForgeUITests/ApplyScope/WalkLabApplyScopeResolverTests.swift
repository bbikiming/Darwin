import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.15.5 (2026-05-21) Phase 1.5 — Resolver 결정 logic 단위 테스트**.
///
/// 4 에이전트 합의 사항 검증:
/// - **C1 (code-reviewer)**: switch exhaustiveness — `default:` 없이 작성됐는지 (silent gap 차단)
/// - **C2 (code-reviewer)**: `WalkLabField.allCases × WalkingEngine.allCases` 완전 cover
/// - **H4 (test-engineer)**: balanceGain @ Onboard = .disabledOnboard 핵심 invariant
/// - **observeOnly 의 .previewOnly fallback** (test-engineer 권고)
final class WalkLabApplyScopeResolverTests: XCTestCase {

    // MARK: - HIGH priority (test-engineer)

    /// 핵심 invariant — verification 문서의 HIGH-risk gap.
    func testBalanceGainScopeIsDisabledOnboardWhenRobotisOnboard() {
        let scope = WalkLabApplyScopeResolver.scope(for: .balanceGain, engine: .robotisOnboard)
        XCTAssertEqual(scope, .disabledOnboard,
                       "balanceGain @ Onboard 는 펌웨어 미송신 (HIGH-risk) — disable 권장")
    }

    func testBalanceGainSentBothWhenMacSparse() {
        let scope = WalkLabApplyScopeResolver.scope(for: .balanceGain, engine: .macSparseKeyframe)
        XCTAssertEqual(scope, .sentBoth(timing: .debounced220),
                       "balanceGain @ Mac sparse 는 220ms 후 cycle 재시작")
    }

    /// **Completeness 강제** — 신규 field 또는 engine 추가 시 forgetting risk 방지.
    func testAllFieldsHaveScopeForBothEngines() {
        for field in WalkLabField.allCases {
            for engine in WalkingEngine.allCases {
                _ = WalkLabApplyScopeResolver.scope(for: field, engine: engine)
                // panic/crash 없이 반환되면 통과 — exhaustive switch invariant.
            }
        }
        // 도달 자체가 성공 — 모든 30+ 조합이 crash 없이 scope 결정.
        XCTAssertGreaterThan(WalkLabField.allCases.count * WalkingEngine.allCases.count, 30,
                             "30 이상 조합이 검증됨")
    }

    func testWalkLabFieldCaseCount() {
        // 신규 field 추가 시 이 테스트가 깨져서 Resolver 업데이트 강제.
        // verification §3 매트릭스 + meta toggle = 20 case.
        XCTAssertEqual(WalkLabField.allCases.count, 20,
                       "WalkLabField 신규 추가 시 Resolver 결정 logic 업데이트 + 이 카운트 갱신")
    }

    func testEngineSwitchUpdatesBalanceGainScope() {
        // 동일 field 가 engine 만 바뀌면 scope 가 다른지 — reactive update 가정의 토대.
        let macScope = WalkLabApplyScopeResolver.scope(for: .balanceGain, engine: .macSparseKeyframe)
        let onboardScope = WalkLabApplyScopeResolver.scope(for: .balanceGain, engine: .robotisOnboard)
        XCTAssertNotEqual(macScope, onboardScope, "engine 전환 시 scope 변경")
    }

    // MARK: - MEDIUM priority

    /// **observeOnly 처리 (test-engineer 권고)**: corrections 계산만 + pose 변경 X → previewOnly.
    func testObserveOnlyAlgorithmReturnsPreviewOnly() {
        let scope = WalkLabApplyScopeResolver.scopeForBalanceConfig(
            engine: .macSparseKeyframe,
            algorithmMode: .observeOnly
        )
        XCTAssertEqual(scope, .previewOnly,
                       "observeOnly 는 pose 변경 X → previewOnly")
    }

    func testOffAlgorithmReturnsPreviewOnly() {
        let scope = WalkLabApplyScopeResolver.scopeForBalanceConfig(
            engine: .macSparseKeyframe,
            algorithmMode: .off
        )
        XCTAssertEqual(scope, .previewOnly,
                       "off algorithm 도 pose 변경 X → previewOnly")
    }

    func testActiveAlgorithmReturnsRegularScope() {
        // active (hybridBA/robotisPControl) 일 때는 일반 scope 결정.
        let mac = WalkLabApplyScopeResolver.scopeForBalanceConfig(
            engine: .macSparseKeyframe, algorithmMode: .robotisPControl
        )
        XCTAssertEqual(mac, .sentBoth(timing: .debounced220))

        let onboard = WalkLabApplyScopeResolver.scopeForBalanceConfig(
            engine: .robotisOnboard, algorithmMode: .hybridBA
        )
        XCTAssertEqual(onboard, .macSparseOnly,
                       "hybridBA @ Onboard 는 macSparseOnly (pose 변경 있지만 펌웨어 미송신)")
    }

    /// preflight gate 류는 engine 무관하게 startGateOnly.
    func testCradleAndRiskAreStartGateOnly() {
        for engine in WalkingEngine.allCases {
            XCTAssertEqual(WalkLabApplyScopeResolver.scope(for: .cradleConfirmed, engine: engine),
                           .startGateOnly)
            XCTAssertEqual(WalkLabApplyScopeResolver.scope(for: .riskAcknowledged, engine: engine),
                           .startGateOnly)
        }
    }

    /// nextSession 류 — engine 무관.
    func testOperatorNoteAndComparisonTagAreNextSession() {
        for engine in WalkingEngine.allCases {
            XCTAssertEqual(WalkLabApplyScopeResolver.scope(for: .operatorNote, engine: engine),
                           .nextSession)
            XCTAssertEqual(WalkLabApplyScopeResolver.scope(for: .comparisonTag, engine: engine),
                           .nextSession)
        }
    }

    /// strideMm/sideMm/turnDeg 등 보행 기본 — 양쪽 엔진 모두 송신.
    func testWalkBasicsAreAlwaysSentBoth() {
        let basics: [WalkLabField] = [.strideMm, .sideMm, .turnDeg, .customPeriodMs,
                                      .footHeightMm, .hipPitchOffsetTrimDeg]
        for field in basics {
            for engine in WalkingEngine.allCases {
                let scope = WalkLabApplyScopeResolver.scope(for: field, engine: engine)
                if case .sentBoth = scope {
                    // OK
                } else {
                    XCTFail("\(field) @ \(engine) = \(scope) — sentBoth 기대")
                }
            }
        }
    }

    // MARK: - LOW priority

    /// 모든 scope 의 label / icon 이 비어있지 않은지.
    func testScopeBadgeLabelsAndIconsNonEmpty() {
        let allScopes: [WalkLabApplyScope] = [
            .sentBoth(timing: .immediate),
            .sentBoth(timing: .debounced220),
            .sentBoth(timing: .debounced300),
            .macSparseOnly,
            .previewOnly,
            .startGateOnly,
            .nextSession,
            .disabledOnboard,
        ]
        for scope in allScopes {
            XCTAssertFalse(scope.label.isEmpty, "\(scope) label 비어있음")
            XCTAssertFalse(scope.icon.isEmpty, "\(scope) icon 비어있음")
        }
    }

    /// scope 별 detailedMessage 가 의미있는 길이 (10자 이상) 또는 nil.
    func testScopeBadgeDetailedMessagesMeaningful() {
        let scopes: [WalkLabApplyScope] = [
            .sentBoth(timing: .debounced300),
            .macSparseOnly,
            .previewOnly,
            .startGateOnly,
            .nextSession,
            .disabledOnboard,
        ]
        for scope in scopes {
            if let msg = scope.detailedMessage {
                XCTAssertGreaterThan(msg.count, 10, "\(scope) message 너무 짧음")
            }
        }
    }

    /// SendTiming 의 label 가 unique.
    func testSendTimingLabelsAreUnique() {
        let labels = [
            SendTiming.immediate.label,
            SendTiming.debounced220.label,
            SendTiming.debounced300.label,
        ]
        XCTAssertEqual(Set(labels).count, labels.count,
                       "SendTiming 3 case 의 label 이 모두 다름")
    }

    /// WalkLabField 의 displayLabel 모두 unique.
    func testWalkLabFieldDisplayLabelsAreUnique() {
        let labels = WalkLabField.allCases.map { $0.displayLabel }
        XCTAssertEqual(Set(labels).count, labels.count,
                       "WalkLabField 의 displayLabel 충돌 없음")
    }
}
