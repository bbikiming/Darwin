import ForgeCore
import Foundation
import SwiftUI

/// Remote Pilot 의 통합 명령 채널 — PRD §5.
///
/// 책임:
///   - ARM 시퀀스: dxl_power ON → 모든 관절 torque ON → walkready 자세 도달
///   - sendMotion: 게이트 통과 후 target pose 송출 (ConnectionStore.applyPoseSmoothly 위임)
///   - emergencyStop: 진행 중인 motion 취소 + bus 토크 OFF + UI flash
///   - cancel: 사용자 disarm / ESC 등 의도적 중단
///
/// **v1.0 구현 메모**: motion_4096.bin 의 raw step SYNC_WRITE 경로는 별도 PR.
/// 본 채널은 motion slot → MotionCatalog 의 v1TargetPoseID → PoseLibrary 의
/// 검증된 RobotPose 로 매핑하고, ConnectionStore.applyPoseSmoothly 의 안전
/// 경로 (voltage / load / 한계 / split) 로 송출. v1TargetPoseID 가 nil 이면
/// "v1.5 에서 활성" 메시지로 거부.
@MainActor
public final class TeleopChannel: ObservableObject {
    /// 진행 중인 motion slot. 아무것도 진행 중이 아니면 nil.
    @Published public private(set) var playingSlot: UInt8?

    /// 진행 중인 motion 의 0..1 진행도 (UI ring 용).
    @Published public private(set) var progress: Double = 0

    /// ARM 진행 단계 — UI 토스트 / 진행 표시.
    @Published public private(set) var armStage: ArmStage = .idle

    /// 마지막 발생 오류 메시지 (UI 표시).
    @Published public private(set) var lastError: String?

    /// 마지막 토스트 메시지.
    @Published public private(set) var lastToast: String?

    public enum ArmStage: String, Sendable, Equatable {
        case idle
        case enablingPower
        case rampingTorque
        case reachingWalkready
        case ready
        case disarming
    }

    /// 진행 중인 motion 태스크 — emergencyStop 시 cancel 대상.
    private var currentMotionTask: Task<Void, Never>?

    private weak var store: ConnectionStore?
    private weak var gate: PilotSafetyGate?

    public init() {}

    /// SwiftUI StateObject init 한계 우회 — `.onAppear` 에서 env 가 도착하면 호출.
    /// 이미 attach 된 경우 noop.
    public func attach(store: ConnectionStore, gate: PilotSafetyGate) {
        self.store = store
        self.gate = gate
    }

    // MARK: - ARM / DISARM

    /// ARM 슬라이더 drag 완료 시 호출.
    /// 시뮬 모드(bus == nil) 에서는 시각만 진행 — 실제 모터 송출은 skip.
    public func arm() async {
        guard let gate else { return }
        // 이미 ARM 이면 noop.
        guard !gate.armed else { return }

        armStage = .enablingPower
        defer {
            if armStage != .ready { armStage = .idle }
        }

        if let bus = store?.bus {
            // [1] CM dxl_power ON.
            do {
                try bus.setDxlPower(true)
            } catch {
                lastError = "Dynamixel 전원 ON 실패: \(error.localizedDescription)"
                return
            }

            // [2] 모든 관절 torque ON (소프트 ramp — 추후 P_GAIN 단계화).
            armStage = .rampingTorque
            for j in JointID.allCases {
                try? bus.setTorque(j, enable: true)
            }
            // 짧은 정착.
            try? await Task.sleep(nanoseconds: 250_000_000)
        } else {
            // bus 미연결 — 시뮬 모드. 사용자에게 명확히 알림.
            lastToast = "시뮬 모드 — 실 로봇 미연결 (자세 미리보기만)"
        }

        if store?.bus != nil {
            lastToast = "보행 자세로 전환 중…"
        }

        // [3] walkready 자세 (slot 9) 자동 호출.
        armStage = .reachingWalkready
        if let walkready = MotionCatalog.find(slot: 9),
           let store {
            let poseID = walkready.v1TargetPoseID ?? "walk_ready"
            if let target = PoseLibrary.get(poseID)?.pose {
                playingSlot = 9
                let task = Task { @MainActor in
                    await store.applyPoseSmoothly(target)
                }
                currentMotionTask = task
                _ = await task.value
                playingSlot = nil
            }
        }

        // [4] 게이트 ARM.
        gate.arm()
        armStage = .ready
        lastToast = "준비 완료 — 동작 버튼을 눌러보세요"
        lastError = nil
    }

