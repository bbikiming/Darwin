import SwiftUI
import MobilePilotKit

public struct ConnectScreen: View {

    @EnvironmentObject var state: AppState
    @State private var manualHost: String = ""
    @State private var manualPort: String = "17370"
    @State private var manualCode: String = ""
    @State private var qrPasteString: String = ""
    @State private var pasteError: String?
    // P1-1 fix (truth-gap report, 2026-05-25): Bonjour discovery tap → require
    // the user to enter the actual 6-digit code shown on the Mac.
    @State private var pendingDiscoveryTarget: RelayDiscoveryResult?
    @State private var pendingDiscoveryCode: String = ""

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                currentStatusSection
                modeSection
                guideSection
                discoverySection
                qrSection
                manualSection
                troubleshootSection
            }
            .navigationTitle("연결")
            .accessibilityIdentifier("connect.root")
            .onAppear { state.startDiscovery() }
            .onDisappear { state.stopDiscovery() }
            .sheet(item: $pendingDiscoveryTarget) { target in
                DiscoveryPairingSheet(target: target,
                                      code: $pendingDiscoveryCode,
                                      onConnect: { code in
                                          pendingDiscoveryTarget = nil
                                          Task {
                                              await state.connect(to: RelayEndpoint(
                                                  host: target.host,
                                                  port: target.port,
                                                  pairingCode: code.trimmingCharacters(in: .whitespaces)))
                                          }
                                      },
                                      onCancel: {
                                          pendingDiscoveryTarget = nil
                                      })
            }
        }
    }

    private var currentStatusSection: some View {
        Section {
            ConnectionStatusRow(title: "Mac 앱",
                                value: macStatusText,
                                systemImage: "desktopcomputer",
                                tone: state.isMacReady ? .success : .neutral)
            ConnectionStatusRow(title: "로봇",
                                value: robotStatusText,
                                systemImage: "cpu",
                                tone: robotStatusTone)
            if let endpoint = state.pairedEndpoint {
                ConnectionStatusRow(title: "연결 대상",
                                    value: "\(endpoint.host):\(endpoint.port)",
                                    systemImage: "network",
                                    tone: .info)
            }
        } header: {
            Text("지금 상태")
        } footer: {
            Text("연결 탭은 Mac 앱과 실제 로봇을 찾는 곳입니다. 움직이는 명령과 긴급 정지는 동작/조종기 화면에서만 다룹니다.")
        }
    }

    private var modeSection: some View {
        Section("사용 방식") {
            Picker("사용 방식", selection: Binding(get: { state.connectionMode },
                                                set: { mode in
                Task { await state.setConnectionMode(mode) }
            })) {
                Text("연습").tag(AppState.ConnectionMode.mockReview)
                Text("실제 연결").tag(AppState.ConnectionMode.realRelay)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("connect.mode.picker")

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.connectionMode == .mockReview {
                Button {
                    Task { await state.connectMockReview() }
                } label: {
                    Label("연습 모드 시작", systemImage: "play.circle.fill")
                }
                .accessibilityIdentifier("connect.mock.open")
            }
        }
    }

    private var guideSection: some View {
        Section("연결 순서") {
            ForEach(connectionSteps) { step in
                ConnectionStepRow(step: step)
            }
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            if state.connectionMode == .mockReview {
                Label("연습 모드에서는 Mac 앱 없이 화면과 안전 흐름을 확인합니다.",
                      systemImage: "cube.transparent")
                    .foregroundStyle(.secondary)
            } else if state.discovered.isEmpty {
                Label("같은 Wi‑Fi에서 Mac 앱을 찾는 중입니다.",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Button {
                    state.startDiscovery()
                } label: {
                    Label("다시 찾기", systemImage: "arrow.clockwise")
                }
            } else {
                ForEach(state.discovered) { result in
                    Button {
                        pendingDiscoveryCode = ""
                        pendingDiscoveryTarget = result
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(DS.Color.info)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.displayName).font(.body.weight(.semibold))
                                Text("\(result.host):\(result.port)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "number.square.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("6자리 코드 필요")
                        }
                    }
                    .accessibilityIdentifier("connect.discovered.\(result.id)")
                }
            }
        } header: {
            Text("Mac 자동 찾기")
        } footer: {
            Text("Darwin Forge Mac 앱에서 Mobile Pilot Relay를 켠 뒤, Mac 화면의 6자리 코드를 iPhone에 입력하세요.")
        }
    }

    private var qrSection: some View {
        Section {
            TextField("Mac에서 복사한 연결 텍스트를 붙여넣기",
                      text: $qrPasteString, axis: .vertical)
                .font(.caption.monospaced())
                .lineLimit(3, reservesSpace: true)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("connect.qr.paste")
            Button {
                Task { await tryQR() }
            } label: {
                Label("붙여넣은 정보로 연결", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("connect.qr.scan")
            .disabled(qrPasteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let pasteError {
                Label(pasteError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        } header: {
            Text("공유 텍스트로 연결")
        } footer: {
            Text("카메라 스캔은 아직 포함되지 않았습니다. 지금은 Mac 앱이 표시한 연결 텍스트를 복사해 붙여넣습니다.")
        }
    }

    private var manualSection: some View {
        Section {
            TextField("예: 192.168.0.23", text: $manualHost)
                .textContentType(.URL)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("connect.manual.host")
            TextField("포트", text: $manualPort)
                .keyboardTypeIfAvailable(.numberPad)
                .accessibilityIdentifier("connect.manual.port")
            TextField("Mac 화면의 6자리 코드", text: $manualCode)
                .keyboardTypeIfAvailable(.numberPad)
                .accessibilityIdentifier("connect.manual.code")
            Button {
                Task { await tryManual() }
            } label: {
                Label("IP로 연결", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(!isManualReady)
            .accessibilityIdentifier("connect.manual.submit")
        } header: {
            Text("IP 직접 입력")
        } footer: {
            Text("자동 찾기가 되지 않을 때만 사용하세요. Mac과 iPhone이 같은 네트워크에 있어야 합니다.")
        }
    }

    private var troubleshootSection: some View {
        Section("안 보일 때 확인") {
            ConnectionHelpRow(icon: "switch.2",
                              text: "Mac Darwin Forge 앱에서 Mobile Pilot Relay가 켜져 있는지 확인합니다.")
            ConnectionHelpRow(icon: "wifi",
                              text: "iPhone과 Mac이 같은 Wi‑Fi에 연결되어 있는지 확인합니다.")
            ConnectionHelpRow(icon: "lock.shield",
                              text: "iOS 설정에서 OP Pilot의 로컬 네트워크 권한을 허용합니다.")
            ConnectionHelpRow(icon: "powerplug.fill",
                              text: "실제 로봇 연결은 Mac 앱이 로봇 전원과 네트워크를 먼저 인식해야 표시됩니다.")
            if let error = state.lastError {
                Label(error, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var connectionSteps: [ConnectionStep] {
        [
            ConnectionStep(number: 1,
                           title: "Mac 앱 준비",
                           detail: "Mac에서 Darwin Forge를 열고 Mobile Pilot Relay를 켭니다.",
                           isDone: state.isMacReady || !state.discovered.isEmpty || state.connectionMode == .mockReview),
            ConnectionStep(number: 2,
                           title: "같은 Wi‑Fi 확인",
                           detail: "iPhone과 Mac이 같은 네트워크에 있어야 자동으로 찾을 수 있습니다.",
                           isDone: state.connectionMode == .mockReview || !state.discovered.isEmpty || state.isMacReady),
            ConnectionStep(number: 3,
                           title: "6자리 코드 입력",
                           detail: "Mac 화면의 숫자를 입력해 이 iPhone을 승인합니다.",
                           isDone: state.pairedEndpoint != nil),
            ConnectionStep(number: 4,
                           title: "상태 대시보드 확인",
                           detail: "연결 후 동작 탭의 상태에서 전압, 지연, 로봇 상태를 확인합니다.",
                           isDone: state.telemetry != nil)
        ]
    }

    private var macStatusText: String {
        switch state.transport {
        case .connected: return "연결됨"
        case .connecting, .handshaking: return "연결 중"
        case .disconnected: return "끊김"
        case .idle: return "대기"
        }
    }

    private var robotStatusText: String {
        guard let telemetry = state.telemetry else { return "수신 전" }
        switch telemetry.robot {
        case .connected: return "연결됨"
        case .sim: return "연습 중"
        case .stale: return "응답 지연"
        case .busBusy: return "사용 중"
        case .disconnected: return "미연결"
        case .estopped: return "정지 상태"
        }
    }

    private var robotStatusTone: DSChip.Tone {
        guard let telemetry = state.telemetry else { return .neutral }
        switch telemetry.robot {
        case .connected: return .success
        case .sim: return .info
        case .stale, .busBusy: return .warning
        case .disconnected: return .neutral
        case .estopped: return .danger
        }
    }

    private var modeDescription: String {
        switch state.connectionMode {
        case .mockReview:
            return "연습 모드는 실제 로봇 없이 UI, 안전 흐름, 테스트 기록을 확인합니다."
        case .realRelay:
            return "실제 연결은 Mac 앱을 중계기로 사용해 로봇 상태와 명령을 주고받습니다."
        }
    }

    private var isManualReady: Bool {
        !manualHost.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(manualPort) ?? 0) > 0 &&
        PairingCode.validate(manualCode)
    }

    private func tryQR() async {
        do {
            pasteError = nil
            let payload = try QRPairingDecoder.decode(qrPasteString)
            await state.connect(to: RelayEndpoint(host: payload.host,
                                                  port: payload.port,
                                                  pairingCode: payload.pairingCode))
        } catch {
            pasteError = "연결 텍스트 형식을 확인하세요."
        }
    }

    private func tryManual() async {
        guard let port = Int(manualPort) else { return }
        await state.connect(to: RelayEndpoint(
            host: manualHost.trimmingCharacters(in: .whitespaces),
            port: port,
            pairingCode: manualCode.trimmingCharacters(in: .whitespaces)))
    }
}

private struct ConnectionStep: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
}

private struct ConnectionStepRow: View {
    let step: ConnectionStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(step.isDone ? DS.Color.success.opacity(0.18) : DS.Color.elevated)
                if step.isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(DS.Color.success)
                } else {
                    Text("\(step.number)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.number)단계 \(step.title). \(step.detail)")
    }
}

private struct ConnectionStatusRow: View {
    let title: String
    let value: String
    let systemImage: String
    let tone: DSChip.Tone

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.foreground)
        }
    }
}

private struct ConnectionHelpRow: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    @ViewBuilder
    func keyboardTypeIfAvailable(_ type: UIKeyboardTypeShim) -> some View {
        #if canImport(UIKit)
        self.keyboardType(type.uiType)
        #else
        self
        #endif
    }
}

// MARK: - Pairing sheet

private struct DiscoveryPairingSheet: View {
    let target: RelayDiscoveryResult
    @Binding var code: String
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("연결할 Mac") {
                    LabeledContent("이름", value: target.displayName)
                    LabeledContent("주소") {
                        Text("\(target.host):\(target.port)")
                            .font(.caption.monospacedDigit())
                    }
                }
                Section("6자리 코드") {
                    TextField("Mac 화면의 숫자", text: $code)
                        .keyboardTypeIfAvailable(.numberPad)
                        .font(.title3.monospacedDigit())
                        .accessibilityIdentifier("connect.discovered.code")
                    Text("Mac 앱의 Mobile Pilot Relay 패널에 표시된 숫자를 그대로 입력하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Mac 연결")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("연결") { onConnect(code) }
                        .disabled(!PairingCode.validate(code))
                        .accessibilityIdentifier("connect.discovered.submit")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

enum UIKeyboardTypeShim { case numberPad
    #if canImport(UIKit)
    var uiType: UIKeyboardType {
        switch self { case .numberPad: return .numberPad }
    }
    #endif
}

#if canImport(UIKit)
import UIKit
#endif
