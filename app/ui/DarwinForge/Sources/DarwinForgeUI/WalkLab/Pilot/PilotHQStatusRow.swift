import SwiftUI
import Observation

/// **v1.22.0 (2026-05-22) — 사이클 78: Pilot HQ 통합 status row**.
///
/// 5 panel 이 vertical stack 으로 길게 늘어선 pilotOverlay 의 상단에 위치하는 한 줄 요약.
/// 사용자가 어떤 source 가 active / 정지 / emergency 인지 한 눈에 파악 가능.
///
/// # 비유
///
/// 비행기 cockpit 의 primary flight display — altitude / airspeed / heading 을 한 화면에.
/// 본 status row 는 (마지막 active source / total event rate / emergency 상태 / bridge
/// 활성) 4개 핵심 신호를 한 줄로.
///
/// # 표시 항목
///
/// 1. **emergency 인디케이터**: 발생 시 빨간색 펄스 (animation), 아닐 시 정상 dot.
/// 2. **마지막 active source**: 5 source 중 가장 최근 intent 가 어느 source 였는지 + icon.
/// 3. **event rate**: 최근 1초 동안 events/s (eventsPerSecond accumulator metric).
/// 4. **bridge 활성**: enabled 인지 disabled 인지 토글 표시.
///
/// # 비활성 갱신
///
/// View 가 `@Observable` bridge 의 변경을 자동 react — 별도 Timer 불요.
/// eventsPerSecond 는 caller view 가 1Hz refresh 권장 (HUD 와 동일 패턴).
@MainActor
public struct PilotHQStatusRow: View {

    let bridge: WalkLabRCBridge
    let session: WalkLabSession

    /// **테스트 / preview** — 외부에서 nowTick 주입 가능 (eventsPerSecond 계산 결정론).
    var now: Date = Date()

    public init(bridge: WalkLabRCBridge, session: WalkLabSession) {
        self.bridge = bridge
        self.session = session
    }

    public var body: some View {
        HStack(spacing: DFSpace.sm) {
            emergencyIndicator
            Divider().frame(height: 14)
            activeSourceLabel
            Divider().frame(height: 14)
            eventRateLabel
            Spacer(minLength: 4)
            bridgeEnabledIndicator
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, 5)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(rowBorderColor, lineWidth: 1)
        )
    }

    // MARK: - Subviews

    /// emergency 상태 dot + 라벨. emergency 일 때 빨강색 + 펄스 effect.
    private var emergencyIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.emergencyStopActive ? DFColor.danger : DFColor.success)
                .frame(width: 8, height: 8)
            Text(session.emergencyStopActive ? "비상" : "정상")
                .font(.caption2.weight(.medium))
                .foregroundStyle(session.emergencyStopActive ? DFColor.danger : DFColor.textSecondary)
        }
    }

    /// 가장 최근 active source — `bridge.lastIntent?.source` 표시.
    /// nil 시 "대기".
    private var activeSourceLabel: some View {
        HStack(spacing: 4) {
            if let source = bridge.lastIntent?.source {
                Image(systemName: source.icon)
                    .font(.caption2)
                    .foregroundStyle(DFColor.accent)
                Text(source.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(DFColor.textSecondary)
            } else {
                Image(systemName: "circle.dashed")
                    .font(.caption2)
                    .foregroundStyle(DFColor.textSecondary.opacity(0.6))
                Text("대기")
                    .font(.caption2)
                    .foregroundStyle(DFColor.textSecondary.opacity(0.6))
            }
        }
    }

    /// events/s — 사용자가 입력 활동 강도 파악.
    /// 0/s: 정지 / 1-5/s: 보통 / 6+/s: 활발 (색상 단계).
    private var eventRateLabel: some View {
        let rate = bridge.accumulator.eventsPerSecond(window: 1.0, now: now)
        return HStack(spacing: 4) {
            Image(systemName: "waveform.path")
                .font(.caption2)
                .foregroundStyle(rateColor(rate))
            Text(String(format: "%.0f/s", rate))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    /// bridge enabled 토글 — `bridge.enabled` 시각화.
    private var bridgeEnabledIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: bridge.enabled ? "bolt.fill" : "bolt.slash")
                .font(.caption2)
                .foregroundStyle(bridge.enabled ? DFColor.accent : DFColor.textSecondary.opacity(0.6))
            Text(bridge.enabled ? "활성" : "비활성")
                .font(.caption2.weight(.medium))
                .foregroundStyle(bridge.enabled ? DFColor.textSecondary : DFColor.textSecondary.opacity(0.6))
        }
    }

    // MARK: - Styling

    /// emergency 상태별 배경 — 비상 시 빨간 tint 로 즉시 시각 인지.
    private var rowBackground: Color {
        if session.emergencyStopActive {
            return DFColor.danger.opacity(0.08)
        }
        return DFColor.card.opacity(0.6)
    }

    private var rowBorderColor: Color {
        if session.emergencyStopActive {
            return DFColor.danger.opacity(0.4)
        }
        return DFColor.textSecondary.opacity(0.2)
    }

    /// event rate 색상 단계 — 0 회색 / 1-5 보통 / 6+ 활발.
    private func rateColor(_ rate: Double) -> Color {
        if rate < 0.1 { return DFColor.textSecondary.opacity(0.5) }
        if rate < 6 { return DFColor.textSecondary }
        return DFColor.accent
    }
}
