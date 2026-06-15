import Combine
import SwiftUI

// MARK: - ViewInspection (V276-3 ViewInspector Phase B 지원)
//
// ViewInspector 의 async/ViewHosting 패턴 (Approach #2) 에 필요한 Inspection 클래스.
// 본 파일은 DarwinForgeUI build target 에 포함 — `internal` 접근 수준으로 외부 모듈에 노출 안 됨.
// Test target 에서는 `extension Inspection: InspectionEmissary {}` 를 선언하여 활성화.
//
// 비유: 공장 내부의 "검사구" — 제품이 컨베이어 벨트(SwiftUI lifecycle)를 타고 있는 동안
// 특정 순간에 품질 검사관(test)이 제품(view)을 잠깐 멈추고 내부를 살펴볼 수 있게 해 주는 도구.
//
// 참고: ViewInspector guide.md §Approach #2
// https://github.com/nalexn/ViewInspector

// @unchecked Sendable: InspectionEmissary 프로토콜이 Sendable 요구.
// Inspection 은 @MainActor test 환경에서만 사용 — concurrent access 없음.
internal final class Inspection<V>: @unchecked Sendable {

    /// 검사 요청 신호 — line 번호를 전달해 어느 검사 포인트인지 식별.
    let notice = PassthroughSubject<UInt, Never>()

    /// line → callback 매핑. 한 번 호출되면 자동 제거 (single-shot).
    var callbacks = [UInt: (V) -> Void]()

    /// SwiftUI `onReceive` 에서 호출 — 해당 line 의 callback 을 실행하고 제거.
    func visit(_ view: V, _ line: UInt) {
        if let callback = callbacks.removeValue(forKey: line) {
            callback(view)
        }
    }
}
