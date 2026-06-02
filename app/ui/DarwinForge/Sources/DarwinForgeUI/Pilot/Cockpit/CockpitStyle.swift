import SwiftUI

/// **조종 시뮬 HUD — macOS 머티리얼 네이티브 리스타일 (2026-05-31)**.
///
/// 코크핏 오버레이의 **단일 스타일 출처**. FPV 네온 HUD 정체성(상태색·계기)은 유지하되,
/// 패널 배경을 macOS 반투명 머티리얼(SwiftUI `.ultraThinMaterial` + 다크 HUD 틴트)로,
/// 시각 요소를 한 단계 키우고, 토글을 일관 정렬한다.
///
/// # 머티리얼 방법론 (리뷰 H1 반영)
///
/// SwiftUI 머티리얼은 **뒤 콘텐츠를 반투명하게 비치지만**, 3D `SCNView`(Metal 레이어)는
/// 시스템 합성상 **블러로 샘플되지 않는다**. 따라서 "유리 너머 3D가 블러된다"가 아니라
/// "다크 반투명 글래스 위에 HUD 정보" 가 실제 결과다(`.hudWindow` NSVisualEffectView 역시
/// 동일 한계 → 더 단순·신뢰성 높은 SwiftUI 머티리얼 채택). 다크 틴트를 깔아 밝은 3D가
/// 텍스트 뒤로 비쳐 대비가 떨어지는 것을 방지한다.
///
/// # 비유
///
/// 검정 시트지 계기판 → 다크 반투명 글래스 계기판. 글자가 커지고, 스위치가 가지런해진다.

// MARK: - 크기 상수 (절제된 +1단계)

public enum CockpitMetrics {
    // 패널
    public static let panelRadius: CGFloat = 12
    public static let panelPadding: CGFloat = 14
    public static let panelSpacing: CGFloat = 8
    public static let panelStrokeOpacity: Double = 0.32
    /// 머티리얼 위 다크 HUD 틴트(가독성 floor — 밝은 3D 가 텍스트 뒤로 비치지 않게).
    public static let panelTintOpacity: Double = 0.34
    // 폰트
    public static let pillLabel: CGFloat = 11
    public static let pillValue: CGFloat = 13
    public static let sectionHeader: CGFloat = 11
    public static let sectionLabel: CGFloat = 9
    public static let commandLabel: CGFloat = 10
    public static let commandValue: CGFloat = 15
    public static let toggleLabel: CGFloat = 11
    public static let bannerText: CGFloat = 12
    // 프레임 (full)
    public static let horizon: CGFloat = 116
    public static let compassH: CGFloat = 26
    public static let joystick: CGFloat = 160
    public static let keyCap: CGFloat = 38
    public static let keyCapWide: CGFloat = 58
    public static let safetyButtonW: CGFloat = 150
    public static let safetyButtonH: CGFloat = 44
    public static let columnMin: CGFloat = 224
    public static let columnMax: CGFloat = 264
    // 점/그림자
    public static let statusDot: CGFloat = 8
    public static let shadowRadius: CGFloat = 10
    public static let shadowY: CGFloat = 4

    // 반응형 bottom bar (좁은 창에서 오버플로 방지 — 리뷰 H1 반응형)
    /// 폭 < 900pt 이면 컨트롤을 한 단계 축소.
    public static func narrow(_ width: CGFloat) -> Bool { width < 900 }
    public static func joystickSize(_ width: CGFloat) -> CGFloat { narrow(width) ? 132 : joystick }
    public static func safetyW(_ width: CGFloat) -> CGFloat { narrow(width) ? 122 : safetyButtonW }
    public static func safetyH(_ width: CGFloat) -> CGFloat { narrow(width) ? 38 : safetyButtonH }
    public static func bottomGap(_ width: CGFloat) -> CGFloat { narrow(width) ? 12 : 18 }
}

// MARK: - 패널 모디파이어 (.cockpitPanel)

/// 코크핏 패널 공통 배경: 반투명 머티리얼(접근성 `reduceTransparency` ON 시 solid 폴백) +
/// 다크 HUD 틴트 + 라운드 + 네온 stroke + 부드러운 그림자. 반복되던
/// `RoundedRectangle(8).fill(panel).stroke(...)` 패턴을 전부 대체한다.
struct CockpitPanelModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let stroke: Color
    let strokeOpacity: Double
    let radius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .padding(padding)
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(CockpitColors.panelSolid)
                    } else {
                        // 진짜 반투명 글래스(뒤 다크 씬이 비침) + 다크 틴트로 가독성 floor 확보.
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.black.opacity(CockpitMetrics.panelTintOpacity))
                    }
                }
            }
            .overlay { shape.stroke(stroke.opacity(strokeOpacity), lineWidth: 1) }
            .shadow(color: .black.opacity(0.25),
                    radius: CockpitMetrics.shadowRadius, x: 0, y: CockpitMetrics.shadowY)
    }
}

extension View {
    /// 코크핏 패널 배경(머티리얼 + 네온 stroke + 그림자). `tint` 은 stroke 색(상태별 네온).
    func cockpitPanel(
        tint: Color = CockpitColors.live,
        strokeOpacity: Double = CockpitMetrics.panelStrokeOpacity,
        radius: CGFloat = CockpitMetrics.panelRadius,
        padding: CGFloat = CockpitMetrics.panelPadding
    ) -> some View {
        modifier(CockpitPanelModifier(
            stroke: tint, strokeOpacity: strokeOpacity, radius: radius, padding: padding))
    }
}
