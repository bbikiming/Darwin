import SwiftUI
import MobilePilotKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ConnectPhase
//
// 공항 체크인 4단계에 대응하는 연결 화면 단계.
// ConnectScreen 과 ConnectStepBar 가 공유하므로 internal 접근.

enum ConnectPhase: Int, CaseIterable {
    case discovery    = 0  // Mac 탐색
    case pairing      = 1  // OTP 핸드셰이크
    case safety       = 2  // 안전 점검 안내
    case arm          = 3  // ARM 준비 확인

    var title: String {
        switch self {
        case .discovery: return "Mac 발견"
        case .pairing:   return "핸드셰이크"
        case .safety:    return "안전 점검"
        case .arm:       return "ARM 준비"
        }
    }
}

// MARK: - N of 4 Step Bar (V292-5)

/// 공항 탑승 안내 화면처럼 현재 단계를 시각적으로 표시하는 4단계 진행 표시줄.
struct ConnectStepBar: View {
    let phase: ConnectPhase

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(ConnectPhase.allCases, id: \.rawValue) { step in
                stepCell(step)
                if step != .arm {
                    Rectangle()
                        .fill(step.rawValue < phase.rawValue
                              ? DS.Color.success
                              : DS.Color.divider)
                        .frame(height: DS.Stroke.regular)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("연결 단계: \(phase.title), \(phase.rawValue + 1) / \(ConnectPhase.allCases.count)")
    }

    private func stepCell(_ step: ConnectPhase) -> some View {
        let isDone = step.rawValue < phase.rawValue
        let isCurrent = step == phase

        return VStack(spacing: DS.Space.xxs) {
            ZStack {
                Circle()
                    .fill(isDone ? DS.Color.success
                          : isCurrent ? DS.Color.brand
                          : DS.Color.elevated)
                    .frame(width: 24, height: 24)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(isCurrent ? .white : DS.Color.secondaryText)
                }
            }
            Text(step.title)
                .font(.system(size: 9, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? DS.Color.brand
                                 : isDone ? DS.Color.success
                                 : DS.Color.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: DS.Hit.minimum / 2)
    }
}

// MARK: - DiscoveredMacCard (V292-1)

/// HomeKit 스타일의 발견된 Mac 카드.
/// 이 카드가 여행사 창구 직원 카드처럼 "이 Mac에 연결하겠어요?" 를 명확히 물어본다.
struct DiscoveredMacCard: View {
    let result: RelayDiscoveryResult
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Space.m) {
                ZStack {
                    Circle()
                        .fill(isSelected ? DS.Color.brandSoft : DS.Color.elevated)
                        .frame(width: 44, height: 44)
                    Image(systemName: "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(isSelected ? DS.Color.brand : DS.Color.secondaryText)
                }

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(result.displayName)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.primaryText)
                    Text("\(result.host):\(result.port)")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundStyle(DS.Color.secondaryText)
                    Text("마지막 확인: \(lastSeenText)")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Color.tertiaryText)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(isSelected ? DS.Color.brand : DS.Color.secondaryText)
            }
            .padding(DS.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(DS.Color.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .stroke(isSelected ? DS.Color.brand : DS.Color.divider,
                                    lineWidth: isSelected ? DS.Stroke.emphasis : DS.Stroke.hairline)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.displayName), \(result.host):\(result.port)")
        .accessibilityHint(isSelected ? "선택됨. OTP 코드를 입력하세요" : "탭하여 이 Mac을 선택합니다")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var lastSeenText: String {
        let delta = Date().timeIntervalSince(result.lastSeen)
        if delta < 5 { return "방금" }
        if delta < 60 { return "\(Int(delta))초 전" }
        return "\(Int(delta / 60))분 전"
    }
}

// MARK: - OTP Pairing Section (V292-4)

/// 6자리 OTP 입력 섹션. SMS autofill 호환 (UITextContentType.oneTimeCode).
/// 마치 ATM 비밀번호 입력처럼 한 칸씩 자동으로 이동한다.
struct OTPPairingSection: View {
    let target: RelayDiscoveryResult
    @Binding var digits: [String]
    @Binding var activeField: Int
    let onConnect: () -> Void
    let onCancel: () -> Void

    private var code: String { digits.joined() }
    private var isComplete: Bool { PairingCode.validate(code) }

