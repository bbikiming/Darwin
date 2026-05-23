import ForgeCore
import SwiftUI

/// 사이클 259 (Wave 4.3.6) — `MotionStudioView` 타임라인 영역 분리.
///
/// **목적**: MotionStudioView 929 줄 god view 분할 — Canvas 와 함께
/// centerColumn 의 하단 (transport bar + step list + 키프레임 디테일) 책임을
/// 독립 View 로 격리.
///
/// **책임**:
/// - `TransportBar` — 재생/정지/추가/캡처/저장/Undo/Redo + LIVE 토글
/// - `TimelineCanvas` — step 카드 가로 스트립 + 재생 헤드
/// - `stepDetailRow` — 현재 step 의 playMs / pauseMs stepper + Copy/Paste/Split + 삭제
/// - 빈 상태 안내 (`ContentUnavailableView`)
/// - `updateSelectedStepTiming` — playMs/pauseMs raw quantize + undo push + player seek
///
/// **소유권**:
/// - `doc` 은 `@Bindable` — selectedStep / copiedStep / executingOnRobot /
///   undoStack 등 다중 mutation 의 핵심 store.
/// - `player` 는 owner 의 `@StateObject` 를 `@ObservedObject` 로 — elapsedMs /
///   mode 변화에 view 가 반응하고, seek/play 호출.
/// - `sendToHardware` 는 owner @State 의 Binding — TransportBar 의 LIVE 토글이
///   양방향으로 갱신.
/// - `currentPage` 는 owner 가 계산해 전달 (doc.motion.pages[selectedPageIdx]).
/// - 나머지 action 은 closure 로 주입 — owner 가 mutation 책임.
@MainActor
struct MotionStudioTimeline: View {
    @Bindable var doc: MotionDocumentStore
    @ObservedObject var player: MotionPlayer

    /// LIVE 토글 — TransportBar 가 양방향 바인딩 필요.
    @Binding var sendToHardware: Bool

    /// 현재 선택된 페이지 — owner 가 doc 에서 계산해 전달.
    let currentPage: MotionPage?

    /// TransportBar LIVE 토글의 "가용성" — bus 연결 여부.
    let hasBus: Bool

    /// Undo / Redo 가능 여부 — TransportBar disabled 상태 결정.
    let canUndo: Bool
    let canRedo: Bool

    // MARK: - Action callbacks (owner 위임)

    let onPlay: () -> Void
    let onAddStep: () -> Void
    let onCapture: () -> Void
    let onRunOnRobot: () -> Void
    let onSave: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    /// 선택된 step 이 변경되면 owner 가 stagedPose 를 재계산.
    let onApplySelectedStepToPose: () -> Void

    /// 키프레임 편집 cluster — Copy / Paste / Split.
    let onCopySelectedStep: () -> Void
    let onPasteStep: () -> Void
    let onSplitSelectedStep: () -> Void

    /// "이 단계 삭제" — owner 가 mutation + pose refresh.
    let onRemoveSelectedStep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            transportRow

