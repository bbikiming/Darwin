//  SynthPaletteView.swift — Sprint 11 메인 View.
//
//  3-pane drag-and-drop UI:
//    [Library Panel]  →  [Canvas Panel]  →  [Inspector Panel]
//      카탈로그 페이지        합성 캔버스          파라미터 + validator overlay
//
//  RootView 통합은 별도. 사용자가 명시적으로 SynthPaletteView 를 navigation
//  destination 또는 sheet 으로 호출.
//
//  V281-2 (2026-05-24): 첫 진입 onboarding banner (DFBanner .info).
//    - @AppStorage("df.synth.onboardingShown") 로 1회만 노출.
//    - 사용자 "이해했어요" dismiss → 영구 skip.
//    - toolbar "?" 버튼 으로 재호출 가능 (onboardingShown = false).
//    - Synth 모듈 logic 0 변경 — additive only.

import SwiftUI

/// 메인 Synth Palette view — standalone.
public struct SynthPaletteView: View {
    @StateObject private var model = SynthModel()

    /// V281-2 — 첫 진입 onboarding banner 노출 여부.
    ///
    /// 비유: 처음 카페에 온 손님에게만 한 번 메뉴판을 가리키는 점원 — 한 번 안내 후
    /// 다음 방문 부터는 알아서 주문. 사용자가 다시 보고 싶으면 toolbar "?" 버튼 으로 호출.
    ///
    /// 기본값 `false` = 첫 진입 시 banner 노출. dismiss 후 `true` 영구 저장.
    @AppStorage("df.synth.onboardingShown") private var onboardingShown: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: DFSpace.none) {
            // V281-2 — 첫 진입 시 onboarding banner (DFBanner .info).
            if !onboardingShown {
                onboardingBanner
                    .padding(.horizontal, DFSpace.md)
                    .padding(.top, DFSpace.sm)
            }

            HStack(spacing: DFSpace.none) {
                // Left — Library
                SynthLibraryPanel(model: model)
                    .frame(width: 320)
                    .background(.thinMaterial)

                Divider()

                // Center — Canvas
                SynthCanvasPanel(model: model)
                    .frame(minWidth: 480)

                Divider()

                // Right — Inspector
                SynthInspectorPanel(model: model)
                    .frame(width: 360)
                    .background(.thinMaterial)
            }
        }
        .navigationTitle("Motion Synthesis")
        .toolbar {
            // V281-2 — 도움말 재호출 ("?" 버튼).
            // 사용자가 banner 를 dismiss 한 후에도 다시 보고 싶을 때 사용.
            ToolbarItem(placement: .automatic) {
                Button(action: { onboardingShown = false }) {
                    Label("사용 안내", systemImage: "questionmark.circle")
                }
                .help("AI 모션 빌더 사용 안내 다시 보기")
                .accessibilityLabel("사용 안내 다시 보기")
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: { model.clearCanvas() }) {
                    Label("Clear Canvas", systemImage: "trash")
                }
                .disabled(model.canvas.isEmpty)
            }
        }
    }

    // MARK: - V281-2 Onboarding banner

    /// 첫 진입 사용자에게 3-pane 구조 + 워크플로우 1줄 안내.
    ///
    /// Microcopy 원칙 (V279-3 Voice & Tone Info):
    ///   - 한국어 + 친근 톤
    ///   - 위치 명시 (좌측/중앙/우측) — 공간 학습 도움
    ///   - 액션 동사 (골라/드래그/조정/추가)
    @ViewBuilder
    private var onboardingBanner: some View {
        DFBanner(
            title: "AI 모션 빌더 사용 안내",
            message: "라이브러리(좌측)에서 자세를 골라 캔버스(중앙)로 드래그하면 모션 시퀀스가 만들어져요. 인스펙터(우측)에서 각 자세의 timing 을 조정할 수 있어요. 완성 후 'Motion Studio 로 보내기' 로 페이지 추가.",
            severity: .info,
            onDismiss: { onboardingShown = true }
        )
    }
}

#Preview {
    SynthPaletteView()
        .frame(width: 1200, height: 700)
}
