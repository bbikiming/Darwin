import ForgeCore
import SwiftUI

/// Action Bar — v1.0 메인 7 페이지 + v1.5 "+ 더 보기" 9 페이지 (PRD §7).
///
/// HIG:
///   - 적응형 LazyVGrid 로 윈도우 폭에 따라 2~4 컬럼 자동.
///   - 각 버튼 minHeight 88pt (3D 모션 + 라벨 + 메타).
///   - Safe/Caution/HighRisk DFChip 으로 시각 위계.
///   - 키 1..7 (no modifier) — Pilot 화면 활성 시만 작동.
public struct PilotActionBar: View {
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate
    let flags: PilotFeatureFlags

    @State private var pendingConfirm: MotionPageMetadata?
    @State private var showMoreSheet: Bool = false

    public init(channel: TeleopChannel, gate: PilotSafetyGate, flags: PilotFeatureFlags) {
        self.channel = channel
        self.gate = gate
        self.flags = flags
    }

    public var body: some View {
        DFPanel(
            "Action Bar",
            subtitle: gate.armed ? "키 1..7 / 클릭 — 7 페이지 송출 가능" : "ARM 후 활성화",
            icon: "play.rectangle.on.rectangle",
            tint: DFColor.accent,
            trailing: {
                DFKeyboardHint("1", "2", "3", "4", "5", "6", "7")
            }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                LazyVGrid(columns: gridColumns, spacing: DFSpace.sm) {
                    ForEach(Array(MotionCatalog.actionBarMain.enumerated()), id: \.element.slot) { idx, meta in
                        actionButton(meta, keyIndex: idx + 1)
                    }
                }

                moreButton
            }
        }
        .alert(item: $pendingConfirm) { meta in
            Alert(
                title: Text("위험 동작 확인"),
                message: Text("\(meta.displayNameKo)\n실행하면 \(String(format: "%.1f", Double(meta.durationMs)/1000.0))초 동안 \(meta.bodyRegions.first?.rawValue ?? "관절") 가(이) 움직입니다.\n\ncradle 거치를 확인했나요?"),
                primaryButton: .destructive(Text("확인 후 실행")) {
                    Task { _ = await channel.sendMotion(slot: meta.slot, confirmRisk: true) }
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
        .sheet(isPresented: $showMoreSheet) { moreSheet }
    }

    /// 적응형 컬럼 — 110pt 미만으로 좁아지지 않음. 윈도우 폭에 따라 2~4 컬럼.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 8, alignment: .top)]
    }

    @ViewBuilder
    private func actionButton(_ meta: MotionPageMetadata, keyIndex: Int) -> some View {
        let isPlaying = channel.playingSlot == meta.slot
        let isV1Sendable = meta.v1TargetPoseID != nil
        let isEnabled = isV1Sendable && (gate.armed || !gate.armed)  // 시뮬에서도 시각만 동작
        let safetyTint: Color = safetyColor(meta.safetyClass)

        Button {
            press(meta)
        } label: {
            VStack(spacing: DFSpace.xs2) {
                ZStack {
                    if isPlaying {
                        Circle()
                            .trim(from: 0, to: max(0.02, channel.progress))
                            .stroke(safetyTint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: DFSize.iconXxl, height: DFSize.iconXxl)
                            .animation(PilotAnim.motionProgress, value: channel.progress)
                    }
                    Image(systemName: meta.icon)
                        .font(.system(size: DFFontSize.s22, weight: .semibold))
                        .foregroundStyle(safetyTint)
                }
                .frame(height: 48)

                Text(meta.displayNameKo)
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)

                HStack(spacing: DFSpace.xs) {
                    Text(meta.rawName)
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                    Text("·").foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o50))
                    Text(String(format: "%.1fs", Double(meta.durationMs)/1000.0))
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                }
                .lineLimit(1)

                HStack(spacing: DFSpace.xs) {
                    Circle().fill(safetyTint).frame(width: DFSize.indicatorXxs, height: DFSize.indicatorXxs)
                    Text(meta.safetyClass.koreanLabel)
                        .font(.system(size: DFFontSize.s9, weight: .semibold))
                        .foregroundStyle(safetyTint)
                    Spacer(minLength: 0)
                    DFKeyboardHint("\(keyIndex)")
                }
            }
            .padding(.vertical, DFSpace.sm2)
            .padding(.horizontal, DFSpace.sm)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .fill(isPlaying ? safetyTint.opacity(0.14) : DFColor.elev2)
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.md)
                            .stroke(
                                isPlaying ? safetyTint : safetyTint.opacity(DFOpacity.o25),
                                lineWidth: isPlaying ? 1.5 : 0.5
                            )
                    )
            )
            .opacity(isV1Sendable ? 1.0 : DFOpacity.disabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(tooltip(meta))
        .keyboardShortcut(KeyEquivalent(Character("\(keyIndex)")), modifiers: [])
    }

    private func safetyColor(_ s: SafetyClass) -> Color {
        switch s {
        case .safe:     return PilotColor.safetySafe
        case .caution:  return PilotColor.safetyCaution
        case .highRisk: return PilotColor.safetyHighRisk
        }
    }

    private func tooltip(_ meta: MotionPageMetadata) -> String {
        [
            "[\(meta.displayNameKo)] (\(meta.displayName))",
            "raw_name: \(meta.rawName)",
            "duration: \(meta.durationMs) ms",
            "safety: \(meta.safetyClass.koreanLabel)",
            "mp3: \(meta.mp3Sync ?? "—")",
            "source: motion_4096.bin page \(meta.slot)",
            meta.v1TargetPoseID != nil ? "v1.0 활성" : "v1.5 활성 (raw step 경로 필요)",
        ].joined(separator: "\n")
    }

    private func press(_ meta: MotionPageMetadata) {
        if meta.safetyClass.requiresConfirm {
            pendingConfirm = meta
        } else {
            Task { _ = await channel.sendMotion(slot: meta.slot, confirmRisk: false) }
        }
    }

    @ViewBuilder
    private var moreButton: some View {
        if flags.actionBarMore {
            DFButton(.secondary, size: .medium) {
                showMoreSheet = true
            } label: {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: "ellipsis.circle.fill")
                    Text("+ 더 보기 (\(MotionCatalog.actionBarMore.count) 페이지)")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DFFontSize.s10, weight: .semibold))
                        .foregroundStyle(DFColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "ellipsis.circle")
                Text("+ 더 보기 (\(MotionCatalog.actionBarMore.count) 페이지)")
                    .font(DFFont.bodyEmph)
                Spacer()
            }
            .padding(.vertical, DFSpace.sm2)
            .padding(.horizontal, DFSpace.sm2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.sm).fill(DFColor.elev2)
            )
            .comingSoon(
                "v1.5",
                title: "9 추가 페이지 (끄덕임 / 가로젓기 / 박수 요청 / 등)",
                why: "메인 7 페이지로 v1.0 의 사용성 안정 후 확장",
                when: "Sprint 17",
                alternative: "지금: 메인 7 페이지 + Motion Studio 의 사용자 모션"
            )
        }
    }

    @ViewBuilder
    private var moreSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack {
                Text("추가 페이지").font(DFFont.title)
                Spacer()
                Button("닫기") { showMoreSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: DFSpace.sm) {
                    ForEach(MotionCatalog.actionBarMore, id: \.slot) { meta in
                        actionButton(meta, keyIndex: 0)
                    }
                }
            }
        }
        .padding(DFSpace.lg)
        .frame(width: 600, height: 480)
    }
}
