import ForgeCore
import Foundation

/// Walk Lab 프리셋용 보행 step 시퀀스 합성 — `OfficialCatalogReference` 와 동일 패턴.
///
/// # 배경
/// Rust `forge-core::walk::engine` 의 다리 IK 는 미완성 (engine.rs line 3 — "MVP: 다리 IK 는
/// 간단한 mapping. 실 IK 는 후속 사이클"). `motion_4096.bin` 의 raw step 디코더 + SYNC_WRITE
/// 송출 경로도 미구현 (Sprint 15 Day 1-2 별도 PR). 따라서 WalkLab 프리셋 (`march`,
/// `slowWalk`, `normalWalk`, `fastWalk`, `jog`, `turnLeft`, `turnRight`) 을 누르면 종전엔
/// `WalkEngine` FFI 시뮬만 돌고 모터에는 **정적 `walkReady` 자세 한 번** 만 송출 됐다.
///
/// # 본 라이브러리의 역할
/// `WalkLabPreset` → `MotionPage` (joint-space step 시퀀스) 합성. `MotionStep.from(pose:)` 가
/// 31-slot raw position 배열을 만들고 `WalkLabSession.runWalkCycle()` 이 각 step 마다
/// `Bus.setPosition` 으로 직접 송출한다. IK 가 아니라 **사전 정의된 자세 보간** 이라는 점에서
/// ROBOTIS-OP2 `motion_4096.bin` 의 walk slot (38=F_S, 41=F_M 등) 과 동일 접근.
///
/// # 안전 설계
/// - 모든 step 은 `walkReady` anchor 에서 시작·종료 (페이지 종료 직후 즉시 직립 복귀 가능).
/// - 한쪽 발 들기 step 은 **각도 변화량을 작게 유지** (`maxLiftDeg ≤ 25°`) — 균형 손실 최소화.
/// - `WalkLabSession` 가 cradleConfirmed + bus 연결 + 균형 / 온도 / 부하 watchdog 후에만 송출.
/// - 한 번에 한 step — pause 후 다음 step. 50ms watchdog tick 과 직교 (별도 Task).
///
/// # 향후 (v1.5+)
/// - Rust walk-engine IK 완성 시 본 라이브러리 deprecate → `WalkEngine.tick(dt)` 의
///   `FootTargets` → joint angle IK → SYNC_WRITE 실시간 송출로 교체.
/// - `motion_4096.bin` step decoder 완성 시 ROBOTIS 공식 보행 slot 직접 재생 옵션 추가.
public enum WalkMotionLibrary {

    /// 한 프리셋의 보행 사이클 페이지 반환. nil 이면 송출 불가 (e.g. `idle`).
    public static func page(for preset: WalkLabPreset) -> MotionPage? {
        switch preset {
        case .idle:        return nil
        case .march:       return march()
        case .slowWalk:    return walkForward(speedClass: .slow)
        case .normalWalk:  return walkForward(speedClass: .normal)
        case .fastWalk:    return walkForward(speedClass: .fast)
        case .jog:         return jog()
        case .turnLeft:    return turn(direction: .left)
        case .turnRight:   return turn(direction: .right)
        }
    }

    // MARK: - Speed class — step time 매핑

    private enum SpeedClass {
        case slow, normal, fast

        /// 한 step (반-cycle) 의 보간 시간 (ms). 작을수록 빠른 보행.
        var playMs: Int {
            switch self {
            case .slow:   return 500
            case .normal: return 380
            case .fast:   return 280
            }
        }
        /// step 사이 정지 (ms). 빠른 보행일수록 짧음 — 사이클 연속성.
        var pauseMs: Int {
            switch self {
            case .slow:   return 100
            case .normal: return 60
            case .fast:   return 30
            }
        }
        /// 전진 보폭의 hip pitch 추가 회전 (°). 작을수록 안전 — 자기충돌 회피.
        var swingDeg: Double {
            switch self {
            case .slow:   return 6   // 작은 보폭
            case .normal: return 10
            case .fast:   return 14  // ROBOTIS 공식 권장 max
            }
        }
    }

    // MARK: - 보행 자세 빌더

