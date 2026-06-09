import Foundation

/// reWASD / Steam Input Activator 의 Swift 순수 값 타입 구현.
///
/// 버튼 물리 누름/뗌 신호를 다양한 활성화 의미로 변환한다.
/// 시간(`nowMs`)은 외부에서 주입받아 테스트 가능성을 보장한다.
public enum ActivatorType: Codable, Hashable, Sendable {
    /// 누르는 동안 계속 active. (= "단순 홀드")
    case hold
    /// 누름 순간 1회만 fired.
    case start
    /// 뗌 순간 1회만 fired.
    case release
    /// `thresholdMs` 이상 지속 홀드 시 fired + active.
    case longPress(thresholdMs: Int)
    /// 누름 edge 마다 active 반전 (reWASD toggle).
    case toggle
    /// `windowMs` 내 2회 누름 시 fired.
    case double(windowMs: Int)
}

public extension ActivatorType {
    /// 1회성 트리거 액션(E-STOP/복구/볼트랙 등)을 이 프레임에 발화할지 결정하는
    /// 순수 정책 — `ActivatorState.updated()` 의 출력을 트리거 이벤트로 번역한다.
    ///
    /// - hold:   active rising edge 에 1회 (누름당 1회, 홀드 spam 차단).
    /// - toggle: active 가 플립될 때마다 1회 (ON/OFF 모두 — 토글형 액션과 정합).
    /// - start/release/longPress/double: 상태머신의 `fired` 그대로.
    func firesEvent(previousActive: Bool, isActive: Bool, fired: Bool) -> Bool {
        switch self {
        case .hold:
            return isActive && !previousActive
        case .toggle:
            return isActive != previousActive
        case .start, .release, .longPress, .double:
            return fired
        }
    }
}

/// 순수 상태 — `updated(pressed:nowMs:type:)` 를 호출할 때마다 **새 값을 반환**.
/// mutation 없음. 내부에 타이머·DispatchQueue 없음.
public struct ActivatorState: Equatable {
    /// 현재 활성 여부 (hold/toggle/longPress 등에서 사용).
    public let isActive: Bool
    /// 직전 누름 상태 (edge 감지용).
    let wasPressed: Bool
    /// 누름 시작 시각 ms (longPress 계산용). nil = 현재 누르고 있지 않음.
    let pressStartMs: Int?
    /// longPress 가 이미 발화됐는지 (중복 발화 방지).
    let longPressFired: Bool
    /// 더블클릭 첫 번째 누름 시각 ms. nil = 대기 중 아님.
    let firstPressMs: Int?

    public init(
        isActive:       Bool = false,
        wasPressed:     Bool = false,
        pressStartMs:   Int? = nil,
        longPressFired: Bool = false,
        firstPressMs:   Int? = nil
    ) {
        self.isActive       = isActive
        self.wasPressed     = wasPressed
        self.pressStartMs   = pressStartMs
        self.longPressFired = longPressFired
        self.firstPressMs   = firstPressMs
    }

    /// 초기 상태.
    public static let idle = ActivatorState()

    // MARK: - 순수 상태 전이

    /// `type` 에 따라 현재 상태를 전이하고 결과를 반환.
    ///
    /// - Parameters:
    ///   - pressed: 이 프레임의 버튼 누름 여부.
    ///   - nowMs:   현재 시각(밀리초). 외부 주입으로 테스트 용이.
    ///   - type:    적용할 activator 종류.
    /// - Returns:
    ///   - state:    다음 프레임으로 넘길 새 상태.
    ///   - isActive: 이 프레임의 "활성" 여부 (지속적 동작, e.g. hold/toggle).
    ///   - fired:    이 프레임에 1회성 이벤트 발화 여부 (e.g. start/release/longPress).
    public func updated(
        pressed: Bool,
        nowMs: Int,
        type: ActivatorType
    ) -> (state: ActivatorState, isActive: Bool, fired: Bool) {
        let pressedEdge  = pressed && !wasPressed   // 누름 edge
        let releasedEdge = !pressed && wasPressed   // 뗌 edge

        switch type {

        // MARK: hold — 누르는 동안 active
        case .hold:
            let next = ActivatorState(isActive: pressed, wasPressed: pressed)
            return (next, pressed, false)

        // MARK: start — 누름 순간 1회 fired
        case .start:
            let next = ActivatorState(isActive: pressedEdge, wasPressed: pressed)
            return (next, pressedEdge, pressedEdge)

        // MARK: release — 뗌 순간 1회 fired
        case .release:
            let next = ActivatorState(isActive: releasedEdge, wasPressed: pressed)
            return (next, releasedEdge, releasedEdge)

        // MARK: longPress — 임계 ms 이상 홀드 시 fired
        case .longPress(let thresholdMs):
            if pressedEdge {
                // 누름 시작
                let next = ActivatorState(
                    isActive: false,
                    wasPressed: true,
                    pressStartMs: nowMs,
                    longPressFired: false,
                    firstPressMs: firstPressMs
                )
                return (next, false, false)
            }
            if pressed, let startMs = pressStartMs {
                let elapsed = nowMs - startMs
                if !longPressFired && elapsed >= thresholdMs {
                    // 임계 초과 → 발화
                    let next = ActivatorState(
                        isActive: true,
                        wasPressed: true,
                        pressStartMs: startMs,
                        longPressFired: true,
                        firstPressMs: firstPressMs
                    )
                    return (next, true, true)
                }
                // 아직 임계 미달
                let next = ActivatorState(
                    isActive: longPressFired,
                    wasPressed: true,
                    pressStartMs: startMs,
                    longPressFired: longPressFired,
                    firstPressMs: firstPressMs
                )
                return (next, longPressFired, false)
            }
            if releasedEdge {
                // 뗌 → 초기화
                let next = ActivatorState(isActive: false, wasPressed: false)
                return (next, false, false)
            }
            let next = ActivatorState(isActive: false, wasPressed: pressed)
            return (next, false, false)

        // MARK: toggle — 누름 edge 마다 active 반전
        case .toggle:
            if pressedEdge {
                let toggled = !isActive
                let next = ActivatorState(isActive: toggled, wasPressed: true)
                return (next, toggled, false)
            }
            let next = ActivatorState(isActive: isActive, wasPressed: pressed)
            return (next, isActive, false)

        // MARK: double — windowMs 내 2회 누름 시 fired
        case .double(let windowMs):
            if pressedEdge {
                if let fp = firstPressMs {
                    let elapsed = nowMs - fp
                    if elapsed <= windowMs {
                        // 더블 클릭 성공
                        let next = ActivatorState(
                            isActive: true,
                            wasPressed: true,
                            firstPressMs: nil
                        )
                        return (next, true, true)
                    } else {
                        // 기존 첫 누름 만료 → 새 첫 누름으로 갱신
                        let next = ActivatorState(
                            isActive: false,
                            wasPressed: true,
                            firstPressMs: nowMs
                        )
                        return (next, false, false)
                    }
                } else {
                    // 첫 번째 누름 기록
                    let next = ActivatorState(
                        isActive: false,
                        wasPressed: true,
                        firstPressMs: nowMs
                    )
                    return (next, false, false)
                }
            }
            // 누름 유지 or 뗌
            let next = ActivatorState(
                isActive: false,
                wasPressed: pressed,
                firstPressMs: firstPressMs
            )
            return (next, false, false)
        }
    }
}
