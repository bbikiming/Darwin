import AppKit
import ForgeCore
import SceneKit
import XCTest
@testable import DarwinForgeUI

/// **W3 (2026-06-12)** — emission 채널 우선순위(§3-F): warn95 > warn85 > highlight > none.
///
/// highlight(선택 관절)와 한계 근접 경고가 같은 emission 채널을 공유하므로,
/// `RigSkeleton.setEmissionState` / `highlight` 가 우선순위대로 합성하는지 검증한다.
/// STL 비의존을 위해 항상 메시를 만드는 프리미티브 `DarwinOP2Rig` 로 테스트.
final class RigEmissionPriorityTests: XCTestCase {

    /// catalog 색(systemRed 등)은 component 접근 전 deviceRGB 변환 필수(아니면 크래시).
    private func rgb(_ c: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let conv = c?.usingColorSpace(.deviceRGB) else { return nil }
        return (conv.redComponent, conv.greenComponent, conv.blueComponent, conv.alphaComponent)
    }

    private func emission(_ rig: DarwinOP2Rig, _ joint: JointID) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let node = rig.jointAnchor(joint) else { return nil }
        var found: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)?
        node.enumerateHierarchy { n, stop in
            // 기본 emission 은 black(alpha 1) — 켜짐 판정은 알파가 아닌 휘도로.
            if let c = (n.geometry?.firstMaterial?.emission.contents as? NSColor),
               let t = self.rgb(c), (t.r + t.g + t.b) > 0.05 {
                found = t
                stop.pointee = true
            }
        }
        return found
    }

    @MainActor
    func testWarnOverridesHighlight() {
        let rig = DarwinOP2Rig()
        let j = JointID.lKnee

        // 초기: emission 없음.
        XCTAssertNil(emission(rig, j))

        // highlight → orange.
        rig.highlight(j)
        XCTAssertNotNil(emission(rig, j), "highlight 가 emission 을 켜지 않음")

        // warn95 가 highlight 를 덮어써야 함(빨강 — red 우세).
        rig.setEmissionState(j, .warn95)
        let warn = emission(rig, j)
        XCTAssertNotNil(warn)
        XCTAssertGreaterThan(warn!.r, 0.5, "warn95 가 빨강이 아님(highlight 우선 실패)")
        XCTAssertLessThan(warn!.b, 0.3)

        // warn 해제 → highlight 복귀(여전히 선택 상태).
        rig.setEmissionState(j, .none)
        XCTAssertNotNil(emission(rig, j), "warn 해제 후 highlight 가 복귀하지 않음")

        // highlight 해제 → 원래(emission off).
        rig.highlight(nil)
        XCTAssertNil(emission(rig, j), "highlight 해제 후 원래 색으로 복원되지 않음")
    }

    @MainActor
    func testWarn85And95DistinctFromHighlight() {
        let rig = DarwinOP2Rig()
        let j = JointID.rElbow
        rig.setEmissionState(j, .warn85)
        let amber = emission(rig, j)
        rig.setEmissionState(j, .warn95)
        let red = emission(rig, j)
        XCTAssertNotNil(amber)
        XCTAssertNotNil(red)
        // warn95(빨강)는 warn85(노랑)보다 green 성분이 작다.
        XCTAssertGreaterThan(red!.r, 0.5)
        XCTAssertLessThan(red!.g, amber!.g)
    }
}
