import CForgeCore
import Foundation

/// `forge-core`가 반환하는 에러 코드 (forge_core.h `FC_*` 매핑).
public enum ForgeError: Int32, Error, Equatable, Sendable {
    case generic        = -1
    case invalid        = -2
    case io             = -3
    case timeout        = -4
    case codec          = -5
    case deviceNotFound = -6
    /// S4 — 진행 중 read 가 E-STOP 선점으로 조기 abort. 오류가 아닌 의도된 중단 —
    /// 백그라운드 리더/폴러는 disconnect 로 취급하지 말고 무음 skip 해야 한다.
    case estopPreempted = -7
    case panic          = -99

    /// FFI raw → enum (FC_OK 0은 nil).
    public init?(raw: Int32) {
        if raw == FC_OK { return nil }
        self.init(rawValue: raw)
    }

    /// 코드를 못 찾으면 .generic.
    public static func from(_ raw: Int32) -> ForgeError? {
        if raw == FC_OK { return nil }
        return ForgeError(rawValue: raw) ?? .generic
    }

    /// 사람이 읽는 메시지.
    public var localizedDescription: String {
        switch self {
        case .generic:        return "generic error from forge-core"
        case .invalid:        return "invalid argument"
        case .io:             return "serial I/O error"
        case .timeout:        return "device did not respond in time"
        case .codec:          return "Dynamixel packet decode error"
        case .deviceNotFound: return "device did not respond on bus"
        case .estopPreempted: return "read aborted by e-stop preempt"
        case .panic:          return "forge-core panicked (bug)"
        }
    }
}

/// `fc_*` 함수가 반환한 C string을 Swift String으로 받고 free.
@inline(__always)
internal func consumeForgeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    defer { fc_string_free(ptr) }
    return String(cString: ptr)
}

/// FC 코드 0/-1/-2/... → 결과 throw.
@inline(__always)
internal func checkForgeReturn(_ code: Int32) throws {
    if code == FC_OK { return }
    throw ForgeError.from(code) ?? .generic
}
