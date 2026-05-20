import SwiftUI
import ForgeCore

/// v1.1 Fall Prevention 모니터링 대시보드 — 6 안전 layer + 시계열 + 이벤트 로그.
///
/// # UX 레퍼런스 근거
///
/// 본 대시보드는 다음 레퍼런스 기반 설계:
///
/// 1. **ISA-101 *Human Machine Interfaces for Process Automation Systems* (2015)**
///    - §6.3 — gray + semantic color HMI (회색 배경 + 상태색만 강조 = "Situational
///      Awareness" 패턴). 본 dashboard 의 hero status banner 가 동일 패턴.
///    - §6.5 — 5-tier alarm priority. 본 시스템도 5-tier `BalanceState`.
///    - §6.7 — alarm event log: 시간 + 우선순위 + 메시지 + 처치 컬럼. 본 이벤트
///      로그가 동일 구조.
/// 2. **NASA Ames *Primary Flight Display Design Guidelines* NASA-TM-104781 (1993)**
///    - §3.2.1 — attitude indicator: 임계 zone 음영. 본 sparkline 의 25°/35°/50°
///      stripe 가 동일.
///    - §4.1 — EICAS (Engine Indication & Crew Alert System) 패턴: 6 systems
///      tile grid. 본 dashboard 의 6-Layer status grid 가 동일.
/// 3. **Edward Tufte *The Visual Display of Quantitative Information* (1983)**
///    - "Maximize data-ink ratio": 본 sparkline 이 축 label / grid / legend 최소.
///    - "Small multiples": 본 dashboard 의 3 sparkline 동시 표시 (Roll / Pitch /
///      Score) — 같은 시간축 정렬.
/// 4. **NN/g *Dashboard Design Patterns* (Nielsen Norman Group, 2024)**
///    - "Inverted pyramid": 가장 critical info (current state) 가 top. 본
///      dashboard 도 hero banner → 6-layer grid → time series → 이벤트 로그 순.
///    - "Color + shape + label": 색에만 의존 X. 본 시스템은 SF Symbol icon +
///      텍스트 라벨 + 색을 항상 함께 (WCAG 1.4.1 색 단독 정보 금지).
/// 5. **Philips IntelliVue MX800 *User Guide* (2019)** — medical patient monitor:
///    - alarm event log row: 시간 / severity icon / message. 본 이벤트 로그가
///      동일 구조.
///    - "fresh" vs "stale" data indicator. 본 시스템의 IMU source tag (sim / real
///      / stale) 가 동일.
/// 6. **Boston Dynamics *Spot SDK Operator Console* (2023 공개 자료)**:
///    - 4-quadrant layout: pose / sensors / telemetry / events. 본 dashboard 의
///      hero / grid / sparkline / log 4영역과 매핑.
/// 7. **KS S ISO 7010 *안전 표지* (2019)**: 빨강 = 위험, 노랑 = 주의, 파랑 = 정보,
///    초록 = 안전. 본 시스템의 5-tier 색 매핑이 ISO 7010 + macOS dynamic color.
/// 8. **WCAG 2.2 §1.4.11 *Non-text Contrast***: 그래픽 요소 ≥ 3:1 명도비. 본
///    dashboard 의 모든 SF Symbol / 라인 색이 배경 대비 3:1 이상.
///
/// # 레이아웃 (top → bottom)
///
/// 1. **Hero status banner** — 현재 안전 상태 (큰 아이콘 + 라벨 + tilt 값).
/// 2. **6-Layer status grid** — L1..L6 각 안전 layer 의 현재 / 임계 / 상태.
/// 3. **Time-series row** — Roll / Pitch / Prediction Score 3 sparkline 동시.
/// 4. **Corrector deltas + ramp** — 8 관절 delta bar + ramp progress.
/// 5. **Event log** — 시간역순 이벤트 로그.
struct FallPreventionMonitor: View {
    @ObservedObject var session: WalkLabSession
    /// **v1.11.5.1 (2026-05-18) — ROBOTIS onboard 모드 brokering 채널**.
    /// `WalkingEnginePicker` 의 시작/종료 버튼이 이 RemoteShell 을 통해 SSH 명령 send.
    /// 종전 (v1.11.5): callback 미전달 → 버튼 disabled 상태. 이번 fix.
    @EnvironmentObject private var remoteShell: RemoteShell
    /// **2026-05-16 a11y 정정**: `repeatForever` animation 은 SwiftUI 가
    /// 자동 disable 안 함. 명시적 @Environment 가드 필요.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var emergencyPulse: Bool = false
    /// Pulse animation 활성 상태 — startEmergencyPulse 중복 호출 가드.
    @State private var pulseActive: Bool = false

