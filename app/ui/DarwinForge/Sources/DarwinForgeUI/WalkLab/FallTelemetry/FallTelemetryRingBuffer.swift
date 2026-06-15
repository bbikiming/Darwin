import Foundation

/// Fixed-capacity ring buffer for pre-fall sensor samples.
///
/// # Analogy
/// Like a dashcam that continuously overwrites the oldest footage — the last N seconds
/// are always available to "dump" when an incident is detected.
///
/// # Capacity and rate
/// Tied to the 10 Hz WalkLab tick (100 ms cadence). Default capacity 150 samples = 15 s.
/// At the moment of a fall, the ring holds up to ~15 s of pre-fall history.
///
/// # Thread safety
/// NOT thread-safe. All callers must operate on the same actor (MainActor in production).
/// The struct is deliberately pure (no I/O) for testability.
public struct FallTelemetryRingBuffer {

    /// Default capacity: 150 samples at 10 Hz = 15 s of pre-fall history.
    public static let defaultCapacity = 150

    private var buffer: [FallTelemetrySample]
    private var writeIndex: Int = 0
    private var count: Int = 0
    public let capacity: Int

    /// - Parameter capacity: Maximum number of samples to retain. Must be > 0.
    public init(capacity: Int = FallTelemetryRingBuffer.defaultCapacity) {
        precondition(capacity > 0, "FallTelemetryRingBuffer capacity must be > 0")
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
    }

    /// Push a new sample. If the buffer is full, the oldest sample is evicted.
    public mutating func push(_ sample: FallTelemetrySample) {
        if buffer.count < capacity {
            buffer.append(sample)
        } else {
            buffer[writeIndex] = sample
        }
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Returns a snapshot of all retained samples in chronological order (oldest first).
    public func snapshot() -> [FallTelemetrySample] {
        guard !buffer.isEmpty else { return [] }
        if buffer.count < capacity {
            // Not yet full — buffer is already in order.
            return buffer
        }
        // Full ring: start at writeIndex (oldest), wrap around.
        let tail = Array(buffer[writeIndex...])
        let head = Array(buffer[..<writeIndex])
        return tail + head
    }

    /// Number of samples currently in the buffer (0…capacity).
    public var sampleCount: Int { buffer.count }

    /// Remove all samples.
    public mutating func clear() {
        buffer.removeAll(keepingCapacity: true)
        writeIndex = 0
        count = 0
    }
}
