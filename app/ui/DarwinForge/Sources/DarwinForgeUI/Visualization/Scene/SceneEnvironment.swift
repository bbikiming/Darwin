import SceneKit
import SwiftUI

/// 화면별 3D 환경 프리셋 — **W2** (docs/design/3d-viewport-enhancement.md §4).
///
/// 비유: 같은 무대(로봇·조명 rig)를 두고 조명감독이 장면마다 다른 "조명 큐"를 거는 것.
/// Studio 는 중성 엔지니어링, Teach 는 따뜻한 워크벤치, WalkLab 은 쿨톤 계측 랩,
/// Motion 은 어두운 무대, Cockpit 은 teal FPV 호라이즌.
///
/// preset 은 **화면당 빌드 시 1회 고정**(런타임 변경 미지원 — 코디네이터 재생성 비용
/// 회피). 라이브 튜닝 패널(SceneTuning)은 그 위에 절대값 오버라이드로 동작한다.
public enum ScenePreset: String, Sendable, CaseIterable {
    case studio, teach, walkLab, motion, cockpit
}

/// 그리드 외형 — 셰이더 AA 그리드(GridFloorMaterial)와 레거시 실린더 그리드 공용.
struct GridStyle {
    var minorStep: CGFloat
    var majorStep: CGFloat
    var color: NSColor
    /// 카메라 거리 fade 시작 거리(m).
    var fadeDistance: CGFloat
    /// minor(촘촘한) 라인 표시 여부.
    var showMinor: Bool
    /// emissive 증폭(Cockpit teal glow). 0이면 비발광.
    var emissiveBoost: CGFloat
}

/// 화면별 추가 소품.
enum PropKind {
    case originAxes      // 원점 RGB 축(기존 axesNode 가 담당 — 스펙 표기용)
    case distanceMarks   // 진행축 0.5m 간격 거리 마킹(WalkLab)
    case startLine       // 출발선(WalkLab)
    case workMat         // 작업 매트(Teach)
    case stageSpot       // 무대 스팟라이트(Motion)
}

/// preset별 정적 환경 스펙(값 테이블). MainActor 에서 무대 빌드에 소비.
struct SceneEnvironmentSpec {
    var iblZenith: NSColor
    var iblHorizon: NSColor
    var iblGround: NSColor
    var iblIntensity: CGFloat
    var keyIntensity: CGFloat
    var keyColor: NSColor
    var rimIntensity: CGFloat
    var floorAlbedo: NSColor
    var floorRoughness: CGFloat
    var grid: GridStyle
    var props: [PropKind]
}

extension SceneEnvironmentSpec {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    /// §4 2-A 표의 화면별 초기값. **Studio 는 W1 상수와 동일**(노출 회귀 0 보장).
    static func spec(for preset: ScenePreset) -> SceneEnvironmentSpec {
        switch preset {
        case .studio:
            return SceneEnvironmentSpec(
                iblZenith: rgb(0.95, 0.97, 1.00).scaled(1.15),
                iblHorizon: rgb(0.52, 0.55, 0.60),
                iblGround: rgb(0.16, 0.16, 0.18),
                iblIntensity: 1.0,
                keyIntensity: 550, keyColor: rgb(1.00, 0.98, 0.95),
                rimIntensity: 180,
                floorAlbedo: NSColor(calibratedWhite: 0.10, alpha: 1), floorRoughness: 0.85,
                grid: GridStyle(minorStep: 0.10, majorStep: 0.50,
                                color: NSColor(calibratedWhite: 0.30, alpha: 1),
                                fadeDistance: 18, showMinor: true, emissiveBoost: 0),
                props: [.originAxes])

        case .teach:
            return SceneEnvironmentSpec(
                iblZenith: rgb(1.00, 0.97, 0.92).scaled(1.12),
                iblHorizon: rgb(0.60, 0.55, 0.48),
                iblGround: rgb(0.15, 0.13, 0.11),
                iblIntensity: 1.0,
                keyIntensity: 520, keyColor: rgb(1.00, 0.93, 0.82),  // ~3600K
                rimIntensity: 150,
                floorAlbedo: rgb(0.14, 0.13, 0.11), floorRoughness: 0.90,
                grid: GridStyle(minorStep: 0.25, majorStep: 0.25,
                                color: NSColor(calibratedWhite: 0.22, alpha: 1),
                                fadeDistance: 10, showMinor: false, emissiveBoost: 0),
                props: [.workMat])

        case .walkLab:
            return SceneEnvironmentSpec(
                iblZenith: rgb(0.90, 0.94, 1.00).scaled(1.12),
                iblHorizon: rgb(0.48, 0.55, 0.62),
                iblGround: rgb(0.12, 0.13, 0.15),
                iblIntensity: 0.9,
                keyIntensity: 560, keyColor: rgb(0.98, 0.99, 1.00),  // ~5500K neutral
                rimIntensity: 180,
                floorAlbedo: NSColor(calibratedWhite: 0.09, alpha: 1), floorRoughness: 0.80,
                grid: GridStyle(minorStep: 0.10, majorStep: 0.50,
                                color: rgb(0.28, 0.30, 0.34),
                                fadeDistance: 16, showMinor: true, emissiveBoost: 0),
                props: [.distanceMarks, .startLine, .originAxes])

        case .motion:
            return SceneEnvironmentSpec(
                iblZenith: rgb(0.55, 0.55, 0.62),
                iblHorizon: rgb(0.35, 0.35, 0.42),
                iblGround: rgb(0.06, 0.06, 0.08),
                iblIntensity: 0.7,
                keyIntensity: 650, keyColor: rgb(1.00, 0.97, 0.92),  // spot 성
                rimIntensity: 120,
                floorAlbedo: NSColor(calibratedWhite: 0.05, alpha: 1), floorRoughness: 0.95,
                grid: GridStyle(minorStep: 1.0, majorStep: 1.0,
                                color: NSColor(calibratedWhite: 0.20, alpha: 1),
                                fadeDistance: 14, showMinor: false, emissiveBoost: 0),
                props: [.stageSpot])

        case .cockpit:
            return SceneEnvironmentSpec(
                iblZenith: rgb(0.70, 0.86, 0.92),
                iblHorizon: rgb(0.10, 0.22, 0.26),   // teal
                iblGround: rgb(0.03, 0.07, 0.09),
                iblIntensity: 0.55,
                keyIntensity: 420, keyColor: rgb(0.85, 0.92, 1.00),  // cool
                rimIntensity: 100,
                floorAlbedo: rgb(0.02, 0.05, 0.06), floorRoughness: 0.90,
                grid: GridStyle(minorStep: 0.50, majorStep: 0.50,
                                color: rgb(0.10, 0.62, 0.66),  // emissive teal
                                fadeDistance: 12, showMinor: false, emissiveBoost: 1.6),
                props: [])
        }
    }
}

// MARK: - NSColor helper (ProceduralEnvironmentMap 의 scaled 와 동일 의미, 내부 공용)

extension NSColor {
    /// 휘도 스케일(클램프 1.0). IBL tint 사전 강조용.
    func scaled(_ factor: CGFloat) -> NSColor {
        let c = usingColorSpace(.deviceRGB) ?? self
        return NSColor(calibratedRed: min(1, c.redComponent * factor),
                       green: min(1, c.greenComponent * factor),
                       blue: min(1, c.blueComponent * factor),
                       alpha: 1)
    }

    /// sRGB 0–1 튜플(device 공간 안전 변환) — 셰이더 uniform 수급용.
    var sceneRGBTuple: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = usingColorSpace(.deviceRGB) ?? self
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }
}
