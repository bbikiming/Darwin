import SwiftUI

/// **v1.11 (2026-05-17 사용자 prompt)**: 자이로 보정 4축 실험 패널.
///
/// 사용자 prompt 의 핵심 요구:
/// 1. **Profile picker (default)** — 한 줄 선택 (ROBOTIS 기본 / v1.10 관찰 / v1.10 적용 / 보정 OFF).
///    초보자 / 일반 사용자가 보는 기본 UI.
/// 2. **Expert disclosure** — 펼치면 4축 (algorithm / sign / gain / apply) 개별 세그먼티드 컨트롤.
///    A/B 실험을 직접 조합하는 사용자만 사용.
/// 3. **Safety verdict 표시** — `BalanceExperimentConfig.safetyVerdict` 가
///    `.caution` / `.blocked` 일 때 카드 상단 노란/빨간 배너.
/// 4. **알고리즘 / 부호 분리** — 종전 v1.10 에서 Hybrid B+A 와 ROBOTIS 부호가
///    한 묶음으로 묶여 "어느 차원이 효과를 냈는지" 분리 검증 불가했던 문제 해결.
public struct BalanceExperimentControls: View {
    @ObservedObject var session: WalkLabSession
    @State private var showExpert: Bool = false
    /// **v1.11.1 (2026-05-18 사용자 review MEDIUM-6)**: hybridBA + applyToRobot 또는
    /// v110Experimental gain + applyToRobot 토글 시 명시 확인 sheet.
    @State private var pendingRiskyApply: BalanceExperimentConfig? = nil

    public init(session: WalkLabSession) {
        self.session = session
    }

