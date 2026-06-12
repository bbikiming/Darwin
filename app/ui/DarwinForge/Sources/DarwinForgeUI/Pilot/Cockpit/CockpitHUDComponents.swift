import SwiftUI

// MARK: - Cockpit color tokens

public enum CockpitColors {
    /// 형광 그린 — connected / active.
    public static let live = Color(red: 0.20, green: 0.95, blue: 0.55)
    /// 호박색 — caution / arming.
    public static let warn = Color(red: 1.00, green: 0.78, blue: 0.20)
    /// 짙은 적색 — emergency / disconnect.
    public static let danger = Color(red: 1.00, green: 0.30, blue: 0.30)
    /// 시안 — input visualisation accent.
    public static let cyan = Color(red: 0.35, green: 0.85, blue: 1.00)
    /// 화면 배경.
    public static let backdrop = Color(red: 0.04, green: 0.06, blue: 0.08)
    /// HUD glass background (translucent — legacy/fallback tint).
    public static let panel = Color.black.opacity(0.55)
    /// 머티리얼 폴백색 — 접근성 "투명도 줄이기" ON 시 불투명 dark glass.
    public static let panelSolid = Color(red: 0.07, green: 0.09, blue: 0.12)
}

// MARK: - Status pill (one row in the top-left status block)

struct CockpitStatusPill: View {
    let label: String
    let value: String
    let tone: Tone
    enum Tone { case live, warn, danger, idle }

