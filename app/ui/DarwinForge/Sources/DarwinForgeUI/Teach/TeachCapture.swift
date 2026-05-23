import Foundation
import ForgeCore
import SwiftUI
// v1.12.0 — Telemetry harness 통합.
// v1.20.6 (사이클 206) — 스냅샷 메타데이터 UserDefaults 영속화.

/// 티칭 모드 — 사용자가 손으로 자세를 잡고 소프트웨어가 실시간으로 캡처.
///
/// 흐름:
///   1. 토크 해제 → 로봇 관절이 자유롭게 움직임
///   2. 사용자가 원하는 자세로 손으로 조작
///   3. 200ms 폴링으로 present_position read → 3D 모델 sync
///   4. 스냅샷 버튼으로 현재 자세를 RobotPose 로 저장
///   5. (옵션) 토크 복원 → 저장한 자세 유지
///
/// **사이클 206 — Snapshot Metadata Persistence**
/// RobotPose 조인트 데이터(PII 경계)는 디스크에 기록하지 않음.
/// 재시작 후 "N개의 스냅샷이 있었습니다" 표시를 위해 메타데이터(id·name·timestamp)만
/// UserDefaults 에 저장. 실제 pose 는 재캡처 필요.
@MainActor
public final class TeachCapture: ObservableObject {

    // MARK: - Persistence (사이클 206)

    /// UserDefaults key — 스냅샷 메타데이터 배열.
    static let metaDefaultsKey = "df.teach.snapshot_meta"

    /// 메타데이터 최대 보유 수 — FIFO 초과 시 오래된 항목 삭제.
    static let maxPersistedMeta: Int = 100

