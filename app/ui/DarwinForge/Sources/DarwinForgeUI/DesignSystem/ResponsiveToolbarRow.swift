import SwiftUI

/// 환경 `dfWindowWidth` 를 읽어 자식 view 에 `ResponsiveSize` 를 전달하는 wrapper.
///
/// 사용 — 페이지별 top toolbar 가 반응형으로 label / overflow 결정:
/// ```swift
/// ResponsiveToolbarRow { size in
///     HStack {
///         Button { ... } label: {
///             if size.isWide { Label("저장", systemImage: "tray") }
///             else { Image(systemName: "tray") }
///         }
///     }
/// }
/// ```
///
/// 기존 `dfResponsiveSize` 환경 값 사용도 가능하나, view-level 분기가 SwiftUI 의
/// view tree 무효화에 더 자연스러워서 explicit closure 패턴 제공.
public struct ResponsiveToolbarRow<Content: View>: View {
    @Environment(\.dfResponsiveSize) private var size
    @ViewBuilder public let content: (ResponsiveSize) -> Content

    public init(@ViewBuilder content: @escaping (ResponsiveSize) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(size)
    }
}
