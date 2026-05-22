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
///
/// **Phase G2 (Codex audit P0-2, 2026-05-14)**: 인덱싱 규약 ROBOTIS 공식 1:1.
/// 이전 `positions[id - 1]` (slot 0 부터 R_S_PITCH) 는 Rust/CLI/공식 Action player
/// 와 한 칸 어긋났음 → 모든 관절이 시프트되는 P0 버그였다.
///
/// **현 규약** — `Framework/include/Action.h` STEP::position[31] + `Action.cpp`의
/// `m_PlayPage.step[...].position[bID]` 와 동일:
///   - `positions[joint_id]` (slot 0 reserved, 1..20 = MX-28 joints, 21..30 reserved)
///   - INVALID marker = `0x4000` (Action.h:37 `INVALID_BIT_MASK`)
///   - TORQUE_OFF marker = `0x2000` (Action.h:38 `TORQUE_OFF_BIT_MASK`)
public struct MotionStep: Codable, Sendable, Equatable {
    /// 31개 raw position. 인덱스 == JointID rawValue. slot 0 / 21..30 은 reserved.
    /// 미사용 슬롯 marker: `0x4000` (공식 INVALID_BIT_MASK).
    public var positions: [UInt16]
    /// 도달 후 정지 시간 raw (×8 ms).
    public var pauseTime: UInt8
    /// 보간 시간 raw (×8 ms).
    public var playTime: UInt8

    /// 공식 invalid / torque-off 마커 (Action.h:37-38).
    public static let invalidBitMask: UInt16 = 0x4000
    public static let torqueOffBitMask: UInt16 = 0x2000

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

    /// JointID → raw position. ROBOTIS `position[bID]` 와 1:1.
    ///
    /// **반환값** — `positions[joint.rawValue]` 의 raw 값 그대로 (INVALID/TORQUE_OFF
    /// 마커 비트도 포함된 상태). 슬롯 범위 밖이면 `2048` fallback.
    ///
    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: 이전 doc 은 "invalid bit
    /// 만 set 된 경우 2048 로 fallback" 이라 했지만 구현은 raw 그대로 반환이라 doc 불일치.
    /// 마커 변환은 호출자 측에서 `toPose()` (단발) 또는 `toPose(previous:)` (chain) 가
    /// 명시적으로 처리. 이 함수는 row data accessor 로만 정확히 동작.
    public func raw(for joint: JointID) -> UInt16 {
        let idx = Int(joint.rawValue)
        guard idx > 0, idx < positions.count else { return 2048 }
        return positions[idx]
    }

