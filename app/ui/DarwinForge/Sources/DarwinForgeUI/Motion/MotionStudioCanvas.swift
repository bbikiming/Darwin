import ForgeCore
import SwiftUI

/// 사이클 259 (Wave 4.3.6) — `MotionStudioView` 중앙 3D 캔버스 분리.
///
/// **목적**: MotionStudioView 929 줄 god view 분할 — 4.3.5 (Sidebar / Inspector)
/// 에 이어 centerColumn 의 3D 영역을 독립 View 로 격리.
///
/// **책임**:
/// - `RobotScene3D` 미러 렌더 (stagedPose + footTrace=[] + highlight)
/// - `sourceModeBadge` — 편집/실시간 편집/재생 미리보기/송출 중 4-case 분기
/// - `pageMetaBadge` — 현재 페이지 이름 + step/next/exit 요약
/// - `ViewportControls` — top-trailing 카메라 위치 단축버튼
///
/// **소유권**:
/// - `pose` / `inspectorJoint` 는 owner 의 @State value (read-only, 캔버스는 표시만).
/// - `camera` 는 owner 의 `@StateObject` 를 `@ObservedObject` 로 받음.
/// - `currentPage` 는 owner 의 derived value (read-only).
/// - `sourceMode` 는 owner 가 계산해 전달 — `player.mode` / `sendToHardware` /
///   `store.bus` 등의 다중 의존성을 owner 에 집중시켜 본 view 는 표시 책임만.
///
/// **불변**:
/// - 분리 전후 3D 렌더 결과 byte-identical (RobotScene3D 호출 인자 동일).
/// - 두 badge 의 위치 / 스타일 / help 텍스트 동일.
@MainActor
struct MotionStudioCanvas: View {
    /// 미러에 표시할 자세 — owner 의 `stagedPose`.
    let pose: RobotPose

    /// 강조 표시할 관절 — `nil` 이면 highlight 없음.
    let highlightJoint: JointID?

    /// 카메라 컨트롤러 — 좌상단 badge 와 우상단 ViewportControls 모두 공유.
    @ObservedObject var camera: CameraController
    /// **W3**: 로봇공학 오버레이 토글 store(Motion 기본값 — EE 궤적 포함).
    @StateObject private var overlayStore = OverlayToggleStore(preset: .motion)

    /// 좌상단 badge 에 표시할 현재 source mode (owner 계산).
    let sourceMode: SourceMode

    /// 좌상단 badge 에 표시할 현재 페이지 (nil 이면 page badge 미표시).
    let currentPage: MotionPage?

    /// 3D 뷰포트 데이터 출처 — 4가지 상태로 사용자가 자기 행동의 효과를 정확히 인지.
    ///
    /// **사이클 259 분리**: 원래 MotionStudioView 내부 private enum. Canvas
    /// 가 표시만 책임지므로 enum 도 동반 이동. owner 의 `currentSourceMode`
    /// computed 가 이 enum 값을 계산해 전달.
    enum SourceMode {
        case editing       // 정지/일시정지 + 송출 OFF (또는 버스 nil) — 진정한 화면-only.
        case liveEditing   // 정지/일시정지 + 송출 ON + 버스 있음 — 슬라이더 한 번에 모터 1번.
        case previewing    // 재생 + 송출 OFF (또는 버스 nil) — 화면에서만 재생.
        case broadcasting  // 재생 + 송출 ON + 버스 있음 — 모션 전체가 로봇으로 송출.

        var title: String {
            switch self {
            case .editing:      return "편집 미리보기"
            case .liveEditing:  return "실시간 편집 송출"
            case .previewing:   return "재생 미리보기"
            case .broadcasting: return "로봇으로 송출 중"
            }
        }
        var icon: String {
            switch self {
            case .editing:      return "pencil.tip"
            case .liveEditing:  return "slider.horizontal.below.rectangle"
            case .previewing:   return "play.tv"
            case .broadcasting: return "antenna.radiowaves.left.and.right"
            }
        }
        var help: String {
            switch self {
            case .editing:
                return "선택한 단계의 자세를 화면에만 보여줍니다. 로봇은 움직이지 않아요."
            case .liveEditing:
                // **Codex pass 3 [P2]**: MotionStudioView 의 PoseInspector binding setter
                // 가 매 변경마다 stagedPose 갱신 + `if sendToHardware` 즉시 송출 —
                // PoseInspector 내부의 commit-only logic 을 우회한다.
                // 따라서 드래그 중 매 frame 송출이 일어남. 사실대로 안내.
                return "슬라이더가 움직이는 동안 매 변경이 곧바로 로봇으로 송출됩니다. 모터 부하가 클 수 있으니 큰 변경 전에는 ‘로봇에 보내기’ 토글을 끄세요."
            case .previewing:
                return "모션을 화면에서만 재생합니다. 로봇은 움직이지 않아요."
            case .broadcasting:
                return "재생 중인 모션이 실 로봇으로 송출되고 있습니다."
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RobotScene3D(pose: pose,
                         footTrace: [],
                         highlight: highlightJoint,
                         showAxes: true,
                         cameraController: camera,
                         preset: .motion,
                         overlays: overlayStore.overlays)
            // 3D 가 무엇을 보여주는지 명확히 — 사용자가 편집/재생/송출을 한눈에 구분.
            HStack(spacing: DFSpace.xs) {
                sourceModeBadge
                pageMetaBadge
            }
            .padding(DFSpace.md)
            ViewportControls(camera: camera, overlayStore: overlayStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
        }
        .background(LinearGradient(colors: [DFColor.canvas.opacity(DFOpacity.dim), DFColor.canvas],
                                    startPoint: .top, endPoint: .bottom))
    }

    private var sourceModeBadge: some View {
        let mode = sourceMode
        let tint: Color = {
            switch mode {
            case .editing:      return DFColor.textSecondary
            case .liveEditing:  return DFColor.warning  // 송출은 맞지만 부분적 — 주황.
            case .previewing:   return DFColor.info
            case .broadcasting: return DFColor.danger   // 전체 모션 송출 — 빨강.
            }
        }()
        return HStack(spacing: DFSpace.xs) {
            Image(systemName: mode.icon)
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(tint)
            Text(mode.title)
                .font(.system(size: DFFontSize.s10, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 0.8))
        .help(mode.help)
    }

    private var pageMetaBadge: some View {
        Group {
            if let page = currentPage {
                HStack(spacing: DFSpace.sm) {
                    Image(systemName: "doc.text").foregroundStyle(DFColor.accent)
                    VStack(alignment: .leading, spacing: DFSpace.none) {
                        Text(page.name.isEmpty ? "동작 \(page.id)" : page.name)
                            .font(DFFont.bodyEmph)
                        Text(metaLine(for: page))
                            .font(DFFont.caption.monospaced())
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
                .padding(.horizontal, DFSpace.md)
                .padding(.vertical, DFSpace.sm)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            }
        }
    }

    private func metaLine(for page: MotionPage) -> String {
        var parts: [String] = []
        parts.append("\(page.steps.count)단계")
        if page.nextPage != 0 { parts.append("다음: 동작 \(page.nextPage)") }
        if page.exitPage != 0 { parts.append("종료: 동작 \(page.exitPage)") }
        return parts.joined(separator: " · ")
    }
}
