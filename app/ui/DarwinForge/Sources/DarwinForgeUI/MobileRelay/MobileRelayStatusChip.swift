import SwiftUI

/// 스마트폰의 Wi-Fi indicator — 항상 보이는 연결 상태.
///
/// macOS 툴바에 상주하는 Mobile Pilot Relay 상태 chip.
/// 스마트폰의 Wi-Fi 상태 표시줄처럼, 사용자가 어느 탭에 있어도
/// 릴레이가 켜졌는지·연결됐는지를 한눈에 알 수 있도록 한다.
///
/// 기술적으로: `MobileRelayController` 의 `sessionState` computed 를 관찰해
/// 6단계 상태(off/advertising/handshaking/paired/disconnecting/error)를
/// pill 형식으로 렌더링. 클릭 시 요약 popover 표시.
///
/// # Popover 패턴
///
/// Apple Calendar 의 일정 popover 와 동일 패턴 — `.popover(isPresented:arrowEdge:)` 로
/// 외부 클릭 시 자동 dismiss, 명시 ✕ 버튼 추가 (HIG Nielsen #3).
///
/// # 6 상태
/// - **OFF** (회색) — 릴레이 비활성
/// - **대기** (amber) — 활성, 미연결
/// - **연결 확인 중** (amber) — socket 열림, handshake 진행 중
/// - **연결됨** (accent) — 활성, 페어링 완료
/// - **끊는 중** (warning) — close 진행 중
/// - **오류** (red) — lastError 설정됨
///
/// # ISA-101 CVD 팔레트 (Okabe-Ito)
/// 활성 = `DFColor.accent` (파랑), 대기 = `DFColor.warning` (amber), 꺼짐 = gray.
/// 녹색 회피 — 안전 색상과 혼동 방지.
@MainActor
public struct MobileRelayStatusChip: View {

    @ObservedObject var controller: MobileRelayController

    // popover 표시 여부
    @State private var popoverVisible: Bool = false

    // MARK: - Derived values

    private var state: RelaySessionState { controller.sessionState }

    private var dotColor: Color {
        switch state {
        case .off:             return DFColor.textSecondary
        case .advertising:     return DFColor.warning
        case .handshaking:     return DFColor.warning
        case .paired:          return DFColor.accent
        case .disconnecting:   return DFColor.warning
        case .error:           return .red
        }
    }

    private var chipLabel: String {
        switch state {
        case .off:                        return "모바일 Pilot 꺼짐"
        case .advertising(let code):      return "모바일 Pilot 대기 · \(code)"
        case .handshaking:                return "모바일 Pilot 연결 확인 중…"
        case .paired(let device, _, _, _): return "모바일 Pilot 연결 · \(device)"
        case .disconnecting:              return "모바일 Pilot 끊는 중…"
        case .error:                      return "모바일 Pilot 오류"
        }
    }

    private var isActive: Bool {
        if case .off = state { return false }
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
            MobileRelayPopoverContent(controller: controller,
                                      isPresented: $popoverVisible)
        }
    }

    // MARK: - Helpers

    private var chipHelpText: String {
        switch state {
        case .off:                        return "모바일 Pilot Relay 꺼짐 — 클릭해서 상세 보기"
        case .advertising(let code):      return "모바일 Pilot 대기 중 · 코드: \(code)"
        case .handshaking:                return "모바일 Pilot 연결 확인 중…"
        case .paired(let device, _, _, _): return "모바일 Pilot 연결됨 · \(device)"
        case .disconnecting(let reason):  return "모바일 Pilot 끊는 중 · \(reason)"
        case .error(let message):         return "모바일 Pilot 오류 · \(message)"
        }
    }

    private var accessibilityLabelText: String {
        switch state {
        case .off:                         return "모바일 Pilot Relay 꺼짐"
        case .advertising(let code):       return "모바일 Pilot Relay 대기 중, 페어링 코드 \(code)"
        case .handshaking:                 return "모바일 Pilot Relay 연결 확인 중"
        case .paired(let device, _, _, _): return "모바일 Pilot Relay 연결됨, \(device)"
        case .disconnecting:               return "모바일 Pilot Relay 끊는 중"
        case .error(let message):          return "모바일 Pilot Relay 오류, \(message)"
        }
    }
}

