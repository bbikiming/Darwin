//  SynthPaletteView.swift — Sprint 11 메인 View.
//
//  3-pane drag-and-drop UI:
//    [Library Panel]  →  [Canvas Panel]  →  [Inspector Panel]
//      카탈로그 페이지        합성 캔버스          파라미터 + validator overlay
//
//  RootView 통합은 별도. 사용자가 명시적으로 SynthPaletteView 를 navigation
//  destination 또는 sheet 으로 호출.

import SwiftUI

/// 메인 Synth Palette view — standalone.
public struct SynthPaletteView: View {
    @StateObject private var model = SynthModel()

    public init() {}

    public var body: some View {
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
        .navigationTitle("Motion Synthesis")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { model.clearCanvas() }) {
                    Label("Clear Canvas", systemImage: "trash")
                }
                .disabled(model.canvas.isEmpty)
            }
        }
    }
}

#Preview {
    SynthPaletteView()
        .frame(width: 1200, height: 700)
}
