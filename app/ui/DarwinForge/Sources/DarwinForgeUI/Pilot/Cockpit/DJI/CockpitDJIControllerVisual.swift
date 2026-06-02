import SwiftUI

#if canImport(IOKit)

/// **방법론 (Logitech G HUB + Razer Synapse + DJI Fly UI 참조)**:
///
/// DJI controller mapping UI 의 핵심 가치는 **(1) 사실적 representation**, **(2) 실
/// 시간 상태 시각화**, **(3) inline 매핑 인터랙션** 3 가지. 본 컴포넌트는 SwiftUI
/// Path/Shape 만으로 photorealistic asset 없이 이 3 가지를 모두 충족.
///
/// # 구성 요소
///
/// - **Controller body**: 가로형 game-pad 실루엣. LinearGradient 로 dark plastic 질
///   감. 외곽 stroke 로 hairline highlight.
/// - **Stick wells**: 2 개 concentric circle stack — 외곽 recess (어두운 가장자리) +
///   colored glow ring (좌=cyan/teal, 우=blue) + 내부 stick body + 실시간 indicator
///   dot.
/// - **DJI 로고**: 본체 상단 중앙 monospaced text — 가시 정체성.
/// - **Center cluster**: C1 / 휠 / 전원 3 개 control 버튼 — RC-N1 기준 layout.
/// - **콜아웃 라벨 (DJI Fly UI 패턴)**: 본체 위/아래로 dashed line 으로 라벨 연결.
///   사용자가 어떤 control 이 어떤 입력인지 즉시 파악.
/// - **번호 버튼 row**: 8 개 button 의 grid. 매핑된 action label 도 표시.
/// - **범례 (Legend)**: 색상 → 상태 매핑 설명 (미매핑/매핑됨/선택/활성).
///
/// # 실시간 상태 표현
///
/// - axis ≥ deadzone (0.30) → glow ring opacity 증가 + indicator dot 강조 + scale 1.1.
/// - button pressed → fill = accent + scale 0.95 (haptic press 시각 모방).
/// - selected (inspector 에서 선택된 binding) → element 외곽선 accent + 백색 글로우.
///
/// # 매핑 인터랙션
///
/// - element 를 클릭 (axis hotspot 또는 button) → `onTap` callback 에 binding 전달.
/// - 상위 sheet 가 `selectedAction` 에 binding 적용. 결과는 chip badge 로 즉시 반영.
@MainActor
struct CockpitDJIControllerVisual: View {

    let report: DJIVirtualJoystickReport?
    let profile: DJIBindingProfile
    let onTap: (DJIInputBinding) -> Void
    /// 현재 사용자가 매핑 작업 중인 action — element 가 그 action 에 mapped 면 강조.
    let selectedAction: CockpitAction?
    /// Inspector 에서 현재 선택된 binding — 해당 element 에 accent ring + glow 강조.
    let selectedBinding: DJIInputBinding?

