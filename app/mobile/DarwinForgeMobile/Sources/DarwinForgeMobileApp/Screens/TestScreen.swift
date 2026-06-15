import SwiftUI
import MobilePilotKit

public struct TestScreen: View {

    @EnvironmentObject var state: AppState
    @State private var sessionStartedAt: Date?
    @State private var currentStep: Int = 0
    @State private var notes: String = ""
    @State private var result: TestResult = .pending
    // P2-2 fix (truth-gap report, 2026-05-25): structured artifact export.
    @State private var estopVerified: Bool = false
    @State private var backgroundStopVerified: Bool = false
    @State private var disconnectStopVerified: Bool = false
    @State private var lastRecord: TestRunRecord?
    @State private var lastExport: String?
    @State private var lastExportSummary: String?
    @State private var showExport: Bool = false

    public init() {}

    enum TestResult: String, Sendable, CaseIterable, Identifiable {
        case pending = "진행 중"
        case pass    = "통과"
        case fail    = "실패"
        var id: String { rawValue }
    }

    private let steps: [String] = [
        "주변 정리와 크래들 확인",
        "잠금 해제 준비",
        "보행 자세 실행",
        "인사 또는 앉기",
        "천천히 전진 2초",
        "좌회전 1초",
        "정지 확인",
        "결과와 메모 저장"
    ]

