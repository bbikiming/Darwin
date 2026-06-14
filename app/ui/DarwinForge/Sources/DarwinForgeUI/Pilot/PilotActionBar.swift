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
    @EnvironmentObject private var store: ConnectionStore
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate
    let flags: PilotFeatureFlags
    /// 공 자동 추적 / walk demo 등 robot 측 데모가 USB bus 를 점유 중인지.
    /// true 면 Action Bar 의 모든 모션 송출 비활성 (USB 충돌 방지).
    let demoOccupiesBus: Bool

    @State private var pendingConfirm: MotionPageMetadata?
    @State private var showMoreSheet: Bool = false
    /// **사이클 121 (audit #11, P0)**: send 실패 시 사용자 보이게 표시. 종전 silent fail
    /// (Task 결과 `_ = await`) → 사용자가 "왜 안 움직이지?" 혼동. 본 state 가 lastError
    /// observe → banner 표시 + auto-dismiss.
    @State private var displayedError: String?
    /// 본 banner 자동 dismiss task — 재발화 시 cancel + 재시작.
    @State private var errorDismissTask: Task<Void, Never>?

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    //
    // 종전: `Harness.shared.record(...)` 직접 호출 (4 사이트) — 테스트/Preview 에서
    //       NoopHarness 주입 불가 → 실제 디스크 IO 발생.
    // 신규: SwiftUI Environment 주입. Root 가 LiveHarness 주입 (RootView).
    @Environment(\.harness) private var harness

    public init(channel: TeleopChannel, gate: PilotSafetyGate, flags: PilotFeatureFlags,
                demoOccupiesBus: Bool = false) {
        self.channel = channel
        self.gate = gate
        self.flags = flags
        self.demoOccupiesBus = demoOccupiesBus
    }

    /// 실 로봇 미연결 — sim 미리보기 모드. ARM 없이도 버튼 활성 (Codex P1 권고).
    private var isSimMode: Bool { store.bus == nil }

    public var body: some View {
        DFPanel(
            "Action Bar",
            subtitle: subtitleText,
            icon: "play.rectangle.on.rectangle",
            tint: DFColor.accent,
            trailing: {
                DFKeyboardHint("1", "2", "3", "4", "5", "6", "7")
            }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                // **사이클 121 (audit #11, P0)**: 송출 실패 시 사용자 명시 banner.
                if let err = displayedError {
                    errorBanner(err)
                }

                LazyVGrid(columns: gridColumns, spacing: DFSpace.sm) {
                    ForEach(Array(MotionCatalog.actionBarMain.enumerated()), id: \.element.slot) { idx, meta in
                        actionButton(meta, keyIndex: idx + 1)
                    }
                }

                moreButton
            }
        }
        // **사이클 121 (audit #11)**: channel.lastError observer — 비-nil 변경 시 banner 표시 + 5초 후 dismiss.
        .onChange(of: channel.lastError) { _, newError in
            guard let err = newError, !err.isEmpty else { return }
            // Gate-rejection 메시지는 pilotSafetyGateBlocked 에서 이미 기록됨 — errorException 중복 방지.
            let isGateRejection = err.hasPrefix("먼저 ARM") || err.hasPrefix("위험 동작")
            if !isGateRejection {
                harness.record(
                    .errorException, level: .error, actor: .system,
                    data: ["source": AnyCodable("pilot.action_bar"),
                           "error_hash": AnyCodable(Harness.shortHash(err))]
                )
            }
            displayedError = err
            errorDismissTask?.cancel()
            errorDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled, displayedError == err {
                    displayedError = nil
                }
            }
        }
        .alert(item: $pendingConfirm) { meta in
            // **Phase G8 (Codex audit follow-up, 2026-05-15) — 옵션 A**: chain page 면
            // 공식 demo 의 chain 길이 (8초+) 도 함께 표시. Mac v1 은 단발 자세만 송출 —
            // 사용자가 "왜 송출이 일찍 끝나지?" 혼동 방지.
            let chainNote: String = {
                guard meta.isChain, let chainMs = meta.rawChainDurationMs else { return "" }
                return "\n\n📎 참고: ROBOTIS 공식 chain 모션은 \(String(format: "%.1f", Double(chainMs)/1000.0))초 입니다. Mac 은 v1 에서 단발 자세만 보내고 끝납니다 (chain 재생은 ROBOTIS demo 위임)."
            }()
            return Alert(
                title: Text("위험 동작 확인"),
                message: Text("\(meta.displayNameKo)\n실행하면 \(String(format: "%.1f", Double(meta.durationMs)/1000.0))초 동안 \(meta.bodyRegions.first?.rawValue ?? "관절") 가(이) 움직입니다.\(chainNote)\n\ncradle 거치를 확인했나요?"),
                primaryButton: .destructive(Text("확인 후 실행")) {
                    // .warn 의도적 — safety override 이벤트를 대시보드에서 플래그하기 위함.
                    harness.record(
                        .pilotActionBarRiskConfirmed, level: .warn, actor: .user,
                        data: ["slot": AnyCodable(meta.slot),
                               "safety_class": AnyCodable(meta.safetyClass.rawValue),
                               "display_name_hash": AnyCodable(Harness.shortHash(meta.displayNameKo))]
                    )
                    Task { _ = await channel.sendMotion(slot: meta.slot, confirmRisk: true) }
                },
                secondaryButton: .cancel(Text("취소")) {
                    harness.record(
                        .pilotActionBarRiskCancelled, level: .info, actor: .user,
                        data: ["slot": AnyCodable(meta.slot),
                               "safety_class": AnyCodable(meta.safetyClass.rawValue),
                               "display_name_hash": AnyCodable(Harness.shortHash(meta.displayNameKo))]
                    )
                }
            )
        }
        .sheet(isPresented: $showMoreSheet) { moreSheet }
    }

    /// 적응형 컬럼 — 110pt 미만으로 좁아지지 않음. 윈도우 폭에 따라 2~4 컬럼.
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 8, alignment: .top)]
    }

    /// **사이클 121 (audit #11, P0)**: 송출 실패 banner. orange tint, dismiss 버튼 포함.
    /// 5초 후 자동 사라지지만 사용자가 명시 dismiss 가능.
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(DFFont.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                displayedError = nil
                errorDismissTask?.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("오류 메시지 닫기")
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityIdentifier("pilot.actionbar.error.banner")
    }

    /// Action Bar 의 상태별 부제목 — sim 미연결 / demo 점유 / ARM 전/후 분리.
    private var subtitleText: String {
        if demoOccupiesBus {
            return "🤖 ROBOTIS 데모가 USB 점유 중 — 수동 모드로 전환해야 송출 가능"
        }
        if isSimMode {
            return "시뮬 미리보기 — 실 로봇 미연결 (자세 미리보기만)"
        }
        if gate.armed {
            return "키 1..7 / 클릭 — 7 페이지 송출 가능"
        }
        return "🔒 ARM 슬라이더 잠금 해제 후 활성"
    }

    @ViewBuilder
    private func actionButton(_ meta: MotionPageMetadata, keyIndex: Int) -> some View {
        let isPlaying = channel.playingSlot == meta.slot
        let isV1Sendable = meta.v1TargetPoseID != nil
        // Sprint 18: demo 가 USB bus 점유 중이면 실 송출 불가. sim 모드(bus nil)도 동일하게 disable.
        // 단, sim 미리보기 자체는 demo 와 무관하니 sim 모드는 그대로 enable.
        // Codex P1 fix (2026-05-13): `gate.armed || !gate.armed` 무의미 boolean 제거.
        let isEnabled = isV1Sendable
            && !demoOccupiesBus
            && (isSimMode || gate.armed)
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
                    // **Phase G8 (Codex audit follow-up, 2026-05-15) — 옵션 A**:
                    // chain page 면 공식 demo 의 chain 길이도 caption 표시.
                    // Mac v1 은 단발 자세 송출만 — chain 재생은 ROBOTIS demo 위임.
                    if let chainMs = meta.rawChainDurationMs {
                        Text("(공식 \(String(format: "%.1f", Double(chainMs)/1000.0))s)")
                            .font(.system(size: DFFontSize.s9, design: .monospaced))
                            .foregroundStyle(DFColor.info.opacity(DFOpacity.o70))
                    }
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
        // 2026-05-17 a11y: VoiceOver — 한국어 이름 + 안전 등급 + 단축키.
        // 종전엔 라벨 VStack 안 텍스트 3개 (이름/duration/등급) 가 한 줄로 합쳐져
        // 읽혔음 → 사용자 인지 어려움.
        .accessibilityLabel(meta.displayNameKo)
        .accessibilityHint("\(meta.safetyClass.koreanLabel), \(String(format: "%.1f", Double(meta.durationMs)/1000.0))초, 단축키 \(keyIndex)")
    }

    private func safetyColor(_ s: SafetyClass) -> Color {
        switch s {
        case .safe:     return PilotColor.safetySafe
        case .caution:  return PilotColor.safetyCaution
        case .highRisk: return PilotColor.safetyHighRisk
        }
    }

    private func tooltip(_ meta: MotionPageMetadata) -> String {
        // Codex P0/A3 권고 (2026-05-13 3차): "source: motion_4096.bin page N" 은
        // raw page chain 재생을 암시하지만, 현재 구현은 단일 PoseLibrary target.
        // 사용자 오해 방지 — 명시적으로 "단일 pose preview" 와 매핑 ID 노출.
        let renderingMode = meta.v1TargetPoseID.map { "단일 pose preview → PoseLibrary.\($0)" }
            ?? "준비 중 — raw page chain 재생 (별도 Sprint, motion_4096.bin page \(meta.slot) chain)"
        return [
            "[\(meta.displayNameKo)] (\(meta.displayName))",
            "원본: motion_4096.bin page \(meta.slot) (raw_name: \(meta.rawName))",
            "duration: \(meta.durationMs) ms",
            "safety: \(meta.safetyClass.koreanLabel)",
            "mp3: \(meta.mp3Sync ?? "—") (재생 비활성 — v2)",
            "재생 방식: \(renderingMode)",
        ].joined(separator: "\n")
    }

    private func press(_ meta: MotionPageMetadata) {
        harness.record(
            .pilotActionBarPressed, level: .info, actor: .user,
            data: ["slot": AnyCodable(meta.slot),
                   "safety_class": AnyCodable(meta.safetyClass.rawValue),
                   "is_sim": AnyCodable(isSimMode)]
        )
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
            // App Store 빌드(§4): '더 보기' 미출시 placeholder + '다음 업데이트'
            // affordance 제거 — 출시된 기능만 노출(가이드라인 2.1). PilotHudStrip 2건과 일관.
            #if !APPSTORE
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
            // **사이클 127 (audit #13, P1)**: ComingSoonOverlay 3사용처 일관성 — "when" 형식
            // 통일. 종전 "Sprint 17" (내부 개발 일정 누설) → 사용자 친화 "다음 업데이트" 채택.
            // PilotHudStrip 2건과 동일.
            .comingSoon(
                "v1.5",
                title: "9 추가 페이지 (끄덕임 / 가로젓기 / 박수 요청 / 등)",
                why: "메인 7 페이지로 v1.0 의 사용성 안정 후 확장",
                when: "다음 업데이트",
                alternative: "지금: 메인 7 페이지 + Motion Studio 의 사용자 모션"
            )
            #else
            EmptyView()
            #endif
        }
    }

    @ViewBuilder
    private var moreSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack {
                Text("추가 페이지").font(DFFont.title)
                Spacer()
                // 사이클 138 (audit #24 codex sweep)
                Button("닫기", role: .cancel) { showMoreSheet = false }
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