    /// 명시적 DISARM — 진행 중 motion 취소.
    public func disarm() {
        armStage = .disarming
        currentMotionTask?.cancel()
        store?.cancelMovingPose()
        playingSlot = nil
        progress = 0
        gate?.disarm()
        armStage = .idle
        lastToast = "잠금"
    }

    // MARK: - Motion send

    /// 한 motion slot 송출.
    /// 게이트 미통과 시 false 반환 + lastError 설정.
    @discardableResult
    public func sendMotion(slot: UInt8, confirmRisk: Bool) async -> Bool {
        guard let meta = MotionCatalog.find(slot: slot) else {
            lastError = "알 수 없는 슬롯: \(slot)"
            return false
        }
        guard let gate else { return false }

        switch gate.allowMotion(meta, confirmRisk: confirmRisk) {
        case .allow:
            break
        case .blockUnarmed:
            lastError = "먼저 ARM 슬라이더를 잠금 해제하세요"
            return false
        case .requireHighRiskConfirm:
            lastError = "위험 동작 — 확인 후 다시 누르세요"
            return false
        }

        guard let poseID = meta.v1TargetPoseID,
              let target = PoseLibrary.get(poseID)?.pose else {
            lastError = "\(meta.displayNameKo) 은(는) v1.5 에서 활성됩니다 (raw step 경로 필요)"
            return false
        }

        playingSlot = slot
        progress = 0
        defer {
            playingSlot = nil
            progress = 0
        }

        // 진행 ring tween — duration_ms 동안 0..1.
        let progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let frames = max(1, Int(meta.durationMs / 50))
            for i in 0..<frames {
                if Task.isCancelled { return }
                self.progress = Double(i) / Double(frames)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.progress = 1
        }

        // bus 미연결 시 미리 사용자에게 알림 — 실 송출 없이 시각만 진행.
        let isSimOnly = (store?.bus == nil)

        let motionTask = Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return }
            await store.applyPoseSmoothly(target)
            _ = self  // silence unused-self warning
        }
        currentMotionTask = motionTask
        _ = await motionTask.value
        progressTask.cancel()
        lastError = nil
        lastToast = isSimOnly
            ? "\(meta.displayNameKo) — 시뮬 미리보기 (실 로봇 미연결)"
            : "\(meta.displayNameKo) 완료"
        return true
    }

    // MARK: - Manual pose send (UI buttons that aren't motion slots)

    /// 임의 자세 송출 (Walk Lab "walk_ready 송출" 등 UI 헬퍼).
    /// 게이트는 우회 — UI 호출자가 자체 안전 (cradle 등) 책임.
    @discardableResult
    public func sendPose(_ pose: RobotPose, label: String) async -> Bool {
        guard let store else {
            lastError = "store 가 연결되지 않았어요"
            return false
        }
        guard store.bus != nil else {
            lastError = "로봇 미연결 — '\(label)' 송출 skip"
            return false
        }
        lastToast = "\(label) 송출 중…"
        await store.applyPoseSmoothly(pose)
        lastError = nil
        lastToast = "\(label) 완료"
        return true
    }

    // MARK: - E-stop

    /// 즉시 토크 OFF + motion cancel + UI flash. ⌘⇧. 어디서든 호출 가능.
    public func emergencyStop() {
        gate?.triggerFlashRed()
        currentMotionTask?.cancel()
        store?.cancelMovingPose()
        store?.emergencyStop()
        playingSlot = nil
        progress = 0
        armStage = .idle
        gate?.disarm()
        lastToast = "긴급 정지 — 토크 OFF. ARM 다시 해주세요."
    }
}
