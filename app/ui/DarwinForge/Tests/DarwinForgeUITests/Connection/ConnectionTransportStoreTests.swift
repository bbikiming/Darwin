import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// Wave 4.2.2 (사이클 V261-1) 회귀 가드.
///
/// `ConnectionStore` 의 transport state (status / 포트 / endpoint / reconnect counter) 를
/// `ConnectionTransportStore` 로 분리한 후, 동작이 byte-identical 로 보존됨을 검증.
///
/// 종전 `store.status`, `store.availablePorts`, `store.networkHost`, `store.networkPort`,
/// `store.activeEndpoint`, `store.lastSuccessfulEndpoint`, `store.reconnectAttempt`,
/// `store.isReconnecting` 직접 path 접근은 backward-compat computed delegate 로 유지.
/// 본 테스트는 새 store 의 5개 핵심 invariant 만 격리 검증.
@MainActor
final class ConnectionTransportStoreTests: XCTestCase {

    // MARK: - 1. 초기 상태 disconnected

    func testInitialStateDisconnected() {
        let store = ConnectionTransportStore()
        XCTAssertEqual(store.status, .disconnected)
        XCTAssertTrue(store.availablePorts.isEmpty)
        XCTAssertNil(store.selectedPort)
        XCTAssertNil(store.activeEndpoint)
        XCTAssertNil(store.lastSuccessfulEndpoint)
        XCTAssertEqual(store.reconnectAttempt, 0)
        XCTAssertFalse(store.isReconnecting)
    }

    // MARK: - 2. networkPort 기본값 5530 (forge serve)

    func testNetworkPortDefault5530() {
        let store = ConnectionTransportStore()
        XCTAssertEqual(store.networkPort, 5530, "default port = forge serve daemon listen port")
        XCTAssertEqual(store.networkHost, "")
    }

    // MARK: - 3. disconnected 상태에선 activeEndpoint nil

    func testEndpointEmptyWhenDisconnected() {
        let store = ConnectionTransportStore()
        XCTAssertEqual(store.status, .disconnected)
        XCTAssertNil(store.activeEndpoint, "disconnected 상태에선 endpoint 없음")

        // 연결 시뮬: status → connecting → activeEndpoint set 안 됨
        // (lifecycle 메서드가 따로 mutate — 본 테스트는 state 만 검증)
        store.status = .connecting("test")
        XCTAssertNil(store.activeEndpoint, "connecting 단계에서도 endpoint 는 아직 nil")
    }

    // MARK: - 4. status transition connecting → connected

    func testStatusTransitionConnectingToConnected() {
        let store = ConnectionTransportStore()
        XCTAssertEqual(store.status, .disconnected)

        store.status = .connecting("/dev/cu.usbserial-X")
        guard case .connecting(let label) = store.status else {
            XCTFail("connecting case 가 아님: \(store.status)"); return
        }
        XCTAssertEqual(label, "/dev/cu.usbserial-X")

        let snap = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 74, button: 0)
        store.status = .connected(snap)
        if case .connected(let bs) = store.status {
            XCTAssertEqual(bs.voltageVolts, 7.4, accuracy: 0.01)
        } else {
            XCTFail("connected case 가 아님: \(store.status)")
        }
    }

    // MARK: - 5. reset 후 모든 상태 초기값 복귀

    func testResetReturnsToDisconnected() {
        let store = ConnectionTransportStore()
        // 다양한 상태로 mutate.
        store.availablePorts = ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"]
        store.selectedPort = "/dev/cu.usbserial-A"
        store.networkHost = "10.0.0.42"
        store.networkPort = 7000
        store.activeEndpoint = .usbSerial(path: "/dev/cu.usbserial-A")
        store.status = .connected(BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 74, button: 0))
        store.recordSuccessfulEndpoint(.usbSerial(path: "/dev/cu.usbserial-A"))
        store.beginReconnecting()
        store.updateReconnectAttempt(3)

        // sanity — mutate 됐는지.
        XCTAssertFalse(store.availablePorts.isEmpty)
        XCTAssertNotNil(store.selectedPort)
        XCTAssertNotNil(store.activeEndpoint)
        XCTAssertNotNil(store.lastSuccessfulEndpoint)
        XCTAssertEqual(store.reconnectAttempt, 3)
        XCTAssertTrue(store.isReconnecting)
        if case .connected = store.status {} else { XCTFail("connected 상태여야 함") }

        store.reset()

        XCTAssertTrue(store.availablePorts.isEmpty)
        XCTAssertNil(store.selectedPort)
        XCTAssertEqual(store.status, .disconnected)
        XCTAssertNil(store.activeEndpoint)
        XCTAssertEqual(store.networkHost, "")
        XCTAssertEqual(store.networkPort, 5530, "reset 후 port default 복귀")
        XCTAssertNil(store.lastSuccessfulEndpoint)
        XCTAssertEqual(store.reconnectAttempt, 0)
        XCTAssertFalse(store.isReconnecting)
    }
}
