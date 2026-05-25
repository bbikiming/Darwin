import Foundation

/// Structured artifact of a single HIL / smoke test run. Encoded as
/// pretty-printed JSON so testers can attach it to TestFlight feedback or
/// paste it into HIL handoff docs.
///
/// P2-2 (truth-gap report, 2026-05-25): print-only diagnostics were not
/// enough evidence for safety-critical HIL gates. This record gives every
/// run a self-contained, copy/share-able trail.
public struct TestRunRecord: Codable, Sendable, Equatable {

    public struct Step: Codable, Sendable, Equatable {
        public let index: Int
        public let title: String
        public let completedAt: Date?
        public let note: String?

        public init(index: Int, title: String,
                    completedAt: Date? = nil, note: String? = nil) {
            self.index = index
            self.title = title
            self.completedAt = completedAt
            self.note = note
        }
    }

    public enum Result: String, Codable, Sendable {
        case pending, pass, fail
    }

    public let id: UUID
    public let appVersion: String
    public let mode: String              // mockReview / realRelay
    public let endpoint: String?
    public let pairingMethod: String?    // discovery / qr / manual
    public let startedAt: Date
    public let endedAt: Date?
    public let steps: [Step]
    public let result: Result
    public let notes: String
    public let commandIds: [String]      // recent command ids touched during the run
    public let maxLatencyMs: Int?
    public let stopReasons: [String]     // walk/E-stop release reasons seen
    public let estopVerified: Bool
    public let backgroundStopVerified: Bool
    public let disconnectStopVerified: Bool
    public let cradleConfirmed: Bool
    public let physicalEStopConfirmed: Bool
    public let lineOfSightConfirmed: Bool

    public init(id: UUID = UUID(),
                appVersion: String,
                mode: String,
                endpoint: String?,
                pairingMethod: String?,
                startedAt: Date,
                endedAt: Date?,
                steps: [Step],
                result: Result,
                notes: String,
                commandIds: [String],
                maxLatencyMs: Int?,
                stopReasons: [String],
                estopVerified: Bool,
                backgroundStopVerified: Bool,
                disconnectStopVerified: Bool,
                cradleConfirmed: Bool,
                physicalEStopConfirmed: Bool,
                lineOfSightConfirmed: Bool) {
        self.id = id
        self.appVersion = appVersion
        self.mode = mode
        self.endpoint = endpoint
        self.pairingMethod = pairingMethod
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.steps = steps
        self.result = result
        self.notes = notes
        self.commandIds = commandIds
        self.maxLatencyMs = maxLatencyMs
        self.stopReasons = stopReasons
        self.estopVerified = estopVerified
        self.backgroundStopVerified = backgroundStopVerified
        self.disconnectStopVerified = disconnectStopVerified
        self.cradleConfirmed = cradleConfirmed
        self.physicalEStopConfirmed = physicalEStopConfirmed
        self.lineOfSightConfirmed = lineOfSightConfirmed
    }

    public func encodeJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Human-readable summary suitable for pasting into chat / TestFlight
    /// feedback.
    public func summaryText() -> String {
        let duration = endedAt.map { Int($0.timeIntervalSince(startedAt)) } ?? -1
        let completedSteps = steps.filter { $0.completedAt != nil }.count
        return """
        DarwinForge Pilot — \(appVersion) (\(mode))
        Result: \(result.rawValue)
        Duration: \(duration)s
        Steps: \(completedSteps)/\(steps.count)
        Endpoint: \(endpoint ?? "—")
        Pairing: \(pairingMethod ?? "—")
        Max latency: \(maxLatencyMs.map { "\($0)ms" } ?? "—")
        Stops observed: \(stopReasons.joined(separator: ", "))
        Safety:
          E-stop verified:        \(estopVerified ? "Y" : "N")
          Background stop verified: \(backgroundStopVerified ? "Y" : "N")
          Disconnect stop verified: \(disconnectStopVerified ? "Y" : "N")
        Checklist:
          Cradle/tether:  \(cradleConfirmed ? "Y" : "N")
          Physical E-stop:\(physicalEStopConfirmed ? "Y" : "N")
          Line of sight:  \(lineOfSightConfirmed ? "Y" : "N")
        Notes: \(notes.isEmpty ? "—" : notes)
        """
    }
}
