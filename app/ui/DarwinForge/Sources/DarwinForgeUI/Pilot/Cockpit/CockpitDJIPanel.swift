import Foundation
import GameController
import SwiftUI

/// Cockpit 의 DJI 조종기 페어링 패널.
///
/// # 두 가지 경로
///
/// 1. **MFi 호환 RC (DJI RC-N1 등)** → `GameController.framework` 가 자동 인식,
///    `CockpitGameControllerWatcher` 가 stick 입력 push. 본 패널의
///    `GAMECONTROLLER.FRAMEWORK` 섹션이 진단 표시.
///
/// 2. **DJI FPV Remote Controller 3 등 MFi 미인증 USB HID** →
///    `DJIVirtualJoystickHIDClient` 가 **IOKit HID Manager** 로 직접 매칭
///    (vendor=0x2CA3, product=0x1021, "DJI Virtual Joystick"). MFi 인증이 없어
///    `GameController.framework` 가 무시하는 디바이스도 본 경로로 잡힌다.
///    `DJI VIRTUAL JOYSTICK (HID)` 섹션이 axis raw 값을 라이브로 표시하므로
///    사용자가 stick 을 움직이면 즉시 변동이 보인다 — "연결됐는지 모르겠다" 의
///    가장 흔한 원인이 해소된다.
///
/// 두 경로는 동시에 active 가능하다. cockpit `apply(...)` 는 마지막 호출만 보존하므로
/// 두 source 가 idle 일 때 다른 쪽이 자연스럽게 통제권을 가진다.
///
/// 추가로 컨트롤러 없이도 입력 → 모션 흐름을 확인할 수 있도록 **Mock DJI 데모**
/// (자동 stick 패턴) 옵션도 제공한다. Mock 진입 시 본 패널이 HID watcher 를
/// `pauseStreaming` 시켜 사용자 혼란을 막는다.
@MainActor
public final class CockpitDJIController: ObservableObject {

    public enum Status: Equatable {
        case idle
        case searching
        case connected(name: String)
        case mockActive
        case notFound
    }

    @Published public private(set) var status: Status = .idle
    /// USB / BT controller diagnostics — refreshed every poll for the UI.
    /// `GameController.framework` 가 인식한 모든 컨트롤러를 그대로 노출하여
    /// 사용자가 USB 연결이 인식 안 되는 원인을 즉시 진단할 수 있다.
    @Published public private(set) var diagnostics: [ControllerDiagnostic] = []

    public struct ControllerDiagnostic: Identifiable, Equatable {
        public let id = UUID()
        public let vendorName: String
        public let productCategory: String
        public let hasExtendedGamepad: Bool
        public let hasMicroGamepad: Bool
        public let isAttachedToDevice: Bool
    }

    private weak var cockpit: CockpitState?
    private var searchTask: Task<Void, Never>?
    private var mockTimer: Timer?
    private var mockStartedAt: Date?
    /// 1Hz polling timer — 사용자가 패널을 열어 두는 동안 USB 연결/해제 변화를
    /// 즉시 시각화. notification-only 였던 종전 watcher 는 일부 USB HID 가 적시에
    /// notification 을 발사하지 않는 경우를 놓쳤다 (사용자 보고).
    private var diagnosticsTimer: Timer?

    public init(cockpit: CockpitState) {
        self.cockpit = cockpit
        refreshDiagnostics()
    }

