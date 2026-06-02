import Foundation

/// 맥으로 전송된 WAV 바이트를 파싱·분석하는 순수 모듈.
///
/// # 비유
///
/// 택배로 도착한 상자(WAV 바이트)를 열어 송장(헤더)을 읽고, 안의 내용물이 비어 있는지
/// (무음) 꽉 차 있는지(실제 음성) 무게를 재는 일. 외부(로봇)에서 온 입력이므로 송장이
/// 위조/손상됐을 가능성을 가정하고 매 단계 검증한다 — 시스템 경계 검증 원칙.
///
/// 지원 포맷: PCM(`S16_LE`) — `arecord -f S16_LE` 가 만드는 canonical WAV. 다른 포맷은
/// 헤더 메타데이터는 읽되 진폭 계산은 건너뛴다(`rms`/`peak` = 0).
public enum WavAnalysis {

    /// WAV 분석 결과 — 전부 불변.
    public struct WavInfo: Equatable {
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerSample: Int
        /// 채널당 프레임 수.
        public let frameCount: Int
        public let durationSeconds: Double
        /// 0...1 정규화 피크 진폭.
        public let peakAmplitude: Double
        /// 0...1 정규화 RMS(실효값).
        public let rms: Double

        public init(sampleRate: Int, channels: Int, bitsPerSample: Int,
                    frameCount: Int, durationSeconds: Double,
                    peakAmplitude: Double, rms: Double) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitsPerSample = bitsPerSample
            self.frameCount = frameCount
            self.durationSeconds = durationSeconds
            self.peakAmplitude = peakAmplitude
            self.rms = rms
        }

        /// 실제 소리가 잡혔는지 — RMS 가 잡음 바닥(~ -46 dBFS) 을 넘는가.
        /// 무음/장치 미연결이면 거의 0 에 수렴하므로 false.
        public var hasSignal: Bool { rms > Self.signalThreshold }

        /// RMS 를 dBFS 로 (로그). rms 0 이면 -∞ 대신 -120 dB 로 floor.
        public var rmsDBFS: Double {
            rms <= 0 ? -120 : 20 * log10(rms)
        }

        static let signalThreshold = 0.005
    }

    public enum WavError: Error, Equatable {
        case tooShort
        case notRiffWave
        case missingFmtChunk
        case missingDataChunk
    }

    /// WAV 바이트를 분석. 헤더 검증 실패 시 throw.
    public static func analyze(_ data: Data) throws -> WavInfo {
        let bytes = [UInt8](data)
        // 최소 RIFF(12) + fmt(8+16) + data(8) = 44 바이트.
        guard bytes.count >= 44 else { throw WavError.tooShort }
        guard match(bytes, at: 0, ascii: "RIFF"),
              match(bytes, at: 8, ascii: "WAVE") else {
            throw WavError.notRiffWave
        }

        guard let fmt = findChunk(bytes, id: "fmt ") else { throw WavError.missingFmtChunk }
        guard let dataChunk = findChunk(bytes, id: "data") else { throw WavError.missingDataChunk }

        let audioFormat = readUInt16LE(bytes, at: fmt.bodyOffset)
        let channels = max(Int(readUInt16LE(bytes, at: fmt.bodyOffset + 2)), 1)
        let sampleRate = Int(readUInt32LE(bytes, at: fmt.bodyOffset + 4))
        let bitsPerSample = Int(readUInt16LE(bytes, at: fmt.bodyOffset + 14))

        // data 청크 크기는 헤더 값과 실제 잔여 바이트 중 작은 쪽으로 clamp(손상 방어).
        let availableBytes = max(0, bytes.count - dataChunk.bodyOffset)
        let dataSize = min(dataChunk.size, availableBytes)

        let bytesPerSample = max(bitsPerSample / 8, 1)
        let totalSamples = dataSize / bytesPerSample
        let frameCount = totalSamples / channels
        let duration = sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0

        // 진폭은 PCM 16-bit 에서만 계산. 그 외 포맷은 0(헤더만 신뢰).
        var peak = 0.0
        var rms = 0.0
        if audioFormat == 1, bitsPerSample == 16, totalSamples > 0 {
            (peak, rms) = pcm16Levels(bytes, dataOffset: dataChunk.bodyOffset,
                                      sampleCount: totalSamples)
        }

        return WavInfo(
            sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample,
            frameCount: frameCount, durationSeconds: duration,
            peakAmplitude: peak, rms: rms
        )
    }

    // MARK: - 청크 탐색

    private struct Chunk { let bodyOffset: Int; let size: Int }

    /// RIFF 청크들을 offset 12 부터 순회해 `id` 청크의 body offset/size 반환.
    private static func findChunk(_ bytes: [UInt8], id: String) -> Chunk? {
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = Int(readUInt32LE(bytes, at: offset + 4))
            let bodyOffset = offset + 8
            if match(bytes, at: offset, ascii: id) {
                return Chunk(bodyOffset: bodyOffset, size: size)
            }
            // 청크는 2바이트 정렬 — 홀수 size 면 패딩 1바이트.
            offset = bodyOffset + size + (size % 2)
        }
        return nil
    }

    // MARK: - PCM 16 진폭 계산

    private static func pcm16Levels(_ bytes: [UInt8], dataOffset: Int,
                                    sampleCount: Int) -> (peak: Double, rms: Double) {
        var peakInt = 0
        var sumSquares = 0.0
        var counted = 0
        var i = dataOffset
        let end = min(dataOffset + sampleCount * 2, bytes.count - 1)
        while i < end {
            let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            let sample = Int(Int16(bitPattern: raw))
            let magnitude = abs(sample)
            if magnitude > peakInt { peakInt = magnitude }
            sumSquares += Double(sample) * Double(sample)
            counted += 1
            i += 2
        }
        guard counted > 0 else { return (0, 0) }
        let fullScale = 32768.0
        let peak = Double(peakInt) / fullScale
        let rms = (sumSquares / Double(counted)).squareRoot() / fullScale
        return (peak, rms)
    }

    // MARK: - 리틀엔디안 읽기 헬퍼

    private static func match(_ bytes: [UInt8], at offset: Int, ascii: String) -> Bool {
        let target = Array(ascii.utf8)
        guard offset + target.count <= bytes.count else { return false }
        for (i, b) in target.enumerated() where bytes[offset + i] != b { return false }
        return true
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
