import Foundation
import ForgeCore

/// 앱 전체에 공유되는 연결 상태. 한 번에 하나의 Bus만 활성.
@MainActor
public final class ConnectionStore: ObservableObject {
    public enum Status: Equatable {
        case disconnected
        case connecting(String)
        case connected(BoardSnapshot)
        case error(String)
    }

    @Published public var availablePorts: [String] = []
    @Published public var selectedPort: String?
    @Published public var status: Status = .disconnected
    @Published public var bus: Bus?
    @Published public var jointStates: [JointID: JointState] = [:]

    public init() {}

    /// `/dev/cu.*` 후보 새로고침. 실패하면 에러 set.
    public func refreshPorts() {
        do {
            self.availablePorts = try SerialPortEnumerator.available()
            if selectedPort == nil {
                selectedPort = availablePorts.first
            } else if let p = selectedPort, !availablePorts.contains(p) {
                selectedPort = availablePorts.first
            }
        } catch {
            self.status = .error("포트 열거 실패: \(error.localizedDescription)")
        }
    }

    /// 선택된 포트로 연결 시도. board snapshot까지 가져오면 .connected.
    public func connect() {
        guard let port = selectedPort, !port.isEmpty else {
            status = .error("포트 선택 필요")
            return
        }
        status = .connecting(port)
        do {
            let bus = try Bus(portPath: port)
            let snap = try bus.boardSnapshot()
            self.bus = bus
            self.status = .connected(snap)
        } catch let e as ForgeError {
            self.status = .error("연결 실패: \(e.localizedDescription)")
        } catch {
            self.status = .error("연결 실패: \(error.localizedDescription)")
        }
    }

    /// 연결 해제.
    public func disconnect() {
        bus = nil
        jointStates.removeAll()
        status = .disconnected
    }

    /// 응급 e-stop — 모든 관절 토크 OFF.
    public func emergencyStop() {
        guard let bus else { return }
        do {
            try bus.emergencyStop()
        } catch {
            status = .error("e-stop 실패: \(error.localizedDescription)")
        }
    }

    /// 한 관절 상태 갱신.
    public func refreshJointState(_ joint: JointID) {
        guard let bus else { return }
        do {
            jointStates[joint] = try bus.readState(joint)
        } catch {
            // 단일 관절 실패는 status에 영향 X — 로그 출력만.
            print("readState(\(joint.name)) failed: \(error)")
        }
    }
}
