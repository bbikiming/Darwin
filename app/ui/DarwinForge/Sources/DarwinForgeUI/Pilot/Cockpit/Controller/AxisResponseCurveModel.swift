import CoreGraphics
import Foundation

/// 축 응답 곡선 샘플링 — `ControllerAxisTuning.shaped()` 를 그래프 좌표로 변환
/// (설계 §C, 8BitDo Ultimate 패턴, 순수 함수).
///
/// 좌표계: x = 입력 크기 [0,1], y = 출력 크기 [0,1]. invert 는 부호만 바꾸므로
/// magnitude 그래프에서는 동일 곡선이다.
public enum AxisResponseCurveModel {

    /// 곡선 폴리라인 샘플 — x 균등 분할.
    public static func points(tuning: ControllerAxisTuning, sampleCount: Int = 48) -> [CGPoint] {
        guard sampleCount >= 2 else { return [] }
        return (0..<sampleCount).map { index in
            let x = Double(index) / Double(sampleCount - 1)
            return CGPoint(x: x, y: abs(tuning.shaped(x)))
        }
    }

    /// 현재 원시 입력의 라이브 점 — 곡선 위 위치.
    public static func livePoint(tuning: ControllerAxisTuning, raw: Double) -> CGPoint {
        CGPoint(x: abs(raw), y: abs(tuning.shaped(raw)))
    }
}
