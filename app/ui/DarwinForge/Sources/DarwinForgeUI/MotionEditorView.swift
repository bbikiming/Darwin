import SwiftUI

/// 모션 편집 뷰 — Sprint 4 스켈레톤.
/// 실 구현은 forge-core::motion + FFI (Sprint 4 후속) 후 채워짐.
public struct MotionEditorView: View {
    @State private var selectedPage: Int = 1
    @State private var pages: [MotionPageStub] = MotionPageStub.samples

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(pages, selection: $selectedPage) { page in
                Text("\(page.id). \(page.name)")
                    .tag(page.id)
            }
            .navigationTitle("Motions")
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Motion Editor — Sprint 4 스켈레톤")
                    .font(.title2.bold())
                Text("forge-core::motion::timeline + library를 FFI로 임포트하면 키프레임 타임라인 편집 UI가 여기 채워집니다.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
        }
    }
}

struct MotionPageStub: Identifiable, Hashable {
    let id: Int
    let name: String

    static let samples: [MotionPageStub] = [
        .init(id: 1, name: "Stand Up"),
        .init(id: 2, name: "Wave"),
    ]
}
