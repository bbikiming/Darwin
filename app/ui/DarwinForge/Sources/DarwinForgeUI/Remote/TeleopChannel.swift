import ForgeCore
import SwiftUI

/// 원격 조종 명령 — Swift 측 표현.
public enum TeleopCommandSwift: Sendable {
    case stop
    case motion(slot: UInt8)
    case walk(x: Double, y: Double, a: Double)
}

/// Remote Pilot 핵심 채널.
/// ARM 시퀀스, 모션 송출, E-Stop 을 담당.
/// PRD §5.2/§5.3.
@MainActor
public final class TeleopChannel: ObservableObject {
    @Published public var currentCmd: TeleopCommandSwift = .stop
    @Published public var isPlaying: Bool = false
    @Published public var lastError: String?
    @Published public var toastMessage: String?

    private weak var busActor: BusActor?
    private var currentMotionTask: Task<Void, Never>?

    public let flags = PilotFeatureFlags.default

    public init(busActor: BusActor? = nil) {
        self.busActor = busActor
    }

    // MARK: - ARM 시퀀스 (PRD §5.2)

    /// ARM 시퀀스: dxl_power ON → walkready(page 9).
    public func arm() async {
        guard let bus = busActor else {
            showToast("시뮬 모드 — 로봇 연결 없음")
            return
        }
        do {
            showToast("DXL 전원 ON…")
            try await bus.setDxlPower(true)
            showToast("보행 자세로 전환 중…")
            try await sendMotion(slot: 9, confirmRisk: false)
            let ms = MotionCatalog.find(slot: 9)?.durationMs ?? 1000
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            showToast("준비 완료")
        } catch {
            lastError = error.localizedDescription
            showToast("ARM 실패: \(error.localizedDescription)")
        }
    }

    /// 해제: 모션 취소 + dxl_power OFF.
    public func disarm() async {
        currentMotionTask?.cancel()
        currentMotionTask = nil
        currentCmd = .stop
        isPlaying = false
        if let bus = busActor {
            try? await bus.setDxlPower(false)
        }
    }

    // MARK: - 모션 송출

    /// 슬롯 모션을 실 robot 에 송출.
    /// HighRisk 모션은 confirmRisk=true 필수.
    public func sendMotion(slot: UInt8, confirmRisk: Bool) async throws {
        guard let bus = busActor else {
            await simulateMotion(slot: slot)
            return
        }

        guard let meta = MotionCatalog.find(slot: slot) else {
            throw ForgeError.generic
        }

        if meta.safetyClass == .highRisk && !confirmRisk {
            throw ForgeError.generic
        }

        currentMotionTask?.cancel()
        currentCmd = .motion(slot: slot)
        let busRef = bus
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await MainActor.run { self?.isPlaying = true }
            defer {
                Task { @MainActor [weak self] in
                    self?.isPlaying = false
                    self?.currentCmd = .stop
                }
            }
            // fc_motion_play_slot is blocking — called from detached task.
            try? await busRef.motionPlaySlot(slot: slot, confirmRisk: confirmRisk)
        }
        currentMotionTask = task
    }

    // MARK: - E-Stop (PRD §5.3)

    /// 비상 정지 — 어느 상태에서도 작동. 절대 disable 금지.
    public func emergencyStop() async {
        currentMotionTask?.cancel()
        currentMotionTask = nil
        currentCmd = .stop
        isPlaying = false
        if let bus = busActor {
            try? await bus.motionPlayCancel()
            try? await bus.emergencyStop()
        }
        showToast("⛔ 비상 정지")
    }

    // MARK: - Private helpers

    private func simulateMotion(slot: UInt8) async {
        isPlaying = true
        currentCmd = .motion(slot: slot)
        let ms = MotionCatalog.find(slot: slot)?.durationMs ?? 1000
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        isPlaying = false
        currentCmd = .stop
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toastMessage == msg { toastMessage = nil }
        }
    }
}
