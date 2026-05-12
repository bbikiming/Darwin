import ForgeCore
import SwiftUI

/// Action Bar — v1.0 메인 7 버튼.
/// slots: 1·4·15·12·13·9·23 (actionBarMain).
public struct PilotActionBar: View {
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate

    @State private var confirmingSlot: UInt8? = nil
    @State private var confirmMsg: String = ""
    @State private var confirmTitle: String = ""

    public init(channel: TeleopChannel, gate: PilotSafetyGate) {
        self.channel = channel
        self.gate = gate
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(actionBarMain.enumerated()), id: \.element) { index, slot in
                    if let meta = MotionCatalog.find(slot: slot) {
                        actionButton(meta: meta, keyIndex: index + 1)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // + 더 보기 (v1.5 비활성)
            Button {
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                    Text("+ 더 보기")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .comingSoon(
                stage: "v1.5",
                title: "+ 더 보기 9 페이지",
                why: "카탈로그 확장은 카메라·HSV 튜닝과 함께 준비 중입니다.",
                when: "Sprint 17 (v1.5) — 카메라 설정 완료 후",
                alternative: "현재 7개 메인 버튼을 사용하세요"
            )
        }
        .alert(confirmTitle, isPresented: Binding(
            get: { confirmingSlot != nil },
            set: { if !$0 { confirmingSlot = nil } }
        )) {
            Button("취소", role: .cancel) { confirmingSlot = nil }
            Button("실행", role: .destructive) {
                if let slot = confirmingSlot {
                    confirmingSlot = nil
                    Task { @MainActor in
                        try? await channel.sendMotion(slot: slot, confirmRisk: true)
                    }
                }
            }
        } message: {
            Text(confirmMsg)
        }
    }

    private func actionButton(meta: MotionPageMetadata, keyIndex: Int) -> some View {
        let isPlaying = channel.isPlaying && channel.currentCmd.isMotion(slot: meta.id)
        let isArmed = gate.armed

        return Button {
            handleTap(meta: meta)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    // Progress ring
                    if isPlaying {
                        Circle()
                            .stroke(PilotColor.progressRing.opacity(0.25), lineWidth: 2)
                            .frame(width: 32, height: 32)
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(PilotColor.progressRing, lineWidth: 2)
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                                       value: isPlaying)
                    }
                    // Safety indicator
                    Circle()
                        .fill(safetyColor(meta.safetyClass).opacity(0.18))
                        .frame(width: 28, height: 28)
                    Text(String(keyIndex))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(isPlaying ? PilotColor.progressRing : safetyColor(meta.safetyClass))
                }
                Text(meta.displayNameKo)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.white.opacity(isArmed ? 1.0 : 0.45))
                Text("\(meta.rawName) · \(meta.durationMs / 100).\(meta.durationMs % 100 / 10)s")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPlaying
                        ? PilotColor.progressRing.opacity(0.12)
                        : (isArmed ? Color.white.opacity(0.06) : Color.white.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isPlaying ? PilotColor.progressRing.opacity(0.5) : Color.white.opacity(0.10),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isArmed)
        .help(buttonTooltip(meta: meta))
        .padding(.horizontal, 2)
    }

    private func handleTap(meta: MotionPageMetadata) {
        let gateResult = gate.allowMotion(meta, confirmRisk: false)
        switch gateResult {
        case .allow:
            Task { @MainActor in
                try? await channel.sendMotion(slot: meta.id, confirmRisk: false)
            }
        case .requireConfirm(let title, let message):
            confirmTitle = title
            confirmMsg = message
            confirmingSlot = meta.id
        case .block(let reason):
            channel.lastError = reason
        }
    }

    private func buttonTooltip(_ meta: MotionPageMetadata) -> String {
        var lines = [
            "raw: \(meta.rawName)",
            "duration: \(meta.durationMs) ms",
            "safety: \(meta.safetyClass.rawValue)",
            "source: motion_4096.bin page \(meta.id)",
            "v1.0 활성",
        ]
        if let mp3 = meta.mp3Sync { lines.insert("mp3: \(mp3)", at: 2) }
        return lines.joined(separator: "\n")
    }

    private func safetyColor(_ c: MotionSafetyClass) -> Color {
        switch c {
        case .safe:     return .white
        case .caution:  return PilotColor.caution
        case .highRisk: return PilotColor.highRisk
        }
    }
}

// MARK: - Helper

private extension TeleopCommandSwift {
    func isMotion(slot: UInt8) -> Bool {
        if case .motion(let s) = self { return s == slot }
        return false
    }
}
