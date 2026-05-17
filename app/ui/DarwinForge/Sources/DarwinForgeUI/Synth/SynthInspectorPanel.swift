//  SynthInspectorPanel.swift — 연산자 선택 + 파라미터 + Validator overlay + Synthesize 버튼.
//
//  Synthesize 클릭 시 SynthBridge 를 통해 `forge synth ...` 호출.

import ForgeCore
import SwiftUI

public struct SynthInspectorPanel: View {
    @ObservedObject var model: SynthModel
    @State private var bridge = SynthBridge()
    @State private var showingHelp = false

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm3) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                Button(action: { showingHelp.toggle() }) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            // Operator picker
            Picker("연산자", selection: $model.selectedOperator) {
                ForEach(SynthOperator.allCases) { op in
                    Text(op.korean).tag(op)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)

            // Parameters by operator
            Group {
                switch model.selectedOperator {
                case .sequence:
                    DFSlider("Transition", value: $model.transitionMs,
                             in: 0...3000, step: 100, unit: "ms")
                        .padding(.horizontal)
                case .mutate:
                    DFSlider("Time Scale", value: $model.timeScale,
                             in: 0.25...4.0, step: 0.05, unit: "×",
                             ticks: [0.5, 1.0, 2.0])
                        .padding(.horizontal)
                case .layer, .morph, .mirror, .procedural:
                    Text("기본 파라미터 사용 (자동)").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }

            Divider()

            // Synthesize button
            Button(action: { Task { await synthesize() } }) {
                if model.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Synthesize", systemImage: "wand.and.sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.canvas.isEmpty || model.isLoading)
            .padding(.horizontal)

            // Validator overlay — Codex audit (2026-05-17) 이후 정직 표기.
            // 이 화면은 `forge synth validate` 를 호출하지 않습니다. 결과는 모두 "미검증"
            // 상태로 표기됩니다. 사용자가 의도치 않게 ✅ 로 오인하지 않도록.
            if !model.validatorResults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    HStack(spacing: DFSpace.xs) {
                        Text("검증 단계").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("자동 검증 미실행")
                            .font(.system(size: DFFontSize.s9, weight: .bold))
                            .foregroundStyle(DFColor.warning)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(DFColor.warning, lineWidth: 0.5)
                            )
                    }
                    ForEach(Array(model.validatorResults.enumerated()), id: \.offset) { _, r in
                        validatorRow(r)
                    }
                    Text("정확한 검증은 터미널에서 `forge synth validate <page.json>` 를 실행하세요.")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.horizontal)
            }

            // Last error
            if let err = model.lastError {
                Divider()
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .sheet(isPresented: $showingHelp) {
            helpSheet()
        }
    }

    private func validatorRow(_ r: SynthValidatorOutcome) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: icon(r.status))
                .foregroundStyle(color(r.status))
            Text(r.stage).font(.system(.caption, design: .monospaced)).frame(width: 110, alignment: .leading)
            Text(r.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func icon(_ s: SynthValidatorOutcome.Status) -> String {
        switch s {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        }
    }

    private func color(_ s: SynthValidatorOutcome.Status) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }

    private func helpSheet() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                Text("Motion Synthesis 도움말").font(.title3.bold())
                Text("좌측 라이브러리에서 페이지를 캔버스에 추가합니다. 우측 연산자를 선택하고 파라미터를 조정한 뒤 Synthesize.")
                Text("연산자별:")
                Text("• Sequence — 캔버스의 모든 페이지를 시간순 연결").font(.caption)
                Text("• Layer — 첫 3 페이지를 상체/하체/머리로 배치").font(.caption)
                Text("• Morph — 첫 2 페이지의 가중 평균").font(.caption)
                Text("• Mutate — 첫 페이지에 time-scale 적용").font(.caption)
                Text("• Mirror — 첫 페이지 좌우 반전").font(.caption)
                Text("• Procedural — 첫·둘째 페이지를 anchor 로 sine 곡선").font(.caption)
                Text("이 화면은 합성만 수행하며 자동 검증은 하지 않습니다. 4단계 검증은 터미널에서 `forge synth validate <page.json>` 로 실행해 확인하세요.")
                    .padding(.top, 8)
            }
            .padding()
        }
        .frame(width: 380, height: 360)
    }

    // MARK: - Synthesize action

    @MainActor
    private func synthesize() async {
        model.isLoading = true
        defer { model.isLoading = false }
        model.lastError = nil
        model.validatorResults.removeAll()

        let result: Result<SynthResult, SynthBridgeError>
        switch model.selectedOperator {
        case .sequence:
            let ids = model.canvas.map { $0.entry.id }
            result = bridge.sequence(
                pageIds: ids,
                transitionMs: Int(model.transitionMs),
                baseId: 100,
                name: "synth_canvas"
            )
        case .mutate:
            guard let first = model.canvas.first else { return }
            result = bridge.mutateTimeScale(pageId: first.entry.id, factor: model.timeScale, newId: 100)
        case .mirror:
            guard let first = model.canvas.first else { return }
            result = bridge.mirror(pageId: first.entry.id, newId: 100, newName: "synth_mirror")
        case .layer, .morph, .procedural:
            // 본 view 에서는 기본 옵션으로 호출. 본구현은 후속 Sprint.
            model.lastError = "\(model.selectedOperator.korean)는 본 view 에서 미지원 — `forge synth` CLI 사용"
            return
        }

        switch result {
        case .success(let r):
            model.resultJSON = r.motionJSON
            // **Codex audit (2026-05-17)**: 이 화면은 검증을 수행하지 않습니다. 이전엔
            // 4단계 모두 .pass 하드코딩으로 사용자가 검증 통과로 오인할 위험이 있었음.
            // 이제 모든 단계를 .warn 으로 표기하여 "미검증" 임을 시각적으로 명시.
            // 추후 SynthBridge 가 `forge synth validate` 를 노출하면 .pass/.fail 로 채움.
            let missing = "이 화면에선 검증되지 않음"
            model.validatorResults = [
                SynthValidatorOutcome(stage: "JointLimit",      status: .warn, message: missing),
                SynthValidatorOutcome(stage: "Velocity",        status: .warn, message: missing),
                SynthValidatorOutcome(stage: "SelfCollision",   status: .warn, message: missing),
                SynthValidatorOutcome(stage: "StaticStability", status: .warn, message: missing),
            ]
        case .failure(let err):
            model.lastError = "\(err)"
        }
    }
}
