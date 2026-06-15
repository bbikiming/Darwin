import SwiftUI
import MobilePilotKit

public struct LogsScreen: View {

    @EnvironmentObject var state: AppState
    @State private var filter: LogFilter = .all

    public init() {}

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "전체"
        case command = "명령"
        case safety = "안전"
        case connection = "연결"
        case error = "오류"
        var id: String { rawValue }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("필터", selection: $filter) {
                    ForEach(LogFilter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if filteredLogs.isEmpty {
                    ContentUnavailableView("기록 없음",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text(emptyDescription))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("logs.empty")
                } else {
                    List(filteredLogs) { entry in
                        LogRow(entry: entry)
                    }
                    .listStyle(.plain)
                    .accessibilityIdentifier("logs.timeline")
                }
            }
            .navigationTitle("실행 기록")
        }
    }

    private var filteredLogs: [AppState.LogEntry] {
        switch filter {
        case .all: return state.logs
        case .command: return state.logs.filter { $0.category == .command }
        case .safety: return state.logs.filter { $0.category == .safety }
        case .connection: return state.logs.filter { $0.category == .connection }
        case .error: return state.logs.filter { $0.level == .error || $0.level == .warning }
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .all: return "연결, 잠금 해제, 동작 실행을 시작하면 기록이 여기에 쌓입니다."
        case .command: return "동작이나 보행 명령을 실행하면 명령 기록이 표시됩니다."
        case .safety: return "긴급 정지, 자동 정지, 잠금 해제 확인 기록이 표시됩니다."
        case .connection: return "Mac 앱이나 로봇 연결 상태 변화가 표시됩니다."
        case .error: return "주의가 필요한 항목만 모아 표시합니다."
        }
    }
}

private struct LogRow: View {
    let entry: AppState.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.category.koreanCopy)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.level.koreanCopy)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(entry.message)
                    .font(.subheadline)
                if let id = entry.commandId {
                    Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var time: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: entry.timestamp)
    }

    private var icon: String {
        switch entry.level {
        case .debug: return "dot.scope"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private extension LogCategory {
    var koreanCopy: String {
        switch self {
        case .command: return "명령"
        case .safety: return "안전"
        case .connection: return "연결"
        case .system: return "시스템"
        }
    }
}

private extension LogLevel {
    var koreanCopy: String {
        switch self {
        case .debug: return "상세"
        case .info: return "정보"
        case .warning: return "주의"
        case .error: return "오류"
        }
    }
}
