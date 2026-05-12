import ForgeCore
import Foundation

/// ROBOTIS-OP2 공식 `motion_4096.bin` 의 16-페이지 카탈로그 (`gui_motion.yaml` 기준).
///
/// Swift 측 starter 모션 — `RobotPose.walkReady` (정정된 ROBOTIS deep squat) anchor 위에
/// 각 페이지의 ROBOTIS 의도를 합성. 실 ROBOTIS raw 데이터의 byte-exact 복제는
/// 아니며 (그건 `forge motion play --slot N` CLI 사용), **사용자에게 "공식 데모
/// 모션" 카테고리를 명확히 노출** 하기 위한 in-app 합성.
///
/// 안전 분류:
/// - **Safe** (11): Stand Up · Yes · No · Thank You · Walk Ready · Sit Down · Yes Go ·
///   Wow · Oops · Bye Bye · Clap Please
/// - **Caution** (2): Get Up (Front) · Get Up (Back) — placeholder, 실 robot 송출은
///   `forge synth library get 10` 또는 `forge motion play --slot 10 --engage`.
/// - **HighRisk** (3): Right Kick · Left Kick · Hand Standing — placeholder,
///   `single_foot_ok` 메타 필수 + 사용자 supervised 권장.
///
/// 모든 페이지는 `RobotPose.walkReady` 에서 시작·종료해 안전 anchor 보장.
public enum OfficialCatalogReference {

    /// 16 페이지 + 시작 ID 부여. Motion Studio / Expert 동작 라이브러리 양쪽 사용.
    /// 기본 startId = 1 — ROBOTIS 공식 slot ID 와 일치.
    public static func allPages(startId: Int = 1) -> [MotionPage] {
        var pages: [MotionPage] = []
        pages.append(standUp(id: startId + 0))           // 1 — Safe
        pages.append(yes(id: startId + 1))                // 2 — Safe
        pages.append(no(id: startId + 2))                 // 3 — Safe
        pages.append(thankYou(id: startId + 3))           // 4 — Safe
        pages.append(walkReadyPose(id: startId + 8))     // 9 — Safe
        pages.append(getUpFront(id: startId + 9))         // 10 — Caution (placeholder)
        pages.append(getUpBack(id: startId + 10))         // 11 — Caution (placeholder)
        pages.append(rightKick(id: startId + 11))         // 12 — HighRisk
        pages.append(leftKick(id: startId + 12))          // 13 — HighRisk
        pages.append(sitDown(id: startId + 14))           // 15 — Safe
        pages.append(handStanding(id: startId + 16))      // 17 — HighRisk (placeholder)
        pages.append(yesGo(id: startId + 22))             // 23 — Safe
        pages.append(wow(id: startId + 23))               // 24 — Safe
        pages.append(oops(id: startId + 26))              // 27 — Safe
        pages.append(byeBye(id: startId + 37))            // 38 — Safe
        pages.append(clapPlease(id: startId + 53))        // 54 — Safe
        return pages
    }

    // MARK: - Safe 페이지

    /// **Page 1 — Stand Up.** ROBOTIS 기본 자세, 다른 페이지의 anchor.
    public static func standUp(id: Int) -> MotionPage {
        MotionPage(
            id: UInt8(clamping: id),
            name: "공식 1 — Stand Up (기본 자세)",
            steps: [
                .from(pose: .walkReady, playMs: 2000, pauseMs: 200)
            ]
        )
    }

    /// **Page 2 — Yes.** 머리 끄덕임 (긍정 표시).
    public static func yes(id: Int) -> MotionPage {
        let nodDown = RobotPose.walkReady.with([
            .headTilt: Kinematics.raw(fromDegrees: 25)
        ])
        let nodUp = RobotPose.walkReady.with([
            .headTilt: Kinematics.raw(fromDegrees: 0)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 2 — Yes (긍정 끄덕임)",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: nodDown,    playMs: 400, pauseMs: 0),
                .from(pose: nodUp,      playMs: 300, pauseMs: 0),
                .from(pose: nodDown,    playMs: 400, pauseMs: 0),
                .from(pose: .walkReady, playMs: 600, pauseMs: 200)
            ]
        )
    }