    /// **v1.11.2 (2026-05-18 사용자 review P1) — 모든 config 변경의 단일 진입점**.
    ///
    /// 종전 버그: profile picker 의 v1.10 적용 버튼 / Expert 4축 picker 가 직접
    /// `session.balanceExperimentConfig = ...` 호출 → confirmation sheet 우회.
    /// applyToRobot=true 상태에서 algorithm 만 hybridBA 로 바꾸면 sheet 없이 즉시 적용.
    ///
    /// fix: 모든 진입점이 본 helper 거치게 통일. 새 config 가 isRiskyToApply 면
    /// 무조건 sheet (이전 config 가 risky 였든 안 했든 — 매 변경마다 의도 재확인).
    private func requestConfigChange(_ newConfig: BalanceExperimentConfig) {
        if newConfig.isRiskyToApply {
            pendingRiskyApply = newConfig
        } else {
            session.balanceExperimentConfig = newConfig
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            // 1) Safety verdict 배너 — 최상단, 위험 조합 즉시 인지.
            safetyBanner

            // 2) Profile picker — 한 줄로 자주 쓰는 4개 프로파일.
            profileRow

            // 3) Expert disclosure — 4축 개별 세그먼티드 컨트롤.
            DisclosureGroup(isExpanded: $showExpert) {
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    axisControl(
                        title: "알고리즘",
                        icon: "function",
                        selection: Binding(
                            get: { session.balanceExperimentConfig.algorithmMode },
                            set: { newMode in
                                requestConfigChange(BalanceExperimentConfig(
                                    algorithmMode: newMode,
                                    signConvention: session.balanceExperimentConfig.signConvention,
                                    gainProfile: session.balanceExperimentConfig.gainProfile,
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot
                                ))
                            }
                        )
                    )

                    axisControl(
                        title: "부호 규약",
                        icon: "plus.forwardslash.minus",
                        selection: Binding(
                            get: { session.balanceExperimentConfig.signConvention },
                            set: { newSign in
                                requestConfigChange(BalanceExperimentConfig(
                                    algorithmMode: session.balanceExperimentConfig.algorithmMode,
                                    signConvention: newSign,
                                    gainProfile: session.balanceExperimentConfig.gainProfile,
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot
                                ))
                            }
                        )
                    )

                    axisControl(
                        title: "Gain 프로파일",
                        icon: "dial.medium",
                        selection: Binding(
                            get: { session.balanceExperimentConfig.gainProfile },
                            set: { newGain in
                                requestConfigChange(BalanceExperimentConfig(
                                    algorithmMode: session.balanceExperimentConfig.algorithmMode,
                                    signConvention: session.balanceExperimentConfig.signConvention,
                                    gainProfile: newGain,
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot
                                ))
                            }
                        )
                    )

                    Toggle(isOn: Binding(
                        get: { session.balanceExperimentConfig.applyToRobot },
                        set: { newApply in
                            requestConfigChange(BalanceExperimentConfig(
                                algorithmMode: session.balanceExperimentConfig.algorithmMode,
                                signConvention: session.balanceExperimentConfig.signConvention,
                                gainProfile: session.balanceExperimentConfig.gainProfile,
                                applyToRobot: newApply
                            ))
                        }
                    )) {
                        HStack(spacing: DFSpace.xs2) {
                            Image(systemName: "bolt.fill")
                                .font(DFFont.label)
                                .foregroundStyle(applyColor)
                            Text("실 robot 적용")
                                .font(DFFont.sectionLabel)
                                .foregroundStyle(DFColor.textSecondary)
                            Spacer()
                            Text(session.balanceExperimentConfig.applyToRobot ? "ON (pose 실제 변경)" : "OFF (관찰만)")
                                .font(DFFont.monoLabel)
                                .foregroundStyle(applyColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(safetyDisablesApply)
                }
                .padding(.top, DFSpace.xs2)
            } label: {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: showExpert ? "chevron.down.circle.fill" : "chevron.right.circle")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                    Text("Expert — 4축 개별 조절")
                        .font(DFFont.sectionLabel)
                        .foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    if !showExpert {
                        Text(compactConfigSummary)
                            .font(DFFont.micro)
                            .foregroundStyle(DFColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.info.opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .sheet(item: Binding<RiskyApplyConfirm?>(
            get: { pendingRiskyApply.map { RiskyApplyConfirm(config: $0) } },
            set: { _ in pendingRiskyApply = nil }
        )) { item in
            riskyApplyConfirmSheet(item.config)
        }
    }

    // MARK: - v1.11.1 (MEDIUM-6) — 위험 조합 실 적용 확인 sheet

    /// Identifiable wrapper for `.sheet(item:)`.
    /// **Codex #3 권고**: id 에 4축 모두 포함 — 부분 변경 시 sheet 가 재구성되도록.
    private struct RiskyApplyConfirm: Identifiable {
        let config: BalanceExperimentConfig
        var id: String {
            "\(config.algorithmMode.rawValue)-\(config.signConvention.rawValue)-" +
            "\(config.gainProfile.rawValue)-\(config.applyToRobot)"
        }
    }

    @ViewBuilder
    private func riskyApplyConfirmSheet(_ config: BalanceExperimentConfig) -> some View {
        let isHybrid = config.algorithmMode == .hybridBA
        let isV110 = config.gainProfile == .v110Experimental
        let isAlternateSign = config.signConvention == .alternateDiagnostic
        // **v1.11.2 (Codex #1 UX 정정)**: alternateDiagnostic 은 safetyVerdict 가
        // .blocked → didSet 가 자동으로 applyToRobot=false 강등. 진행 버튼이 그대로
        // "실 적용 진행" 이면 사용자가 실 적용 가능하다고 오해. 명시 안내 + 라벨 변경.
        VStack(alignment: .leading, spacing: DFSpace.sm2) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: isAlternateSign ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(isAlternateSign ? DFColor.danger : DFColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isAlternateSign ? "실 적용 차단됨" : "실 robot 적용 확인")
                        .font(.system(size: 16, weight: .semibold))
                    Text(isAlternateSign
                         ? "실 적용 차단됨 — 관찰만 진행"
                         : "이 조합은 실 robot 미검증입니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("선택한 조합:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
                HStack(spacing: 6) {
                    Image(systemName: config.algorithmMode.icon)
                        .font(.system(size: 11))
                    Text(config.algorithmMode.label).font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus.forwardslash.minus").font(.system(size: 11))
                    Text(config.signConvention.label).font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Image(systemName: "dial.medium").font(.system(size: 11))
                    Text(config.gainProfile.label).font(.system(size: 12, design: .monospaced))
                }
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs)
            .background(DFColor.textSecondary.opacity(DFOpacity.o06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                if isAlternateSign {
                    riskBullet("fall 가속 위험 — sagittal 부호 반전")
                    riskBullet("진행 시 applyToRobot 자동 OFF (observe-only 강제)")
                    riskBullet("corrections 는 로그에 기록되어 분석 가능하지만 pose 변경 X")
                }
                if isHybrid {
                    riskBullet("Hybrid B+A 알고리즘은 시뮬에서만 검증됨 — 실 robot fall 가속 가능성")
                }
                if isV110 {
                    riskBullet("v1.10 gain (anklePitch 1.5, ankleRoll 0.5) 은 random search 결과, 실 검증 전")
                }
                if !isAlternateSign {
                    riskBullet("cradle (정비 스탠드) 거치된 상태에서만 적용 권장")
                    riskBullet("처음에는 strict supervision — 즉시 비상 정지 가능한 상태로")
                    riskBullet("문제 발생 시 OFF 또는 ROBOTIS 프리셋으로 즉시 되돌리기")
                }
            }
            .padding(.horizontal, DFSpace.sm)

            Divider()

            HStack {
                Button("취소") {
                    pendingRiskyApply = nil
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)
                Spacer()
                Button(isAlternateSign ? "관찰 전용으로 진행" : "이해함, 실 적용 진행") {
                    session.balanceExperimentConfig = config
                    pendingRiskyApply = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(isAlternateSign ? DFColor.danger : DFColor.warning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DFSpace.md)
        .frame(width: 440)
    }

    private func riskBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(DFColor.warning)
            Text(text).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Safety banner

    @ViewBuilder
    private var safetyBanner: some View {
        switch session.balanceExperimentConfig.safetyVerdict {
        case .safe:
            EmptyView()
        case .caution(let msg):
            HStack(alignment: .top, spacing: DFSpace.xs2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DFColor.warning)
                Text(msg)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.warning)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DFSpace.xs2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DFColor.warning.opacity(DFOpacity.o15))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
        case .blocked(let msg):
            HStack(alignment: .top, spacing: DFSpace.xs2) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(DFColor.danger)
                Text(msg)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DFSpace.xs2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DFColor.danger.opacity(DFOpacity.o15))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
        }
    }

    // MARK: - Profile row

    private var profileRow: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "rectangle.stack.fill")
                .font(DFFont.label)
                .foregroundStyle(DFColor.accent)
            Text("프로파일")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            Spacer()
            ForEach(profilePresets, id: \.name) { preset in
                Button {
                    // v1.11.2 P1: profile picker 도 requestConfigChange 거치게.
                    // v1.10 적용 preset (hybridBA+v110+applyToRobot=true) 시 sheet 띄움.
                    requestConfigChange(preset.config)
                } label: {
                    Text(preset.shortLabel)
                        .font(DFFont.label.monospaced())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, DFSpace.xs2)
                        .padding(.horizontal, DFSpace.xs)
                        .background(
                            preset.matches(session.balanceExperimentConfig)
                                ? DFColor.accent.opacity(DFOpacity.o20)
                                : Color.clear
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DFRadius.xs2)
                                .stroke(
                                    preset.matches(session.balanceExperimentConfig)
                                        ? DFColor.accent
                                        : DFColor.textSecondary.opacity(DFOpacity.o25),
                                    lineWidth: preset.matches(session.balanceExperimentConfig) ? 2 : 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                }
                .buttonStyle(.plain)
                .help(preset.tooltip)
            }
        }
    }

    private struct PresetEntry {
        let name: String
        let shortLabel: String
        let tooltip: String
        let config: BalanceExperimentConfig

        func matches(_ other: BalanceExperimentConfig) -> Bool {
            config == other
        }
    }

    private var profilePresets: [PresetEntry] {
        [
            PresetEntry(
                name: "off",
                shortLabel: "OFF",
                tooltip: "보정 자체 꺼짐 — pose 그대로 송출",
                config: BalanceExperimentConfig(
                    algorithmMode: .off,
                    signConvention: .robotisWalkingCpp,
                    gainProfile: .robotisOriginal,
                    applyToRobot: true
                )
            ),
            PresetEntry(
                name: "robotis",
                shortLabel: "ROBOTIS",
                tooltip: "ROBOTIS Walking.cpp 기본 P-control + LPF + deadband. 검증된 baseline.",
                config: .defaultRobotis
            ),
            PresetEntry(
                name: "v110observe",
                shortLabel: "v1.10 관찰",
                tooltip: "Hybrid B+A 알고리즘 + v1.10 gain 으로 corrections 계산 (slow EMA + phase-locked residual). pose 변경 X — 로그/UI 표시만. v1.11.1 fix 로 실제 Hybrid 경로 실행 보장됨.",
                config: .v110Observe
            ),
            PresetEntry(
                name: "v110apply",
                shortLabel: "v1.10 적용",
                tooltip: "Hybrid B+A + v1.10 gain 실 robot 적용. cradle 확인 후 사용.",
                config: .v110Apply
            ),
        ]
    }

    private var compactConfigSummary: String {
        let c = session.balanceExperimentConfig
        let alg = c.algorithmMode.rawValue
        let sign = c.signConvention == .robotisWalkingCpp ? "+" : "±"
        let gain = c.gainProfile.rawValue
        let apply = c.applyToRobot ? "→robot" : "관찰"
        return "\(alg)·\(sign)·\(gain)·\(apply)"
    }

    // MARK: - Axis control helper

    private func axisControl<Mode: CaseIterable & Hashable & RawRepresentable & Identifiable>(
        title: String,
        icon: String,
        selection: Binding<Mode>
    ) -> some View where Mode.AllCases: RandomAccessCollection, Mode.RawValue == String {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: icon)
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
                Text(title)
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Picker(title, selection: selection) {
                ForEach(Array(Mode.allCases), id: \.id) { (mode: Mode) in
                    Text(modeLabel(mode))
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func modeLabel<Mode: RawRepresentable>(_ mode: Mode) -> String where Mode.RawValue == String {
        if let m = mode as? BalanceAlgorithmMode { return m.label }
        if let m = mode as? BalanceSignConvention { return m.label }
        if let m = mode as? BalanceGainProfile { return m.label }
        return mode.rawValue
    }

    // MARK: - Helpers

    private var applyColor: Color {
        if !session.balanceExperimentConfig.applyToRobot { return DFColor.textSecondary }
        switch session.balanceExperimentConfig.safetyVerdict {
        case .safe:    return DFColor.success
        case .caution: return DFColor.warning
        case .blocked: return DFColor.danger
        }
    }

    private var safetyDisablesApply: Bool {
        if case .blocked = session.balanceExperimentConfig.safetyVerdict {
            return false  // 사용자가 OFF 로 돌릴 수 있게 토글은 살리고, ON 만 차단됨 (didSet 이 강제 OFF).
        }
        return false
    }
}
