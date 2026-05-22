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
    @Environment(WalkLabSession.self) private var session
    @Environment(\.dfTheme) private var theme: DFTheme
    @AppStorage("df.walklab.autoOnboardFallback") private var autoFallback: Bool = false

    public init() {}

    public var body: some View {
        // .robotisOnboard 모드일 때만 표시 — 다른 모드면 invisible.
        if session.walkingEngine == .robotisOnboard {
            // **v1.14.8 (2026-05-21) perf cleanup**: TimelineView(.periodic, by: 1.0) 유지.
            // 1Hz redraw 는 stale 판정 (>5s 경과) 의 정확성에 필요. 종전과 동일.
            // 비교: session @Published 변화만 봐서는 시간 경과 자체를 감지 못 함 → stale
            // 표시 X. 1Hz 는 cost 가 미미 (단순 HStack 4 요소 재합성).
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    HStack(spacing: DFSpace.xs) {
                        statusIcon
                        statusLabel
                        Spacer(minLength: DFSpace.xs)
                        fallbackToggle
                    }
                    // 사이클 168 (cycle 162/164 wire-up): 옛 daemon balance schema silent
                    // 차단 경고. Onboard mode + balance ON + version 미확인 시 빨간 banner.
                    if session.onboardBalanceSchemaWarningActive {
                        schemaWarningBanner
                    }
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

    /// 사이클 168 (cycle 164 wire-up): 옛 daemon (v1 patch, sscanf 7 필드) 는 balance
    /// 필드 silent ignore — Mac UI 가 "보정 활성" 표시했지만 robot 무동작 위험.
    /// 사용자가 daemon v2 확인 후 onboardBalanceSchemaVerified 토글로 dismiss.
    /// 사이클 169: "v2 확인" 버튼 추가 — 사용자 명시 dismiss path.
    @ViewBuilder
    private var schemaWarningBanner: some View {
        @Bindable var session = session
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: DFFontSize.s11, weight: .bold))
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: 0) {
                Text("⚠ daemon v2 미확인 — balance 미적용 가능")
                    .font(DFFont.micro.weight(.semibold))
                    .foregroundStyle(DFColor.warning)
                Text("옛 firmware 는 balance 필드 무시. robot 측 확인 후 verified 토글.")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DFSpace.xs2)
            // 사이클 169 + 172: 사용자가 robot 측 daemon v2 확인 후 dismiss.
            // 사이클 172: warningActive 가 computed property 로 전환 — verified set 만으로
            // 자동 dismiss. UserDefaults persist 로 다음 session 도 유지.
            Button("v2 확인") {
                session.onboardBalanceSchemaVerified = true
            }
            .font(DFFont.micro.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(DFColor.warning)
            .help("ROBOTIS daemon 이 v2 patch (sscanf 10 필드) 임을 명시 확인. " +
                  "이후 balance 필드가 robot 에 전달됩니다.")
            .accessibilityLabel("daemon v2 확인 토글")
        }
        .padding(.horizontal, DFSpace.xs2)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.xs2)
                .fill(DFColor.warning.opacity(0.10))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboard.schema.warning.banner")
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
