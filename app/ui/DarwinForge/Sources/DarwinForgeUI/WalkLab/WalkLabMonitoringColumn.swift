import ForgeCore
import SwiftUI

/// 사이클 V281-1 (V280-A1) — `WalkLabView` 좌측 모니터링 column 분리.
///
/// # 비유
///
/// 자동차 dashboard 의 **좌측 슬라이딩 글러브박스** — 닫힘 시 얇은 세로
/// stripe (펼치기 버튼) 만 노출, 펼침 시 Fall Prevention 모니터링 패널 전체.
/// 사용자가 좌우 drag 으로 너비 조절 (macOS Mail / Notes inspector 패턴).
///
/// # 책임 (Single Responsibility)
///
/// - **세로 stripe (collapsed)**: 펼치기 버튼 + `⌘⇧M` 단축키
/// - **확장 sidebar (expanded)**: macOS-native Inspector header + 닫기 버튼 +
///   `FallPreventionMonitor` ScrollView
/// - **drag handle**: 6pt hit area + 1pt visible line. 좌우 drag → 너비 update.
///   `@AppStorage("df.walklab.fallPanelWidth")` 영속 — 다음 실행 시 자동 복원.
///
/// # 비-책임 (절대 안 함)
///
/// - actionBar / banner / sidebar (PresetButton)
/// - session lifecycle
/// - 3D scene / 사이드 패널 카드
///
/// # 의존성
///
/// - `@Environment(WalkLabSession.self)` — `monitoringExpanded` read/write
///
/// behavior 0 변경 — V281-1 이전 inline 구현과 layout / animation / visibility /
/// drag clamp / `⌘⇧M` shortcut 모두 동일 (pure structural refactoring).
struct WalkLabMonitoringColumn: View {
    @Environment(WalkLabSession.self) private var session

    /// **v1.11 (2026-05-17 사용자 요청)**: Fall Prevention 패널 너비 — 사용자 drag
    /// 으로 조절 + 다음 실행 시 복원. UserDefaults key `df.walklab.fallPanelWidth`.
    /// 기본 380pt, range 280..720.
    @AppStorage("df.walklab.fallPanelWidth") private var fallPanelWidth: Double = 380
    /// Drag 시작 시점의 너비 — translation 누적 계산용.
    @State private var fallPanelDragStartWidth: Double? = nil
    /// Drag handle hover 상태 — 시각 highlight 용.
    @State private var fallPanelHandleHovering: Bool = false

    var body: some View {
        if session.monitoringExpanded {
            HStack(alignment: .top, spacing: DFSpace.none) {
                expandedSidebar
                dragHandle
            }
        } else {
            collapsedStripe
        }
    }

    /// 좌측 세로 모니터링 dashboard column — `monitoringExpanded` 시만 표시.
    /// 헤더에 닫기 버튼 (sidebar.left) + 본문 `FallPreventionMonitor` ScrollView.
    private var expandedSidebar: some View {
        VStack(spacing: 0) {
            // **macOS-native header** — Inspector style. material background.
            HStack(spacing: DFSpace.sm) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DFColor.accent.gradient)
                Text("Fall Prevention")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DFColor.textPrimary)
                Spacer()
                Button {
                    withAnimation(DFAnimation.fast) {
                        session.monitoringExpanded = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DFColor.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("모니터링 패널 접기 (⌘⇧M)")
                .accessibilityLabel("모니터링 패널 접기")
            }
            .padding(.horizontal, DFSpace.sm2)
            .padding(.vertical, DFSpace.sm)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                FallPreventionMonitor(session: session)
                    .padding(DFSpace.sm)
            }
            .scrollIndicators(.automatic)
        }
        // **v1.11 (2026-05-17)**: AppStorage 가 관리하는 사용자 drag 너비 적용.
        // `dragHandle` 이 옆에서 lifecycle 관리.
        .frame(width: CGFloat(fallPanelWidth))
        .background(.regularMaterial)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// **v1.11 (2026-05-17 사용자 요청) — Fall Prevention 패널 drag handle**.
    ///
    /// 6pt 너비 hit area + 1pt visible line (hover 시 3pt + accent). 좌우 drag 으로
    /// `fallPanelWidth` 업데이트 (clamp 280..720). `NSCursor.resizeLeftRight` 자동.
    /// 사용자 마지막 너비는 `@AppStorage` 가 다음 실행 때 자동 복원.
    private var dragHandle: some View {
        let isActive = fallPanelHandleHovering || fallPanelDragStartWidth != nil
        return ZStack {
            // Hit area (cursor + drag) — 투명 6pt.
            Color.clear
                .contentShape(Rectangle())
            // Visible line — 1pt 또는 3pt (hover/drag 시).
            Rectangle()
                .fill(isActive ? DFColor.accent : DFColor.textSecondary.opacity(DFOpacity.o20))
                .frame(width: isActive ? 3 : 1)
                .animation(DFAnimation.fast, value: isActive)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            fallPanelHandleHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if fallPanelDragStartWidth == nil {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if fallPanelDragStartWidth == nil {
                        fallPanelDragStartWidth = fallPanelWidth
                    }
                    let newWidth = (fallPanelDragStartWidth ?? fallPanelWidth)
                                 + Double(value.translation.width)
                    fallPanelWidth = max(280, min(720, newWidth))
                }
                .onEnded { _ in
                    fallPanelDragStartWidth = nil
                    if !fallPanelHandleHovering {
                        NSCursor.pop()
                    }
                }
        )
        .help("좌우 drag — Fall Prevention 패널 너비 조절")
        .accessibilityLabel("패널 너비 조절")
        .accessibilityHint("좌우 드래그하여 너비를 조절합니다")
    }

    /// 접힘 상태의 좌측 edge 세로 stripe — 펼치기 버튼 + 라벨.
    /// macOS Mail / Notes 의 sidebar collapse 패턴 정합.
    private var collapsedStripe: some View {
        VStack(spacing: DFSpace.sm) {
            Button {
                withAnimation(DFAnimation.fast) {
                    session.monitoringExpanded = true
                }
            } label: {
                VStack(spacing: DFSpace.xs2) {
                    Image(systemName: "chevron.right")
                        .font(DFFont.sectionBody)
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(DFFont.sectionBody)
                    Text("모니터링")
                        .font(DFFont.micro)
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                        .frame(width: 12, height: 60)
                }
                .foregroundStyle(DFColor.accent)
                .padding(.vertical, DFSpace.md)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("Fall Prevention 모니터링 펼치기 (⌘⇧M)")
            .accessibilityLabel("Fall Prevention 모니터링 펼치기")
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Spacer()
        }
        .frame(width: 36)
        .frame(maxHeight: .infinity)
        .background(DFColor.elev2)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DFColor.textSecondary.opacity(DFOpacity.subtle))
                .frame(width: DFSize.borderHairline)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}
