import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SafetyBriefModal
//
// 비행기 이륙 전 안전 영상 비유:
// 항공사는 "이미 아는 내용이에요"라고 해도 매번 안전 영상을 튼다.
// 승객이 건너뛸 수 없고, 항상 본다. OP Pilot 도 동일하다 — 페어링 성공 후
// 매번 이 3-check 브리핑을 통과해야만 다음 단계(Preflight)로 진행할 수 있다.
//
// 기술적으로:
//   - 3개 체크박스 모두 ON → "다음" 버튼 활성
//   - 부분 체크 → "다음" 비활성 (ARM 차단)
//   - "다시 보지 않기" 옵션 없음 — 매 페어링마다 강제
//
// ISA-101 DS 토큰 준수: 위험 = vermillion #D55E00 (DS.Color.danger),
// 정상 상태 = DS grayscale

/// 페어링 성공 후 강제 표시되는 안전 브리핑 모달.
/// 항공 안전 영상처럼 dismiss 불가 — 3개 체크 완료 후에만 진행 가능.
public struct SafetyBriefModal: View {

    // MARK: - State

    @State private var check1: Bool = false  // 1m 공간 확보
    @State private var check2: Bool = false  // E-Stop 버튼 위치 확인
    @State private var check3: Bool = false  // 평평한 바닥

    let onContinue: () -> Void

    public init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    // MARK: - Computed

    private var allChecked: Bool {
        check1 && check2 && check3
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    heroSection
                    checklistSection
                    continueButton
                    mandatoryNotice
                }
                .padding(DS.Space.l)
                .padding(.bottom, DS.Space.xxl)
            }
            .background(DS.Color.canvas.ignoresSafeArea())
            .navigationTitle("안전 브리핑")
            .dfInlineNavigationTitle()
            // dismiss 불가: .interactiveDismissDisabled
            .interactiveDismissDisabled(true)
        }
        .accessibilityIdentifier("safetyBrief.root")
    }

    // MARK: - Sub-views

    private var heroSection: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                Circle()
                    .fill(DS.Color.danger.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(DS.Color.danger)
            }
            .accessibilityHidden(true)

            Text("시작 전 안전 확인")
                .font(DS.Font.screenTitle)
                .accessibilityAddTraits(.isHeader)

            Text("OP2 주변 안전을 확인하세요.\n아래 3가지를 모두 확인해야 다음 단계로 이동할 수 있습니다.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var checklistSection: some View {
        DSCard(tone: .standard) {
            VStack(spacing: DS.Space.l) {
                briefCheckRow(
                    isChecked: $check1,
                    icon: "person.fill.viewfinder",
                    title: "OP2 주변 1m 공간 확보",
                    detail: "로봇 반경 1m 이내에 사람, 장애물이 없는지 확인하세요.",
                    accessibilityID: "safetyBrief.check.space"
                )

                Divider()

                briefCheckRow(
                    isChecked: $check2,
                    icon: "hand.raised.fill",
                    title: "E-Stop 버튼 위치 확인",
                    detail: "화면 오른쪽 상단 빨간 버튼이 E-Stop입니다. 위치를 확인하세요.",
                    iconTint: DS.Color.danger,
                    accessibilityID: "safetyBrief.check.estop"
                )

                Divider()

                briefCheckRow(
                    isChecked: $check3,
                    icon: "square.grid.3x1.fill.below.line.grid.1x2",
                    title: "평평하고 미끄럽지 않은 바닥",
                    detail: "카펫, 타일, 나무 바닥 — 경사 없이 평평한 곳에서 작동하세요.",
                    accessibilityID: "safetyBrief.check.floor"
                )
            }
        }
    }

    private var continueButton: some View {
        VStack(spacing: DS.Space.s) {
            DSButton("다음 — Preflight 점검",
                     systemImage: allChecked ? "checkmark.shield.fill" : "lock.fill",
                     style: .primary,
                     size: .large,
                     fullWidth: true,
                     disabled: !allChecked) {
                guard allChecked else { return }
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                onContinue()
            }
            .frame(minHeight: DS.Hit.estop)
            .accessibilityIdentifier("safetyBrief.continue")
            .accessibilityHint(allChecked
                               ? "Preflight 점검으로 이동합니다"
                               : "위 3가지를 모두 체크해야 활성화됩니다")

            if !allChecked {
                Text("3가지 항목을 모두 체크해야 다음으로 이동할 수 있어요")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("safetyBrief.hint")
            }
        }
    }

    private var mandatoryNotice: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "info.circle")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            Text("이 화면은 매 페어링마다 표시됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.tertiaryText)
        }
    }

    // MARK: - Check Row

    private func briefCheckRow(isChecked: Binding<Bool>,
                                icon: String,
                                title: String,
                                detail: String,
                                iconTint: Color = DS.Color.brand,
                                accessibilityID: String) -> some View {
        Button {
            withAnimation(DS.Motion.quick) { isChecked.wrappedValue.toggle() }
            #if canImport(UIKit)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
        } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                        .fill(isChecked.wrappedValue ? DS.Color.success : DS.Color.elevated)
                        .frame(width: 28, height: 28)
                    if isChecked.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: icon)
                            .font(DS.Font.caption)
                            .foregroundStyle(iconTint)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.primaryText)
                    }
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(isChecked.wrappedValue ? "체크됨. 탭하여 해제" : "탭하여 확인")
        .accessibilityAddTraits(isChecked.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
    }
}