    /// `RobotPose`로 변환 — invalid / torque-off marker 는 center (2048) 로.
    ///
    /// 공식 동작과 다르다 (공식은 invalid면 "이전 target 유지"). 이전 자세 정보가
    /// 없는 단발 미리보기용. 정확한 chain 재생 시 `toPose(previous:)` 사용.
    public func toPose() -> RobotPose {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            let v = raw(for: j)
            // 공식 마커 (0x4000 / 0x2000) 또는 우리 legacy marker (32767) 모두 center 로.
            let masked = v & (Self.invalidBitMask | Self.torqueOffBitMask)
            if masked != 0 || v == 32767 {
                dict[j] = 2048
            } else {
                dict[j] = Int(v & 0x0FFF)
            }
        }
        return RobotPose(positions: dict)
    }

    /// **ROBOTIS 공식 의미 보존 변환** — invalid bit 면 `previous` 의 해당 관절 유지.
    ///
    /// `Action.cpp:554-557`:
    /// ```c
    /// if( m_PlayPage.step[i].position[bID] & INVALID_BIT_MASK )
    ///     wCurrentTargetAngle = wpTargetAngle1024[bID];   // 이전 target 유지
    /// else
    ///     wCurrentTargetAngle = m_PlayPage.step[i].position[bID];
    /// ```
    /// chain 재생에서 step 별로 호출하면 공식 player 와 동등한 자세 시퀀스.
    public func toPose(previous: RobotPose) -> RobotPose {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            let v = raw(for: j)
            let masked = v & Self.invalidBitMask
            if masked != 0 || v == 32767 {
                dict[j] = previous.raw(j)
            } else if (v & Self.torqueOffBitMask) != 0 {
                // **사이클 124 (audit #33, P1)**: TORQUE_OFF 비트 preview placeholder 명시.
                // 본 구현은 "이전 target 유지" — ROBOTIS Action 공식 동작 (실제 토크 OFF
                // → 자세 자연 free fall) 과 다름. preview 시각화용으로만 정확.
                // 실 robot 송출은 motion_play CLI 가 별도 처리 (torque OFF 비트 해석).
                // 호출자는 본 method 가 preview semantics 임을 명시 가정해야 함.
                dict[j] = previous.raw(j)
            } else {
                dict[j] = Int(v & 0x0FFF)
            }
        }
        return RobotPose(positions: dict)
    }

    /// `RobotPose`로부터 새 step 생성. 시간은 인자로.
    ///
    /// **Phase G2**: ROBOTIS 공식 인덱싱 (`positions[joint_id]`). slot 0 / 21..30 reserved.
    /// 미사용 슬롯은 INVALID marker (`0x4000`) — 이전 32767 legacy 와 동등 의미.
    public static func from(pose: RobotPose, playMs: Int = 256, pauseMs: Int = 0) -> MotionStep {
        // 모든 슬롯 invalid marker 로 초기화 후 실제 관절만 채움.
        var positions = Array<UInt16>(repeating: invalidBitMask, count: 31)
        positions[0] = 0   // slot 0 reserved (ROBOTIS 표준 — 0으로 고정).
        for j in JointID.allCases {
            let idx = Int(j.rawValue)
            if idx > 0, idx < positions.count {
                positions[idx] = UInt16(clamping: pose.raw(j))
            }
        }
        let play = UInt8(clamping: max(0, playMs / 8))
        let pause = UInt8(clamping: max(0, pauseMs / 8))
        return MotionStep(positions: positions, pauseTime: pause, playTime: play)
    }
}

extension MotionPage {
    /// **단발 미리보기** 용 — 각 step 을 독립적으로 `toPose()` (invalid → center).
    ///
    /// ⚠️ **Phase G8 (Codex audit follow-up, 2026-05-15)**: 공식 ROBOTIS chain 의미
    /// 가 **아니다**. 공식 `Action.cpp:554-557` 은 invalid bit 면 "이전 target hold"
    /// 인데 이 함수는 각 step 을 독립으로 본다 → invalid step 의 자세가 center 로
    /// 보임. raw chain 재생 미리보기에는 [`chainedPoses(startingFrom:)`] 사용.
    public var poses: [RobotPose] {
        steps.map { $0.toPose() }
    }

    /// **ROBOTIS 공식 chain 의미** — `anchor` 자세부터 시작해서 step 별로 fold.
    ///
    /// `Action.cpp:551-557` 그대로:
    ///   - 각 step 의 invalid bit slot → 이전 step 의 target 유지
    ///   - valid bit slot → step.position 값으로 갱신
    ///
    /// **사용 예** — Motion Studio 의 raw page preview, MotionPlayer 시뮬레이션:
    /// ```swift
    /// let poses = page.chainedPoses(startingFrom: .walkReady)
    /// // poses[i] = walkReady → step1 fold → step2 fold ... step i 직후 자세
    /// ```
    ///
    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: P0-2 의 `toPose(previous:)`
    /// 를 page-level fold 로 연결 — Mac UI 가 공식 player 와 동등한 chain 자세 시퀀스를
    /// 보여줄 수 있게 됐다.
    public func chainedPoses(startingFrom anchor: RobotPose = .walkReady) -> [RobotPose] {
        var current = anchor
        return steps.map { step in
            current = step.toPose(previous: current)
            return current
        }
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
