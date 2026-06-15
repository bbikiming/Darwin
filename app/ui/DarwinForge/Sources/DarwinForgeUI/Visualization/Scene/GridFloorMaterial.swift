import SceneKit
import SwiftUI

/// 안티앨리어싱 그리드 — **W2 2-B** (docs/design/3d-viewport-enhancement.md §4).
///
/// 비유: 실린더 막대 36개를 일일이 세우는 대신, 유리판 한 장에 "거리에 상관없이 늘
/// 같은 굵기로 보이는" 격자무늬를 인쇄해 바닥 위에 깐다. GPU 가 픽셀 단위로 라인을
/// 그리므로 멀어져도 모아레/시머링이 없다(fwidth AA).
///
/// **구현 경로(문서 권장)**: `SCNFloor` 는 무한 평면이라 texcoord 가 불안정 →
/// 40×40m `SCNPlane` 투명 오버레이에 fragment surface modifier 를 입힌다. zFar 60
/// 안에서 시각 차이 없음. 헤드리스 SCNRenderer 가 modifier 를 무시해도 plane 은
/// 투명(clear)이라 무해(바닥은 SCNFloor 가 그대로 보임).
///
/// 레거시 실린더 그리드는 `legacyGrid(style:)` 로 보존, `useShaderGrid` 한 줄로 전환.
enum GridFloorMaterial {
    /// 셰이더 그리드 사용 여부. false 면 실린더 그리드(레거시)로 폴백.
    static let useShaderGrid = true

    /// 오버레이 평면 한 변(m). zFar 60 안에서 충분.
    static let planeSize: CGFloat = 40

    /// 레거시 실린더 그리드 커버리지 반경(m) — 기존 makeGrid 와 동일.
    static let legacyHalf: CGFloat = 0.85

    /// 라인 픽셀 폭(fwidth 정규화 기준).
    static let lineWidthPx: CGFloat = 1.5

    static func makeGridNode(style: GridStyle) -> SCNNode {
        useShaderGrid ? makeShaderGrid(style: style) : legacyGrid(style: style)
    }

    // MARK: - 셰이더 그리드 (권장)

    static func makeShaderGrid(style: GridStyle) -> SCNNode {
        let plane = SCNPlane(width: planeSize, height: planeSize)
        let mat = SCNMaterial()
        mat.lightingModel = .constant          // 라인은 비조명 — 모든 preset 에서 일정하게.
        mat.diffuse.contents = NSColor.clear   // 라인 외엔 투명(바닥은 SCNFloor).
        mat.isDoubleSided = false
        mat.blendMode = .alpha
        mat.writesToDepthBuffer = false        // 투명 오버레이 — 바닥과 z-fight 방지.
        mat.readsFromDepthBuffer = true
        mat.shaderModifiers = [.surface: Self.surfaceShader]

        let rgb = style.color.sceneRGBTuple
        mat.setValue(NSNumber(value: Float(style.minorStep)), forKey: "minorStep")
        mat.setValue(NSNumber(value: Float(style.majorStep)), forKey: "majorStep")
        mat.setValue(NSNumber(value: Float(rgb.r)), forKey: "lineR")
        mat.setValue(NSNumber(value: Float(rgb.g)), forKey: "lineG")
        mat.setValue(NSNumber(value: Float(rgb.b)), forKey: "lineB")
        mat.setValue(NSNumber(value: Float(style.fadeDistance)), forKey: "fadeDistance")
        mat.setValue(NSNumber(value: Float(lineWidthPx)), forKey: "lineWidthPx")
        mat.setValue(NSNumber(value: Float(planeSize / 2)), forKey: "planeHalf")
        mat.setValue(NSNumber(value: Float(style.showMinor ? 1 : 0)), forKey: "showMinor")
        mat.setValue(NSNumber(value: Float(style.emissiveBoost)), forKey: "emissiveBoost")

        plane.firstMaterial = mat
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)  // xz 평면에 눕힘(법선 +Y).
        node.position = SCNVector3(0, 0.001, 0)               // 바닥 살짝 위.
        node.castsShadow = false
        node.name = "shaderGrid"
        return node
    }

    /// "pristine grid" — 픽셀폭 정규화 + fwidth AA + 카메라 거리 fade.
    /// `_surface.position` 은 view space(카메라 원점) → length 가 카메라 거리.
    private static let surfaceShader = """
    #pragma arguments
    float minorStep;
    float majorStep;
    float lineR;
    float lineG;
    float lineB;
    float fadeDistance;
    float lineWidthPx;
    float planeHalf;
    float showMinor;
    float emissiveBoost;
    #pragma body
    float2 uv = _surface.diffuseTexcoord;
    float2 p = (uv - 0.5) * (planeHalf * 2.0);
    float dist = length(_surface.position.xyz);
    float fade = saturate(1.0 - dist / fadeDistance);
    float line = 0.0;
    if (showMinor > 0.5) {
        float2 wMinor = fwidth(p / minorStep);
        float2 gMinor = abs(fract(p / minorStep - 0.5) - 0.5) / max(wMinor, float2(1e-5));
        line = max(line, (1.0 - saturate(min(gMinor.x, gMinor.y) / lineWidthPx)) * 0.45);
    }
    float2 wMajor = fwidth(p / majorStep);
    float2 gMajor = abs(fract(p / majorStep - 0.5) - 0.5) / max(wMajor, float2(1e-5));
    line = max(line, 1.0 - saturate(min(gMajor.x, gMajor.y) / lineWidthPx));
    float a = saturate(line * fade);
    float3 lineColor = float3(lineR, lineG, lineB);
    _surface.diffuse.rgb = lineColor;
    _surface.diffuse.a = a;
    _surface.emission.rgb = lineColor * (a * emissiveBoost);
    """

    // MARK: - 레거시 실린더 그리드 (폴백 — 보존)

    static func legacyGrid(style: GridStyle) -> SCNNode {
        let group = SCNNode()
        let half = legacyHalf
        let step = max(0.02, style.majorStep)  // 레거시는 major 간격만 사용.
        let mat = SCNMaterial()
        mat.diffuse.contents = style.color
        mat.lightingModel = .constant
        if style.emissiveBoost > 0 { mat.emission.contents = style.color }
        for i in stride(from: -half, through: half, by: step) {
            let xLine = SCNCylinder(radius: 0.0012, height: CGFloat(half * 2))
            xLine.firstMaterial = mat
            let nx = SCNNode(geometry: xLine)
            nx.position = SCNVector3(0, 0.0006, CGFloat(i))
            nx.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            group.addChildNode(nx)

            let zLine = SCNCylinder(radius: 0.0012, height: CGFloat(half * 2))
            zLine.firstMaterial = mat
            let nz = SCNNode(geometry: zLine)
            nz.position = SCNVector3(CGFloat(i), 0.0006, 0)
            group.addChildNode(nz)
        }
        group.name = "legacyGrid"
        return group
    }
}
