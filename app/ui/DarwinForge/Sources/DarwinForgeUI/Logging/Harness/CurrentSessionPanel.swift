import Foundation
import SwiftUI

// MARK: - File-private helpers (duplicated per-file to avoid module-level name clashes)

private func prettyBytes(_ n: UInt64) -> String {
    if n < 1024 { return "\(n) B" }
    let kb = Double(n) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    return String(format: "%.2f MB", mb)
}

// MARK: - CurrentSessionPanel
//
// **V289-1** — HarnessInspectorView 분할 (2026-05-25)
//
// 비유: 이 파일은 "항공 관제탑의 실시간 레이더 스크린". 매 1초 갱신되는
// 라이브 이벤트 tail 을 보여주며 현재 세션 상태를 표시.
//
// 기술: `Timer` 기반 1초 poll 로 `events.jsonl` 을 off-main 읽어
// 최근 200 이벤트를 표 형태로 표시. 세션이 없을 때 HSplitView 우측에 마운트.

struct CurrentSessionPanel: View {
    @State private var liveEvents: [TelemetryEvent] = []
    @State private var ticker: Timer?
    @State private var lastEventCount: UInt64 = 0
    @State private var lastSize: UInt64 = 0
    @State private var lastFlushAt: Date? = nil
    @State private var filter: String = ""
    // **V289-5** — Space: UI 갱신 freeze (telemetry 수신은 계속).
    @State private var isPaused: Bool = false
    // **V289-5** — ⌘F: 검색창 포커스 트리거.
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            statusHeader
            // **V289-3** — L2 Primary Tile Grid (2×3): IMU / Gait / Intent / Servo / CPU / Comm.
            HarnessSensorTileGrid(imuBuffer: liveEvents, liveEvents: liveEvents)
            Divider()
            // **v1.14.0** — 진행 중 세션의 라이브 알림 배너.
            LiveAlertsBanner()
            Divider()
            HStack {
                TextField("kind 검색", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($isSearchFocused)
                    .accessibilityLabel("이벤트 kind 검색")
                Button {
                    Harness._internalShared.bookmark("inspector live-tail bookmark")
                } label: {
                    Label("북마크 추가", systemImage: "bookmark.fill")
                }
                .buttonStyle(.borderless)
                .help("이 시점에 user.bookmark 이벤트 삽입")
                // **V289-5** — ⌘B 북마크 단축키 (CurrentSessionPanel 레벨 바인딩).
                // HarnessInspectorView toolbar ⌘B 와 동일 action — 두 컨텍스트 모두 커버.
                .keyboardShortcut(HarnessShortcuts.bookmark)

                // **V289-5** — Space pause/resume hidden button.
                // **V289-7 critic MINOR-8 fix** — 검색창 focus 시 Space 충돌 회피.
                // disabled(isSearchFocused) 로 검색 입력 중에는 키보드 단축키 비활성.
                Button("") {
                    isPaused.toggle()
                    if !isPaused { refresh() }
                }
                .keyboardShortcut(HarnessShortcuts.pauseResume)
                .disabled(isSearchFocused)
                .opacity(0)
                .accessibilityLabel(isPaused ? "라이브 tail 재개 (Space)" : "라이브 tail 일시정지 (Space)")
                .allowsHitTesting(false)

                // **V289-5** — ⌘F 검색 포커스 hidden button.
                Button("") { isSearchFocused = true }
                .keyboardShortcut(HarnessShortcuts.focusSearch)
                .opacity(0)
                .accessibilityLabel("검색창 포커스 (⌘F)")
                .allowsHitTesting(false)

                Spacer()
                // Pause 상태 표시.
                if isPaused {
                    Label("일시정지", systemImage: "pause.circle.fill")
                        .font(DFFont.label)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("라이브 tail 일시정지 중")
                }
                Text(refreshStatusLabel).font(DFFont.label).foregroundStyle(.tertiary)
            }
            Divider()
            if filtered.isEmpty {
                VStack(spacing: DFSpace.xs2) {
                    Image(systemName: "tray")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(HarnessFormat.EmptyState.noEvents(filter: filter))
                        .font(DFFont.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered) {
                    TableColumn("시각") { ev in
                        Text(timeString(ev.tw)).font(.system(.caption, design: .monospaced))
                    }.width(min: 80, ideal: 100)
                    TableColumn("Seq") { ev in
                        Text("#\(ev.i)").font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }.width(60)
                    TableColumn("Kind") { ev in
                        HStack(spacing: DFSpace.xs) {
                            LevelBadge(level: ev.lv)
                            Text(ev.k.rawValue).font(DFFont.caption)
                            if let korLabel = EventKindLabel.from(kindRawValue: ev.k.rawValue) {
                                Text(korLabel.displayName)
                                    .font(DFFont.label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }.width(min: 200, ideal: 290)
                    TableColumn("Actor") { ev in
                        Text(ev.a.rawValue).font(DFFont.label).foregroundStyle(.secondary)
                    }.width(60)
                    TableColumn("Payload") { ev in
                        Text(payloadOneLine(ev))
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1).truncationMode(.tail)
                            .help(payloadFull(ev))
                    }
                }
                // **V289-5** — VoiceOver 가 각 행을 의미 단위로 읽도록.
                .accessibilityElement(children: .contain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
    }

    private var statusHeader: some View {
        let sid = Harness._internalShared.sessionId
        let shortId = sid.isEmpty ? "(미시동)" : String(sid.prefix(8))
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.sm) {
                // **V289-7 critic MINOR-1 fix** — ISA-101: 녹색 회피, 활성은 명도로.
                Circle().fill(Harness._internalShared.recorder == nil ? Color.gray : Color.primary)
                    .frame(width: 10, height: 10)
                Text("Live tail — 현재 세션")
                    .font(.headline)
                Spacer()
                Text(shortId)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack(spacing: DFSpace.md) {
                MetaCell(label: "시작",
                         value: shortTime(Harness._internalShared.sessionStarted))
                MetaCell(label: "수집한 이벤트",
                         value: "\(lastEventCount)")
                MetaCell(label: "디스크 사용량",
                         value: prettyBytes(lastSize))
                MetaCell(label: "마지막 flush",
                         value: lastFlushAt.map(briefRelative) ?? "—")
            }
        }
    }

    private var filtered: [TelemetryEvent] {
        guard !filter.isEmpty else { return liveEvents }
        return liveEvents.filter { $0.k.rawValue.localizedCaseInsensitiveContains(filter) }
    }

    /// 마지막 flush 기준 갱신 상태 라벨 — stale(2초 초과) 시 amber 계열로 표시할 용도로 분리.
    private var refreshStatusLabel: String {
        guard let t = lastFlushAt else { return "갱신 대기 중" }
        let dt = Date().timeIntervalSince(t)
        if dt > 2.0 { return HarnessFormat.staleLabel(secondsAgo: dt) }
        return HarnessFormat.freshLabel(secondsAgo: dt)
    }

    private func startTicker() {
        stopTicker()
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                // **V289-5** — isPaused: UI 갱신만 skip. telemetry 수신은 계속.
                guard !self.isPaused else { return }
                self.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        // **v1.12.2 (Codex P2 fix)** — file I/O 를 off-main 으로.
        guard let dir = Harness._internalShared.sessionDir else { return }
        Task.detached(priority: .utility) {
            let events = dir.appendingPathComponent("events.jsonl")
            let metaURL = dir.appendingPathComponent("meta.json")
            // 사이클 141 (Swift 6 Sendable closure fix): var → let
            let (newEventCount, newSize): (UInt64, UInt64) = {
                if let data = try? Data(contentsOf: metaURL),
                   let m = try? JSONDecoder().decode(TelemetrySessionMeta.self, from: data) {
                    return (m.eventCount, m.sizeBytes)
                }
                return (0, 0)
            }()
            let newFlushAt: Date? = {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: events.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    return mtime
                }
                return nil
            }()
            // **v1.14.1 (Critic P2-7 fix)** — maxLines 200 → 800.
            let loaded = HarnessFileReader.loadEvents(from: events, maxLines: 800)
            // UI 표시는 최근 200 만 유지 — 메모리.
            let displayed = Array(loaded.suffix(200).reversed())
            await MainActor.run {
                self.lastEventCount = newEventCount
                self.lastSize = newSize
                self.lastFlushAt = newFlushAt
                self.liveEvents = displayed
                // LiveAlerts 는 800 전체 윈도우를 봐서 시간 정확도 우선.
                HarnessLiveAlerts.shared.evaluate(events: loaded)
            }
        }
    }

    private func timeString(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "HH:mm:ss.SSS"
            return out.string(from: d)
        }
        return iso
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f.string(from: d)
    }

    private func briefRelative(_ d: Date) -> String {
        let dt = Date().timeIntervalSince(d)
        if dt < 1 { return "방금" }
        if dt < 60 { return String(format: "%.1f초 전", dt) }
        if dt < 3600 { return String(format: "%.0f분 전", dt / 60) }
        return String(format: "%.1f시간 전", dt / 3600)
    }

    private func payloadOneLine(_ ev: TelemetryEvent) -> String {
        let pairs = ev.d.raw.sorted { $0.key < $1.key }.prefix(4).map { k, v in
            "\(k)=\(briefValue(v))"
        }
        return pairs.joined(separator: " ")
    }

    private func payloadFull(_ ev: TelemetryEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ev.d.raw),
           let str = String(data: data, encoding: .utf8) { return str }
        return "(empty)"
    }

    private func briefValue(_ v: AnyCodable) -> String {
        switch v.value {
        case let s as String: return s.count > 24 ? "\(s.prefix(24))…" : s
        case let i as Int: return "\(i)"
        case let d as Double: return String(format: "%.2f", d)
        case let b as Bool: return b ? "true" : "false"
        default: return "…"
        }
    }
}
