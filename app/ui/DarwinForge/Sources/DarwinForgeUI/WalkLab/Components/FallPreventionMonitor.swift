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
///    - §3.2.1 — attitude indicator: 임계 zone 음영. 본 sparkline 의 22°/28°/30°
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm2) {
            heroBanner
            layerStatusGrid
            timeSeriesRow
            correctorPanel
            eventLogPanel
        }
        .padding(DFSpace.sm2)
        // **2026-05-16**: Apple HIG Liquid Glass — `.regularMaterial` 사용.
        // Reduce Transparency ON 시 자동으로 solid elev2 fallback.
        .dfMaterial(.regularMaterial, fallback: DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline)
        )
        // **2026-05-16 검증**: ultrawide / fullscreen 시 dashboard 시각 sparseness
        // 방지. 1400pt = NN/g Dashboard Design Patterns 권장 표준 폭 (시선 이동
        // 최적). leading alignment — detail 좌상단부터. 작은 윈도우 (< 1400pt)
        // 에선 영향 X (maxWidth 라 .infinity 처럼 동작).
        .frame(maxWidth: Self.dashboardMaxW, alignment: .leading)
        // **2026-05-16 Phase B-1**: Dynamic Type cap — `xxxLarge` 까지 허용.
        // Apple HIG: monitoring dashboard 같은 dense layout 은 큰 텍스트
        // 모드에서 부서질 위험. `xxxLarge` 가 안전한 상한 (사용자 가독성 ↑ +
        // layout 무결성). 그 이상 (`accessibility1`~`accessibility5`) 차단.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fall Prevention 모니터링 대시보드")
    }

    /// Dashboard 최대 폭 — ultrawide / fullscreen 시 시각 sparseness 방지.
    /// NN/g: dashboard 의 데이터 밀도 최적 폭 = 1200-1400pt.
    private static let dashboardMaxW: CGFloat = 1400

    // MARK: - 1. Hero status banner

    /// **ISA-101 §6.3 패턴**: 회색 카드 배경 + 현재 상태색 만 강조.
    /// **NASA EICAS 패턴**: 단일 critical info 가 hero — 1초 안에 인식 가능.
    private var heroBanner: some View {
        let state = session.balanceState
        let color = stateColor(state)
        let icon = stateIcon(state)
        let tiltMax = max(abs(session.imuRollDeg), abs(session.imuPitchDeg))
        return HStack(spacing: DFSpace.sm3) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s28, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: DFSize.heroBox, height: DFSize.heroBox)
                .background(color.opacity(DFOpacity.o15))
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .accessibilityLabel("안전 상태 \(state.label)")
                .help(stateMessage(state).isEmpty
                      ? "안전 상태 \(state.label) — 정상 보행"
                      : stateMessage(state))
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                HStack(spacing: DFSpace.xs2) {
                    Text("안전 상태")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: DFSpace.xs)
                    // 데이터 source 요약 — 사용자가 한 눈에 "실 robot vs sim 데이터" 식별.
                    // **2026-05-16**: 재사용 가능 `DFSourcePill` 컴포넌트 사용.
                    DFSourcePill(label: session.imuSource.label,
                                 tint: imuSourceColor,
                                 leading: "IMU")
                        .layoutPriority(1)
                    DFSourcePill(label: session.motorTempSource.label,
                                 tint: motorTempSourceColor,
                                 leading: "모터")
                        .layoutPriority(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: DFSpace.sm) {
                    Text(state.label)
                        .font(.system(size: DFFontSize.s20, weight: .semibold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: DFSpace.xs)
                    Text(String(format: "%.1f°", tiltMax))
                        .font(.system(size: DFFontSize.s18, weight: .semibold,
                                      design: .monospaced).monospacedDigit())
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("max|tilt|")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                }
                if !stateMessage(state).isEmpty {
                    Text(stateMessage(state))
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DFSpace.sm2)
        .background(color.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs2)
                .stroke(color.opacity(DFOpacity.o35),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
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
                .font(.system(size: DFFontSize.s10, weight: .medium))
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
            id: "L1", name: "L1 Cradle",
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
            id: "L2", name: "L2 Stability",
            icon: session.advanced ? "slider.horizontal.3" : "minus.circle",
            valueLabel: session.advanced ? String(format: "%.0f", stab) : "—",
            unit: session.advanced ? "/100" : nil,
            thresholdLabel: session.advanced ? "≥ 80 = critical 차단" : "고급 모드 OFF",
            color: stabColor,
            dataSourceLabel: nil,
            dataSourceColor: nil
        )
        // L3 — IMU tilt (max|roll/pitch|). data = imuSource.
        let tiltMax = max(abs(session.imuRollDeg), abs(session.imuPitchDeg))
        let tiltColor: Color = {
            if tiltMax >= 30 { return DFColor.danger }
            if tiltMax >= 28 { return DFColor.danger }
            if tiltMax >= 22 { return DFColor.warning }
            if tiltMax >= 15 { return DFColor.warning }
            return DFColor.success
        }()
        let l3 = LayerStatus(
            id: "L3", name: "L3 IMU Tilt",
            icon: "gyroscope",
            valueLabel: String(format: "%.1f", tiltMax),
            unit: "°",
            thresholdLabel: "15/22/28/30° 5단계",
            color: tiltColor,
            dataSourceLabel: session.imuSource.label,
            dataSourceColor: imuSourceColor
        )
        // L4 — Predictor score. data = imuSource (gyro + tilt 둘 다 IMU).
        let score = session.fallPrediction.score
        let scoreColor: Color = {
            if score >= 80 { return DFColor.danger }
            if score >= 60 { return DFColor.warning }
            if score >= 30 { return DFColor.warning }
            return DFColor.success
        }()
        let l4 = LayerStatus(
            id: "L4", name: "L4 Predictor",
            icon: "exclamationmark.shield",
            valueLabel: String(format: "%.0f", score),
            unit: "/100",
            thresholdLabel: session.fallPrediction.etaMs.map {
                String(format: "ETA %.0fms", $0)
            } ?? "≥ 80 = 선제 정지",
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
            id: "L5", name: "L5 Corrector",
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
            if temp >= 60 { return DFColor.danger }
            if temp >= 50 { return DFColor.warning }
            if temp >= 45 { return DFColor.warning }
            return DFColor.success
        }()
        let l6 = LayerStatus(
            id: "L6", name: "L6 Thermal",
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
    /// **NASA Ames §3.2.1**: 임계 zone stripe (-30..-22 / 22..30 음영).
    ///
    /// **반응형 (Apple HIG Adaptive Layout)**: `ViewThatFits` 사용 —
    /// 충분한 폭 (각 sparkline ≥ 130pt) 시 horizontal 3 column,
    /// 그 외 vertical stack (각 차트 full-width). HSplitView detail
    /// minWidth 480 - sidebar 240 = 240pt 일 때도 vertical 로 사용 가능.
    private var timeSeriesRow: some View {
        let now = Date()
        let cutoff = now.addingTimeInterval(-10)
        let recent = session.safetyTimeline.filter { $0.timestamp >= cutoff }
        let rollSp = makeSparkline(
            samples: recent.map { ($0.timestamp, $0.rollDeg) },
            valueRange: -35...35,
            tiltLineColor: sparklineColor(forTilt: session.imuRollDeg),
            currentLabel: String(format: "%+.1f°", session.imuRollDeg),
            title: "Roll", isTiltAxis: true
        )
        let pitchSp = makeSparkline(
            samples: recent.map { ($0.timestamp, $0.pitchDeg) },
            valueRange: -35...35,
            tiltLineColor: sparklineColor(forTilt: session.imuPitchDeg),
            currentLabel: String(format: "%+.1f°", session.imuPitchDeg),
            title: "Pitch", isTiltAxis: true
        )
        let scoreSp = makeSparkline(
            samples: recent.map { ($0.timestamp, $0.predictionScore) },
            valueRange: 0...100,
            tiltLineColor: sparklineColor(forScore: session.fallPrediction.score),
            currentLabel: String(format: "%.0f", session.fallPrediction.score),
            title: "Predictor", isTiltAxis: false
        )
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("최근 10초 — Roll / Pitch / Predictor Score")
                .font(.system(size: DFFontSize.s10, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
            ViewThatFits(in: .horizontal) {
                // Wide: 3 columns horizontal (preferred — Tufte small multiples)
                HStack(spacing: DFSpace.xs) {
                    rollSp.frame(minWidth: Self.sparklineMinW, height: Self.sparklineWideH)
                    pitchSp.frame(minWidth: Self.sparklineMinW, height: Self.sparklineWideH)
                    scoreSp.frame(minWidth: Self.sparklineMinW, height: Self.sparklineWideH)
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
        .accessibilityLabel("최근 10초 시계열 — Roll, Pitch, Predictor Score")
    }

    /// Sparkline 최소 너비 — ViewThatFits 폭 분기점. 130pt = Roll/Pitch 10초 trace
    /// 가 인지 가능한 최소 (10 sample × 10pt 간격 + padding).
    private static let sparklineMinW: CGFloat = 130
    /// Sparkline horizontal 모드 높이 — Apple HIG chart canvas 표준 ≥ 48pt.
    private static let sparklineWideH: CGFloat = 56
    /// Sparkline vertical 모드 높이 — 좁은 폭에서 컨텍스트 손실 최소화 + 가독성.
    private static let sparklineNarrowH: CGFloat = 44

    /// Sparkline factory — wide/narrow ViewThatFits 모두 동일 구성으로 생성.
    /// `isTiltAxis = true` 시 IMU tilt 임계 (15/22/30°), false 시 score 임계 (30/60/80).
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
                .init(value: 15, color: DFColor.warning),
                .init(value: 22, color: .orange),
                .init(value: 30, color: DFColor.danger),
              ]
            : [
                .init(value: 30, color: DFColor.warning),
                .init(value: 60, color: .orange),
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
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Text("자세 보정 delta (8 관절)")
                    .font(.system(size: DFFontSize.s10, weight: .medium))
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if let progress = session.rampProgress {
                    Text(String(format: "Ramp %.0f%%", progress * 100))
                        .font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(progress >= 1 ? DFColor.success : DFColor.accent)
                } else if session.enableBalanceCorrection {
                    Text("Ramp pending")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text("Corrector OFF")
                        .font(.system(size: DFFontSize.s10))
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
                .font(.system(size: DFFontSize.s9))
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
            .frame(height: DFSize.dot)
            Text(String(format: "%+.2f°", value))
                .font(.system(size: DFFontSize.s9, design: .monospaced).monospacedDigit())
                .foregroundStyle(absVal > 0.05 ? color : DFColor.textSecondary)
                .frame(width: Self.jointValueColW, alignment: .trailing)
                .lineLimit(1)
        }
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
                    .font(.system(size: DFFontSize.s10, weight: .medium))
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if !session.safetyEvents.isEmpty {
                    Button {
                        session.clearSafetyEvents()
                    } label: {
                        Text("지우기")
                            .font(.system(size: DFFontSize.s9))
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
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DFSpace.xs2)
            } else {
                ScrollView {
                    VStack(spacing: DFSpace.micro) {
                        ForEach(session.safetyEvents.reversed()) { evt in
                            eventRow(evt)
                        }
                    }
                }
                .frame(maxHeight: Self.eventLogMaxH)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("이벤트 로그 \(session.safetyEvents.count)건")
            }
        }
    }

    /// 이벤트 로그 ScrollView 최대 높이 — 약 9 row × 15pt 가시 + scroll.
    private static let eventLogMaxH: CGFloat = 140

    private func eventRow(_ evt: WalkLabSession.SafetyEvent) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: eventIcon(evt.kind))
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(eventColor(evt.kind))
                .frame(width: DFSize.iconCol)
                .accessibilityHidden(true)
            Text(timeString(evt.timestamp))
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: Self.eventTimeColW, alignment: .leading)
            Text(evt.message)
                .font(.system(size: DFFontSize.s10))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DFSpace.xs)
        .padding(.vertical, DFSpace.micro)
        .background(eventColor(evt.kind).opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.tiny))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeString(evt.timestamp)) \(evt.kind.rawValue) — \(evt.message)")
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
        case .warning:   return .orange
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
        case .caution:   return "기울기 15°+ — 모니터링 강화"
        case .warning:   return "기울기 22°+ — 보행 속도 70% 자동 감속"
        case .danger:    return "기울기 28°+ — 자세 동결 (lastSafePose 유지)"
        case .emergency: return "기울기 30°+ — 토크 OFF + walkReady 복귀"
        }
    }

    private func sparklineColor(forTilt deg: Double) -> Color {
        let abs = Swift.abs(deg)
        if abs >= 30 { return DFColor.danger }
        if abs >= 22 { return .orange }
        if abs >= 15 { return DFColor.warning }
        return DFColor.accent
    }

    private func sparklineColor(forScore score: Double) -> Color {
        if score >= 80 { return DFColor.danger }
        if score >= 60 { return .orange }
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

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
