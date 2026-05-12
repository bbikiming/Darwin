import SwiftUI

/// 카메라 뷰 — v1.0 placeholder (비활성).
/// v1.5 에서 mjpg-streamer 연결 + AR HUD 활성화.
public struct PilotCameraView: View {
    public init() {}

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )

            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.25))
                Text("카메라 피드")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text("v1.5 — mjpg-streamer 셋업 후 활성")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .comingSoon(
            stage: "v1.5",
            title: "카메라 뷰",
            why: "robot-side mjpg-streamer 설정과 MJPEG 스트리밍 구현이 필요합니다.",
            when: "Sprint 17 (v1.5) — robot-side 셋업 가이드 완료 후",
            alternative: "원격 명령(⌘6) > 원격 도구 > Vision Tool에서 브라우저로 미리 볼 수 있습니다"
        )
    }
}
