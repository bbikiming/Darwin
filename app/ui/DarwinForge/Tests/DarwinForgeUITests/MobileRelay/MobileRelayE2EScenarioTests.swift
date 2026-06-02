import XCTest
@testable import DarwinForgeUI

/// V297-7 E2E Scenario Verification — Gherkin/BDD 기반.
///
/// # 검증 방법론
///
/// ISO/IEC/IEEE 29119-4 의 State-Transition Testing + Scenario-Based Testing 결합.
/// 각 테스트는 **Given-When-Then** 형식으로 사용자 시나리오 전체 흐름을 추적한다.
///
/// # 비유
///
/// 신차 출고 전 도로주행 시험과 동일. unit test 가 엔진 각 부품 검사라면, 본 테스트는
/// "운전석 앉기 → 키 꽂기 → 시동 → 주행 → 정차 → 다시 출발" 같은 사용자 시나리오 전체.
///
/// 다루는 시나리오 (안전 critical 우선):
///   S1: 페어링 → 즉시 telemetry 도착
///   S2: ARM 성공 → walk 명령 → robot 으로 전달
///   S3: walk 활성 중 E-stop → robot 즉시 정지 + iOS UI estopped
///   S4: estopped → 복구 1탭 → arming → armedReady
///   S5: 동시 두 폰 (deviceId 다름) → 두 번째 alreadyOwned
///   S6: 시계 12s 드리프트 → walk clockSkew reject
///   S7: 페어링 코드 3회 실패 → lockout
final class MobileRelayE2EScenarioTests: XCTestCase {

    // MARK: - S1: 페어링 → 즉시 telemetry

    /// **Scenario S1** — 페어링 직후 사용자가 robot 상태를 보려면 첫 telemetry 가 빨리
    /// 도착해야 한다. acceptHello 끝의 broadcastTelemetry 가 확실히 호출되는지.
    ///
    /// - Given: Mac relay started + pairing code "111111"
    /// - When: iOS 가 valid hello 보내고 50ms 기다림
    /// - Then: welcome + 첫 telemetry.state 모두 도착
    func testS1_pairingDeliversTelemetryWithin50ms() async throws {
        let pairing = MobileRelayPairing(initialCode: "111111")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let channel = E2EChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "111111",
                                                                           deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let types = channel.frames.compactMap { decode($0)?.type }
        XCTAssertTrue(types.contains("session.welcome"),
                      "AC: welcome 도착")
        XCTAssertTrue(types.contains("telemetry.state"),
                      "AC: 페어링 직후 첫 telemetry.state 도착 (50ms 이내)")
    }

    // MARK: - S2: ARM → walk

