import Foundation

/// press-to-bind(Listen) 캡처 — 스냅샷에서 **가장 강한 입력**을 `ControllerBinding` 으로
/// 변환하는 순수 함수. `DJIBindingCapture.detect` 의 범용 버전.
///
/// 규칙:
/// - 버튼이 눌렸으면 가장 낮은 인덱스 버튼 우선(디지털 명확).
/// - 아니면 임계 초과 축 중 |값| 최대를 선택, 부호로 polarity 결정.
/// - 아무 입력도 임계 미만이면 nil.
public enum ControllerBindingCapture {

    /// 축 캡처 임계 — 드리프트/미세입력 무시.
    public static let axisThreshold: Double = 0.5

    public static func detect(_ snapshot: ControllerSnapshot) -> ControllerBinding? {
        // 1. 버튼 우선.
        for (index, pressed) in snapshot.buttons.enumerated() where pressed {
            return .button(index: index)
        }

        // 2. 축 — 임계 초과 중 최대 magnitude.
        var bestIndex = -1
        var bestMag   = axisThreshold
        for (index, value) in snapshot.axes.enumerated() {
            let mag = abs(value)
            if mag > bestMag {
                bestMag   = mag
                bestIndex = index
            }
        }
        guard bestIndex >= 0 else { return nil }
        let polarity: ControllerBinding.Polarity = snapshot.axes[bestIndex] >= 0 ? .positive : .negative
        return .axis(index: bestIndex, polarity: polarity)
    }
}