    public var body: some View {
        NavigationStack {
            Form {
                Section("세션") {
                    if let started = sessionStartedAt {
                        Label("시작: \(timeFormatter.string(from: started))",
                              systemImage: "clock")
                        Label("경과: \(elapsed(started))s", systemImage: "stopwatch")
                            .font(.body.monospacedDigit())
                        Button(role: .destructive) { endSession() } label: {
                            Label("세션 종료", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            sessionStartedAt = Date()
                            currentStep = 0
                            result = .pending
                            lastRecord = nil
                            lastExport = nil
                            lastExportSummary = nil
                            state.clearError()
                        } label: {
                            Label("테스트 시작", systemImage: "play.circle.fill")
                        }
                        .accessibilityIdentifier("test.session.start")
                    }
                }

                Section("체크리스트") {
                    ForEach(steps.indices, id: \.self) { idx in
                        HStack {
                            Image(systemName: stepIcon(idx))
                                .foregroundStyle(stepColor(idx))
                            Text("\(idx + 1). \(steps[idx])")
                                .fontWeight(idx == currentStep ? .semibold : .regular)
                            Spacer()
                            if idx == currentStep && sessionStartedAt != nil {
                                Button("다음") {
                                    currentStep = min(steps.count - 1, currentStep + 1)
                                }
                                .font(.caption.weight(.semibold))
                                .accessibilityIdentifier("test.step.next")
                            }
                        }
                    }
                }

                Section("결과") {
                    Picker("결과", selection: $result) {
                        ForEach(TestResult.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    TextField("메모", text: $notes, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .accessibilityIdentifier("test.notes")
                    Button("실패 기록") {
                        result = .fail
                    }
                    .accessibilityIdentifier("test.record.failure")
                }

                // P2-2: safety verification checks
                Section("안전 검증 항목") {
                    Toggle("긴급 정지로 즉시 멈췄다", isOn: $estopVerified)
                        .accessibilityIdentifier("test.estop.verified")
                    Toggle("앱을 내려도 자동 정지가 동작했다",
                           isOn: $backgroundStopVerified)
                        .accessibilityIdentifier("test.background.verified")
                    Toggle("연결이 끊기면 안전 정지가 동작했다",
                           isOn: $disconnectStopVerified)
                        .accessibilityIdentifier("test.disconnect.verified")
                }

                Section("테스트 기록 내보내기") {
                    Button {
                        guard let record = currentExportRecord() else { return }
                        if let json = try? record.encodeJSON() {
                            lastExport = json
                            lastExportSummary = record.summaryText()
                            showExport = true
                        }
                    } label: {
                        Label("JSON으로 내보내기", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("test.export.json")
                    .disabled(currentExportRecord() == nil)
                    if let summary = currentExportRecord()?.summaryText() {
                        Text(summary)
                            .font(.caption2.monospaced())
                            .lineLimit(8)
                            .foregroundStyle(.secondary)
                    }
                }

                if let receipt = state.lastReceipt {
                    Section("마지막 명령") {
                        Text(receipt.commandId).font(.caption.monospaced())
                        Text(receiptDescription(receipt)).font(.caption)
                    }
                }
            }
            .navigationTitle("테스트")
            .sheet(isPresented: $showExport) {
                ExportSheet(json: lastExport ?? "",
                            summary: lastExportSummary ?? currentExportRecord()?.summaryText() ?? "",
                            onDismiss: { showExport = false })
            }
        }
    }

    private func currentExportRecord() -> TestRunRecord? {
        if sessionStartedAt != nil {
            return buildRecord(endedAt: Date())
        }
        return lastRecord
    }

    private func buildRecord(endedAt: Date?) -> TestRunRecord {
        let now = endedAt ?? Date()
        let commandIds = state.logs.compactMap { $0.commandId }.prefix(20).map { $0 }
        let maxLatency = state.lastReceipt.flatMap { r -> Int? in
            if case .acked(let ms) = r.outcome { return ms }
            return nil
        }
        return TestRunRecord(
            appVersion: state.appVersion,
            mode: state.connectionMode.rawValue,
            endpoint: state.telemetry?.endpoint,
            pairingMethod: state.pairedEndpoint != nil ? "manual_or_discovery" : nil,
            startedAt: sessionStartedAt ?? now,
            endedAt: endedAt,
            steps: steps.enumerated().map { idx, title in
                TestRunRecord.Step(index: idx,
                                    title: title,
                                    completedAt: idx < currentStep ? now : nil,
                                    note: nil)
            },
            result: TestRunRecord.Result(rawValue: result == .pass ? "pass" :
                                                   result == .fail ? "fail" : "pending")!,
            notes: notes,
            commandIds: Array(commandIds),
            maxLatencyMs: maxLatency,
            stopReasons: state.logs
                .filter { $0.message.contains("정지") || $0.message.contains("stop") }
                .prefix(10).map { $0.message },
            estopVerified: estopVerified,
            backgroundStopVerified: backgroundStopVerified,
            disconnectStopVerified: disconnectStopVerified,
            cradleConfirmed: state.cradleConfirmed,
            physicalEStopConfirmed: state.physicalEStopConfirmed,
            lineOfSightConfirmed: state.lineOfSightConfirmed)
    }

    private func endSession() {
        if let started = sessionStartedAt {
            let endedAt = Date()
            lastRecord = buildRecord(endedAt: endedAt)
            if let json = try? lastRecord?.encodeJSON() {
                lastExport = json
                lastExportSummary = lastRecord?.summaryText()
            }
            let summary = "테스트 종료: 결과 \(result.rawValue), \(Int(endedAt.timeIntervalSince(started)))s, note: \(notes)"
            print("[TEST]", summary)
        }
        sessionStartedAt = nil
        notes = ""
        currentStep = 0
    }

    private func stepIcon(_ idx: Int) -> String {
        if idx < currentStep { return "checkmark.circle.fill" }
        if idx == currentStep { return "circle.dashed" }
        return "circle"
    }

    private func stepColor(_ idx: Int) -> Color {
        if idx < currentStep { return .green }
        if idx == currentStep { return .blue }
        return .secondary
    }

    private func elapsed(_ started: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(started)))
    }

    private func receiptDescription(_ r: CommandReceipt) -> String {
        switch r.outcome {
        case .accepted: return "접수"
        case .acked(let ms): return "응답 \(ms)ms"
        case .rejected(let reason, _): return "거부 \(reason.rawValue)"
        case .failed(let reason, _): return "실패 \(reason.rawValue)"
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}

// MARK: - Export sheet (P2-2)

private struct ExportSheet: View {
    let json: String
    let summary: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("요약").font(.headline)
                    Text(summary)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Divider()
                    Text("JSON").font(.headline)
                    Text(json)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle("테스트 기록")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: json) {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                    .disabled(json.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기", action: onDismiss)
                }
            }
        }
    }
}