    /// listen mode 와 같은 threshold — element glow 의 활성 기준.
    private let activeDeadzone: Double = 0.30

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controllerCard
            buttonsSection
            legend
        }
        .accessibilityIdentifier("cockpit.dji.controller.visual")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("DJI 조종기")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(report == nil ? Color.secondary.opacity(0.5) : Color.green)
                .frame(width: 6, height: 6)
                .shadow(color: report == nil ? .clear : Color.green.opacity(0.7),
                        radius: report == nil ? 0 : 3)
            Text(report == nil ? "오프라인" : "실시간")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controller card (body + callouts)

    private var controllerCard: some View {
        ZStack {
            // Card background
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1))

            // Controller illustration + callouts
            controllerWithCallouts
                .padding(.vertical, 18)
        }
        .frame(height: 320)
    }

    /// 컨트롤러 본체 + 콜아웃 라벨/라인 합성.
    private var controllerWithCallouts: some View {
        ZStack {
            // Body in center
            controllerBody
                .frame(width: 340, height: 175)

            // Top callouts: 좌 스틱 + 우 스틱
            topCallouts

            // Bottom callouts: C1 / 휠 / 전원
            bottomCallouts
        }
    }

    // MARK: - Controller body

    private var controllerBody: some View {
        ZStack {
            // Main shell (gamepad silhouette)
            controllerShell

            // Subtle inset accent line
            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                .frame(width: 320, height: 155)

            // DJI logo center top
            Text("DJI")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .tracking(2)
                .foregroundStyle(Color.white.opacity(0.55))
                .offset(y: -34)

            // Stick wells
            HStack(spacing: 134) {
                stickWell(
                    xAxis: .x, yAxis: .y,
                    xValue: report?.axisX ?? 0,
                    yValue: report?.axisY ?? 0,
                    glowColor: Color.cyan)
                stickWell(
                    xAxis: .rx, yAxis: .ry,
                    xValue: report?.axisRx ?? 0,
                    yValue: report?.axisRy ?? 0,
                    glowColor: Color.blue)
            }
            .offset(y: 5)

            // Center cluster: C1 / wheel / power
            centerCluster
                .offset(y: 50)
        }
    }

    /// 메인 셸 — gradient body + 외곽 highlight.
    ///
    /// **퍼포먼스**: 이 그룹은 정적 (binding 상태와 무관). HID stream 으로 매 frame
    /// rerender 되지만 시각 결과는 동일. `.drawingGroup()` 로 Metal 텍스처 캐시 —
    /// shell + antennas 합쳐 한 번만 rasterize 후 같은 텍스처 재사용. 다크모드 전환
    /// 시에만 invalidate. 또한 이전의 `.blur(radius: 14)` 그림자 (raster filter,
    /// GPU 비싼 연산) 를 제거하고 단일 `.shadow` modifier 만 사용.
    private var controllerShell: some View {
        ZStack {
            // Top antennas (small nubs)
            HStack(spacing: 230) {
                antennaNub
                antennaNub
            }
            .offset(y: -85)

            // Main shell — `.shadow` modifier 만 사용 (blur 제거).
            RoundedRectangle(cornerRadius: 36)
                .fill(LinearGradient(
                    colors: [Color(white: 0.32), Color(white: 0.18)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 340, height: 175)
                .overlay(
                    RoundedRectangle(cornerRadius: 36)
                        .stroke(LinearGradient(
                            colors: [Color.white.opacity(0.20),
                                     Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom),
                                lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .drawingGroup()
    }

    private var antennaNub: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(
                colors: [Color(white: 0.25), Color(white: 0.15)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: 18, height: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: - Stick well

    private func stickWell(xAxis: DJIInputBinding.Axis,
                            yAxis: DJIInputBinding.Axis,
                            xValue: Double, yValue: Double,
                            glowColor: Color) -> some View {
        let isActiveX = abs(xValue) >= activeDeadzone
        let isActiveY = abs(yValue) >= activeDeadzone
        let isActive = isActiveX || isActiveY
        let maxOffset: CGFloat = 18

        return ZStack {
            // Outer recess
            Circle()
                .fill(LinearGradient(
                    colors: [Color.black.opacity(0.45),
                             Color.black.opacity(0.25)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 72, height: 72)

            // Glow ring (colored identity)
            Circle()
                .stroke(glowColor.opacity(isActive ? 0.95 : 0.55),
                        lineWidth: 2.5)
                .frame(width: 64, height: 64)
                .shadow(color: glowColor.opacity(isActive ? 0.7 : 0.3),
                        radius: isActive ? 8 : 4)

            // Inner stick body (dark plastic)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(white: 0.18), Color(white: 0.05)],
                    center: .center, startRadius: 0, endRadius: 24))
                .frame(width: 48, height: 48)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        .frame(width: 48, height: 48))

            // Position indicator dot — 직접 추적 (animation 없음).
            //
            // **퍼포먼스**: HID input 이 이미 60Hz throttled 로 부드러운 stream.
            // spring smoothing 은 spring math 를 매 animation frame 마다 돌리고
            // (60 FPS × 0.18s decay), 실제로는 latency 만 add (60Hz 입력 → spring
            // 으로 평균 90ms latency). 직접 binding 이 더 빠르고 시각도 동일.
            Circle()
                .fill(isActive ? glowColor : Color.white.opacity(0.35))
                .frame(width: 10, height: 10)
                .offset(x: CGFloat(xValue) * maxOffset,
                        y: CGFloat(-yValue) * maxOffset)
                .shadow(color: isActive ? glowColor : .clear,
                        radius: isActive ? 4 : 0)
                .allowsHitTesting(false)

            // 4 directional hotspots — clickable rims for mapping
            directionalHotspots(xAxis: xAxis, yAxis: yAxis,
                                 xValue: xValue, yValue: yValue,
                                 isActiveX: isActiveX, isActiveY: isActiveY,
                                 glowColor: glowColor)
        }
    }

    private func directionalHotspots(
        xAxis: DJIInputBinding.Axis,
        yAxis: DJIInputBinding.Axis,
        xValue: Double, yValue: Double,
        isActiveX: Bool, isActiveY: Bool,
        glowColor: Color
    ) -> some View {
        let r: CGFloat = 47

        return ZStack {
            // Up
            hotspot(binding: .axis(yAxis, polarity: .positive),
                     isActive: isActiveY && yValue > 0,
                     glow: glowColor)
                .offset(y: -r)
            // Down
            hotspot(binding: .axis(yAxis, polarity: .negative),
                     isActive: isActiveY && yValue < 0,
                     glow: glowColor)
                .offset(y: r)
            // Left
            hotspot(binding: .axis(xAxis, polarity: .negative),
                     isActive: isActiveX && xValue < 0,
                     glow: glowColor)
                .offset(x: -r)
            // Right
            hotspot(binding: .axis(xAxis, polarity: .positive),
                     isActive: isActiveX && xValue > 0,
                     glow: glowColor)
                .offset(x: r)
        }
    }

    private func hotspot(binding: DJIInputBinding,
                          isActive: Bool,
                          glow: Color) -> some View {
        let mappedAction = actionFor(binding)
        let isInspectorSelected = selectedBinding == binding
        let isActionTarget = selectedAction != nil && mappedAction == selectedAction
        let isMapped = mappedAction != nil

        return Button {
            onTap(binding)
        } label: {
            ZStack {
                Circle()
                    .fill(hotspotFill(isActive: isActive,
                                       isInspectorSelected: isInspectorSelected,
                                       isActionTarget: isActionTarget,
                                       isMapped: isMapped))
                    .frame(width: 18, height: 18)
                Circle()
                    .stroke(hotspotStroke(isActive: isActive,
                                           isInspectorSelected: isInspectorSelected,
                                           isActionTarget: isActionTarget),
                            lineWidth: (isActive || isInspectorSelected) ? 1.5 : 0.5)
                    .frame(width: 18, height: 18)
            }
            .shadow(color: isActive ? glow.opacity(0.6) : .clear,
                    radius: isActive ? 6 : 0)
            .scaleEffect(isActive ? 1.18 : (isInspectorSelected ? 1.10 : 1.0))
            // **퍼포먼스**: 단축 0.22s → 0.12s. boolean state 전환이라
            // 연속 spring 누적 없음. 짧은 transition 으로 응답성 ↑.
            .animation(.spring(response: 0.12), value: isActive)
        }
        .buttonStyle(.plain)
        .help(elementHelp(binding: binding, mapped: mappedAction))
    }

    // MARK: - Center cluster (C1 / Wheel / Power)

    private var centerCluster: some View {
        HStack(spacing: 14) {
            clusterButton(binding: .button(2), label: "C1",
                          icon: nil, hint: "Custom 1")
            wheelButton
            clusterButton(binding: .button(3), label: nil,
                          icon: "power", hint: "Power 버튼")
        }
    }

    private func clusterButton(binding: DJIInputBinding,
                                label: String?,
                                icon: String?,
                                hint: String) -> some View {
        let isPressed: Bool = {
            if case .button(let idx) = binding {
                return report?.buttons[safe: idx] ?? false
            }
            return false
        }()
        let mappedAction = actionFor(binding)
        let isInspectorSelected = selectedBinding == binding
        let isActionTarget = selectedAction != nil && mappedAction == selectedAction
        let isMapped = mappedAction != nil

        return Button {
            onTap(binding)
        } label: {
            ZStack {
                Circle()
                    .fill(elementFill(isPressed: isPressed,
                                       isInspectorSelected: isInspectorSelected,
                                       isActionTarget: isActionTarget,
                                       isMapped: isMapped))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle()
                            .stroke(elementStroke(isPressed: isPressed,
                                                    isInspectorSelected: isInspectorSelected,
                                                    isActionTarget: isActionTarget),
                                    lineWidth: isPressed ? 1.5 : 0.5))
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(elementForeground(isPressed: isPressed,
                                                             isInspectorSelected: isInspectorSelected,
                                                             isActionTarget: isActionTarget))
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(elementForeground(isPressed: isPressed,
                                                             isInspectorSelected: isInspectorSelected,
                                                             isActionTarget: isActionTarget))
                }
            }
            .shadow(color: isPressed ? Color.accentColor.opacity(0.6) : .clear,
                    radius: isPressed ? 5 : 0)
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.12), value: isPressed)
        }
        .buttonStyle(.plain)
        .help("\(hint) — " + elementHelp(binding: binding, mapped: mappedAction))
    }

    /// Z 휠 — drum-style wheel 시각화. Z axis 의 + / - 두 영역을 별도 클릭 가능.
    private var wheelButton: some View {
        VStack(spacing: 2) {
            wheelHalf(polarity: .positive, symbol: "plus")
            wheelHalf(polarity: .negative, symbol: "minus")
        }
        .help("카메라 휠 — 위/아래 절반을 각각 매핑 가능")
    }

    private func wheelHalf(polarity: DJIInputBinding.Polarity,
                            symbol: String) -> some View {
        let binding: DJIInputBinding = .axis(.z, polarity: polarity)
        let value = report?.axisZ ?? 0
        let isActive: Bool = {
            if polarity == .positive { return value >= activeDeadzone }
            return value <= -activeDeadzone
        }()
        let mappedAction = actionFor(binding)
        let isInspectorSelected = selectedBinding == binding
        let isActionTarget = selectedAction != nil && mappedAction == selectedAction
        let isMapped = mappedAction != nil

        return Button {
            onTap(binding)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(elementFill(isPressed: isActive,
                                       isInspectorSelected: isInspectorSelected,
                                       isActionTarget: isActionTarget,
                                       isMapped: isMapped))
                    .frame(width: 24, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(elementStroke(isPressed: isActive,
                                                    isInspectorSelected: isInspectorSelected,
                                                    isActionTarget: isActionTarget),
                                    lineWidth: isActive ? 1.5 : 0.5))
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(elementForeground(isPressed: isActive,
                                                         isInspectorSelected: isInspectorSelected,
                                                         isActionTarget: isActionTarget))
            }
            .shadow(color: isActive ? Color.accentColor.opacity(0.6) : .clear,
                    radius: isActive ? 4 : 0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Callouts (top: 스틱, bottom: C1/휠/전원)

    private var topCallouts: some View {
        ZStack {
            // 좌 스틱 callout
            calloutLabel(title: "좌 스틱",
                         subtitle: "Yaw / Throttle",
                         alignment: .leading)
                .offset(x: -100, y: -130)
            calloutLine(start: CGPoint(x: -100, y: -110),
                        end:   CGPoint(x: -67,  y: -34))

            // 우 스틱 callout
            calloutLabel(title: "우 스틱",
                         subtitle: "Roll / Pitch",
                         alignment: .trailing)
                .offset(x: 100, y: -130)
            calloutLine(start: CGPoint(x: 100, y: -110),
                        end:   CGPoint(x: 67,  y: -34))
        }
    }

    private var bottomCallouts: some View {
        ZStack {
            // C1 callout
            calloutSmallLabel(title: "C1",
                              status: bindingStatusLabel(for: .button(2)))
                .offset(x: -50, y: 105)
            calloutLine(start: CGPoint(x: -50, y: 85),
                        end:   CGPoint(x: -18, y: 62))

            // 휠 callout
            calloutSmallLabel(title: "휠",
                              status: bindingStatusLabel(for: .axis(.z, polarity: .positive)))
                .offset(x: 0, y: 105)
            calloutLine(start: CGPoint(x: 0, y: 85),
                        end:   CGPoint(x: 0, y: 62))

            // 전원 callout
            calloutSmallLabel(title: "전원",
                              status: bindingStatusLabel(for: .button(3)))
                .offset(x: 50, y: 105)
            calloutLine(start: CGPoint(x: 50, y: 85),
                        end:   CGPoint(x: 18, y: 62))
        }
    }

    /// 상단 stick 라벨 — 큰 제목 + 부제.
    private func calloutLabel(title: String,
                              subtitle: String,
                              alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    /// 하단 control 라벨 — 작은 chip.
    private func calloutSmallLabel(title: String, status: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            Text(status)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 36)
    }

    /// Dashed connector line.
    private func calloutLine(start: CGPoint, end: CGPoint) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 0.7, dash: [2.5, 2.5]))
        .frame(width: 1, height: 1)  // path uses absolute coords; tiny frame
        .allowsHitTesting(false)
    }

    // MARK: - Number button row (1..8)

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("번호 버튼")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { idx in
                    numberButton(idx: idx)
                }
            }
        }
    }

    private func numberButton(idx: Int) -> some View {
        let binding: DJIInputBinding = .button(idx)
        let isPressed = report?.buttons[safe: idx] ?? false
        let mappedAction = actionFor(binding)
        let isInspectorSelected = selectedBinding == binding
        let isActionTarget = selectedAction != nil && mappedAction == selectedAction
        let isMapped = mappedAction != nil

        return Button {
            onTap(binding)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(elementFill(isPressed: isPressed,
                                           isInspectorSelected: isInspectorSelected,
                                           isActionTarget: isActionTarget,
                                           isMapped: isMapped))
                        .frame(width: 46, height: 46)
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(elementStroke(isPressed: isPressed,
                                                isInspectorSelected: isInspectorSelected,
                                                isActionTarget: isActionTarget),
                                lineWidth: isPressed ? 2 : 0.5)
                        .frame(width: 46, height: 46)
                    Text("\(idx + 1)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(elementForeground(isPressed: isPressed,
                                                             isInspectorSelected: isInspectorSelected,
                                                             isActionTarget: isActionTarget))
                }
                .shadow(color: isPressed ? Color.accentColor.opacity(0.7) : .clear,
                        radius: isPressed ? 6 : 0)
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.spring(response: 0.12), value: isPressed)
                Text(mappedAction?.label ?? "미매핑")
                    .font(.system(size: 9))
                    .foregroundStyle(mappedAction == nil
                                     ? Color.secondary.opacity(0.6)
                                     : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 50)
            }
        }
        .buttonStyle(.plain)
        .help(elementHelp(binding: binding, mapped: mappedAction))
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: Color.secondary.opacity(0.20),
                       text: "미매핑")
            legendItem(color: Color.green,
                       text: "매핑됨", isCircle: true)
            legendItem(color: Color.accentColor.opacity(0.75),
                       text: "선택")
            legendItem(color: Color.accentColor,
                       text: "활성", glow: true)
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, text: String,
                             isCircle: Bool = false,
                             glow: Bool = false) -> some View {
        HStack(spacing: 5) {
            Group {
                if isCircle {
                    Circle().fill(color).frame(width: 8, height: 8)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 10, height: 10)
                }
            }
            .shadow(color: glow ? color.opacity(0.7) : .clear,
                    radius: glow ? 3 : 0)
            Text(text)
        }
    }

    // MARK: - Element styling helpers

    private func hotspotFill(isActive: Bool,
                              isInspectorSelected: Bool,
                              isActionTarget: Bool,
                              isMapped: Bool) -> Color {
        if isActive { return Color.accentColor }
        if isInspectorSelected { return Color.accentColor.opacity(0.85) }
        if isActionTarget { return Color.accentColor.opacity(0.55) }
        if isMapped { return Color.green.opacity(0.45) }
        return Color.white.opacity(0.12)
    }

    private func hotspotStroke(isActive: Bool,
                                isInspectorSelected: Bool,
                                isActionTarget: Bool) -> Color {
        if isActive || isInspectorSelected || isActionTarget {
            return Color.accentColor
        }
        return Color.white.opacity(0.25)
    }

    private func elementFill(isPressed: Bool,
                              isInspectorSelected: Bool,
                              isActionTarget: Bool,
                              isMapped: Bool) -> Color {
        if isPressed { return Color.accentColor }
        if isInspectorSelected { return Color.accentColor.opacity(0.85) }
        if isActionTarget { return Color.accentColor.opacity(0.50) }
        if isMapped { return Color.green.opacity(0.30) }
        return Color.white.opacity(0.10)
    }

    private func elementStroke(isPressed: Bool,
                                isInspectorSelected: Bool,
                                isActionTarget: Bool) -> Color {
        if isPressed || isInspectorSelected || isActionTarget {
            return Color.accentColor
        }
        return Color.white.opacity(0.20)
    }

    private func elementForeground(isPressed: Bool,
                                    isInspectorSelected: Bool,
                                    isActionTarget: Bool) -> Color {
        if isPressed || isInspectorSelected || isActionTarget {
            return Color.white
        }
        return Color.white.opacity(0.65)
    }

    // MARK: - Helpers

    private func actionFor(_ binding: DJIInputBinding) -> CockpitAction? {
        if case .unbound = binding { return nil }
        return profile.bindings.first { $0.value == binding }?.key
    }

    private func bindingStatusLabel(for binding: DJIInputBinding) -> String {
        actionFor(binding)?.label ?? "미매핑"
    }

    private func elementHelp(binding: DJIInputBinding,
                              mapped: CockpitAction?) -> String {
        let label: String
        switch binding {
        case .axis(let ax, let pol):
            label = "\(ax.label) \(pol.rawValue) (\(ax.humanDescription))"
        case .button(let idx):
            label = "Button \(idx + 1)"
        case .unbound:
            label = "—"
        }
        if let m = mapped {
            return "\(label) → 현재 매핑: \(m.label).\n클릭하면 선택된 동작에 재할당."
        }
        return "\(label) — 매핑되지 않음.\n선택된 동작이 있으면 클릭으로 할당."
    }
}

