import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - EStopDrillView
//
// 비행 전 "산소 마스크 착용 시연" 비유:
// 승무원이 실제로 마스크를 끼어보여줄 때처럼, OP Pilot 최초 사용 시
// 사용자가 E-Stop 버튼을 직접 한 번 눌러봐야 한다.
// 이렇게 해야 실제 긴급 상황에서 망설이지 않고 바로 누를 수 있다.
//
// 기술적으로:
//   - 첫 페어링 시에만 표시 (UserDefaults eStopDrillCompleted)
//   - 빨간 E-Stop 버튼 → 탭하면 haptic + 시각 ✓ + "이제 ARM 할 수 있어요"
//   - 토크 OFF 상태이므로 실제 물리 영향 없음 (fireEmergencyStop = noop)
//   - 완료 후 UserDefaults 에 저장 → 다음 페어링부터 skip

/// 첫 페어링 시 1회 강제 E-Stop 동작 확인 화면.
/// 완료 후 UserDefaults 에 저장되어 재페어링 시 skip.
public struct EStopDrillView: View {

    // MARK: - State

    @State private var drillCompleted: Bool = false
    @State private var isAnimating: Bool = false

    let onComplete: () -> Void

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    heroSection
                    instructionCard
                    eStopButton
                    if drillCompleted {
                        successSection
                        continueButton
                    }
                }
                .padding(DS.Space.l)
                .padding(.bottom, DS.Space.xxl)
            }
            .background(DS.Color.canvas.ignoresSafeArea())
            .navigationTitle("E-Stop 동작 확인")
            .dfInlineNavigationTitle()
            // **V292-C critic MAJOR-3 fix** — drill 완료 전후 모두 swipe-dismiss 차단.
            // Brief/Preflight 와 일관 정책. 완료 후 dismiss 는 명시적 "ARM 가능" CTA 만 허용.
            .interactiveDismissDisabled(true)
        }
        .accessibilityIdentifier("estopDrill.root")
    }

    // MARK: - Sub-views

    private var heroSection: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                Circle()
                    .fill(drillCompleted
                          ? DS.Color.success.opacity(0.12)
                          : DS.Color.danger.opacity(0.12))
                    .frame(width: 80, height: 80)
                    .animation(DS.Motion.standard, value: drillCompleted)

                Image(systemName: drillCompleted ? "checkmark.shield.fill" : "hand.raised.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(drillCompleted ? DS.Color.success : DS.Color.danger)
                    .animation(DS.Motion.standard, value: drillCompleted)
            }
            .accessibilityHidden(true)

            Text(drillCompleted ? "E-Stop 확인 완료!" : "E-Stop 버튼을 눌러보세요")
                .font(DS.Font.screenTitle)
                .animation(DS.Motion.standard, value: drillCompleted)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var instructionCard: some View {
        DSCard(tone: drillCompleted ? .success : .standard) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Label("이 화면은 최초 1회만 표시됩니다",
                      systemImage: "info.circle.fill")
                    .font(DS.Font.sectionTitle)
                    .foregroundStyle(drillCompleted ? DS.Color.success : DS.Color.brand)

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    instructionRow(icon: "1.circle.fill",
                                   text: "아래의 빨간 E-Stop 버튼을 탭하세요")
                    instructionRow(icon: "2.circle.fill",
                                   text: "조종 중 긴급 시에는 조종기 화면 상단의 상태 칩 옆 빨간 [STOP] 버튼을 즉시 탭")
                    instructionRow(icon: "3.circle.fill",
                                   text: "확인 후 잠금 해제(ARM) 가능 상태로 전환됩니다")
                }

                if !drillCompleted {
                    Text("지금은 토크가 OFF 상태이므로 로봇에 물리적 영향이 없습니다.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.top, DS.Space.xs)
                }
            }
        }
    }

    private var eStopButton: some View {
        Button {
            guard !drillCompleted else { return }
            performDrill()
        } label: {
            VStack(spacing: DS.Space.m) {
                ZStack {
                    // Outer ring
                    Circle()
                        .fill(drillCompleted ? DS.Color.success.opacity(0.15) : DS.Color.danger.opacity(0.15))
                        .frame(width: 140, height: 140)
                        .scaleEffect(isAnimating ? 1.08 : 1.0)
                        .animation(
                            isAnimating
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .default,
                            value: isAnimating
                        )

                    // Button face
                    Circle()
                        .fill(drillCompleted ? DS.Color.success : DS.Color.danger)
                        .frame(width: 112, height: 112)

                    VStack(spacing: DS.Space.xs) {
                        Image(systemName: drillCompleted ? "checkmark" : "stop.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                        Text(drillCompleted ? "완료" : "E-STOP")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .animation(DS.Motion.spring, value: drillCompleted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("E-Stop 버튼")
        .accessibilityHint(drillCompleted
                           ? "이미 완료됐습니다"
                           : "탭하여 E-Stop 동작을 확인하세요")
        .accessibilityIdentifier("estopDrill.button")
        .disabled(drillCompleted)
        .onAppear { isAnimating = !drillCompleted }
    }

    private var successSection: some View {
        DSCard(tone: .success) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Label("E-Stop 동작 확인됨", systemImage: "checkmark.seal.fill")
                    .font(DS.Font.sectionTitle)
                    .foregroundStyle(DS.Color.success)
                Text("실제 긴급 상황에서는 조종기 화면 상단의 상태 칩 옆 빨간 [STOP] 버튼을 즉시 탭하세요.\n이제 잠금 해제(ARM) 할 수 있습니다.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var continueButton: some View {
        DSButton("ARM 가능 — 시작하기",
                 systemImage: "figure.stand",
                 style: .success,
                 size: .large,
                 fullWidth: true) {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            #endif
            onComplete()
        }
        .frame(minHeight: DS.Hit.estop)
        .accessibilityIdentifier("estopDrill.continue")
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Actions

    private func performDrill() {
        isAnimating = false
        withAnimation(DS.Motion.spring) {
            drillCompleted = true
        }
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
        // fireEmergencyStop 은 현재 토크 OFF 상태이므로 noop — 시각/햅틱만 제공.
        // AppState.performEStop() 은 실제 페이로드 전송이므로 drill 에서는 호출하지 않음.
    }

    // MARK: - Helpers

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: icon)
                .foregroundStyle(DS.Color.info)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
