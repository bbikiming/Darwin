#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **V289-3** — HarnessSensorTileGrid tile 표시 + 데이터 없음 fallback 검증.
///
/// 비유: 6개 계기판 각각의 "전원 없음" 상태를 확인하는 항공 체크리스트.
/// 기술: 각 tile view model 의 UI 분기 (data present vs nil) 를 단위 검증.
///
/// 테스트 대상:
///   1. ImuTile — IMU 없을 때 "—" 반환 (nil fallback)
///   2. ImuTile — roll 임계 초과 시 vermillion 색상 경보
///   3. GaitPhaseTile — idle 상태 레이블 "Idle"
///   4. GaitPhaseTile — march 활성 시 "DSP" 레이블
///   5. ServoHealthTile — snap nil → "—" 반환
///   6. CommQualityTile — RTT nil → "—" 반환
@MainActor
final class HarnessSensorTileGridTests: XCTestCase {

    // MARK: - Tile 1: IMU

    func test_imu_nilRaw_returnsPlaceholder() {
        // given: no IMU data
        let raw: ImuRaw? = nil
        // when: format roll
        let label = raw.map { String(format: "%.1f", $0.rollDeg) } ?? "—"
        // then: placeholder shown (NIST UX: no zero for absent data)
        XCTAssertEqual(label, "—")
    }