    var color: Color {
        switch tone {
        case .live:   return CockpitColors.live
        case .warn:   return CockpitColors.warn
        case .danger: return CockpitColors.danger
        case .idle:   return Color.gray
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: CockpitMetrics.statusDot, height: CockpitMetrics.statusDot)
            Text(label.uppercased())
                .font(.system(size: CockpitMetrics.pillLabel, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.system(size: CockpitMetrics.pillValue, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Status block (top-left)

struct CockpitStatusBlock: View {
    let controllerName: String?
    let macConnected: Bool
    let robotConnected: Bool
    let armed: Bool
    let dxlPowerOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CockpitStatusPill(label: "Controller",
                              value: controllerName ?? "—",
                              tone: controllerName != nil ? .live : .idle)
            CockpitStatusPill(label: "Mac",
                              value: macConnected ? "LIVE" : "LOST",
                              tone: macConnected ? .live : .danger)
            CockpitStatusPill(label: "Robot",
                              value: robotConnected ? "CONNECTED" : "OFFLINE",
                              tone: robotConnected ? .live : .danger)
            CockpitStatusPill(label: "DXL Power",
                              value: dxlPowerOn ? "ON" : "OFF",
                              tone: dxlPowerOn ? .live : .idle)
            CockpitStatusPill(label: "ARM",
                              value: armed ? "ARMED" : "LOCKED",
                              tone: armed ? .live : .warn)
        }
        .cockpitPanel(tint: CockpitColors.live, strokeOpacity: 0.35)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Latch indicator (command vs robot-applied — O4 래칭 지연 가시화)

/// **O4 (2026-06-12)** — "명령 vs 래치값" 마이크로 인디케이터. 콕핏이 보낸 명령(스무딩 후
/// 모터 명령)과 로봇이 **실제로 적용 중인** 셰이핑 후 값(TEL2 래치)을 나란히 보여 래칭 지연을
/// 시각화한다. 차이가 임계 이상이면 "적용 대기"(warn) — 명령이 게이트 위상 경계 채택을
/// 기다리는 중. 온보드 TEL2 가 있을 때만 표시(직결/오프라인 시 호출부가 숨김).
struct CockpitLatchIndicator: View {
    let cmdStrideMm: Double
    let cmdSideMm: Double
    let cmdTurnDeg: Double
    let latch: OnboardLatchSnapshot

    private var pending: Bool {
        abs(cmdStrideMm - latch.strideMm) > 3.0 ||
        abs(cmdSideMm - latch.sideMm) > 3.0 ||
        abs(cmdTurnDeg - latch.turnDeg) > 2.0
    }

    private func row(_ label: String, _ cmd: Double, _ lat: Double, _ unit: String,
                     eps: Double) -> some View {
        let tone: Color = abs(cmd - lat) > eps ? CockpitColors.warn : CockpitColors.live
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: CockpitMetrics.pillLabel, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            Text(String(format: "%.0f", cmd))
                .font(.system(size: CockpitMetrics.pillValue, weight: .bold, design: .monospaced))
                .foregroundStyle(CockpitColors.cyan)
                .frame(width: 36, alignment: .trailing)
            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
            Text(String(format: "%.0f%@", lat, unit))
                .font(.system(size: CockpitMetrics.pillValue, weight: .bold, design: .monospaced))
                .foregroundStyle(tone)
                .frame(width: 46, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("CMD → APPLIED")
                    .font(.system(size: CockpitMetrics.pillLabel, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                Text(pending ? "적용 대기" : "동기")
                    .font(.system(size: CockpitMetrics.pillLabel, weight: .bold, design: .monospaced))
                    .foregroundStyle(pending ? CockpitColors.warn : CockpitColors.live)
            }
            row("STRIDE", cmdStrideMm, latch.strideMm, "", eps: 3.0)
            row("SIDE", cmdSideMm, latch.sideMm, "", eps: 3.0)
            row("TURN", cmdTurnDeg, latch.turnDeg, "°", eps: 2.0)
            HStack(spacing: 6) {
                Text("PH \(latch.phase.map(String.init) ?? "—")")
                    .font(.system(size: CockpitMetrics.pillLabel, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 8)
                Text((latch.activeSource ?? "—").uppercased())
                    .font(.system(size: CockpitMetrics.pillLabel, weight: .bold, design: .monospaced))
                    .foregroundStyle(latch.activeSource == "udp" ? CockpitColors.live : CockpitColors.warn)
            }
        }
        .cockpitPanel(tint: pending ? CockpitColors.warn : CockpitColors.live, strokeOpacity: 0.35)
    }
}

// MARK: - Attitude indicator (top-right, artificial horizon)

struct CockpitAttitudeIndicator: View {
    let rollDeg: Double
    let pitchDeg: Double
    let headingDeg: Double
    let batteryV: Double?
    let tempC: Double?
    let latencyMs: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Horizon 큰 원형은 column 의 시그니처. 가운데 정렬로 시각 무게중심 통일.
            HStack {
                Spacer()
                ArtificialHorizon(rollDeg: rollDeg, pitchDeg: pitchDeg)
                    .frame(width: CockpitMetrics.horizon, height: CockpitMetrics.horizon)
                Spacer()
            }
            HeadingCompassStrip(headingDeg: headingDeg)
                .frame(height: CockpitMetrics.compassH)
            VStack(alignment: .leading, spacing: 4) {
                CockpitStatusPill(label: "Battery",
                                  value: batteryV.map { String(format: "%.1f V", $0) } ?? "—",
                                  tone: batteryTone)
                CockpitStatusPill(label: "Temp",
                                  value: tempC.map { String(format: "%.0f℃", $0) } ?? "—",
                                  tone: tempTone)
                CockpitStatusPill(label: "Latency",
                                  value: latencyMs.map { "\($0) ms" } ?? "—",
                                  tone: latencyTone)
            }
        }
        .cockpitPanel(tint: CockpitColors.live, strokeOpacity: 0.25)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var batteryTone: CockpitStatusPill.Tone {
        guard let v = batteryV else { return .idle }
        if v < 10.5 { return .danger }
        if v < 11.2 { return .warn }
        return .live
    }
    private var tempTone: CockpitStatusPill.Tone {
        guard let t = tempC else { return .idle }
        if t > 60 { return .danger }
        if t > 50 { return .warn }
        return .live
    }
    private var latencyTone: CockpitStatusPill.Tone {
        guard let ms = latencyMs else { return .idle }
        if ms > 300 { return .danger }
        if ms > 150 { return .warn }
        return .live
    }
}

/// 비행 시뮬 HUD 의 클래식 — 360° linear heading compass. 현재 heading 이
/// 가운데, N/E/S/W tick 이 슬라이딩.
private struct HeadingCompassStrip: View {
    let headingDeg: Double  // 0 = North (forward in sim)

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let centre = w / 2
                // Background strip
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.black.opacity(0.6)))

                // Visible window — ±60° around current heading.
                let degVisible: Double = 120
                let pxPerDeg = w / CGFloat(degVisible)
                let normHeading = headingDeg.truncatingRemainder(dividingBy: 360)
                let baseHeading = normHeading - 60   // left edge

                // Tick every 15°, label every 45° (N/NE/E/SE/S/SW/W/NW).
                var deg = (floor(baseHeading / 15.0) * 15.0)
                while deg < baseHeading + degVisible + 15 {
                    let offsetDeg = deg - normHeading
                    let x = centre + CGFloat(offsetDeg) * pxPerDeg
                    let isMajor = Int(deg).isMultiple(of: 45)
                    let tickH: CGFloat = isMajor ? 8 : 4
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 0))
                    tick.addLine(to: CGPoint(x: x, y: tickH))
                    ctx.stroke(tick,
                               with: .color(CockpitColors.live.opacity(isMajor ? 0.9 : 0.4)),
                               lineWidth: isMajor ? 1.2 : 0.8)
                    if isMajor {
                        let label = headingLabel(deg)
                        ctx.draw(Text(label)
                                    .font(.system(size: 8, weight: .bold,
                                                  design: .monospaced))
                                    .foregroundStyle(CockpitColors.live.opacity(0.85)),
                                 at: CGPoint(x: x, y: h - 6))
                    }
                    deg += 15
                }

                // Centre marker — 현재 heading 가리키는 화살표.
                var marker = Path()
                marker.move(to: CGPoint(x: centre, y: h - 2))
                marker.addLine(to: CGPoint(x: centre - 4, y: h - 9))
                marker.addLine(to: CGPoint(x: centre + 4, y: h - 9))
                marker.closeSubpath()
                ctx.fill(marker, with: .color(CockpitColors.warn))
            }
        }
    }

    private func headingLabel(_ deg: Double) -> String {
        let d = (deg.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        switch Int(d.rounded()) {
        case 0:    return "N"
        case 45:   return "NE"
        case 90:   return "E"
        case 135:  return "SE"
        case 180:  return "S"
        case 225:  return "SW"
        case 270:  return "W"
        case 315:  return "NW"
        default:   return ""
        }
    }
}