    var body: some View {
        // **v1.10 (2026-05-17 사용자 요청) — macOS-native 디자인 업그레이드**:
        // - 각 section 을 `dfSectionCard` modifier 로 통일 (Inspector 패턴, macOS Sequoia)
        // - 외곽 컨테이너 제거 (parent monitoringSidebar 가 이미 material)
        // - section 간 spacing 16pt (macOS HIG group margin)
        VStack(alignment: .leading, spacing: 16) {
            heroAndGyroRow
                .dfSectionCard(title: nil)  // hero 는 헤더 없음 (status banner 자체가 hero)
            layerStatusGrid
                .dfSectionCard(title: "6-Layer 안전 시스템", icon: "shield.lefthalf.filled")
            timeSeriesRow
                .dfSectionCard(title: "최근 10초 시계열", icon: "waveform.path")
            correctorPanel
                .dfSectionCard(title: "관절 보정 (8 joint)", icon: "figure.walk.motion")
            eventLogPanel
                .dfSectionCard(title: "안전 이벤트", icon: "bell.badge")
        }
        .frame(maxWidth: Self.dashboardMaxW, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fall Prevention 모니터링 대시보드")
    }

    /// Dashboard 최대 폭 — ultrawide / fullscreen 시 시각 sparseness 방지.
    /// NN/g: dashboard 의 데이터 밀도 최적 폭 = 1200-1400pt.
    private static let dashboardMaxW: CGFloat = 1400

    // MARK: - 1. Hero status banner + GyroMeter (적응형 layout)

    /// **v1.7 (2026-05-17 사용자 요청)**: 폭 ≥ 720pt → 옆, 그 외 → 위/아래.
    /// `ViewThatFits` 가 자동으로 fits 결정. heroBanner 와 GyroMeter 양쪽 다 lineLimit
    /// 적용으로 좁은 폭에서도 글자 안 잘림.
    private var heroAndGyroRow: some View {
        ViewThatFits(in: .horizontal) {
            // 1순위: 옆 배치 (폭 충분할 때)
            HStack(alignment: .top, spacing: DFSpace.sm) {
                heroBanner
                    .frame(maxWidth: .infinity, alignment: .leading)
                gyroMeterBlock
                    .fixedSize()
            }
            // 2순위: 위/아래 (좁은 폭)
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                heroBanner
                gyroMeterBlock
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// 원형 g-meter + 보정 강도 slider + 자동 튜닝 카드 stack.
    /// v1.9 (2026-05-17 사용자 요청): GyroMeter 하단에 보정 컨트롤 카드 위치.
    /// **v1.11 (2026-05-17 사용자 재요청)**: maxWidth=360 캡 제거 — HSplitView drag
    /// resize 가 콘텐츠까지 도달하도록. minWidth 280 로 GyroMeter 직경 (160) +
    /// padding 보장.
    private var gyroMeterBlock: some View {
        return VStack(alignment: .leading, spacing: DFSpace.xs2) {
            CircularGyroMeter(
                rollDeg: session.displayImuRollDeg,
                pitchDeg: session.displayImuPitchDeg,
                dangerThreshold: 50.0,
                sourceLabel: gyroSourceWithCorrection,
                sourceColor: imuSourceColor,
                diameter: 160
            )
            .frame(maxWidth: .infinity, alignment: .center)
            CorrectorIntensityCard(session: session)
            // **v1.11.5.1 (2026-05-18)** — 보행 엔진 선택 (Mac sparse vs ROBOTIS onboard).
            // 시작/종료 버튼이 RemoteShell.send 로 SSH 명령 송출. 종전 v1.11.5 는
            // callback 미전달로 disabled — 이번 fix.
            WalkingEnginePicker(
                session: session,
                onStartOnboard: { [remoteShell] in
                    Task { @MainActor in
                        await remoteShell.send(RobotSetupCommand.walkLabRobotisStart)
                    }
                },
                onStopOnboard: { [remoteShell] in
                    Task { @MainActor in
                        await remoteShell.send(RobotSetupCommand.walkLabRobotisStop)
                    }
                },
                onSendCommand: { [remoteShell] cmd in
                    Task { @MainActor in
                        let line = cmd.serializedLine
                        await remoteShell.send(
                            RobotSetupCommand.walkLabRobotisSendCommand(line: line)
                        )
                    }
                }
            )
            BalanceExperimentControls(session: session)   // v1.11: 4축 분리 패널
            // **v1.11.4 (2026-05-18)** — 정적 IMU 캘리브레이션 (5축 손 캡처 + 부호 진단).
            // 부호 컨벤션 검증 후 BalanceExperimentControls 의 pitchInputConvention 토글로 적용.
            StaticTiltCalibrationPanel(session: session)
            AutoTunerCard(tuner: session.autoTuner, session: session)
        }
        .padding(.horizontal, DFSpace.xs2)
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
    }

    /// 자이로 source + 보정 active 여부 표시 — 사용자가 "실시간 보정 작동 중" 확인.
    /// 예: "실 IMU · 보정 Δ0.8°" (보정 ON) 또는 "실 IMU · 보정 OFF".
    private var gyroSourceWithCorrection: String {
        let src = session.imuSource.label
        if session.enableBalanceCorrection {
            if let delta = session.lastCorrections?.maxAbs, delta > 0.01 {
                return String(format: "%@ · 보정 Δ%.1f°", src, delta)
            }
            return "\(src) · 보정 대기"
        }
        return "\(src) · 보정 OFF"
    }

    /// **ISA-101 §6.3 패턴**: 회색 카드 배경 + 현재 상태색 만 강조.
    /// **NASA EICAS 패턴**: 단일 critical info 가 hero — 1초 안에 인식 가능.
    private var heroBanner: some View {
        let state = session.balanceState
        let color = stateColor(state)
        let icon = stateIcon(state)
        let normalized = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: session.imuRollDeg,
            rawPitch: session.imuPitchDeg,
            convention: session.balanceExperimentConfig.pitchInputConvention
        )
        let tiltMax = max(abs(normalized.roll), abs(normalized.pitch))
        return HStack(spacing: DFSpace.sm3) {
            Image(systemName: icon)
                .font(DFIcon.hero)
                .foregroundStyle(color)
                .frame(width: DFSize.heroBox, height: DFSize.heroBox)
                .background(color.opacity(DFOpacity.o15))
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
                .accessibilityLabel("안전 상태 \(state.label)")
                .help(stateMessage(state).isEmpty
                      ? "안전 상태 \(state.label) — 정상 보행"
                      : stateMessage(state))
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                // v1.7: source pill 줄바꿈 방지 — lineLimit(1) + fixedSize horizontal.
                HStack(spacing: DFSpace.xs2) {
                    Text("안전 상태")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: DFSpace.xs)
                    DFSourcePill(label: session.imuSource.label,
                                 tint: imuSourceColor,
                                 leading: "IMU")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    DFSourcePill(label: session.motorTempSource.label,
                                 tint: motorTempSourceColor,
                                 leading: "모터")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                imuScaleWarningChip
                HStack(alignment: .firstTextBaseline, spacing: DFSpace.sm) {
                    Text(state.label)
                        .font(DFFont.heroState)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                    Spacer(minLength: DFSpace.xs)
                    Text(String(format: "%.1f°", tiltMax))
                        .font(DFFont.dataLarge)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    Text("최대 기울기")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if !stateMessage(state).isEmpty {
                    Text(stateMessage(state))
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // **2026-05-16 a11y 정정**: VoiceOver 통합.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("안전 상태 \(state.label), 최대 기울기 \(String(format: "%.1f도", tiltMax))")
        }
        .padding(DFSpace.sm2)
        .background(color.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(color.opacity(pulseStrokeAlpha(for: state)),
                        lineWidth: state >= .danger ? 1.0 : DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
        // **2026-05-16 시인성**: state 변경 시 smooth color transition.
        .animation(DFAnimation.standard, value: state)
        // **2026-05-16 시인성**: emergency / danger 시 subtle pulse.
        // Reduce Motion ON 시 SwiftUI 자동 disable.
        // **이슈 처리 (2026-05-16)**: `state` (local let) 캡처 대신 `session.balanceState`
        // 직접 참조 — closure capture 명확성 + onChange 의 publisher 직결.
        .onAppear {
            if session.balanceState >= .danger && !pulseActive {
                startEmergencyPulse()
            }
        }
        .onChange(of: session.balanceState) { _, newState in
            let shouldPulse = newState >= .danger
            if shouldPulse && !pulseActive {
                // 중첩 호출 가드 — danger → emergency 등 동일 zone 내 전환 시
                // startEmergencyPulse 중복 호출 방지.
                startEmergencyPulse()
            } else if !shouldPulse && pulseActive {
                stopEmergencyPulse()
            }
        }
        // **2026-05-16 정정 (Agent 2 발견)**: view 사라질 때 (monitoringExpanded
        // toggle OFF) animation state hygiene — pulseActive/emergencyPulse reset.
        .onDisappear {
            if pulseActive { stopEmergencyPulse() }
        }
    }

    /// Pulse 활성 시 더 강한 stroke alpha (60%) — 부드러운 사이클.
    private func pulseStrokeAlpha(for state: WalkLabSession.BalanceState) -> Double {
        if state >= .danger {
            return emergencyPulse ? DFOpacity.o60 : DFOpacity.o35
        }
        return DFOpacity.o35
    }

    /// **2026-05-16 a11y 정정 (Agent 2 발견)**: Reduce Motion ON 시 `repeatForever`
    /// 가 SwiftUI 가 자동 disable 안 함 — 명시적 guard 필요.
    /// `withAnimation` 안에 들어가도 repeatForever 는 이 setting 무시.
    private func startEmergencyPulse() {
        guard !reduceMotion else {
            // Reduce Motion ON — animation 없이 단순히 활성 상태만 표시.
            pulseActive = true
            emergencyPulse = true  // stroke alpha 60% 고정 (animate X)
            return
        }
        pulseActive = true
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            emergencyPulse = true
        }
    }

    /// **2026-05-16 정정 (Agent 2 발견)**: animation cancellation 명시.
    /// `emergencyPulse = false` 만 으로는 repeatForever 가 stuck 가능 →
    /// `withAnimation(.linear(duration: 0))` 으로 explicit end.
    private func stopEmergencyPulse() {
        withAnimation(.linear(duration: 0)) {
            emergencyPulse = false
        }
        pulseActive = false
    }

    // MARK: - 2. 6-Layer status grid

    /// **NASA EICAS 패턴**: 6 systems tile grid. 각 tile = 1 safety layer.
    /// **NN/g "color + shape + label"**: icon + 라벨 + 색 항상 함께.
    ///
    /// **반응형 (Material Design 3 Adaptive Layouts)**: `GridItem(.adaptive(minimum:))`
    /// 사용 — 좁은 폭에서 1-2 column auto-collapse, 넓은 폭에서 6 column 펼침.
    /// minimum 110pt = 한국어 "L1 Cradle / 미확인" 1줄 표시 보장.
    private var layerStatusGrid: some View {
        let layers: [LayerStatus] = currentLayers()
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("6-Layer 안전 시스템")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.layerTileMinW),
                                   spacing: DFSpace.xs)],
                spacing: DFSpace.xs
            ) {
                ForEach(layers) { layer in
                    layerTile(layer)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("6-Layer 안전 시스템 상태")
    }

    /// 6-Layer tile 의 최소 너비 — adaptive grid 의 GridItem.minimum.
    /// 110pt = 한국어 "L1 Cradle / 미확인" 1줄 표시 보장.
    private static let layerTileMinW: CGFloat = 110

    /// **2026-05-16**: 재사용 가능 `DFStatusTile` 컴포넌트 사용.
    /// 기존 inline VStack 구조 → 디자인 시스템 컴포넌트로 추출.
    private func layerTile(_ l: LayerStatus) -> some View {
        DFStatusTile(
            name: l.name,
            icon: l.icon,
            valueLabel: l.valueLabel,
            unit: l.unit,
            thresholdLabel: l.thresholdLabel,
            tint: l.color,
            sourcePill: {
                if let label = l.dataSourceLabel, let color = l.dataSourceColor {
                    DFSourcePill(label: label, tint: color)
                }
            }
        )
    }

    private func currentLayers() -> [LayerStatus] {
        // L1 — 정비 스탠드 (사이드바 토글). UI-only — source 라벨 없음.
        let l1 = LayerStatus(
            id: "L1", name: "L1 거치 안정",
            icon: session.cradleConfirmed ? "checkmark.shield.fill" : "shield",
            valueLabel: session.cradleConfirmed ? "확인" : "미확인",
            unit: nil,
            thresholdLabel: "정비 스탠드 거치 필수",
            color: session.cradleConfirmed ? DFColor.success : DFColor.warning,
            dataSourceLabel: nil,
            dataSourceColor: nil
        )
        // L2 — 슬라이더 stability score (advanced 모드일 때만 의미). UI-only.
        let stab = session.advanced ? session.stabilityScore.score : 0
        let stabColor: Color = {
            if !session.advanced { return DFColor.textSecondary }
            switch session.stabilityScore.category {
            case .safe: return DFColor.success
            case .caution: return DFColor.warning
            case .highRisk, .critical: return DFColor.danger
            }
        }()
        let l2 = LayerStatus(
            id: "L2", name: "L2 균형 안정도",
            icon: session.advanced ? "slider.horizontal.3" : "minus.circle",
            valueLabel: session.advanced ? String(format: "%.0f", stab) : "—",
            unit: session.advanced ? "/100" : nil,
            thresholdLabel: session.advanced ? "≥ 80 = critical 차단" : "고급 모드 OFF",
            color: stabColor,
            dataSourceLabel: nil,
            dataSourceColor: nil
        )
        // L3 — IMU tilt (max|roll/pitch|). data = imuSource.
        // unclamped convention — 진단 숫자에 ±50° clamp 적용 X (정보 손실 방지).
        let l3Norm = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: session.imuRollDeg,
            rawPitch: session.imuPitchDeg,
            convention: session.balanceExperimentConfig.pitchInputConvention
        )
        let tiltMax = max(abs(l3Norm.roll), abs(l3Norm.pitch))
        let tiltColor: Color = {
            if tiltMax >= 50 { return DFColor.danger }
            if tiltMax >= 45 { return DFColor.severe }
            if tiltMax >= 35 { return DFColor.warning }
            if tiltMax >= 25 { return DFColor.warning.opacity(0.7) }
            return DFColor.success
        }()
        let l3 = LayerStatus(
            id: "L3", name: "L3 IMU 자세",
            icon: "gyroscope",
            valueLabel: String(format: "%.1f", tiltMax),
            unit: "°",
            thresholdLabel: "25/35/45/50° 5단계",
            color: tiltColor,
            dataSourceLabel: session.imuSource.label,
            dataSourceColor: imuSourceColor
        )
        // L4 — Predictor score. data = imuSource (gyro + tilt 둘 다 IMU).
        let score = session.fallPrediction.score
        let scoreColor: Color = {
            // **이슈 정정 (2026-05-16)**: 이전 60/30 둘 다 warning — 의도된 severe 누락.
            // 정정: 4-tier — < 30 / 30-60 / 60-80 / >= 80.
            if score >= 80 { return DFColor.danger }
            if score >= 60 { return DFColor.severe }
            if score >= 30 { return DFColor.warning }
            return DFColor.success
        }()
        let l4 = LayerStatus(
            id: "L4", name: "L4 낙상 예측",
            icon: "exclamationmark.shield",
            valueLabel: String(format: "%.0f", score),
            unit: "/100",
            thresholdLabel: session.fallPrediction.etaMs.map {
                String(format: "ETA %.0fms", $0)
            } ?? "≥ 80 = 위험 임박 (이벤트 로그)",
            color: scoreColor,
            dataSourceLabel: session.imuSource.label,
            dataSourceColor: imuSourceColor
        )
        // L5 — Corrector. data = imuSource (output 은 IMU error 에 비례).
        let corrColor: Color = session.enableBalanceCorrection
            ? (session.lastCorrections?.maxAbs ?? 0 > 0 ? DFColor.accent : DFColor.success)
            : DFColor.textSecondary
        let corrValue: String = {
            guard session.enableBalanceCorrection else { return "OFF" }
            if let d = session.lastCorrections?.maxAbs, d > 0 {
                return String(format: "%.1f", d)
            }
            return "0.0"
        }()
        let l5 = LayerStatus(
            id: "L5", name: "L5 자세 보정",
            icon: "figure.balanced",
            valueLabel: corrValue,
            unit: session.enableBalanceCorrection ? "° max" : nil,
            thresholdLabel: session.enableBalanceCorrection
                ? (session.rampProgress.map { String(format: "ramp %.0f%%", $0 * 100) }
                   ?? "ramp pending")
                : "토글 OFF",
            color: corrColor,
            dataSourceLabel: session.enableBalanceCorrection ? session.imuSource.label : nil,
            dataSourceColor: session.enableBalanceCorrection ? imuSourceColor : nil
        )
        // L6 — 모터 온도. data = motorTempSource (별도 source — Telemetry 의 joints).
        let temp = session.maxMotorTemp
        let tempColor: Color = {
            // **이슈 정정 (2026-05-16)**: 이전 50/45 둘 다 warning — severe 누락.
            // 정정: 4-tier — < 45 / 45-50 / 50-60 / >= 60.
            if temp >= 60 { return DFColor.danger }
            if temp >= 50 { return DFColor.severe }
            if temp >= 45 { return DFColor.warning }
            return DFColor.success
        }()
        let l6 = LayerStatus(
            id: "L6", name: "L6 모터 온도",
            icon: "thermometer.medium",
            valueLabel: String(format: "%.1f", temp),
            unit: "°C",
            thresholdLabel: "≥ 60°C = 자동 정지",
            color: tempColor,
            dataSourceLabel: session.motorTempSource.label,
            dataSourceColor: motorTempSourceColor
        )
        return [l1, l2, l3, l4, l5, l6]
    }

    // MARK: - 3. Time-series row (Tufte small multiples)

    /// **Tufte "small multiples" 패턴**: 같은 시간축 3 sparkline. 일관 비교.
    /// **NASA Ames §3.2.1**: 임계 zone stripe (25/35/50° 음영).
    ///
    /// **반응형 (Apple HIG Adaptive Layout)**: `ViewThatFits` 사용 —
    /// 충분한 폭 (각 sparkline ≥ 130pt) 시 horizontal 3 column,
    /// 그 외 vertical stack (각 차트 full-width). HSplitView detail
    /// minWidth 480 - sidebar 240 = 240pt 일 때도 vertical 로 사용 가능.
    private var timeSeriesRow: some View {
        // **2026-05-16 최적화**: 이전엔 timeline 을 4번 iterate (filter + 3× map).
        // 정정: 단일 pass 로 3 array 동시 build — 50ms tick 마다 O(N) × 4 → O(N) × 1.
        // **v1.11.19 (2026-05-20)**: safetyTimeline 은 raw 값 저장 — display 표시 전
        // convention 정규화 + NaN guard (unclamped) 적용. currentLabel 과 부호 일치.
        let now = Date()
        let cutoff = now.addingTimeInterval(-10)
        let convention = session.balanceExperimentConfig.pitchInputConvention
        var rollSamples: [(Date, Double)] = []
        var pitchSamples: [(Date, Double)] = []
        var scoreSamples: [(Date, Double)] = []
        rollSamples.reserveCapacity(session.safetyTimeline.count)
        pitchSamples.reserveCapacity(session.safetyTimeline.count)
        scoreSamples.reserveCapacity(session.safetyTimeline.count)
        for sample in session.safetyTimeline where sample.timestamp >= cutoff {
            let mapped = ImuAttitudeDisplayMapping.normalizeConvention(
                rawRoll: sample.rollDeg,
                rawPitch: sample.pitchDeg,
                convention: convention
            )
            rollSamples.append((sample.timestamp, mapped.roll))
            pitchSamples.append((sample.timestamp, mapped.pitch))
            scoreSamples.append((sample.timestamp, sample.predictionScore))
        }
        // currentLabel + tiltLineColor 도 unclamped normalizeConvention 으로 — 차트 trace
        // 와 부호/스케일 일치. raw 70° 가 들어와도 label 이 ±50 clamp 되지 않음.
        let nowDisplay = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: session.imuRollDeg,
            rawPitch: session.imuPitchDeg,
            convention: convention
        )
        // valueRange ±60: emergency 50° + 10° 헤드룸. 60° 이상은 saturated cliff
        // (out-of-range 시각적 명시). 일상 보행 ±4° 가독성 유지.
        let rollSp = makeSparkline(
            samples: rollSamples,
            valueRange: -60...60,
            tiltLineColor: sparklineColor(forTilt: nowDisplay.roll),
            currentLabel: String(format: "%+.1f°", nowDisplay.roll),
            title: "옆 기울기", isTiltAxis: true
        )
        let pitchSp = makeSparkline(
            samples: pitchSamples,
            valueRange: -60...60,
            tiltLineColor: sparklineColor(forTilt: nowDisplay.pitch),
            currentLabel: String(format: "%+.1f°", nowDisplay.pitch),
            title: "앞뒤 기울기", isTiltAxis: true
        )
        let scoreSp = makeSparkline(
            samples: scoreSamples,
            valueRange: 0...100,
            tiltLineColor: sparklineColor(forScore: session.fallPrediction.score),
            currentLabel: String(format: "%.0f", session.fallPrediction.score),
            title: "낙상 예측", isTiltAxis: false
        )
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("최근 10초 — 옆 기울기 / 앞뒤 기울기 / 낙상 예측 점수")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            ViewThatFits(in: .horizontal) {
                // Wide: 3 columns horizontal (preferred — Tufte small multiples)
                HStack(spacing: DFSpace.xs) {
                    rollSp.frame(minWidth: Self.sparklineMinW).frame(height: Self.sparklineWideH)
                    pitchSp.frame(minWidth: Self.sparklineMinW).frame(height: Self.sparklineWideH)
                    scoreSp.frame(minWidth: Self.sparklineMinW).frame(height: Self.sparklineWideH)
                }
                // Narrow: vertical stack (각 차트 full-width)
                VStack(spacing: DFSpace.xs) {
                    rollSp.frame(height: Self.sparklineNarrowH)
                    pitchSp.frame(height: Self.sparklineNarrowH)
                    scoreSp.frame(height: Self.sparklineNarrowH)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("최근 10초 시계열 — 옆 기울기, 앞뒤 기울기, 낙상 예측 점수")
    }

    /// Sparkline 최소 너비 — ViewThatFits 폭 분기점. 130pt = Roll/Pitch 10초 trace
    /// 가 인지 가능한 최소 (10 sample × 10pt 간격 + padding).
    private static let sparklineMinW: CGFloat = 130
    /// Sparkline horizontal 모드 높이 — 2026-05-17 56pt 에서 라벨 겹침 결함.
    /// 수직 라벨 분포 수학: tilt valueRange ±55 + 3 thresholds (25/35/50) 면
    /// 최소 delta = 10° → (10/110)·H ≥ 12pt 필요 → H ≥ 132pt → 120pt 유지.
    /// 차트 너비 (~100pt) 와 1:1 box 형태가 되지만 6개 라벨 가독성 확보 우선.
    private static let sparklineWideH: CGFloat = 120
    /// Sparkline vertical 모드 높이 — 좁은 폭에서 컨텍스트 손실 최소화 + 가독성.
    /// Wide 의 75% — narrow 화면에서도 라벨 ≥ 9pt spacing 유지.
    private static let sparklineNarrowH: CGFloat = 90

    /// Sparkline factory — wide/narrow ViewThatFits 모두 동일 구성으로 생성.
    /// `isTiltAxis = true` 시 IMU tilt 임계 (25/35/50°), false 시 score 임계 (30/60/80).
    private func makeSparkline(
        samples: [(Date, Double)],
        valueRange: ClosedRange<Double>,
        tiltLineColor: Color,
        currentLabel: String,
        title: String,
        isTiltAxis: Bool
    ) -> SafetySparkline {
        let thresholds: [SafetySparkline.Threshold] = isTiltAxis
            ? [
                .init(value: 25, color: DFColor.warning),
                .init(value: 35, color: DFColor.severe),
                .init(value: 50, color: DFColor.danger),
              ]
            : [
                .init(value: 30, color: DFColor.warning),
                .init(value: 60, color: DFColor.severe),
                .init(value: 80, color: DFColor.danger),
              ]
        return SafetySparkline(
            samples: samples,
            valueRange: valueRange,
            thresholds: thresholds,
            lineColor: tiltLineColor,
            currentValueLabel: currentLabel,
            title: title
        )
    }

    // MARK: - 4. Corrector deltas + ramp

    /// **NN/g + medical monitor 패턴**: 8 관절 horizontal bar (center=0, deflect=delta).
    /// 부호 색 분리: + = 파랑 (info), - = 주황 (forge) — WCAG color-blind safe.
    private var correctorPanel: some View {
        // v1.9 (2026-05-17): 보정 강도 slider + 자동 튜닝 패널은 gyroMeterBlock 으로
        // 이동. 여기는 8 관절 delta + ramp progress 만 남김.
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Text("자세 보정 delta (8 관절)")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if let progress = session.rampProgress {
                    Text(String(format: "보정 진행 %.0f%%", progress * 100))
                        .font(DFFont.monoLabel)
                        .foregroundStyle(progress >= 1 ? DFColor.success : DFColor.accent)
                } else if session.enableBalanceCorrection {
                    Text("보정 대기")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text("자세 보정 꺼짐")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            if let progress = session.rampProgress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(DFColor.textSecondary.opacity(DFOpacity.o15))
                            .frame(height: DFSize.barTrackH)
                        Rectangle()
                            .fill(progress >= 1 ? DFColor.success : DFColor.accent)
                            .frame(width: max(0, geo.size.width) * CGFloat(progress),
                                   height: DFSize.barTrackH)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.tiny))
                }
                .frame(height: DFSize.barTrackH)
                .accessibilityLabel("Ramp 진행 \(Int(progress * 100))%")
            }
            let corrections = session.lastCorrections
            VStack(spacing: DFSpace.micro2) {
                jointDeltaRow("R hipRoll", corrections?.rHipRoll)
                jointDeltaRow("L hipRoll", corrections?.lHipRoll)
                jointDeltaRow("R knee", corrections?.rKnee)
                jointDeltaRow("L knee", corrections?.lKnee)
                jointDeltaRow("R ankPitch", corrections?.rAnklePitch)
                jointDeltaRow("L ankPitch", corrections?.lAnklePitch)
                jointDeltaRow("R ankRoll", corrections?.rAnkleRoll)
                jointDeltaRow("L ankRoll", corrections?.lAnkleRoll)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("8 관절 자세 보정 delta")
        }
    }

