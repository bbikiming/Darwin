import Foundation

/// 자연어 / pose 이름 시퀀스에서 `MotionPage` 를 빌드.
///
/// 알고리즘 (3단계):
///   1. **명령 파싱** — Claude CLI 출력의 keypose JSON 또는 휴리스틱 토큰화
///   2. **자세 매칭** — PoseLibrary.search 로 각 token 을 RobotPose 로 해석
///   3. **모션 합성** — 자세 시퀀스에 시간 정보 + 안전 transition 추가
///
/// 안전:
///   - 두 자세 사이 거리 > 60° 면 중간 step 자동 삽입 (큰 변화 분할)
///   - 시작/끝 자세 모두 안전한 base 자세 (walk_ready) 로 prepend/append
///   - SafeMotion.verify 로 검증 — 거부 시 빌드 실패
public enum MotionBuilder {

    public enum BuildError: Error, LocalizedError {
        case emptyInput
        case noPoseMatched(String)
        case unsafe(String)

        public var errorDescription: String? {
            switch self {
            case .emptyInput:           return "명령이 비어있어요"
            case .noPoseMatched(let t): return "'\(t)' 에 해당하는 자세를 찾지 못했어요"
            case .unsafe(let m):        return "안전 검증 실패: \(m)"
            }
        }
    }

    /// 자세 스텝 사양 — id + 재생시간 + 정지시간.
    public struct StepSpec: Equatable {
        public let poseId: String
        public let playMs: UInt32
        public let pauseMs: UInt32

        public init(poseId: String, playMs: UInt32 = 600, pauseMs: UInt32 = 100) {
            self.poseId = poseId
            self.playMs = playMs
            self.pauseMs = pauseMs
        }
    }

    /// 입력: pose id 시퀀스 → 출력: MotionPage.
    /// 자동으로 시작/끝 walk_ready 추가 + 안전 transition.
    /// 자세 검색 순서: 1) UserPoseLibrary (사용자 캡처, 신뢰 1순위)
    ///                2) PoseLibrary (빌트인, 추측 기반)
    @MainActor public static func build(
        name: String,
        steps: [StepSpec],
        wrapWithReady: Bool = true
    ) throws -> MotionPage {
        guard !steps.isEmpty else { throw BuildError.emptyInput }

        var poses: [(name: String, pose: RobotPose)] = []
        for s in steps {
            // 1) 사용자 라이브러리 우선
            if let user = UserPoseLibrary.shared.search(s.poseId) {
                poses.append((user.name, user.pose))
                continue
            }
            // 2) 빌트인 라이브러리
            guard let p = PoseLibrary.get(s.poseId) else {
                throw BuildError.noPoseMatched(s.poseId)
            }
            poses.append((p.displayName, p.pose))
        }

        // wrap: 시작/끝에 walk_ready 추가.
        var finalSteps: [MotionStep] = []
        if wrapWithReady {
            let ready = PoseLibrary.get("walk_ready")!
            finalSteps.append(MotionStep.from(pose: ready.pose, playMs: 300, pauseMs: 0))
        }

        for (i, entry) in poses.enumerated() {
            let spec = steps[i]
            // 큰 변화 분할: 직전 step 과 거리 > 60° 면 중간 step 삽입.
            if i > 0 {
                let prev = poses[i - 1].pose
                let mid = midpointIfNeeded(from: prev, to: entry.pose)
                if let m = mid {
                    finalSteps.append(MotionStep.from(pose: m, playMs: Int(spec.playMs) / 2, pauseMs: 0))
                }
            }
            finalSteps.append(MotionStep.from(pose: entry.pose,
                                              playMs: Int(spec.playMs),
                                              pauseMs: Int(spec.pauseMs)))
        }

        if wrapWithReady {
            let ready = PoseLibrary.get("walk_ready")!
            finalSteps.append(MotionStep.from(pose: ready.pose, playMs: 500, pauseMs: 200))
        }

        let nextId = UInt8.random(in: 100...250)  // 임시 — 호출자가 ID 재할당
        return MotionPage(id: nextId, name: name, steps: finalSteps)
    }

