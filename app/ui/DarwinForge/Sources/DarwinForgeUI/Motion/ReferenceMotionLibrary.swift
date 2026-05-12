import ForgeCore
import Foundation

/// 외부 커뮤니티 reference (`research/community/`, `motions/external/`) 기반
/// 추가 starter 모션 페이지. `MotionStudioView.starterPages()` 가 append.
///
/// 4 카테고리:
///   1. **보행 점진 테스트** — `motions/test/walk-progression-v1.bin` 의 slot 110~115
///      를 Swift `RobotPose.walkReady` 베이스로 재구현. Sprint 5 walk-engine 진입 전
///      motion primitive 별 격리 검증. 위험도 오름차순.
///   2. **Ergonomic 케어** — `PersonalAssistantGradProject/robot_personal_assistant_op2`
///      page 100~108 의 책상 사용자 통증 케어 시나리오. 모두 `next=base` 패턴 인용 —
///      각 페이지가 자기완결적이고 walk_ready 로 복귀.
///   3. **인사·작별** — 동 페이지 250~255 의 `init_pose` + welcome/ok/bye/go set.
///   4. **HROS5 소셜** — `Interbotix/HROS5-Framework` `Data/motion_4096.bin` 의
///      wave/scratch/bow/dance 의 디자인을 PoseLibrary 의 기존 자세로 구성.
///
/// 모든 페이지는 `RobotPose.walkReady` 에서 시작·종료해야 함 (StarterMotionLibraryTests
/// 의 `testStarterPagesStartAndEndAtSafePose` 회귀).
///
/// 라이선스 / 출처:
///   - PersonalAssistant: `package.xml` 의 `<license>TODO</license>` — 페이지 메타
///     데이터 (페이지 번호 + 의미) 만 사실(facts) 수준에서 인용. 관절값은 우리가
///     `RobotPose.walkReady` + 안전 한도 내 delta 로 새로 합성.
///   - HROS5: GPL v3 — 페이지 디자인 패턴만 인용, 코드/관절값 직접 임포트 X.
///   - darwinop-ens: Apache 2.0 — walkready 기반 자세 합성에 안전한 reference.
public enum ReferenceMotionLibrary {

    // MARK: - 1. Walk Progression Test (Sprint 5 진입 전 검증)
    //
    // `motions/test/walk-progression-v1.bin` 과 동일한 의도이지만, .bin 파일이 사용하는
    // 정확한 darwinop-ens page 9 의 비대칭 raw 값 대신 Swift `RobotPose.walkReady` (대칭
    // 표준) 을 베이스로 사용. 각 페이지는 motion primitive 한 가지만 격리 검증.
    //
    // 사용 절차: `docs/walk-lab/WALK_PROGRESSION_TEST.md` (페이지별 합격 기준 + abort
    // 임계).

