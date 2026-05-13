import Foundation

/// 휴머노이드 자세 사전 — ROBOTIS-OP framework + Webots + RoboCup + 학술 자료 + 일반 인간 모션 통합.
///
/// 출처:
///   - ROBOTIS-GIT/ROBOTIS-OP2-Common/Data/motion_4096.bin (RoboPlus Motion 표준 페이지)
///   - Webots ROBOTIS-OP2 controller samples (greeting, walking, getup)
///   - RoboCup Humanoid League soccer behaviors (kick, save, throw-in)
///   - Bonn University / Hamburg TAMS DARwIn-OP papers
///   - 일반 사람 모션 사전 (MediaPipe / OpenPose annotated)
///
/// 50+ 명명 자세. 각 자세는 `RobotPose` (20 joint raw position) 로 표현.
/// 안전 한계 (Kinematics.degreeLimits) 안에서 정의.
public enum PoseLibrary {

    public struct NamedPose: Identifiable {
        public let id: String
        public let displayName: String
        public let category: Category
        public let description: String
        public let keywords: [String]
        public let pose: RobotPose

        public init(id: String, displayName: String, category: Category,
                    description: String, keywords: [String], pose: RobotPose) {
            self.id = id
            self.displayName = displayName
            self.category = category
            self.description = description
            self.keywords = keywords
            self.pose = pose
        }
    }

