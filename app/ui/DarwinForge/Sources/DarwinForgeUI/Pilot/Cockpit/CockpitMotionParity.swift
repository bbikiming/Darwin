import Foundation
import ForgeCore

/// **방법론 (Digital Twin + Single Source of Truth + Drone Simulator Auto-Arm)**:
///
/// 본 파일은 "화면의 robot 3D 모델 모션 = 실 robot 의 모션" 동등성을 보장하기
/// 위한 결정 로직을 view 와 분리해 순수 함수로 노출. View struct 안의 분기는
/// 단위 테스트 불가하므로, 가장 위험한 두 분기 (effective pose 선택 + dispatch
/// action 결정) 를 pure logic 으로 추출해 30+ 시나리오 검증을 가능하게 한다.
///
/// # 분리 이유
///
/// - **테스트 가능성**: SwiftUI View struct 안의 computed property / closure 는
///   단위 테스트 직접 불가. 순수 함수로 분리하면 input → output 정확 검증.
/// - **일관성**: cockpit / sim / preview / 추후 다른 진입점 (예: 외부 SDK) 에서
///   동일 결정 로직 재사용.
/// - **방법론적 명시**: 결정 규칙이 documentation 으로 명확히 보이고, 게임 / 드론
///   /로봇공학의 표준 패턴 참조 가능.

// MARK: - Pose resolver (Digital Twin pattern)

/// 화면에 표시할 robot pose 를 결정. **single source of truth**:
///
/// - **실 motor active + walking 중** → `visualPose` (WalkLabSession 이 motor 로
///   송출한 그 pose — digital twin 1:1 mirror).
/// - **그 외** → `animatedPose` (CockpitWalkAnimator 의 시뮬 pose).
///
/// # 방법론 — Digital Twin (ROS2 / Webots / NVIDIA Isaac)
///
/// 로봇공학 시뮬레이션의 표준 패턴: 실 robot 과 시뮬 robot 이 분리된 pose source
/// 를 갖지 않는다. 단일 stream 이 두 곳 (시뮬 view + 실 motor) 으로 fan-out 된다.
/// 본 cockpit 은 motor 활성 시 motor stream 을 view 에 mirror 함으로써 동일 패턴.
public enum CockpitPoseResolver {

    /// 화면에 표시할 pose 결정. 순수 함수 — side effect 없음.
    ///
    /// - Parameters:
    ///   - realMotorEnabled: 사용자가 cockpit 에서 "실 모터" 토글 ON 한 상태.
    ///   - isWalking: WalkLabSession 이 actually walking (walkCycleTask 활성).
    ///   - visualPose: WalkLabSession 의 visualPose (motor 가 실제 송출한 pose).
    ///   - animatedPose: CockpitWalkAnimator 의 시뮬 pose.
    /// - Returns: 화면 3D 모델이 그릴 pose.
    public static func effective(realMotorEnabled: Bool,
                                  isWalking: Bool,
                                  visualPose: RobotPose,
                                  animatedPose: RobotPose) -> RobotPose {
        if realMotorEnabled && isWalking {
            return visualPose
        }
        return animatedPose
    }
}

// MARK: - Dispatch decision (Drone Simulator Auto-Arm pattern)

/// stick 입력 + walking 상태 + safety gate 를 종합해서 PilotCockpitView 가 취할
/// dispatch action 을 결정. 순수 함수로 테스트 가능.
///
/// # 방법론 — DJI Fly / Mission Planner Auto-Arm
///
/// 조종기 stick 1° 이상 움직이면 자동 ARM. stick zero + dwell (~2초) = 자동
/// DISARM. 사용자 mental model: "조종기 잡으면 켜진다, 놓으면 꺼진다". WalkLab
/// 탭의 manual ARM 절차를 cockpit 에서는 implicit 으로.
///
/// # Safety gate (Mission Planner)
///
/// `motorGateOpen = false` 이면 모든 dispatch 차단. emergency / bus 연결 / dxl
/// power 등 조건 미충족 시 사용자에게 silent (HUD 의 motorGate 메시지가 사유).
public enum CockpitDispatchDecision {