    var body: some View {
        DSCard(tone: .standard) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Mac 화면의 6자리 코드")
                        .font(DS.Font.sectionTitle)
                    Text("\(target.displayName) — Mobile Pilot Relay 패널에 표시된 숫자")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }

                OTPBoxRow(digits: $digits,
                          activeField: $activeField,
                          onComplete: { if isComplete { onConnect() } })

                HStack(spacing: DS.Space.m) {
                    DSButton("취소",
                             style: .secondary,
                             fullWidth: true,
                             action: onCancel)
                    .accessibilityIdentifier("connect.otp.cancel")

                    DSButton("연결",
                             systemImage: "bolt.horizontal.fill",
                             style: .primary,
                             fullWidth: true,
                             disabled: !isComplete,
                             action: onConnect)
                    .accessibilityIdentifier("connect.otp.submit")
                }
            }
        }
    }
}

// MARK: - OTPBoxRow

/// ATM 비밀번호 입력 UI: 6개 분리된 박스에 숫자를 하나씩 입력, 자동 다음 칸 이동.
struct OTPBoxRow: View {
    @Binding var digits: [String]
    @Binding var activeField: Int
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(0..<6, id: \.self) { idx in
                OTPSingleBox(digit: $digits[idx],
                             index: idx,
                             activeIndex: $activeField,
                             onNext: { advance(from: idx) },
                             onComplete: onComplete,
                             // P2-3 (검수 2026-05-26): 6자리 paste / autofill 처리.
                             onMultiDigitInput: { rawDigits in
                                 distribute(rawDigits)
                             })
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("6자리 인증 코드 입력, 현재 \(digits.filter { !$0.isEmpty }.count)자리 입력됨")
    }

    private func advance(from index: Int) {
        if index < 5 {
            activeField = index + 1
        } else {
            onComplete()
        }
    }

    /// raw 문자열의 첫 6자리 숫자를 각 box 에 분배. 6자리 모두 채우면
    /// 자동으로 onComplete 호출 — 사용자가 enter 누를 필요 없음.
    private func distribute(_ raw: String) {
        let chars = raw.filter { $0.isNumber }
        for i in 0..<6 {
            if i < chars.count {
                let c = chars.index(chars.startIndex, offsetBy: i)
                digits[i] = String(chars[c])
            } else {
                digits[i] = ""
            }
        }
        activeField = min(chars.count, 5)
        if chars.count >= 6 {
            onComplete()
        }
    }
}

// MARK: - OTPSingleBox

struct OTPSingleBox: View {
    @Binding var digit: String
    let index: Int
    @Binding var activeIndex: Int
    let onNext: () -> Void
    let onComplete: () -> Void
    /// P2-3 (검수 2026-05-26): 6자리 paste 또는 autofill (`textContentType(.oneTimeCode)`)
    /// 시 부모가 모든 칸을 동시에 채울 수 있도록 multi-digit input 을 broadcast.
    var onMultiDigitInput: ((String) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $digit)
            .font(.title2.monospacedDigit().weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(width: 44, height: 52)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(DS.Color.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .stroke(isFocused ? DS.Color.brand : DS.Color.divider,
                                    lineWidth: isFocused ? DS.Stroke.emphasis : DS.Stroke.hairline)
                    )
            )
            #if canImport(UIKit)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            #endif
            .focused($isFocused)
            .onChange(of: activeIndex) { _, newActive in
                if newActive == index { isFocused = true }
            }
            .onChange(of: digit) { _, newValue in
                let filtered = newValue.filter { $0.isNumber }
                // P2-3 fix (검수 2026-05-26): paste / autofill 로 multi-digit 입력
                // 들어오면 부모에 broadcast 후 한 자리만 유지. 종전: 나머지 버려짐.
                if filtered.count > 1 {
                    onMultiDigitInput?(filtered)
                    digit = String(filtered.prefix(1))
                } else {
                    digit = filtered
                }
                if !digit.isEmpty { onNext() }
            }
            .onAppear {
                if activeIndex == index { isFocused = true }
            }
            .accessibilityLabel("\(index + 1)번째 자리")
            .accessibilityIdentifier("connect.otp.\(index)")
    }
}

// MARK: - TroubleshootExpander (V292-3)

/// 30초 타임아웃 후 "안 보여요?" 자동 펼침 패널.
/// 공항에서 항공편이 없을 때 안내 데스크가 자동으로 팝업되는 것과 같다.
struct TroubleshootExpander: View {
    @Binding var isExpanded: Bool
    let autoExpand: Bool
    let onRetry: () -> Void