    /// **Page 3 — No.** 머리 좌우 흔들기 (부정 표시).
    public static func no(id: Int) -> MotionPage {
        let leftLook = RobotPose.walkReady.with([
            .headPan: Kinematics.raw(fromDegrees: -25)
        ])
        let rightLook = RobotPose.walkReady.with([
            .headPan: Kinematics.raw(fromDegrees: 25)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 3 — No (좌우 흔들기)",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: leftLook,   playMs: 400, pauseMs: 0),
                .from(pose: rightLook,  playMs: 400, pauseMs: 0),
                .from(pose: leftLook,   playMs: 400, pauseMs: 0),
                .from(pose: .walkReady, playMs: 600, pauseMs: 200)
            ]
        )
    }

    /// **Page 4 — Thank You.** 오른팔 앞으로 인사 + 머리 살짝 숙임.
    public static func thankYou(id: Int) -> MotionPage {
        let bow = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +75),  // 오른팔 더 앞으로
            .rElbow:         Kinematics.raw(fromDegrees: 35),
            .headTilt:       Kinematics.raw(fromDegrees: 15)    // 살짝 숙임
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 4 — Thank You (감사 인사)",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: bow,        playMs: 800, pauseMs: 400),
                .from(pose: .walkReady, playMs: 600, pauseMs: 200)
            ]
        )
    }

    /// **Page 9 — Walk Ready.** 보행 시작 자세.
    public static func walkReadyPose(id: Int) -> MotionPage {
        MotionPage(
            id: UInt8(clamping: id),
            name: "공식 9 — Walk Ready (보행 시작)",
            steps: [
                .from(pose: .walkReady, playMs: 1500, pauseMs: 200)
            ]
        )
    }

    /// **Page 15 — Sit Down.** 깊은 squat (놓치면 위험, 부드럽게).
    public static func sitDown(id: Int) -> MotionPage {
        let sit = RobotPose.walkReady.with([
            .rHipPitch:   Kinematics.raw(fromDegrees: -75),   // 깊은 굽힘
            .lHipPitch:   Kinematics.raw(fromDegrees: 75),
            .rKnee:       Kinematics.raw(fromDegrees: 105),   // 무릎 깊게
            .lKnee:       Kinematics.raw(fromDegrees: -105),
            .rAnklePitch: Kinematics.raw(fromDegrees: 60),    // 발끝 위로 보정
            .lAnklePitch: Kinematics.raw(fromDegrees: -60),
            .rShoulderPitch: Kinematics.raw(fromDegrees: +10),
            .lShoulderPitch: Kinematics.raw(fromDegrees: -10)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 15 — Sit Down (앉기)",
            steps: [
                .from(pose: .walkReady, playMs: 600, pauseMs: 0),
                .from(pose: sit,        playMs: 1200, pauseMs: 400),
                .from(pose: .walkReady, playMs: 1200, pauseMs: 200)
            ]
        )
    }

    /// **Page 23 — Yes Go.** 오른팔 앞으로 swing — "출발" 신호.
    public static func yesGo(id: Int) -> MotionPage {
        let swing = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +90),  // 팔 수평
            .rElbow:         Kinematics.raw(fromDegrees: 50)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 23 — Yes Go (출발 신호)",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: swing,      playMs: 600, pauseMs: 400),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ]
        )
    }

    /// **Page 24 — Wow.** 양팔 위로 만세 + 머리 위로.
    public static func wow(id: Int) -> MotionPage {
        let cheer = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +150),  // 팔 위로
            .lShoulderPitch: Kinematics.raw(fromDegrees: -150),
            .rElbow:         Kinematics.raw(fromDegrees: 10),
            .lElbow:         Kinematics.raw(fromDegrees: -10),
            .headTilt:       Kinematics.raw(fromDegrees: -15)    // 머리 위로
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 24 — Wow (감탄 / 만세)",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: cheer,      playMs: 800, pauseMs: 500),
                .from(pose: .walkReady, playMs: 600, pauseMs: 200)
            ]
        )
    }

    /// **Page 27 — Oops.** 양팔 옆으로 어깨 으쓱.
    public static func oops(id: Int) -> MotionPage {
        let shrug = RobotPose.walkReady.with([
            .rShoulderRoll:  Kinematics.raw(fromDegrees: -50),   // 팔 옆으로
            .lShoulderRoll:  Kinematics.raw(fromDegrees: 50),
            .rElbow:         Kinematics.raw(fromDegrees: 70),    // 팔꿈치 굽힘
            .lElbow:         Kinematics.raw(fromDegrees: -70)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 27 — Oops (실수 / 어깨 으쓱)",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: shrug,      playMs: 600, pauseMs: 400),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ]
        )
    }

    /// **Page 38 — Bye Bye.** 오른손 좌우로 흔들기.
    public static func byeBye(id: Int) -> MotionPage {
        let waveUp = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +120),  // 팔 위로
            .rShoulderRoll:  Kinematics.raw(fromDegrees: -30),
            .rElbow:         Kinematics.raw(fromDegrees: 60)
        ])
        let waveLeft = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
            .rShoulderRoll:  Kinematics.raw(fromDegrees: -10),
            .rElbow:         Kinematics.raw(fromDegrees: 60)
        ])
        let waveRight = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
            .rShoulderRoll:  Kinematics.raw(fromDegrees: -50),
            .rElbow:         Kinematics.raw(fromDegrees: 60)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 38 — Bye Bye (작별 인사)",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: waveUp,     playMs: 500, pauseMs: 0),
                .from(pose: waveLeft,   playMs: 400, pauseMs: 0),
                .from(pose: waveRight,  playMs: 400, pauseMs: 0),
                .from(pose: waveLeft,   playMs: 400, pauseMs: 0),
                .from(pose: waveUp,     playMs: 400, pauseMs: 200),
                .from(pose: .walkReady, playMs: 600, pauseMs: 200)
            ]
        )
    }

    /// **Page 54 — Clap Please.** 양팔 박수 자세 (앞으로 모음).
    public static func clapPlease(id: Int) -> MotionPage {
        let apart = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +90),
            .lShoulderPitch: Kinematics.raw(fromDegrees: -90),
            .rShoulderRoll:  Kinematics.raw(fromDegrees: -40),
            .lShoulderRoll:  Kinematics.raw(fromDegrees: 40),
            .rElbow:         Kinematics.raw(fromDegrees: 40),
            .lElbow:         Kinematics.raw(fromDegrees: -40)
        ])
        let together = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +90),
            .lShoulderPitch: Kinematics.raw(fromDegrees: -90),
            .rShoulderRoll:  Kinematics.raw(fromDegrees: -5),
            .lShoulderRoll:  Kinematics.raw(fromDegrees: 5),
            .rElbow:         Kinematics.raw(fromDegrees: 40),
            .lElbow:         Kinematics.raw(fromDegrees: -40)
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 54 — Clap Please (박수 요청)",
            steps: [
                .from(pose: .walkReady, playMs: 400, pauseMs: 0),
                .from(pose: apart,      playMs: 400, pauseMs: 0),
                .from(pose: together,   playMs: 200, pauseMs: 0),
                .from(pose: apart,      playMs: 200, pauseMs: 0),
                .from(pose: together,   playMs: 200, pauseMs: 0),
                .from(pose: apart,      playMs: 200, pauseMs: 0),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ]
        )
    }

    // MARK: - Caution 페이지 (placeholder)

    /// **Page 10 — Get Up (Front).** 앞쪽 낙상 복구.
    ///
    /// 본 합성은 placeholder — 안전한 walkReady hold 만 표시. 실 ROBOTIS 데이터는
    /// `forge motion play --slot 10 --engage` (단, robot 이 앞쪽으로 누운 상태
    /// 에서만 의미). UI 에서는 fallen detection 자동 트리거가 표준 진입 경로.
    public static func getUpFront(id: Int) -> MotionPage {
        MotionPage(
            id: UInt8(clamping: id),
            name: "공식 10 — Get Up Front (앞 낙상 복구) ⚠ Caution",
            steps: [
                .from(pose: .walkReady, playMs: 1500, pauseMs: 200)
            ]
        )
    }

    /// **Page 11 — Get Up (Back).** 뒤쪽 낙상 복구. placeholder.
    public static func getUpBack(id: Int) -> MotionPage {
        MotionPage(
            id: UInt8(clamping: id),
            name: "공식 11 — Get Up Back (뒤 낙상 복구) ⚠ Caution",
            steps: [
                .from(pose: .walkReady, playMs: 1500, pauseMs: 200)
            ]
        )
    }

    // MARK: - HighRisk 페이지

    /// **Page 12 — Right Kick.** 오른발 들어 swing — 단발 지지.
    ///
    /// 본 합성은 walkReady → 오른발 lift → return. 실 ROBOTIS kick (큰 진폭,
    /// V2 velocity peak burst) 은 `forge motion play --slot 12` 사용 권장.
    /// 정비 스탠드 거치 필수 — 단발 지지 자세.
    public static func rightKick(id: Int) -> MotionPage {
        // 왼발 지지, 오른발 들어올림 (knee 굽힘 + hip 앞으로).
        let lift = RobotPose.walkReady.with([
            .rHipRoll:   Kinematics.raw(fromDegrees: 5),     // CoM 왼발로 살짝
            .lHipRoll:   Kinematics.raw(fromDegrees: -5),
            .rHipPitch:  Kinematics.raw(fromDegrees: -60),   // 오른발 더 굽힘
            .rKnee:      Kinematics.raw(fromDegrees: 80),    // 오른 무릎 깊게
            .rAnklePitch:Kinematics.raw(fromDegrees: 0),     // 발끝 release
        ])
        let kick = RobotPose.walkReady.with([
            .rHipRoll:   Kinematics.raw(fromDegrees: 5),
            .lHipRoll:   Kinematics.raw(fromDegrees: -5),
            .rHipPitch:  Kinematics.raw(fromDegrees: -75),   // 오른발 swing
            .rKnee:      Kinematics.raw(fromDegrees: 20),    // 무릎 펴며 swing
            .rAnklePitch:Kinematics.raw(fromDegrees: 0),
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 12 — Right Kick (오른발 킥) 🔴 HighRisk",
            steps: [
                .from(pose: .walkReady, playMs: 500, pauseMs: 0),
                .from(pose: lift,       playMs: 400, pauseMs: 0),
                .from(pose: kick,       playMs: 200, pauseMs: 200),  // impact hold
                .from(pose: lift,       playMs: 300, pauseMs: 0),
                .from(pose: .walkReady, playMs: 700, pauseMs: 200)
            ]
        )
    }

    /// **Page 13 — Left Kick.** Page 12 의 좌우 mirror.
    public static func leftKick(id: Int) -> MotionPage {
        let lift = RobotPose.walkReady.with([
            .rHipRoll:   Kinematics.raw(fromDegrees: -5),
            .lHipRoll:   Kinematics.raw(fromDegrees: 5),
            .lHipPitch:  Kinematics.raw(fromDegrees: 60),
            .lKnee:      Kinematics.raw(fromDegrees: -80),
            .lAnklePitch:Kinematics.raw(fromDegrees: 0),
        ])
        let kick = RobotPose.walkReady.with([
            .rHipRoll:   Kinematics.raw(fromDegrees: -5),
            .lHipRoll:   Kinematics.raw(fromDegrees: 5),
            .lHipPitch:  Kinematics.raw(fromDegrees: 75),
            .lKnee:      Kinematics.raw(fromDegrees: -20),
            .lAnklePitch:Kinematics.raw(fromDegrees: 0),
        ])
        return MotionPage(
            id: UInt8(clamping: id),
            name: "공식 13 — Left Kick (왼발 킥) 🔴 HighRisk",
            steps: [
                .from(pose: .walkReady, playMs: 500, pauseMs: 0),
                .from(pose: lift,       playMs: 400, pauseMs: 0),
                .from(pose: kick,       playMs: 200, pauseMs: 200),
                .from(pose: lift,       playMs: 300, pauseMs: 0),
                .from(pose: .walkReady, playMs: 700, pauseMs: 200)
            ]
        )
    }

    /// **Page 17 — Hand Standing.** 물구나무. placeholder.
    ///
    /// 실 robot 송출 절대 금지 (사용자 명시 + 안전 보장 X). UI 표시만.
    public static func handStanding(id: Int) -> MotionPage {
        MotionPage(
            id: UInt8(clamping: id),
            name: "공식 17 — Hand Standing (물구나무) 🔴 HighRisk",
            steps: [
                .from(pose: .walkReady, playMs: 2000, pauseMs: 500)
            ]
        )
    }
}