    /// `walkReady` 에서 출발하는 안전한 발 들기 자세.
    /// `liftDeg` = 무릎 추가 굽힘 (°). 25° 이하 권장 — 한쪽 발 지지 시 균형 한계.
    /// `side`: `.right` = 오른발 들기, `.left` = 왼발 들기.
    private static func liftFoot(side: FootSide, liftDeg: Double) -> RobotPose {
        let deg = liftDeg.clamped(to: 5.0...30.0)
        switch side {
        case .right:
            return RobotPose.walkReady.with([
                // 오른발 들기 — 무릎 추가 굽힘 + hip pitch 살짝 더 굽힘 + ankle 보정.
                .rHipPitch:   Kinematics.raw(fromDegrees: -36 - deg * 0.4),  // walkReady -36° → 더 굽힘.
                .rKnee:       Kinematics.raw(fromDegrees: 53 + deg),         // walkReady 53° → +deg.
                .rAnklePitch: Kinematics.raw(fromDegrees: 30 + deg * 0.6),   // 발끝 더 위로.
                // 왼발 지지 — 살짝 펴서 키 늘리기 (들린 발 clearance).
                .lHipPitch:   Kinematics.raw(fromDegrees: 36 - deg * 0.2),
                .lKnee:       Kinematics.raw(fromDegrees: -53 + deg * 0.4),
                .lAnklePitch: Kinematics.raw(fromDegrees: -30 + deg * 0.3),
                // 무게중심 좌발로 — ankle roll 작게 (±3° max).
                .rAnkleRoll:  Kinematics.raw(fromDegrees: 0.8 + 2.5),
                .lAnkleRoll:  Kinematics.raw(fromDegrees: -0.8 - 2.5),
                .rHipRoll:    Kinematics.raw(fromDegrees: 0.4 - 2.5),        // hip CoM 보정.
                .lHipRoll:    Kinematics.raw(fromDegrees: -0.4 + 2.5)
            ])
        case .left:
            return RobotPose.walkReady.with([
                // mirror of right.
                .lHipPitch:   Kinematics.raw(fromDegrees: 36 + deg * 0.4),
                .lKnee:       Kinematics.raw(fromDegrees: -53 - deg),
                .lAnklePitch: Kinematics.raw(fromDegrees: -30 - deg * 0.6),
                .rHipPitch:   Kinematics.raw(fromDegrees: -36 + deg * 0.2),
                .rKnee:       Kinematics.raw(fromDegrees: 53 - deg * 0.4),
                .rAnklePitch: Kinematics.raw(fromDegrees: 30 - deg * 0.3),
                .lAnkleRoll:  Kinematics.raw(fromDegrees: -0.8 - 2.5),
                .rAnkleRoll:  Kinematics.raw(fromDegrees: 0.8 + 2.5),
                .lHipRoll:    Kinematics.raw(fromDegrees: -0.4 - 2.5),
                .rHipRoll:    Kinematics.raw(fromDegrees: 0.4 + 2.5)
            ])
        }
    }

    /// 전진 swing 자세 — 들린 발을 앞으로 swing.
    /// `swingDeg`: hip pitch 의 추가 전방 회전 (°). 보폭에 비례.
    private static func swingForward(side: FootSide, liftDeg: Double, swingDeg: Double) -> RobotPose {
        let lift = liftFoot(side: side, liftDeg: liftDeg)
        switch side {
        case .right:
            return lift.with([
                // 오른 hip pitch 를 더 굽혀서 (음수 방향) 앞으로 swing.
                .rHipPitch: Kinematics.raw(fromDegrees: -36 - liftDeg * 0.4 - swingDeg),
                // 무릎 살짝 펴 (착지 준비) — knee 가 lift 시 53+deg 였던 걸 줄임.
                .rKnee:     Kinematics.raw(fromDegrees: 53 + liftDeg * 0.5),
                // 팔 swing — 자연 보행 모방 (반대 팔이 앞으로). 좌 어깨가 앞으로.
                .lShoulderPitch: Kinematics.raw(fromDegrees: 41 - swingDeg * 0.7),
                .rShoulderPitch: Kinematics.raw(fromDegrees: -48 + swingDeg * 0.7)
            ])
        case .left:
            return lift.with([
                .lHipPitch: Kinematics.raw(fromDegrees: 36 + liftDeg * 0.4 + swingDeg),
                .lKnee:     Kinematics.raw(fromDegrees: -53 - liftDeg * 0.5),
                .rShoulderPitch: Kinematics.raw(fromDegrees: -48 - swingDeg * 0.7),
                .lShoulderPitch: Kinematics.raw(fromDegrees: 41 + swingDeg * 0.7)
            ])
        }
    }

    private enum FootSide { case right, left }
    private enum TurnDirection { case left, right }

    // MARK: - 페이지 합성

    /// 제자리 걸음 — march. 가장 안전한 보행 (전진 없음, 발 들기만).
    /// 한 cycle = 4 step: walkReady → R lift → walkReady → L lift → walkReady.
    private static func march() -> MotionPage {
        let liftDeg: Double = 18  // 작게 (25° 한계 이하).
        let playMs = 480
        let pauseMs = 80
        return MotionPage(
            id: 200,
            name: "WalkLab march — 제자리 걸음",
            steps: [
                .from(pose: .walkReady,                         playMs: 400, pauseMs: 0),
                .from(pose: liftFoot(side: .right, liftDeg: liftDeg), playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady,                         playMs: playMs, pauseMs: pauseMs),
                .from(pose: liftFoot(side: .left, liftDeg: liftDeg),  playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady,                         playMs: playMs, pauseMs: pauseMs)
            ]
        )
    }

