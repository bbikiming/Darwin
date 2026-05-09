import Foundation

/// Wire label parser for the project's "W042 LL.KNEE.SIG" convention.
/// See `docs/harness/data-model.md` for the full grammar.
public struct WireLabel: Sendable, Equatable {
    public let id: Int               // 42 from "W042"
    public let body: String          // "LL"
    public let joint: String         // "KNEE"
    public let function: String      // "SIG"

    public init(id: Int, body: String, joint: String, function: String) {
        self.id = id
        self.body = body
        self.joint = joint
        self.function = function
    }

    public init?(parsing raw: String) {
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let head = parts[0]
        guard head.first == "W" else { return nil }
        guard let n = Int(head.dropFirst()) else { return nil }
        let segments = parts[1].split(separator: ".")
        guard segments.count == 3 else { return nil }
        self.id = n
        self.body = String(segments[0])
        self.joint = String(segments[1])
        self.function = String(segments[2])
    }

    public var formatted: String {
        String(format: "W%03d %@.%@.%@", id, body, joint, function)
    }
}
