import Foundation

/// High-density fall-window telemetry recorder.
///
/// # Analogy
/// An airplane's black box, but specifically for fall events. The ring buffer acts as
/// the continuous cockpit voice recorder (pre-fall ~15 s always ready), and this
/// recorder writes a new JSONL file the moment a fall is detected.
///
/// # File layout
/// ```
/// ~/Library/Application Support/DarwinForge/FallEvents/<sessionId>/
///     fall-<ISO8601>.jsonl    ← manifest (line 1) + ring dump + live samples + outcome
/// ```
///
/// # Usage
/// 1. Every WalkLab tick: call `pushSample(_:)` to feed the ring.
/// 2. On `.idle/.done → .fallen` transition: call `startCapture(manifest:)`.
/// 3. During recovery: call `appendLiveSample(_:)` each tick.
/// 4. On `.done` or `.failed`: call `finalizeOutcome(_:)`.
///
/// # Thread safety
/// `@MainActor` — same isolation as `WalkLabSession`. All public methods must be
/// called from MainActor (same pattern as `CockpitPilotRecorder`).
@MainActor
public final class FallTelemetryRecorder {

    // MARK: - Static root

    /// `~/Library/Application Support/DarwinForge/FallEvents/`
    public static func rootDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("FallEvents", isDirectory: true)
    }

    // MARK: - State

    /// Pre-fall ring buffer — fed continuously from WalkLab tick.
    private var ring: FallTelemetryRingBuffer
    /// Active JSONL file handle. nil = no capture in progress.
    private var activeHandle: FileHandle?
    /// Active session directory (for fsync + finalize).
    private var activeSessionDir: URL?
    /// Time at which startCapture was called (for settleMs / recoveryTotalMs).
    private var captureStartedAt: Date?
    /// JSON encoder — shared instance for performance.
    private let encoder: JSONEncoder
    /// Write count since last fsync — flush every N lines (matches CockpitPilotRecorder pattern).
    private var linesSinceSync: Int = 0
    private static let fsyncEvery = 10

    /// Optional root override for tests.
    private let rootOverride: URL?

    // MARK: - Init

    public init(capacity: Int = FallTelemetryRingBuffer.defaultCapacity,
                rootOverride: URL? = nil) {
        self.ring = FallTelemetryRingBuffer(capacity: capacity)
        self.rootOverride = rootOverride
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: - Ring feed (every tick)

    /// Feed the pre-fall ring. Call every WalkLab tick regardless of fall state.
    public func pushSample(_ sample: FallTelemetrySample) {
        ring.push(sample)
    }

    // MARK: - Capture lifecycle

    /// Begin capturing a fall event: create JSONL, write manifest, dump ring.
    ///
    /// - Parameters:
    ///   - manifest: Session metadata (thresholds, appVersion, robotModel).
    ///   - sessionId: Walk session ID — used as the subdirectory name.
    public func startCapture(manifest: FallTelemetryManifest, sessionId: String) {
        // Finalize any previous in-progress capture (defensive).
        closeHandle()

        captureStartedAt = Date()
        let root = rootOverride ?? Self.rootDirectory()
        let dir = root.appendingPathComponent(sessionId, isDirectory: true)
        activeSessionDir = dir

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Build ISO filename (colons replaced with dashes for filesystem compatibility).
        let iso = ISO8601DateFormatter().string(from: captureStartedAt!)
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = dir.appendingPathComponent("fall-\(iso).jsonl")
        fm.createFile(atPath: fileURL.path, contents: nil)
        activeHandle = try? FileHandle(forWritingTo: fileURL)
        linesSinceSync = 0

        // Line 1: manifest.
        appendLine(manifest)

        // Lines 2…N: ring dump (pre-fall history).
        for sample in ring.snapshot() {
            appendLine(sample)
        }
    }

    /// Append a live (post-fall) sample during recovery. No-op if not capturing.
    public func appendLiveSample(_ sample: FallTelemetrySample) {
        guard activeHandle != nil else { return }
        appendLine(sample)
    }

    /// Write the outcome record and close the file. Call on `.done` or `.failed`.
    ///
    /// - Parameter outcome: Recovery outcome.
    public func finalizeOutcome(_ outcome: FallTelemetryOutcome) {
        guard activeHandle != nil else { return }
        appendLine(outcome)
        closeHandle()
        captureStartedAt = nil
        activeSessionDir = nil
    }

    /// Close without writing an outcome (e.g. app termination).
    public func cancel() {
        closeHandle()
        captureStartedAt = nil
        activeSessionDir = nil
    }

    // MARK: - Elapsed helpers (for caller to compute settleMs / recoveryTotalMs)

    /// Milliseconds elapsed since `startCapture` was called.
    public var elapsedMsSinceCapture: Double {
        guard let start = captureStartedAt else { return 0 }
        return Date().timeIntervalSince(start) * 1000.0
    }

    // MARK: - Private helpers

    private func appendLine<T: Encodable>(_ value: T) {
        guard let handle = activeHandle else { return }
        guard let data = try? encoder.encode(value) else { return }
        var line = data
        line.append(0x0a)  // newline
        try? handle.write(contentsOf: line)
        linesSinceSync += 1
        if linesSinceSync >= Self.fsyncEvery {
            try? handle.synchronize()
            linesSinceSync = 0
        }
    }

    private func closeHandle() {
        if let handle = activeHandle {
            try? handle.synchronize()
            try? handle.close()
            activeHandle = nil
            linesSinceSync = 0
        }
    }
}
