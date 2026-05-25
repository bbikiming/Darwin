import SwiftUI

/// 스마트폰의 Wi-Fi indicator — 항상 보이는 연결 상태.
///
/// macOS 툴바에 상주하는 Mobile Pilot Relay 상태 chip.
/// 스마트폰의 Wi-Fi 상태 표시줄처럼, 사용자가 어느 탭에 있어도
/// 릴레이가 켜졌는지·연결됐는지를 한눈에 알 수 있도록 한다.
///
/// 기술적으로: `MobileRelayController` 의 `@Published` 속성을 관찰해
/// 3단계 상태를 pill 형식으로 렌더링. 클릭 시 요약 popover 표시.
///
/// # 3 상태
/// - **OFF** (회색 dot + "모바일 Pilot 꺼짐") — 릴레이 비활성
/// - **대기** (amber dot + "모바일 Pilot 대기 · 코드 XXXXXX") — 활성, 미연결
/// - **연결됨** (primary dot + "모바일 Pilot 연결 · iPhone명") — 활성, 연결됨
///
/// # ISA-101 CVD 팔레트 (Okabe-Ito)
/// 활성 = `DFColor.accent` (파랑), 대기 = `DFColor.warning` (amber), 꺼짐 = gray.
/// 녹색 회피 — 안전 색상과 혼동 방지.
@MainActor
public struct MobileRelayStatusChip: View {

    @ObservedObject var controller: MobileRelayController

    // popover 표시 여부
    @State private var popoverVisible: Bool = false

    // MARK: - State classification

    private enum RelayState {
        case off
        case waiting(code: String)
        case connected(name: String)
    }

    private var relayState: RelayState {
        guard controller.isRunning else { return .off }
        if let name = controller.activeIPhoneName { return .connected(name: name) }
        return .waiting(code: controller.pairingCode)
    }

    // MARK: - Derived values

    private var dotColor: Color {
        switch relayState {
        case .off:           return DFColor.textSecondary
        case .waiting:       return DFColor.warning
        case .connected:     return DFColor.accent
        }
    }

    private var chipLabel: String {
        switch relayState {
        case .off:                   return "모바일 Pilot 꺼짐"
        case .waiting(let code):     return "모바일 Pilot 대기 · \(code)"
        case .connected(let name):   return "모바일 Pilot 연결 · \(name)"
        }
    }

    private var isActive: Bool {
        if case .off = relayState { return false }
        return true
    }

    // MARK: - Body

    public var body: some View {
        Button {
            popoverVisible = true
        } label: {
            HStack(spacing: DFSpace.xs2) {
                // CVD-safe 상태 dot — 색 + 발광(glow) 조합
                Circle()
                    .fill(dotColor)
                    .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)
                    .shadow(color: isActive ? dotColor.opacity(DFOpacity.o70) : .clear,
                            radius: isActive ? 3 : 0)
                Text(chipLabel)
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                    .foregroundStyle(isActive ? dotColor : DFColor.textSecondary)
                    .lineLimit(1)
            }
            .dfPill(active: isActive, tint: dotColor)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .help(chipHelpText)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("클릭하면 Mobile Pilot Relay 상세 정보를 확인할 수 있습니다")
        .popover(isPresented: $popoverVisible, arrowEdge: .bottom) {
            chipPopover
        }
    }

    // MARK: - Popover

    private var chipPopover: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "iphone.gen2.radiowaves.left.and.right")
                    .font(.system(size: DFFontSize.s14, weight: .semibold))
                    .foregroundStyle(dotColor)
                Text("Mobile Pilot Relay")
                    .font(.system(size: DFFontSize.s14, weight: .semibold))
            }

            Divider()

            switch relayState {
            case .off:
                Text("릴레이가 꺼져 있습니다.")
                    .font(.system(size: DFFontSize.s12))
                    .foregroundStyle(DFColor.textSecondary)
                Text("우하단 패널에서 토글을 켜 iPhone과 연결하세요.")
                    .font(.system(size: DFFontSize.s11))
                    .foregroundStyle(DFColor.textSecondary)

            case .waiting(let code):
                LabeledRow(label: "호스트") {
                    Text(controller.advertisedHost.isEmpty ? "—" : "\(controller.advertisedHost):\(controller.listenPort)")
                        .font(.system(size: DFFontSize.s12, design: .monospaced))
                }
                LabeledRow(label: "페어링 코드") {
                    Text(code)
                        .font(.system(size: DFFontSize.s13, weight: .bold, design: .monospaced))
                        .foregroundStyle(DFColor.warning)
                }
                Text("iPhone 앱에서 위 코드를 입력하세요.")
                    .font(.system(size: DFFontSize.s11))
                    .foregroundStyle(DFColor.textSecondary)

            case .connected(let name):
                LabeledRow(label: "연결된 기기") {
                    Text(name)
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(DFColor.accent)
                }
                LabeledRow(label: "호스트") {
                    Text(controller.advertisedHost.isEmpty ? "—" : "\(controller.advertisedHost):\(controller.listenPort)")
                        .font(.system(size: DFFontSize.s12, design: .monospaced))
                }
            }
        }
        .padding(DFSpace.md)
        .frame(minWidth: 240)
    }

    // MARK: - Helpers

    private var chipHelpText: String {
        switch relayState {
        case .off:                  return "모바일 Pilot Relay 꺼짐 — 클릭해서 상세 보기"
        case .waiting(let code):    return "모바일 Pilot 대기 중 · 코드: \(code)"
        case .connected(let name):  return "모바일 Pilot 연결됨 · \(name)"
        }
    }

    private var accessibilityLabelText: String {
        switch relayState {
        case .off:                  return "모바일 Pilot Relay 꺼짐"
        case .waiting(let code):    return "모바일 Pilot Relay 대기 중, 페어링 코드 \(code)"
        case .connected(let name):  return "모바일 Pilot Relay 연결됨, \(name)"
        }
    }
}

// MARK: - LabeledRow helper

/// popover 내부 label-value 행 — 재사용 최소화.
private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
            Text(label)
                .font(.system(size: DFFontSize.s11, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
                .frame(minWidth: 72, alignment: .trailing)
            content()
        }
    }
}