// MARK: - Equatable conformance for SwiftUI .equatable() diff

/// **퍼포먼스**: closure prop (`onTap`) 때문에 Swift 가 Equatable 자동 합성 불가.
/// 수동 conformance 로 `report` / `profile` / `selectedAction` / `selectedBinding`
/// 만 비교 — closure 는 무시. SwiftUI 의 `.equatable()` 가 이 == 를 사용해서 동일
/// 값일 때 visual body 건너뜀.
///
/// 본 conformance 의 효과: 부모 column 의 body 가 parent 의 `@ObservedObject` 변
/// 화로 100Hz reeval 되어도, throttle 된 `state.report` 는 60Hz 만 바뀐다 (40Hz 의
/// 추가 reeval 은 동일값). `.equatable()` 가 이 동일값을 잡아 visual body 를 그
/// 사이에 skip — 최종 visual rerender 횟수가 60 / 초 로 캡.
extension CockpitDJIControllerVisual: Equatable {
    nonisolated static func == (lhs: CockpitDJIControllerVisual,
                                 rhs: CockpitDJIControllerVisual) -> Bool {
        return lhs.report == rhs.report
            && lhs.profile == rhs.profile
            && lhs.selectedAction == rhs.selectedAction
            && lhs.selectedBinding == rhs.selectedBinding
        // `onTap` (closure) 은 의도적으로 비교 제외.
    }
}

// MARK: - Safe array indexing

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#endif