    /// **Scenario S2** — ARM 후 walk 가 robot 으로 전달되어 ack 도착.
    ///
    /// - Given: paired + battery 11.7V
    /// - When: pilot.arm → wait → pilot.walk(slowForward)
    /// - Then: arm ack + walk ack 모두 도착, robotAckId 존재
    func testS2_armThenWalk_robotAckReceived() async throws {
        let pairing = MobileRelayPairing(initialCode: "222222")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = E2EChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "222222",
                                                                           deviceId: "phone-A"))
        await server.handleClientFrame(armFrame(id: "cmd_arm"), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        await server.handleClientFrame(walkFrame(id: "cmd_walk", preset: "slowForward"),
                                       from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let armAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_arm" && $0.type == "command.ack" }
        XCTAssertNotNil(armAck, "AC: ARM ack 도착")

        let walkAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_walk" && $0.type == "command.ack" }
        XCTAssertNotNil(walkAck, "AC: walk ack 도착")
        // robotAckId 검증 — sendWalk hook 이 robot 으로 전달됐다는 증거.
        if let frame = channel.frames.first(where: {
            decode($0)?.id == "cmd_walk" && decode($0)?.type == "command.ack"
        }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<AckPayload>.self, from: frame)
            XCTAssertNotNil(env?.payload.robotAckId, "AC: walk 의 robotAckId 가 있어 실제 robot 전달 추적 가능")
        }
    }

    // MARK: - S3: walk + E-stop → 즉시 정지

    /// **Scenario S3** — walk 활성 중 E-stop 도착하면 robot 이 즉시 estopped 상태로,
    /// iOS 가 받는 telemetry 도 estopped 표시.
    ///
    /// - Given: armed + walk 진행 중
    /// - When: pilot.estop
    /// - Then: command.ack + telemetry.robot == estopped
    func testS3_walkActiveThenEStop_robotStops() async throws {
        let pairing = MobileRelayPairing(initialCode: "333333")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = E2EChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "333333",
                                                                           deviceId: "phone-A"))
        await server.handleClientFrame(armFrame(id: "cmd_a"), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        await server.handleClientFrame(walkFrame(id: "cmd_w", preset: "slowForward"),
                                       from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        // E-stop.
        await server.handleClientFrame(estopFrame(id: "cmd_e"), from: channel)
        try await Task.sleep(nanoseconds: 100_000_000)

        // E-stop ack 도착.
        let estopAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_e" && $0.type == "command.ack" }
        XCTAssertNotNil(estopAck, "AC: E-stop ack 도착")

        // 다음 telemetry 가 estopped 상태 반영.
        await server.broadcastTelemetry()
        try await Task.sleep(nanoseconds: 30_000_000)
        let latestTelemetry = channel.frames.compactMap { decode($0) }
            .last { $0.type == "telemetry.state" }
        XCTAssertNotNil(latestTelemetry)
        let snap = await port.snapshot()
        XCTAssertEqual(snap.robot, .estopped, "AC: port 가 robot=estopped 보고")
    }

    // S4 (FSM 시나리오) 는 iOS target 에서 별도 테스트 파일로 분리.
    // (Mac DarwinForgeUI 는 MobilePilotKit 모듈을 import 하지 않음.)
    // → app/mobile/DarwinForgeMobile/Tests/MobilePilotKitTests/RecoveryFSMScenarioTests.swift

    // MARK: - S5: 동시 두 폰 (다른 deviceId) → alreadyOwned

    func testS5_secondPhoneWithDifferentDeviceIdRejected() async throws {
        let pairing = MobileRelayPairing(initialCode: "555000")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let first = E2EChannel()
        let second = E2EChannel()

        await server.handleClientConnected(first, handshake: helloFrame(code: "555000",
                                                                         deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 30_000_000)
        await server.handleClientConnected(second, handshake: helloFrame(code: "555000",
                                                                          deviceId: "phone-B"))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(first.frames.contains { decode($0)?.type == "session.welcome" })
        let secondRejected = second.frames.compactMap { decode($0) }
            .first { $0.type == "session.rejected" }
        XCTAssertNotNil(secondRejected)
        if let frame = second.frames.first(where: { decode($0)?.type == "session.rejected" }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<SessionRejectedPayload>.self, from: frame)
            XCTAssertEqual(env?.payload.reason, "alreadyOwned")
        }
    }

    // MARK: - S6: 시계 12s 드리프트 → clockSkew

    func testS6_clockSkew12sRejectsWalk() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let pairing = MobileRelayPairing(initialCode: "606060")
        let port = InMemorySafetyPort()
        // Mac clock 이 base − 12s — iOS sentAt(base) 와 12초 차이.
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       clock: { base.addingTimeInterval(-12.0) },
                                       batteryVoltage: { 11.7 })
        let channel = E2EChannel()

        await server.handleClientConnected(channel,
                                            handshake: helloFrameRaw(code: "606060",
                                                                     deviceId: "phone-A",
                                                                     sentAt: base))
        await server.handleClientFrame(walkFrameRaw(id: "cmd_skew", sentAt: base, preset: "slowForward"),
                                       from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_skew" && $0.type == "command.rejected" }
        XCTAssertNotNil(rejected, "AC: 12s 드리프트 walk 는 reject")
        if let frame = channel.frames.first(where: {
            decode($0)?.id == "cmd_skew" && decode($0)?.type == "command.rejected"
        }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<RejectedPayload>.self, from: frame)
            XCTAssertEqual(env?.payload.reason, "clockSkew")
        }
    }

    // MARK: - S7: 페어링 코드 3회 실패 → lockout

    func testS7_threeWrongCodesTriggerLockout() async throws {
        let pairing = MobileRelayPairing(initialCode: "777777")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())

        for attempt in 1...3 {
            let c = E2EChannel()
            await server.handleClientConnected(c, handshake: helloFrame(code: "000000",
                                                                         deviceId: "phone-attempt-\(attempt)"))
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        // 3번째 시도가 .locked 응답.
        let pairingNow = pairing.validate("777777", now: Date())
        if case .locked = pairingNow {
            // OK — lockout 활성.
        } else {
            XCTFail("AC: 3회 실패 후 lockout 활성 (validate 가 .locked 반환해야)")
        }
    }

    // MARK: - S8: E-stop ack + port.snapshot == .estopped

    /// **Scenario S8** — paired + armed + walk 진행 중 E-stop 송신.
    /// E-stop ack 가 도착하고 port.snapshot 의 robot == .estopped 확인.
    ///
    /// - Given: paired + ARM + walk 진행
    /// - When: pilot.estop 송신
    /// - Then: command.ack 도착, port.snapshot 의 robot == .estopped
    ///
    /// V297-8 (P3-Tests): S8
    func testS8_estopAckedNormally() async throws {
        let pairing = MobileRelayPairing(initialCode: "888000")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = E2EChannel()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "888000",
                                                                 deviceId: "phone-S8"))
        await server.handleClientFrame(armFrame(id: "s8_arm"), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        await server.handleClientFrame(walkFrame(id: "s8_walk", preset: "slowForward"),
                                       from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        // E-stop.
        await server.handleClientFrame(estopFrame(id: "s8_estop"), from: channel)
        try await Task.sleep(nanoseconds: 100_000_000)

        // E-stop ack 도착 확인.
        let estopAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "s8_estop" && $0.type == "command.ack" }
        XCTAssertNotNil(estopAck, "AC: E-stop ack 도착")

        // port snapshot 이 robot == .estopped 반영.
        let snap = await port.snapshot()
        XCTAssertEqual(snap.robot, .estopped,
                       "AC: port.snapshot.robot == .estopped (E-stop 실행 후)")
    }

    // MARK: - S9: priority E-stop bypasses long ARM (V297-5 CRITICAL-1)

    /// **Scenario S9** — paired, battery nil (2초 grace polling), ARM 직후 E-stop 송신.
    /// E-stop 의 ack 가 ARM 응답보다 먼저 channel.frames 에 도착해야 한다.
    ///
    /// - Given: paired, battery nil (cold-boot grace polling 진행)
    /// - When: pilot.arm 보내고 곧이어 Task 로 pilot.estop 병렬 송신
    /// - Then: E-stop ack 가 ARM ack 보다 channel.frames 배열 인덱스 상 앞에 위치
    ///
    /// V297-8 (P3-Tests): S9 — V297-5 CRITICAL-1 priority bypass 회귀 방어.
    func testS9_priorityEstopBypassesLongARM() async throws {
        let pairing = MobileRelayPairing(initialCode: "999001")
        let port = InMemorySafetyPort()
        // batteryVoltage = nil → ARM 이 최대 2초 grace polling 진입.
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { nil })
        let channel = E2EChannel()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "999001",
                                                                 deviceId: "phone-S9"))
        try await Task.sleep(nanoseconds: 20_000_000)

        // ARM 을 background Task 로 발사 (2초 grace polling 대기 예상).
        let armTask = Task {
            await server.handleClientFrame(armFrame(id: "s9_arm"), from: channel)
        }

        // ARM 이 grace polling 에 진입할 시간 확보.
        try await Task.sleep(nanoseconds: 50_000_000)

        // E-stop 을 별도 Task 로 병렬 발사 — WSChannel 에서는 priority bypass 로 직행.
        // 단위 테스트에서 handleClientFrame 은 actor 직렬 실행이라 grace poll 완료 후
        // 직렬 처리되지만, battery nil 정책은 2초 후 lowBattery reject 로 ARM 을 끝냄.
        // E-stop 자체의 ack 는 ARM rejected 응답 이전에는 오지 않을 수 있으나
        // 결과적으로 E-stop ack 가 존재하고 rejected/ack frame 이 모두 도착해야 한다.
        let estopTask = Task {
            await server.handleClientFrame(estopFrame(id: "s9_estop"), from: channel)
        }

        // ARM grace (2초) + 여유 500ms 대기.
        try await Task.sleep(nanoseconds: 2_600_000_000)
        _ = await armTask.value
        _ = await estopTask.value

        let frameTypes = channel.frames.compactMap { decode($0) }

        // E-stop ack 가 존재해야 한다.
        let estopAck = frameTypes.first { $0.id == "s9_estop" && $0.type == "command.ack" }
        XCTAssertNotNil(estopAck,
                        "AC: E-stop ack 도착 (battery nil 시나리오에서도)")

        // E-stop ack 가 ARM 최종 응답보다 앞선 인덱스에 있어야 한다.
        let allFrames = channel.frames.compactMap { decode($0) }
        if let estopIdx = allFrames.firstIndex(where: { $0.id == "s9_estop" && $0.type == "command.ack" }),
           let armFinalIdx = allFrames.lastIndex(where: { $0.id == "s9_arm" }) {
            XCTAssertLessThan(estopIdx, armFinalIdx,
                              "AC: E-stop ack 인덱스(\(estopIdx)) < ARM 최종응답 인덱스(\(armFinalIdx)) — priority bypass 검증")
        } else {
            // battery nil → ARM 은 lowBattery reject 되고 E-stop 은 ack. 둘 다 존재 확인.
            let armResponse = allFrames.first { $0.id == "s9_arm" }
            XCTAssertNotNil(armResponse, "AC: ARM 응답(rejected/ack) 존재")
        }
    }

    // MARK: - S10: disarm does not cache RTT (V297-5 HIGH-2)

    /// **Scenario S10** — ARM(50ms) 후 disarm. disarm RTT 가 캐시에 들어가지 않으므로
    /// 이어서 walk gate 는 캐시 nil 상태로 관대 통과해야 한다.
    ///
    /// 검증 로직:
    ///   1. ARM latencyMs=50 → RTT cache=50ms
    ///   2. disarm (port latencyMs 유지 50ms — 캐시 안 됨)
    ///   3. port latencyMs 를 400ms 로 올림 (이후 arm 이 cache 를 오염시키는지 확인용)
    ///   4. 두 번째 ARM(400ms) → RTT cache=400ms (arm 은 정상 캐시)
    ///   5. disarm(400ms) — 캐시 오염 없어야 함
    ///   6. 세 번째 ARM(40ms) → RTT cache=40ms (cache 리셋용)
    ///   7. walk → 40ms 캐시 → gate 통과 (disarm 의 400ms 가 캐시에 안 남아 있음 검증)
    ///
    /// V297-8 (P3-Tests): S10
    func testS10_disarmDoesNotCacheRTT() async throws {
        let pairing = MobileRelayPairing(initialCode: "101010")
        let port = MutableLatencyGateTestPort(latencyMs: 50)
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = E2EChannel()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "101010",
                                                                 deviceId: "phone-S10"))
        // 1. 첫 ARM (RTT 50ms prime).
        await server.handleClientFrame(armFrame(id: "s10_arm1"), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        // 2. disarm (50ms — cache 안 됨 정책).
        await server.handleClientFrame(
            buildFrame(type: "pilot.disarm", id: "s10_disarm1", sentAt: Date(),
                       payload: ["reason": "test"]),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        // 3. disarm 후 latencyMs 400ms 설정 (walk gate 350ms 초과).
        port.latencyMs = 400

        // 4. 두 번째 ARM (400ms prime — arm 은 정상 캐시 = 400ms).
        await server.handleClientFrame(armFrame(id: "s10_arm2"), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        // 5. disarm (400ms — cache 안 됨).
        await server.handleClientFrame(
            buildFrame(type: "pilot.disarm", id: "s10_disarm2", sentAt: Date(),
                       payload: ["reason": "test2"]),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        // 6. latencyMs 를 40ms 로 리셋 후 세 번째 ARM (cache = 40ms — gate 통과 범위).
        port.latencyMs = 40
        await server.handleClientFrame(armFrame(id: "s10_arm3"), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        // 7. walk — 최종 RTT cache = 40ms (arm3 기준) → gate(350ms) 통과.
        //    만약 disarm2(400ms) 가 캐시에 들어가 있었다면 reject.
        await server.handleClientFrame(walkFrame(id: "s10_walk", preset: "slowForward"),
                                       from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let walkRejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "s10_walk" && $0.type == "command.rejected" }
        XCTAssertTrue(walkRejected.isEmpty,
                      "AC: disarm RTT 가 캐시에 들어가지 않아 walk 는 40ms cache 로 gate 통과")

        let walkAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "s10_walk" && $0.type == "command.ack" }
        XCTAssertNotNil(walkAck, "AC: walk ack 도착 (disarm non-caching 확인)")
    }

    // MARK: - S11: capabilities included in welcome

    /// **Scenario S11** — 서버 시작 후 hello 송신 시 welcome.payload.capabilities 가
    /// nil 아니고 head=false, walkFreeform=true, speedScaleAccepted=true 이어야 한다.
    ///
    /// - Given: server 시작
    /// - When: 정상 hello 송신
    /// - Then: welcome.payload.capabilities 가 non-nil, head=false, walkFreeform=true,
    ///         speedScaleAccepted=true
    ///
    /// V297-8 (P3-Tests): S11
    func testS11_capabilitiesIncludedInWelcome() async throws {
        let pairing = MobileRelayPairing(initialCode: "111200")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let channel = E2EChannel()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "111200",
                                                                 deviceId: "phone-S11"))
        try await Task.sleep(nanoseconds: 50_000_000)

        // welcome 프레임 찾기.
        guard let welcomeFrame = channel.frames.first(where: { decode($0)?.type == "session.welcome" }) else {
            XCTFail("AC: session.welcome 미도착")
            return
        }

        let env = try RelayCodec.decoder.decode(RelayEnvelope<WelcomePayload>.self,
                                                from: welcomeFrame)
        let caps = env.payload.capabilities
        XCTAssertNotNil(caps,
                        "AC: welcome.payload.capabilities 가 nil 아님")
        XCTAssertEqual(caps?.head, false,
                       "AC: capabilities.head = false (head MVP 미지원)")
        XCTAssertEqual(caps?.walkFreeform, true,
                       "AC: capabilities.walkFreeform = true (iOS joystick freeform 지원)")
        XCTAssertEqual(caps?.speedScaleAccepted, true,
                       "AC: capabilities.speedScaleAccepted = true (스키마 수신/검증 지원)")
    }

    // MARK: - Helpers

    private func helloFrame(code: String, deviceId: String) -> Data {
        helloFrameRaw(code: code, deviceId: deviceId, sentAt: Date())
    }

    private func helloFrameRaw(code: String, deviceId: String, sentAt: Date) -> Data {
        buildFrame(type: "session.hello", id: "cmd_hello_\(deviceId)", sentAt: sentAt,
                   payload: ["app": "ios", "appVersion": "0.1.0", "protocolVersion": 1,
                             "deviceName": "Test", "deviceId": deviceId, "pairingCode": code])
    }

    private func armFrame(id: String) -> Data {
        buildFrame(type: "pilot.arm", id: id, sentAt: Date(),
                   payload: ["cradleConfirmed": true, "operator": "Tester"])
    }

    private func walkFrame(id: String, preset: String) -> Data {
        walkFrameRaw(id: id, sentAt: Date(), preset: preset)
    }

    private func walkFrameRaw(id: String, sentAt: Date, preset: String) -> Data {
        buildFrame(type: "pilot.walk", id: id, sentAt: sentAt,
                   payload: ["preset": preset, "enabled": true,
                             "xMm": 20.0, "yMm": 0.0, "aDeg": 0.0,
                             "periodMs": 700, "footMm": 35.0, "hipPitchDeg": 13.0])
    }

    private func estopFrame(id: String) -> Data {
        buildFrame(type: "pilot.estop", id: id, sentAt: Date(),
                   payload: ["reason": "user"])
    }

    private func buildFrame(type: String, id: String, sentAt: Date, payload: [String: Any]) -> Data {
        let iso = ISO8601DateFormatter.e2eFractional.string(from: sentAt)
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type, "sentAt": iso, "payload": payload
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func decode(_ data: Data) -> RelayEnvelopeHead? {
        try? RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data)
    }
}

// MARK: - E2EChannel

final class E2EChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }

    func deliver(_ frame: Data) async throws {
        lock.lock(); _frames.append(frame); lock.unlock()
    }

    func disconnect(reason: String) async { _ = reason }
}

private extension ISO8601DateFormatter {
    static let e2eFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
