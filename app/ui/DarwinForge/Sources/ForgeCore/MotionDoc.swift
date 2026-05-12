import Foundation

/// `forge-core::motion::Motion`의 Swift Codable 미러.
/// JSON 스키마는 `forge-core::motion::page`에 정의됨.
public struct MotionDoc: Codable, Sendable, Equatable {
    public let version: UInt32
    public var robotGeneration: String
    public var pages: [MotionPage]

    public init(version: UInt32 = 1, robotGeneration: String = "op2", pages: [MotionPage] = []) {
        self.version = version
        self.robotGeneration = robotGeneration
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey {
        case version
        case robotGeneration = "robot_generation"
        case pages
    }

    /// JSON 텍스트로 디코딩.
    public static func from(json: String) throws -> MotionDoc {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "MotionDoc", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid utf-8"])
        }
        let dec = JSONDecoder()
        return try dec.decode(MotionDoc.self, from: data)
    }

    /// JSON 텍스트로 인코딩.
    public func toJSON(prettyPrinted: Bool = true) throws -> String {
        let enc = JSONEncoder()
        if prettyPrinted { enc.outputFormatting = [.prettyPrinted, .sortedKeys] }
        let data = try enc.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `id`로 페이지 검색.
    public func page(id: UInt8) -> MotionPage? {
        pages.first { $0.id == id }
    }
}

/// 한 페이지 — 의미 있는 모션 단위 ("인사", "기본자세" 등).
public struct MotionPage: Codable, Sendable, Equatable, Identifiable {
    public var id: UInt8
    public var name: String
    public var compliance: [UInt8]   // length = 31
    public var nextPage: UInt8
    public var exitPage: UInt8
    public var `repeat`: UInt8
    public var speed: UInt8
    public var accel: UInt8
    public var steps: [MotionStep]

    public init(
        id: UInt8 = 1,
        name: String = "",
        compliance: [UInt8] = Array(repeating: 5, count: 31),
        nextPage: UInt8 = 0,
        exitPage: UInt8 = 0,
        repeat: UInt8 = 1,
        speed: UInt8 = 32,
        accel: UInt8 = 0,
        steps: [MotionStep] = [.center]
    ) {
        self.id = id
        self.name = name
        self.compliance = compliance
        self.nextPage = nextPage
        self.exitPage = exitPage
        self.repeat = `repeat`
        self.speed = speed
        self.accel = accel
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case id, name, compliance
        case nextPage = "next_page"
        case exitPage = "exit_page"
        case `repeat`, speed, accel, steps
    }
}

/// 한 step — 하나의 keyframe.
public struct MotionStep: Codable, Sendable, Equatable {
    /// 31개 raw position. 미사용 슬롯은 32767(스킵).
    public var positions: [UInt16]
    /// 도달 후 정지 시간 raw (×8 ms).
    public var pauseTime: UInt8
    /// 보간 시간 raw (×8 ms).
    public var playTime: UInt8

    public init(
        positions: [UInt16] = Array(repeating: 2048, count: 31),
        pauseTime: UInt8 = 0,
        playTime: UInt8 = 32
    ) {
        self.positions = positions
        self.pauseTime = pauseTime
        self.playTime = playTime
    }

    enum CodingKeys: String, CodingKey {
        case positions
        case pauseTime = "pause_time"
        case playTime = "play_time"
    }

    /// 모든 관절이 중심인 step.
    public static let center = MotionStep()

    public var pauseMs: Int { Int(pauseTime) * 8 }
    public var playMs: Int { Int(playTime) * 8 }

    /// `.mtn` 31-slot 인덱스 ↔ 캐논 JointID 매핑.
    /// `JointData.h` 순서: [pad, R_S_PITCH(1), L_S_PITCH(2), ..., HEAD_TILT(20), pad...]
    /// 가장 표준적인 매핑은 `positions[id - 1]` (id가 1-based).
    public func raw(for joint: JointID) -> UInt16 {
        let idx = Int(joint.rawValue) - 1
        guard idx >= 0, idx < positions.count else { return 2048 }
        return positions[idx]
    }

    /// `RobotPose`로 변환. 32767(skip)은 2048로 대체.
    public func toPose() -> RobotPose {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            let v = raw(for: j)
            dict[j] = (v == 32767) ? 2048 : Int(v)
        }
        return RobotPose(positions: dict)
    }

    /// `RobotPose`로부터 새 step 생성. 시간은 인자로.
    public static func from(pose: RobotPose, playMs: Int = 256, pauseMs: Int = 0) -> MotionStep {
        var positions = Array<UInt16>(repeating: 32767, count: 31)
        for j in JointID.allCases {
            let idx = Int(j.rawValue) - 1
            if idx >= 0, idx < positions.count {
                positions[idx] = UInt16(clamping: pose.raw(j))
            }
        }
        let play = UInt8(clamping: max(0, playMs / 8))
        let pause = UInt8(clamping: max(0, pauseMs / 8))
        return MotionStep(positions: positions, pauseTime: pause, playTime: play)
    }
}

extension MotionPage {
    /// 페이지의 step들을 `RobotPose` 시퀀스로.
    public var poses: [RobotPose] {
        steps.map { $0.toPose() }
    }

    /// 한 step의 끝 시각 (ms, 페이지 시작 기준).
    public func endTimeMs(stepIndex: Int) -> Int {
        guard stepIndex >= 0, stepIndex < steps.count else { return 0 }
        return steps.prefix(stepIndex + 1).reduce(0) { $0 + $1.playMs + $1.pauseMs }
    }

    /// 페이지 전체 길이 (ms).
    public var totalDurationMs: Int {
        steps.reduce(0) { $0 + $1.playMs + $1.pauseMs }
    }
}
