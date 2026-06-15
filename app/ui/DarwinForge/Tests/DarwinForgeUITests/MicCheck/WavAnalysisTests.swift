import XCTest
@testable import DarwinForgeUI

/// WAV 헤더 파싱 + RMS/피크/길이 계산 regression guard.
final class WavAnalysisTests: XCTestCase {

    // MARK: - WAV 합성 헬퍼

    /// canonical 44-byte PCM16 WAV 를 합성.
    private func makeWav(sampleRate: Int = 16000, channels: Int = 1,
                         samples: [Int16]) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * 2
        var d = Data()
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                                       UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(16)
        ascii("data"); u32(UInt32(dataSize))
        for s in samples {
            let raw = UInt16(bitPattern: s)
            d.append(contentsOf: [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF)])
        }
        return d
    }

    // MARK: - 헤더 파싱

    func testParsesHeaderMetadata() throws {
        let wav = makeWav(sampleRate: 16000, channels: 1, samples: Array(repeating: 0, count: 16000))
        let info = try WavAnalysis.analyze(wav)
        XCTAssertEqual(info.sampleRate, 16000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertEqual(info.frameCount, 16000)
        XCTAssertEqual(info.durationSeconds, 1.0, accuracy: 0.001)
    }

    // MARK: - 진폭 (무음 vs 신호)

    func testSilenceHasNoSignal() throws {
        let wav = makeWav(samples: Array(repeating: 0, count: 8000))
        let info = try WavAnalysis.analyze(wav)
        XCTAssertEqual(info.rms, 0, accuracy: 1e-9)
        XCTAssertEqual(info.peakAmplitude, 0, accuracy: 1e-9)
        XCTAssertFalse(info.hasSignal)
        XCTAssertEqual(info.rmsDBFS, -120, accuracy: 0.001)
    }

    func testFullScaleToneHasStrongSignal() throws {
        // ±32000 진폭 구형파 — 강한 신호.
        let samples = (0..<8000).map { $0 % 2 == 0 ? Int16(32000) : Int16(-32000) }
        let info = try WavAnalysis.analyze(makeWav(samples: samples))
        XCTAssertGreaterThan(info.peakAmplitude, 0.97)
        XCTAssertGreaterThan(info.rms, 0.9)
        XCTAssertTrue(info.hasSignal)
        XCTAssertGreaterThan(info.rmsDBFS, -1.0)
    }

    func testLowLevelNoiseBelowThreshold() throws {
        // ±100 (~ -50 dBFS) — 잡음 바닥, 신호로 치지 않음.
        let samples = (0..<8000).map { $0 % 2 == 0 ? Int16(100) : Int16(-100) }
        let info = try WavAnalysis.analyze(makeWav(samples: samples))
        XCTAssertFalse(info.hasSignal)
        XCTAssertLessThan(info.rms, WavAnalysis.WavInfo.signalThreshold)
    }

    func testStereoFrameCount() throws {
        // 2채널 × 4000 프레임 = 8000 샘플.
        let wav = makeWav(sampleRate: 8000, channels: 2,
                          samples: Array(repeating: 0, count: 8000))
        let info = try WavAnalysis.analyze(wav)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.frameCount, 4000)
        XCTAssertEqual(info.durationSeconds, 0.5, accuracy: 0.001)
    }

    // MARK: - 손상/비정상 입력 방어 (시스템 경계 검증)

    func testTooShortThrows() {
        XCTAssertThrowsError(try WavAnalysis.analyze(Data([0x52, 0x49, 0x46, 0x46]))) { err in
            XCTAssertEqual(err as? WavAnalysis.WavError, .tooShort)
        }
    }

    func testNonRiffThrows() {
        let junk = Data(repeating: 0x41, count: 64)
        XCTAssertThrowsError(try WavAnalysis.analyze(junk)) { err in
            XCTAssertEqual(err as? WavAnalysis.WavError, .notRiffWave)
        }
    }

    func testTruncatedDataChunkClampsGracefully() throws {
        // data 청크가 1초라고 선언하지만 실제 바이트는 절반만 — clamp 되어 crash 없이 분석.
        var wav = makeWav(samples: Array(repeating: 1000, count: 16000))
        wav.removeLast(16000) // 데이터 절반 제거 (헤더 size 는 과대 신고 상태 유지)
        let info = try WavAnalysis.analyze(wav)
        XCTAssertLessThan(info.frameCount, 16000)
        XCTAssertGreaterThan(info.frameCount, 0)
    }
}
