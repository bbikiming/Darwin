import Foundation
import GameController
import SwiftUI

/// 통합 「컨트롤러 연결」 시트의 **DJI 연결 보조 컨트롤러** — 검색·진단·Mock 데모.
///
/// (종전 `CockpitDJIPanel` 에서 패널 UI 를 분리하고 연결 로직만 남긴 것. 라이브
/// HID→로봇 경로는 `DJIVirtualJoystickWatcher` 가, 매핑 UI 는
/// `CockpitDJIBindingSheet` 가 담당한다.)
///
/// # 두 가지 경로
///
/// 1. **MFi 호환 RC (DJI RC-N1 등)** → `GameController.framework` 가 자동 인식,
///    `CockpitGameControllerWatcher` 가 stick 입력 push. `diagnostics` 가
///    인식된 컨트롤러 목록을 노출한다.
///
/// 2. **DJI FPV Remote Controller 3 등 MFi 미인증 USB HID** →
///    `DJIVirtualJoystickHIDClient` 가 **IOKit HID Manager** 로 직접 매칭
///    (vendor=0x2CA3, product=0x1021, "DJI Virtual Joystick"). MFi 인증이 없어
///    `GameController.framework` 가 무시하는 디바이스도 본 경로로 잡힌다.
///
/// 두 경로는 동시에 active 가능하다. cockpit `apply(...)` 는 마지막 호출만 보존하므로
/// 두 source 가 idle 일 때 다른 쪽이 자연스럽게 통제권을 가진다.
///
/// 추가로 컨트롤러 없이도 입력 → 모션 흐름을 확인할 수 있도록 **Mock DJI 데모**
/// (자동 stick 패턴) 옵션도 제공한다. Mock 진입 시 통합 시트가 HID watcher 를
/// `pauseStreaming` 시켜 사용자 혼란을 막는다.
@MainActor
public final class CockpitDJIController: ObservableObject {

    public enum Status: Equatable {
        case idle
        case searching
        case connected(name: String)
        case mockActive
        case notFound
    }

    @Published public private(set) var status: Status = .idle
    /// USB / BT controller diagnostics — refreshed every poll for the UI.
    /// `GameController.framework` 가 인식한 모든 컨트롤러를 그대로 노출하여
    /// 사용자가 USB 연결이 인식 안 되는 원인을 즉시 진단할 수 있다.
    @Published public private(set) var diagnostics: [ControllerDiagnostic] = []

    public struct ControllerDiagnostic: Identifiable, Equatable {
        public let id = UUID()
        public let vendorName: String
        public let productCategory: String
        public let hasExtendedGamepad: Bool
        public let hasMicroGamepad: Bool
        public let isAttachedToDevice: Bool
    }

    private weak var cockpit: CockpitState?
    private var searchTask: Task<Void, Never>?
    private var mockTimer: Timer?
    private var mockStartedAt: Date?
    /// 1Hz polling timer — 사용자가 패널을 열어 두는 동안 USB 연결/해제 변화를
    /// 즉시 시각화. notification-only 였던 종전 watcher 는 일부 USB HID 가 적시에
    /// notification 을 발사하지 않는 경우를 놓쳤다 (사용자 보고).
    private var diagnosticsTimer: Timer?

    public init(cockpit: CockpitState) {
        self.cockpit = cockpit
        refreshDiagnostics()
    }

    public func startDiagnosticsPolling() {
        guard diagnosticsTimer == nil else { return }
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                                repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDiagnostics() }
        }
    }

    public func stopDiagnosticsPolling() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func refreshDiagnostics() {
        diagnostics = GCController.controllers().map { c in
            ControllerDiagnostic(
                vendorName: c.vendorName ?? "Unknown",
                productCategory: c.productCategory,
                hasExtendedGamepad: c.extendedGamepad != nil,
                hasMicroGamepad: c.microGamepad != nil,
                isAttachedToDevice: c.isAttachedToDevice)
        }
    }

    // MARK: - Search

    public func startSearch() {
        cancelMock()
        status = .searching
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // 4-second discovery window. 실제로 GameController.framework 가 즉시
            // 알아챌 가능성이 높지만 사용자 인지를 위해 진행 표시 유지.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                if let name = await self.detectController() {
                    self.status = .connected(name: name)
                    return
                }
            }
            await MainActor.run {
                guard let self else { return }
                if case .connected = self.status { return }
                self.status = .notFound
            }
        }
    }

    public func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        status = .idle
    }

    public func updateFromWatcher() {
        // 컨트롤러가 watcher 에서 자동 연결 → status 동기화.
        if let name = cockpit?.connectedController,
           case .connected(let cur) = status, cur == name {
            return  // 이미 same
        }
        if let name = cockpit?.connectedController {
            status = .connected(name: name)
        } else if case .connected = status {
            status = .idle
        }
    }

    @MainActor
    private func detectController() -> String? {
        if let name = cockpit?.connectedController { return name }
        return GCController.controllers().first?.vendorName
    }

    // MARK: - Mock DJI demo

    /// 30 Hz mock stick driver — 사용자가 실제 컨트롤러 없이도 cockpit 의
    /// stick → motion 흐름을 시각적으로 검증할 수 있게 자동 패턴 송신.
    ///
    /// 패턴 (12초 cycle):
    /// - 0-3s : 전진 (leftY=-0.8)
    /// - 3-5s : 우회전 (turn=+0.6) + 약한 전진
    /// - 5-7s : 좌회전 (turn=-0.6) + 약한 전진
    /// - 7-10s: 측면 우 (leftX=+0.8)
    /// - 10-12s: 정지
    public func startMockDemo() {
        cancelSearch()
        status = .mockActive
        mockStartedAt = Date()
        mockTimer?.invalidate()
        mockTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMock() }
        }
    }

    public func stopMockDemo() {
        mockTimer?.invalidate()
        mockTimer = nil
        mockStartedAt = nil
        cockpit?.apply(leftX: 0, leftY: 0, turn: 0, from: .djiRC)
        status = .idle
    }

    private func cancelMock() {
        if mockTimer != nil {
            stopMockDemo()
        }
    }

    private func tickMock() {
        // **CRITICAL #1 fix (code review)**: 종전 case 3..<5 가 `tn = 0.6` 직후
        // `tn = -0.6` dead write — case 5..<7 의 `tn = 0.6` (좌회전) 와 같은
        // 효과가 되어 두 구간 모두 좌회전이었다. 명시 분기로 좌/우 회전 패턴 복원.
        guard let cockpit, let start = mockStartedAt else { return }
        let t = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: 12.0)
        var lx = 0.0
        var ly = 0.0
        var tn = 0.0
        switch t {
        case 0..<3:
            ly = -0.8                 // 전진
        case 3..<5:
            ly = -0.3
            tn = -0.6                 // 우회전 (turn -1 = 우)
        case 5..<7:
            ly = -0.3
            tn = 0.6                  // 좌회전 (turn +1 = 좌)
        case 7..<10:
            lx = 0.8                  // 측면 우
        default:
            break                     // 정지
        }
        cockpit.apply(leftX: lx, leftY: ly, turn: tn, from: .djiRC)
    }
}