    var body: some View {
        DSCard(tone: .standard) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Button {
                    withAnimation(DS.Motion.standard) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(DS.Color.warning)
                        Text("안 보여요?")
                            .font(DS.Font.sectionTitle)
                            .foregroundStyle(DS.Color.primaryText)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("안 보여요? 도움말 \(isExpanded ? "접기" : "펼치기")")
                .accessibilityIdentifier("connect.troubleshoot.toggle")

                if isExpanded {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        troubleshootItem(number: 1,
                                         text: "Mac에서 DarwinForge 앱이 실행 중인가요?")
                        troubleshootItem(number: 2,
                                         text: "Mac의 Mobile Pilot Relay 토글이 ON인가요?")
                        troubleshootItem(number: 3,
                                         text: "iPhone과 Mac이 같은 Wi-Fi에 연결되어 있나요?")
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "4.circle.fill")
                                .foregroundStyle(DS.Color.info)
                            Button {
                                ConnectSubViewHelpers.openAppSettings()
                            } label: {
                                Text("Settings → 로컬 네트워크 권한 확인")
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.accent)
                                    .underline()
                            }
                            .accessibilityIdentifier("connect.troubleshoot.settings")
                        }

                        DSButton("다시 찾기",
                                 systemImage: "arrow.clockwise",
                                 style: .secondary,
                                 fullWidth: true,
                                 action: onRetry)
                        .accessibilityIdentifier("connect.troubleshoot.retry")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .onAppear {
            if autoExpand && !isExpanded {
                withAnimation(DS.Motion.slow) { isExpanded = true }
                #if canImport(UIKit)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
                #endif
            }
        }
    }

    private func troubleshootItem(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(DS.Color.info)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }
}

// MARK: - PairingDiagnosis (V292-6)

/// 페어링 실패 원인을 구체적으로 진단해 사용자에게 행동 가이드를 제시.
/// Nielsen #9: 오류 복구 지원 — "무언가 잘못됐어요" 대신 "코드 만료, 새 QR 생성하세요" 처럼 구체적으로.
struct PairingDiagnosis {
    let localizedMessage: String
    let actionLabel: String?
    let action: PairingAction

    enum PairingAction {
        case retry
        case openSettings
        case none
    }

    func performAction(openSettings: () -> Void) {
        switch action {
        case .retry: break
        case .openSettings: openSettings()
        case .none: break
        }
    }

    static func diagnose(_ errorString: String) -> PairingDiagnosis {
        let lower = errorString.lowercased()
        if lower.contains("code") || lower.contains("pairing") || lower.contains("auth") {
            return PairingDiagnosis(
                localizedMessage: "코드가 만료되었거나 일치하지 않아요. Mac에서 새 QR을 생성하세요.",
                actionLabel: "재시도",
                action: .retry
            )
        }
        if lower.contains("connection") || lower.contains("timeout") || lower.contains("refused") {
            return PairingDiagnosis(
                localizedMessage: "DarwinForge가 실행 중인지 확인하세요. Mac 앱이 꺼져 있을 수 있어요.",
                actionLabel: nil,
                action: .none
            )
        }
        if lower.contains("network") || lower.contains("wifi") || lower.contains("unreachable") {
            return PairingDiagnosis(
                localizedMessage: "iPhone과 Mac이 다른 Wi-Fi에 있어요. 같은 네트워크인지 확인하세요.",
                actionLabel: "Settings",
                action: .openSettings
            )
        }
        return PairingDiagnosis(
            localizedMessage: "연결에 실패했어요. (\(errorString))",
            actionLabel: "재시도",
            action: .retry
        )
    }
}

// MARK: - ManualEntrySheet (V292-4 고급 방법)

/// 보조 연결 방법: IP + 포트 + OTP 직접 입력.
/// Hick's Law: 이 화면은 Hero CTA 뒤에 숨겨져 있어 일반 사용자는 볼 필요 없다.
struct ManualEntrySheet: View {
    let onConnect: (RelayEndpoint) -> Void
    /// P2-3 (검수 2026-05-26): QR 카메라 스캔 결과가 JSON 파싱 실패했을 때
    /// 그 raw 텍스트를 paste 영역에 그대로 채워 사용자가 보고 수정/확정할 수 있게.
    var prefillJSON: String? = nil