    public func startDiagnosticsPolling() {
        guard diagnosticsTimer == nil else { return }
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                                repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDiagnostics() }
        }
    }

    public func stopDiagnosticsPolling() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func refreshDiagnostics() {
        diagnostics = GCController.controllers().map { c in
            ControllerDiagnostic(
                vendorName: c.vendorName ?? "Unknown",
                productCategory: c.productCategory,
                hasExtendedGamepad: c.extendedGamepad != nil,
                hasMicroGamepad: c.microGamepad != nil,
                isAttachedToDevice: c.isAttachedToDevice)
        }
    }

    // MARK: - Search

    public func startSearch() {
        cancelMock()
        status = .searching
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // 4-second discovery window. 실제로 GameController.framework 가 즉시
            // 알아챌 가능성이 높지만 사용자 인지를 위해 진행 표시 유지.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                if let name = await self.detectController() {
                    self.status = .connected(name: name)
                    return
                }
            }
            await MainActor.run {
                guard let self else { return }
                if case .connected = self.status { return }
                self.status = .notFound
            }
        }
    }

    public func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        status = .idle
    }

    public func updateFromWatcher() {
        // 컨트롤러가 watcher 에서 자동 연결 → status 동기화.
        if let name = cockpit?.connectedController,
           case .connected(let cur) = status, cur == name {
            return  // 이미 same
        }
        if let name = cockpit?.connectedController {
            status = .connected(name: name)
        } else if case .connected = status {
            status = .idle
        }
    }

    @MainActor
    private func detectController() -> String? {
        if let name = cockpit?.connectedController { return name }
        return GCController.controllers().first?.vendorName
    }

    // MARK: - Mock DJI demo

    /// 30 Hz mock stick driver — 사용자가 실제 컨트롤러 없이도 cockpit 의
    /// stick → motion 흐름을 시각적으로 검증할 수 있게 자동 패턴 송신.
    ///
    /// 패턴 (12초 cycle):
    /// - 0-3s : 전진 (leftY=-0.8)
    /// - 3-5s : 우회전 (turn=+0.6) + 약한 전진
    /// - 5-7s : 좌회전 (turn=-0.6) + 약한 전진
    /// - 7-10s: 측면 우 (leftX=+0.8)
    /// - 10-12s: 정지
    public func startMockDemo() {
        cancelSearch()
        status = .mockActive
        mockStartedAt = Date()
        mockTimer?.invalidate()
        mockTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMock() }
        }
    }

    public func stopMockDemo() {
        mockTimer?.invalidate()
        mockTimer = nil
        mockStartedAt = nil
        cockpit?.apply(leftX: 0, leftY: 0, turn: 0, from: .djiRC)
        status = .idle
    }

    private func cancelMock() {
        if mockTimer != nil {
            stopMockDemo()
        }
    }

    private func tickMock() {
        // **CRITICAL #1 fix (code review)**: 종전 case 3..<5 가 `tn = 0.6` 직후
        // `tn = -0.6` dead write — case 5..<7 의 `tn = 0.6` (좌회전) 와 같은
        // 효과가 되어 두 구간 모두 좌회전이었다. 명시 분기로 좌/우 회전 패턴 복원.
        guard let cockpit, let start = mockStartedAt else { return }
        let t = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: 12.0)
        var lx = 0.0
        var ly = 0.0
        var tn = 0.0
        switch t {
        case 0..<3:
            ly = -0.8                 // 전진
        case 3..<5:
            ly = -0.3
            tn = -0.6                 // 우회전 (turn -1 = 우)
        case 5..<7:
            ly = -0.3
            tn = 0.6                  // 좌회전 (turn +1 = 좌)
        case 7..<10:
            lx = 0.8                  // 측면 우
        default:
            break                     // 정지
        }
        cockpit.apply(leftX: lx, leftY: ly, turn: tn, from: .djiRC)
    }
}

// MARK: - SwiftUI panel

public struct CockpitDJIPanel: View {
    @ObservedObject var cockpit: CockpitState
    @StateObject private var controller: CockpitDJIController
    #if canImport(IOKit)
    @StateObject private var hidWatcher: DJIVirtualJoystickWatcher
    #endif
    /// Accordion 상태 — collapsed (default) 시 헤더 + 1-줄 status 만 표시.
    /// 사용자가 chevron 클릭으로 토글.
    @State private var expanded: Bool = false
    /// 사용자 binding settings sheet 가 열려 있는지.
    @State private var bindingSheetOpen: Bool = false
    /// 현재 사용자 binding profile — sheet 에서 편집 시 commit, panel 이 hid watcher
    /// 에 전달.
    @State private var bindingProfile: DJIBindingProfile = DJIBindingProfileStore.load()