            if let page = currentPage {
                TimelineCanvas(
                    page: page,
                    selectedStep: Binding(
                        get: { doc.selectedStep },
                        set: { doc.selectedStep = $0; onApplySelectedStepToPose() }
                    ),
                    elapsedMs: player.elapsedMs,
                    onSeek: { player.seek(toMs: $0) }
                )

                stepDetailRow(page: page)
            } else {
                ContentUnavailableView(
                    "동작을 선택하세요",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("왼쪽 목록에서 동작을 고르거나, ➕ 버튼으로 새로 만들거나, ⬇️ 로 .mtn 파일을 가져올 수 있어요.")
                )
            }
        }
    }

    /// 영상 편집 도구 (Premiere / FCP / After Effects) 스타일의 transport bar.
    /// 분리된 컴포넌트로 — `Motion/TransportBar.swift`.
    private var transportRow: some View {
        TransportBar(
            player: player,
            totalDurationMs: Double(currentPage?.totalDurationMs ?? 0),
            stepCount: currentPage?.steps.count ?? 0,
            hasBus: hasBus,
            sendToHardware: $sendToHardware,
            isDirty: doc.isDirty,
            executingOnRobot: doc.executingOnRobot,
            canUndo: canUndo,
            canRedo: canRedo,
            onPlay: onPlay,
            onAddStep: onAddStep,
            onCapture: onCapture,
            onRunOnRobot: onRunOnRobot,
            onSave: onSave,
            onUndo: onUndo,
            onRedo: onRedo
        )
    }

    private func stepDetailRow(page: MotionPage) -> some View {
        // 현재 step idx 가 안전한 범위인지.
        let stepCount = page.steps.count
        return HStack(spacing: DFSpace.md) {
            // 키프레임 위치 label.
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: DFFontSize.s11))
                    .foregroundStyle(DFColor.forge)
                Text("\(doc.selectedStep + 1) / \(stepCount)")
                    .font(DFFont.bodyEmph.monospacedDigit())
            }

            Divider().frame(height: DFSize.iconMd2)

            // 이동 시간 (playMs) — stepper 인라인 편집.
            keyframeStepperField(
                label: "이동",
                valueMs: page.steps[safe: doc.selectedStep]?.playMs ?? 0,
                range: 0...4096,    // .mtn raw 한계 (255 × 8ms = ~2040ms 권장, 여유로 4096).
                stepMs: 8,           // .mtn raw 단위 (1 raw = 8ms).
                tint: DFColor.accent
            ) { newMs in
                updateSelectedStepTiming(playMs: newMs, pauseMs: nil)
            }

            // 멈춤 시간 (pauseMs) — stepper 인라인 편집.
            keyframeStepperField(
                label: "정지",
                valueMs: page.steps[safe: doc.selectedStep]?.pauseMs ?? 0,
                range: 0...2040,
                stepMs: 8,
                tint: DFColor.textSecondary
            ) { newMs in
                updateSelectedStepTiming(playMs: nil, pauseMs: newMs)
            }

            Spacer()

            // 키프레임 편집 클러스터 — Copy / Paste / Split (단축키 ⌘C / ⌘V / ⌘K).
            HStack(spacing: DFSpace.micro2) {
                keyframeIconButton(
                    icon: "doc.on.doc",
                    help: "키프레임 복사 (⌘C)",
                    tint: DFColor.accent,
                    enabled: true,
                    action: onCopySelectedStep
                )
                keyframeIconButton(
                    icon: "doc.on.clipboard",
                    help: doc.copiedStep == nil
                        ? "먼저 키프레임을 복사하세요"
                        : "복사한 키프레임 붙여넣기 (⌘V)",
                    tint: DFColor.accent,
                    enabled: doc.copiedStep != nil,
                    action: onPasteStep
                )
                keyframeIconButton(
                    icon: "scissors",
                    help: "키프레임 쪼개기 (⌘K) — 중간 자세로 두 단계 분할",
                    tint: DFColor.forge,
                    enabled: (page.steps[safe: doc.selectedStep]?.playMs ?? 0) >= 16,
                    action: onSplitSelectedStep
                )
            }

            Divider().frame(height: DFSize.iconMd2)

            Button(role: .destructive) {
                onRemoveSelectedStep()
            } label: {
                Label("이 단계 삭제", systemImage: "trash")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
            }
            .controlSize(.small)
            .disabled(stepCount <= 1)
            .help("동작에는 최소 한 단계가 있어야 해요")
        }
        .font(DFFont.caption)
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(DFColor.elev2.opacity(DFOpacity.dim))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    /// 키프레임 편집 아이콘 버튼 — Copy / Paste / Split 공통 스타일.
    private func keyframeIconButton(
        icon: String,
        help: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s11, weight: .semibold))
                .foregroundStyle(enabled ? tint : DFColor.textSecondary.opacity(DFOpacity.disabled))
                .frame(width: DFSize.iconMd, height: DFSize.iconMd)
                .background(enabled ? tint.opacity(DFOpacity.subtle) : DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(
                            enabled ? tint.opacity(DFOpacity.strong) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                            lineWidth: DFSize.borderHairline
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// 키프레임 시간 stepper — 라벨 + 값 (mono) + Stepper +/-. 변경 시 onChange 콜.
    private func keyframeStepperField(
        label: String,
        valueMs: Int,
        range: ClosedRange<Int>,
        stepMs: Int,
        tint: Color,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: DFSpace.xs) {
            Text(label)
                .font(.system(size: DFFontSize.s11))
                .foregroundStyle(DFColor.textSecondary)
            Text("\(valueMs)ms")
                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(minWidth: 56, alignment: .trailing)
                .monospacedDigit()
            Stepper("",
                    value: Binding(
                        get: { valueMs },
                        set: { onChange(max(range.lowerBound, min(range.upperBound, $0))) }
                    ),
                    in: range,
                    step: stepMs)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, DFSpace.xs2)
        .padding(.vertical, DFSpace.xs)
        .background(DFColor.canvas.opacity(DFOpacity.dim))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs)
                .stroke(tint.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
    }

    /// 선택된 step 의 playMs / pauseMs 갱신. nil 인 인자는 변경 안 함.
    ///
    /// **사이클 259 (W4.3.6) 분리**: 원래 MotionStudioView 의 private func.
    /// stepper 만의 mutation 이라 Timeline view 와 결속됨 — view 내부로 이동.
    /// doc / player 가 binding/observed 로 view 의 자산이므로 비결합.
    private func updateSelectedStepTiming(playMs: Int?, pauseMs: Int?) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        let stepCount = doc.motion.pages[doc.selectedPageIdx].steps.count
        guard doc.selectedStep >= 0, doc.selectedStep < stepCount else { return }
        var step = doc.motion.pages[doc.selectedPageIdx].steps[doc.selectedStep]
        let oldStep = step
        if let newPlay = playMs {
            // playMs / pauseMs 모두 raw (×8 ms) 로 저장 — 8 단위 quantize.
            let quantized = max(0, (newPlay / 8) * 8)
            step.playTime = UInt8(clamping: quantized / 8)
        }
        if let newPause = pauseMs {
            let quantized = max(0, (newPause / 8) * 8)
            step.pauseTime = UInt8(clamping: quantized / 8)
        }
        guard step != oldStep else { return }   // 무의미한 변경 skip (undo 폭주 방지).
        MotionPageActions.pushUndoSnapshot(in: doc)
        doc.motion.pages[doc.selectedPageIdx].steps[doc.selectedStep] = step
        MotionPageActions.markDirty(in: doc)
        // Player 에 변경 반영 — 재생 중이면 다음 tick 부터 적용.
        if let page = currentPage {
            let wasPlaying = player.mode == .playing
            let elapsed = player.elapsedMs
            player.page = page
            player.seek(toMs: elapsed)
            if wasPlaying { player.play() }
        }
    }
}

/// Array safe subscript — out-of-range index 시 nil (페이지 idx 안전 접근).
///
/// **사이클 259 (W4.3.6)**: MotionStudioView 에 fileprivate 으로 있던 것을
/// Timeline 도 stepDetailRow 에서 사용하므로 동반 정의. 두 파일이 같은 module
/// 내 fileprivate 이라 충돌 없음.
fileprivate extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