    /// 전진 보행 — 발 들기 + swing + 착지 + 반대쪽.
    /// 한 cycle = 7 step + endcap.
    private static func walkForward(speedClass: SpeedClass) -> MotionPage {
        let liftDeg: Double = 16
        let swing = speedClass.swingDeg
        let playMs = speedClass.playMs
        let pauseMs = speedClass.pauseMs
        let id: UInt8 = {
            switch speedClass {
            case .slow:   return 201
            case .normal: return 202
            case .fast:   return 203
            }
        }()
        let name: String = {
            switch speedClass {
            case .slow:   return "WalkLab slowWalk — 천천히 걷기"
            case .normal: return "WalkLab normalWalk — 보통 속도"
            case .fast:   return "WalkLab fastWalk — 빠르게 걷기"
            }
        }()
        return MotionPage(
            id: id,
            name: name,
            steps: [
                .from(pose: .walkReady,                                            playMs: 400,    pauseMs: 0),
                .from(pose: liftFoot(side: .right, liftDeg: liftDeg),              playMs: playMs, pauseMs: pauseMs),
                .from(pose: swingForward(side: .right, liftDeg: liftDeg, swingDeg: swing), playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady,                                            playMs: playMs, pauseMs: pauseMs),
                .from(pose: liftFoot(side: .left, liftDeg: liftDeg),               playMs: playMs, pauseMs: pauseMs),
                .from(pose: swingForward(side: .left, liftDeg: liftDeg, swingDeg: swing),  playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady,                                            playMs: playMs, pauseMs: pauseMs)
            ]
        )
    }

    /// 달리기 — fastWalk 보다 더 빠른 cycle + 큰 swing. HighRisk.
    private static func jog() -> MotionPage {
        let liftDeg: Double = 22  // 더 깊게.
        let swing: Double = 16    // 큰 보폭.
        let playMs = 220
        let pauseMs = 20
        return MotionPage(
            id: 204,
            name: "WalkLab jog — 달리기 (HighRisk)",
            steps: [
                .from(pose: .walkReady,                                            playMs: 400,    pauseMs: 0),
                .from(pose: liftFoot(side: .right, liftDeg: liftDeg),              playMs: playMs, pauseMs: pauseMs),
                .from(pose: swingForward(side: .right, liftDeg: liftDeg, swingDeg: swing), playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady,                                            playMs: playMs, pauseMs: pauseMs),
                .from(pose: liftFoot(side: .left, liftDeg: liftDeg),               playMs: playMs, pauseMs: pauseMs),
                .from(pose: swingForward(side: .left, liftDeg: liftDeg, swingDeg: swing),  playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady,                                            playMs: playMs, pauseMs: pauseMs)
            ]
        )
    }

    /// 회전 — hipYaw 로 한쪽 다리 안쪽 회전 + 짧은 step.
    /// 한 cycle: yaw 진입 → R lift+yaw → walkReady → L lift+yaw → walkReady.
    private static func turn(direction: TurnDirection) -> MotionPage {
        let yawDeg: Double = 12
        let liftDeg: Double = 14
        let playMs = 420
        let pauseMs = 80

        // 회전은 hipYaw 의 부호로 결정. left turn = 좌측 다리가 안쪽으로 (+yaw), 우측은 바깥 (-yaw).
        let leftYaw  = direction == .left ?  yawDeg : -yawDeg
        let rightYaw = direction == .left ? -yawDeg :  yawDeg

        // walkReady 에 yaw 만 적용한 anchor.
        let yawAnchor = RobotPose.walkReady.with([
            .lHipYaw: Kinematics.raw(fromDegrees: leftYaw),
            .rHipYaw: Kinematics.raw(fromDegrees: rightYaw)
        ])
        // R lift + yaw.
        let rLift = liftFoot(side: .right, liftDeg: liftDeg).with([
            .lHipYaw: Kinematics.raw(fromDegrees: leftYaw),
            .rHipYaw: Kinematics.raw(fromDegrees: rightYaw)
        ])
        let lLift = liftFoot(side: .left, liftDeg: liftDeg).with([
            .lHipYaw: Kinematics.raw(fromDegrees: leftYaw),
            .rHipYaw: Kinematics.raw(fromDegrees: rightYaw)
        ])

        let id: UInt8 = direction == .left ? 205 : 206
        let name: String = direction == .left
            ? "WalkLab turnLeft — 좌회전"
            : "WalkLab turnRight — 우회전"
        return MotionPage(
            id: id,
            name: name,
            steps: [
                .from(pose: .walkReady, playMs: 400,    pauseMs: 0),
                .from(pose: yawAnchor,  playMs: playMs, pauseMs: pauseMs),
                .from(pose: rLift,      playMs: playMs, pauseMs: pauseMs),
                .from(pose: yawAnchor,  playMs: playMs, pauseMs: pauseMs),
                .from(pose: lLift,      playMs: playMs, pauseMs: pauseMs),
                .from(pose: yawAnchor,  playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady, playMs: 400,    pauseMs: 100)
            ]
        )
    }
}
