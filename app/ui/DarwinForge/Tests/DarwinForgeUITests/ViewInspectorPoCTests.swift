import XCTest
import SwiftUI
import ViewInspector
@testable import DarwinForgeUI

/// **V274-6 (2026-05-24) — ViewInspector PoC 2개** (V276-4 FallSeverity 6 test 분리).
///
/// 목적: ViewInspector 0.10.3 이 Swift 6.2 / macOS 14 대상 codebase 에서
/// 동작하는지 검증. 2가지 시나리오 (ViewInspector 실 사용):
///
/// 1. `FallPredictionCard` View body — 점수 4-tier 별 severity 아이콘/레이블 분기.
/// 2. `PilotHQStatusRow` View body — bridge.enabled 상태별 indicator 텍스트 분기.
///
/// (FallSeverity 순수 enum logic 6 test 는 `FallSeverityTests.swift` 로 이관 —
/// ViewInspector 미사용 test 가 PoC 검증에 inflation 이라는 V275-3 critic 권고.)
///
/// # 비유
///
/// 공장 조립라인 첫 테스트 — "기계가 볼트를 제대로 조이는가" 의 기초 smoke test.
/// 통과하면 122개 View 전체로 확대. 실패하면 대안 검토.
///
/// # PoC 제약
///
/// - `FallPredictionCard` / `PilotHQStatusRow` 는 init 파라미터로만 의존성을 받으므로
///   ViewInspector 의 synchronous `.inspect()` API 가 적용 가능.
/// - `WalkLabView` 는 `@Environment(WalkLabSession.self)` 의존 → ViewHosting async
///   패턴이 필요하며, 본 PoC 범위 밖 (별도 Phase).
@MainActor
final class ViewInspectorPoCTests: XCTestCase {

    // MARK: - PoC 1: FallPredictionCard ViewInspector — 점수 기반 severity 텍스트 노출

    /// FallPredictionCard 가 점수 10 (안정) 일 때 body 에 '안정' 텍스트를 포함해야 한다.
    func testFallPredictionCard_점수10_body에_안정_텍스트노출() throws {
        let prediction = FallPredictor.Prediction(
            score: 10,
            etaMs: nil,
            recommendEmergency: false
        )
        let card = FallPredictionCard(prediction: prediction, imuSource: nil)
        let inspected = try card.inspect()

        // body 전체에서 '안정' 텍스트가 존재하는지 검색.
        // ViewInspector findAll(ViewType.Text.self) 로 모든 Text 추출.
        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("안정"),
            "점수 10 FallPredictionCard body 에 '안정' 레이블이 있어야 한다. 실제: \(strings)"
        )
    }

    /// FallPredictionCard 가 점수 85 (위험) 일 때 body 에 '위험' 텍스트를 포함해야 한다.
    func testFallPredictionCard_점수85_body에_위험_텍스트노출() throws {
        let prediction = FallPredictor.Prediction(
            score: 85,
            etaMs: nil,
            recommendEmergency: false
        )
        let card = FallPredictionCard(prediction: prediction)
        let inspected = try card.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("위험"),
            "점수 85 FallPredictionCard body 에 '위험' 레이블이 있어야 한다. 실제: \(strings)"
        )
    }

    /// recommendEmergency=true 일 때 FallPredictionCard 가 '위험 임박' 텍스트를 노출해야 한다.
    func testFallPredictionCard_응급권고시_위험임박_텍스트노출() throws {
        let prediction = FallPredictor.Prediction(
            score: 90,
            etaMs: 200,
            recommendEmergency: true
        )
        let card = FallPredictionCard(prediction: prediction)
        let inspected = try card.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("위험 임박"),
            "recommendEmergency=true 시 '위험 임박' 텍스트가 있어야 한다. 실제: \(strings)"
        )
    }

    /// ETA 있을 때 FallPredictionCard body 에 'ETA' prefix 텍스트가 포함되어야 한다.
    func testFallPredictionCard_ETA_있을때_ETA_텍스트노출() throws {
        let prediction = FallPredictor.Prediction(
            score: 55,
            etaMs: 1500,
            recommendEmergency: false
        )
        let card = FallPredictionCard(prediction: prediction)
        let inspected = try card.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        let hasETA = strings.contains { $0.hasPrefix("ETA") }
        XCTAssertTrue(hasETA, "etaMs=1500 시 ETA 레이블이 있어야 한다. 실제: \(strings)")
    }

    // MARK: - PoC 2: PilotHQStatusRow ViewInspector — bridge enabled 상태 분기

    /// bridge.enabled=true 일 때 PilotHQStatusRow 가 '활성' 텍스트를 포함해야 한다.
    func testPilotHQStatusRow_bridge활성시_활성_텍스트노출() throws {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        bridge.enabled = true

        let row = PilotHQStatusRow(bridge: bridge, session: session)
        let inspected = try row.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("활성"),
            "bridge.enabled=true 시 '활성' 텍스트가 있어야 한다. 실제: \(strings)"
        )
    }

    /// bridge.enabled=false 일 때 PilotHQStatusRow 가 '비활성' 텍스트를 포함해야 한다.
    func testPilotHQStatusRow_bridge비활성시_비활성_텍스트노출() throws {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        bridge.enabled = false

        let row = PilotHQStatusRow(bridge: bridge, session: session)
        let inspected = try row.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("비활성"),
            "bridge.enabled=false 시 '비활성' 텍스트가 있어야 한다. 실제: \(strings)"
        )
    }

    /// emergencyStopActive=false (정상) 일 때 PilotHQStatusRow 가 '정상' 텍스트를 포함해야 한다.
    func testPilotHQStatusRow_정상상태_정상_텍스트노출() throws {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)

        // WalkLabSession.emergencyStopActive 는 internal(set) — @testable import 로 접근 가능.
        // 초기값 false (정상 baseline).
        XCTAssertFalse(session.emergencyStopActive, "사전조건: 초기 상태는 정상")

        let row = PilotHQStatusRow(bridge: bridge, session: session)
        let inspected = try row.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("정상"),
            "emergencyStopActive=false 시 '정상' 텍스트가 있어야 한다. 실제: \(strings)"
        )
    }

    /// bridge.lastIntent=nil (대기) 일 때 PilotHQStatusRow 가 '대기' 텍스트를 포함해야 한다.
    func testPilotHQStatusRow_의도없을때_대기_텍스트노출() throws {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)
        // bridge.lastIntent 초기값 nil — 아무 intent 발화 안 한 상태.

        let row = PilotHQStatusRow(bridge: bridge, session: session)
        let inspected = try row.inspect()

        let allTexts = try inspected.findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("대기"),
            "lastIntent=nil 시 '대기' 텍스트가 있어야 한다. 실제: \(strings)"
        )
    }
}
