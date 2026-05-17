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

    /// 마지막 송출 결과 — Pilot 진단 패널 표시 (v1.5 Codex 권고).
    @Published public private(set) var lastDispatchSummary: DispatchSummary?

    /// 마지막 송출 결과 요약 — 라벨, 결과, 시각.
    public struct DispatchSummary: Sendable, Equatable {
        public let label: String
        public let result: ConnectionStore.PoseApplyResult
        public let at: Date
        public var isSimOnly: Bool {
            if case .notConnected = result { return true } else { return false }
        }
    }

    public enum ArmStage: String, Sendable, Equatable {
        case idle
        case enablingPower
        case rampingTorque
        case reachingWalkready
        case ready
        case readyDegraded   // ARM 됐으나 상체 일부 토크/쓰기 실패 — 사용자 인지 필요
        case disarming
        case simReady        // 시뮬 모드 ARM — bus 미연결 상태에서 시각만
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

    /// 하체 (균형 critical) 관절 — ARM 시 1개라도 토크 실패하면 차단.
    private static let lowerBodyJoints: Set<JointID> = [
        .rHipYaw, .lHipYaw, .rHipRoll, .lHipRoll,
        .rHipPitch, .lHipPitch,
        .rKnee, .lKnee,
        .rAnklePitch, .lAnklePitch, .rAnkleRoll, .lAnkleRoll,
    ]

    /// `arm()` defer 가 보존해야 할 terminal ready stage 화이트리스트.
    /// Codex P2 fix: 이전엔 `.ready` 만 보존 → readyDegraded/simReady 가 idle 로 회귀.
    private static func isTerminalReadyStage(_ s: ArmStage) -> Bool {
        switch s {
        case .ready, .readyDegraded, .simReady: return true
        case .idle, .enablingPower, .rampingTorque, .reachingWalkready, .disarming: return false
        }
    }

    /// ARM 슬라이더 drag 완료 시 호출.
    ///
    /// 시뮬 모드(bus == nil): `gate.arm()` 호출 **안 함** (Codex 2차 권고).
    /// ARM 이라는 단어는 실 로봇 동작 허가만을 의미. 시뮬은 `.simReady` 라벨만.
    /// `sendMotion` 도 sim 모드에서는 gate 우회 — 미리보기 자유롭게.
    ///
    /// 실 로봇:
    ///   1. dxl_power ON
    ///   2. torque ON — 실패 관절 1회 retry, 그래도 하체 1개라도 실패면 ARM 차단
    ///   3. walkReady applyPoseSmoothly — `.completed` 일 때만 `gate.arm()`
    public func arm() async {
        guard let gate else { return }
        guard !gate.armed else { return }

        let isSimOnly = (store?.bus == nil)

        if isSimOnly {
            // Codex 2차 권고: sim 에서는 gate.arm() 호출하지 않음.
            // sendMotion 이 isSimOnly 분기에서 gate.allowMotion 우회.
            armStage = .simReady
            lastToast = "시뮬 모드 — ARM 불필요, 버튼 누르면 미리보기"
            lastError = nil
            return
        }

        armStage = .enablingPower
        // Codex P2 fix (2026-05-13 3차): `.ready` 만 보존하던 defer 가 `.readyDegraded`
        // / `.simReady` (이번 PR 신규 stage) 도 `.idle` 로 되돌리던 버그. Terminal
        // ready stage 전체 화이트리스트로 변경.
        defer {
            if !Self.isTerminalReadyStage(armStage) {
                armStage = .idle
            }
        }

        guard let bus = store?.bus else {
            lastError = "bus 가 사라졌어요 — 재연결 후 다시 시도"
            return
        }

        // [1] CM dxl_power ON.
        do {
            try bus.setDxlPower(true)
        } catch {
            lastError = "Dynamixel 전원 ON 실패: \(error.localizedDescription)"
            return
        }

        // [2] 모든 관절 torque ON. Codex 2차 권고: 실패 joints 1회 retry, 그래도
        //     하체 1개라도 실패면 ARM 차단 (균형 위험).
        armStage = .rampingTorque
        var failedJoints: [JointID] = []
        var lastTorqueError: String? = nil
        for j in JointID.allCases {
            do { try bus.setTorque(j, enable: true) }
            catch {
                failedJoints.append(j)
                lastTorqueError = "\(j.name): \(error.localizedDescription)"
            }
        }
        // 2026-05-17 C1 fix: 실패가 있으면 endpoint 종류별 동적 delay 후 retry.
        // USB 100ms 충분, network (TCP jitter) 는 250ms 필요. 종전 100ms hardcoded.
        if !failedJoints.isEmpty {
            let retryDelay = store?.activeEndpoint?.recommendedRetryDelayNanoseconds
                ?? 100_000_000
            try? await Task.sleep(nanoseconds: retryDelay)
            var stillFailed: [JointID] = []
            for j in failedJoints {
                do { try bus.setTorque(j, enable: true) }
                catch {
                    stillFailed.append(j)
                    lastTorqueError = "\(j.name) (retry 실패): \(error.localizedDescription)"
                }
            }
            failedJoints = stillFailed
        }
        let lowerBodyTorqueFails = failedJoints.filter { Self.lowerBodyJoints.contains($0) }
        if !lowerBodyTorqueFails.isEmpty {
            let names = lowerBodyTorqueFails.prefix(3).map { $0.name }.joined(separator: ", ")
            let suffix = lastTorqueError.map { " · 예: \($0)" } ?? ""
            lastError = "ARM 차단 — 하체 토크 \(lowerBodyTorqueFails.count)개 실패 (\(names)). USB·전원·ID 확인\(suffix)"
            return
        }
        if failedJoints.count > 3 {
            // 상체 다수 실패도 ARM 차단 — 일관성을 위해.
            let suffix = lastTorqueError.map { " · 예: \($0)" } ?? ""
            lastError = "ARM 차단 — 상체 토크 \(failedJoints.count)/\(JointID.allCases.count) 실패. 통신/전원 확인\(suffix)"
            return
        }
        let upperTorqueDegradedCount = failedJoints.count
        if upperTorqueDegradedCount > 0 {
            // 상체 1-3개 실패는 경고만 (continue) — 단, readyDegraded 로 ARM 후 표시.
            lastToast = "경고 — 상체 \(upperTorqueDegradedCount)개 토크 실패 (계속 진행)"
        }
        // 짧은 정착.
        try? await Task.sleep(nanoseconds: 250_000_000)

        lastToast = "보행 자세로 전환 중…"

        // [3] walkready 자세 (slot 9) 자동 호출 + 결과 확인.
        armStage = .reachingWalkready
        guard let walkready = MotionCatalog.find(slot: 9),
              let store else {
            lastError = "walkready 메타데이터 없음 — MotionCatalog 손상"
            return
        }
        let poseID = walkready.v1TargetPoseID ?? "walk_ready"
        guard let target = PoseLibrary.get(poseID)?.pose else {
            lastError = "walkready 자세 로드 실패 — PoseLibrary 손상"
            return
        }
        playingSlot = 9
        let resultTask: Task<ConnectionStore.PoseApplyResult, Never> = Task { @MainActor in
            await store.applyPoseSmoothly(target)
        }
        currentMotionTask = Task { _ = await resultTask.value }
        let walkReadyResult = await resultTask.value
        playingSlot = nil
        lastDispatchSummary = DispatchSummary(
            label: "보행 자세 (ARM)",
            result: walkReadyResult,
            at: Date()
        )

        // [4] walkReady 결과에 따라 ARM 분기.
        // Codex 2차: partialFailure (상체만) 은 사용자에게 경고 + 진행 가능.
        // writeFailed (하체 또는 전체 절반 이상) 은 ARM 차단.
        switch walkReadyResult {
        case .completed:
            gate.arm()
            // 상체 토크가 일부 실패한 경우는 readyDegraded 로 사용자 인지.
            armStage = (upperTorqueDegradedCount > 0) ? .readyDegraded : .ready
            if upperTorqueDegradedCount > 0 {
                lastToast = "준비 완료 (degraded) — 상체 토크 \(upperTorqueDegradedCount)개 미응답. 해당 부위 동작 약할 수 있음"
            } else {
                lastToast = "준비 완료 — 동작 버튼을 눌러보세요"
            }
            lastError = nil
        case .partialFailure(let p, let s, _, let sample):
            // walkReady 의 상체 부분 실패 — ARM 은 가능하지만 readyDegraded 로 명시.
            gate.arm()
            armStage = .readyDegraded
            let suffix = sample.map { " · 예: \($0)" } ?? ""
            lastToast = "준비 완료 (degraded) — walkReady 상체 위치 \(p)·속도 \(s) 실패\(suffix)"
            lastError = nil
        case .notConnected:
            // 시뮬 fallback — 위 isSimOnly 분기에서 처리됐어야 함.
            armStage = .simReady
            lastToast = "시뮬 모드 — ARM 불필요"
        case .rejected(let reason):
            lastError = "ARM 거부 — \(reason)"
        case .cancelled:
            lastError = "ARM 중단됨"
        case .writeFailed(let p, let s, let t, let sample):
            let suffix = sample.map { " · 예: \($0)" } ?? ""
            if p > 0 {
                lastError = "ARM 차단 — 하체 위치쓰기 \(p)개 실패 (관절 \(t)개). 균형 위험\(suffix)"
            } else {
                lastError = "ARM 차단 — 쓰기 절반 이상 실패 (위치 \(p)·속도 \(s), 관절 \(t)개)\(suffix)"
            }
        case .criticalLoad(let j):
            lastError = "ARM 중단 — \(j) 부하 위험. 정비 스탠드 확인"
        }
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

        let isSimOnly = (store?.bus == nil)

        // Codex 2차 권고: sim 에서는 gate 우회 — ARM 개념이 sim 에 없음.
        if !isSimOnly {
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
        } else if meta.safetyClass.requiresConfirm && !confirmRisk {
            // sim 에서도 high-risk 모션은 확인 요구.
            lastError = "위험 동작 — 확인 후 다시 누르세요 (시뮬도 동일 안전 흐름)"
            return false
        }

        guard let poseID = meta.v1TargetPoseID,
              let target = PoseLibrary.get(poseID)?.pose else {
            lastError = "\(meta.displayNameKo) 은(는) 후속 Sprint 에서 활성됩니다 (raw step chain 필요)"
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

        // 실 송출 — 결과를 받아 분기 (Codex 권고: 실패가 성공처럼 보이는 UX 차단).
        let motionTask: Task<ConnectionStore.PoseApplyResult, Never> = Task { @MainActor [weak self] in
            guard let self, let store = self.store else { return .notConnected }
            let r = await store.applyPoseSmoothly(target)
            _ = self
            return r
        }
        currentMotionTask = Task { _ = await motionTask.value }
        let result = await motionTask.value
        progressTask.cancel()

        lastDispatchSummary = DispatchSummary(
            label: meta.displayNameKo,
            result: result,
            at: Date()
        )

        switch result {
        case .completed:
            lastError = nil
            lastToast = "\(meta.displayNameKo) 완료"
            return true
        case .partialFailure(let p, let s, _, let sample):
            // 상체 부분 실패 — 시각 이상 가능, 안전 OK. 사용자에게 경고.
            let suffix = sample.map { " · 예: \($0)" } ?? ""
            lastError = nil
            lastToast = "\(meta.displayNameKo) 부분 완료 — 위치 \(p)·속도 \(s) 실패\(suffix)"
            return true
        case .notConnected:
            lastError = nil
            lastToast = "\(meta.displayNameKo) — 시뮬 미리보기 (실 로봇 미연결)"
            return true   // sim 은 의도된 동작 — 사용자 관점 "성공"
        case .rejected(let reason):
            lastError = "\(meta.displayNameKo) 거부 — \(reason)"
            return false
        case .cancelled:
            lastError = "\(meta.displayNameKo) 중단됨"
            return false
        case .writeFailed(let p, let s, let t, let sample):
            let suffix = sample.map { " · 예: \($0)" } ?? ""
            if p > 0 {
                lastError = "\(meta.displayNameKo) 실패 — 하체 위치쓰기 \(p)개 실패 (관절 \(t)개)\(suffix)"
            } else {
                lastError = "\(meta.displayNameKo) 실패 — 쓰기 절반 이상 실패 (위치 \(p)·속도 \(s), 관절 \(t)개)\(suffix)"
            }
            return false
        case .criticalLoad(let j):
            lastError = "\(meta.displayNameKo) 자동 정지 — \(j) 부하 위험"
            return false
        }
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
        let result = await store.applyPoseSmoothly(pose)
        lastDispatchSummary = DispatchSummary(label: label, result: result, at: Date())
        switch result {
        case .completed:
            lastError = nil
            lastToast = "\(label) 완료"
            return true
        case .partialFailure(let p, let s, _, let sample):
            let suffix = sample.map { " · 예: \($0)" } ?? ""
            lastError = nil
            lastToast = "\(label) 부분 완료 — 위치 \(p)·속도 \(s) 실패\(suffix)"
            return true
        case .notConnected:
            lastError = "로봇 미연결 — '\(label)' 송출 skip"
            return false
        case .rejected(let reason):
            lastError = "\(label) 거부 — \(reason)"
            return false
        case .cancelled:
            lastError = "\(label) 중단됨"
            return false
        case .writeFailed(let p, let s, let t, let sample):
            let suffix = sample.map { " · 예: \($0)" } ?? ""
            if p > 0 {
                lastError = "\(label) 실패 — 하체 위치쓰기 \(p)개 실패 (관절 \(t)개)\(suffix)"
            } else {
                lastError = "\(label) 실패 — 쓰기 절반 이상 실패 (위치 \(p)·속도 \(s), 관절 \(t)개)\(suffix)"
            }
            return false
        case .criticalLoad(let j):
            lastError = "\(label) 자동 정지 — \(j) 부하 위험"
            return false
        }
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
