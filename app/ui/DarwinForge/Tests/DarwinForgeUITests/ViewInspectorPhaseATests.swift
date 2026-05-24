import XCTest
import SwiftUI
import ViewInspector
@testable import DarwinForgeUI
@testable import ForgeCore

/// **V275-1 (2026-05-24) — ViewInspector Phase A 10 View 확대**.
///
/// V274-6 PoC (14 tests) 이 성공한 패턴을 10개 init-parameter-only View 로 확장.
/// 모든 대상 View 는 `@Environment` / `@State` / `ObservableObject` 없이
/// init 파라미터만으로 완전히 구성 가능하여 동기 `.inspect()` API 가 적용 가능.
///
/// # 비유
///
/// 자동차 부품 공장에서 "부품 하나씩 치수 검사" — 완제품 조립 전에 각 부품이
/// 규격대로 만들어졌는지 확인. 여기서 "규격 = View body 텍스트/구조 분기".
///
/// # 선정 기준
///
/// - 환경 의존 없거나 최소 (Phase B 후보 제외).
/// - init 파라미터로만 완전 구성 가능.
/// - body 에서 파라미터 기반 텍스트 분기가 있어 assertion 할 대상이 존재.
///
/// # 선정 10 View
///
/// 1. `DFStatusBadgeView`  — badge × style 분기
/// 2. `DFChip`             — text + style 분기
/// 3. `DFStatusPill`       — severity 라벨 분기
/// 4. `DFNoticeBanner`     — severity + title/message 분기
/// 5. `DFSourcePill`       — label + leading prefix 분기
/// 6. `DFKeyboardHint`     — 키 배열 분기
/// 7. `DFMetricRow`        — label + value 표시
/// 8. `DFStepIndicator`    — current step 분기
/// 9. `StabilityGauge`     — WalkStabilityResult 카테고리 분기
/// 10. `CircularGyroMeter` — tilt 수치 라벨 분기
///
/// # 제약
///
/// - additive: 기존 View source 일절 변경 없음.
/// - 환경 의존 View 발견 시 주석 처리 + 이유 기록.
/// - 각 test 는 정확히 하나의 행동을 검증.
@MainActor
final class ViewInspectorPhaseATests: XCTestCase {

    // MARK: - View 1: DFStatusBadgeView — badge × style 분기