    /// dispatch 의사결정 결과. PilotCockpitView 가 case 별로 적절한 session 호출.
    public enum Action: Equatable {
        /// 아무 동작 안 함 (motor disabled 또는 gate closed).
        case noop
        /// `pilotStart(.slowWalk)` 호출 후 amplitude write 시도.
        case autoArmThenApply
        /// amplitude write 만 (이미 walking 중).
        case applyAmplitudeOnly
        /// amplitude write + Auto-DISARM dwell timer 시작 (stick zero + walking).
        case applyAmplitudeAndScheduleDisarm
    }

    /// dispatch action 결정.
    ///
    /// - Parameters:
    ///   - isStickActive: 현재 stick 입력이 active (cmd != stop).
    ///   - realMotorEnabled: 사용자 토글 ON.
    ///   - motorGateOpen: 모든 safety gate 충족 (bus / dxl / emergency).
    ///   - isWalking: WalkLabSession 의 walkCycleTask 활성.
    ///   - disarmTimerActive: 이미 dwell timer 가 도는 중.
    /// - Returns: PilotCockpitView 가 취할 action.
    public static func decide(isStickActive: Bool,
                               realMotorEnabled: Bool,
                               motorGateOpen: Bool,
                               isWalking: Bool,
                               disarmTimerActive: Bool) -> Action {
        // Gate 1 — motor disabled 또는 safety gate closed → noop.
        guard realMotorEnabled, motorGateOpen else {
            return .noop
        }
        // Gate 2 — stick idle + 보행 미시작 → noop.
        // **code review MEDIUM-1 fix**: 정지(parked) robot 에서 throttle 슬라이더만
        // 만질 때, 종전엔 fall-through 로 `.applyAmplitudeOnly` 반환 → stop 명령 +
        // `advanced=true` silent flip + engine poke. 정지 중엔 아무 것도 하지 않아야
        // 안전 (motor 깨우지 않음). stick 을 실제로 움직여야 Auto-ARM (Gate 3).
        if !isStickActive && !isWalking {
            return .noop
        }
        // Gate 3 — stick active + 아직 walking 안 시작 → Auto-ARM.
        if isStickActive && !isWalking {
            return .autoArmThenApply
        }
        // Gate 4 — stick zero + walking 중 + dwell timer 아직 안 도는 중 → dwell 시작.
        if !isStickActive && isWalking && !disarmTimerActive {
            return .applyAmplitudeAndScheduleDisarm
        }
        // 기본 — amplitude write 만 (walking 중 stick active 또는 dwell timer 활성).
        return .applyAmplitudeOnly
    }
}

// MARK: - Stick composition (Keyboard + Diagonal normalisation)

/// 키보드 hold set → desired stick vector. WASD/QE 와 대각선 normalisation 의 규
/// 칙이 한 곳에 있도록 순수 함수로 분리. CockpitState.applyHeldKeys 가 본 함수
/// 결과를 apply(...) 에 전달.
///
/// # 규칙
///
/// - W = -y (전진), S = +y (후진)
/// - A = -x (좌측 이동), D = +x (우측 이동)
/// - Q = +turn (좌회전), E = -turn (우회전)
///
/// # 대각선 normalisation
///
/// `|xy| > 1` 이면 (x,y) /= |xy| — 대각선이 직선보다 √2 배 빠른 효과 차단.
/// 게임 input 의 표준 패턴.
public enum CockpitKeyboardCompose {

    public struct StickVector: Equatable {
        public let leftX: Double
        public let leftY: Double
        public let turn: Double
    }

    public static func compose(_ keys: Set<Character>) -> StickVector {
        var lx = 0.0, ly = 0.0, tn = 0.0
        if keys.contains("w") { ly -= 1 }
        if keys.contains("s") { ly += 1 }
        if keys.contains("a") { lx -= 1 }
        if keys.contains("d") { lx += 1 }
        if keys.contains("q") { tn += 1 }
        if keys.contains("e") { tn -= 1 }
        let mag = (lx * lx + ly * ly).squareRoot()
        if mag > 1.0 {
            lx /= mag
            ly /= mag
        }
        return StickVector(leftX: lx, leftY: ly, turn: tn)
    }
}