// MARK: - Popover Content

/// Apple Calendar 의 일정 popover 와 동일 패턴으로 구현된 Mobile Relay 제어 패널.
///
/// HIG "Popovers" 가이드라인 준수:
/// - 외부 클릭 시 자동 dismiss (`.popover` modifier 기본 동작)
/// - 명시 ✕ 닫기 버튼 상단 우측 (Nielsen Heuristic #3 — 사용자 통제)
/// - 300pt 고정 폭 (Calendar/AirDrop 표준 범위)
///
/// # 섹션 구성
/// 1. 헤더 (아이콘 + 제목 + ✕ 버튼)
/// 2. 상태 + Toggle (RelaySessionState 6-case 매핑)
/// 3. isRunning=true: Host:Port + 복사 / 페어링코드 + 재발급 / QR / JSON DisclosureGroup
/// 4. 진단 DisclosureGroup (V295-3): sessionId suffix / connectedAt / heartbeat age / timeline
/// 5. footer 안내 문구
@MainActor
struct MobileRelayPopoverContent: View {

    @ObservedObject var controller: MobileRelayController
    @Binding var isPresented: Bool

    @State private var jsonExpanded: Bool = false
    @State private var diagnosticsExpanded: Bool = false
    @State private var copyFeedback: Bool = false
    @State private var hostPickerExpanded: Bool = false

    // MARK: - State

    private var state: RelaySessionState { controller.sessionState }

    private var dotColor: Color {
        switch state {
        case .off:           return DFColor.textSecondary
        case .advertising:   return DFColor.warning
        case .handshaking:   return DFColor.warning
        case .paired:        return DFColor.accent
        case .disconnecting: return DFColor.warning
        case .error:         return .red
        }
    }

    private var statusLabel: String {
        switch state {
        case .off:                         return "꺼짐"
        case .advertising:                 return "대기 중 — iPhone 연결 기다리는 중"
        case .handshaking:                 return "연결 확인 중…"
        case .paired(let device, _, _, _): return "연결됨 · \(device)"
        case .disconnecting(let reason):   return "끊는 중… (\(reason))"
        case .error(let message):          return "오류 — \(message)"
        }
    }

