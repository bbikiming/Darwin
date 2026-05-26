import SwiftUI
import MobilePilotKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PreflightChecklistView
// 항공기 pre-takeoff 체크리스트 비유: 자동 계기 점검(autopilot) + 수동 확인(기장 직접).
// 자동 체크: IMU / 배터리 / 관절 calibration / dxlPower OFF
// 수동 체크: iPhone 충전 > 20%
// 자동 + 수동 모두 pass → "다음" 버튼 활성

/// Safety Brief 통과 후 표시되는 Preflight 체크리스트 화면.
/// telemetry 기반 자동 체크 4개 + 사용자 수동 체크 1개.
public struct PreflightChecklistView: View {

    // MARK: - Props

    let telemetry: TelemetryStatePayload?
    let onComplete: () -> Void

    // MARK: - State

    @State private var manualIphoneCharge: Bool = false
    @State private var isRetrying: Bool = false

    public init(telemetry: TelemetryStatePayload?, onComplete: @escaping () -> Void) {
        self.telemetry = telemetry
        self.onComplete = onComplete
    }

    // MARK: - Computed

    private var autoItems: [PreflightItem] {
        PreflightEvaluator.evaluate(telemetry: telemetry)
    }

    private var allAutoPassed: Bool {
        autoItems.allSatisfy(\.isPassed)
    }

    private var allPassed: Bool {
        allAutoPassed && manualIphoneCharge
    }

    private var failedItems: [PreflightItem] {
        autoItems.filter { !$0.isPassed }
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    heroSection
                    autoCheckSection
                    manualCheckSection

                    if !failedItems.isEmpty {
                        failureGuidanceSection
                    }

                    continueButton
                }
                .padding(DS.Space.l)
                .padding(.bottom, DS.Space.xxl)
            }
            .background(DS.Color.canvas.ignoresSafeArea())
            .navigationTitle("Preflight 점검")
            .dfInlineNavigationTitle()
            .interactiveDismissDisabled(true)
        }
        .accessibilityIdentifier("preflight.root")
    }

    // MARK: - Sub-views

    private var heroSection: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                Circle()
                    .fill(allPassed ? DS.Color.success.opacity(0.12) : DS.Color.warning.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: allPassed ? "checkmark.circle.fill" : "checklist")
                    .font(.system(size: 38))
                    .foregroundStyle(allPassed ? DS.Color.success : DS.Color.warning)
            }
            .animation(DS.Motion.standard, value: allPassed)
            .accessibilityHidden(true)

            Text("사전 점검 체크리스트")
                .font(DS.Font.screenTitle)
                .accessibilityAddTraits(.isHeader)

            Text(allPassed
                 ? "모든 항목이 통과됐어요. E-Stop 확인으로 이동하세요."
                 : "자동으로 로봇 상태를 점검합니다. 수동 항목도 확인하세요.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var autoCheckSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            DSSectionHeader("자동 점검", subtitle: "로봇 텔레메트리 기반")

            DSCard(tone: .standard) {
                VStack(spacing: DS.Space.m) {
                    ForEach(Array(autoItems.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { Divider() }
                        autoCheckRow(item: item)
                    }
                }
            }
        }
    }

    private var manualCheckSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            DSSectionHeader("수동 확인", subtitle: "직접 확인하는 항목")

            DSCard(tone: .standard) {
                manualCheckRow(
                    isChecked: $manualIphoneCharge,
                    icon: "iphone",
                    title: "iPhone 충전 > 20%",
                    detail: "충분한 배터리가 없으면 중간에 연결이 끊길 수 있어요.",
                    accessibilityID: "preflight.manual.iphone"
                )
            }
        }
    }

    private var failureGuidanceSection: some View {
        DSCard(tone: .danger) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Label("점검 실패 항목", systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.sectionTitle).foregroundStyle(DS.Color.danger)
                ForEach(failedItems) { item in
                    if case .fail(let reason) = item.status {
                        HStack(alignment: .top, spacing: DS.Space.s) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.Color.danger).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(item.title).font(DS.Font.captionEmphasis)
                                Text(reason).font(DS.Font.caption).foregroundStyle(DS.Color.secondaryText)
                            }
                        }
                    }
                }
                DSButton("다시 점검", systemImage: "arrow.clockwise",
                         style: .secondary, fullWidth: true) {
                    withAnimation(DS.Motion.standard) { isRetrying = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isRetrying = false }
                }
                .accessibilityIdentifier("preflight.retry")
            }
        }
    }

    private var continueButton: some View {
        DSButton("다음 — E-Stop 확인",
                 systemImage: allPassed ? "hand.raised.fill" : "lock.fill",
                 style: .primary,
                 size: .large,
                 fullWidth: true,
                 disabled: !allPassed) {
            guard allPassed else { return }
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            onComplete()
        }
        .frame(minHeight: DS.Hit.estop)
        .accessibilityIdentifier("preflight.continue")
        .accessibilityHint(allPassed
                           ? "E-Stop 확인으로 이동합니다"
                           : "모든 점검 항목을 통과해야 활성화됩니다")
    }

    // MARK: - Row views

    private func autoCheckRow(item: PreflightItem) -> some View {
        HStack(spacing: DS.Space.m) {
            statusIcon(for: item.status)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(item.title)
                    .font(DS.Font.bodyEmphasis)
                if case .fail(let reason) = item.status {
                    Text(reason)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.danger)
                }
            }

            Spacer()

            statusBadge(for: item.status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(accessibilityStatus(item.status))")
        .accessibilityIdentifier("preflight.auto.\(item.id)")
    }

    private func manualCheckRow(isChecked: Binding<Bool>,
                                 icon: String,
                                 title: String,
                                 detail: String,
                                 accessibilityID: String) -> some View {
        Button {
            withAnimation(DS.Motion.quick) { isChecked.wrappedValue.toggle() }
            #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .fill(isChecked.wrappedValue ? DS.Color.success : DS.Color.elevated)
                        .frame(width: 28, height: 28)
                    if isChecked.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.primaryText)
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(isChecked.wrappedValue ? "확인됨. 탭하여 해제" : "탭하여 확인")
        .accessibilityAddTraits(isChecked.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: - Status helpers

    @ViewBuilder
    private func statusIcon(for status: PreflightItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock.fill")
                .foregroundStyle(DS.Color.secondaryText)
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DS.Color.success)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(DS.Color.danger)
        }
    }

    @ViewBuilder
    private func statusBadge(for status: PreflightItem.Status) -> some View {
        switch status {
        case .pending:
            Text("대기")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Color.secondaryText)
        case .pass:
            Text("통과")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Color.success)
        case .fail:
            Text("실패")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Color.danger)
        }
    }

    private func accessibilityStatus(_ status: PreflightItem.Status) -> String {
        switch status {
        case .pending: return "대기 중"
        case .pass: return "통과"
        case .fail(let reason): return "실패 — \(reason)"
        }
    }
}
