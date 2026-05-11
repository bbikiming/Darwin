//  SynthLibraryPanel.swift — 카탈로그 페이지 카드 목록.

import SwiftUI

/// 좌측 panel — OFFICIAL_CATALOG 16 페이지.
public struct SynthLibraryPanel: View {
    @ObservedObject var model: SynthModel
    @State private var safetyFilter: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Text("\(filteredEntries.count) / \(model.catalog.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Safety filter
            Picker("Safety", selection: $safetyFilter) {
                Text("All").tag(String?.none)
                Text("Safe").tag(String?("Safe"))
                Text("Caution").tag(String?("Caution"))
                Text("HighRisk").tag(String?("HighRisk"))
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Cards
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        SynthLibraryCard(entry: entry, onAdd: {
                            model.addToCanvas(entry)
                        })
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var filteredEntries: [SynthCatalogEntry] {
        if let filter = safetyFilter {
            return model.catalog.filter { $0.safetyClass == filter }
        }
        return model.catalog
    }
}

/// 한 페이지의 카드.
struct SynthLibraryCard: View {
    let entry: SynthCatalogEntry
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Safety indicator
            Circle()
                .fill(SynthModel.color(for: entry.safetyClass))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(.body, design: .rounded).weight(.medium))
                Text("page \(entry.id) · \(entry.rawName) · \(entry.stepCount) step")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