    @State private var host: String = ""
    @State private var port: String = "17370"
    @State private var code: String = ""
    @State private var pasteJSON: String = ""
    @State private var pasteError: String?
    @Environment(\.dismiss) private var dismiss

    private var isManualReady: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(port) ?? 0) > 0 &&
        PairingCode.validate(code)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("호스트") {
                        TextField("예: 192.168.0.23", text: $host)
                            .textContentType(.URL)
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("connect.manual.host")
                    }
                    LabeledContent("포트") {
                        TextField("17370", text: $port)
                            #if canImport(UIKit)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("connect.manual.port")
                    }
                    LabeledContent("6자리 코드") {
                        TextField("Mac 화면 숫자", text: $code)
                            #if canImport(UIKit)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("connect.manual.code")
                    }
                } header: {
                    Text("IP 직접 입력")
                } footer: {
                    Text("자동 탐색이 되지 않을 때만 사용하세요.")
                }

                Section {
                    DSButton("IP로 연결",
                             systemImage: "point.3.connected.trianglepath.dotted",
                             style: .primary,
                             fullWidth: true,
                             disabled: !isManualReady) {
                        guard let portInt = Int(port) else { return }
                        onConnect(RelayEndpoint(
                            host: host.trimmingCharacters(in: .whitespaces),
                            port: portInt,
                            pairingCode: code.trimmingCharacters(in: .whitespaces)))
                    }
                    .accessibilityIdentifier("connect.manual.submit")
                }

                Section {
                    TextField("Mac에서 복사한 연결 텍스트를 붙여넣기",
                              text: $pasteJSON, axis: .vertical)
                        .font(.caption.monospaced())
                        .lineLimit(3, reservesSpace: true)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("connect.qr.paste")

                    if let pasteError {
                        Label(pasteError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(DS.Color.warning)
                    }

                    Button {
                        tryPaste()
                    } label: {
                        Label("붙여넣은 정보로 연결", systemImage: "doc.on.clipboard")
                    }
                    .disabled(pasteJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connect.qr.scan")
                } header: {
                    Text("공유 텍스트로 연결")
                } footer: {
                    Text("Mac 앱에서 복사한 연결 텍스트(JSON)를 그대로 붙여넣으세요. QR 카메라 스캔은 \"다른 방법으로 연결\" 메뉴에서 따로 시작할 수 있습니다.")
                }
            }
            .navigationTitle("다른 연결 방법")
            .dfInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear {
                // P2-3: QR 카메라가 raw 문자열을 던졌을 때 paste 영역 미리 채움.
                if let raw = prefillJSON, pasteJSON.isEmpty {
                    pasteJSON = raw
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func tryPaste() {
        do {
            pasteError = nil
            let payload = try QRPairingDecoder.decode(pasteJSON)
            onConnect(RelayEndpoint(host: payload.host,
                                    port: payload.port,
                                    pairingCode: payload.pairingCode))
        } catch {
            pasteError = "연결 텍스트 형식을 확인하세요."
        }
    }
}

// MARK: - DevMenuSheet (#if DEBUG)

#if DEBUG
/// 개발자 전용 숨김 메뉴. Production 사용자에게 노출되지 않는다.
/// 10회 탭으로 활성화 (hidden 10-tap unlock pattern).
struct DevMenuSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Mock / 연습") {
                    Button("연습 모드 시작") {
                        Task {
                            await state.setConnectionMode(.mockReview)
                            await state.connectMockReview()
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("dev.mock.start")
                }
                Section("연결 모드") {
                    Picker("모드", selection: Binding(
                        get: { state.connectionMode },
                        set: { mode in Task { await state.setConnectionMode(mode) } }
                    )) {
                        Text("연습 (Mock)").tag(AppState.ConnectionMode.mockReview)
                        Text("실제 연결").tag(AppState.ConnectionMode.realRelay)
                    }
                    .accessibilityIdentifier("dev.mode.picker")
                }
                Section("디버그") {
                    LabeledContent("lastError", value: state.lastError ?? "없음")
                    LabeledContent("pilotState", value: "\(state.pilotState)")
                    LabeledContent("transport", value: "\(state.transport)")
                }
            }
            .navigationTitle("개발자 메뉴")
            .dfInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
#endif

// MARK: - Shared Helpers

enum ConnectSubViewHelpers {
    static func openAppSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