/// 드론 시뮬레이터 클리셰 — artificial horizon. roll/pitch 만 가지고도
/// 사용자가 한눈에 자세를 알 수 있는 클래식 UI 요소.
private struct ArtificialHorizon: View {
    let rollDeg: Double
    let pitchDeg: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.7))
                .overlay(
                    Circle().stroke(CockpitColors.live.opacity(0.5), lineWidth: 1.5)
                )
            // Horizon line + pitch shading.
            Canvas { ctx, size in
                let radius = min(size.width, size.height) / 2
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let pitchOffset = CGFloat(pitchDeg) * radius / 45.0  // ±45° fills

                ctx.translateBy(x: centre.x, y: centre.y)
                ctx.rotate(by: .degrees(-rollDeg))

                // Sky.
                let sky = Path { p in
                    p.addRect(CGRect(x: -radius, y: -radius - pitchOffset,
                                     width: radius * 2, height: radius * 2))
                }
                ctx.clip(to: Circle().path(in: CGRect(x: -radius, y: -radius,
                                                      width: radius * 2,
                                                      height: radius * 2)))
                ctx.fill(sky, with: .color(Color(red: 0.15, green: 0.35, blue: 0.55)))

                let ground = Path { p in
                    p.addRect(CGRect(x: -radius, y: -pitchOffset,
                                     width: radius * 2, height: radius * 2 + pitchOffset))
                }
                ctx.fill(ground, with: .color(Color(red: 0.45, green: 0.32, blue: 0.18)))

                // Horizon line.
                var line = Path()
                line.move(to: CGPoint(x: -radius, y: -pitchOffset))
                line.addLine(to: CGPoint(x: radius, y: -pitchOffset))
                ctx.stroke(line, with: .color(.white), lineWidth: 1.4)

                // Pitch ladder (every 10°).
                for deg in stride(from: -40, through: 40, by: 10) where deg != 0 {
                    let y = -pitchOffset - CGFloat(deg) * radius / 45.0
                    let half: CGFloat = deg.isMultiple(of: 20) ? 14 : 8
                    var tick = Path()
                    tick.move(to: CGPoint(x: -half, y: y))
                    tick.addLine(to: CGPoint(x: half, y: y))
                    ctx.stroke(tick, with: .color(.white.opacity(0.7)),
                               lineWidth: 0.8)
                }
            }
            // Static aircraft symbol.
            Path { p in
                p.move(to: CGPoint(x: 20, y: 55))
                p.addLine(to: CGPoint(x: 45, y: 55))
                p.move(to: CGPoint(x: 65, y: 55))
                p.addLine(to: CGPoint(x: 90, y: 55))
                p.move(to: CGPoint(x: 55, y: 55))
                p.addEllipse(in: CGRect(x: 52, y: 52, width: 6, height: 6))
            }
            .stroke(CockpitColors.live, lineWidth: 1.4)
        }
        .clipShape(Circle())
    }
}

