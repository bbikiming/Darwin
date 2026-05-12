import SwiftUI

/// "준비 중" 오버레이 설정.
public struct ComingSoonConfig {
    public let stage: String       // 예: "v1.1", "v1.5", "v2"
    public let title: String
    public let why: String
    public let when: String
    public let alternative: String?

    public init(stage: String, title: String, why: String, when: String, alternative: String? = nil) {
        self.stage = stage
        self.title = title
        self.why = why
        self.when = when
        self.alternative = alternative
    }
}

/// "준비 중" 배지 + 탭 시 sheet 안내 ViewModifier.
struct ComingSoonModifier: ViewModifier {
    let config: ComingSoonConfig
    @State private var sheetOpen = false

    func body(content: Content) -> some View {
        content
            .disabled(true)
            .overlay(alignment: .topTrailing) {
                Button {
                    sheetOpen = true
                } label: {
                    Text("\(config.stage) 활성")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(PilotColor.caution)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(PilotColor.comingSoon)
            )
            .sheet(isPresented: $sheetOpen) {
                comingSoonSheet
            }
    }

    private var comingSoonSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(config.title)
                    .font(.title2.bold())
                Spacer()
                Button("닫기") { sheetOpen = false }
                    .buttonStyle(.bordered)
            }
            Label("활성 시점: \(config.stage)", systemImage: "clock.badge")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            Text("왜 아직 비활성인가요?")
                .font(.headline)
            Text(config.why)
                .font(.body)
            Text("언제 활성화되나요?")
                .font(.headline)
            Text(config.when)
                .font(.body)
            if let alt = config.alternative {
                Text("지금 사용할 수 있는 대안:")
                    .font(.headline)
                Text(alt)
                    .font(.body)
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 380, minHeight: 280)
    }
}

extension View {
    /// 비활성 기능에 "준비 중" 오버레이를 추가한다.
    public func comingSoon(
        stage: String,
        title: String,
        why: String,
        when: String,
        alternative: String? = nil
    ) -> some View {
        modifier(ComingSoonModifier(config: ComingSoonConfig(
            stage: stage, title: title, why: why, when: when, alternative: alternative
        )))
    }
}
