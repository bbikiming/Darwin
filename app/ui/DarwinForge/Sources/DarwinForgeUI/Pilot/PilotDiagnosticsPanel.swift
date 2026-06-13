import ForgeCore
import SwiftUI

/// 원격 조종 진단 패널 — Sprint 15 v1.5 (Codex 권고 2026-05-13).
///
/// **목적**: "로봇 컨트롤 안 됨" 의 1차 진단 화면. 사용자가 한 눈에:
///   - 현재 endpoint (USB / 네트워크 / 미연결)
///   - 마지막 통신 시각 + 왕복 RTT + 누적 실패 카운터
///   - 마지막 송출 명령 + 결과 (성공 / 거부 / 쓰기실패 / 부하 위험)
///   - 마지막 SafeMotion 안전 이벤트 (저전압·고부하·각도 한계)
///
/// **배경**: v1.0 의 `applyPoseSmoothly` 가 SafeMotion 거부를 silently swallow 했음.
/// `lastSafetyEvent` 는 set 됐지만 Pilot UI 가 표시 안 함 → 사용자는 "완료" 토스트만 보고
/// 실제로는 모터가 안 움직임. v1.5 의 `PoseApplyResult` 와 본 패널이 함께 그 격차를 메움.
public struct PilotDiagnosticsPanel: View {
    @ObservedObject var store: ConnectionStore
    @ObservedObject var channel: TeleopChannel

    public init(store: ConnectionStore, channel: TeleopChannel) {
        self.store = store
        self.channel = channel
    }