// MARK: - Stick indicator (bottom-left + bottom-right)

struct CockpitStickIndicator: View {
    let label: String
    let value: SIMD2<Double>     // (x, y) in [-1, +1]
    let xLabel: String
    let yLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
            ZStack {
                // Outer frame
                RoundedRectangle(cornerRadius: 6)
                    .stroke(CockpitColors.cyan.opacity(0.5), lineWidth: 1)
                // Crosshair
                Canvas { ctx, size in
                    let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                    var cross = Path()
                    cross.move(to: CGPoint(x: 0, y: mid.y))
                    cross.addLine(to: CGPoint(x: size.width, y: mid.y))
                    cross.move(to: CGPoint(x: mid.x, y: 0))
                    cross.addLine(to: CGPoint(x: mid.x, y: size.height))
                    ctx.stroke(cross, with: .color(CockpitColors.cyan.opacity(0.25)),
                               lineWidth: 0.5)
                }
                // Position dot
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let dotSize: CGFloat = 9
                    let x = CGFloat(value.x) * (w / 2 - dotSize) + w / 2 - dotSize / 2
                    let y = CGFloat(value.y) * (h / 2 - dotSize) + h / 2 - dotSize / 2
                    Circle()
                        .fill(CockpitColors.cyan)
                        .frame(width: dotSize, height: dotSize)
                        .position(x: x + dotSize / 2, y: y + dotSize / 2)
                        .shadow(color: CockpitColors.cyan.opacity(0.7), radius: 4)
                        .animation(.easeOut(duration: 0.08), value: value)
                }
                // Axis labels
                VStack {
                    Text(yLabel.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 4)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Text(xLabel.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.trailing, 4)
                }
            }
            .frame(width: 110, height: 110)
            .background(Color.black.opacity(0.6))
        }
    }
}

// MARK: - Position minimap (top-down view of sim path)

/// Robot 의 시뮬 평면 위치를 top-down 으로 시각화. 사용자가 어디로 가고 있는지
/// 항상 인지 가능 — drone 시뮬레이터의 GPS minimap 패턴.
///
/// # 시각 요소
/// - 격자 grid (0.5m 단위)
/// - path trail (점선 fade-out)
/// - robot dot + heading arrow
/// - 누적 거리 readout
struct CockpitPositionMinimap: View {
    let positionMM: SIMD2<Double>
    let headingDeg: Double
    let trail: [SIMD2<Double>]
    let totalDistanceMm: Double

