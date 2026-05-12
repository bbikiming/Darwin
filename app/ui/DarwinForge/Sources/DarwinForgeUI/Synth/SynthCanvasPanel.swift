//  SynthCanvasPanel.swift — 합성 캔버스 (현재 캔버스에 쌓인 페이지들).

import SwiftUI

public struct SynthCanvasPanel: View {
    @ObservedObject var model: SynthModel

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm3) {
            HStack {
                Text("Canvas").font(.headline)
                Spacer()
                Text(model.selectedOperator.korean)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if model.canvas.isEmpty {
                ContentUnavailableView(
                    "캔버스가 비어 있어요",
                    systemImage: "rectangle.dashed",
                    description: Text("왼쪽 라이브러리에서 페이지를 + 버튼으로 추가하세요. 그리고 우측 인스펙터에서 연산자를 선택해 합성합니다.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: DFSpace.sm) {
                        ForEach(Array(model.canvas.enumerated()), id: \.element.id) { index, item in
                            SynthCanvasRow(
                                index: index,
                                item: item,
                                onRemove: {
                                    model.canvas.removeAll { $0.id == item.id }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // Result section
            if let resultJSON = model.resultJSON {
                Divider()
                VStack(alignment: .leading, spacing: DFSpace.xs) {
                    Text("결과 Motion JSON").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(resultJSON.prefix(800).appending(resultJSON.count > 800 ? "\n..." : ""))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    if let path = model.resultPagePath {
                        Text("저장 경로: \(path)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
    }
}

struct SynthCanvasRow: View {
    let index: Int
    let item: SynthCanvasItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DFSpace.sm) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 24)
                .foregroundStyle(.secondary)

            Circle()
                .fill(SynthModel.color(for: item.entry.safetyClass))
                .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)

            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(item.entry.displayName).font(.body)
                Text("page \(item.entry.id) · \(item.entry.stepCount) step")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.background.opacity(DFOpacity.disabled))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
