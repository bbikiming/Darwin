import ForgeCore
import SwiftUI

/// 사이클 V281-1 (V280-A1) — `WalkLabView` 3D scene + overlay 분리.
///
/// # 비유
///
/// 자동차 dashboard 의 **중앙 stage** — 3D model + HUD overlay (속도계 / 자이로 /
/// 그래프 / 안내 banner) 만 책임. `WalkLabView` 본체는 dashboard composition
/// (좌측 패널 + 중앙 stage + 우측 행동 bar) 만 담당한다. 책임 분리로
/// 1427 LOC god view 를 800 LOC 한계 아래로 회복 (Fowler "Extract Class").
///
/// # 책임 (Single Responsibility)
///
/// - **3D scene 렌더링** (`RobotScene3D`): pose / footTrace / IMU read-only 입력
/// - **최소 HUD** (`sceneInfoOverlay`): preset + cycle phase + 보정 mode (항상)
/// - **Tertiary overlay 4 종** (`showSceneOverlays` 또는 `session.advanced` 시):
///   `SceneSpeedometerOverlay` / `SceneGyroMiniOverlay` / `SceneWalkGraphOverlay` /
///   `walkGuidanceBanner` (차단 사유 안내)
/// - **overlay toggle chip** — 4 종 일괄 표시/숨김
///
/// # 비-책임 (절대 안 함)
///
/// - session lifecycle (start/stop)
/// - actionBar
/// - banner priority
/// - sidebar / monitoring column
/// - preset 차단 사유 평가 — `WalkLabView` 가 계산 후 `blockingReasons` 로 주입
///
/// # 의존성
///
/// - `@Environment(WalkLabSession.self)` — 보행 상태 read
/// - `@Binding var showSceneOverlays: Bool` — 부모의 `@AppStorage` 와 연결
/// - `blockingReasons: [String]` — 부모가 사전 계산 후 주입 (banner 표시 only)
///
/// behavior 0 변경 — V281-1 이전 inline 구현과 layout / animation / visibility
/// 모두 동일 (pure structural refactoring).
struct WalkLabSceneSection: View {
    @Environment(WalkLabSession.self) private var session
    @Binding var showSceneOverlays: Bool
    /// 부모(`WalkLabView`) 가 `presetBlockingReason` 으로 사전 계산한 unique 리스트.
    /// 본 view 는 banner 표시만 담당 (계산 책임 분리).
    let blockingReasons: [String]

