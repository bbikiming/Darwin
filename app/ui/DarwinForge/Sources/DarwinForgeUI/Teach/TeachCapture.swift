import Foundation
import ForgeCore
import SwiftUI

/// 티칭 모드 — 사용자가 손으로 자세를 잡고 소프트웨어가 실시간으로 캡처.
///
/// 흐름:
///   1. 토크 해제 → 로봇 관절이 자유롭게 움직임
///   2. 사용자가 원하는 자세로 손으로 조작
///   3. 200ms 폴링으로 present_position read → 3D 모델 sync
///   4. 스냅샷 버튼으로 현재 자세를 RobotPose 로 저장
///   5. (옵션) 토크 복원 → 저장한 자세 유지
@MainActor
public final class TeachCapture: ObservableObject {

    /// 현재 캡처된 라이브 포즈 — 매 200ms 갱신.
    @Published public private(set) var livePose: RobotPose = .center
    /// 캡처 활성 여부.
    @Published public private(set) var isCapturing: Bool = false
    /// 관절별 토크 상태 (UI 표시용).
    @Published public private(set) var torqueState: [JointID: Bool] = [:]
    /// 저장된 스냅샷.
    @Published public private(set) var snapshots: [PoseSnapshot] = []
    /// 마지막 캡처 시각 — UI 의 "방금" 표시용.
    @Published public private(set) var lastUpdateAt: Date?
    /// 통신 통계 — 실패율 / 라이브 RTT.
    @Published public private(set) var readMs: Double = 0
    @Published public private(set) var consecutiveFailures: Int = 0

    private var captureTask: Task<Void, Never>?

    public init() {}

    public struct PoseSnapshot: Identifiable, Equatable {
        public let id = UUID()
        public let name: String
        public let pose: RobotPose
        public let capturedAt: Date
    }

    // MARK: - Torque control

    /// 모든 관절 토크 해제 — 로봇이 free-moving 상태.
    public func disableAllTorque(store: ConnectionStore) async {
        guard let bus = store.bus else { return }
        for j in JointID.allCases {
            do {
                try bus.setTorque(j, enable: false)
                torqueState[j] = false
            } catch {
                // 일부 실패해도 계속.
            }
        }
    }

    /// 모든 관절 토크 ON — 현재 자세 유지 (저장한 자세 hold).
    public func enableAllTorque(store: ConnectionStore) async {
        guard let bus = store.bus else { return }
        for j in JointID.allCases {
            do {
                try bus.setTorque(j, enable: true)
                torqueState[j] = true
            } catch {
                // 일부 실패해도 계속.
            }
        }
    }

    /// 한 관절만 토글.
    public func toggleTorque(_ joint: JointID, store: ConnectionStore) {
        guard let bus = store.bus else { return }
        let nextState = !(torqueState[joint] ?? false)
        do {
            try bus.setTorque(joint, enable: nextState)
            torqueState[joint] = nextState
        } catch {
            // ignore
        }
    }

    // MARK: - Live capture

    /// 200ms 폴링으로 모든 관절 present_position read → livePose 갱신.
    public func startCapture(store: ConnectionStore) {
        guard !isCapturing else { return }
        captureTask?.cancel()
        isCapturing = true
        consecutiveFailures = 0
        captureTask = Task { [weak self] in
            await self?.captureLoop(store: store)
        }
    }

    public func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
    }

    private func captureLoop(store: ConnectionStore) async {
        while !Task.isCancelled {
            guard let bus = store.bus else {
                isCapturing = false
                return
            }
            let t0 = Date()
            var positions: [JointID: Int] = [:]
            var failed = 0
            for j in JointID.allCases {
                do {
                    let s = try bus.readState(j)
                    positions[j] = Int(s.presentPosition)
                    torqueState[j] = s.torqueEnabled
                } catch {
                    failed += 1
                }
            }
            let rtt = Date().timeIntervalSince(t0) * 1000
            readMs = rtt
            if failed == JointID.allCases.count {
                consecutiveFailures += 1
                if consecutiveFailures > 5 {
                    isCapturing = false
                    return
                }
            } else {
                consecutiveFailures = 0
                if !positions.isEmpty {
                    livePose = RobotPose(positions: positions)
                    lastUpdateAt = Date()
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Snapshots

    /// 현재 livePose 를 스냅샷으로 저장.
    public func snapshot(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? "자세 \(snapshots.count + 1)"
            : trimmed
        snapshots.insert(
            PoseSnapshot(name: finalName, pose: livePose, capturedAt: Date()),
            at: 0
        )
    }

    public func deleteSnapshot(_ s: PoseSnapshot) {
        snapshots.removeAll { $0.id == s.id }
    }

    public func clearSnapshots() {
        snapshots.removeAll()
    }

    /// 저장된 스냅샷을 로봇에 적용 — 토크 ON 상태에서 호출 권장.
    public func applySnapshot(_ s: PoseSnapshot, store: ConnectionStore) {
        guard let bus = store.bus else { return }
        for (j, raw) in s.pose.positions {
            _ = try? bus.setPosition(j, raw: UInt16(clamping: raw))
        }
    }
}
