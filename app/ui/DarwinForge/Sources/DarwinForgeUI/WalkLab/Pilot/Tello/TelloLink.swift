import Foundation
import Network

/// **v1.17.0 (2026-05-21) — Phase 4 첫 단계: Tello UDP 조종기 통합**.
///
/// DJI 조사 결과 (`docs/handoff/2026-05-21-DJI-REMOTE-CONTROL-DEFERRED.md` + research):
/// - DJI Mobile SDK = iOS 전용, macOS 직접 불가능
/// - DJI Onboard SDK = Linux 전용
/// - **Tello SDK = macOS native, UDP text, 즉시 구현 가능** ← 본 모듈 선택
///
/// Tello 는 Ryze Tech (DJI 자회사) 의 학습용 드론. SDK 가 가장 단순:
/// - Command port: UDP `192.168.10.1:8889` (Tello 가 host)
/// - State port: UDP `0.0.0.0:8890` (Tello 가 client)
/// - Text 명령 (ASCII): `command`, `takeoff`, `land`, `rc <lr> <fb> <ud> <yaw>`
///
/// # 사용 패턴
///
/// 1. 사용자가 Tello Wi-Fi AP (TELLO-XXXX) 에 macOS 접속
/// 2. `link.start()` → "command" 명령 → Tello SDK 모드 진입
/// 3. `link.rc(lr:fb:ud:yaw:)` 호출 시 stick value → robot X/Y/A amplitude 매핑
///
/// # Mock-first 설계
///
/// 실 Tello 없이 테스트 가능하도록 `TelloLinkProtocol` 으로 추상화. `MockTelloLink`
/// 가 in-memory queue 로 명령 기록 — XCTest 검증.
public protocol TelloLinkProtocol: Sendable {
    /// SDK 모드 진입 — 모든 명령 전 1회 호출.
    func start() async throws
    /// stick 입력 — 각 채널 -100..100. 권장 5Hz 이상 (Tello 가 200ms 미수신 시 hover).
    func sendRC(lr: Int, fb: Int, ud: Int, yaw: Int) async
    /// 비상 정지 (Tello 자체 명령 — 모터 즉시 정지).
    func emergency() async
    /// 종료 — UDP socket close.
    func stop()
}

/// 실 Tello UDP 구현. macOS Network framework 사용.
public final class TelloLink: TelloLinkProtocol, @unchecked Sendable {

    // MARK: - 명령 채널 (UDP 8889)

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port = 8889
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "TelloLink.udp", qos: .userInitiated)

    /// 직전 RC 명령 — debug + UI 표시 용. nil = 미전송.
    public private(set) var lastRC: (lr: Int, fb: Int, ud: Int, yaw: Int)?
    /// 명령 송신 횟수 — Harness 통계.
    public private(set) var sentCount: Int = 0

    /// init — default Tello IP. 사용자가 다른 host 지정 가능 (예: localhost mock).
    public init(host: String = "192.168.10.1") {
        self.host = .init(host)
    }

    public func start() async throws {
        connection = NWConnection(host: host, port: port, using: .udp)
        connection?.start(queue: queue)
        // SDK 진입 — "command" 명령.
        await sendRaw("command")
    }

    public func sendRC(lr: Int, fb: Int, ud: Int, yaw: Int) async {
        // 각 채널 clamp -100..100 (Tello SDK spec).
        let cl = max(-100, min(100, lr))
        let cf = max(-100, min(100, fb))
        let cu = max(-100, min(100, ud))
        let cy = max(-100, min(100, yaw))
        await sendRaw("rc \(cl) \(cf) \(cu) \(cy)")
        lastRC = (cl, cf, cu, cy)
    }

    public func emergency() async {
        await sendRaw("emergency")
    }

    public func stop() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - 내부 raw send

    private func sendRaw(_ cmd: String) async {
        guard let conn = connection else { return }
        let data = cmd.data(using: .ascii) ?? Data()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.sentCount += 1
                cont.resume()
            })
        }
    }
}
