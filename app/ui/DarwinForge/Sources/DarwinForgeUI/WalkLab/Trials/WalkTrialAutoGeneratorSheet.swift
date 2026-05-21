import SwiftUI

/// **v1.19.1 (2026-05-21) 사이클 4 — Trial Auto-Generator UI**.
///
/// Library 안의 "도구" 또는 Recommender 가 비어있을 때 사용자에게 제공.
/// preset/intensity range 선택 후 generation 시작. 진행 progress bar + cancel 버튼.
@MainActor
public struct WalkTrialAutoGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WalkLabSession.self) private var session

    @State private var generator = WalkTrialAutoGenerator()

    @State private var selectedPresets: Set<WalkLabPreset> = [.slowWalk, .normalWalk, .march, .fastWalk]
    @State private var intensityLowerBound: Int = 0
    @State private var intensityUpperBound: Int = 4
    @State private var trialsPerCombo: Int = 2
    @State private var durationSec: Double = 5.0

    @State private var isGenerating: Bool = false
    @State private var generationTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if isGenerating {
                progressSection
            } else {
                configSection
            }
            Spacer()
            footerButtons
        }
        .padding(20)
        .frame(width: 480, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Trial 자동 생성", systemImage: "sparkles.rectangle.stack")
                .font(.title2.weight(.semibold))
            Text("Recommender 학습용 trial 자동 batch — sim 모드 전용")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("탐색 범위")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Preset (\(selectedPresets.count)개 선택)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach([WalkLabPreset.slowWalk, .normalWalk, .march, .fastWalk, .turnLeft, .turnRight], id: \.self) { p in
                        Button(action: { togglePreset(p) }) {
                            Text(p.label)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedPresets.contains(p) ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                .foregroundStyle(selectedPresets.contains(p) ? Color.accentColor : .secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Intensity 범위")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Stepper("최소 \(intensityLowerBound)", value: $intensityLowerBound, in: 0...4)
                        .controlSize(.small)
                    Stepper("최대 \(intensityUpperBound)", value: $intensityUpperBound, in: 0...4)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Combo 당 반복 (variance)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Stepper("\(trialsPerCombo)회", value: $trialsPerCombo, in: 1...5)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("각 trial 길이 (초)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Slider(value: $durationSec, in: 2...15)
                Text(String(format: "%.0f 초", durationSec))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("예상 trial 수")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(expectedTrialCount)건 × \(String(format: "%.0f", durationSec))초 = 약 \(estimatedTimeSec)초")
                    .font(.callout.bold().monospacedDigit())
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("진행 중...")
                .font(.headline)
            if let p = generator.progress {
                ProgressView(value: p.percentComplete)
                Text("\(p.current) / \(p.total) — \(String(format: "%.0f", p.percentComplete * 100))%")
                    .font(.callout.monospacedDigit())
                if let last = p.lastTrial {
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("시작 중...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            if isGenerating {
                Button("취소", role: .destructive) {
                    generationTask?.cancel()
                    isGenerating = false
                }
            } else {
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if !isGenerating {
                Button(action: startGeneration) {
                    Label("생성 시작", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPresets.isEmpty || intensityLowerBound > intensityUpperBound)
            }
        }
    }

    private func togglePreset(_ p: WalkLabPreset) {
        if selectedPresets.contains(p) {
            selectedPresets.remove(p)
        } else {
            selectedPresets.insert(p)
        }
    }

    private var expectedTrialCount: Int {
        selectedPresets.count
            * max(0, intensityUpperBound - intensityLowerBound + 1)
            * trialsPerCombo
    }

    private var estimatedTimeSec: Int {
        Int(Double(expectedTrialCount) * (durationSec + 0.2))
    }

    private func startGeneration() {
        guard session.store?.bus == nil else {
            // 실 robot 연결 — UI 가 차단 (도구 자체도 거부하지만 사용자 안내).
            return
        }
        isGenerating = true
        generationTask = Task { @MainActor in
            await generator.generateBatch(
                session: session,
                presetSet: Array(selectedPresets).sorted { $0.rawValue < $1.rawValue },
                intensityRange: intensityLowerBound...intensityUpperBound,
                trialsPerCombo: trialsPerCombo,
                durationSec: durationSec
            )
            isGenerating = false
        }
    }
}