    /// 스냅샷 메타데이터 — pose joint 데이터 제외 (PII 경계).
    private struct PersistedSnapshotMeta: Codable {
        let id: String
        let name: String
        let timestamp: String   // ISO-8601
    }

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
    private let defaults: UserDefaults
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restorePersistedMetadata()
    }

    // MARK: - Persistence helpers (사이클 206)

    /// UserDefaults 에서 메타데이터를 읽어 복원 수를 텔레메트리로 보고.
    /// 실제 pose 는 복원하지 않음 (PII 경계).
    private func restorePersistedMetadata() {
        let count = persistedSnapshotCount
        Harness.shared.record(
            .teachSnapshotMetaRestored, level: .info, actor: .system,
            data: ["count": AnyCodable(count)]
        )
    }

    /// 사이클 212 (cycle 212 critic MINOR-1): decode 실패 시 telemetry 추가 —
    /// saveMeta 의 encode 실패 telemetry 와 대칭. 스키마 마이그레이션 시
    /// silent regression 방지.
    private func loadMeta() -> [PersistedSnapshotMeta] {
        guard let data = defaults.data(forKey: Self.metaDefaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([PersistedSnapshotMeta].self, from: data)
        } catch {
            Harness.shared.record(
                .errorException, level: .error, actor: .system,
                data: ["component": AnyCodable("TeachCapture.loadMeta"),
                       "error_type": AnyCodable(String(describing: type(of: error))),
                       "data_bytes": AnyCodable(data.count)]
            )
            return []
        }
    }

    /// 메타데이터 목록 저장.
    ///
    /// **사이클 211 (cycle 210 critic MINOR-3 응답)**: encode 실패 시 silent drop 차단 —
    /// telemetry 발화 로 debug 가능. `Codable struct (PersistedSnapshotMeta)` 의 인코딩
    /// 실패는 사실상 일어날 일이 거의 없지만 (3 필드 모두 String + 표준 JSON), 향후
    /// 스키마 확장 시 silent regression 차단.
    private func saveMeta(_ list: [PersistedSnapshotMeta]) {
        do {
            let data = try JSONEncoder().encode(list)
            defaults.set(data, forKey: Self.metaDefaultsKey)
        } catch {
            Harness.shared.record(
                .errorException, level: .error, actor: .system,
                data: ["component": AnyCodable("TeachCapture.saveMeta"),
                       "error_type": AnyCodable(String(describing: type(of: error))),
                       "list_count": AnyCodable(list.count)]
            )
        }
    }

    /// 스냅샷 메타데이터 항목 추가.
    /// 사이클 212: maxPersistedMeta 초과 시 오래된(뒤쪽) 항목 FIFO 삭제.
    private func appendMeta(for snap: PoseSnapshot) {
        var list = loadMeta()
        let entry = PersistedSnapshotMeta(
            id: snap.id.uuidString,
            name: snap.name,
            timestamp: isoFormatter.string(from: snap.capturedAt)
        )
        list.insert(entry, at: 0)
        if list.count > Self.maxPersistedMeta {
            list = Array(list.prefix(Self.maxPersistedMeta))
        }
        saveMeta(list)
    }

    /// 스냅샷 메타데이터 항목 제거.
    private func removeMeta(id: UUID) {
        let list = loadMeta().filter { $0.id != id.uuidString }
        saveMeta(list)
    }

    // MARK: - Public persistence API (사이클 206)

    /// 현재 UserDefaults 에 저장된 스냅샷 메타데이터 수.
    public var persistedSnapshotCount: Int {
        loadMeta().count
    }

    /// UserDefaults 의 메타데이터 전체 삭제 (테스트·디버그용).
    public func clearPersistedMetadata() {
        defaults.removeObject(forKey: Self.metaDefaultsKey)
    }

    /// **v1.20.1 (사이클 7)** — Sendable 추가: MotionDescriptor.teach(PoseSnapshot) 가
    /// Sendable enum 의 associated value 라 Swift 6 모드에서 conformance 필수.
    /// RobotPose / UUID / String / Date 모두 Sendable.
    public struct PoseSnapshot: Identifiable, Equatable, Sendable {
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
        // v1.12.3 telemetry — 전체 토크 해제.
        Harness.shared.record(
            .teachTorqueChanged, level: .info, actor: .user,
            data: ["action": AnyCodable("disable_all"),
                   "joint_count": AnyCodable(JointID.allCases.count)]
        )
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
        // v1.12.3 telemetry — 전체 토크 ON.
        Harness.shared.record(
            .teachTorqueChanged, level: .info, actor: .user,
            data: ["action": AnyCodable("enable_all"),
                   "joint_count": AnyCodable(JointID.allCases.count)]
        )
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
        // v1.12.3 telemetry — 단일 관절 토크 토글.
        Harness.shared.record(
            .teachTorqueChanged, level: .info, actor: .user,
            data: ["action": AnyCodable("toggle"),
                   "joint": AnyCodable(joint.name),
                   "new_state": AnyCodable(nextState ? "on" : "off")]
        )
    }

    // MARK: - Live capture

    /// 200ms 폴링으로 모든 관절 present_position read → livePose 갱신.
    public func startCapture(store: ConnectionStore) {
        guard !isCapturing else { return }
        captureTask?.cancel()
        isCapturing = true
        consecutiveFailures = 0
        // v1.12.0 telemetry — 티칭 캡처 시작.
        Harness.shared.record(
            .teachCaptureStart, level: .info, actor: .user,
            data: ["connected": AnyCodable(store.bus != nil)]
        )
        captureTask = Task { [weak self] in
            await self?.captureLoop(store: store)
        }
    }

    public func stopCapture() {
        let wasCapturing = isCapturing
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
        if wasCapturing {
            // v1.12.0 telemetry — 티칭 캡처 정지.
            Harness.shared.record(
                .teachCaptureStop, level: .info, actor: .user,
                data: ["snapshot_count": AnyCodable(snapshots.count),
                       "consec_failures": AnyCodable(consecutiveFailures)]
            )
        }
    }

    private func captureLoop(store: ConnectionStore) async {
        var autoDisableFired = false
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
                // v1.12.3 telemetry — 첫 auto-disable 전환만 기록 (루프 스팸 방지).
                if !autoDisableFired {
                    autoDisableFired = true
                    Harness.shared.record(
                        .teachTorqueChanged, level: .info, actor: .user,
                        data: ["action": AnyCodable("capture_loop_auto_disable"),
                               "joint_count": AnyCodable(JointID.allCases.count)]
                    )
                }
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
        let snap = PoseSnapshot(name: finalName, pose: livePose, capturedAt: Date())
        snapshots.insert(snap, at: 0)
        appendMeta(for: snap)   // 사이클 206 — 메타데이터 영속화
        // v1.12.2 telemetry — 자세 스냅샷 저장 (사용자 이름은 길이+해시로 redact).
        Harness.shared.record(
            .teachSnapshotCaptured, level: .notice, actor: .user,
            data: ["name_len": AnyCodable(finalName.count),
                   "name_hash": AnyCodable(Harness.shortHash(finalName)),
                   "name_was_default": AnyCodable(trimmed.isEmpty),
                   "joint_count": AnyCodable(livePose.positions.count),
                   "total_snapshots": AnyCodable(snapshots.count),
                   "snapshot_id": AnyCodable(snap.id.uuidString)]
        )
    }

    public func deleteSnapshot(_ s: PoseSnapshot) {
        snapshots.removeAll { $0.id == s.id }
        removeMeta(id: s.id)    // 사이클 206 — 메타데이터 동기화
        // v1.12.2 telemetry — 스냅샷 삭제 (name redacted).
        Harness.shared.record(
            .teachSnapshotDeleted, level: .info, actor: .user,
            data: ["name_hash": AnyCodable(Harness.shortHash(s.name)),
                   "snapshot_id": AnyCodable(s.id.uuidString),
                   "remaining": AnyCodable(snapshots.count)]
        )
    }

    public func clearSnapshots() {
        let prev = snapshots.count
        snapshots.removeAll()
        clearPersistedMetadata()    // 사이클 206 — 메타데이터 전체 삭제
        if prev > 0 {
            // v1.12.0 telemetry — 전체 스냅샷 비움.
            Harness.shared.record(
                .teachSnapshotsCleared, level: .info, actor: .user,
                data: ["count_before": AnyCodable(prev)]
            )
        }
    }

    /// 저장된 스냅샷을 로봇에 적용 — 토크 ON 상태에서 호출 권장.
    public func applySnapshot(_ s: PoseSnapshot, store: ConnectionStore) {
        // v1.12.2 telemetry — 자세 적용 (name redacted).
        Harness.shared.record(
            .teachSnapshotApplied, level: .notice, actor: .user,
            data: ["name_hash": AnyCodable(Harness.shortHash(s.name)),
                   "snapshot_id": AnyCodable(s.id.uuidString),
                   "joint_count": AnyCodable(s.pose.positions.count),
                   "bus_connected": AnyCodable(store.bus != nil)]
        )
        guard let bus = store.bus else { return }
        for (j, raw) in s.pose.positions {
            _ = try? bus.setPosition(j, raw: UInt16(clamping: raw))
        }
    }
}
