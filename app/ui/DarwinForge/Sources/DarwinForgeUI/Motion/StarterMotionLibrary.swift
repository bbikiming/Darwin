import Foundation
import ForgeCore

/// 사이클 246 — Wave 4.3.1: `MotionStudioView` 에서 분리된 starter document factory.
///
/// `MotionStudioView` (1641줄) god view 분할 첫 단계. 사이클 154/155 의 ID 매핑
/// 규약을 그대로 유지한 채로 logic 만 외부 모듈로 옮겼다.
///
/// **ID 매핑** (변경 없음 — 기존 호출자와 100% 호환):
/// - 1-54: ROBOTIS 공식 motion_4096.bin catalog (`OfficialCatalogReference`)
/// - 110-119: `ReferenceMotionLibrary` walk progression
/// - 120-129: ergonomic / 일상
/// - 130-139: greetings
/// - 140-149: social
/// - 150-182: mixamo 스타일
/// - 200-204: prebundled (idle / tPose / bow / wave / sit)
/// - 220+: `libraryStarterPages`
///
/// **호출자**:
/// - `MotionStudioView.motion` — 첫 열림 시 starter document
/// - `MotionLibraryView.starterPages` — 카테고리 분류 표시
/// - `StarterMotionLibraryTests` — 회귀 가드
public enum StarterMotionLibrary {

    // MARK: - Public API

    /// 신규 사용자가 처음 열 때 보는 starter document.
    public static func starterDoc() -> MotionDoc {
        return MotionDoc(pages: starterPages())
    }

