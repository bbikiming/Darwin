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
    @Bindable var session: WalkLabSession  // $session.foo binding 사용 → @Bindable
    @State private var showExpert: Bool = false
    /// **v1.11.1 (2026-05-18 사용자 review MEDIUM-6)**: hybridBA + applyToRobot 또는
    /// v110Experimental gain + applyToRobot 토글 시 명시 확인 sheet.
    @State private var pendingRiskyApply: BalanceExperimentConfig? = nil

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

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
    ///
    /// **v1.11.3 (2026-05-18)** — `.blocked` 케이스는 confirmation sheet 도 띄우지 않고
    /// 바로 `applyToRobot=false` 로 강등. 이유: blocked = 실 데이터로 입증된 위험 조합
    /// 이므로 "사용자가 확인하면 적용" 패턴 자체가 부적절. session.didSet / startWalkCycle
    /// 진입 가드가 이중 안전망이지만 UI 단에서도 명시 거부하여 사용자 의도 오해 차단.
    private func requestConfigChange(_ newConfig: BalanceExperimentConfig) {
        harness.record(
            .walklabBalanceProfileChanged, level: .info, actor: .user,
            data: [
                "algorithm": AnyCodable(newConfig.algorithmMode.rawValue),
                "sign": AnyCodable(newConfig.signConvention.rawValue),
                "gain": AnyCodable(newConfig.gainProfile.rawValue),
                "apply_to_robot": AnyCodable(newConfig.applyToRobot),
            ]
        )
        if case .blocked = newConfig.safetyVerdict {
            // 사용자 의도 (algorithm/sign/gain/pitchInputConvention 변경) 는 보존하되
            // applyToRobot 만 강제 OFF. **v1.11.4 (2026-05-18) fix**: pitchInputConvention
            // 보존 필수 — 종전엔 누락되어 default `.imuRaw` 로 reset 되었음.
            let downgraded = BalanceExperimentConfig(
                algorithmMode: newConfig.algorithmMode,
                signConvention: newConfig.signConvention,
                gainProfile: newConfig.gainProfile,
                applyToRobot: false,
                pitchInputConvention: newConfig.pitchInputConvention
            )
            session.balanceExperimentConfig = downgraded
            return
        }
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

            // **v1.15.5 (2026-05-21) Phase 1.5 — ApplyScope badge**.
            // verification §4.2 — balanceExperimentConfig 가 Onboard 모드에서 미송신.
            // observeOnly algorithm 은 pose 변경 X → .previewOnly 자동 선택.
            // engine 별 + algorithm 별 정확한 scope 표시.
            WalkLabApplyScopeBadge(
                scope: WalkLabApplyScopeResolver.scopeForBalanceConfig(
                    engine: session.walkingEngine,
                    algorithmMode: session.balanceExperimentConfig.algorithmMode
                ),
                style: .full
            )

            // **v1.11.8 (2026-05-18) — HIGH-1 fix**: .robotisOnboard 모드에선 Mac
            // corrector path 자체가 우회되므로 5축 토글 (algorithm/sign/gain/pitchInput
            // + applyToRobot) 변경이 무효. 사용자 혼동 차단 — 안내 배너 + 토글 disabled.
            if session.walkingEngine == .robotisOnboard {
                onboardModeNotice
            }

            // 3) Expert disclosure — 4축 개별 세그먼티드 컨트롤.
            DisclosureGroup(isExpanded: $showExpert) {
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    axisControl(
                        title: "알고리즘",
                        icon: "function",
                        selection: Binding(
                            get: { session.balanceExperimentConfig.algorithmMode },
                            set: { newMode in
                                // **v1.11.4 fix**: pitchInputConvention 보존 (종전 누락).
                                requestConfigChange(BalanceExperimentConfig(
                                    algorithmMode: newMode,
                                    signConvention: session.balanceExperimentConfig.signConvention,
                                    gainProfile: session.balanceExperimentConfig.gainProfile,
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot,
                                    pitchInputConvention: session.balanceExperimentConfig.pitchInputConvention
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
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot,
                                    pitchInputConvention: session.balanceExperimentConfig.pitchInputConvention
                                ))
                            }
                        )
                    )

                    // **v1.11.4 (2026-05-18) — 신규 axis**: Pitch 부호 정규화 (P1.1 인프라).
                    // 실 robot 에서 앞기울 = imuPitch 음수 인 케이스 (2026-05-18 데이터로 입증)
                    // 에서 사용자가 `.negateForwardIsNegative` 로 정규화 가능.
                    axisControl(
                        title: "Pitch 입력",
                        icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                        selection: Binding(
                            get: { session.balanceExperimentConfig.pitchInputConvention },
                            set: { newConv in
                                requestConfigChange(BalanceExperimentConfig(
                                    algorithmMode: session.balanceExperimentConfig.algorithmMode,
                                    signConvention: session.balanceExperimentConfig.signConvention,
                                    gainProfile: session.balanceExperimentConfig.gainProfile,
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot,
                                    pitchInputConvention: newConv
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
                                    applyToRobot: session.balanceExperimentConfig.applyToRobot,
                                    pitchInputConvention: session.balanceExperimentConfig.pitchInputConvention
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
                                applyToRobot: newApply,
                                pitchInputConvention: session.balanceExperimentConfig.pitchInputConvention
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

                    // **v1.11.6 (2026-05-18)** — .custom gainProfile 선택 시만 노출.
                    // 4개 gain slider — 사용자가 직접 hipRoll/knee/anklePitch/ankleRoll 조절.
                    // 종전 .custom 은 robotisOriginal fallback 뿐 — UI 라벨과 실 동작 불일치.
                    if session.balanceExperimentConfig.gainProfile == .custom {
                        customGainSliders
                    }
                }
                .padding(.top, DFSpace.xs2)
                // **v1.11.8 HIGH-1**: .robotisOnboard 시 5축 무효 → disabled.
                .disabled(fiveAxisDisabledForOnboard)
                .opacity(fiveAxisDisabledForOnboard ? 0.5 : 1.0)
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
                    harness.record(
                        .walklabBalanceRiskyCancelled, level: .info, actor: .user,
                        data: [
                            "algorithm": AnyCodable(config.algorithmMode.rawValue),
                            "sign": AnyCodable(config.signConvention.rawValue),
                            "gain": AnyCodable(config.gainProfile.rawValue),
                        ]
                    )
                    pendingRiskyApply = nil
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)
                Spacer()
                Button(isAlternateSign ? "관찰 전용으로 진행" : "이해함, 실 적용 진행") {
                    harness.record(
                        .walklabBalanceRiskyConfirmed, level: .warn, actor: .user,
                        data: [
                            "algorithm": AnyCodable(config.algorithmMode.rawValue),
                            "sign": AnyCodable(config.signConvention.rawValue),
                            "gain": AnyCodable(config.gainProfile.rawValue),
                            "apply_to_robot": AnyCodable(config.applyToRobot),
                        ]
                    )
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

    // MARK: - Onboard mode notice (v1.11.8)

    /// **v1.11.8 (2026-05-18) — HIGH-1 fix**: .robotisOnboard 모드에선 Mac corrector
    /// path 가 우회되므로 5축 토글이 무효임을 명시. expert disclosure 내 토글들도
    /// 자동 disabled 처리.
    ///
    /// **V280-E (2026-05-24)**: hardcoded HStack/background → DFBanner (.info).
    @ViewBuilder
    private var onboardModeNotice: some View {
        DFBanner(
            title: "ROBOTIS Onboard 모드 — Mac corrector 우회",
            message: "아래 5축 토글은 robot-side Walking 엔진에 영향 없음 (record 만).",
            severity: .info
        )
    }

    /// **v1.11.8**: .robotisOnboard 시 5축 토글 disabled 헬퍼.
    private var fiveAxisDisabledForOnboard: Bool {
        session.walkingEngine == .robotisOnboard
    }

    // MARK: - Safety banner

    /// **V280-E (2026-05-24)**: hardcoded HStack/background → DFBanner (.warning/.error).
    @ViewBuilder
    private var safetyBanner: some View {
        switch session.balanceExperimentConfig.safetyVerdict {
        case .safe:
            EmptyView()
        case .caution(let msg):
            DFBanner(title: msg, severity: .warning)
        case .blocked(let msg):
            DFBanner(title: msg, severity: .error)
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

    /// **v1.11.6 (2026-05-18)** — .custom gainProfile 의 4 gain slider.
    @ViewBuilder
    private var customGainSliders: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "slider.horizontal.3")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.warning)
                Text(".custom gain (4축 사용자 지정)")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            customGainSlider("hipRoll", value: $session.customHipRollGain, range: 0...2)
            customGainSlider("knee", value: $session.customKneeGain, range: 0...2)
            customGainSlider("anklePitch", value: $session.customAnklePitchGain, range: 0...2)
            customGainSlider("ankleRoll", value: $session.customAnkleRollGain, range: 0...2)
        }
        .padding(.top, DFSpace.xs2)
    }

    @ViewBuilder
    private func customGainSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Text(label)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(DFFont.monoLabel)
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

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
                // V279-2 (P1 discoverability fix): 각 axis 옆 info icon — 옵션이
                // 무엇이고 언제 쓰는지 hover 안내. segmented picker 는 segment 별
                // help 불가 → 전체 옵션 안내를 axis 라벨 옆 info 에 통합.
                if let axisHelp = axisHelpText(for: Mode.self) {
                    Image(systemName: "info.circle")
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.info.opacity(DFOpacity.subtle))
                        .help(axisHelp)
                        .accessibilityLabel("\(title) 옵션 설명")
                        .accessibilityHint(axisHelp)
                }
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
        if let m = mode as? BalancePitchInputConvention { return m.label }
        return mode.rawValue
    }

    /// V279-2 (P1 discoverability fix): axis 별 옵션 안내 — 각 enum 옵션의 의미와
    /// 언제 쓰는지 1줄 안내. segmented picker 는 옵션 별 help 가 불가 → axis 라벨
    /// 옆 info icon 에서 모든 옵션을 한 번에 안내.
    ///
    /// **주의**: `alternateDiagnostic` 은 fall 가속 위험 — observe-only 권장.
    /// (BalanceExperimentConfig.swift 의 enum 주석과 일치.)
    private func axisHelpText<Mode>(for type: Mode.Type) -> String? {
        if type == BalanceAlgorithmMode.self {
            return "보정 알고리즘 — ROBOTIS 공식 / Hybrid 등 선택. " +
                   "Hybrid 는 시뮬 검증만 — 실 robot 적용 시 주의."
        }
        if type == BalanceSignConvention.self {
            return "부호 규약 — corrections 의 sagittal 부호 적용 방식.\n" +
                   "• ROBOTIS 기준: 공식 walking_engine 부호 (기본 권장)\n" +
                   "• 반대 부호 실험: 부호 반전 진단 실험. 실 robot 적용 시 fall " +
                   "가속 위험 — observe-only 모드 권장."
        }
        if type == BalancePitchInputConvention.self {
            return "Pitch 입력 정규화 — IMU pitch 부호 처리 방식.\n" +
                   "• 원본: IMU 값 그대로 사용 (양수=앞기울 가정, 기본)\n" +
                   "• 정규화: IMU 값 반전 (실 robot 에서 음수=앞기울 캘리브 후 사용)"
        }
        if type == BalanceGainProfile.self {
            return "Gain 프로파일 — 4 관절 (hipRoll/knee/anklePitch/ankleRoll) 게인.\n" +
                   "• ROBOTIS 원본: 공식 검증 게인 (기본 권장)\n" +
                   "• v1.10 실험: random search 결과 — 실 검증 전\n" +
                   "• 사용자 지정: 4 게인 직접 슬라이더 조절 (expert)"
        }
        return nil
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