    public init(cockpit: CockpitState) {
        self.cockpit = cockpit
        _controller = StateObject(wrappedValue: CockpitDJIController(cockpit: cockpit))
        #if canImport(IOKit)
        _hidWatcher = StateObject(wrappedValue: DJIVirtualJoystickWatcher(cockpit: cockpit))
        #endif
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            accordionHeader
            if expanded {
                statusRow
                actionRow
                hint
                diagnosticsBlock
                #if canImport(IOKit)
                hidBlock
                #endif
            } else {
                collapsedStatusRow
            }
        }
        .cockpitPanel(tint: tone, strokeOpacity: 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: expanded)
        #if canImport(IOKit)
        .sheet(isPresented: $bindingSheetOpen) {
            CockpitDJIBindingSheet(
                isPresented: $bindingSheetOpen,
                profile: $bindingProfile,
                watcher: hidWatcher)
        }
        #endif
        .onAppear {
            controller.startDiagnosticsPolling()
            #if canImport(IOKit)
            hidWatcher.start()
            // 저장된 profile 을 watcher 에 즉시 전달 (panel 진입 시 1회).
            hidWatcher.applyBindingProfile(bindingProfile)
            #endif
        }
        .onChange(of: bindingProfile) { _, newValue in
            #if canImport(IOKit)
            hidWatcher.applyBindingProfile(newValue)
            #endif
        }
        .onDisappear {
            controller.stopMockDemo()
            controller.stopDiagnosticsPolling()
            #if canImport(IOKit)
            hidWatcher.stop()
            #endif
        }
        .onReceive(cockpit.$connectedController) { _ in
            controller.updateFromWatcher()
        }
        #if canImport(IOKit)
        .onChange(of: controller.status) { _, newStatus in
            // Mock 데모 active 일 때는 HID watcher 가 같은 cockpit 에 race 하지 않도록
            // pause. 데모 종료 시 자동 재개.
            if newStatus == .mockActive {
                hidWatcher.pauseStreaming()
            } else {
                hidWatcher.resumeStreaming()
            }
        }
        #endif
    }

    #if canImport(IOKit)
    @ViewBuilder
    private var hidBlock: some View {
        Divider().background(CockpitColors.live.opacity(0.2))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DJI VIRTUAL JOYSTICK (HID)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Circle()
                    .fill(hidWatcher.isStreaming
                          ? CockpitColors.live
                          : CockpitColors.warn)
                    .frame(width: 7, height: 7)
                Text(hidWatcher.isStreaming ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(hidWatcher.isStreaming
                                     ? CockpitColors.live
                                     : CockpitColors.warn)
            }
            if let name = hidWatcher.connectedName {
                Text(name)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                hidAxisRow
                hidInversionRow
                hidStaleRow
            } else {
                Text("VID 0x2CA3 / PID 0x1021 미검색. RC3 USB-A 어댑터로 Mac 연결 후 ‘Game Controller’ 모드 진입 필요.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(CockpitColors.warn.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var hidAxisRow: some View {
        let r = hidWatcher.lastReport
        // **반응형(리뷰 H2)**: 고정폭 5셀(290pt)이 224pt 컬럼을 넘쳐 → flexible 셀로 균등 분배.
        HStack(spacing: 4) {
            axisCell("X",  value: r?.axisX ?? 0)
            axisCell("Y",  value: r?.axisY ?? 0)
            axisCell("Z",  value: r?.axisZ ?? 0)
            axisCell("Rx", value: r?.axisRx ?? 0)
            axisCell("Ry", value: r?.axisRy ?? 0)
        }
    }

    private func axisCell(_ name: String, value: Double) -> some View {
        VStack(spacing: 1) {
            Text(name)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Text(String(format: "%+.2f", value))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(abs(value) > 0.05
                                 ? CockpitColors.live
                                 : .white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private var hidInversionRow: some View {
        // **ISSUE-G fix**: binding profile 이 활성 (panel onAppear 에서 항상 적용) 이면
        // mapper 가 profile 우선 사용하므로 inversion 토글은 silent no-op. 사용자가
        // 만져도 효과 없는 ghost 컨트롤을 노출하지 않도록 — profile 활성 시 row 자체
        // 를 안내 텍스트로 대체.
        Group {
            if hidWatcher.bindingProfile != nil {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9))
                        .foregroundStyle(CockpitColors.cyan)
                    Text("커스텀 매핑 활성 (▦ 버튼으로 편집)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(CockpitColors.cyan.opacity(0.85))
                }
            } else {
                HStack(spacing: 8) {
                    Text("INVERT")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    inversionToggle("FWD", isOn: Binding(
                        get: { hidWatcher.inversion.invertForward },
                        set: { hidWatcher.toggleInvertForward($0) }))
                    inversionToggle("LAT", isOn: Binding(
                        get: { hidWatcher.inversion.invertLateral },
                        set: { hidWatcher.toggleInvertLateral($0) }))
                    inversionToggle("TRN", isOn: Binding(
                        get: { hidWatcher.inversion.invertTurn },
                        set: { hidWatcher.toggleInvertTurn($0) }))
                }
            }
        }
    }

    private func inversionToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? .black : .white.opacity(0.7))
                .frame(width: 32, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn.wrappedValue
                              ? CockpitColors.cyan
                              : Color.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help("\(label) 축 부호 반전 — stick 을 움직였을 때 cockpit 이 반대로 반응하면 토글하세요.")
    }

    @ViewBuilder
    private var hidStaleRow: some View {
        if let at = hidWatcher.lastReportAt {
            let dt = Date().timeIntervalSince(at)
            let stale = dt > 0.5
            HStack(spacing: 4) {
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "dot.radiowaves.right")
                    .font(.system(size: 9))
                    .foregroundStyle(stale ? CockpitColors.warn : CockpitColors.live)
                Text(stale
                     ? String(format: "마지막 입력 %.1fs 전 — RC 절전?", dt)
                     : "입력 수신 중")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(stale ? CockpitColors.warn : .white.opacity(0.55))
            }
        }
    }
    #endif

    @ViewBuilder
    private var diagnosticsBlock: some View {
        Divider().background(CockpitColors.live.opacity(0.2))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GAMECONTROLLER.FRAMEWORK")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("\(controller.diagnostics.count)")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(controller.diagnostics.isEmpty
                                     ? CockpitColors.warn
                                     : CockpitColors.live)
            }
            if controller.diagnostics.isEmpty {
                Text("인식된 컨트롤러 없음. USB MFi 호환 모드 또는 BT 페어링 필요.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(CockpitColors.warn.opacity(0.85))
            } else {
                ForEach(controller.diagnostics) { d in
                    diagnosticRow(d)
                }
            }
        }
    }

    private func diagnosticRow(_ d: CockpitDJIController.ControllerDiagnostic) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(d.hasExtendedGamepad ? CockpitColors.live : CockpitColors.warn)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.vendorName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(d.productCategory) · \(profileLabel(d))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private func profileLabel(_ d: CockpitDJIController.ControllerDiagnostic) -> String {
        if d.hasExtendedGamepad { return "extendedGamepad ✓" }
        if d.hasMicroGamepad { return "microGamepad (제한적)" }
        return "MFi 미호환 — cockpit 매핑 불가"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(tone)
            Text("DJI 조종기")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Circle().fill(tone).frame(width: 7, height: 7)
        }
    }

    /// 아코디언 header — 전체 row 가 클릭 가능 (contentShape + hit target 확장).
    /// chevron 은 둥근 background 위에 14pt 로 명확한 affordance 제공.
    private var accordionHeader: some View {
        // **방법론 (Apple HIG nested controls)**: 한 row 안에 toggle (큰 영역) +
        // 별도 action button (작은 영역) 패턴은 macOS Settings.app 의 sidebar row 와
        // 동일. tap target 이 명확히 분리되도록 두 개의 Button 으로 분할.
        HStack(spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13))
                        .foregroundStyle(tone)
                    Text("DJI 조종기")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Circle().fill(tone).frame(width: 8, height: 8)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cockpit.dji.accordion.toggle")
            .accessibilityLabel(expanded ? "DJI 패널 접기" : "DJI 패널 펼치기")

            #if canImport(IOKit)
            Button {
                bindingSheetOpen = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.10))
                            .overlay(Circle().stroke(tone.opacity(0.4), lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("DJI 키 매핑 설정")
            .help("DJI 컨트롤러 키를 동작에 매핑합니다.")
            .accessibilityIdentifier("cockpit.dji.settings.open")
            #endif

            Button {
                expanded.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .overlay(Circle().stroke(tone.opacity(0.4), lineWidth: 1))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "패널 접기" : "패널 펼치기")
        }
    }

    /// 접힌 상태에서 보여줄 1-줄 status. 컨트롤러 이름 또는 상태 라벨.
    private var collapsedStatusRow: some View {
        HStack(spacing: 6) {
            statusIcon
                .font(.system(size: 10))
            Text(collapsedStatusText.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tone)
                .lineLimit(1)
            Spacer()
        }
    }

    private var collapsedStatusText: String {
        switch controller.status {
        case .idle:           return "대기 · 펼치기"
        case .searching:      return "검색 중…"
        case .connected(let name): return name
        case .mockActive:     return "Mock 데모"
        case .notFound:       return "미발견 · 펼치기"
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(tone)
                if let detail = statusDetail {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            switch controller.status {
            case .idle, .notFound:
                actionButton("검색", systemImage: "magnifyingglass",
                             tint: CockpitColors.cyan) {
                    controller.startSearch()
                }
                actionButton("Mock 데모", systemImage: "play.circle",
                             tint: CockpitColors.live) {
                    controller.startMockDemo()
                }
            case .searching:
                actionButton("취소", systemImage: "xmark.circle",
                             tint: CockpitColors.warn) {
                    controller.cancelSearch()
                }
            case .connected:
                actionButton("새로 검색", systemImage: "arrow.clockwise",
                             tint: CockpitColors.cyan) {
                    controller.startSearch()
                }
            case .mockActive:
                actionButton("Mock 정지", systemImage: "stop.circle",
                             tint: CockpitColors.danger) {
                    controller.stopMockDemo()
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String,
                              tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(tint.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var hint: some View {
        switch controller.status {
        case .idle:
            Text("BT/USB 페어링 후 검색하거나, 컨트롤러 없이 Mock 데모로 동작 확인.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        case .searching:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
                Text("DJI RC MFi 모드 진입 필요. 4초간 검색 중...")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case .connected:
            Text("좌·우 스틱 입력이 cockpit HUD 에 실시간 반영됩니다.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        case .mockActive:
            Text("자동 데모 입력 송신 중 — 12초 cycle (전진·회전·측면).")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        case .notFound:
            Text("컨트롤러를 찾지 못함. MFi 호환 모드 확인 또는 Mock 데모 사용.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(CockpitColors.warn.opacity(0.85))
        }
    }

    private var statusIcon: some View {
        Group {
            switch controller.status {
            case .idle, .notFound:
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
            case .searching:
                Image(systemName: "dot.radiowaves.left.and.right")
            case .connected:
                Image(systemName: "checkmark.seal.fill")
            case .mockActive:
                Image(systemName: "play.fill")
            }
        }
        .foregroundStyle(tone)
        .font(.system(size: 16))
    }

    private var statusLabel: String {
        switch controller.status {
        case .idle:            return "대기"
        case .searching:       return "검색 중"
        case .connected:       return "연결됨"
        case .mockActive:      return "Mock 데모"
        case .notFound:        return "미발견"
        }
    }

    private var statusDetail: String? {
        switch controller.status {
        case .connected(let name): return name
        case .mockActive:          return "DJI RC (시뮬)"
        case .notFound:            return "다시 시도 또는 Mock 사용"
        default:                   return nil
        }
    }

    private var tone: Color {
        switch controller.status {
        case .idle, .notFound:  return CockpitColors.warn
        case .searching:        return CockpitColors.cyan
        case .connected:        return CockpitColors.live
        case .mockActive:       return CockpitColors.live
        }
    }
}