    public var body: some View {
        DFPanel(
            "연결 진단",
            subtitle: subtitleText,
            icon: "stethoscope",
            tint: tint,
            trailing: { statusChip }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                endpointRow
                Divider().background(DFColor.textSecondary.opacity(DFOpacity.o15))
                timingRow
                if let dispatch = channel.lastDispatchSummary {
                    Divider().background(DFColor.textSecondary.opacity(DFOpacity.o15))
                    dispatchRow(dispatch)
                }
                if let safety = store.lastSafetyEvent, !safety.isEmpty {
                    safetyEventRow(safety)
                }
                if let recovery = store.lastRecoveryResult, !recovery.isEmpty {
                    recoveryRow(recovery)
                }
                busLatencyRow
            }
        }
        .onDisappear { persistLatencySessionIfEnabled() }
    }

    /// **A1 (cockpit-latency-hardening §6)** — 진단 패널이 사라질 때(세션 종료) tracer
    /// 활성 시에만 6채널 요약을 Application Support 에 JSON 으로 1회 떨군다.
    ///
    /// 활성/비활성 게이트 결정은 `PilotLatencyJSONSink.persistIfEnabled` 단일 지점으로
    /// 일원화(테스트 가능) — 비활성이면 sink 가 파일을 쓰지 않고 nil 반환. report 스냅샷도
    /// detached Task 안에서 떠 read-only 호출(`*Stats()`)이 UI teardown 을 막지 않는다.
    private func persistLatencySessionIfEnabled() {
        let tracer = PilotLatencyTracer.shared
        guard let dir = PilotLatencyJSONSink.defaultDirectory() else { return }
        let sink = PilotLatencyJSONSink()
        Task.detached(priority: .utility) {
            try? sink.persistIfEnabled(tracer: tracer, into: dir)
        }
    }

    /// **bus D0 계측 HUD (1Hz)** — `df.latency.busTracer` 활성 시에만 노출.
    /// TimelineView 라 패널이 보일 때만 틱(자체 타이머 누수 없음).
    @ViewBuilder
    private var busLatencyRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let summary = PilotLatencyTracer.shared.hudSummary() {
                Divider().background(DFColor.textSecondary.opacity(DFOpacity.o15))
                HStack(alignment: .top, spacing: DFSpace.sm) {
                    Image(systemName: "timer")
                        .font(.system(size: DFFontSize.s14, weight: .semibold))
                        .foregroundStyle(DFColor.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: DFSpace.none) {
                        Text("직결 케이던스")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                        Text(summary)
                            .font(DFFont.bodyEmph.monospaced())
                            .foregroundStyle(DFColor.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Subtitle / tint / status

    private var subtitleText: String {
        switch store.status {
        case .disconnected:           return "연결 안 됨 — 연결 마법사 사용"
        case .connecting(let label):  return "연결 중 — \(label)"
        case .connected(let snap):    return "\(snap.controllerLabel) · \(String(format: "%.1fV", snap.voltageVolts))"
        case .error(let msg):         return msg
        }
    }

    private var tint: Color {
        switch store.status {
        case .connected: return DFColor.success
        case .connecting, .disconnected: return DFColor.textSecondary
        case .error: return DFColor.danger
        }
    }

    private var statusChip: some View {
        Group {
            switch store.status {
            case .connected:    DFChip("연결됨", icon: "link", style: .success)
            case .connecting:   DFChip("연결 중", icon: "arrow.triangle.2.circlepath", style: .warning)
            case .disconnected: DFChip("미연결", icon: "link.badge.plus", style: .neutral)
            case .error:        DFChip("오류", icon: "exclamationmark.triangle.fill", style: .danger)
            }
        }
    }

    // MARK: - Endpoint row

    private var endpointRow: some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            Image(systemName: endpointIcon)
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(DFColor.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                Text(endpointKind)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Text(endpointDetail)
                    .font(DFFont.bodyEmph.monospaced())
                    .foregroundStyle(DFColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
    }

    private var endpointKind: String {
        guard let ep = store.activeEndpoint else { return "Endpoint" }
        return ep.kindLabel
    }

    private var endpointDetail: String {
        guard let ep = store.activeEndpoint else { return "미연결" }
        return ep.detail
    }

    private var endpointIcon: String {
        store.activeEndpoint?.iconSystemName ?? "questionmark.circle"
    }

    // MARK: - Timing row (RTT / lastSuccess / failures)

    private var timingRow: some View {
        HStack(spacing: DFSpace.md) {
            timingCell(label: "RTT", value: rttText, tint: rttTint)
            timingCell(label: "마지막 통신", value: lastSuccessText, tint: DFColor.info)
            timingCell(label: "성공/실패", value: "\(store.successCount)/\(store.failureCount)", tint: failureTint)
        }
    }

    private func timingCell(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.none) {
            Text(label)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Text(value)
                .font(DFFont.bodyEmph.monospaced())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rttText: String {
        guard let ms = store.lastRoundTripMs else { return "—" }
        if ms < 10 { return String(format: "%.1fms", ms) }
        return String(format: "%dms", Int(ms.rounded()))
    }

    private var rttTint: Color {
        guard let ms = store.lastRoundTripMs else { return DFColor.textSecondary }
        if ms < 20 { return DFColor.success }
        if ms < 100 { return DFColor.warning }
        return DFColor.danger
    }

    private var lastSuccessText: String {
        guard let at = store.lastSuccessAt else { return "—" }
        let elapsed = Date().timeIntervalSince(at)
        if elapsed < 2 { return "방금" }
        if elapsed < 60 { return String(format: "%.0f초 전", elapsed) }
        return String(format: "%.0f분 전", elapsed / 60)
    }

    private var failureTint: Color {
        if store.failureCount == 0 { return DFColor.success }
        if store.failureCount < 5 { return DFColor.warning }
        return DFColor.danger
    }

    // MARK: - Dispatch summary

    private func dispatchRow(_ d: TeleopChannel.DispatchSummary) -> some View {
        let icon: String
        let tint: Color
        switch d.result {
        case .completed:
            icon = "checkmark.circle.fill"; tint = DFColor.success
        case .partialFailure:
            icon = "exclamationmark.triangle.fill"; tint = DFColor.warning
        case .notConnected:
            icon = "circle.dashed"; tint = DFColor.warning
        case .rejected, .cancelled, .writeFailed, .criticalLoad:
            icon = "xmark.octagon.fill"; tint = DFColor.danger
        }
        return HStack(alignment: .top, spacing: DFSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                HStack(spacing: DFSpace.xs2) {
                    Text("마지막 송출")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                    Spacer(minLength: 0)
                    Text(elapsedText(d.at))
                        .font(DFFont.caption.monospaced())
                        .foregroundStyle(DFColor.textSecondary)
                }
                HStack(spacing: DFSpace.xs2) {
                    Text(d.label)
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(DFColor.textPrimary)
                    Text("·")
                        .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o50))
                    Text(d.result.userMessage)
                        .font(DFFont.caption)
                        .foregroundStyle(tint)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
        }
    }

    private func elapsedText(_ at: Date) -> String {
        let s = Date().timeIntervalSince(at)
        if s < 2 { return "방금" }
        if s < 60 { return String(format: "%.0f초 전", s) }
        return String(format: "%.0f분 전", s / 60)
    }

    // MARK: - Safety / recovery

    /// **V280-E (2026-05-24)**: hardcoded HStack/overlay → DFBanner (.warning).
    /// 종전 shield 아이콘 → DFNotification 표준 triangle (Carbon consistency).
    private func safetyEventRow(_ msg: String) -> some View {
        DFBanner(title: msg, severity: .warning)
            .accessibilityIdentifier("pilot.safety")
    }

    private func recoveryRow(_ msg: String) -> some View {
        let tint = store.lastRecoveryOutcome == .success ? DFColor.success : DFColor.warning
        return HStack(alignment: .top, spacing: DFSpace.sm) {
            Image(systemName: "arrow.clockwise.heart.fill")
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(msg)
                .font(DFFont.caption)
                .foregroundStyle(tint)
                .lineLimit(3)
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(tint.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }
}