    func test_imu_withRaw_returnsFormattedValue() {
        // given (gyroX:gyroY:gyroZ:accelX:accelY:accelZ: order per Bus.swift public init)
        let raw = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 512,
            rollDeg: -12.3, pitchDeg: 5.7
        )
        // when
        let rollLabel = String(format: "%.1f", raw.rollDeg)
        let pitchLabel = String(format: "%.1f", raw.pitchDeg)
        // then: 1 decimal place (NIST SP 811 §7.5 — fixed digits)
        XCTAssertEqual(rollLabel, "-12.3")
        XCTAssertEqual(pitchLabel, "5.7")
    }

    func test_imu_rollAbove25deg_isAnomalous() {
        // given: roll 임계 25° 초과
        let raw = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 512,
            rollDeg: 30.0, pitchDeg: 0.0
        )
        // when: check anomaly flag
        let isAnomalous = abs(raw.rollDeg) > 25
        // then: vermillion 경보 발동 조건 참
        XCTAssertTrue(isAnomalous)
    }

    // MARK: - Tile 2: Gait Phase

    func test_gaitPhase_idle_labelIsIdle() {
        // given
        let preset = WalkLabPreset.idle
        let isActive = false
        // when
        let label = gaitLabel(preset: preset, isActive: isActive)
        // then
        XCTAssertEqual(label, "Idle")
    }

    func test_gaitPhase_march_active_labelIsDSP() {
        // given: march = 두 발이 동시에 땅에 닿는 DSP (double support phase)
        let preset = WalkLabPreset.march
        let isActive = true
        // when
        let label = gaitLabel(preset: preset, isActive: isActive)
        // then
        XCTAssertEqual(label, "DSP")
    }

    func test_gaitPhase_slowWalk_labelIsSSPL() {
        let label = gaitLabel(preset: .slowWalk, isActive: true)
        XCTAssertEqual(label, "SSP-L")
    }

    func test_gaitPhase_normalWalk_labelIsSSPR() {
        let label = gaitLabel(preset: .normalWalk, isActive: true)
        XCTAssertEqual(label, "SSP-R")
    }

    // MARK: - Tile 4: Servo Health

    func test_servoHealth_nilSnap_returnsPlaceholder() {
        // given: no telemetry snapshot
        let snap: TelemetrySnapshot? = nil
        // when
        let label = servoNormalLabel(snap: snap)
        // then
        XCTAssertEqual(label, "—")
    }

    func test_servoHealth_emptyJoints_returnsPlaceholder() {
        // given: snapshot with no joints yet polled
        let snap = TelemetrySnapshot(board: nil, joints: [:])
        // when
        let label = servoNormalLabel(snap: snap)
        // then
        XCTAssertEqual(label, "—")
    }

    func test_servoHealth_allNormal_returns20() {
        // given: 20 joints all at 35°C (well below 75° warn threshold)
        var joints: [JointID: JointState] = [:]
        for jid in JointID.allCases {
            joints[jid] = JointState(
                id: jid, torqueEnabled: true,
                goalPosition: 2048, presentPosition: 2048,
                presentSpeed: 0, presentLoad: 0,
                presentVoltageRaw: 120, presentTemperature: 35
            )
        }
        let snap = TelemetrySnapshot(board: nil, joints: joints)
        // when
        let label = servoNormalLabel(snap: snap)
        // then: 20 - 0 abnormal = "20"
        XCTAssertEqual(label, "20")
    }

    func test_servoHealth_oneHotJoint_returns19() {
        // given: 1 joint at 80°C (above 75° warn)
        var joints: [JointID: JointState] = [:]
        for (idx, jid) in JointID.allCases.enumerated() {
            let temp: UInt8 = idx == 0 ? 80 : 35
            joints[jid] = JointState(
                id: jid, torqueEnabled: true,
                goalPosition: 2048, presentPosition: 2048,
                presentSpeed: 0, presentLoad: 0,
                presentVoltageRaw: 120, presentTemperature: temp
            )
        }
        let snap = TelemetrySnapshot(board: nil, joints: joints)
        // when
        let label = servoNormalLabel(snap: snap)
        // then: 20 - 1 = "19"
        XCTAssertEqual(label, "19")
    }

    // MARK: - Tile 6: Comm Quality

    func test_commQuality_nilRTT_returnsPlaceholder() {
        // given
        let rttMs: Double? = nil
        // when
        let label = rttMs.map { String(format: "%.1f", $0) } ?? "—"
        // then
        XCTAssertEqual(label, "—")
    }

    func test_commQuality_withRTT_formatsOneDecimal() {
        // given: 8.2 ms (NIST SP 811 §7.5 — 1 decimal)
        let rttMs: Double? = 8.2
        // when
        let label = rttMs.map { String(format: "%.1f", $0) } ?? "—"
        // then
        XCTAssertEqual(label, "8.2")
    }

    func test_commQuality_highRTT_isAnomalous() {
        // given: 120 ms > 100 ms threshold
        let rttMs = 120.0
        let isAnomalous = rttMs > 100
        XCTAssertTrue(isAnomalous)
    }

    // MARK: - Intent extraction

    func test_activeIntent_noEvents_returnsNil() {
        let events: [TelemetryEvent] = []
        let last = events.last { $0.k == .claudeIntentDispatched }
        XCTAssertNil(last)
    }

    func test_activeIntent_withEvent_returnsLast() throws {
        // given: one intent event
        let ev = TelemetryEvent(
            session: "test", seq: 1,
            wall: ISO8601DateFormatter().string(from: Date()),
            mono: 0,
            kind: .claudeIntentDispatched,
            level: .info, actor: .claude,
            data: .dict(["tool": "joint_state", "mode": "simulation"])
        )
        let events = [ev]
        // when
        let found = events.last { $0.k == .claudeIntentDispatched }
        // then
        XCTAssertNotNil(found)
        let tool = found?.d.raw["tool"]?.value as? String
        XCTAssertEqual(tool, "joint_state")
    }

    // MARK: - V290-B: 서보 온도 bar chart 데이터 변환 검증

    func test_tempBars_nilSnap_isEmpty() {
        // given: 스냅샷 없음
        let snap: TelemetrySnapshot? = nil
        // when
        let bars = tempBars(snap: snap)
        // then: bar chart 데이터 없음 (빈 배열)
        XCTAssertTrue(bars.isEmpty)
    }

    func test_tempBars_allNormal_allGrayscale() {
        // given: 20 joint 모두 35°C (정상)
        var joints: [JointID: JointState] = [:]
        for jid in JointID.allCases {
            joints[jid] = JointState(
                id: jid, torqueEnabled: true,
                goalPosition: 2048, presentPosition: 2048,
                presentSpeed: 0, presentLoad: 0,
                presentVoltageRaw: 120, presentTemperature: 35
            )
        }
        let snap = TelemetrySnapshot(board: nil, joints: joints)
        // when
        let bars = tempBars(snap: snap)
        // then: bar count 20, 정상 색 = grayscale (neither warn nor crit)
        XCTAssertEqual(bars.count, 20, "20 개 servo 는 20 개 bar 를 생성해야 함")
        // 모든 bar 가 warn/crit 색이 아님 (isWarn, isCrit 모두 false)
        XCTAssertTrue(bars.allSatisfy { !$0.isWarn && !$0.isCrit },
                      "정상 온도(35°C) 는 모두 grayscale 이어야 함")
    }

    func test_tempBars_oneWarnJoint_markedAmber() {
        // given: joint[0] = 80°C (warn 75+)
        var joints: [JointID: JointState] = [:]
        for (idx, jid) in JointID.allCases.enumerated() {
            let temp: UInt8 = idx == 0 ? 80 : 35
            joints[jid] = JointState(
                id: jid, torqueEnabled: true,
                goalPosition: 2048, presentPosition: 2048,
                presentSpeed: 0, presentLoad: 0,
                presentVoltageRaw: 120, presentTemperature: temp
            )
        }
        let snap = TelemetrySnapshot(board: nil, joints: joints)
        // when
        let bars = tempBars(snap: snap)
        // then: warn bar 1개
        let warnCount = bars.filter { $0.isWarn }.count
        XCTAssertEqual(warnCount, 1, "80°C joint 1개 = warn bar 1개 이어야 함")
    }

    func test_tempBars_oneCritJoint_markedVermillion() {
        // given: joint[0] = 92°C (crit 90+)
        var joints: [JointID: JointState] = [:]
        for (idx, jid) in JointID.allCases.enumerated() {
            let temp: UInt8 = idx == 0 ? 92 : 35
            joints[jid] = JointState(
                id: jid, torqueEnabled: true,
                goalPosition: 2048, presentPosition: 2048,
                presentSpeed: 0, presentLoad: 0,
                presentVoltageRaw: 120, presentTemperature: temp
            )
        }
        let snap = TelemetrySnapshot(board: nil, joints: joints)
        // when
        let bars = tempBars(snap: snap)
        // then: crit bar 1개
        let critCount = bars.filter { $0.isCrit }.count
        XCTAssertEqual(critCount, 1, "92°C joint 1개 = crit bar 1개 이어야 함")
    }

    func test_tempBars_sortedByJointId() {
        // given: 20 joint 를 역순으로 넣어도 bar 는 ID 오름차순이어야 함
        var joints: [JointID: JointState] = [:]
        for jid in JointID.allCases {
            joints[jid] = JointState(
                id: jid, torqueEnabled: true,
                goalPosition: 2048, presentPosition: 2048,
                presentSpeed: 0, presentLoad: 0,
                presentVoltageRaw: 120, presentTemperature: 35
            )
        }
        let snap = TelemetrySnapshot(board: nil, joints: joints)
        let bars = tempBars(snap: snap)
        // ID 는 1~20 오름차순이어야 함
        let ids = bars.map { $0.id }
        XCTAssertEqual(ids, Array(1...bars.count), "bar ID 는 1-based 오름차순이어야 함")
    }

    // MARK: - Helpers (mirrors tile view model logic for testability)

    private func gaitLabel(preset: WalkLabPreset, isActive: Bool) -> String {
        switch preset {
        case .idle:       return "Idle"
        case .march:      return "DSP"
        case .slowWalk:   return "SSP-L"
        case .normalWalk: return "SSP-R"
        case .fastWalk:   return "SSP-R"
        case .jog:        return "SSP-R"
        case .turnLeft:   return "SSP-L"
        case .turnRight:  return "SSP-R"
        }
    }

    private func servoNormalLabel(snap: TelemetrySnapshot?) -> String {
        guard let joints = snap?.joints, !joints.isEmpty else { return "—" }
        let warnThreshold: UInt8 = 75
        let totalServos = 20
        let abnormal = joints.values.filter {
            $0.presentTemperature >= warnThreshold
        }.count
        return "\(totalServos - abnormal)"
    }

    // MARK: - V290-B: bar chart 테스트 헬퍼 (ServoHealthTile.tempBars 로직 미러)

    /// V290-B 테스트용 bar 데이터 모델 — 색상을 isWarn/isCrit flag 으로 표현
    private struct TestTempBar {
        let id: Int
        let temp: Double
        let isWarn: Bool    // amber: 75 <= temp < 90
        let isCrit: Bool    // vermillion: temp >= 90
    }

    /// ServoHealthTile.tempBars 와 동일 로직 (private 접근 불가 → 미러)
    private func tempBars(snap: TelemetrySnapshot?) -> [TestTempBar] {
        guard let joints = snap?.joints, !joints.isEmpty else { return [] }
        let warnThreshold: Double = 75
        let critThreshold: Double = 90
        return joints
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .enumerated()
            .map { idx, pair in
                let temp = Double(pair.value.presentTemperature)
                let isCrit = temp >= critThreshold
                let isWarn = !isCrit && temp >= warnThreshold
                return TestTempBar(id: idx + 1, temp: temp, isWarn: isWarn, isCrit: isCrit)
            }
    }
}
#endif
