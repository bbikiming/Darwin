import SwiftUI

/// 카메라 미리보기 — v1.0: 회색 placeholder + "v1.5 활성" 배지 (PRD §3 우측 패널 A).
/// v1.5: MJPEG snapshot + AR HUD overlay.
public struct PilotCameraView: View {
    let flags: PilotFeatureFlags
    @State private var showSetupSheet: Bool = false

    public init(flags: PilotFeatureFlags) {
        self.flags = flags
    }

    public var body: some View {
        DFPanel(
            "카메라 (AR HUD)",
            subtitle: flags.camera ? "MJPEG snapshot — 폴링 중" : "v1.5 에서 활성 — 로봇 측 mjpg-streamer 셋업 필요",
            icon: flags.camera ? "video.fill" : "video.slash",
            tint: flags.camera ? DFColor.success : PilotColor.comingSoon,
            trailing: {
                DFChip(
                    flags.camera ? "v1.5 활성" : "v1.5 예정",
                    icon: flags.camera ? "checkmark.seal.fill" : "lock.fill",
                    style: flags.camera ? .success : .warning
                )
            }
        ) {
            ZStack {
                // 16:9 검은 캔버스 (실제 mjpeg 가 들어올 자리).
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .fill(LinearGradient(
                        colors: [DFColor.elev2, DFColor.canvas],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: 0.5)
                    )

                if flags.camera {
                    cameraActiveOverlay
                } else {
                    cameraPlaceholderOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 160)
        }
        .sheet(isPresented: $showSetupSheet) { setupSheet }
    }

    @ViewBuilder
    private var cameraActiveOverlay: some View {
        VStack(spacing: DFSpace.sm) {
            Image(systemName: "video.fill")
                .font(.system(size: DFFontSize.s32))
                .foregroundStyle(DFColor.success)
            Text("카메라 활성")
                .font(DFFont.bodyEmph)
            Text("MJPEG snapshot 폴링 중…")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    @ViewBuilder
    private var cameraPlaceholderOverlay: some View {
        VStack(spacing: DFSpace.sm2) {
            Image(systemName: "video.slash")
                .font(.system(size: DFFontSize.s32, weight: .light))
                .foregroundStyle(DFColor.textSecondary)
            Text("카메라 미연결")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.textSecondary)
            Text("v1.5 에서 활성 — 로봇 측 mjpg-streamer 셋업 필요")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o70))
                .multilineTextAlignment(.center)
                .padding(.horizontal, DFSpace.md)
            DFButton(.secondary, size: .small) {
                showSetupSheet = true
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "doc.text")
                    Text("로봇 셋업 가이드")
                }
            }
        }
    }

    @ViewBuilder
    private var setupSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack {
                Image(systemName: "doc.text.fill").foregroundStyle(DFColor.accent)
                Text("로봇 측 카메라 셋업").font(DFFont.title)
                Spacer()
                Button("닫기") { showSetupSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            Text("v1.5 활성 조건 — 로봇에서 mjpg-streamer + forge-bridge socat 설치.")
                .font(DFFont.body)
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                Label("Sprint 17 의 robot-side 가이드 — docs/handoff/teleop-robot-setup.md",
                      systemImage: "doc")
                Label("RemoteShell QuickAction vision-start 가 자동화 예정",
                      systemImage: "terminal")
                Label("mjpg-streamer: BSD-2-Clause 라이선스 (OQ-6 확인)",
                      systemImage: "checkmark.seal")
            }
            .font(DFFont.body)
            .foregroundStyle(DFColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(DFSpace.lg)
        .frame(width: 560, height: 320)
    }
}