    var body: some View {
        RobotScene3D(
            pose: session.visualPose,
            footTrace: session.footTrailLefts,
            imuRollDeg: session.displayImuRollDeg,
            imuPitchDeg: session.displayImuPitchDeg
        )
        .frame(minHeight: 360, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
        )
        .overlay(alignment: .topLeading) {
            // 항상 표시 — minimal HUD (preset/phase/Δ). Primary.
            sceneInfoOverlay
                .padding(DFSpace.sm)
        }
        // Tertiary — 사용자 명시 토글 또는 advanced 모드 시만 노출.
        .overlay(alignment: .topTrailing) { sceneOverlayToggleChip }
        .overlay(alignment: .topTrailing) {
            if showSceneOverlays || session.advanced {
                SceneSpeedometerOverlay()
                    .padding(DFSpace.sm)
                    // chip 가 표시될 때만 stack 회피 padding. advanced 모드 시 chip hidden — 종전 정렬 유지.
                    .padding(.top, session.advanced ? 0 : DFSpace.lg)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showSceneOverlays || session.advanced {
                SceneGyroMiniOverlay().padding(DFSpace.sm)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showSceneOverlays || session.advanced {
                SceneWalkGraphOverlay().padding(DFSpace.sm)
            }
        }
        .overlay(alignment: .bottom) {
            if showSceneOverlays || session.advanced {
                walkGuidanceBanner
                    .padding(.bottom, DFSpace.sm2)
                    .padding(.horizontal, DFSpace.sm)
            }
        }
    }

    /// scene 우상단 small toggle — overlay 4종 일괄 표시/숨김.
    /// advanced 모드일 땐 강제 ON (UI에서 hidden), 명시 토글만 노출.
    @ViewBuilder
    private var sceneOverlayToggleChip: some View {
        if !session.advanced {
            Button {
                withAnimation(DFAnimation.fast) { showSceneOverlays.toggle() }
            } label: {
                Image(systemName: showSceneOverlays ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                    .font(DFFont.label)
                    .padding(DFSpace.xs)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(DFSpace.sm)
            .help(showSceneOverlays
                  ? "Scene 오버레이 4종 숨기기 (Speedometer / Gyro / Graph / 안내)"
                  : "Scene 오버레이 4종 표시")
            .accessibilityLabel(showSceneOverlays ? "scene 오버레이 숨기기" : "scene 오버레이 표시")
        }
    }

    /// **v1.11 (2026-05-17 사용자 요청) — 3D scene 좌상단 floating chip**:
    /// 빈 영역 시각 채움 + 정보 가치 추가. **항상 표시** (idle 도 안내):
    /// - idle 시: 보행 대기 안내 + walk_ready 자세 표기
    /// - walking 시: preset / cycle phase progress / 보정 Δ
    private var sceneInfoOverlay: some View {
        let isWalking = session.current != .idle
        return VStack(alignment: .leading, spacing: 4) {
            // 1행: preset 또는 idle 안내
            HStack(spacing: 6) {
                Image(systemName: isWalking ? "figure.walk.motion" : "figure.stand")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isWalking ? DFColor.accent : DFColor.textSecondary)
                Text(isWalking ? session.current.label : "보행 대기 · walk_ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DFColor.textPrimary)
            }
            // 2행: walking 시 cycle phase, idle 시 안내 부제
            if isWalking,
               let elapsedMs = session.lastWalkCycleElapsedMs,
               let periodMs = session.lastWalkPeriodMs,
               periodMs > 0 {
                HStack(spacing: 6) {
                    Text(String(format: "%.0f/%.0fms", elapsedMs, periodMs))
                        .font(DFFont.monoLabel)
                        .foregroundStyle(DFColor.textSecondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DFColor.textSecondary.opacity(DFOpacity.o20))
                            Capsule().fill(DFColor.accent)
                                .frame(width: geo.size.width
                                       * CGFloat(min(1, elapsedMs / periodMs)))
                        }
                    }
                    .frame(width: 60, height: 3)
                }
            } else if !isWalking {
                Text("프리셋을 시작하면 cycle phase 표시")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
            // 3행: 보정 status — 항상 표시 (config mode 인지)
            HStack(spacing: 6) {
                let modeIcon: String = {
                    switch session.balanceExperimentConfig.algorithmMode {
                    case .off:             return "power.circle"
                    case .robotisPControl: return "shield.fill"
                    case .hybridBA:        return "brain"
                    case .observeOnly:     return "eye.fill"
                    }
                }()
                let modeColor: Color = {
                    switch session.balanceExperimentConfig.algorithmMode {
                    case .off:             return DFColor.textSecondary
                    case .robotisPControl: return DFColor.success
                    case .hybridBA:        return DFColor.warning
                    case .observeOnly:     return DFColor.info
                    }
                }()
                Image(systemName: modeIcon)
                    .font(DFIcon.label)
                    .foregroundStyle(modeColor)
                if let delta = session.lastCorrections?.maxAbs, delta > 0.01 {
                    Text(String(format: "Δ%.1f° %@",
                                delta,
                                session.lastCorrectionApplied ? "적용" : "관찰"))
                        .font(DFFont.monoLabel)
                        .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text(session.balanceExperimentConfig.algorithmMode.label)
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                }
                // 사이클 167 (cycle 160 wire-up): IMU stale 신호 — 사용자가 보정 silent
                // 차단 인지. .normal 은 노출 X (이미 algorithm 라벨 표시).
                if session.balanceCorrectionFreshness != .normal {
                    freshnessBadge
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o15),
                        lineWidth: DFSize.borderHairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isWalking ? "보행 \(session.current.label) 진행 중" : "보행 대기")
    }

    /// 사이클 167 (cycle 160 HUD wire-up): IMU freshness 신호 inline badge.
    /// 사용자가 보정 ON 인데 robot 측 stale IMU 로 차단/감쇠 된 상태를 즉시 인지.
    /// .normal 은 별도 표시 안 함 (algorithm mode 라벨이 이미 있음).
    @ViewBuilder
    private var freshnessBadge: some View {
        let state = session.balanceCorrectionFreshness
        let (icon, color): (String, Color) = {
            switch state {
            case .normal:   return ("checkmark.circle", DFColor.success)
            case .degraded: return ("clock.badge.exclamationmark", DFColor.warning)
            case .blocked:  return ("xmark.octagon.fill", DFColor.danger)
            }
        }()
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(DFFont.labelStrong)
            Text(state.koreanLabel)
                .font(DFFont.micro)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.12))
        )
        .help("자이로 보정 상태: \(state.koreanLabel)")
        .accessibilityLabel("자이로 보정 \(state.koreanLabel)")
    }

    /// **v1.14.6 (2026-05-21) — 사용자 요청**: 3D 뷰 하단의 차단 사유 안내 banner.
    /// 부모(`WalkLabView`) 가 사전 계산한 `blockingReasons` 리스트 표시. 비어있으면 hidden.
    ///
    /// **V280-E (2026-05-24)**: hardcoded HStack/overlay → `DFBanner` (.warning).
    /// 가로 폭 520pt cap 유지 — narrow detail pane 에서 wrap 회피.
    @ViewBuilder
    private var walkGuidanceBanner: some View {
        if blockingReasons.isEmpty {
            EmptyView()
        } else {
            DFBanner(
                title: "일부 보행 모션 비활성",
                message: blockingReasons.joined(separator: " · "),
                severity: .warning
            )
            .frame(maxWidth: 520)
        }
    }
}