    private var hostPortString: String {
        let host = controller.advertisedHost.isEmpty ? "<your-mac>" : controller.advertisedHost
        return "\(host):\(controller.listenPort)"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.none) {
            header
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DFSpace.sm) {
                    statusSection
                    if controller.isRunning {
                        Divider()
                        hostSection
                        pairingCodeSection
                        qrSection
                        jsonSection
                        Divider()
                        diagnosticsSection
                    }
                    Divider()
                    footerSection
                }
                .padding(DFSpace.md)
            }
        }
        // **V297-fix (2026-05-26, 사용자 보고)** — 300pt 폭이 너무 좁아 toggle/host:port/
        // picker/재발급/footer 우측+좌측이 잘림. HIG popover 일반 폭 (Calendar, AirDrop)
        // 기준 + 한글 행 + 16자 페어링 코드 + Menu picker 모두 한 줄에 수용하도록 380pt
        // 로 확대. 진단 섹션의 timeline 한글 항목도 wrap 없이 한 줄에 끝나도록 조정.
        .frame(width: 380)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "iphone.gen2.radiowaves.left.and.right")
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(DFColor.accent)
            Text("Mobile Pilot Relay")
                .font(.system(size: DFFontSize.s14, weight: .semibold))
            Spacer()
            // ✕ 닫기 버튼 (HIG Nielsen #3 — 사용자 통제 및 자유)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DFFontSize.s16))
                    .foregroundStyle(DFColor.textSecondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("닫기")
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
    }

    // MARK: - Status + Toggle

    private var statusSection: some View {
        HStack(spacing: DFSpace.sm) {
            Circle()
                .fill(dotColor)
                .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)
                .shadow(color: controller.isRunning ? dotColor.opacity(DFOpacity.o70) : .clear,
                        radius: controller.isRunning ? 3 : 0)
            Text(statusLabel)
                .font(.system(size: DFFontSize.s12, weight: .medium))
                .foregroundStyle(controller.isRunning ? dotColor : DFColor.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // **V297-fix** — Toggle 우측 잘림 방지: Spacer 대신 frame(maxWidth:.infinity)
            // 로 label 이 가용 공간을 차지하게 하고, Toggle 은 trailing 고정.
            Toggle("", isOn: Binding(
                get: { controller.isRunning },
                set: { newValue in
                    Task {
                        if newValue { await controller.start() }
                        else { await controller.stop() }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(controller.isRunning ? "릴레이 끄기" : "릴레이 켜기")
        }
    }

    // MARK: - Host : Port + IP picker + 복사

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            PopoverRow(label: "호스트") {
                HStack(spacing: DFSpace.xs2) {
                    Text(hostPortString)
                        .font(.system(size: DFFontSize.s12, design: .monospaced))
                        .foregroundStyle(DFColor.textPrimary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hostPortString, forType: .string)
                        withAnimation(.easeOut(duration: 0.15)) { copyFeedback = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { copyFeedback = false }
                        }
                    } label: {
                        Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: DFFontSize.s11))
                            .foregroundStyle(copyFeedback ? DFColor.success : DFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("호스트:포트 복사")
                }
            }
            // IP picker — 여러 인터페이스가 있을 때만 표시.
            if controller.availableHosts.count > 1 {
                PopoverRow(label: "인터페이스") {
                    Menu {
                        ForEach(controller.availableHosts) { candidate in
                            Button {
                                controller.setAdvertisedHost(candidate.ip)
                            } label: {
                                HStack {
                                    Text(candidate.displayName)
                                    if candidate.ip == controller.advertisedHost {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: DFSpace.xs2) {
                            let current = controller.availableHosts.first {
                                $0.ip == controller.advertisedHost
                            }
                            // **V297-fix** — `(Wi-Fi, LAN)` 우측 잘림 방지: truncation.middle
                            // 로 ifName 과 LAN 표시가 동시에 보이도록.
                            Text(current?.displayName ?? controller.advertisedHost)
                                .font(.system(size: DFFontSize.s11, design: .monospaced))
                                .foregroundStyle(DFColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: DFFontSize.s10))
                                .foregroundStyle(DFColor.textSecondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    // **V297-fix** — .fixedSize() 제거: popover 폭에 맞춰 확장하도록.
                    .help("QR 코드에 사용할 IP 선택 — iPhone 과 같은 Wi-Fi 망의 IP 를 선택하세요")
                }
            }
        }
    }

    // MARK: - 페어링 코드 + 재발급

    private var pairingCodeSection: some View {
        PopoverRow(label: "페어링 코드") {
            HStack(spacing: DFSpace.sm) {
                Text(controller.pairingCode)
                    .font(.system(size: DFFontSize.s18, weight: .bold, design: .monospaced))
                    .foregroundStyle(DFColor.warning)
                    .kerning(4)
                Spacer()
                Button("재발급") {
                    controller.rotatePairingCode()
                }
                .buttonStyle(.borderless)
                .font(.system(size: DFFontSize.s11, weight: .medium))
                .foregroundStyle(DFColor.accent)
                .help("새 페어링 코드 생성 — 현재 코드 무효화")
            }
        }
    }

    // MARK: - QR 코드

    private var qrSection: some View {
        VStack(alignment: .center, spacing: DFSpace.xs) {
            QRCodeImage(payload: controller.qrPayload(), size: 160)
                .accessibilityLabel(
                    "페어링 QR 코드, \(hostPortString)"
                )
                .padding(.top, DFSpace.xs)
            Text("iPhone 카메라로 스캔하세요")
                .font(.system(size: DFFontSize.s11))
                .foregroundStyle(DFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DFSpace.xs2)
    }

    // MARK: - JSON payload DisclosureGroup

    private var jsonSection: some View {
        DisclosureGroup(isExpanded: $jsonExpanded) {
            Text(controller.qrPayload())
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .textSelection(.enabled)
                .lineLimit(6)
                .padding(.top, DFSpace.xs2)
        } label: {
            Text("JSON payload")
                .font(.system(size: DFFontSize.s11, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    // MARK: - 진단 DisclosureGroup (V295-3)
    //
    // 비행 데이터 레코더처럼 핵심 timeline 항상 보임 — 개발·디버깅 시 세션 진단 정보를
    // 한눈에 확인할 수 있는 접이식 섹션. 기본 접힘 상태로 일반 사용자 UX 를 방해하지 않는다.

    private var diagnosticsSection: some View {
        DisclosureGroup(isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                // Session ID suffix (마지막 8자)
                if let sid = controller.activeSessionId {
                    let suffix = sid.count > 8 ? "…\(sid.suffix(8))" : sid
                    DiagRow(label: "Session ID", value: suffix)
                }
                // 연결 시작 시각
                if let since = controller.pairedSince {
                    DiagRow(label: "연결 시작", value: timeFormatter.string(from: since))
                }
                // 마지막 heartbeat age
                heartbeatRow
                // Timeline (최근 5건)
                if !controller.lifecycleTimeline.isEmpty {
                    Divider().padding(.vertical, DFSpace.xs2)
                    Text("Timeline")
                        .font(DFFont.labelStrong)
                        .foregroundStyle(DFColor.textSecondary)
                    let recent = Array(controller.lifecycleTimeline.suffix(5))
                    ForEach(recent) { entry in
                        HStack(alignment: .top, spacing: DFSpace.xs2) {
                            Text(timeFormatter.string(from: entry.timestamp))
                                .font(DFFont.monoMicro)
                                .foregroundStyle(DFColor.textSecondary)
                                .frame(width: 52, alignment: .trailing)
                            Text(entry.event)
                                .font(DFFont.label)
                                .foregroundStyle(DFColor.textPrimary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(.top, DFSpace.xs2)
        } label: {
            Text("진단")
                .font(.system(size: DFFontSize.s11, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    /// Heartbeat age 행 — stale (>3s) 이면 amber 경고 표시.
    @ViewBuilder
    private var heartbeatRow: some View {
        if let hb = controller.lastHeartbeatAt {
            let age = Date().timeIntervalSince(hb)
            let isStale = age > 3.0
            let ageStr = String(format: "%.1f초 전", age) + (isStale ? " (stale)" : "")
            HStack(spacing: DFSpace.xs2) {
                Text("마지막 신호")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
                    .frame(minWidth: 60, alignment: .trailing)
                Text(ageStr)
                    .font(DFFont.monoLabel)
                    .foregroundStyle(isStale ? DFColor.warning : DFColor.textPrimary)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        Text("iPhone OP Pilot 앱 → Connect 탭 → QR 스캔")
            .font(.system(size: DFFontSize.s10))
            .foregroundStyle(DFColor.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Formatters

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}

// MARK: - PopoverRow helper

/// popover 내부 label-value 행 — 좌측 label 고정 폭, 우측 콘텐츠.
private struct PopoverRow<Content: View>: View {
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

// MARK: - DiagRow helper

/// 진단 섹션 내 label-value 단일 행.
private struct DiagRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: DFSpace.xs2) {
            Text(label)
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
                .frame(minWidth: 60, alignment: .trailing)
            Text(value)
                .font(DFFont.monoLabel)
                .foregroundStyle(DFColor.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }
}
