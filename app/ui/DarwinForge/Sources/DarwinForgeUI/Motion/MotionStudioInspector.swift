import ForgeCore
import SwiftUI

/// 사이클 258 (Wave 4.3.5) — `MotionStudioView` 우측 자세 편집기 패널 분리.
///
/// **목적**: MotionStudioView 1251 줄 god view 분할.
/// 우측 inspector wrapper (제목 헤더 + 닫기 버튼 + PoseInspector) 책임을
/// 독립 View 로 격리.
///
/// **책임**:
/// - 자세 편집기 헤더 (타이틀 + 닫기 토글)
/// - `PoseInspector` 호출 + binding 전달 + 송출 로직 위임
///
/// **소유권**:
/// - `pose` / `selected` / `isOpen` 은 owner 의 @State 를 Binding 으로 받음.
/// - `liveApply` (sendToHardware) 는 read-only value.
/// - `onPoseEdit` / `onApplyToHardware` 는 closure — owner 가 mutation /
///   하드웨어 송출 로직을 책임.
@MainActor
struct MotionStudioInspector: View {
    @Binding var pose: RobotPose
    @Binding var selected: JointID?
    @Binding var isOpen: Bool

    /// PoseInspector 가 표시할 실측 joint state (telemetry / lastKnown).
    let states: [JointID: JointState]

    /// 송출 활성 표시 + PoseInspector live apply 동작 트리거.
    let liveApply: Bool

    // MARK: - Action callbacks

    /// 사용자가 자세 슬라이더를 변경했을 때 — owner 가 stagedPose 갱신 +
    /// 현재 step 저장 + (필요 시) 하드웨어 송출.
    let onPoseEdit: (RobotPose) -> Void

    /// PoseInspector 의 "로봇에 적용" 버튼 — owner 가 비동기 송출.
    let onApplyToHardware: (RobotPose) -> Void

    var body: some View {
        VStack(spacing: DFSpace.none) {
            HStack {
                Text("자세 편집기").font(DFFont.bodyEmph)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { isOpen = false }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DFColor.textSecondary)
                .help("자세 편집기 닫기")
                .accessibilityLabel("자세 편집기 닫기")
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm)
            .background(DFColor.elev2)
            Divider()

            PoseInspector(
                pose: Binding(
                    get: { pose },
                    set: { onPoseEdit($0) }
                ),
                selected: $selected,
                states: states,
                liveApply: liveApply,
                onApplyToHardware: onApplyToHardware
            )
        }
    }
}
