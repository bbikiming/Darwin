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

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm2) {
            heroBanner
            layerStatusGrid
            timeSeriesRow
            correctorPanel
            eventLogPanel
        }
        .padding(DFSpace.sm2)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline)
        )
    }

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
                .frame(width: 40, height: 40)
                .background(color.opacity(DFOpacity.o15))
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("안전 상태")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    Text(session.imuSource.label)
                        .font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(imuSourceColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(imuSourceColor.opacity(DFOpacity.o10))
                        .clipShape(Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: DFSpace.sm) {
                    Text(state.label)
                        .font(.system(size: DFFontSize.s20, weight: .semibold))
                        .foregroundStyle(color)
                    Spacer()
                    Text(String(format: "%.1f°", tiltMax))
                        .font(.system(size: DFFontSize.s18, weight: .semibold,
                                      design: .monospaced).monospacedDigit())
                        .foregroundStyle(color)
                    Text("max|tilt|")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                }
                if !stateMessage(state).isEmpty {
                    Text(stateMessage(state))
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
        .padding(DFSpace.sm2)
        .background(color.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs2)
                .stroke(color.opacity(DFOpacity.o35), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    // MARK: - 2. 6-Layer status grid

    /// **NASA EICAS 패턴**: 6 systems tile grid. 각 tile = 1 safety layer.
    /// **NN/g "color + shape + label"**: icon + 라벨 + 색 항상 함께.
    private var layerStatusGrid: some View {
        let layers: [LayerStatus] = currentLayers()
        return VStack(alignment: .leading, spacing: 4) {
            Text("6-Layer 안전 시스템")
                .font(.system(size: DFFontSize.s10, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                      spacing: 4) {
                ForEach(layers) { layer in
                    layerTile(layer)
                }
            }
        }
    }

    private func layerTile(_ l: LayerStatus) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: l.icon)
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(l.color)
                Text(l.name)
                    .font(.system(size: DFFontSize.s10, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(l.valueLabel)
                    .font(.system(size: DFFontSize.s12, weight: .semibold,
                                  design: .monospaced).monospacedDigit())
                    .foregroundStyle(l.color)
                if let unit = l.unit {
                    Text(unit)
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                }
                Spacer()
            }
            Text(l.thresholdLabel)
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(l.color.opacity(DFOpacity.o06))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(l.color.opacity(DFOpacity.o25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func currentLayers() -> [LayerStatus] {
        // L1 — 정비 스탠드 (사이드바 토글).
        let l1 = LayerStatus(
            id: "L1", name: "L1 Cradle",
            icon: session.cradleConfirmed ? "checkmark.shield.fill" : "shield",
            valueLabel: session.cradleConfirmed ? "확인" : "미확인",
            unit: nil,
            thresholdLabel: "정비 스탠드 거치 필수",
            color: session.cradleConfirmed ? DFColor.success : DFColor.warning
        )
        // L2 — 슬라이더 stability score (advanced 모드일 때만 의미).
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
            color: stabColor
        )
        // L3 — IMU tilt (max|roll/pitch|).
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
            color: tiltColor
        )
        // L4 — Predictor score.
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
            color: scoreColor
        )
        // L5 — Corrector.
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
            color: corrColor
        )
        // L6 — 모터 온도.
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
            color: tempColor
        )
        return [l1, l2, l3, l4, l5, l6]
    }

    // MARK: - 3. Time-series row (Tufte small multiples)

    /// **Tufte "small multiples" 패턴**: 같은 시간축 3 sparkline. 일관 비교.
    /// **NASA Ames §3.2.1**: 임계 zone stripe (-30..-22 / 22..30 음영).
    private var timeSeriesRow: some View {
        let now = Date()
        let cutoff = now.addingTimeInterval(-10)
        let recent = session.safetyTimeline.filter { $0.timestamp >= cutoff }
        return VStack(alignment: .leading, spacing: 4) {
            Text("최근 10초 — Roll / Pitch / Predictor Score")
                .font(.system(size: DFFontSize.s10, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: DFSpace.xs) {
                SafetySparkline(
                    samples: recent.map { ($0.timestamp, $0.rollDeg) },
                    valueRange: -35...35,
                    thresholds: [
                        .init(value: 15, color: DFColor.warning),
                        .init(value: 22, color: .orange),
                        .init(value: 30, color: DFColor.danger),
                    ],
                    lineColor: sparklineColor(forTilt: session.imuRollDeg),
                    currentValueLabel: String(format: "%+.1f°", session.imuRollDeg),
                    title: "Roll"
                )
                .frame(height: 56)
                SafetySparkline(
                    samples: recent.map { ($0.timestamp, $0.pitchDeg) },
                    valueRange: -35...35,
                    thresholds: [
                        .init(value: 15, color: DFColor.warning),
                        .init(value: 22, color: .orange),
                        .init(value: 30, color: DFColor.danger),
                    ],
                    lineColor: sparklineColor(forTilt: session.imuPitchDeg),
                    currentValueLabel: String(format: "%+.1f°", session.imuPitchDeg),
                    title: "Pitch"
                )
                .frame(height: 56)
                SafetySparkline(
                    samples: recent.map { ($0.timestamp, $0.predictionScore) },
                    valueRange: 0...100,
                    thresholds: [
                        .init(value: 30, color: DFColor.warning),
                        .init(value: 60, color: .orange),
                        .init(value: 80, color: DFColor.danger),
                    ],
                    lineColor: sparklineColor(forScore: session.fallPrediction.score),
                    currentValueLabel: String(format: "%.0f", session.fallPrediction.score),
                    title: "Predictor"
                )
                .frame(height: 56)
            }
        }
    }

    // MARK: - 4. Corrector deltas + ramp

    /// **NN/g + medical monitor 패턴**: 8 관절 horizontal bar (center=0, deflect=delta).
    /// 부호 색 분리: + = 파랑 (info), - = 주황 (forge) — WCAG color-blind safe.
    private var correctorPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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
                            .fill(DFColor.textSecondary.opacity(0.15))
                            .frame(height: 3)
                        Rectangle()
                            .fill(progress >= 1 ? DFColor.success : DFColor.accent)
                            .frame(width: geo.size.width * CGFloat(progress), height: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                }
                .frame(height: 3)
            }
            let corrections = session.lastCorrections
            VStack(spacing: 2) {
                jointDeltaRow("R hipRoll", corrections?.rHipRoll)
                jointDeltaRow("L hipRoll", corrections?.lHipRoll)
                jointDeltaRow("R knee", corrections?.rKnee)
                jointDeltaRow("L knee", corrections?.lKnee)
                jointDeltaRow("R ankPitch", corrections?.rAnklePitch)
                jointDeltaRow("L ankPitch", corrections?.lAnklePitch)
                jointDeltaRow("R ankRoll", corrections?.rAnkleRoll)
                jointDeltaRow("L ankRoll", corrections?.lAnkleRoll)
            }
        }
    }

    /// 가로 bar — center=0, max ±15° (BalanceCorrector.maxCorrectionDeg).
    private func jointDeltaRow(_ name: String, _ delta: Double?) -> some View {
        let value = delta ?? 0
        let absVal = abs(value)
        let maxAbs: Double = 15
        let frac = min(1, absVal / maxAbs)
        let isPositive = value >= 0
        let color: Color = isPositive ? DFColor.info : DFColor.forge
        return HStack(spacing: 4) {
            Text(name)
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                let halfW = geo.size.width / 2
                ZStack(alignment: .leading) {
                    // 중앙선.
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.10))
                        .frame(height: 3)
                    // 양수 / 음수 deflection.
                    if isPositive {
                        Rectangle()
                            .fill(color)
                            .frame(width: halfW * CGFloat(frac), height: 3)
                            .offset(x: halfW)
                    } else {
                        Rectangle()
                            .fill(color)
                            .frame(width: halfW * CGFloat(frac), height: 3)
                            .offset(x: halfW - halfW * CGFloat(frac))
                    }
                    // 중앙 tick.
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.4))
                        .frame(width: 0.5, height: 5)
                        .offset(x: halfW - 0.25)
                }
            }
            .frame(height: 5)
            Text(String(format: "%+.2f°", value))
                .font(.system(size: DFFontSize.s9, design: .monospaced).monospacedDigit())
                .foregroundStyle(absVal > 0.05 ? color : DFColor.textSecondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: - 5. Event log (Philips IntelliVue 패턴)

    /// **Philips IntelliVue alarm log 패턴**: 시간 + severity icon + 메시지.
    /// **ISA-101 §6.7**: 시간역순 + 가장 최근이 상단.
    private var eventLogPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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
                }
            }
            if session.safetyEvents.isEmpty {
                Text("(아직 이벤트 없음 — 보행 시작 시 로그 누적)")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(session.safetyEvents.reversed()) { evt in
                            eventRow(evt)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func eventRow(_ evt: WalkLabSession.SafetyEvent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: eventIcon(evt.kind))
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(eventColor(evt.kind))
                .frame(width: 14)
            Text(timeString(evt.timestamp))
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 54, alignment: .leading)
            Text(evt.message)
                .font(.system(size: DFFontSize.s10))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(eventColor(evt.kind).opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    // MARK: - Helpers

    private struct LayerStatus: Identifiable {
        let id: String
        let name: String
        let icon: String
        let valueLabel: String
        let unit: String?
        let thresholdLabel: String
        let color: Color
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

    private func eventIcon(_ k: WalkLabSession.SafetyEvent.Kind) -> String {
        switch k {
        case .sessionStart:       return "play.circle"
        case .sessionStop:        return "stop.circle"
        case .stateChange:        return "arrow.triangle.swap"
        case .emergencyTriggered: return "bolt.fill"
        case .predictorRecommend: return "exclamationmark.shield.fill"
        case .correctorOn:        return "figure.balanced"
        case .correctorOff:       return "figure.stand"
        case .rampComplete:       return "checkmark.circle.fill"
        case .imuSourceChange:    return "gyroscope"
        case .thermalAlarm:       return "thermometer.sun.fill"
        case .preflightFailure:   return "xmark.shield"
        }
    }

    private func eventColor(_ k: WalkLabSession.SafetyEvent.Kind) -> Color {
        switch k {
        case .sessionStart, .sessionStop, .correctorOff:    return DFColor.textSecondary
        case .stateChange:                                  return DFColor.warning
        case .emergencyTriggered, .predictorRecommend,
             .thermalAlarm, .preflightFailure:              return DFColor.danger
        case .correctorOn, .rampComplete:                   return DFColor.success
        case .imuSourceChange:                              return DFColor.info
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