    public static func walkProgressionPages(startId: UInt8) -> [MotionPage] {
        var pages: [MotionPage] = []
        var id = startId

        // 110 → wk_hold: 2 s walkready 유지. 서보 명령 + 자세 안정성 확인.
        pages.append(MotionPage(
            id: id, name: "보행 테스트 1 — 자세 유지 (2초)",
            steps: [
                .from(pose: .walkReady, playMs: 2000, pauseMs: 200)
            ]
        ))
        id += 1

        // 111 → wk_arms: 팔만 ±15°. 다리 정지 — 비-다리 servo command path 확인.
        let armsBend = RobotPose.walkReady.with([
            .lShoulderPitch: Kinematics.raw(fromDegrees: 35),   // -10° from +45
            .rElbow:         Kinematics.raw(fromDegrees: 35),   // +15° from +20
            .lElbow:         Kinematics.raw(fromDegrees: -35)   // -15° from -20
        ])
        pages.append(MotionPage(
            id: id, name: "보행 테스트 2 — 팔만 흔들기 (다리 정지)",
            steps: [
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0),
                .from(pose: armsBend,   playMs: 1000, pauseMs: 200),
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0)
            ]
        ))
        id += 1

        // 112 → wk_knee: 3° 조정 squat. hip/knee/ankle 6 관절. 토르소 수직 유지.
        // walkReady 의 hipPitch -8/+8, knee +16/-16, anklePitch -7/+7 에서
        // 각각 ∓1.5, ±3, ±1.5 만큼 변화 (양 다리 좌우 대칭 유지).
        let squat3 = RobotPose.walkReady.with([
            .rHipPitch:    Kinematics.raw(fromDegrees: -9.5),
            .lHipPitch:    Kinematics.raw(fromDegrees:  9.5),
            .rKnee:        Kinematics.raw(fromDegrees: 19.0),
            .lKnee:        Kinematics.raw(fromDegrees: -19.0),
            .rAnklePitch:  Kinematics.raw(fromDegrees: -5.5),
            .lAnklePitch:  Kinematics.raw(fromDegrees:  5.5)
        ])
        pages.append(MotionPage(
            id: id, name: "보행 테스트 3 — 무릎 3° 굽힘 (조정 squat)",
            steps: [
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0),
                .from(pose: squat3,     playMs: 1000, pauseMs: 200),
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0)
            ]
        ))
        id += 1

        // 113 → wk_hip_r: 양 hip_roll +2.5°. 발 고정, 토르소 우측 sway.
        let hipR = RobotPose.walkReady.with([
            .rHipRoll: Kinematics.raw(fromDegrees:  2.5),
            .lHipRoll: Kinematics.raw(fromDegrees:  2.5)
        ])
        pages.append(MotionPage(
            id: id, name: "보행 테스트 4 — 우측 hip sway (발 고정)",
            steps: [
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0),
                .from(pose: hipR,       playMs: 1000, pauseMs: 200),
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0)
            ]
        ))
        id += 1

        // 114 → wk_hip_l: 113 좌우 미러.
        let hipL = RobotPose.walkReady.with([
            .rHipRoll: Kinematics.raw(fromDegrees: -2.5),
            .lHipRoll: Kinematics.raw(fromDegrees: -2.5)
        ])
        pages.append(MotionPage(
            id: id, name: "보행 테스트 5 — 좌측 hip sway (발 고정)",
            steps: [
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0),
                .from(pose: hipL,       playMs: 1000, pauseMs: 200),
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0)
            ]
        ))
        id += 1

        // 115 → wk_lean_pitch: ±2° pitch. NimbRo `lean_fb_gain` 의 IMU 피드백 baseline.
        let leanFwd = RobotPose.walkReady.with([
            .rHipPitch:   Kinematics.raw(fromDegrees: -10),  // -2° from -8
            .lHipPitch:   Kinematics.raw(fromDegrees:  10),
            .rAnklePitch: Kinematics.raw(fromDegrees: -5),   // +2° from -7
            .lAnklePitch: Kinematics.raw(fromDegrees:  5)
        ])
        let leanBack = RobotPose.walkReady.with([
            .rHipPitch:   Kinematics.raw(fromDegrees: -6),   // +2° from -8
            .lHipPitch:   Kinematics.raw(fromDegrees:  6),
            .rAnklePitch: Kinematics.raw(fromDegrees: -9),   // -2° from -7
            .lAnklePitch: Kinematics.raw(fromDegrees:  9)
        ])
        pages.append(MotionPage(
            id: id, name: "보행 테스트 6 — 앞뒤 lean ±2° (IMU baseline)",
            steps: [
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0),
                .from(pose: leanFwd,    playMs: 1000, pauseMs: 200),
                .from(pose: .walkReady, playMs: 1000, pauseMs: 200),
                .from(pose: leanBack,   playMs: 1000, pauseMs: 200),
                .from(pose: .walkReady, playMs: 1000, pauseMs: 0)
            ]
        ))
        id += 1

        return pages
    }

    // MARK: - 2. Ergonomic 케어 (책상 사용자 통증 시나리오)
    //
    // PersonalAssistant page 100~108 패턴 인용 (의미만 — 실제 관절값은 우리 PoseLibrary
    // + 안전 한도 안에서 새로 합성).

    public static func ergonomicPages(startId: UInt8) -> [MotionPage] {
        var pages: [MotionPage] = []
        var id = startId

        // 목 좌우 회전 (4 step) — 거북목 케어. headPan ±30°.
        pages.append(MotionPage(
            id: id, name: "거북목 케어 — 목 좌우 회전",
            steps: [
                .from(pose: .walkReady, playMs: 500, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .headPan: Kinematics.raw(fromDegrees:  30)
                ]), playMs: 800, pauseMs: 400),
                .from(pose: .walkReady.with([
                    .headPan: Kinematics.raw(fromDegrees: -30)
                ]), playMs: 800, pauseMs: 400),
                .from(pose: .walkReady, playMs: 500, pauseMs: 0)
            ]
        ))
        id += 1

        // 목 끄덕임 (4 step) — headTilt ±20°.
        pages.append(MotionPage(
            id: id, name: "거북목 케어 — 목 끄덕임",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .headTilt: Kinematics.raw(fromDegrees:  20)
                ]), playMs: 700, pauseMs: 300),
                .from(pose: .walkReady.with([
                    .headTilt: Kinematics.raw(fromDegrees: -20)
                ]), playMs: 700, pauseMs: 300),
                .from(pose: .walkReady, playMs: 500, pauseMs: 0)
            ]
        ))
        id += 1

        // 양팔 스트레치 — 어깨 위로. PoseLibrary "stretch_arms" 활용.
        if let stretchArms = PoseLibrary.get("stretch_arms")?.pose {
            pages.append(MotionPage(
                id: id, name: "어깨 케어 — 양팔 위로 스트레치",
                steps: [
                    .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                    .from(pose: stretchArms, playMs: 1200, pauseMs: 800),
                    .from(pose: .walkReady, playMs: 800, pauseMs: 200)
                ]
            ))
            id += 1
        }

        // 허리 트위스트 — hipYaw 좌우. ±15°.
        pages.append(MotionPage(
            id: id, name: "허리 케어 — 좌우 트위스트",
            steps: [
                .from(pose: .walkReady, playMs: 500, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rHipYaw: Kinematics.raw(fromDegrees:  15),
                    .lHipYaw: Kinematics.raw(fromDegrees:  15)
                ]), playMs: 900, pauseMs: 500),
                .from(pose: .walkReady.with([
                    .rHipYaw: Kinematics.raw(fromDegrees: -15),
                    .lHipYaw: Kinematics.raw(fromDegrees: -15)
                ]), playMs: 900, pauseMs: 500),
                .from(pose: .walkReady, playMs: 500, pauseMs: 0)
            ]
        ))
        id += 1

        // 양팔 운동 × 3 — PoseLibrary "hands_up" oscillate. PersonalAssistant page 107 (arm_2 rep×3) 인용.
        if let handsUp = PoseLibrary.get("hands_up")?.pose {
            var steps: [MotionStep] = [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0)
            ]
            for _ in 0..<3 {
                steps.append(.from(pose: handsUp,    playMs: 500, pauseMs: 200))
                steps.append(.from(pose: .walkReady, playMs: 500, pauseMs: 100))
            }
            pages.append(MotionPage(
                id: id, name: "어깨 운동 — 만세 × 3회",
                steps: steps
            ))
            id += 1
        }

        // 다리 스트레치 — PoseLibrary "lunge_right" 활용. PersonalAssistant page 105 (leg_1) 인용.
        if let lunge = PoseLibrary.get("lunge_right")?.pose {
            pages.append(MotionPage(
                id: id, name: "다리 케어 — 우측 런지",
                steps: [
                    .from(pose: .walkReady, playMs: 500, pauseMs: 0),
                    .from(pose: lunge, playMs: 1200, pauseMs: 600),
                    .from(pose: .walkReady, playMs: 800, pauseMs: 200)
                ]
            ))
            id += 1
        }

        return pages
    }

    // MARK: - 3. 인사·작별 set
    //
    // PersonalAssistant page 250~255 의 패턴 인용 — 모든 페이지가 walkReady (또는 PA 의
    // init_pose) 로 복귀.

    public static func greetingPages(startId: UInt8) -> [MotionPage] {
        var pages: [MotionPage] = []
        var id = startId

        // 환영 인사 — wave + headTilt up.
        if let wave = PoseLibrary.get("wave_right")?.pose,
           let waveB = PoseLibrary.get("wave_right_b")?.pose {
            pages.append(MotionPage(
                id: id, name: "환영 인사 — 사용자 등장 시",
                steps: [
                    .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                    .from(pose: wave.with([
                        .headTilt: Kinematics.raw(fromDegrees: -10)
                    ]), playMs: 500, pauseMs: 100),
                    .from(pose: waveB.with([
                        .headTilt: Kinematics.raw(fromDegrees: -10)
                    ]), playMs: 300, pauseMs: 0),
                    .from(pose: wave.with([
                        .headTilt: Kinematics.raw(fromDegrees: -10)
                    ]), playMs: 300, pauseMs: 0),
                    .from(pose: .walkReady, playMs: 500, pauseMs: 200)
                ]
            ))
            id += 1
        }

        // 수락 (OK) — 양손 엄지 위, 짧은 끄덕임. handsUp + headTilt 조합 단순화.
        pages.append(MotionPage(
            id: id, name: "수락 (OK) — 명령 수행 의사 표시",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -30),
                    .rElbow:         Kinematics.raw(fromDegrees:  60),
                    .headTilt:       Kinematics.raw(fromDegrees:  15)
                ]), playMs: 500, pauseMs: 200),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -30),
                    .rElbow:         Kinematics.raw(fromDegrees:  60),
                    .headTilt:       Kinematics.raw(fromDegrees: -10)
                ]), playMs: 400, pauseMs: 200),
                .from(pose: .walkReady, playMs: 400, pauseMs: 0)
            ]
        ))
        id += 1

        // 작별 인사 — wave 좌우 + 깊은 인사.
        if let bow = PoseLibrary.get("bow_30")?.pose,
           let wave = PoseLibrary.get("wave_right")?.pose {
            pages.append(MotionPage(
                id: id, name: "작별 인사 — Bye",
                steps: [
                    .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                    .from(pose: wave,       playMs: 500, pauseMs: 200),
                    .from(pose: bow,        playMs: 1000, pauseMs: 500),
                    .from(pose: .walkReady, playMs: 800, pauseMs: 0)
                ]
            ))
            id += 1
        }

        // 출발 신호 (Go) — point_forward + 머리 정면.
        if let point = PoseLibrary.get("point_forward")?.pose {
            pages.append(MotionPage(
                id: id, name: "출발 신호 — Go!",
                steps: [
                    .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                    .from(pose: point, playMs: 500, pauseMs: 600),
                    .from(pose: .walkReady, playMs: 500, pauseMs: 0)
                ]
            ))
            id += 1
        }

        // 환호 — cheer + handsUp 조합.
        if let cheer = PoseLibrary.get("cheer")?.pose,
           let handsUp = PoseLibrary.get("hands_up")?.pose {
            pages.append(MotionPage(
                id: id, name: "환호 — 성공/축하 표현",
                steps: [
                    .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                    .from(pose: cheer,      playMs: 500, pauseMs: 200),
                    .from(pose: handsUp,    playMs: 400, pauseMs: 300),
                    .from(pose: cheer,      playMs: 400, pauseMs: 200),
                    .from(pose: .walkReady, playMs: 600, pauseMs: 0)
                ]
            ))
            id += 1
        }

        return pages
    }

    // MARK: - 4. HROS5 소셜 패턴
    //
    // Interbotix HROS5 motion_4096.bin (GPL — 메타데이터 인용만) 의 페이지 디자인 패턴
    // 적용 — `exit=walkReady` 식 안전 복귀 + 짧은 인터랙티브 액션.

    public static func socialPages(startId: UInt8) -> [MotionPage] {
        var pages: [MotionPage] = []
        var id = startId

        // 머리 긁기 — HROS5 page 25 (scratch) / page 27 (scratch_head) 디자인 인용.
        pages.append(MotionPage(
            id: id, name: "머리 긁기 — 생각하는 제스처",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: -40),
                    .rElbow:         Kinematics.raw(fromDegrees: 100),
                    .headTilt:       Kinematics.raw(fromDegrees:  15)
                ]), playMs: 600, pauseMs: 300),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: -50),
                    .rElbow:         Kinematics.raw(fromDegrees: 110),
                    .headTilt:       Kinematics.raw(fromDegrees:  15)
                ]), playMs: 300, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: -40),
                    .rElbow:         Kinematics.raw(fromDegrees: 100),
                    .headTilt:       Kinematics.raw(fromDegrees:  15)
                ]), playMs: 300, pauseMs: 0),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ]
        ))
        id += 1

        // 흥분 — HROS5 page 35 (excite) 디자인 인용. 양손 만세 × 2 + 빠른 박수.
        if let handsUp = PoseLibrary.get("hands_up")?.pose,
           let clapApart = PoseLibrary.get("clap_apart")?.pose,
           let clapReady = PoseLibrary.get("clap_ready")?.pose {
            pages.append(MotionPage(
                id: id, name: "흥분 표현 — Excite",
                steps: [
                    .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                    .from(pose: handsUp,    playMs: 300, pauseMs: 100),
                    .from(pose: clapApart,  playMs: 200, pauseMs: 0),
                    .from(pose: clapReady,  playMs: 200, pauseMs: 0),
                    .from(pose: clapApart,  playMs: 200, pauseMs: 0),
                    .from(pose: handsUp,    playMs: 300, pauseMs: 100),
                    .from(pose: .walkReady, playMs: 400, pauseMs: 200)
                ]
            ))
            id += 1
        }

        // 말하는 제스처 — HROS5 page 40 (talking) 인용. 양손 번갈아 움직임.
        pages.append(MotionPage(
            id: id, name: "말하기 제스처 — Talking",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -60),
                    .rElbow:         Kinematics.raw(fromDegrees:  70)
                ]), playMs: 400, pauseMs: 100),
                .from(pose: .walkReady.with([
                    .lShoulderPitch: Kinematics.raw(fromDegrees:  60),
                    .lElbow:         Kinematics.raw(fromDegrees: -70)
                ]), playMs: 400, pauseMs: 100),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -60),
                    .rElbow:         Kinematics.raw(fromDegrees:  70)
                ]), playMs: 400, pauseMs: 100),
                .from(pose: .walkReady, playMs: 500, pauseMs: 0)
            ]
        ))
        id += 1

        // 감사 인사 — HROS5 page 45 (thanks) 인용. 깊은 인사 + 양손 모으기.
        if let bow = PoseLibrary.get("bow_60")?.pose,
           let pray = PoseLibrary.get("pray")?.pose {
            pages.append(MotionPage(
                id: id, name: "감사 표현 — Thanks",
                steps: [
                    .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                    .from(pose: pray, playMs: 600, pauseMs: 300),
                    .from(pose: bow,  playMs: 1000, pauseMs: 600),
                    .from(pose: .walkReady, playMs: 800, pauseMs: 200)
                ]
            ))
            id += 1
        }

        return pages
    }
}
