import SwiftUI

/// **v1.11.16.1 (2026-05-19)** — ROBOTIS Onboard 모드 health indicator.
///
/// session.walkingEngine == .robotisOnboard 일 때만 표시. daemon 응답 상태 시각화:
/// - ✅ Healthy — 마지막 ACK 5초 이내, 실패 0회
/// - ⚠️ Stale — ACK 5초 이상 오래됨 (또는 미수신)
/// - 🛑 Failing — 연속 실패 1~2 회
/// - ❌ Critical — 3회+ 또는 daemon missing
///
/// WalkLabView 의 toolbar 또는 sidebar 에 표시.
/// 사용자가 자동 fallback toggle 도 여기서 조정.
public struct OnboardHealthIndicator: View {
    @EnvironmentObject private var session: WalkLabSession
    @Environment(\.dfTheme) private var theme: DFTheme
    @AppStorage("df.walklab.autoOnboardFallback") private var autoFallback: Bool = false

    public init() {}

    public var body: some View {
        // .robotisOnboard 모드일 때만 표시 — 다른 모드면 invisible.
        if session.walkingEngine == .robotisOnboard {
            // **v1.11.16.2 — Codex HIGH 4 fix**: TimelineView 로 1초마다 redraw.
            // 종전: stale 판정 (lastAckAt > 5s) 이 onChange 만 — UI 가 자동 갱신 X.
            // TimelineView(.periodic) 으로 1s 마다 body 재평가 → 시간 경과 즉시 반영.
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                HStack(spacing: DFSpace.xs) {
                    statusIcon
                    statusLabel
                    Spacer(minLength: DFSpace.xs)
                    fallbackToggle
                }
                .padding(.horizontal, DFSpace.sm)
                .padding(.vertical, DFSpace.xs2)
                .background(DFColor.adaptiveCard(theme))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(statusColor.opacity(DFOpacity.o30), lineWidth: DFSize.borderHairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("ROBOTIS Onboard 상태: \(statusText)")
            }
        }
    }

    /// 상태 분류 — 4 단계.
    enum Status {
        case healthy        // ACK 최근 + 실패 0
        case stale          // ACK 오래됨 (>5초) 또는 미수신
        case failing        // 1~2회 실패
        case critical       // 3회+ 또는 daemon missing
    }

    private var status: Status {
        if session.onboardDaemonMissing {
            return .critical
        }
        if session.onboardConsecutiveFailures >= 3 {
            return .critical
        }
        if session.onboardConsecutiveFailures > 0 {
            return .failing
        }
        if let lastAck = session.onboardLastAckAt {
            let elapsed = Date().timeIntervalSince(lastAck)
            return elapsed > 5.0 ? .stale : .healthy
        }
        return .stale  // ACK 미수신
    }

    private var statusColor: Color {
        switch status {
        case .healthy: return DFColor.success
        case .stale:   return DFColor.warning
        case .failing: return DFColor.warning
        case .critical: return DFColor.danger
        }
    }

    private var statusIconName: String {
        switch status {
        case .healthy: return "checkmark.circle.fill"
        case .stale:   return "clock.badge.exclamationmark"
        case .failing: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private var statusText: String {
        switch status {
        case .healthy: return "정상"
        case .stale:   return "stale"
        case .failing: return "실패 \(session.onboardConsecutiveFailures)회"
        case .critical:
            return session.onboardDaemonMissing
                ? "daemon 없음"
                : "통신 단절 \(session.onboardConsecutiveFailures)회"
        }
    }

    private var statusIcon: some View {
        Image(systemName: statusIconName)
            .font(.system(size: DFFontSize.s13, weight: .semibold))
            .foregroundStyle(statusColor)
    }

    private var statusLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("Onboard")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textPrimary)
                Text(statusText)
                    .font(DFFont.label)
                    .foregroundStyle(statusColor)
            }
            if let lastAck = session.onboardLastAckAt {
                Text("최근 ACK: \(timeAgoString(from: lastAck))")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            } else if let error = session.onboardLastError {
                Text(error.prefix(40).description)
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var fallbackToggle: some View {
        Toggle(isOn: $autoFallback) {
            Text("자동 전환")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
        }
        .toggleStyle(.checkbox)
        .help("3회 연속 실패 시 자동으로 Mac sparse 로 전환")
    }

    /// 사람이 읽기 쉬운 "Xs ago" 형식.
    private func timeAgoString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 1 { return "<1s" }
        if elapsed < 60 { return "\(Int(elapsed))s" }
        return "\(Int(elapsed / 60))m"
    }
}
