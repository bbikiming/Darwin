import XCTest
@testable import DarwinForgeUI

/// 사이클 178 (P0 #3.3 fix, cycle 177 audit): Pilot 의 `MotionCatalog` 와 OfficialCatalogReference
/// 의 shared slot ID 의 safety classification 일관성 검증.
///
/// # 비유
///
/// 한 회사 의 두 부서가 같은 직원 (slot ID) 의 "위험도" 를 다르게 평가하면 안 됨.
/// 두 카탈로그가 같은 slot ID 에 대해 일치하는 safety class 를 가져야 사용자 혼란 차단.
///
/// # 검증
///
/// 1. Pilot 의 slot 12, 13 (Right/Left Kick) — OfficialCatalogReference.allHighRiskIDs 에 포함.
/// 2. Pilot 의 slot 10, 11 (Get Up Front/Back) — placeholderCautionIDs 에 포함.
/// 3. Pilot 이 [placeholder] prefix 가진 slot 은 OfficialCatalogReference.placeholderIDs 에 포함.
/// 4. Pilot 이 safety .highRisk 인 slot 은 OfficialCatalogReference.allHighRiskIDs 에 포함.
final class PilotMotionCatalogConsistencyTests: XCTestCase {

    /// **유기 검증 #1**: Pilot 의 highRisk safety class 인 slot 이 OfficialCatalogReference 의
    /// allHighRiskIDs (highRisk ∪ placeholderHighRisk) 에 포함.
    func testPilotHighRiskMatchesOfficialCatalog() {
        for m in MotionCatalog.all where m.safetyClass == .highRisk {
            let slot = Int(m.slot)
            XCTAssertTrue(OfficialCatalogReference.allHighRiskIDs.contains(slot),
                          "Pilot \(m.displayName) (slot=\(slot)) safety=highRisk 인데 " +
                          "OfficialCatalogReference.allHighRiskIDs 에 없음")
        }
    }

    /// **유기 검증 #2**: Pilot 의 caution safety class slot 이 OfficialCatalogReference 의
    /// placeholderCautionIDs (Get Up 등) 에 포함.
    func testPilotCautionMatchesOfficialCatalog() {
        for m in MotionCatalog.all where m.safetyClass == .caution {
            let slot = Int(m.slot)
            XCTAssertTrue(OfficialCatalogReference.placeholderCautionIDs.contains(slot),
                          "Pilot \(m.displayName) (slot=\(slot)) safety=caution 인데 " +
                          "OfficialCatalogReference.placeholderCautionIDs 에 없음")
        }
    }

    /// **유기 검증 #3**: Pilot displayName 에 [placeholder] prefix 있는 slot 은
    /// OfficialCatalogReference.placeholderIDs 에 포함.
    func testPilotPlaceholderPrefixMatchesOfficial() {
        for m in MotionCatalog.all where m.displayName.contains("[placeholder]") {
            let slot = Int(m.slot)
            XCTAssertTrue(OfficialCatalogReference.placeholderIDs.contains(slot),
                          "Pilot \(m.displayName) (slot=\(slot)) [placeholder] prefix 있는데 " +
                          "OfficialCatalogReference.placeholderIDs 에 없음")
        }
    }

    /// **유기 검증 #4**: Pilot 의 모든 placeholder slot (OfficialCatalogReference 와 매핑)
    /// displayName + displayNameKo 모두 [placeholder] prefix.
    func testPilotPlaceholderPrefixOnSharedSlotsBoth() {
        let pilotPlaceholderSlots = OfficialCatalogReference.placeholderIDs
        for m in MotionCatalog.all {
            let slot = Int(m.slot)
            if pilotPlaceholderSlots.contains(slot) {
                XCTAssertTrue(m.displayName.contains("[placeholder]"),
                              "Pilot slot=\(slot) 의 displayName 가 placeholder prefix 없음: " +
                              "\(m.displayName)")
                XCTAssertTrue(m.displayNameKo.contains("[placeholder]"),
                              "Pilot slot=\(slot) 의 displayNameKo 가 placeholder prefix 없음: " +
                              "\(m.displayNameKo)")
            }
        }
    }

    /// **유기 검증 #5**: Pilot 의 non-placeholder slot 은 displayName 에 [placeholder]
    /// prefix 없음 (false positive 차단).
    func testPilotNonPlaceholderSlotsHaveNoPrefix() {
        let placeholderSlots = OfficialCatalogReference.placeholderIDs
        for m in MotionCatalog.all where !placeholderSlots.contains(Int(m.slot)) {
            XCTAssertFalse(m.displayName.contains("[placeholder]"),
                           "Pilot slot=\(m.slot) 는 placeholder 아닌데 prefix 있음: " +
                           "\(m.displayName)")
        }
    }

    /// **유기 검증 #6**: 두 카탈로그의 ID intersection 이 비어있지 않음 (실 중복 있음 확인).
    func testCatalogsHaveOverlappingIDs() {
        let pilotSlots = Set(MotionCatalog.all.map { Int($0.slot) })
        let officialSlots = OfficialCatalogReference.allOfficialIDs
        let intersection = pilotSlots.intersection(officialSlots)
        XCTAssertFalse(intersection.isEmpty,
                       "Pilot 와 OfficialCatalogReference 가 공통 ID 없음 — 검증 의미 X")
        XCTAssertGreaterThanOrEqual(intersection.count, 10,
                                     "최소 10개 공통 ID — 실 중복 검증 유의미. 실측 = \(intersection.count)")
    }
}
