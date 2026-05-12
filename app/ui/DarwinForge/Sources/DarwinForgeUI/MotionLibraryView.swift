import ForgeCore
import SwiftUI

/// 모션 라이브러리 — `.mtn` 파일 import (Open Panel) → JSON 변환 + preview.
public struct MotionLibraryView: View {
    @State private var motions: [LoadedMotion] = []
    @State private var lastError: String?
    @State private var selected: LoadedMotion.ID?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(motions) { m in
                    VStack(alignment: .leading) {
                        Text(m.name).font(.headline)
                        Text(m.sourcePath)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        importMotion()
                    } label: {
                        Label("Import .mtn", systemImage: "tray.and.arrow.down")
                    }
                }
            }
            .frame(minWidth: 240)
        } detail: {
            if let id = selected, let m = motions.first(where: { $0.id == id }) {
                MotionDetailView(motion: m)
            } else if motions.isEmpty {
                ContentUnavailableView(
                    "No motions",
                    systemImage: "tray",
                    description: Text("Click Import to add a `.mtn` file from RoboPlus Action.")
                )
            } else {
                ContentUnavailableView(
                    "Select a motion",
                    systemImage: "play.rectangle",
                    description: Text("Choose a motion from the list.")
                )
            }
        }
        .alert(
            "Import failed",
            isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } }),
            actions: { Button("OK") { lastError = nil } },
            message: { Text(lastError ?? "") }
        )
    }

    private func importMotion() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let mtn = try String(contentsOf: url, encoding: .utf8)
                let json = try Motion.mtnToJSON(mtn, generation: "op2")
                let loaded = LoadedMotion(name: url.lastPathComponent, sourcePath: url.path,
                                          mtn: mtn, json: json)
                motions.append(loaded)
                selected = loaded.id
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

struct LoadedMotion: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let sourcePath: String
    let mtn: String
    let json: String
}

struct MotionDetailView: View {
    let motion: LoadedMotion

    @State private var showingMtn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(motion.name).font(.title2)
            Text(motion.sourcePath).font(.caption).foregroundStyle(.secondary)

            Picker("View", selection: $showingMtn) {
                Text("JSON (forge-core 내부 표현)").tag(false)
                Text(".mtn (round-trip)").tag(true)
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(showingMtn ? motion.mtn : motion.json)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
    }
}
