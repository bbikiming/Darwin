import SwiftUI

/// 조명·머티리얼 튜닝 토글 버튼 + 패널(self-contained).
///
/// 모든 3D 화면이 공유하는 재사용 컴포넌트 — `ViewportControls`(Studio/Motion/Teach),
/// `WalkLabSceneSection`, `RemotePilotView` 가 각자 코너 오버레이로 배치. 토글 상태는
/// 자체 `@State`, 값 변경은 전역 `SceneTuning` 경유라 어느 화면에서 열어 조절해도
/// 모든 활성 3D 씬에 Combine 으로 반영된다.
///
/// 레이아웃: 버튼이 위, 패널은 열릴 때 아래로 펼쳐짐(top-trailing 배치 가정).
struct SceneTuningControl: View {
    @State private var show = false

    var body: some View {
        VStack(alignment: .trailing, spacing: DFSpace.xs) {
            Button {
                show.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(DFFont.caption.bold())
                    .foregroundStyle(show ? DFColor.accent : DFColor.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("조명·머티리얼 튜닝")

            if show {
                SceneTuningPanel(isPresented: $show)
            }
        }
    }
}
