import SwiftUI

/// **DFSourcePill** — 데이터 출처 표시 pill (sim / real / stale 등).
///
/// 본 component 는 2026-05-16 monitoring dashboard 의 source pill 패턴을 일반화.
/// 사용 가능 영역:
/// - WalkLab fall prevention monitor (IMU / motor 데이터 source)
/// - Pilot diagnostic (telemetry source)
/// - Studio (서버 / 로컬 모션 source)
///
/// # UX 레퍼런스
///
/// - **Philips IntelliVue MX800** *User Guide* (2019): "fresh vs stale" data
///   indicator pattern — 데이터 source 의 신선도/출처를 monospace pill 로 표시.
/// - **Apple HIG** *Status indicators*: capsule + tint 배경 + monospaced label.
/// - **WCAG 2.2 §1.4.1**: 색 단독 정보 금지 — 라벨 + 색 함께.
///
/// # 사용
///
/// ```swift
/// DFSourcePill(label: "실 IMU", tint: DFColor.success)
/// DFSourcePill(label: "지연", tint: DFColor.warning, leading: "IMU")
/// ```
public struct DFSourcePill: View {
    public let label: String
    public let tint: Color
    /// 라벨 앞에 붙는 prefix (예: "IMU", "모터"). nil 이면 미표시.
    public let leading: String?

    /// pill 폰트 — 디자인 시스템 시맨틱 토큰 (`DFFont.pill` = 8pt medium mono).
    /// custom 폰트 override 가능 — `nil` 이면 system default `pill`.
    public let font: Font?

    public init(label: String, tint: Color, leading: String? = nil,
                font: Font? = nil) {
        self.label = label
        self.tint = tint
        self.leading = leading
        self.font = font
    }

    public var body: some View {
        let displayText: String = {
            if let leading {
                return "\(leading) \(label)"
            }
            return label
        }()
        return Text(displayText)
            .font(font ?? DFFont.pill)
            .foregroundStyle(tint)
            .padding(.horizontal, DFSpace.xs2 - 2)  // 4pt — 매우 좁은 pill 표준
            .padding(.vertical, 0.5)
            .background(tint.opacity(DFOpacity.o15))
            .clipShape(Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(leading.map { "\($0) 출처 \(label)" } ?? "출처 \(label)")
    }
}

#if DEBUG
struct DFSourcePill_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: DFSpace.sm) {
            DFSourcePill(label: "시뮬", tint: DFColor.textSecondary)
            DFSourcePill(label: "실 IMU", tint: DFColor.success, leading: "IMU")
            DFSourcePill(label: "지연", tint: DFColor.warning, leading: "모터")
        }
        .padding()
        .background(DFColor.canvas)
    }
}
#endif