    /// P0-H: prebundled motion library — 첫 실행 시 사용자가 *바로 실행해 볼* 5 페이지.
    ///
    /// 출처: ROBOTIS RoboPlus Action 기본 모션 (인사/sit/stand/wave 등)을 단순화한 안전판.
    /// 모든 페이지는 walk_ready로 시작해 walk_ready로 종료 → 연속 재생 안전.
    /// `static` 으로 외부 노출해 테스트에서도 검증 가능.
    public static func starterPages() -> [MotionPage] {
        // ── 1. 기본 자세 — 워크랩과 동일 walkReady (ROBOTIS standing posture).
        //    "여기서 시작" 의미. 다른 페이지에서 비상시 복귀할 안전 자세이기도 함.
        // ID 정책: ROBOTIS 공식 1-54 (실 slot 일치), prebundled 200+,
        // ReferenceMotionLibrary 110+ (walk_test=110-115, ergonomic=120-125,
        // greeting=130-134, social=140-143). 모든 ID unique.
        let idle = MotionPage(
            id: 200, name: "기본 자세",
            steps: [.from(pose: .walkReady, playMs: 800, pauseMs: 200)]
        )

        // ── 2. T-자세 — 진단/캘리브레이션 표준.
        let tPose = MotionPage(
            id: 201, name: "T 자세 (진단)",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: .tPose,     playMs: 800, pauseMs: 400),
                .from(pose: .walkReady, playMs: 800, pauseMs: 0)
            ]
        )

        // ── 3. 인사 — 머리 끄덕임으로 부드럽게 표현.
        let bow = MotionPage(
            id: 202, name: "인사",
            steps: [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .headTilt: Kinematics.raw(fromDegrees: 25)
                ]), playMs: 600, pauseMs: 200),
                .from(pose: .walkReady.with([
                    .headTilt: Kinematics.raw(fromDegrees: -10)
                ]), playMs: 600, pauseMs: 0),
                .from(pose: .walkReady, playMs: 400, pauseMs: 0)
            ]
        )

        // ── 4. 손 흔들기 — 우측 팔만, 어깨 충돌 한계 안에서.
        let wave = MotionPage(
            id: 203, name: "손 흔들기",
            steps: [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 90)
                ]), playMs: 500, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 30),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 30)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 90),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 0)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 30),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 30)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady, playMs: 500, pauseMs: 0)
            ]
        )

        // ── 5. 앉기 — walkReady deep squat 에서 추가 굽힘 (CRITIC P2 #3 + PR #8 부호 fix 통합).
        //
        // 종전 버그 (CRITIC 두 건 결합):
        //  1. lKnee +90° 로 좌·우 같은 부호 — ROBOTIS convention 위반 (mirror axis).
        //     PR #8 (negative-joint-mirror-fix) 에서 lKnee 절대 -90° 로 부호 fix 됐고,
        //     본 PR 의 delta -37° 패턴이 walkReady (-53°) 와 합쳐져 동일 결과 (-90°).
        //  2. 절대 -45°/+90° 사용 → walkReady (-36°/+53°/+30°) 에서 절대값으로 보간 시
        //     중간 frame 에서 hip 은 walkReady 보다 -4° 더 굽고 knee 는 walkReady 보다
        //     +18° 더 굽은 비대칭 자세 통과 → hotfix v3 "뒤로 넘어짐" fault mode 와 동일.
        //  3. ankle pitch 가 walkReady 의 +30° 그대로 → knee +90° 굽힘 후 발이 +15° 들림
        //     (foot 절대각 = -45+90-30 = +15°) → CoM 뒤로 → 뒤로 넘어짐.
        //
        // Fix — walkReady-relative delta + 좌·우 mirror + ankle CoM 보정:
        //   hip: +(-9°) 추가 굽힘 / knee: +(+37°) 추가 굽힘 / ankle: +(+15°) 발끝 보정.
        //   foot 절대각 = -45 + 90 - 45 = 0° (수평) — CoM 발 위에 정확히 정렬.
        let sitDeltas: [JointID: Double] = [
            .rHipPitch:   -9,    .lHipPitch:   +9,    // mirror pair
            .rKnee:       +37,   .lKnee:       -37,   // mirror pair (PR #8 의 -90° 와 동일 결과)
            .rAnklePitch: +15,   .lAnklePitch: -15    // CoM 보정 — foot 수평 유지
        ]
        let sit = MotionPage(
            id: 204, name: "앉기",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: Self.deltaFromWalkReady(sitDeltas), playMs: 800, pauseMs: 200),
                .from(pose: .walkReady, playMs: 800, pauseMs: 0)
            ]
        )

        // ── 6+. PoseLibrary 활용 추가 starter 페이지들.
        //     각 페이지: walk_ready → key pose → (좌우 oscillate 추가) → walk_ready.
        let extras = libraryStarterPages()

        // ── 7. 외부 reference (research/community + motions/external) 기반 추가 페이지.
        //     ReferenceMotionLibrary 가 분류별로 분리 — 보행 점진 테스트, ergonomic 케어,
        //     인사·작별, HROS5 소셜 패턴. 라이선스·출처 주석은 해당 파일 참고.
        //     ID 충돌 회피: existing 1..5 + 10..32 = ~32 까지 사용 → 새 페이지는 50+.
        // ID 110+ — ROBOTIS 공식 (1-54) 와 충돌 회피. walk_test 의 startId 110 은
        // motions/test/walk-progression-v1.bin 의 실 slot 110-115 와 일치.
        let walkTest = ReferenceMotionLibrary.walkProgressionPages(startId: 110)
        let ergonomic = ReferenceMotionLibrary.ergonomicPages(startId: 120)
        let greetings = ReferenceMotionLibrary.greetingPages(startId: 130)
        let social = ReferenceMotionLibrary.socialPages(startId: 140)

        // ROBOTIS 공식 motion_4096.bin 의 16 카탈로그 (gui_motion.yaml 기준).
        // ID 1..=54 — ROBOTIS slot 과 일치. 50+ ReferenceMotionLibrary 와 충돌
        // 없음 (공식 ID 1, 2, 3, 4, 9, 10, 11, 12, 13, 15, 17, 23, 24, 27, 38, 54).
        // 실 ROBOTIS raw 송출은 `forge motion play --slot N --bin <path>` 사용.
        let officialCatalog = OfficialCatalogReference.allPages(startId: 1)

        // 2026-05-17 신규 mixamo 스타일 33개 — ID 150-182 (UInt8 안전 범위).
        // 기존: official 1-54, walkProgression 110-115, ergonomic 120-125,
        //       greeting 130-134, social 140-143, basic 200-204, library 220-244.
        // 150-182 충돌 없음. 250+ 시작 시 UInt8 overflow trap.
        let mixamoExtras = mixamoStyleStarterPages(startId: 150)

        // v1.11.2 (2026-05-18): CI Swift 5.9 type-checker timeout 회피 — generic
        // `+` 5단계 concatenation 을 단계별 variable 로 분리. 로컬 5.10 은 inference
        // 가능하지만 CI 옛 toolchain 은 표현식 복잡도 초과 → error.
        let starters: [MotionPage] = [idle, tPose, bow, wave, sit]
        let withExtras = starters + extras
        let withOfficial = withExtras + officialCatalog
        let withWalk = withOfficial + walkTest + ergonomic + greetings + social
        return withWalk + mixamoExtras
    }

    // MARK: - Helpers

    /// `walkReady` 의 현재 raw 값에서 각 관절에 delta(°) 를 더한 새 pose.
    /// `ReferenceMotionLibrary.deltaPose` 와 같은 패턴 — walkReady 가 미래에 갱신돼도 delta 의미 보존.
    /// CRITIC P2 #3 권고로 도입.
    fileprivate static func deltaFromWalkReady(_ deltas: [JointID: Double]) -> RobotPose {
        var dict = RobotPose.walkReady.positions
        for (joint, delta) in deltas {
            let base = RobotPose.walkReady.degrees(joint)
            dict[joint] = Kinematics.raw(fromDegrees: base + delta)
        }
        return RobotPose(positions: dict)
    }

    /// PoseLibrary 기반 starter 동작 생성 — 단일 자세 페이지 + 오실레이션 페이지.
    /// 새 사용자 onboarding 및 모션 예제 제공.
    private static func libraryStarterPages() -> [MotionPage] {
        func single(_ id: UInt8, _ name: String, _ poseId: String,
                    playMs: Int = 800, pauseMs: Int = 200) -> MotionPage {
            guard let p = PoseLibrary.get(poseId) else { return MotionPage(id: id, name: name, steps: []) }
            return MotionPage(id: id, name: name, steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: p.pose, playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ])
        }
        func oscillate(_ id: UInt8, _ name: String,
                       _ a: String, _ b: String, times: Int = 3,
                       stepMs: Int = 250) -> MotionPage {
            guard let pa = PoseLibrary.get(a), let pb = PoseLibrary.get(b) else {
                return MotionPage(id: id, name: name, steps: [])
            }
            var steps: [MotionStep] = [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: pa.pose, playMs: 400, pauseMs: 0)
            ]
            for _ in 0..<times {
                steps.append(.from(pose: pb.pose, playMs: stepMs, pauseMs: 0))
                steps.append(.from(pose: pa.pose, playMs: stepMs, pauseMs: 0))
            }
            steps.append(.from(pose: .walkReady, playMs: 500, pauseMs: 200))
            return MotionPage(id: id, name: name, steps: steps)
        }

        var pages: [MotionPage] = []
        // ID 220+ — ROBOTIS 공식 1-54 + ReferenceMotionLibrary 110-143 +
        // prebundled 200-204 와 충돌 없음.
        var id: UInt8 = 220

        // 인사 — 깊은 인사
        pages.append(single(id, "깊은 인사", "bow_60", playMs: 1000, pauseMs: 400)); id += 1
        // 손 흔들기 — 좌우 oscillate
        pages.append(oscillate(id, "손 흔들기 (3회)", "wave_right", "wave_right_b", times: 3)); id += 1
        // 박수
        pages.append(oscillate(id, "박수 (4회)", "clap_apart", "clap_ready", times: 4, stepMs: 200)); id += 1
        // 만세
        pages.append(single(id, "만세 / 환호", "hands_up", playMs: 700, pauseMs: 500)); id += 1
        // 경례
        pages.append(single(id, "경례", "salute", playMs: 800, pauseMs: 400)); id += 1
        // 악수
        pages.append(single(id, "악수", "handshake", playMs: 700, pauseMs: 500)); id += 1
        // 가리키기 — 정면
        pages.append(single(id, "정면 가리키기", "point_forward")); id += 1
        // 가리키기 — 오른쪽
        pages.append(single(id, "오른쪽 가리키기", "point_right")); id += 1
        // 기도 / 합장
        pages.append(single(id, "합장 자세", "pray", playMs: 900, pauseMs: 600)); id += 1
        // 펀치 — 오른손
        pages.append(single(id, "오른손 펀치", "punch_right", playMs: 400, pauseMs: 100)); id += 1
        // 펀치 좌우 콤보
        pages.append(oscillate(id, "원투 콤보", "punch_left", "punch_right", times: 2, stepMs: 350)); id += 1
        // 복싱 자세
        pages.append(single(id, "복싱 가드", "fighting_stance", playMs: 500, pauseMs: 600)); id += 1
        // 스쿼트 한 번
        pages.append(oscillate(id, "스쿼트 (3회)", "squat_up", "squat_down", times: 3, stepMs: 600)); id += 1
        // 의자에 앉기
        pages.append(single(id, "의자에 앉기", "sit_chair", playMs: 1200, pauseMs: 800)); id += 1
        // 스트레칭 — 양팔
        pages.append(single(id, "양팔 스트레칭", "stretch_arms", playMs: 1000, pauseMs: 800)); id += 1
        // 좌우 보기
        pages.append(oscillate(id, "두리번거리기", "look_left", "look_right", times: 2, stepMs: 600)); id += 1
        // 위 아래 보기
        pages.append(oscillate(id, "고개 끄덕임", "look_up", "look_down", times: 2, stepMs: 400)); id += 1
        // 감정 — 환호
        pages.append(single(id, "환호 표현", "cheer", playMs: 900, pauseMs: 500)); id += 1
        // 감정 — 좌절
        pages.append(single(id, "좌절 표현", "despair", playMs: 1000, pauseMs: 600)); id += 1
        // 감정 — 생각
        pages.append(single(id, "생각하는 자세", "think", playMs: 1000, pauseMs: 800)); id += 1
        // 댄스 A↔B 교대
        pages.append(oscillate(id, "댄스 좌우", "dance_a", "dance_b", times: 3, stepMs: 350)); id += 1
        // 강남 스타일
        pages.append(oscillate(id, "강남 스타일 (말춤)", "gangnam_horse", "walk_ready", times: 4, stepMs: 300)); id += 1
        // 로봇 댄스
        pages.append(oscillate(id, "로봇 댄스", "robot_dance_a", "robot_dance_b", times: 3, stepMs: 400)); id += 1
        // 축구 — 발차기 콤보
        if let walkReady = PoseLibrary.get("walk_ready")?.pose,
           let kickBack = PoseLibrary.get("soccer_kick_right_back")?.pose,
           let kickSwing = PoseLibrary.get("soccer_kick_right_swing")?.pose {
            let kickSteps: [MotionStep] = [
                .from(pose: walkReady, playMs: 300, pauseMs: 0),
                .from(pose: kickBack, playMs: 600, pauseMs: 200),
                .from(pose: kickSwing, playMs: 400, pauseMs: 200),
                .from(pose: walkReady, playMs: 600, pauseMs: 100)
            ]
            pages.append(MotionPage(id: id, name: "축구 — 오른발 차기", steps: kickSteps))
        } else {
            DFLog.motion.warning("PoseLibrary 축구 킥 자세 누락 — 페이지 생략")
        }
        id += 1
        // 골키퍼 세이브
        pages.append(single(id, "골키퍼 세이브 (우)", "goalkeeper_save_right", playMs: 600, pauseMs: 300)); id += 1
        // 스로인
        pages.append(single(id, "스로인 자세", "throw_in_ready", playMs: 800, pauseMs: 500)); id += 1
        // 요가 — 나무 자세
        pages.append(single(id, "요가 — 나무 자세", "tree_pose", playMs: 1500, pauseMs: 2000)); id += 1
        // 요가 — 전사 자세
        pages.append(single(id, "요가 — 전사 자세", "warrior_pose", playMs: 1500, pauseMs: 2000)); id += 1
        // 요가 — 산 자세
        pages.append(single(id, "요가 — 산 자세", "mountain_pose", playMs: 1200, pauseMs: 1500)); id += 1

        // 2026-05-17 신규 mixamo 스타일 motion 33개 추가 시도 — 후속 commit 에서
        // 진단 후 별도 추가 예정. 본 commit 은 카테고리 그룹핑 UI 만.

        return pages
    }

    /// 2026-05-17 신규: mixamo 스타일 motion 30+ 추가.
    /// libraryStarterPages 와 별도 helper — 진단 용이성 (격리 가능).
    /// 같은 single/oscillate 헬퍼 사용 (guard let nil-safe).
    fileprivate static func mixamoStyleStarterPages(startId: UInt8) -> [MotionPage] {
        func single(_ id: UInt8, _ name: String, _ poseId: String,
                    playMs: Int = 800, pauseMs: Int = 200) -> MotionPage {
            guard let p = PoseLibrary.get(poseId) else {
                // ID 가 PoseLibrary 에 없으면 walk_ready hold 로 fallback — 안전.
                return MotionPage(id: id, name: name, steps: [
                    .from(pose: .walkReady, playMs: 500, pauseMs: 200)
                ])
            }
            return MotionPage(id: id, name: name, steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: p.pose, playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ])
        }
        func oscillate(_ id: UInt8, _ name: String,
                       _ a: String, _ b: String, times: Int = 3,
                       stepMs: Int = 250) -> MotionPage {
            guard let pa = PoseLibrary.get(a), let pb = PoseLibrary.get(b) else {
                return MotionPage(id: id, name: name, steps: [
                    .from(pose: .walkReady, playMs: 500, pauseMs: 200)
                ])
            }
            var steps: [MotionStep] = [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: pa.pose, playMs: 400, pauseMs: 0)
            ]
            for _ in 0..<times {
                steps.append(.from(pose: pb.pose, playMs: stepMs, pauseMs: 0))
                steps.append(.from(pose: pa.pose, playMs: stepMs, pauseMs: 0))
            }
            steps.append(.from(pose: .walkReady, playMs: 500, pauseMs: 200))
            return MotionPage(id: id, name: name, steps: steps)
        }

        var pages: [MotionPage] = []
        var id = startId

        // === 인사 변형 (5) ===
        pages.append(single(id, "정중한 인사 (느리게)", "bow_60", playMs: 1500, pauseMs: 800)); id += 1
        pages.append(single(id, "가벼운 인사 (목례)", "nod_target", playMs: 500, pauseMs: 300)); id += 1
        pages.append(single(id, "양손 흔들기", "hands_up", playMs: 600, pauseMs: 200)); id += 1
        pages.append(oscillate(id, "인사 + 박수 환영", "bow_60", "clap_apart", times: 2, stepMs: 400)); id += 1
        pages.append(oscillate(id, "양쪽 손 흔들기 콤보", "wave_left", "wave_right", times: 4, stepMs: 350)); id += 1

        // === 격투 변형 (6) ===
        pages.append(oscillate(id, "잽 — 빠른 펀치 (4회)", "punch_left", "punch_right", times: 4, stepMs: 200)); id += 1
        pages.append(oscillate(id, "원투 콤보 + 가드", "punch_right", "fighting_stance", times: 3, stepMs: 300)); id += 1
        pages.append(oscillate(id, "발차기 좌우 콤보", "kick_forward_right", "kick_forward_left", times: 2, stepMs: 500)); id += 1
        pages.append(single(id, "백 킥 (오른발)", "kick_back_right", playMs: 600, pauseMs: 300)); id += 1
        pages.append(single(id, "복싱 가드 hold", "fighting_stance", playMs: 800, pauseMs: 1000)); id += 1
        pages.append(oscillate(id, "방어 자세 (낮은 가드)", "squat_down", "fighting_stance", times: 2, stepMs: 400)); id += 1

        // === 댄스 변형 (5) ===
        pages.append(oscillate(id, "강남 스타일 (말춤 8회)", "gangnam_horse", "walk_ready", times: 8, stepMs: 280)); id += 1
        pages.append(oscillate(id, "로봇 댄스 (긴 버전)", "robot_dance_a", "robot_dance_b", times: 6, stepMs: 350)); id += 1
        pages.append(oscillate(id, "댄스 피니시 시퀀스", "dance_a", "hands_up", times: 3, stepMs: 350)); id += 1
        pages.append(oscillate(id, "박수 + 가리키기 댄스", "clap_apart", "point_forward", times: 3, stepMs: 300)); id += 1
        pages.append(oscillate(id, "좌우 스텝 댄스", "wave_left", "wave_right", times: 6, stepMs: 250)); id += 1

        // === 감정 / 표현 (6) ===
        pages.append(single(id, "환호 + 만세 콤보", "hands_up", playMs: 600, pauseMs: 800)); id += 1
        pages.append(single(id, "놀람 표현", "surprise", playMs: 500, pauseMs: 400)); id += 1
        pages.append(single(id, "부끄러움 표현", "shy", playMs: 800, pauseMs: 600)); id += 1
        pages.append(oscillate(id, "생각 → 유레카 표현", "think", "hands_up", times: 2, stepMs: 500)); id += 1
        pages.append(oscillate(id, "좌절 시퀀스 (slow)", "despair", "look_down", times: 2, stepMs: 800)); id += 1
        pages.append(oscillate(id, "둘러보기 (orientation)", "look_left", "look_right", times: 3, stepMs: 500)); id += 1

        // === 운동 / 일상 (8) ===
        pages.append(oscillate(id, "스쿼트 (5회)", "squat_up", "squat_down", times: 5, stepMs: 600)); id += 1
        pages.append(single(id, "양팔 위로 스트레칭 hold", "hands_up", playMs: 1000, pauseMs: 1500)); id += 1
        pages.append(single(id, "양팔 옆으로 스트레칭", "stretch_arms", playMs: 1200, pauseMs: 1500)); id += 1
        pages.append(single(id, "의자에 앉기 → 일어서기", "sit_chair", playMs: 1200, pauseMs: 1000)); id += 1
        pages.append(single(id, "런지 (오른쪽)", "lunge_right", playMs: 800, pauseMs: 800)); id += 1
        pages.append(oscillate(id, "방향 가리키기 시퀀스", "point_left", "point_right", times: 2, stepMs: 500)); id += 1
        pages.append(oscillate(id, "응원 (박수 + 환호)", "clap_apart", "cheer", times: 2, stepMs: 400)); id += 1
        pages.append(oscillate(id, "감사 인사 (합장 + 절)", "pray", "bow_60", times: 2, stepMs: 600)); id += 1

        // === 요가 / 밸런스 hold (3) ===
        // 2026-05-17 fix: pauseMs ≤ 2000 (MotionStep.play_time UInt8 = 255 × 8ms = 2040ms 한도).
        pages.append(single(id, "요가 — 나무 자세 hold", "tree_pose", playMs: 1500, pauseMs: 2000)); id += 1
        pages.append(single(id, "요가 — 전사 자세 hold", "warrior_pose", playMs: 1500, pauseMs: 2000)); id += 1
        pages.append(single(id, "요가 — 산 자세 hold", "mountain_pose", playMs: 1200, pauseMs: 2000)); id += 1

        return pages
    }
}
