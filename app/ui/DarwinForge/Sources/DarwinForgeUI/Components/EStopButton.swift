import ForgeCore
import SwiftUI

/// L5 — 하드웨어 비상정지 (LLM 경로 우회).
///
/// 근거:
/// - ISO 13850 — 빨강 actuator + 노란 배경, 머쉬룸 헤드 ≥40mm
/// - Apple HIG — ESC 키는 cancel 표준
/// - WCAG 2.3.1 — 깜빡임 제한
/// - 토스 톤 — "긴급정지" 명확하고 짧은 한국어
///
/// 동작: 클릭 시 즉시 `IntentDispatcher.emergencyStop()` 호출.
/// 확인 다이얼로그 없음 — ISO 13850 §4.4 (지연 금지).
public struct EStopButton: View {
    @ObservedObject public var dispatcher: IntentDispatcher
    @Binding public var lastAcknowledgement: String?

    @State private var isPressing = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init(
        dispatcher: IntentDispatcher,
        lastAcknowledgement: Binding<String?>
    ) {
        self.dispatcher = dispatcher
        self._lastAcknowledgement = lastAcknowledgement
    }

    public var body: some View {
        Button(action: trigger) {
            ZStack {
                // 노란 배경 링 (ISO 13850)
                Circle()
                    .fill(DFColor.warning)
                    .frame(width: DFSize.estop + 8, height: DFSize.estop + 8)
                // 빨강 actuator
                Circle()
                    .fill(DFColor.danger)
                    .frame(width: DFSize.estop, height: DFSize.estop)
                // 아이콘 (색+아이콘+텍스트 3중)
                Image(systemName: "stop.fill")
                    .font(.system(size: DFFontSize.s22, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isPressing ? 0.92 : (pulse && !reduceMotion ? 1.04 : 1.0))
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                       value: pulse)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("긴급정지 (ESC)")
        .accessibilityLabel(KoreanUX.Term.estop)
        .accessibilityHint("로봇의 모든 관절 힘을 즉시 풀어요. \(KoreanUX.Safety.estopHint)")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            if !reduceMotion { pulse = true }
        }
        // press feedback
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressing = true }
                .onEnded { _ in isPressing = false }
        )
    }

    private func trigger() {
        // UI 레벨 기록만 — pilotEStop SOT 는 WalkLabRCBridge.
        harness.record(.uiButtonTapped, level: .trace, actor: .user,
                              data: ["button": AnyCodable("estop_button")])
        Task { @MainActor in
            let r = await dispatcher.emergencyStop()
            lastAcknowledgement = r.speak
        }
    }
}

/// 좌상단 항상 가시 컨테이너 — 모든 화면에서 동일 위치.
///
/// 근거: NN/g Liquid Glass 비판 — "E-Stop은 절대 collapse 금지" +
/// ISO 13850 §4.4 — "항상 손 닿는 위치".
public struct EStopOverlay: View {
    @ObservedObject public var dispatcher: IntentDispatcher
    @Binding public var ack: String?

    public init(dispatcher: IntentDispatcher, ack: Binding<String?>) {
        self.dispatcher = dispatcher
        self._ack = ack
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DFSpace.md) {
            EStopButton(dispatcher: dispatcher, lastAcknowledgement: $ack)
                .padding(DFSpace.md)

            // ack 토스트 — 4초 자동 사라짐
            if let message = ack {
                AckToast(message: message)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        await MainActor.run { ack = nil }
                    }
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.25), value: ack)
    }
}

private struct AckToast: View {
    let message: String
    var body: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(DFFont.bodyEmph)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                .fill(DFColor.danger)
        )
        .shadow(radius: 8, y: 4)
        .padding(.top, DFSpace.md)
        .accessibilityLabel(message)
    }
}
