import SwiftUI
import ForgeCore

/// **v1.11.21 (2026-05-20)** — 3D 뷰 우측 상단 비행기 PFD 스타일 HUD.
///
/// 사용자 요청 (2026-05-20):
/// "비행기 시뮬레이션처럼 — 보행 보정 + 연결 상태 + 발목 수평 + 무게중심 솔림".
///
/// 디자인 레퍼런스:
/// - **Boeing 787 PFD (Primary Flight Display)**: attitude indicator (pitch/roll) +
///   instrument cluster + link status. 본 HUD 의 sections 와 1:1 매핑.
/// - **NASA EICAS**: hero critical info (stability) → instruments → link → stats.
/// - **WCAG 1.4.11**: 모든 인디케이터 색 + 라벨/숫자 동반.
///
/// # Sections (top → bottom)
///
/// 1. **TITLE BAR** — "FLT HUD" + elapsed time
/// 2. **STABILITY HERO GAUGE** — 반원 (100 - fallScore) + phase progress
/// 3. **ATTITUDE & CoM** — pitch/roll 직접 표시 + CoM offset bar
/// 4. **ANKLE LEVELING & CORRECTOR** — L/R 발판 잔여각 + Δmax + ramp
/// 5. **LINK STATUS** — bus / IMU / motor freshness (Hz + lag ms)
/// 6. **WALK STATS** — SPD / STR / CYC / GYR / TLT LED rows
/// 7. **STATUS PILL ROW** — IMU + BalanceState
///
/// # 산출 근거 (각 metric 의 derivation + 출처 태깅)
///
/// 데이터 출처 분류:
/// - **LIVE**: 실 telemetry / 사용자 입력 직접 read.
/// - **DERIVED**: 실 입력값으로 계산된 단순 산식 (loss-less).
/// - **EST**: 모델 가정/추정치 포함 — UI 에 `EST` 배지로 명시.
///
/// | metric | type | formula |
/// |---|---|---|
/// | Stability | DERIVED | `100 - fallPrediction.score` (IMU source 의존) |
/// | Phase | LIVE | `session.phaseLabel` last char (idle = "—") |
/// | PIT/ROL | LIVE | `session.displayImuPitchDeg/RollDeg` |
/// | CoM FWD/LAT | **EST** | `h_com × sin(angle)` — h_com = 220mm (ROBOTIS-OP2 height 454.5mm × 0.5) |
/// | Support polygon | **EST** | 30mm 반경 (single-foot stance lateral, 발 width 60/2) |
/// | Ankle L/R | **EST** | magnitude 기반 — `sign(body) × max(0, |body| - |correction|)` |
/// | Corrector Δmax/ramp | LIVE | `lastCorrections.maxAbs`, `rampProgress` |
/// | BUS lag/rtt | LIVE | `now - lastSuccessAt`, `lastRoundTripMs` |
/// | IMU lag | LIVE | `now - lastImuSuccessAt` |
/// | MTR temp | LIVE/SIM | `maxMotorTemp` (sim 모드 시 sim source 표기) |
/// | SPD/CYC | DERIVED | `strideMm / customPeriodMs × 3.6` / `120000 / period` |
///
/// # IMU 모드 / Idle 처리
///
/// IMU `sim` 모드 또는 보행 idle 상태 시 일부 메트릭이 의미가 약해짐
/// (sim sin pattern 만 표시 등). 이런 메트릭은 dim opacity + (SIM) badge 로 명시.
public struct SceneSpeedometerOverlay: View {
    @EnvironmentObject private var session: WalkLabSession
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dfTheme) private var theme: DFTheme

    public init() {}

    public var body: some View {
        // 0.2s tick — link lag 갱신 + 부드러운 HUD 느낌.
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 0) {
                titleBar
                hudDivider
                stabilitySection
                hudDivider
                attitudeAndComSection
                hudDivider
                ankleAndCtrlSection
                hudDivider
                linkSection(now: now)
                hudDivider
                statsSection
                hudDivider
                statusBar
            }
            .frame(width: 220)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(DFColor.forge.opacity(0.40), lineWidth: 0.8)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    // MARK: - 1. Title bar

    private var titleBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DFColor.forge)
            Text("FLT HUD")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(DFColor.forge)
                .tracking(1.5)
            Spacer()
            Text(formatElapsed(ms: Int(session.elapsedMs)))
                .font(.system(size: 10, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(DFColor.textPrimary.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 2. Stability hero gauge

    private var stabilitySection: some View {
        VStack(spacing: 4) {
            ZStack {
                stabilityGaugeBackground
                stabilityGaugeFill
                stabilityCenterLabel
            }
            .frame(height: 70)
            .padding(.top, 8)
            // IMU sim/stale 시 stability 의미 약함 — dim.
            .opacity(isImuLive ? 1.0 : 0.7)

            phaseProgressBar
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                // 보행 idle 시 phase 정체 — dim.
                .opacity(isWalking ? 1.0 : 0.55)
        }
    }

    /// 반원 background arc — 회색 베이스. 컴포넌트 폭 220 의 정중앙 (110).
    private var stabilityGaugeBackground: some View {
        Path { p in
            let center = CGPoint(x: 110, y: 60)
            let r: CGFloat = 55
            p.addArc(center: center, radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(360),
                     clockwise: false)
        }
        .stroke(Color.white.opacity(0.14),
                style: StrokeStyle(lineWidth: 7, lineCap: .round))
    }

    private var stabilityGaugeFill: some View {
        let fraction = max(0.0, min(1.0, stability / 100.0))
        let endAngle = 180.0 + (180.0 * fraction)
        return Path { p in
            let center = CGPoint(x: 110, y: 60)
            let r: CGFloat = 55
            p.addArc(center: center, radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(endAngle),
                     clockwise: false)
        }
        .stroke(
            AngularGradient(
                gradient: Gradient(colors: [DFColor.danger, DFColor.warning,
                                            DFColor.warning, DFColor.success]),
                center: .init(x: 0.5, y: 0.5 + 0.07),
                startAngle: .degrees(180),
                endAngle: .degrees(360)
            ),
            style: StrokeStyle(lineWidth: 7, lineCap: .round)
        )
    }

    private var stabilityCenterLabel: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 18)
            Text("\(Int(stability.rounded()))")
                .font(.system(size: 28, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(stabilityColor)
            Text("STAB")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .tracking(2.0)
        }
    }

    private var phaseProgressBar: some View {
        let currentPhase = phaseIndex
        return HStack(spacing: 2) {
            Text("PH")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .tracking(1.0)
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { idx in
                    Rectangle()
                        .fill(idx <= currentPhase
                              ? DFColor.forge
                              : DFColor.textSecondary.opacity(0.22))
                        .frame(height: 4)
                }
            }
            Text("\(currentPhase + 1)/6")
                .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(DFColor.textPrimary)
                .frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: - 3. Attitude & Center of Mass

    /// **ATTITUDE + CoM**: IMU pitch/roll + 그로부터 derived CoM offset.
    /// 산출 근거: `offset_mm = h_com × sin(angle)`, h_com = 220mm (HUDMetrics, v1.11.22 정정).
    /// IMU sim 모드 시 ATTITUDE badge "SIM", CoM 은 항상 "EST" (모델 추정).
    private var attitudeAndComSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("ATTITUDE",
                          badge: imuBadge,
                          badgeColor: imuBadgeColor)
            HStack(spacing: 8) {
                attitudeReadout(label: "PIT", value: session.displayImuPitchDeg, color: tiltColor)
                attitudeReadout(label: "ROL", value: session.displayImuRollDeg, color: tiltColor)
            }
            .opacity(isImuLive ? 1.0 : 0.65)
            sectionHeader("CENTER OF MASS", badge: "EST", badgeColor: DFColor.warning)
            comOffsetRow(label: "FWD", offsetMm: comForwardMm)
            comOffsetRow(label: "LAT", offsetMm: comLateralMm)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func attitudeReadout(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .tracking(0.8)
            Text(String(format: "%+.1f°", value))
                .font(.system(size: 12, weight: .heavy, design: .monospaced).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// CoM offset row — 중앙 정렬 bar + 솔림 magnitude (mm) + percentage of polygon.
    private func comOffsetRow(label: String, offsetMm: Double) -> some View {
        let halfRange: Double = 70.0  // support polygon 반경 (mm)
        let pct = min(100, abs(offsetMm) / halfRange * 100)
        let normalized = max(-1.0, min(1.0, offsetMm / halfRange))
        let color = comColor(pct: pct)
        return HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .tracking(0.8)
                .frame(width: 22, alignment: .leading)
            // 중앙 0 bar — 음수=왼쪽/뒤, 양수=오른쪽/앞.
            GeometryReader { geo in
                let w = geo.size.width
                let centerX = w / 2
                ZStack(alignment: .leading) {
                    // 트랙
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.22))
                        .frame(height: 3)
                    // 중앙 tick
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.6))
                        .frame(width: 0.8, height: 7)
                        .offset(x: centerX - 0.4, y: -2)
                    // marker
                    Rectangle()
                        .fill(color)
                        .frame(width: 3, height: 9)
                        .offset(x: centerX + CGFloat(normalized) * centerX - 1.5, y: -3)
                }
            }
            .frame(height: 9)
            Text(String(format: "%+.0fmm", offsetMm))
                .font(.system(size: 10, weight: .heavy, design: .monospaced).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 52, alignment: .trailing)
        }
    }

    // MARK: - 4. Ankle leveling & Corrector

    /// **ANKLE LEVELING + CORRECTOR**: 발판이 지면과 얼마나 평행 + 보정 강도.
    /// 산출 근거:
    /// - ankleResidual = sign(body) × max(0, |body| - |correction|) (v1.11.22 magnitude 정합)
    /// - 보정 OFF 시: residual = imuPitch (corrector 미적용 가정)
    private var ankleAndCtrlSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // EST 라벨: corrector 기반 추정 (실 ankle joint angle telemetry 미사용).
            sectionHeader("ANKLE LEVELING", badge: "EST", badgeColor: DFColor.warning)
            ankleResidualRow(label: "L", residual: ankleResidualLeft)
            ankleResidualRow(label: "R", residual: ankleResidualRight)
            sectionHeader("CORRECTOR")  // LIVE — corrector 직접 출력
            correctorRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// 발판 잔여각 = |body pitch - ankle correction| → 0이 best.
    private func ankleResidualRow(label: String, residual: Double) -> some View {
        let absR = abs(residual)
        let frac = max(0.0, min(1.0, absR / 10.0))  // 10° 가 max scale (위험)
        let color = ankleColor(absResidual: absR)
        let activeSegments = Int((frac * 5.0).rounded(.toNearestOrAwayFromZero))
        return HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 12, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { idx in
                    Rectangle()
                        .fill(idx < activeSegments
                              ? color
                              : DFColor.textSecondary.opacity(0.22))
                        .frame(width: 5, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: 0.5))
                }
            }
            Text(String(format: "%+.1f°", residual))
                .font(.system(size: 10, weight: .heavy, design: .monospaced).monospacedDigit())
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(absR < 1 ? "LVL" : (absR < 3 ? "OK" : (absR < 6 ? "DEV" : "TILT")))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 28, alignment: .leading)
        }
    }

    /// Corrector 행 — Δmax + ramp progress + ON/OFF chip.
    private var correctorRow: some View {
        let delta = session.lastCorrections?.maxAbs ?? 0
        let ramp = session.rampProgress ?? 0
        let isOn = session.enableBalanceCorrection
        return HStack(spacing: 5) {
            // Δmax 값
            Text("Δ")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
            Text(String(format: "%.1f°", delta))
                .font(.system(size: 11, weight: .heavy, design: .monospaced).monospacedDigit())
                .foregroundStyle(isOn ? DFColor.accent : DFColor.textSecondary)
                .frame(width: 42, alignment: .leading)
            // ramp progress bar (5 segment)
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { idx in
                    let active = isOn && Double(idx) < (ramp * 5.0)
                    Rectangle()
                        .fill(active
                              ? DFColor.accent
                              : DFColor.textSecondary.opacity(0.22))
                        .frame(width: 5, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: 0.5))
                }
            }
            // state chip
            Text(isOn ? "BAL ON" : "OFF")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(isOn ? DFColor.success : DFColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - 5. Link status (freshness)

    /// **LINK STATUS**: bus / IMU / motor 의 lag 와 source.
    /// 산출 근거:
    /// - bus lag = now - store.lastSuccessAt (telemetry 마지막 round-trip)
    /// - IMU lag = now - store.lastImuSuccessAt
    /// - motor freshness = session.motorTempSource (.sim/.real/.stale)
    private func linkSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader("LINK")
            linkRow(
                label: "BUS",
                isLive: isBusConnected,
                lagMs: timeSinceMs(store.lastSuccessAt, now: now),
                extra: store.lastRoundTripMs.map { String(format: "%.0fms rtt", $0) } ?? "—"
            )
            linkRow(
                label: "IMU",
                isLive: session.imuSource == .real,
                lagMs: timeSinceMs(store.lastImuSuccessAt, now: now),
                extra: imuSourceLabel
            )
            linkRow(
                label: "MTR",
                isLive: session.motorTempSource == .real,
                lagMs: nil,  // motor 별도 timestamp 없음 — source label 만
                extra: String(format: "%.0f°C", session.maxMotorTemp)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Link row — status dot + label + lag + extra info.
    /// lag color: < 200ms 녹색, < 500ms 노랑, ≥ 500ms 빨강.
    private func linkRow(label: String, isLive: Bool, lagMs: Double?, extra: String) -> some View {
        let dotColor = linkDotColor(isLive: isLive, lagMs: lagMs)
        return HStack(spacing: 5) {
            // status dot
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .tracking(0.8)
                .frame(width: 26, alignment: .leading)
            // lag (있을 때만)
            if let lag = lagMs {
                Text(formatLag(lag))
                    .font(.system(size: 9, weight: .heavy, design: .monospaced).monospacedDigit())
                    .foregroundStyle(lagColor(lag))
                    .frame(width: 48, alignment: .leading)
            } else {
                Text("—")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                    .frame(width: 48, alignment: .leading)
            }
            Text(extra)
                .font(.system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(DFColor.textPrimary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - 6. LED stats rows (기존 유지)

    private var statsSection: some View {
        VStack(spacing: 3) {
            // 보행 중일 때만 SPD/CYC 가 의미 있음 — idle 시 dim.
            Group {
                statRow(label: "SPD", value: speedKmh, unit: "km/h",
                        fraction: speedKmh / 2.0, color: speedColor)
                statRow(label: "STR", value: session.strideMm, unit: "mm",
                        fraction: session.strideMm / 100.0, color: DFColor.accent)
                statRow(label: "CYC", value: cadence, unit: "spm",
                        fraction: cadence / 200.0, color: DFColor.accent)
            }
            .opacity(isWalking ? 1.0 : 0.55)
            // GYR/TLT 는 idle 에도 IMU 자세 정보로 의미 있음 — sim 시만 dim.
            Group {
                statRow(label: "GYR", value: gyroMagnitude, unit: "°/s",
                        fraction: gyroMagnitude / 200.0, color: gyroColor)
                statRow(label: "TLT", value: tiltMax, unit: "°",
                        fraction: tiltMax / 50.0, color: tiltColor)
            }
            .opacity(isImuLive ? 1.0 : 0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func statRow(label: String, value: Double, unit: String,
                          fraction: Double, color: Color) -> some View {
        let frac = max(0.0, min(1.0, fraction))
        let activeSegments = Int((frac * 5.0).rounded(.toNearestOrAwayFromZero))
        return HStack(spacing: 5) {
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { idx in
                    Rectangle()
                        .fill(idx < activeSegments
                              ? color
                              : DFColor.textSecondary.opacity(0.22))
                        .frame(width: 5, height: 7)
                        .clipShape(RoundedRectangle(cornerRadius: 0.5))
                }
            }
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .tracking(1.0)
                .frame(width: 22, alignment: .leading)
            Text(formatStatValue(value))
                .font(.system(size: 11, weight: .heavy, design: .monospaced).monospacedDigit())
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(unit)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 26, alignment: .leading)
        }
    }

    // MARK: - 7. Status pill row

    private var statusBar: some View {
        HStack(spacing: 6) {
            statusPill(icon: "antenna.radiowaves.left.and.right",
                       label: imuSourceLabel, color: imuSourceColor)
            statusPill(icon: balanceIcon, label: balanceLabel, color: balanceColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func statusPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Visual building blocks

    private var hudDivider: some View {
        Rectangle()
            .fill(DFColor.forge.opacity(0.25))
            .frame(height: 0.5)
    }

    /// Section header — 좌측 큰 라벨 + 우측 source/state badge.
    /// badge: "EST" (모델 추정), "SIM" (sim source), "IDLE" (보행 비활성).
    private func sectionHeader(_ text: String, badge: String? = nil,
                                badgeColor: Color = DFColor.textSecondary) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(DFColor.forge.opacity(0.75))
                .tracking(1.2)
            if let b = badge {
                Text(b)
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(badgeColor)
                    .tracking(0.5)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 0.5)
                    .background(badgeColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(badgeColor.opacity(0.45), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    // MARK: - Derived data — Stability

    /// 안정성 점수 (0..100, 높을수록 안전). `fallPrediction.score` 의 inverse.
    private var stability: Double {
        max(0, min(100, 100.0 - session.fallPrediction.score))
    }

    private var stabilityColor: Color {
        if stability >= 80 { return DFColor.success }
        if stability >= 60 { return DFColor.warning }
        if stability >= 30 { return DFColor.severe }
        return DFColor.danger
    }

    // MARK: - Source / liveness helpers

    /// IMU 가 실 robot 데이터인지 (sim/stale 이면 false).
    private var isImuLive: Bool { session.imuSource == .real }

    /// 보행 active 인지 (idle 이면 false → SPD/CYC dim).
    private var isWalking: Bool { session.current != .idle }

    /// 모터 telemetry 가 실 데이터인지.
    private var isMotorLive: Bool { session.motorTempSource == .real }

    /// IMU source → badge text (nil = REAL = badge 없음).
    private var imuBadge: String? {
        switch session.imuSource {
        case .real:  return nil
        case .sim:   return "SIM"
        case .stale: return "STALE"
        }
    }

    private var imuBadgeColor: Color {
        switch session.imuSource {
        case .real:  return DFColor.success
        case .sim:   return DFColor.textSecondary
        case .stale: return DFColor.danger
        }
    }

    // MARK: - Derived data — Walking (HUDMetrics 위임)

    private var speedKmh: Double {
        HUDMetrics.speedKmh(strideMm: session.strideMm, periodMs: session.customPeriodMs)
    }

    private var speedColor: Color {
        if speedKmh < 0.3 { return DFColor.textSecondary }
        if speedKmh > 1.5 { return DFColor.warning }
        return DFColor.success
    }

    private var cadence: Double {
        HUDMetrics.cadenceSpm(periodMs: session.customPeriodMs)
    }

    private var gyroMagnitude: Double {
        guard let imu = store.lastImuRaw else { return 0 }
        return max(abs(imu.gyroXDps), abs(imu.gyroYDps))
    }

    private var gyroColor: Color {
        if gyroMagnitude >= 100 { return DFColor.warning }
        if gyroMagnitude >= 50 { return DFColor.accent }
        return DFColor.textPrimary
    }

    private var tiltMax: Double {
        max(abs(session.displayImuRollDeg), abs(session.displayImuPitchDeg))
    }

    private var tiltColor: Color {
        if tiltMax >= 50        { return DFColor.danger }
        if tiltMax >= 45        { return DFColor.severe }
        if tiltMax >= 35        { return DFColor.warning }
        if tiltMax >= 25        { return DFColor.warning.opacity(0.7) }
        return DFColor.success
    }

    private var phaseIndex: Int {
        HUDMetrics.phaseIndex(label: session.phaseLabel) ?? 0
    }

    // MARK: - Derived data — Center of Mass (EST, HUDMetrics 위임)

    private var comForwardMm: Double {
        HUDMetrics.comOffsetMm(angleDeg: session.displayImuPitchDeg)
    }

    private var comLateralMm: Double {
        HUDMetrics.comOffsetMm(angleDeg: session.displayImuRollDeg)
    }

    /// support polygon % → 색.
    private func comColor(pct: Double) -> Color {
        if pct >= 100 { return DFColor.danger }
        if pct >= 70  { return DFColor.severe }
        if pct >= 40  { return DFColor.warning }
        return DFColor.success
    }

    // MARK: - Derived data — Ankle leveling (EST, HUDMetrics 위임)

    private var ankleResidualLeft: Double {
        HUDMetrics.ankleResidualDeg(
            bodyPitch: session.displayImuPitchDeg,
            correctionAnklePitch: session.lastCorrections?.lAnklePitch,
            correctorEnabled: session.enableBalanceCorrection,
            actuallyApplied: session.lastCorrectionApplied
        )
    }

    private var ankleResidualRight: Double {
        HUDMetrics.ankleResidualDeg(
            bodyPitch: session.displayImuPitchDeg,
            correctionAnklePitch: session.lastCorrections?.rAnklePitch,
            correctorEnabled: session.enableBalanceCorrection,
            actuallyApplied: session.lastCorrectionApplied
        )
    }

    private func ankleColor(absResidual: Double) -> Color {
        if absResidual >= 6 { return DFColor.danger }
        if absResidual >= 3 { return DFColor.warning }
        if absResidual >= 1 { return DFColor.warning.opacity(0.7) }
        return DFColor.success
    }

    // MARK: - Derived data — Link freshness

    /// ConnectionStore.Status 의 `.connected(_)` case 검사 — associated value 무시.
    private var isBusConnected: Bool {
        if case .connected = store.status { return true }
        return false
    }

    /// `now - timestamp` (ms). nil = 데이터 없음.
    private func timeSinceMs(_ timestamp: Date?, now: Date) -> Double? {
        guard let t = timestamp else { return nil }
        return now.timeIntervalSince(t) * 1000.0
    }

    /// lag → 색 (link freshness). HUDMetrics.lagTier 위임 (테스트 가능 임계).
    private func lagColor(_ lagMs: Double) -> Color {
        switch HUDMetrics.lagTier(lagMs) {
        case 0:  return DFColor.success
        case 1:  return DFColor.warning
        case 2:  return DFColor.severe
        default: return DFColor.danger
        }
    }

    private func linkDotColor(isLive: Bool, lagMs: Double?) -> Color {
        guard isLive else { return DFColor.textSecondary }
        if let lag = lagMs {
            return lagColor(lag)
        }
        return DFColor.success
    }

    // MARK: - Status helpers

    private var imuSourceLabel: String {
        switch session.imuSource {
        case .real:  return "REAL"
        case .sim:   return "SIM"
        case .stale: return "STALE"
        }
    }

    private var imuSourceColor: Color {
        switch session.imuSource {
        case .real:  return DFColor.success
        case .sim:   return DFColor.textSecondary
        case .stale: return DFColor.danger
        }
    }

    private var balanceIcon: String {
        switch session.balanceState {
        case .normal:    return "checkmark.shield.fill"
        case .caution:   return "exclamationmark.circle"
        case .warning:   return "exclamationmark.triangle"
        case .danger:    return "exclamationmark.octagon"
        case .emergency: return "xmark.octagon.fill"
        }
    }

    private var balanceLabel: String {
        switch session.balanceState {
        case .normal:    return "OK"
        case .caution:   return "CAUT"
        case .warning:   return "WARN"
        case .danger:    return "DANGER"
        case .emergency: return "STOP"
        }
    }

    private var balanceColor: Color {
        switch session.balanceState {
        case .normal:    return DFColor.success
        case .caution:   return DFColor.warning
        case .warning:   return DFColor.severe
        case .danger, .emergency: return DFColor.danger
        }
    }

    // MARK: - Formatting

    private func formatElapsed(ms: Int) -> String {
        let totalSec = ms / 1000
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatStatValue(_ v: Double) -> String {
        if abs(v) >= 100 { return String(format: "%.0f", v) }
        if abs(v) >= 10  { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    private func formatLag(_ ms: Double) -> String {
        HUDMetrics.formatLag(ms)
    }

    private var accessibilitySummary: String {
        """
        보행 HUD 안정성 \(Int(stability))점, pitch \(Int(session.displayImuPitchDeg))도, \
        roll \(Int(session.displayImuRollDeg))도, CoM 전방 \(Int(comForwardMm))mm 측면 \(Int(comLateralMm))mm, \
        발목 잔여 좌 \(String(format: "%.1f", ankleResidualLeft))도 우 \(String(format: "%.1f", ankleResidualRight))도, \
        보정 Δ \(String(format: "%.1f", session.lastCorrections?.maxAbs ?? 0))도, \
        IMU \(imuSourceLabel)
        """
    }
}

#if DEBUG
private func previewBackground() -> some View {
    LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
}

#Preview("Idle (no walking)") {
    let session = WalkLabSession()
    let store = ConnectionStore()
    return SceneSpeedometerOverlay()
        .environmentObject(session)
        .environmentObject(store)
        .padding()
        .background(previewBackground())
}

#Preview("Walking — Normal (IMU sim)") {
    let session = WalkLabSession()
    session.strideMm = 80
    session.customPeriodMs = 600
    session.phaseLabel = "PHASE3"
    session.imuRollDeg = 8
    session.imuPitchDeg = 4
    let store = ConnectionStore()
    return SceneSpeedometerOverlay()
        .environmentObject(session)
        .environmentObject(store)
        .padding()
        .background(previewBackground())
}

#Preview("Warning zone (35°+)") {
    let session = WalkLabSession()
    session.strideMm = 80
    session.customPeriodMs = 600
    session.phaseLabel = "PHASE2"
    session.imuRollDeg = 36
    session.imuPitchDeg = 12
    let store = ConnectionStore()
    return SceneSpeedometerOverlay()
        .environmentObject(session)
        .environmentObject(store)
        .padding()
        .background(previewBackground())
}

#Preview("Danger zone (45°+) + Corrector ON") {
    let session = WalkLabSession()
    session.strideMm = 80
    session.customPeriodMs = 600
    session.phaseLabel = "PHASE4"
    session.imuRollDeg = 46
    session.imuPitchDeg = 10
    session.enableBalanceCorrection = true
    let store = ConnectionStore()
    return SceneSpeedometerOverlay()
        .environmentObject(session)
        .environmentObject(store)
        .padding()
        .background(previewBackground())
}
#endif
