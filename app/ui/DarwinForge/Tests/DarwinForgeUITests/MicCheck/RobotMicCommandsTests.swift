import XCTest
@testable import DarwinForgeUI

/// 다윈 마이크 캡처 셸 명령 빌더 + arecord 파서 regression guard.
final class RobotMicCommandsTests: XCTestCase {

    // MARK: - record 명령

    func testRecordBuildsExpectedCommandWithDevice() {
        let cmd = RobotMicCommands.record(durationSeconds: 5, device: "plughw:1,0")
        XCTAssertTrue(cmd.contains("arecord -D plughw:1,0 "))
        XCTAssertTrue(cmd.contains("-f S16_LE"))
        XCTAssertTrue(cmd.contains("-r 16000"))
        XCTAssertTrue(cmd.contains("-c 1"))
        XCTAssertTrue(cmd.contains("-d 5"))
        XCTAssertTrue(cmd.contains(RobotMicCommands.remoteWavPath))
    }

    func testRecordWithoutDeviceUsesAlsaDefault() {
        let cmd = RobotMicCommands.record(durationSeconds: 3, device: nil)
        XCTAssertFalse(cmd.contains("-D "))
        XCTAssertTrue(cmd.contains("arecord -f S16_LE"))
        XCTAssertTrue(cmd.contains("-d 3"))
    }

    func testRecordClampsDuration() {
        XCTAssertTrue(RobotMicCommands.record(durationSeconds: 0, device: nil).contains("-d 1"))
        XCTAssertTrue(RobotMicCommands.record(durationSeconds: 99, device: nil).contains("-d 15"))
        XCTAssertEqual(RobotMicCommands.clampDuration(-5), 1)
        XCTAssertEqual(RobotMicCommands.clampDuration(8), 8)
        XCTAssertEqual(RobotMicCommands.clampDuration(15), 15)
    }

    // MARK: - 정적 명령

    func testStaticCommandsReferenceWavPath() {
        XCTAssertTrue(RobotMicCommands.transferBase64.contains(RobotMicCommands.remoteWavPath))
        XCTAssertTrue(RobotMicCommands.fileSizeBytes.contains(RobotMicCommands.remoteWavPath))
        XCTAssertTrue(RobotMicCommands.cleanup.contains(RobotMicCommands.remoteWavPath))
        XCTAssertTrue(RobotMicCommands.transferBase64.hasPrefix("base64 "))
    }

    func testProbeCollectsArecordAndCards() {
        let p = RobotMicCommands.probe
        XCTAssertTrue(p.contains("which arecord"))
        XCTAssertTrue(p.contains("arecord -l"))
        XCTAssertTrue(p.contains("/proc/asound/cards"))
        XCTAssertTrue(p.contains("NO_ARECORD"))
    }

    // MARK: - arecord -l 파서: 장치 있음

    func testParseSingleUsbCaptureDevice() {
        let output = """
        == which ==
        /usr/bin/arecord
        == arecord-l ==
        **** List of CAPTURE Hardware Devices ****
        card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
          Subdevices: 1/1
          Subdevice #0: subdevice #0
        == cards ==
         0 [Intel          ]: HDA-Intel - HDA Intel
        """
        let devices = RobotMicCommands.parseCaptureDevices(from: output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first, RobotMicCommands.CaptureDevice(
            card: 1, device: 0, name: "USB Audio Device"))
        XCTAssertEqual(devices.first?.plughwArgument, "plughw:1,0")
        XCTAssertEqual(RobotMicCommands.firstDeviceArgument(from: output), "plughw:1,0")
        XCTAssertFalse(RobotMicCommands.isArecordMissing(in: output))
    }

    func testParseMultipleCaptureDevicesPicksFirst() {
        let output = """
        card 0: Intel [HDA Intel], device 0: ALC662 Analog [ALC662 Analog]
        card 2: Webcam [USB Webcam], device 0: USB Audio [USB Audio]
        """
        let devices = RobotMicCommands.parseCaptureDevices(from: output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].card, 0)
        XCTAssertEqual(devices[1].card, 2)
        XCTAssertEqual(RobotMicCommands.firstDeviceArgument(from: output), "plughw:0,0")
    }

    // MARK: - arecord -l 파서: 장치 없음 / arecord 없음

    func testParseNoSoundcardsReturnsEmpty() {
        let output = """
        == arecord-l ==
        arecord: device_list:276: no soundcards found...
        == cards ==
        --- no soundcards ---
        """
        XCTAssertTrue(RobotMicCommands.parseCaptureDevices(from: output).isEmpty)
        XCTAssertNil(RobotMicCommands.firstDeviceArgument(from: output))
    }

    func testArecordMissingDetected() {
        let output = """
        == which ==
        NO_ARECORD
        == arecord-l ==
        sh: arecord: command not found
        """
        XCTAssertTrue(RobotMicCommands.isArecordMissing(in: output))
        XCTAssertTrue(RobotMicCommands.parseCaptureDevices(from: output).isEmpty)
    }

    func testGarbageLinesIgnored() {
        let output = "random text\nnot a card line\ncardabc nonsense\n"
        XCTAssertTrue(RobotMicCommands.parseCaptureDevices(from: output).isEmpty)
    }
}