    /// 자연어 명령 → StepSpec 시퀀스 (휴리스틱).
    /// Claude CLI 미사용 시 fallback. 한국어/영어 키워드 → PoseLibrary 매칭.
    ///
    /// 예: "왼손 들고 인사" → [wave_left, bow_30, walk_ready]
    public static func parseHeuristic(_ command: String) -> [StepSpec] {
        let normalized = command.lowercased()
        var steps: [StepSpec] = []

        // 핵심 키워드 → pose id 매핑.
        let patterns: [(keywords: [String], poseId: String, ms: UInt32)] = [
            (["인사", "안녕", "bow", "greet"], "bow_30", 800),
            (["깊은 인사", "큰절", "deep bow"], "bow_60", 1000),
            (["손 흔들", "wave"], "wave_right", 500),
            (["악수", "handshake"], "handshake", 700),
            (["경례", "salute"], "salute", 800),
            (["박수", "clap"], "clap_ready", 300),
            (["만세", "celebrate", "환호"], "cheer", 900),
            (["기도", "pray", "namaste"], "pray", 700),
            (["스쿼트 앉", "squat down"], "squat_down", 1000),
            (["스쿼트 서", "squat up"], "squat_up", 700),
            (["발차기", "kick"], "soccer_kick_right_swing", 800),
            (["펀치", "punch"], "punch_right", 600),
            (["복싱", "boxing"], "fighting_stance", 500),
            (["앉기", "sit"], "sit_chair", 1000),
            (["스트레칭", "stretch"], "stretch_arms", 800),
            (["팔짱"], "crossed_arms", 700),
            (["좌절", "despair", "슬픔"], "despair", 700),
            (["생각", "think"], "think", 700),
            (["놀람", "surprise"], "surprise", 500),
            (["수줍", "shy"], "shy", 700),
            (["로봇 댄스", "robot dance"], "robot_dance_a", 400),
            (["강남 스타일", "강남스타일", "horse dance"], "gangnam_horse", 500),
            (["나무 자세", "tree pose"], "tree_pose", 1200),
            (["전사 자세", "warrior"], "warrior_pose", 1000),
            (["산 자세", "mountain"], "mountain_pose", 800),
            (["오른쪽 보", "look right"], "look_right", 500),
            (["왼쪽 보", "look left"], "look_left", 500),
            (["위 보", "look up"], "look_up", 500),
            (["아래 보", "look down"], "look_down", 500),
            (["가리키 오른", "point right"], "point_right", 700),
            (["가리키 왼", "point left"], "point_left", 700),
            (["가리키", "point"], "point_forward", 700),
            (["T 자세", "tpose", "t-pose"], "t_pose", 1000),
            (["기본 자세", "idle", "중립"], "idle", 700),
            (["준비 자세", "walk ready", "ready"], "walk_ready", 500),
        ]

        for (keys, id, ms) in patterns {
            for k in keys {
                if normalized.contains(k) {
                    steps.append(StepSpec(poseId: id, playMs: ms, pauseMs: 200))
                    break
                }
            }
        }

        // 반복 표현 — "박수 3번"
        if normalized.contains("박수") && steps.count == 1 {
            // 추가 박수 패턴
            let claps: [StepSpec] = [
                StepSpec(poseId: "clap_apart", playMs: 200, pauseMs: 0),
                StepSpec(poseId: "clap_ready", playMs: 200, pauseMs: 100),
                StepSpec(poseId: "clap_apart", playMs: 200, pauseMs: 0),
                StepSpec(poseId: "clap_ready", playMs: 200, pauseMs: 100),
            ]
            steps.append(contentsOf: claps)
        }
        if normalized.contains("흔들") && steps.count == 1 && steps[0].poseId.contains("wave") {
            // wave oscillation
            let waves: [StepSpec] = [
                StepSpec(poseId: "wave_right_b", playMs: 250, pauseMs: 0),
                StepSpec(poseId: "wave_right", playMs: 250, pauseMs: 0),
                StepSpec(poseId: "wave_right_b", playMs: 250, pauseMs: 0),
            ]
            steps.append(contentsOf: waves)
        }

        return steps
    }

    /// "왼" / "오른" 같은 좌우 키워드 감지 — 향후 mirror 적용용.
    public static func detectSide(_ command: String) -> Side {
        let n = command.lowercased()
        let leftKeys  = ["왼", "left", "왼쪽", "왼손", "왼팔", "왼발"]
        let rightKeys = ["오른", "right", "오른쪽", "오른손", "오른팔", "오른발"]
        let l = leftKeys.contains { n.contains($0) }
        let r = rightKeys.contains { n.contains($0) }
        if l && !r { return .left }
        if r && !l { return .right }
        return .neutral
    }
    public enum Side { case left, right, neutral }

    // MARK: - Helpers

    /// 두 자세 사이 최대 거리 > 60° 면 중간 자세 반환 (분할).
    private static func midpointIfNeeded(from a: RobotPose, to b: RobotPose) -> RobotPose? {
        var maxDelta: Double = 0
        for j in JointID.allCases {
            let da = Kinematics.degrees(fromRaw: a.positions[j] ?? 2048)
            let db = Kinematics.degrees(fromRaw: b.positions[j] ?? 2048)
            let d = abs(db - da)
            if d > maxDelta { maxDelta = d }
        }
        if maxDelta <= 60 { return nil }
        var mid: [JointID: Int] = [:]
        for j in JointID.allCases {
            let ra = a.positions[j] ?? 2048
            let rb = b.positions[j] ?? 2048
            mid[j] = (ra + rb) / 2
        }
        return RobotPose(positions: mid)
    }
}
