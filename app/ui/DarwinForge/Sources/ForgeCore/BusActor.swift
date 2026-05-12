import Foundation

/// `Bus`를 actor로 wrapping해 다중 호출의 직렬화를 보장.
///
/// Dynamixel 1.0 버스는 단일 마스터/단일 큐 기준 — UI/타이머에서 동시 read·write가
/// 일어나면 패킷이 충돌한다. 모든 호출은 한 actor를 통과하므로 자연스럽게 직렬화.
public actor BusActor {
    private let bus: Bus

    public init(bus: Bus) {
        self.bus = bus
    }

    /// 새 직렬 포트 open.
    public init(portPath: String, baud: UInt32 = 1_000_000, timeoutMs: UInt32 = 200) throws {
        self.bus = try Bus(portPath: portPath, baud: baud, timeoutMs: timeoutMs)
    }

    public var portPath: String { bus.portPath }

    public func boardSnapshot() throws -> BoardSnapshot { try bus.boardSnapshot() }
    public func ping(id: UInt8) throws { try bus.ping(id: id) }
    public func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { try bus.scan(lo: lo, hi: hi) }

    public func setTorque(_ joint: JointID, enable: Bool) throws {
        try bus.setTorque(joint, enable: enable)
    }

    @discardableResult
    public func setPosition(_ joint: JointID, raw: UInt16) throws -> UInt16 {
        try bus.setPosition(joint, raw: raw)
    }

    public func readState(_ joint: JointID) throws -> JointState {
        try bus.readState(joint)
    }

    public func emergencyStop() throws { try bus.emergencyStop() }

    public func setDxlPower(_ on: Bool) throws { try bus.setDxlPower(on) }

    /// 한 번의 actor 호출로 여러 관절을 set — 호출 오버헤드 절감.
    public func setPositions(_ targets: [JointID: UInt16]) throws -> [JointID: UInt16] {
        var applied: [JointID: UInt16] = [:]
        for (joint, raw) in targets {
            applied[joint] = try bus.setPosition(joint, raw: raw)
        }
        return applied
    }

    /// 여러 관절의 토크를 한 번에 set.
    public func setTorqueAll(enable: Bool) throws {
        if !enable {
            try bus.emergencyStop()  // SYNC_WRITE 1회로 처리됨
            return
        }
        for j in JointID.allCases {
            try bus.setTorque(j, enable: true)
        }
    }

    /// 여러 관절 상태를 한 번에 read.
    public func readStates(_ joints: [JointID]) -> [JointID: JointState] {
        var out: [JointID: JointState] = [:]
        for j in joints {
            if let s = try? bus.readState(j) {
                out[j] = s
            }
        }
        return out
    }

    /// 모든 16 관절 상태 read.
    public func readAllStates() -> [JointID: JointState] {
        readStates(JointID.allCases)
    }

    /// `RobotPose`를 한 번에 적용. 적용된 raw 값을 새 pose로 반환.
    @discardableResult
    public func apply(pose: RobotPose) throws -> RobotPose {
        var applied: [JointID: Int] = [:]
        for j in JointID.allCases {
            let raw = UInt16(clamping: pose.raw(j))
            let actual = try bus.setPosition(j, raw: raw)
            applied[j] = Int(actual)
        }
        return RobotPose(positions: applied)
    }
}
