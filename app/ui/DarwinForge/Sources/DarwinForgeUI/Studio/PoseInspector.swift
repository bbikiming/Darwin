import ForgeCore
import SwiftUI

/// 20-DOF 자세 편집 인스펙터.
/// - body part 그룹 별 슬라이더
/// - 좌우 미러 토글
/// - 실시간 실기기 적용 vs 스테이징
public struct PoseInspector: View {
    @Binding public var pose: RobotPose
    @Binding public var selected: JointID?
    public let states: [JointID: JointState]
    public let liveApply: Bool
    public let onApplyToHardware: (RobotPose) -> Void

    @EnvironmentObject var store: ConnectionStore
    @State private var mirrorEnabled: Bool = false

    public init(pose: Binding<RobotPose>,
                selected: Binding<JointID?>,
                states: [JointID: JointState] = [:],
                liveApply: Bool = false,
                onApplyToHardware: @escaping (RobotPose) -> Void) {
        self._pose = pose
        self._selected = selected
        self.states = states
        self.liveApply = liveApply
        self.onApplyToHardware = onApplyToHardware
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sliders
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            Divider()
            footer
        }
        .background(DFColor.card)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("자세 편집기")
                .font(DFFont.title)
            Text("슬라이더로 20개 관절 각도를 조절해요")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)

            // 모터 속도 프로파일 — 자세 변경 시 적용될 보간 속도.
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11))
                    .foregroundStyle(DFColor.accent)
                Text("이동 속도")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
                Picker("", selection: $store.motorSpeedProfile) {
                    ForEach(MotorSpeedProfile.allCases) { p in
                        Label(p.koreanLabel, systemImage: p.icon).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .help(store.motorSpeedProfile.subtitle)
                Spacer()
            }

            HStack(spacing: DFSpace.sm) {
                Toggle("좌우 함께", isOn: $mirrorEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("오른쪽 슬라이더를 움직이면 왼쪽도 거울처럼 같이 움직여요")
                Spacer()
                if liveApply {
                    Label("실시간 적용 중", systemImage: "bolt.fill")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.warning)
                } else {
                    Label("미리보기", systemImage: "tray.fill")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
        .padding(DFSpace.md)
    }

    // MARK: - Sliders

    private var sliders: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                ForEach(BodyPartGroup.all, id: \.label) { group in
                    bodyPartSection(group)
                }
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm)
        }
        .glassScroll(accent: DFColor.forge)
    }

    private func bodyPartSection(_ group: BodyPartGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.icon)
                    .foregroundStyle(group.tint)
                Text(group.label)
                    .font(DFFont.bodyEmph)
                Spacer()
                Button {
                    centerGroup(group)
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("이 부위 관절을 모두 0°(중심)로 되돌립니다")
                .foregroundStyle(DFColor.textSecondary)
            }
            .padding(.bottom, 2)

            ForEach(visibleJoints(in: group), id: \.self) { j in
                jointSlider(for: j)
            }
        }
    }

    private func visibleJoints(in group: BodyPartGroup) -> [JointID] {
        let all = JointID.allCases.filter { $0.bodyPart == group.part }
        // 미러가 켜졌고 그룹이 좌측이면 숨김 (우측만 슬라이더로 노출).
        if mirrorEnabled, group.part == .leftArm || group.part == .leftLeg {
            return []
        }
        return all
    }

    private func jointSlider(for j: JointID) -> some View {
        let raw = pose.raw(j)
        let degree = pose.degrees(j)
        let limits = j.degreeLimits
        let isSelected = selected == j
        let limitDistance = min(degree - limits.lowerBound, limits.upperBound - degree)
        let limitNear = limitDistance < 8

        return HStack(spacing: 6) {
            // 라벨만 selection 탭 영역으로 지정 — slider / StepperField hit-area 와의
            // gesture 충돌 방지 (child Button 액션이 무시되던 원인).
            VStack(alignment: .leading, spacing: 0) {
                Text(j.koreanLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? DFColor.accent : DFColor.textPrimary)
                Text(j.name)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
            }
            .frame(width: 144, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selected = j }
            .help("\(j.koreanLabel) · ID \(j.rawValue) · 한계 \(Int(limits.lowerBound))°~\(Int(limits.upperBound))°")

            // P0-A: drag 중에는 미리보기(pose 상태)만 갱신, 모터 명령은 *드래그 끝*에 1회.
            // 근거: AUDIT §1.1 — 매 프레임 setPosition 16개 호출 = ~800ms 버스 플러드.
            //       Apple HIG "Sliders" + ROS rqt_joint_trajectory_controller 패턴.
            Slider(
                value: Binding(
                    get: { Double(degree) },
                    set: { newDeg in update(joint: j, degrees: newDeg, commit: false) }
                ),
                in: limits,
                onEditingChanged: { editing in
                    if !editing {
                        // 드래그 종료 — 누적된 자세를 hardware로 한 번만 commit.
                        update(joint: j, degrees: pose.degrees(j), commit: true)
                    }
                }
            )

            VStack(alignment: .trailing, spacing: 2) {
                StepperField(
                    value: Binding(
                        get: { Double(degree) },
                        set: { newDeg in update(joint: j, degrees: newDeg, commit: false) }
                    ),
                    in: limits,
                    step: 1,
                    bigStep: 10,
                    unit: "°",
                    tint: limitNear ? DFColor.warning : nil,
                    fieldWidth: 36,
                    onCommit: { newDeg in update(joint: j, degrees: newDeg, commit: true) }
                )
                if limitNear {
                    Text("한계 가까움")
                        .font(.system(size: 9))
                        .foregroundStyle(DFColor.warning)
                } else {
                    Text("raw \(raw)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? DFColor.accent.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // row-wide onTapGesture 제거 — child Button (StepperField + / −) 의 hit-test
        // 와 충돌해 액션이 발화되지 않던 문제 수정. 선택은 라벨 컬럼 탭으로 일원화.
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DFSpace.sm) {
            Button {
                pose = RobotPose.walkReady
                if liveApply { onApplyToHardware(pose) }
            } label: {
                Label("기본 자세", systemImage: "figure.stand")
            }
            .help("워크랩과 동일 — ROBOTIS framework standing posture (walk_ready)")
            Button {
                pose = RobotPose.tPose
                if liveApply { onApplyToHardware(pose) }
            } label: {
                Label("T 자세", systemImage: "figure.arms.open")
            }
            .help("T-pose — 진단·캘리브레이션용 표준 자세")
            Button {
                pose = pose.mirrored()
                if liveApply { onApplyToHardware(pose) }
            } label: {
                Label("좌우 바꾸기", systemImage: "arrow.left.and.right")
            }
            .help("현재 자세의 왼쪽과 오른쪽을 거울처럼 뒤집어요")
            Spacer()
            Button {
                onApplyToHardware(pose)
            } label: {
                Label("로봇에 보내기", systemImage: "bolt.horizontal.fill")
            }
            .buttonStyle(.glassNeon(tint: DFColor.forge, height: DFSize.buttonHSmall))
            .help("지금 편집 중인 자세를 한 번에 실제 로봇에 적용합니다")
        }
        .padding(DFSpace.md)
        .background(DFColor.elev2)
    }

    // MARK: - Actions

    /// 슬라이더 값 변경.
    /// - Parameter commit: true면 hardware로 발행 (드래그 끝 또는 footer 버튼).
    ///                     false면 SwiftUI `pose` 상태만 갱신 (드래그 중 미리보기).
    private func update(joint: JointID, degrees: Double, commit: Bool = true) {
        let raw = Kinematics.raw(fromDegrees: degrees)
        var next = pose.with(joint, raw: raw)
        if mirrorEnabled, joint != .headPan, joint != .headTilt {
            // 미러: 좌측 짝을 함께 조정. yaw/roll은 부호 반전.
            let mate = joint.mirrored
            let sign = joint.mirrorSignFlip ? -1.0 : 1.0
            next = next.with(mate, raw: Kinematics.raw(fromDegrees: degrees * sign))
        }
        pose = next
        if liveApply && commit { onApplyToHardware(next) }
    }

    private func centerGroup(_ group: BodyPartGroup) {
        var updates: [JointID: Int] = [:]
        for j in JointID.allCases where j.bodyPart == group.part {
            updates[j] = 2048
        }
        let next = pose.with(updates)
        pose = next
        if liveApply { onApplyToHardware(next) }
    }
}

// MARK: - BodyPartGroup

public struct BodyPartGroup: Hashable, Sendable {
    public let part: JointID.BodyPart
    public let label: String
    public let icon: String
    public let tint: Color

    public static let all: [BodyPartGroup] = [
        .init(part: .head,      label: "머리",       icon: "person.crop.circle",    tint: DFColor.forge),
        .init(part: .rightArm,  label: "우측 팔",     icon: "figure.arms.open",      tint: DFColor.accent),
        .init(part: .leftArm,   label: "좌측 팔",     icon: "figure.arms.open",      tint: DFColor.accent),
        .init(part: .rightLeg,  label: "우측 다리",   icon: "figure.walk",           tint: DFColor.success),
        .init(part: .leftLeg,   label: "좌측 다리",   icon: "figure.walk",           tint: DFColor.success)
    ]
}
