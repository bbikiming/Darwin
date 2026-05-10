import CForgeCore
import Foundation

/// 한 시점의 발 궤적 + phase.
public struct FootTargets: Sendable, Equatable {
    public let elapsedMs: Double
    public let phase: WalkPhase
    public let leftXYZ: SIMD3<Double>
    public let rightXYZ: SIMD3<Double>

    init(_ ffi: fc_foot_targets) {
        self.elapsedMs = ffi.elapsed_ms
        self.phase = WalkPhase(rawValue: ffi.phase) ?? .phase0
        let f = ffi.feet
        self.leftXYZ = SIMD3(f.0, f.1, f.2)
        self.rightXYZ = SIMD3(f.3, f.4, f.5)
    }
}

public enum WalkPhase: UInt8, Sendable {
    case phase0 = 0, phase1 = 1, phase2 = 2, phase3 = 3
    public var label: String {
        switch self {
        case .phase0: return "PHASE0 (idle)"
        case .phase1: return "PHASE1 (lift)"
        case .phase2: return "PHASE2 (DSP)"
        case .phase3: return "PHASE3 (lift)"
        }
    }
}

/// 워크 엔진 시뮬레이션 wrapper. 실 모터 명령은 발행하지 않음 (forge-core::walk가 sim only).
public final class WalkEngine: @unchecked Sendable {
    private let handle: OpaquePointer

    public init() {
        let h = fc_walk_new()!
        self.handle = OpaquePointer(h)
    }

    deinit { fc_walk_free(UnsafeMutablePointer(handle)) }

    public func setCommand(x: Double, y: Double, a: Double, enabled: Bool) {
        _ = fc_walk_set_command(UnsafeMutablePointer(handle), x, y, a, enabled ? 1 : 0)
    }

    /// dt만큼 진행 후 발 궤적 sample.
    public func tick(dtMs: UInt32) -> FootTargets {
        var out = fc_foot_targets()
        _ = fc_walk_tick(UnsafeMutablePointer(handle), dtMs, &out)
        return FootTargets(out)
    }
}