    /// `.compact` style 에서 badge 의 한국어 라벨이 body 에 노출되어야 한다.
    func testDFStatusBadgeView_compact_appliedToRobot_body에_한국어라벨노출() throws {
        let view = DFStatusBadgeView(.appliedToRobot, style: .compact)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("실 로봇 적용됨"),
            "compact/appliedToRobot body 에 '실 로봇 적용됨' 라벨 없음. 실제: \(strings)"
        )
    }

    /// `.full` style 에서 badge 의 한국어 라벨이 body 에 노출되어야 한다.
    func testDFStatusBadgeView_full_simulationOnly_body에_한국어라벨노출() throws {
        let view = DFStatusBadgeView(.simulationOnly, style: .full)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("시뮬레이션"),
            "full/simulationOnly body 에 '시뮬레이션' 라벨 없음. 실제: \(strings)"
        )
    }

    /// `.compact` placeholder badge 가 'Placeholder' 라벨을 body 에 노출해야 한다.
    func testDFStatusBadgeView_compact_placeholder_body에_Placeholder라벨노출() throws {
        let view = DFStatusBadgeView(.placeholder, style: .compact)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("Placeholder"),
            "compact/placeholder body 에 'Placeholder' 라벨 없음. 실제: \(strings)"
        )
    }

    // MARK: - View 2: DFChip — text + style 분기

    /// DFChip 은 주어진 텍스트를 body 에 그대로 노출해야 한다.
    func testDFChip_text가_body에노출() throws {
        let view = DFChip("연결됨", style: .success)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("연결됨"),
            "DFChip body 에 '연결됨' 텍스트 없음. 실제: \(strings)"
        )
    }

    /// DFChip 은 icon 이 주어질 때 Image(systemName:) 노드를 포함해야 한다.
    func testDFChip_icon있을때_Image노드포함() throws {
        let view = DFChip("ARM", icon: "lock.open.fill", style: .success)
        let images = try view.inspect().findAll(ViewType.Image.self)
        XCTAssertFalse(images.isEmpty, "icon 포함 DFChip body 에 Image 노드가 없음")
    }

    /// DFChip 에 icon 이 없으면 Image 노드가 body 에 없어야 한다.
    func testDFChip_icon없을때_Image노드없음() throws {
        let view = DFChip("태그만", style: .neutral)
        let images = try view.inspect().findAll(ViewType.Image.self)
        XCTAssertTrue(images.isEmpty, "icon 없는 DFChip body 에 Image 노드가 존재함 (예상: 없음)")
    }

    // MARK: - View 3: DFStatusPill — severity 라벨 분기

    /// `.success` severity DFStatusPill 은 body 에 제공된 text 를 포함해야 한다.
    func testDFStatusPill_success_텍스트_body에노출() throws {
        let view = DFStatusPill("연결 정상", severity: .success)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains { $0.contains("연결 정상") },
            "DFStatusPill body 에 '연결 정상' 없음. 실제: \(strings)"
        )
    }

    /// `.danger` severity DFStatusPill 은 body 에 제공된 text 를 포함해야 한다.
    func testDFStatusPill_danger_텍스트_body에노출() throws {
        let view = DFStatusPill("낙상 위험", severity: .danger)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains { $0.contains("낙상 위험") },
            "DFStatusPill danger body 에 '낙상 위험' 없음. 실제: \(strings)"
        )
    }

    // MARK: - View 4: DFNoticeBanner — severity + title/message 분기

    /// DFNoticeBanner 는 title 텍스트를 body 에 노출해야 한다.
    func testDFNoticeBanner_title_body에노출() throws {
        let view = DFNoticeBanner("시뮬 모드 활성", severity: .info)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains { $0.contains("시뮬 모드 활성") },
            "DFNoticeBanner body 에 title '시뮬 모드 활성' 없음. 실제: \(strings)"
        )
    }

    /// DFNoticeBanner 에 message 를 제공하면 body 에 message 텍스트가 포함되어야 한다.
    func testDFNoticeBanner_message있을때_body에_message노출() throws {
        let view = DFNoticeBanner("주의",
                                  message: "로봇 연결을 확인하세요",
                                  severity: .warning)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains { $0.contains("로봇 연결을 확인하세요") },
            "DFNoticeBanner body 에 message 없음. 실제: \(strings)"
        )
    }

    // MARK: - View 5: DFSourcePill — label + leading prefix 분기

    /// leading 없이 DFSourcePill 을 만들면 label 만 body 에 노출되어야 한다.
    func testDFSourcePill_leading없이_label만_body에노출() throws {
        let view = DFSourcePill(label: "시뮬", tint: .gray)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("시뮬"),
            "DFSourcePill (leading 없음) body 에 '시뮬' 없음. 실제: \(strings)"
        )
    }

    /// leading 을 제공하면 DFSourcePill body 에 "leading label" 조합 텍스트가 노출되어야 한다.
    func testDFSourcePill_leading있을때_prefix포함_텍스트_body에노출() throws {
        let view = DFSourcePill(label: "실 IMU", tint: .green, leading: "IMU")
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains { $0.contains("IMU") && $0.contains("실 IMU") },
            "DFSourcePill (leading='IMU') body 에 'IMU 실 IMU' 조합 없음. 실제: \(strings)"
        )
    }

    // MARK: - View 6: DFKeyboardHint — 키 배열 body 노출

    /// DFKeyboardHint 는 초기화에 전달된 각 키 문자열을 body 에 노출해야 한다.
    func testDFKeyboardHint_단일키_body에노출() throws {
        let view = DFKeyboardHint("⌘K")
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("⌘K"),
            "DFKeyboardHint body 에 '⌘K' 없음. 실제: \(strings)"
        )
    }

    /// DFKeyboardHint 는 복수 키를 각각 body 에 노출해야 한다.
    func testDFKeyboardHint_복수키_모두_body에노출() throws {
        let view = DFKeyboardHint("⌘", "⇧", ".")
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(strings.contains("⌘"), "DFKeyboardHint body 에 '⌘' 없음. 실제: \(strings)")
        XCTAssertTrue(strings.contains("⇧"), "DFKeyboardHint body 에 '⇧' 없음. 실제: \(strings)")
        XCTAssertTrue(strings.contains("."), "DFKeyboardHint body 에 '.' 없음. 실제: \(strings)")
    }

    // MARK: - View 7: DFMetricRow — label + value 표시

    /// DFMetricRow 는 초기화에 전달된 label 텍스트를 body 에 노출해야 한다.
    func testDFMetricRow_label_body에노출() throws {
        let view = DFMetricRow("전압", "11.4V")
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("전압"),
            "DFMetricRow body 에 label '전압' 없음. 실제: \(strings)"
        )
    }

    /// DFMetricRow 는 초기화에 전달된 value 텍스트를 body 에 노출해야 한다.
    func testDFMetricRow_value_body에노출() throws {
        let view = DFMetricRow("온도", "53°C")
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }
        XCTAssertTrue(
            strings.contains("53°C"),
            "DFMetricRow body 에 value '53°C' 없음. 실제: \(strings)"
        )
    }

    // MARK: - View 8: DFStepIndicator — current step 분기

    /// DFStepIndicator 는 모든 step 라벨을 body 에 노출해야 한다.
    func testDFStepIndicator_모든_step라벨_body에노출() throws {
        let steps = ["연결", "설정", "완료"]
        let view = DFStepIndicator(steps, current: 0)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        for step in steps {
            XCTAssertTrue(
                strings.contains { $0.contains(step) },
                "DFStepIndicator body 에 step '\(step)' 없음. 실제: \(strings)"
            )
        }
    }

    /// DFStepIndicator 는 step 번호 텍스트를 body 에 포함해야 한다.
    func testDFStepIndicator_step번호_body에노출() throws {
        let steps = ["A", "B", "C"]
        let view = DFStepIndicator(steps, current: 1)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        // step 인덱스 번호 "1", "2", "3" 중 적어도 하나는 있어야 함.
        let hasNumberLabel = strings.contains { ["1", "2", "3"].contains($0) }
        XCTAssertTrue(hasNumberLabel,
                      "DFStepIndicator body 에 step 번호 없음. 실제: \(strings)")
    }

    // MARK: - View 9: StabilityGauge — WalkStabilityResult 카테고리 분기

    /// StabilityGauge 는 안전(safe) 결과일 때 '안전' 카테고리 라벨을 body 에 노출해야 한다.
    func testStabilityGauge_safe결과_안전_카테고리라벨_body에노출() throws {
        // WalkStabilityPredictor.evaluate 로 실제 결과 생성 (safe zone: score 0..30).
        let input = WalkStabilityInput(strideMm: 10, periodMs: 750)
        let result = WalkStabilityPredictor.evaluate(input)
        XCTAssertEqual(result.category, .safe, "사전조건: input이 safe category 를 생성해야 함")

        let view = StabilityGauge(result: result)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("안전") },
            "StabilityGauge (safe) body 에 '안전' 라벨 없음. 실제: \(strings)"
        )
    }

    /// StabilityGauge 는 위험(highRisk) 결과일 때 '위험' 카테고리 라벨을 body 에 노출해야 한다.
    func testStabilityGauge_highRisk결과_위험_카테고리라벨_body에노출() throws {
        // highRisk zone: 60..80. stride=35mm + period=450ms 조합으로 달성.
        let input = WalkStabilityInput(strideMm: 35, periodMs: 450, footHeightMm: 35)
        let result = WalkStabilityPredictor.evaluate(input)
        // highRisk 또는 critical 모두 "위험" 이상의 심각도 — 두 카테고리 모두 허용.
        let isHighOrCritical = result.category == .highRisk || result.category == .critical
        XCTAssertTrue(isHighOrCritical,
                      "사전조건: input이 highRisk 이상 category 를 생성해야 함. 실제: \(result.category)")

        let view = StabilityGauge(result: result)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        // highRisk = "위험", critical = "차단" — 둘 중 하나 있어야 함.
        let hasRiskLabel = strings.contains { $0.contains("위험") || $0.contains("차단") }
        XCTAssertTrue(hasRiskLabel,
                      "StabilityGauge (highRisk) body 에 '위험'/'차단' 라벨 없음. 실제: \(strings)")
    }

    /// StabilityGauge 는 낙상 위험 점수를 body 에 포함해야 한다.
    func testStabilityGauge_score_body에_점수노출() throws {
        let input = WalkStabilityInput(strideMm: 15, periodMs: 700)
        let result = WalkStabilityPredictor.evaluate(input)

        let view = StabilityGauge(result: result)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        // "낙상 위험 N / 100" 형태 텍스트가 있어야 함.
        let hasScore = strings.contains { $0.contains("낙상 위험") }
        XCTAssertTrue(hasScore,
                      "StabilityGauge body 에 점수 라벨('낙상 위험 N / 100') 없음. 실제: \(strings)")
    }

    // MARK: - View 10: CircularGyroMeter — tilt 수치 라벨 분기

    /// CircularGyroMeter 에 sourceLabel 을 제공하면 body 에 source 라벨이 노출되어야 한다.
    func testCircularGyroMeter_sourceLabel있을때_body에노출() throws {
        let view = CircularGyroMeter(
            rollDeg: 5.0,
            pitchDeg: -3.0,
            dangerThreshold: 50.0,
            sourceLabel: "실 IMU",
            sourceColor: .green
        )
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("실 IMU") },
            "CircularGyroMeter body 에 sourceLabel '실 IMU' 없음. 실제: \(strings)"
        )
    }

    /// CircularGyroMeter 에 sourceLabel 없이 생성하면 body 의 Text 에 source 라벨이 없어야 한다.
    func testCircularGyroMeter_sourceLabel없을때_source라벨_body에없음() throws {
        let view = CircularGyroMeter(rollDeg: 0.0, pitchDeg: 0.0)
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertFalse(
            strings.contains { $0.contains("실 IMU") || $0.contains("시뮬") || $0.contains("오래됨") },
            "sourceLabel 없이 생성한 CircularGyroMeter body 에 source 라벨이 있음. 실제: \(strings)"
        )
    }

    /// CircularGyroMeter 는 roll/pitch 수치 정보를 a11y value 또는 body 에 포함해야 한다.
    func testCircularGyroMeter_rollPitch_수치_body에포함() throws {
        let view = CircularGyroMeter(
            rollDeg: 12.0,
            pitchDeg: -8.0,
            dangerThreshold: 50.0
        )
        // ViewInspector 로 Text 추출 — CircularGyroMeter body 의 roll/pitch
        // 수치 라벨이 존재하는지 확인.
        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        // roll/pitch 라벨 또는 수치 표시 ("R", "P", "°", "12", "8" 등).
        let hasAngle = strings.contains { $0.contains("°") || $0.contains("R") || $0.contains("P") }
        XCTAssertTrue(
            hasAngle,
            "CircularGyroMeter body 에 roll/pitch 각도 표시 없음. 실제: \(strings)"
        )
    }
}