    public enum Category: String, CaseIterable, Identifiable, Hashable {
        case basic       // 기본/진단
        case greeting    // 인사/사회
        case sport       // 운동/스포츠
        case daily       // 일상
        case emotion     // 감정
        case dance       // 댄스/예술
        case soccer      // 축구 (RoboCup)
        case yoga        // 요가/밸런스

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .basic:    return "기본"
            case .greeting: return "인사"
            case .sport:    return "스포츠"
            case .daily:    return "일상"
            case .emotion:  return "감정"
            case .dance:    return "댄스"
            case .soccer:   return "축구"
            case .yoga:     return "요가"
            }
        }
        public var icon: String {
            switch self {
            case .basic:    return "figure.stand"
            case .greeting: return "hand.wave.fill"
            case .sport:    return "figure.run"
            case .daily:    return "figure.walk"
            case .emotion:  return "face.smiling"
            case .dance:    return "music.note"
            case .soccer:   return "soccerball"
            case .yoga:     return "figure.mind.and.body"
            }
        }
    }

    /// 모든 사전 정의 자세 — 50+.
    public static let all: [NamedPose] = build()

    private static func build() -> [NamedPose] {
        // ── ROBOTIS-OP2 URDF-consistent 부호 규약 (2026-05-13 hotfix) ─────
        //
        // 모든 자세는 RobotPose.walkReady (ROBOTIS motion_4096.bin page 9 raw) 기반.
        //
        // 부호 규약 — ROBOTIS-OP2 URDF axis 와 정합. "신체 앞쪽 / 위쪽 / 굽힘" 의도:
        //   - 어깨 Pitch (1/2): 양수 = 팔 앞·위로, 음수 = 팔 뒤로 (URDF axis (0,∓1,0))
        //                       오른쪽(1) **양수** / 왼쪽(2) **음수** — mirror pair
        //                       (★ 이전 PoseLibrary 가 정반대 부호로 작성돼 모든 팔
        //                          모션이 뒤로 가던 버그 — 2026-05-13 일괄 반전)
        //   - 어깨 Roll  (3/4): 음수 = 오른쪽으로, 양수 = 왼쪽으로. 오른쪽 음수 / 왼쪽 양수
        //   - 팔꿈치    (5/6): 굽힘. 오른쪽 양수 / 왼쪽 음수 (ROBOTIS ini_pose r_el +30)
        //   - 골반 Yaw (7/8):  좌우 회전 — 좌우 대칭
        //   - 골반 Roll (9/10): 좌우 — 대칭
        //   - 골반 Pitch(11/12): 다리 앞으로 굽힘. 오른쪽 음수 / 왼쪽 양수
        //                       (ROBOTIS ini_pose r_hip_pitch -65 = hip flex 65°)
        //   - 무릎      (13/14): 굽힘. 오른쪽 양수 / 왼쪽 음수
        //   - 발목 Pitch(15/16): 발끝 위 (dorsiflexion). 오른쪽 양수 / 왼쪽 음수
        //   - 발목 Roll (17/18): 좌우 — 대칭
        //   - 머리 Pan (19): 양수 = 오른쪽
        //   - 머리 Tilt(20): 양수 = 위 (chin up)
        //
        // 검증: mirror pair 의 abs 값 동일 + 부호 반대 → URDF mirror 정합.
        //
        // walkReady 절대값 (ROBOTIS 공식 raw → 도):
        //   shoulder_pitch R-48 / L+48 (deep squat counter-balance — 의도적 후방)
        //   shoulder_roll  R-18 / L+18
        //   elbow          R+29 / L-29
        //   hip_pitch      R-36 / L+36 (hip flex)
        //   knee           R+53 / L-53 (knee bend)
        //   ankle_pitch    R+30 / L-30 (ankle dorsiflex)
        //
        // 자세 정의 패턴: walkReady 베이스 + 한정 modification.
        // 새 자세 추가 시 위 부호표를 반드시 따를 것 — motion-composer 에이전트도 동일.

        func wrPose(_ overrides: [JointID: Double]) -> RobotPose {
            var dict = RobotPose.walkReady.positions
            for (j, d) in overrides {
                dict[j] = Kinematics.raw(fromDegrees: d)
            }
            return RobotPose(positions: dict)
        }
        let pose = wrPose

        return [

        // ── 기본/진단 ──────────────────────────────────────────
        NamedPose(id: "idle", displayName: "기본 자세",
                  category: .basic,
                  description: "워크랩과 동일 — ROBOTIS standing posture",
                  keywords: ["기본", "중립", "직립", "idle", "neutral", "stand"],
                  pose: .walkReady),

        NamedPose(id: "t_pose", displayName: "T 자세",
                  category: .basic,
                  description: "양팔 수평 — 캘리브레이션 표준",
                  keywords: ["T자세", "tpose", "T-pose", "캘리브레이션", "calibrate"],
                  pose: .tPose),

        NamedPose(id: "walk_ready", displayName: "준비 자세 (walk_ready)",
                  category: .basic,
                  description: "보행 시작 전 안전 자세 — 무릎 살짝 굽힘",
                  keywords: ["준비", "walk_ready", "ready", "보행 준비"],
                  pose: .walkReady),

        NamedPose(id: "a_pose", displayName: "A 자세",
                  category: .basic,
                  description: "양팔 45° 아래 — natural rest",
                  keywords: ["A자세", "apose", "휴식", "rest"],
                  pose: pose([
                    .rShoulderRoll: -45, .lShoulderRoll: 45
                  ])),

        // ── 인사/사회 ──────────────────────────────────────────
        NamedPose(id: "bow_30", displayName: "인사 (가벼운)",
                  category: .greeting,
                  description: "머리만 살짝 숙임 — 안전한 인사",
                  keywords: ["인사", "bow", "안녕", "greet", "hello"],
                  pose: pose([
                    .headTilt: -20    // 머리만 — 다리 + 팔 안전
                  ])),

        NamedPose(id: "bow_60", displayName: "깊은 인사",
                  category: .greeting,
                  description: "정중한 인사 — 머리 + 어깨 굽힘 (다리 그대로)",
                  keywords: ["깊은 인사", "큰절", "deep bow", "정중"],
                  pose: pose([
                    .rShoulderPitch: +15, .lShoulderPitch: -15,  // walkReady -45/+45 → -15/+15 (앞으로 30°)
                    .headTilt: -35
                  ])),

        NamedPose(id: "wave_right", displayName: "오른손 흔들기 (위)",
                  category: .greeting,
                  description: "오른팔 위 — wave 시작",
                  keywords: ["손 흔들기", "wave", "안녕", "오른손"],
                  pose: pose([
                    .rShoulderPitch: +135,    // 팔 위로 (walkReady -45 → -135 = +90° 들기)
                    .rShoulderRoll: -45,      // 어깨 벌림 (-17 → -45)
                    .rElbow: +90              // 팔꿈치 굽힘 (20 → 90)
                  ])),

        NamedPose(id: "wave_right_b", displayName: "오른손 흔들기 (옆)",
                  category: .greeting,
                  description: "wave oscillation — 손목 방향만 변경",
                  keywords: ["wave", "흔들기", "오른손"],
                  pose: pose([
                    .rShoulderPitch: +135,
                    .rShoulderRoll: -20,      // -45 ↔ -20 oscillation
                    .rElbow: +90
                  ])),

        NamedPose(id: "wave_left", displayName: "왼손 흔들기 (위)",
                  category: .greeting,
                  description: "왼팔 위 — 좌우 대칭",
                  keywords: ["왼손 흔들기", "wave left"],
                  pose: pose([
                    .lShoulderPitch: -135,
                    .lShoulderRoll: +45,
                    .lElbow: -90
                  ])),

        NamedPose(id: "handshake", displayName: "악수",
                  category: .greeting,
                  description: "오른손 앞으로 — 악수 시작",
                  keywords: ["악수", "handshake", "shake"],
                  pose: pose([
                    .rShoulderPitch: +75, .rElbow: 90, .rShoulderRoll: -10
                  ])),

        NamedPose(id: "salute", displayName: "경례",
                  category: .greeting,
                  description: "군대식 경례 — 오른손 이마 옆",
                  keywords: ["경례", "salute"],
                  pose: pose([
                    .rShoulderPitch: +130,    // 팔 거의 위
                    .rShoulderRoll: -25,      // 살짝 벌림
                    .rElbow: +110,            // 팔꿈치 깊게 굽힘
                    .headTilt: 0              // 머리 직립
                  ])),

        NamedPose(id: "clap_ready", displayName: "박수 준비",
                  category: .greeting,
                  description: "양손 모은 직전 — 박수 starting",
                  keywords: ["박수", "clap"],
                  pose: pose([
                    .rShoulderPitch: +80, .rElbow: 110, .rShoulderRoll: -45,
                    .lShoulderPitch: -80, .lElbow: -110, .lShoulderRoll: 45
                  ])),

        NamedPose(id: "clap_apart", displayName: "박수 (벌림)",
                  category: .greeting,
                  description: "박수 사이 — 양손 벌림",
                  keywords: ["박수", "clap"],
                  pose: pose([
                    .rShoulderPitch: +80, .rElbow: 80, .rShoulderRoll: -75,
                    .lShoulderPitch: -80, .lElbow: -80, .lShoulderRoll: 75
                  ])),

        NamedPose(id: "hands_up", displayName: "만세",
                  category: .greeting,
                  description: "양팔 머리 위 V자",
                  keywords: ["만세", "hands up", "V", "celebrate"],
                  pose: pose([
                    .rShoulderPitch: +160,    // 거의 수직
                    .lShoulderPitch: -160,
                    .rShoulderRoll: -30,
                    .lShoulderRoll: +30,
                    .rElbow: 0, .lElbow: 0    // 팔 펴기
                  ])),

        NamedPose(id: "point_right", displayName: "오른쪽 가리키기",
                  category: .greeting,
                  description: "오른팔로 오른쪽 가리킴",
                  keywords: ["가리키기", "point", "오른쪽"],
                  pose: pose([
                    .rShoulderPitch: +90, .rShoulderRoll: -85, .rElbow: 0,
                    .headPan: 60
                  ])),

        NamedPose(id: "point_left", displayName: "왼쪽 가리키기",
                  category: .greeting,
                  description: "왼팔로 왼쪽 가리킴",
                  keywords: ["가리키기", "point", "왼쪽"],
                  pose: pose([
                    .lShoulderPitch: -90, .lShoulderRoll: 85, .lElbow: 0,
                    .headPan: -60
                  ])),

        NamedPose(id: "point_forward", displayName: "정면 가리키기",
                  category: .greeting,
                  description: "오른팔로 정면 가리킴",
                  keywords: ["가리키기", "point forward", "앞"],
                  pose: pose([
                    .rShoulderPitch: +90, .rElbow: 0, .rShoulderRoll: -10
                  ])),

        NamedPose(id: "pray", displayName: "기도 자세",
                  category: .greeting,
                  description: "양손 가슴 앞 모으기",
                  keywords: ["기도", "pray", "namaste"],
                  pose: pose([
                    .rShoulderPitch: +45, .rElbow: 110, .rShoulderRoll: -10,
                    .lShoulderPitch: -45, .lElbow: -110, .lShoulderRoll: 10
                  ])),

        // ── 운동/스포츠 ──────────────────────────────────────────
        NamedPose(id: "squat_down", displayName: "스쿼트 (얕은)",
                  category: .sport,
                  description: "절반 스쿼트 — 균형 안전 우선",
                  keywords: ["스쿼트", "squat", "앉음"],
                  // ROBOTIS framework standing posture 의 hip/knee/ankle 비율 유지하면서 깊이 ×2.
                  // hip -8→-25, knee +16→+50, ankle -7→-25 (대칭 비율 유지 → ZMP 안정).
                  pose: pose([
                    .rHipPitch: -25, .lHipPitch: +25,
                    .rKnee: +50, .lKnee: -50,
                    .rAnklePitch: +25, .lAnklePitch: -25,
                    .rShoulderPitch: +90, .lShoulderPitch: -90  // 팔 앞으로 균형
                  ])),

        NamedPose(id: "squat_up", displayName: "스쿼트 (서기)",
                  category: .sport,
                  description: "직립 — walkReady",
                  keywords: ["스쿼트", "squat", "일어서기"],
                  pose: .walkReady),

        NamedPose(id: "lunge_right", displayName: "오른쪽 런지",
                  category: .sport,
                  description: "오른발 앞으로 lunge",
                  keywords: ["런지", "lunge"],
                  pose: pose([
                    .rHipPitch: -45, .rKnee: 80, .rAnklePitch: +35,
                    .lHipPitch: -15, .lKnee: 0,
                    .rShoulderPitch: -30, .lShoulderPitch: +30
                  ])),

        NamedPose(id: "kick_back_right", displayName: "발차기 준비 (오른발 뒤)",
                  category: .sport,
                  description: "오른발 뒤로 빼고 차기 준비",
                  keywords: ["발차기", "kick back", "준비"],
                  pose: pose([
                    .rHipPitch: +30, .rKnee: 30, .rAnklePitch: 0,
                    .lHipRoll: -15, .lHipPitch: 5,
                    .rShoulderPitch: -30, .lShoulderPitch: +30
                  ])),

        NamedPose(id: "kick_forward_right", displayName: "발차기 (오른발 앞)",
                  category: .sport,
                  description: "오른발 앞으로 차기 — 충격 순간",
                  keywords: ["발차기", "kick forward"],
                  pose: pose([
                    .rHipPitch: -60, .rKnee: 0, .rAnklePitch: +20,
                    .lHipRoll: -15,
                    .rShoulderPitch: +30, .lShoulderPitch: -30
                  ])),

        NamedPose(id: "punch_right", displayName: "오른손 펀치",
                  category: .sport,
                  description: "오른손 정면 펀치",
                  keywords: ["펀치", "punch", "주먹"],
                  pose: pose([
                    .rShoulderPitch: +90, .rElbow: 0, .rShoulderRoll: -5,
                    .lShoulderPitch: -30, .lElbow: -80
                  ])),

        NamedPose(id: "punch_left", displayName: "왼손 펀치",
                  category: .sport,
                  description: "왼손 정면 펀치",
                  keywords: ["펀치", "punch", "왼손"],
                  pose: pose([
                    .lShoulderPitch: -90, .lElbow: 0, .lShoulderRoll: 5,
                    .rShoulderPitch: +30, .rElbow: 80
                  ])),

        NamedPose(id: "fighting_stance", displayName: "복싱 자세",
                  category: .sport,
                  description: "복싱 가드 — 양손 얼굴 앞",
                  keywords: ["복싱", "boxing", "가드"],
                  pose: pose([
                    .rShoulderPitch: +60, .rElbow: 90, .rShoulderRoll: -30,
                    .lShoulderPitch: -60, .lElbow: -90, .lShoulderRoll: 30,
                    .rHipPitch: -10, .lHipPitch: +10,
                    .rKnee: 20, .lKnee: -20
                  ])),

        // ── 일상 ──────────────────────────────────────────
        NamedPose(id: "sit_chair", displayName: "의자에 앉음",
                  category: .daily,
                  description: "엉덩이를 가상 의자에 — 90° 무릎",
                  keywords: ["앉기", "sit", "의자"],
                  pose: pose([
                    .rHipPitch: -80, .lHipPitch: +80,
                    .rKnee: 90, .lKnee: -90,
                    .rAnklePitch: +10, .lAnklePitch: -10,
                    .rShoulderPitch: +10, .lShoulderPitch: -10
                  ])),

        NamedPose(id: "look_left", displayName: "왼쪽 보기",
                  category: .daily,
                  description: "머리 왼쪽 90°",
                  keywords: ["보기", "look", "왼쪽"],
                  pose: pose([.headPan: -75])),

        NamedPose(id: "look_right", displayName: "오른쪽 보기",
                  category: .daily,
                  description: "머리 오른쪽 90°",
                  keywords: ["보기", "look", "오른쪽"],
                  pose: pose([.headPan: 75])),

        NamedPose(id: "look_up", displayName: "위 보기",
                  category: .daily,
                  description: "머리 위로",
                  keywords: ["위 보기", "look up"],
                  pose: pose([.headTilt: 30])),

        NamedPose(id: "look_down", displayName: "아래 보기",
                  category: .daily,
                  description: "머리 아래로",
                  keywords: ["아래 보기", "look down"],
                  pose: pose([.headTilt: -30])),

        // ── Remote Pilot v1.5: + 더 보기 9페이지 매핑용 단발 자세 ─────
        // 끄덕임/가로젓기는 본래 multi-step chain (page 2/3 의 motion_4096.bin).
        // v1.5 는 단발 target pose 로 근사 — 사용자가 "고개가 움직였다" 정도는 인지하나
        // 실제 시각 fidelity 는 v1.6 의 motion_play library 추출 후 향상 예정.
        NamedPose(id: "nod_target", displayName: "끄덕임 단발 (v1.5 근사)",
                  category: .greeting,
                  description: "고개 살짝 숙임 — page 2 ok 의 단일 target",
                  keywords: ["끄덕임", "nod", "yes"],
                  pose: pose([.headTilt: -15])),

        NamedPose(id: "shake_target", displayName: "가로젓기 단발 (v1.5 근사)",
                  category: .greeting,
                  description: "머리 한쪽으로 — page 3 no 의 단일 target",
                  keywords: ["가로젓기", "shake", "no"],
                  pose: pose([.headPan: 20])),

        NamedPose(id: "stretch_arms", displayName: "팔 스트레칭",
                  category: .daily,
                  description: "양팔 좌우 수평 — 펴기",
                  keywords: ["스트레칭", "stretch"],
                  pose: pose([
                    .rShoulderRoll: -80, .lShoulderRoll: 80,
                    .rElbow: 10, .lElbow: -10
                  ])),

        NamedPose(id: "crossed_arms", displayName: "팔짱",
                  category: .daily,
                  description: "양팔 가슴 앞 교차",
                  keywords: ["팔짱", "crossed arms"],
                  pose: pose([
                    .rShoulderPitch: +45, .rElbow: 130, .rShoulderRoll: -30,
                    .lShoulderPitch: -45, .lElbow: -130, .lShoulderRoll: 30
                  ])),

        // ── 감정 ──────────────────────────────────────────
        NamedPose(id: "cheer", displayName: "환호",
                  category: .emotion,
                  description: "만세 + 머리 위",
                  keywords: ["환호", "cheer", "만세", "기쁨"],
                  pose: pose([
                    .rShoulderPitch: +170, .lShoulderPitch: -170,
                    .rElbow: 20, .lElbow: -20,
                    .headTilt: 20
                  ])),

        NamedPose(id: "despair", displayName: "좌절",
                  category: .emotion,
                  description: "고개 숙이고 어깨 처짐",
                  keywords: ["좌절", "despair", "슬픔"],
                  pose: pose([
                    .headTilt: -40,
                    .rShoulderPitch: -30, .lShoulderPitch: +30,
                    .rShoulderRoll: -5, .lShoulderRoll: 5
                  ])),

        NamedPose(id: "think", displayName: "생각 자세",
                  category: .emotion,
                  description: "오른손 턱 — '로댕의 생각하는 사람'",
                  keywords: ["생각", "think", "턱"],
                  pose: pose([
                    .rShoulderPitch: +50, .rElbow: 130, .rShoulderRoll: -10,
                    .headTilt: -10
                  ])),

        NamedPose(id: "surprise", displayName: "놀람",
                  category: .emotion,
                  description: "양팔 살짝 들기 + 고개 들기",
                  keywords: ["놀람", "surprise", "깜짝"],
                  pose: pose([
                    .rShoulderPitch: +45, .lShoulderPitch: -45,
                    .rShoulderRoll: -45, .lShoulderRoll: 45,
                    .rElbow: 60, .lElbow: -60,
                    .headTilt: 15
                  ])),

        NamedPose(id: "shy", displayName: "수줍음",
                  category: .emotion,
                  description: "머리 살짝 옆 + 한 팔 가슴",
                  keywords: ["수줍음", "shy"],
                  pose: pose([
                    .headPan: -20, .headTilt: -15,
                    .rShoulderPitch: +30, .rElbow: 90, .rShoulderRoll: -30
                  ])),

        // ── 댄스 ──────────────────────────────────────────
        NamedPose(id: "dance_a", displayName: "댄스 A — 한팔 위",
                  category: .dance,
                  description: "한팔 위, 한팔 옆",
                  keywords: ["댄스", "dance"],
                  pose: pose([
                    .rShoulderPitch: +150, .rElbow: 30,
                    .lShoulderRoll: 80, .lElbow: -10
                  ])),

        NamedPose(id: "dance_b", displayName: "댄스 B — 좌우 반전",
                  category: .dance,
                  description: "댄스 A 의 좌우 반전",
                  keywords: ["댄스", "dance"],
                  pose: pose([
                    .lShoulderPitch: -150, .lElbow: -30,
                    .rShoulderRoll: -80, .rElbow: 10
                  ])),

        NamedPose(id: "gangnam_horse", displayName: "강남스타일 — 말춤",
                  category: .dance,
                  description: "양손 앞으로 — 말 잡기",
                  keywords: ["강남스타일", "말춤", "horse dance"],
                  pose: pose([
                    .rShoulderPitch: +80, .rElbow: 90, .rShoulderRoll: -20,
                    .lShoulderPitch: -80, .lElbow: -90, .lShoulderRoll: 20,
                    .rHipPitch: -20, .lHipPitch: +20,
                    .rKnee: 30, .lKnee: -30
                  ])),

        NamedPose(id: "robot_dance_a", displayName: "로봇 댄스 A",
                  category: .dance,
                  description: "각진 로봇 모션 — 양팔 직각",
                  keywords: ["로봇댄스", "robot dance"],
                  pose: pose([
                    .rShoulderPitch: +90, .rElbow: 90,
                    .lShoulderPitch: -30
                  ])),

        NamedPose(id: "robot_dance_b", displayName: "로봇 댄스 B",
                  category: .dance,
                  description: "로봇 댄스 A 의 좌우 반전",
                  keywords: ["로봇댄스", "robot dance"],
                  pose: pose([
                    .lShoulderPitch: -90, .lElbow: -90,
                    .rShoulderPitch: +30
                  ])),

        // ── 축구 (RoboCup) ──────────────────────────────────────────
        NamedPose(id: "soccer_ready", displayName: "축구 준비",
                  category: .soccer,
                  description: "RoboCup 시작 자세 — 무릎 살짝 굽힘",
                  keywords: ["축구", "soccer", "준비"],
                  pose: .walkReady),

        NamedPose(id: "soccer_kick_right_back", displayName: "오른발 차기 백스윙",
                  category: .soccer,
                  description: "오른발 뒤로 빼고 골 차기 준비",
                  keywords: ["축구", "kick", "백스윙"],
                  pose: pose([
                    .rHipPitch: +25, .rKnee: 40, .rAnklePitch: -10,
                    .lHipRoll: -10, .lHipPitch: -5,
                    .rShoulderPitch: -35, .lShoulderPitch: +35
                  ])),

        NamedPose(id: "soccer_kick_right_swing", displayName: "오른발 차기 임팩트",
                  category: .soccer,
                  description: "오른발 앞으로 임팩트 순간",
                  keywords: ["축구", "kick", "임팩트"],
                  pose: pose([
                    .rHipPitch: -50, .rKnee: 5, .rAnklePitch: +25,
                    .lHipRoll: -12,
                    .rShoulderPitch: +25, .lShoulderPitch: -25
                  ])),

        NamedPose(id: "goalkeeper_save_right", displayName: "골키퍼 오른쪽 세이브",
                  category: .soccer,
                  description: "오른쪽으로 다이빙",
                  keywords: ["골키퍼", "save", "다이빙"],
                  pose: pose([
                    .rShoulderRoll: -80, .lShoulderRoll: 80,
                    .rElbow: 20, .lElbow: -20,
                    .rHipRoll: -25,
                    .rHipPitch: 30, .lHipPitch: -10
                  ])),

        NamedPose(id: "throw_in_ready", displayName: "스로인 준비",
                  category: .soccer,
                  description: "양손 머리 위 (양팔 90°)",
                  keywords: ["스로인", "throw in"],
                  pose: pose([
                    .rShoulderPitch: +160, .lShoulderPitch: -160,
                    .rElbow: 70, .lElbow: -70
                  ])),

        // ── 요가/밸런스 ──────────────────────────────────────────
        NamedPose(id: "tree_pose", displayName: "나무 자세 (한 발)",
                  category: .yoga,
                  description: "오른발로 서고 왼발 들기",
                  keywords: ["요가", "나무", "tree", "balance"],
                  pose: pose([
                    .lHipPitch: +40, .lKnee: -80, .lAnklePitch: 0,
                    .lHipRoll: 15,
                    .rShoulderPitch: +160, .lShoulderPitch: -160,
                    .rElbow: 30, .lElbow: -30
                  ])),

        NamedPose(id: "warrior_pose", displayName: "전사 자세",
                  category: .yoga,
                  description: "오른발 앞, 양팔 수평",
                  keywords: ["요가", "전사", "warrior"],
                  pose: pose([
                    .rHipPitch: -30, .rKnee: 60, .rAnklePitch: +25,
                    .lHipPitch: -15,
                    .rShoulderRoll: -85, .lShoulderRoll: 85
                  ])),

        NamedPose(id: "mountain_pose", displayName: "산 자세",
                  category: .yoga,
                  description: "양팔 머리 위로 합장",
                  keywords: ["요가", "산", "mountain"],
                  pose: pose([
                    .rShoulderPitch: +170, .lShoulderPitch: -170,
                    .rShoulderRoll: -5, .lShoulderRoll: 5,
                    .rElbow: 10, .lElbow: -10
                  ])),
        ]
    }

    // MARK: - Lookup helpers

    /// id 로 자세 조회.
    public static func get(_ id: String) -> NamedPose? {
        all.first { $0.id == id }
    }

    /// keyword (한국어/영어 어떤 것이든) 로 검색 — 가장 매칭 점수 높은 자세 반환.
    public static func search(_ query: String) -> NamedPose? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var best: (NamedPose, Int)? = nil
        for p in all {
            var score = 0
            if p.id.contains(q) { score += 5 }
            if p.displayName.lowercased().contains(q) { score += 4 }
            for k in p.keywords {
                if k.lowercased().contains(q) || q.contains(k.lowercased()) { score += 3 }
            }
            if p.description.lowercased().contains(q) { score += 1 }
            if score > 0 {
                if best == nil || score > best!.1 { best = (p, score) }
            }
        }
        return best?.0
    }

    /// 카테고리별 그룹.
    public static func byCategory(_ c: Category) -> [NamedPose] {
        all.filter { $0.category == c }
    }
}