    /// View 의 1축 (정사각형) 이 표현하는 world frame 의 m. 예: 4.0 = ±2m 반경.
    private let viewSpanMeters: Double = 4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("POSITION")
                    .font(.system(size: CockpitMetrics.sectionHeader, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(String(format: "%.1f m", totalDistanceMm / 1000.0))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(CockpitColors.cyan)
            }
            GeometryReader { geo in
                Canvas { ctx, size in
                    let side = min(size.width, size.height)
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    let mPerPt = viewSpanMeters / Double(side)

                    // Background
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(.black.opacity(0.55)))

                    // Grid (0.5m)
                    let ptsPerHalfMeter = CGFloat(0.5 / mPerPt)
                    var gridPath = Path()
                    var k = -10
                    while CGFloat(k) * ptsPerHalfMeter < side {
                        let off = CGFloat(k) * ptsPerHalfMeter
                        gridPath.move(to: CGPoint(x: centre.x + off, y: 0))
                        gridPath.addLine(to: CGPoint(x: centre.x + off, y: size.height))
                        gridPath.move(to: CGPoint(x: 0, y: centre.y + off))
                        gridPath.addLine(to: CGPoint(x: size.width, y: centre.y + off))
                        k += 1
                    }
                    ctx.stroke(gridPath,
                               with: .color(CockpitColors.live.opacity(0.16)),
                               lineWidth: 0.5)
                    // Centre cross (bolder)
                    var cross = Path()
                    cross.move(to: CGPoint(x: centre.x, y: 0))
                    cross.addLine(to: CGPoint(x: centre.x, y: size.height))
                    cross.move(to: CGPoint(x: 0, y: centre.y))
                    cross.addLine(to: CGPoint(x: size.width, y: centre.y))
                    ctx.stroke(cross,
                               with: .color(CockpitColors.live.opacity(0.35)),
                               lineWidth: 0.8)

                    // Path trail — fade older points (점선).
                    if trail.count >= 2 {
                        for i in 1..<trail.count {
                            let alpha = Double(i) / Double(trail.count) * 0.75
                            var seg = Path()
                            seg.move(to: worldToView(trail[i - 1],
                                                    centre: centre,
                                                    mPerPt: mPerPt))
                            seg.addLine(to: worldToView(trail[i],
                                                       centre: centre,
                                                       mPerPt: mPerPt))
                            ctx.stroke(seg,
                                       with: .color(CockpitColors.cyan.opacity(alpha)),
                                       lineWidth: 1.6)
                        }
                    }

                    // Robot dot + heading arrow at current position.
                    let robotPt = worldToView(positionMM,
                                              centre: centre,
                                              mPerPt: mPerPt)
                    // Arrow direction (heading 0 = +Z = up).
                    let rad = headingDeg * .pi / 180.0
                    let arrowLen: CGFloat = 10
                    let arrowTip = CGPoint(
                        x: robotPt.x + arrowLen * CGFloat(sin(rad)),
                        y: robotPt.y - arrowLen * CGFloat(cos(rad)))
                    var arrow = Path()
                    arrow.move(to: robotPt)
                    arrow.addLine(to: arrowTip)
                    ctx.stroke(arrow,
                               with: .color(CockpitColors.live),
                               lineWidth: 2)
                    // Robot dot
                    let dotR: CGFloat = 4
                    let dotRect = CGRect(x: robotPt.x - dotR, y: robotPt.y - dotR,
                                         width: dotR * 2, height: dotR * 2)
                    ctx.fill(Path(ellipseIn: dotRect),
                             with: .color(CockpitColors.live))
                    ctx.stroke(Path(ellipseIn: dotRect),
                               with: .color(.black),
                               lineWidth: 1)
                }
                .frame(width: geo.size.width, height: geo.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .cockpitPanel(tint: CockpitColors.cyan, strokeOpacity: 0.3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// World (mm) → minimap (pt). centre 가 view 가운데.
    ///
    /// # 좌표계 (사용자 보고: 좌/우 반대 수정)
    ///
    /// `CockpitChaseSceneView.facingAnchor` 가 robot 을 180° flip 하므로 robot 의
    /// **right** 방향은 SceneKit `-X`. 사용자가 보는 chase camera 시점도 robot 등 뒤
    /// 이므로 화면 우측 = robot 의 right = SceneKit -X.
    ///
    /// minimap 도 같은 사용자 시점 (top-down equivalent) 이어야 하므로:
    ///   - 화면 우측 (centre.x +) ← SceneKit -X (robot right)
    ///   - 화면 좌측 (centre.x -) ← SceneKit +X (robot left)
    /// 따라서 mm.x (SceneKit X) → 부호 flip 적용해 minimap 화면 좌표로 변환.
    ///
    /// mm.y (SceneKit Z, robot forward) 는 minimap 위쪽이 forward 이므로 y 부호 flip.
    private func worldToView(_ mm: SIMD2<Double>,
                             centre: CGPoint,
                             mPerPt: Double) -> CGPoint {
        let x = centre.x - CGFloat((mm.x / 1000.0) / mPerPt)   // facingAnchor 반영
        let y = centre.y - CGFloat((mm.y / 1000.0) / mPerPt)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Speed gauge (right column)

/// 시뮬레이터 cockpit 의 속도계 — forward / lateral / turn 각각 vertical bar
/// 로 표시. mm/sec / deg/sec 단위로 사용자에게 즉각 속도감 제공.
///
/// **방법론**: FPV/비행 시뮬레이터의 vertical strip gauge — 시야 가장자리에
/// 두어 메인 scene 방해 X. 막대 + monospace digit readout 조합으로 변화량과
/// 절대값을 동시에 인지.
struct CockpitSpeedGauge: View {
    let forwardMmPerSec: Double
    let lateralMmPerSec: Double
    let turnDegPerSec: Double
    /// Peak-hold marker — 최근 1초 내 최대 forward 속도. bar 위 작은 tick 으로 표시.
    let peakForwardMmPerSec: Double

    private let maxForward: Double = 200       // visual full-scale
    private let maxLateral: Double = 100
    private let maxTurn: Double = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPEED")
                .font(.system(size: CockpitMetrics.sectionHeader, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
            bar(label: "FWD",
                value: forwardMmPerSec,
                fullScale: maxForward,
                unit: "mm/s",
                tint: CockpitColors.live,
                peak: peakForwardMmPerSec)
            bar(label: "LAT",
                value: lateralMmPerSec,
                fullScale: maxLateral,
                unit: "mm/s",
                tint: CockpitColors.cyan)
            bar(label: "TURN",
                value: turnDegPerSec,
                fullScale: maxTurn,
                unit: "°/s",
                tint: CockpitColors.warn)
        }
        .cockpitPanel(tint: CockpitColors.live, strokeOpacity: 0.25)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(label: String, value: Double,
                     fullScale: Double, unit: String,
                     tint: Color,
                     peak: Double = 0) -> some View {
        let magnitude = abs(value)
        let fraction = min(1.0, magnitude / fullScale)
        let peakFraction = min(1.0, peak / fullScale)
        let isReverse = value < 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("\(isReverse ? "−" : "+")\(Int(magnitude)) \(unit)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(magnitude < 1 ? .white.opacity(0.4) : tint)
                if peak > 1 {
                    Text("⟂\(Int(peak))")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.65))
                }
            }
            // Bipolar bar — centre line, fill outward + peak-hold marker.
            GeometryReader { geo in
                let w = geo.size.width
                let centre = w / 2
                let half = w / 2 - 2
                let fillW = CGFloat(fraction) * half
                let peakW = CGFloat(peakFraction) * half
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.08))
                    // Centre tick
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1)
                        .position(x: centre, y: 4)
                    // Peak-hold tick (forward only — 비대칭 OK since peak >= 0).
                    if peakW > 0 {
                        Rectangle()
                            .fill(tint.opacity(0.7))
                            .frame(width: 2, height: 8)
                            .position(x: centre + peakW, y: 4)
                    }
                    Rectangle()
                        .fill(tint)
                        .frame(width: fillW, height: 4)
                        .position(x: isReverse ? centre - fillW / 2 : centre + fillW / 2,
                                  y: 4)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Command readout (centre bottom)

struct CockpitCommandReadout: View {
    let command: WalkingCommand
    let speedScale: Double
    let source: InputSource

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("INPUT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Text(source.label.uppercased())
                    .font(.system(size: CockpitMetrics.commandValue, weight: .bold, design: .monospaced))
                    .foregroundStyle(CockpitColors.live)
            }
            Divider().frame(height: 28).overlay(CockpitColors.live.opacity(0.3))
            metric("FWD",
                   value: String(format: "%+.1f mm", command.strideMm),
                   tone: command.strideMm == 0 ? .idle : .live)
            metric("LAT",
                   value: String(format: "%+.1f mm", command.sideMm),
                   tone: command.sideMm == 0 ? .idle : .live)
            metric("TURN",
                   value: String(format: "%+.1f°", command.turnDeg),
                   tone: command.turnDeg == 0 ? .idle : .live)
            Divider().frame(height: 28).overlay(CockpitColors.live.opacity(0.3))
            metric("SCALE",
                   value: String(format: "×%.2f", speedScale),
                   tone: .cyan)
        }
        .cockpitPanel(tint: CockpitColors.live, strokeOpacity: 0.4)
    }

    private enum MetricTone { case live, idle, cyan }
    private func metric(_ label: String, value: String, tone: MetricTone) -> some View {
        let color: Color = {
            switch tone {
            case .live:   return CockpitColors.live
            case .idle:   return Color.white.opacity(0.45)
            case .cyan:   return CockpitColors.cyan
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}