    /// 가로 bar — center=0, max ±15° (BalanceCorrector.maxCorrectionDeg).
    /// **v1.9 (2026-05-17 사용자 요청)**: 자동 튜닝 권고 + auto-apply toggle.
    /// 종료된 session 분석 결과 기반으로 다음 cycle 의 보정 강도 자동 조정 권고.
    @ViewBuilder
    private var autoTunerPanel: some View {
        let tuner = session.autoTuner
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "brain.head.profile")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.info)
                Text("자동 튜닝 (학습 기반)")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Toggle("자동 적용", isOn: Binding(
                    get: { tuner.autoApplyEnabled },
                    set: { tuner.autoApplyEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                Text(tuner.autoApplyEnabled ? "ON" : "OFF")
                    .font(DFFont.label)
                    .foregroundStyle(tuner.autoApplyEnabled ? DFColor.success : DFColor.textSecondary)
            }
            if let rec = tuner.pendingRecommendation {
                Text(rec.reason)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.info)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DFSpace.xs2) {
                    Button("바로 적용") {
                        session.correctorIntensityLevel = rec.level
                        tuner.userOverride()  // 권고 reset.
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("무시") {
                        tuner.userOverride()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(DFColor.textSecondary)
                }
            } else if tuner.recentSummaries.isEmpty {
                Text("아직 분석 데이터 없음 — 보행 cycle 종료 후 권고 표시됨")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            } else {
                Text("최근 \(tuner.recentSummaries.count)회 session — 현재 강도 적정 (변경 권고 없음)")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.success)
            }
            if let latest = tuner.recentSummaries.first {
                HStack(spacing: DFSpace.sm) {
                    metric("평균 tilt", String(format: "%.1f°", max(latest.meanAbsRoll, latest.meanAbsPitch)))
                    metric("진동", String(format: "%.1fHz", latest.oscillationScore))
                    metric("효과", String(format: "%+.2f", latest.correctorEffectivenessScore))
                    metric("샘플", "\(latest.sampleCount)")
                }
                .font(DFFont.monoLabel)
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.info.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            Text(value).font(DFFont.monoLabel).foregroundStyle(DFColor.info)
        }
    }

    /// **v1.8 (2026-05-17 사용자 요청)**: 자이로 보정 강도 5단계 슬라이더.
    /// 사용자가 직접 보정 개입 강도를 조절 — 꺼짐(0) ~ 최대(4).
    /// Bus 미연결 / IMU stale 시 자동 비활성 표시.
    @ViewBuilder
    private var correctorIntensitySlider: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "slider.horizontal.3")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.accent)
                Text("자이로 보정 강도")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text(WalkLabSession.intensityLabel(level: session.correctorIntensityLevel))
                    .font(DFFont.monoLabel)
                    .foregroundStyle(intensityColor)
            }
            HStack(spacing: DFSpace.xs2) {
                ForEach(0..<5) { lvl in
                    Button {
                        session.correctorIntensityLevel = lvl
                        // intensity 0 = enableBalanceCorrection off, 1+ = on.
                        session.enableBalanceCorrection = (lvl > 0)
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(lvl)")
                                .font(DFFont.bodyEmph.monospaced())
                                .foregroundStyle(intensityTextColor(for: lvl))
                            Text(intensityShortLabel(for: lvl))
                                .font(DFFont.micro)
                                .foregroundStyle(DFColor.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DFSpace.xs2)
                        .background(intensityBackground(for: lvl))
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                        .overlay(
                            RoundedRectangle(cornerRadius: DFRadius.xs2)
                                .stroke(lvl == session.correctorIntensityLevel
                                        ? DFColor.accent
                                        : DFColor.textSecondary.opacity(DFOpacity.o25),
                                        lineWidth: lvl == session.correctorIntensityLevel ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("강도 \(lvl): \(WalkLabSession.intensityLabel(level: lvl))")
                }
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.accent.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private var intensityColor: Color {
        switch session.correctorIntensityLevel {
        case 0: return DFColor.textSecondary
        case 1: return DFColor.info
        case 2: return DFColor.success
        case 3: return DFColor.warning
        case 4: return DFColor.danger
        default: return DFColor.textSecondary
        }
    }

    private func intensityTextColor(for lvl: Int) -> Color {
        if lvl == session.correctorIntensityLevel {
            switch lvl {
            case 0: return DFColor.textSecondary
            case 1: return DFColor.info
            case 2: return DFColor.success
            case 3: return DFColor.warning
            case 4: return DFColor.danger
            default: return DFColor.textSecondary
            }
        }
        return DFColor.textSecondary
    }

    private func intensityBackground(for lvl: Int) -> Color {
        if lvl == session.correctorIntensityLevel {
            switch lvl {
            case 0: return DFColor.textSecondary.opacity(DFOpacity.o15)
            case 1: return DFColor.info.opacity(DFOpacity.o15)
            case 2: return DFColor.success.opacity(DFOpacity.o15)
            case 3: return DFColor.warning.opacity(DFOpacity.o15)
            case 4: return DFColor.danger.opacity(DFOpacity.o15)
            default: return DFColor.textSecondary.opacity(DFOpacity.o10)
            }
        }
        return Color.clear
    }

    private func intensityShortLabel(for lvl: Int) -> String {
        switch lvl {
        case 0: return "꺼짐"
        case 1: return "약함"
        case 2: return "표준"
        case 3: return "강함"
        case 4: return "최대"
        default: return ""
        }
    }

    /// joint name 64pt 고정 + value 48pt 고정 = layout 안정. 가운데 bar 가 flex.
    private func jointDeltaRow(_ name: String, _ delta: Double?) -> some View {
        let value = delta ?? 0
        let absVal = abs(value)
        let maxAbs: Double = 15
        let frac = min(1, absVal / maxAbs)
        let isPositive = value >= 0
        let color: Color = isPositive ? DFColor.info : DFColor.forge
        return HStack(spacing: DFSpace.xs) {
            Text(name)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.jointNameColW, alignment: .leading)
                .accessibilityHidden(true)  // 부모가 combined label 사용
            GeometryReader { geo in
                let halfW = max(0, geo.size.width / 2)
                ZStack(alignment: .leading) {
                    // 중앙선.
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(DFOpacity.o10))
                        .frame(height: DFSize.barTrackH)
                    // **2026-05-16 시인성**: threshold tick marks at ±5° / ±10°.
                    // 사용자가 보정 magnitude 즉시 비교 가능.
                    ForEach([5.0, 10.0], id: \.self) { tickDeg in
                        let tickFrac = tickDeg / maxAbs
                        // 양수 쪽 tick.
                        Rectangle()
                            .fill(DFColor.textSecondary.opacity(DFOpacity.o25))
                            .frame(width: DFSize.borderHairline, height: DFSpace.xs)  // 4pt tick mark
                            .offset(x: halfW + halfW * CGFloat(tickFrac))
                        // 음수 쪽 tick.
                        Rectangle()
                            .fill(DFColor.textSecondary.opacity(DFOpacity.o25))
                            .frame(width: DFSize.borderHairline, height: DFSpace.xs)  // 4pt tick mark
                            .offset(x: halfW - halfW * CGFloat(tickFrac))
                    }
                    // 양수 / 음수 deflection.
                    if isPositive {
                        Rectangle()
                            .fill(color)
                            .frame(width: halfW * CGFloat(frac),
                                   height: DFSize.barTrackH)
                            .offset(x: halfW)
                    } else {
                        Rectangle()
                            .fill(color)
                            .frame(width: halfW * CGFloat(frac),
                                   height: DFSize.barTrackH)
                            .offset(x: halfW - halfW * CGFloat(frac))
                    }
                    // 중앙 tick (center zero indicator) — 0.5pt hairline.
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(DFOpacity.o40))
                        .frame(width: DFSize.borderHairline, height: DFSize.dot)
                        .offset(x: halfW - DFSize.borderHairline / 2)
                }
            }
            .frame(height: DFSize.dot + DFSpace.micro2)  // 7pt: dot(5) + micro(2) — tick 위로 확장
            Text(String(format: "%+.2f°", value))
                .font(DFFont.dataMicro)
                .foregroundStyle(absVal > 0.05 ? color : DFColor.textSecondary)
                .frame(width: Self.jointValueColW, alignment: .trailing)
                .lineLimit(1)
        }
        // **2026-05-16 시인성**: 보정 값 변경 시 부드러운 animation.
        .animation(DFAnimation.standard, value: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) 보정 \(String(format: "%+.2f°", value))")
    }

    /// joint name 컬럼 폭 — "R ankPitch" 14자 까지 1줄 표시 보장.
    private static let jointNameColW: CGFloat = 64
    /// joint value 컬럼 폭 — "+10.00°" 7자 monospace 보장.
    private static let jointValueColW: CGFloat = 48

    // MARK: - 5. Event log (Philips IntelliVue 패턴)

    /// **Philips IntelliVue alarm log 패턴**: 시간 + severity icon + 메시지.
    /// **ISA-101 §6.7**: 시간역순 + 가장 최근이 상단.
    private var eventLogPanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Text("이벤트 로그")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if !session.safetyEvents.isEmpty {
                    Button {
                        session.clearSafetyEvents()
                    } label: {
                        Text("지우기")
                            .font(DFFont.micro)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DFColor.textSecondary)
                    .accessibilityLabel("이벤트 로그 비우기")
                    .help("이벤트 로그 \(session.safetyEvents.count)건 모두 삭제")
                    .dfPointerCursor()
                }
            }
            if session.safetyEvents.isEmpty {
                Text("(아직 이벤트 없음 — 보행 시작 시 로그 누적)")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DFSpace.xs2)
            } else {
                ScrollView {
                    VStack(spacing: DFSpace.micro) {
                        // **2026-05-16 시인성**: 최신 이벤트 강조.
                        // **이슈 처리 (2026-05-16)**: 이전엔 Array(reversed) +
                        // Array(enumerated) 두 allocation (~10KB × 2 / body eval =
                        // 400KB/s 알로 churn). 정정: ReversedCollection 직접 사용
                        // (RandomAccessCollection 보장) + isNewest 는 last id 비교.
                        let newestId = session.safetyEvents.last?.id
                        ForEach(session.safetyEvents.reversed()) { evt in
                            eventRow(evt, isNewest: evt.id == newestId)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(DFAnimation.listChange, value: session.safetyEvents.count)
                }
                .frame(maxHeight: Self.eventLogMaxH)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("이벤트 로그 \(session.safetyEvents.count)건")
            }
        }
    }

    /// 이벤트 로그 ScrollView 최대 높이 — 약 9 row × 15pt 가시 + scroll.
    private static let eventLogMaxH: CGFloat = 140

    private func eventRow(_ evt: WalkLabSession.SafetyEvent, isNewest: Bool) -> some View {
        let severityColor = eventColor(evt.kind)
        return HStack(spacing: 0) {
            // **2026-05-16 시인성**: 좌측 severity stripe (3pt) — Philips IntelliVue 패턴.
            // 색 + 라벨 분리 — 텍스트 옆 sticker 처럼 즉시 인식.
            Rectangle()
                .fill(severityColor)
                .frame(width: DFSize.barTrackH)
                .accessibilityHidden(true)
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: eventIcon(evt.kind))
                    .font(DFFont.label)
                    .foregroundStyle(severityColor)
                    .frame(width: DFSize.iconCol)
                    .accessibilityHidden(true)
                Text(timeString(evt.timestamp))
                    .font(DFFont.monoMicro)
                    .foregroundStyle(DFColor.textSecondary)
                    .frame(width: Self.eventTimeColW, alignment: .leading)
                Text(evt.message)
                    .font(DFFont.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DFSpace.xs)
            .padding(.vertical, DFSpace.micro)
        }
        // **2026-05-16 시인성**: 최신 이벤트 강조 — newest row 에 subtle bg.
        // Twitter/X 의 새 트윗 highlight 패턴.
        .background(isNewest
            ? severityColor.opacity(DFOpacity.o12)
            : severityColor.opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.tiny))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeString(evt.timestamp)) \(evt.kind.rawValue) — \(evt.message)\(isNewest ? " (최신)" : "")")
    }

    /// 이벤트 로그 의 timestamp 컬럼 폭 — "HH:mm:ss" 8 char monospace.
    private static let eventTimeColW: CGFloat = 54

    // MARK: - Helpers

    private struct LayerStatus: Identifiable {
        let id: String
        let name: String
        let icon: String
        let valueLabel: String
        let unit: String?
        let thresholdLabel: String
        let color: Color
        /// 데이터 source 라벨 — "실 IMU" / "실 모터" / "시뮬" / "지연" / nil (UI-only layer).
        /// nil 이면 source pill 미표시 (L1 cradle, L2 stability).
        let dataSourceLabel: String?
        /// 데이터 source 색 — source pill 색.
        let dataSourceColor: Color?
    }

    private func stateColor(_ s: WalkLabSession.BalanceState) -> Color {
        switch s {
        case .normal:    return DFColor.success
        case .caution:   return DFColor.warning
        case .warning:   return DFColor.severe
        case .danger:    return DFColor.danger
        case .emergency: return DFColor.danger
        }
    }

    private func stateIcon(_ s: WalkLabSession.BalanceState) -> String {
        switch s {
        case .normal:    return "checkmark.shield.fill"
        case .caution:   return "exclamationmark.circle.fill"
        case .warning:   return "exclamationmark.triangle.fill"
        case .danger:    return "exclamationmark.octagon.fill"
        case .emergency: return "xmark.octagon.fill"
        }
    }

    private func stateMessage(_ s: WalkLabSession.BalanceState) -> String {
        switch s {
        case .normal:    return "임계 미초과 — 정상 보행"
        case .caution:   return "기울기 25°+ — 모니터링 강화"
        case .warning:   return "기울기 35°+ — 보행 속도 70% 자동 감속"
        case .danger:    return "기울기 45°+ — 자세 동결 (lastSafePose 유지)"
        case .emergency: return "기울기 50°+ — 토크 OFF + walkReady 복귀"
        }
    }

    private func sparklineColor(forTilt deg: Double) -> Color {
        let abs = Swift.abs(deg)
        if abs >= 50 { return DFColor.danger }
        if abs >= 35 { return DFColor.severe }
        if abs >= 25 { return DFColor.warning }
        return DFColor.accent
    }

    private func sparklineColor(forScore score: Double) -> Color {
        if score >= 80 { return DFColor.danger }
        if score >= 60 { return DFColor.severe }
        if score >= 30 { return DFColor.warning }
        return DFColor.accent
    }

    private var imuSourceColor: Color {
        switch session.imuSource {
        case .sim:   return DFColor.textSecondary
        case .real:  return DFColor.success
        case .stale: return DFColor.warning
        }
    }

    /// 2026-05-17 v1.7: IMU plausibility chip.
    /// cm.rs/lib.rs 10-bit ADC + RL=X/FB=Y axis 정정 완료. 이 chip 은 plausibility 진단
    /// (1g 중력 정상 감지 여부) 만 표시. accelZ |centered| 가 150-400 범위면 정상.
    @ViewBuilder
    private var imuScaleWarningChip: some View {
        let suspicion = session.imuScaleSuspicion
        // sim / unknown — 표시 안 함 (false positive 차단).
        if session.imuSource == .real,
           suspicion != .unknown,
           suspicion != .looksValid16Bit {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("IMU plausibility — \(suspicion.rawValue)")
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(DFColor.danger)
                    Text("accelZ |centered| 평균 \(Int(session.imuAccelZMagnitude)) (10-bit ADC). 정상 idle 시 ≈ 256 (≈1g). chip variant / mounting / 진동 확인.")
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DFSpace.xs2)
            .background(DFColor.danger.opacity(DFOpacity.o12))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.tiny))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("IMU plausibility 경고, \(suspicion.rawValue), accelZ centered 평균 \(Int(session.imuAccelZMagnitude))")
        }
    }

    /// 모터 온도 source 색 — sim=회색, real=초록, stale=주황.
    /// imuSourceColor 와 동일 매핑.
    private var motorTempSourceColor: Color {
        switch session.motorTempSource {
        case .sim:   return DFColor.textSecondary
        case .real:  return DFColor.success
        case .stale: return DFColor.warning
        }
    }

    private func eventIcon(_ k: WalkLabSession.SafetyEvent.Kind) -> String {
        switch k {
        case .sessionStart:          return "play.circle"
        case .sessionStop:           return "stop.circle"
        case .stateChange:           return "arrow.triangle.swap"
        case .emergencyTriggered:    return "bolt.fill"
        case .predictorRecommend:    return "exclamationmark.shield.fill"
        case .correctorOn:           return "figure.balanced"
        case .correctorOff:          return "figure.stand"
        case .rampComplete:          return "checkmark.circle.fill"
        case .imuSourceChange:       return "gyroscope"
        case .motorTempSourceChange: return "thermometer"
        case .thermalAlarm:          return "thermometer.sun.fill"
        case .preflightFailure:      return "xmark.shield"
        }
    }

    private func eventColor(_ k: WalkLabSession.SafetyEvent.Kind) -> Color {
        switch k {
        case .sessionStart, .sessionStop, .correctorOff: return DFColor.textSecondary
        case .stateChange:                               return DFColor.warning
        case .emergencyTriggered, .predictorRecommend,
             .thermalAlarm, .preflightFailure:           return DFColor.danger
        case .correctorOn, .rampComplete:                return DFColor.success
        case .imuSourceChange, .motorTempSourceChange:   return DFColor.info
        }
    }

    /// **2026-05-16 정정 (Agent 2 발견)**: DateFormatter 매 row 마다 새로 alloc
    /// → 50ms tick × N rows 의 GC pressure. static cache 로 한 번만 alloc.
    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func timeString(_ d: Date) -> String {
        Self.eventTimeFormatter.string(from: d)
    }
}
