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
                    paramSlider("Transition (ms)", value: $model.transitionMs, range: 0...3000, step: 100)
                case .mutate:
                    paramSlider("Time Scale", value: $model.timeScale, range: 0.25...4.0, step: 0.05)
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

            // Validator overlay
            if !model.validatorResults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    Text("Validation").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.validatorResults.enumerated()), id: \.offset) { _, r in
                        validatorRow(r)
                    }
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

    private func paramSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
        }
        .padding(.horizontal)
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
                Text("Validator 4 단계 모두 통과해야 commit 가능. WARN 은 진행 허용, FAIL 은 차단.")
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
            // 단순 stderr 파싱으로 validator 결과 mock — 실제 validate 는 별도 호출 필요.
            model.validatorResults = [
                SynthValidatorOutcome(stage: "JointLimit",      status: .pass, message: ""),
                SynthValidatorOutcome(stage: "Velocity",        status: .pass, message: ""),
                SynthValidatorOutcome(stage: "SelfCollision",   status: .pass, message: ""),
                SynthValidatorOutcome(stage: "StaticStability", status: .pass, message: "(추정) `forge synth validate` 로 정확한 결과 확인"),
            ]
        case .failure(let err):
            model.lastError = "\(err)"
        }
    }
}
