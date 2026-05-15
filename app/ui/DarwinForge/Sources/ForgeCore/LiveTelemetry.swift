import Foundation

/// 한 사이클의 텔레메트리 스냅샷 — 보드 + 관절 일부 + IMU (Sprint 18 Phase D3).
public struct TelemetrySnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let board: BoardSnapshot?
    public let joints: [JointID: JointState]
    /// CM-730/740 IMU read 결과 — 1Hz 폴링. nil = 아직 못 읽음.
    public let imu: ImuRaw?

    public init(timestamp: Date = .init(),
                board: BoardSnapshot? = nil,
                joints: [JointID: JointState] = [:],
                imu: ImuRaw? = nil) {
        self.timestamp = timestamp
        self.board = board
        self.joints = joints
        self.imu = imu
    }

    /// 빠른 액세스: 가장 뜨거운 관절.
    public var hottestJoint: (JointID, JointState)? {
        joints.max { $0.value.presentTemperature < $1.value.presentTemperature }
            .map { ($0.key, $0.value) }
    }

    /// 평균 온도(°C). 없으면 nil.
    public var avgTemperature: Double? {
        guard !joints.isEmpty else { return nil }
        let total = joints.values.reduce(0) { $0 + Int($1.presentTemperature) }
        return Double(total) / Double(joints.count)
    }

    /// 토크 ON 관절 수.
    public var torqueOnCount: Int {
        joints.values.filter { $0.torqueEnabled }.count
    }
}

/// 백그라운드에서 보드/관절 상태를 주기 폴링하는 actor.
///
/// `start()`는 AsyncStream을 반환 — UI는 `for await snap in stream { … }` 패턴으로 소비.
public actor LiveTelemetry {
    public enum Cadence: Sendable {
        /// 보드만 1 Hz (관절 X). 화면이 보드 탭일 때.
        case boardOnly
        /// 보드 1 Hz + 머리·우어깨·우무릎(샘플 4관절) 5 Hz. 평상 모드.
        case essentials
        /// 16 관절 모두 5 Hz. 무거운 모드 — 모션 디버깅 시.
        case full
    }

    private let bus: BusActor
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<TelemetrySnapshot>.Continuation?
    private var cadence: Cadence

    public init(bus: BusActor, cadence: Cadence = .essentials) {
        self.bus = bus
        self.cadence = cadence
    }

    /// 폴링 시작 — 한 actor당 한 stream만 반환.
    public func start() -> AsyncStream<TelemetrySnapshot> {
        stop()
        let (stream, cont) = AsyncStream<TelemetrySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        self.continuation = cont
        let bus = self.bus
        let cadence = self.cadence
        self.task = Task {
            await Self.runLoop(bus: bus, cadence: cadence, continuation: cont)
        }
        return stream
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    public func setCadence(_ new: Cadence) {
        self.cadence = new
    }

    deinit {
        task?.cancel()
        continuation?.finish()
    }

    // MARK: - Loop

    private static func runLoop(bus: BusActor,
                                cadence: Cadence,
                                continuation: AsyncStream<TelemetrySnapshot>.Continuation) async {
        let essentials: [JointID] = [.headPan, .headTilt, .rShoulderPitch, .rKnee]
        var tick = 0
        while !Task.isCancelled {
            let board = try? await bus.boardSnapshot()
            let joints: [JointID: JointState]
            switch cadence {
            case .boardOnly:
                joints = [:]
            case .essentials:
                joints = await bus.readStates(essentials)
            case .full:
                joints = await bus.readAllStates()
            }
            let snap = TelemetrySnapshot(board: board, joints: joints)
            continuation.yield(snap)
            tick += 1
            // 1 Hz 보드 폴링 + 200 ms 관절 폴링 — full mode면 200 ms로 통일
            let dt: UInt64 = (cadence == .boardOnly) ? 1_000_000_000 : 200_000_000
            try? await Task.sleep(nanoseconds: dt)
        }
    }
}
