import Foundation
import ForgeCore

/// 사용자 발화로부터 도출된 `CommandPlan`을 안전 검증·실행한다.
///
/// 5계층 안전 모델 중 L2 (Whitelist), L3 (Safety Clip / Dry-run),
/// L4 (HITL Approval), L5 (Hardware E-Stop)을 담당.
///
/// L1 (Constitutional refusal)은 Claude system prompt에서 처리.
@MainActor
public final class IntentDispatcher: ObservableObject {

    public enum DispatcherError: Error, LocalizedError {
        case noBus(String)
        case unknownTool(String)
        case invalidArgs(String)
        case forge(String)

        public var errorDescription: String? {
            switch self {
            case .noBus(let msg): return msg
            case .unknownTool(let name): return KoreanUX.Errors.unknownTool(name).title
            case .invalidArgs(let msg): return msg
            case .forge(let msg): return msg
            }
        }

        /// 사이클 187 (codex MINOR fix cycle 181): telemetry-friendly case name 만.
        /// 종전: `String(describing: err)` 가 associated value (예: noBus("darwin.local
        /// 에 연결 필요"), invalidArgs(...)) 본문 노출 → 부분 PII leak.
        /// 신규: enum case name 만 — cycle 182 shellErrorCase 패턴 일관.
        public var telemetryCase: String {
            switch self {
            case .noBus:        return "no_bus"
            case .unknownTool:  return "unknown_tool"
            case .invalidArgs:  return "invalid_args"
            case .forge:        return "forge"
            }
        }
    }

    public struct ExecutionResult: Sendable, Equatable {
        public let speak: String           // 한국어 사용자 응답
        public let detail: String?         // 상세 (raw forge 출력 — 옵션)
        public let wasClipped: Bool        // 안전 범위로 자동 조정됐나

        public init(speak: String, detail: String? = nil, wasClipped: Bool = false) {
            self.speak = speak
            self.detail = detail
            self.wasClipped = wasClipped
        }
    }

    /// 현재 활성화된 모드 — UI 인디케이터에 노출.
    public enum Mode: String, Sendable {
        case simulation     // dry-run only
        case hardware       // 실 로봇 (USB 연결됨)
        case offline        // USB 미연결
    }

    /// **사이클 125 (audit #16, P1)**: 기본값 `.simulation` — 처음 앱 실행 시 사용자가 명시
    /// 연결하기 전까지 dry-run only. UI 가 본 mode 를 명시 표시해야 사용자 오해 차단.
    /// ConnectionStore 가 bus 연결 감지 시 IntentDispatcher.mode 를 `.hardware` 로 갱신.
    @Published public var mode: Mode = .simulation

    /// `ConnectionStore`가 보유한 Bus를 받아서 사용 — DI.
    public weak var connectionStore: ConnectionStore?

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    private let harness: any HarnessFacade

    public init(harness: (any HarnessFacade)? = nil) {
        self.harness = harness ?? LiveHarness.shared
    }

    // MARK: - 공용 진입점

    /// CommandPlan을 실행한다.
    /// 호출 측은 `needs_confirmation`을 사전에 확인하고 사용자 승인 후 호출.
    public func execute(_ plan: CommandPlan) async throws -> ExecutionResult {
        let toolName = String(describing: plan.tool)
        let currentMode = mode.rawValue

        // Telemetry: mode resolution — simulation vs hardware 판단 근거.
        harness.record(
            .claudeIntentDispatched, level: .info, actor: .claude,
            data: ["tool": AnyCodable(toolName),
                   "mode": AnyCodable(currentMode)]
        )

        do {
            let result = try await dispatchTool(plan)
            return result
        } catch {
            let errorCase: String
            if let de = error as? DispatcherError {
                errorCase = de.telemetryCase
            } else {
                errorCase = "generic"
            }
            harness.record(
                .claudeIntentError, level: .warn, actor: .system,
                data: ["tool": AnyCodable(toolName),
                       "error_case": AnyCodable(errorCase)]
            )
            throw error
        }
    }

    /// `execute(_:)` 에서 telemetry 를 분리하기 위한 내부 라우터.
    private func dispatchTool(_ plan: CommandPlan) async throws -> ExecutionResult {
        switch plan.tool {
        // 정보 조회 — Bus 필요
        case .ports: return try await runPorts()
        case .ping: return try await runPing(args: plan.args)
        case .scan: return try await runScan(args: plan.args)
        case .board_snapshot: return try await runBoardSnapshot()
        case .joint_state: return try await runJointState(args: plan.args)
        case .motion_inspect: return try await runMotionInspect(args: plan.args)
        case .status_report: return try await runStatusReport()

        // 모터 동작 — Bus 필요
        case .joint_set_position: return try await runJointSetPosition(args: plan.args)
        case .joint_torque: return try await runJointTorque(args: plan.args)
        case .wake_up: return try await runWakeUp()
        case .sleep: return try await runSleep()

        // 안전 critical — LLM 경로 우회 가능
        case .emergency_stop: return try await runEmergencyStop()

        // 신규 — AI 모션/자세 도구.
        case .apply_named_pose: return try await runApplyNamedPose(args: plan.args)
        case .build_motion:     return try await runBuildMotion(args: plan.args)
        case .search_pose:      return try await runSearchPose(args: plan.args)

        // 거부 — 도구 호출 없이 사용자 응답만
        case .refuse:
            let reason = plan.args["reason"]?.stringValue ?? "이유를 명시하지 않았어요"
            return ExecutionResult(speak: reason)
        }
    }

    // MARK: - AI motion/pose dispatch

    private func runApplyNamedPose(args: [String: ArgValue]) async throws -> ExecutionResult {
        guard let id = args["pose_id"]?.stringValue else {
            throw DispatcherError.invalidArgs("pose_id 가 필요해요")
        }
        guard let named = PoseLibrary.get(id) else {
            // id 가 없으면 keyword 로 search 한 번 더.
            if let fallback = PoseLibrary.search(id) {
                if let store = connectionStore {
                    let r = await store.applyPoseSmoothly(fallback.pose)
                    return ExecutionResult(
                        speak: speakForPose(r, displayName: fallback.displayName, fallbackFrom: id)
                    )
                }
                // **사이클 122 (audit #17, P0)**: bus nil → [시뮬] prefix 명시.
                // 종전 "적용했어요" → 사용자가 실 robot 동작으로 오해. 실 송출은 안 함.
                return ExecutionResult(
                    speak: "[시뮬] '\(id)' 정확한 ID 가 없어 '\(fallback.displayName)' 으로 미리보기 (실 robot 미연결)."
                )
            }
            throw DispatcherError.invalidArgs("자세 '\(id)' 를 찾지 못했어요")
        }
        if let store = connectionStore {
            let r = await store.applyPoseSmoothly(named.pose)
            return ExecutionResult(speak: speakForPose(r, displayName: named.displayName, description: named.description))
        }
        // **사이클 122 (audit #17, P0)**: bus nil → [시뮬] prefix 명시.
        return ExecutionResult(
            speak: "[시뮬] 자세 '\(named.displayName)' 미리보기 (실 robot 미연결) — \(named.description)"
        )
    }

    /// Codex 2차 권고: applyPoseSmoothly 결과를 Claude 의 speak 응답에 surface.
    private func speakForPose(_ r: ConnectionStore.PoseApplyResult, displayName: String,
                              description: String? = nil, fallbackFrom: String? = nil) -> String {
        let prefix = fallbackFrom.map { "'\($0)' 정확한 ID 가 없어 '\(displayName)' 으로 시도 — " } ?? ""
        switch r {
        case .completed:
            let extra = description.map { " — \($0)" } ?? ""
            return "\(prefix)✓ '\(displayName)' 적용\(extra)"
        case .partialFailure:
            return "\(prefix)⚠ '\(displayName)' 부분 완료 — \(r.userMessage)"
        case .notConnected:
            return "\(prefix)ℹ '\(displayName)' 시뮬 미리보기만 진행 (실 로봇 미연결)"
        case .rejected, .cancelled, .writeFailed, .criticalLoad:
            return "\(prefix)✗ '\(displayName)' 실패 — \(r.userMessage)"
        }
    }

    private func runBuildMotion(args: [String: ArgValue]) async throws -> ExecutionResult {
        let description = args["description"]?.stringValue ?? ""
        guard !description.isEmpty else {
            throw DispatcherError.invalidArgs("어떤 동작인지 설명이 필요해요")
        }
        let steps = MotionBuilder.parseHeuristic(description)
        guard !steps.isEmpty else {
            return ExecutionResult(
                speak: "'\(description)' 에서 해당하는 자세를 찾지 못했어요. '인사' '손 흔들기' '박수' 같은 키워드를 포함해 보세요."
            )
        }
        let stepsDesc = steps.map { $0.poseId }.joined(separator: " → ")
        return ExecutionResult(
            speak: "동작 빌드 완료 — \(steps.count) 스텝 (\(stepsDesc)). 모션 스튜디오에서 확인하세요."
        )
    }

    private func runSearchPose(args: [String: ArgValue]) async throws -> ExecutionResult {
        let query = args["query"]?.stringValue ?? ""
        guard !query.isEmpty else {
            throw DispatcherError.invalidArgs("검색어가 필요해요")
        }
        guard let found = PoseLibrary.search(query) else {
            return ExecutionResult(
                speak: "'\(query)' 에 해당하는 자세를 찾지 못했어요."
            )
        }
        return ExecutionResult(
            speak: "\(found.displayName) — \(found.description) (id: \(found.id))"
        )
    }

    /// L5 — Hardware E-Stop. LLM 경로 우회로 호출 가능.
    /// 실패해도 항상 한국어 응답.
    public func emergencyStop() async -> ExecutionResult {
        do {
            return try await runEmergencyStop()
        } catch {
            // Bus 없어도 비상정지는 성공으로 간주 (이미 안전 상태).
            return ExecutionResult(
                speak: "현재 로봇과 연결되지 않아 보내지 못했지만, 시뮬에서는 모든 힘을 풀었어요.",
                detail: error.localizedDescription
            )
        }
    }

    // MARK: - 정보 조회

    private func runPorts() async throws -> ExecutionResult {
        let ports = (try? SerialPortEnumerator.available()) ?? []
        if ports.isEmpty {
            return ExecutionResult(speak: KoreanUX.Connection.noPort)
        }
        return ExecutionResult(
            speak: KoreanUX.Connection.portsFound(ports.count),
            detail: ports.joined(separator: ", ")
        )
    }

    private func runPing(args: [String: ArgValue]) async throws -> ExecutionResult {
        let id = args["id"]?.intValue ?? 200
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "로봇이 연결되어 있지 않아요. 시뮬 모드에서는 ping을 보낼 수 없어요.")
        }
        do {
            try bus.ping(id: UInt8(clamping: id))
            let label = KoreanUX.JointName.from(rawId: id)
            return ExecutionResult(speak: "\(label)이(가) 정상적으로 응답했어요")
        } catch {
            return ExecutionResult(speak: "\(KoreanUX.JointName.from(rawId: id))에서 응답이 없어요", detail: "\(error)")
        }
    }

    private func runScan(args: [String: ArgValue]) async throws -> ExecutionResult {
        let lo = UInt8(clamping: args["lo"]?.intValue ?? 1)
        let hi = UInt8(clamping: args["hi"]?.intValue ?? 20)
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "로봇이 연결되어 있지 않아요. 시뮬 모드에서는 스캔할 수 없어요.")
        }
        do {
            let ids = try bus.scan(lo: lo, hi: hi).map(Int.init)
            if ids.isEmpty {
                return ExecutionResult(speak: "응답한 관절이 없어요. 케이블이나 전원을 확인해 주세요.")
            }
            return ExecutionResult(
                speak: KoreanUX.Connection.jointsFound(ids),
                detail: "ID: \(ids.map(String.init).joined(separator: ", "))"
            )
        } catch {
            return ExecutionResult(speak: "스캔 중 오류가 났어요", detail: "\(error)")
        }
    }

    private func runBoardSnapshot() async throws -> ExecutionResult {
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "로봇이 연결되어 있지 않아요.")
        }
        do {
            let snap = try bus.boardSnapshot()
            let v = String(format: "%.1f", snap.voltageVolts)
            return ExecutionResult(
                speak: "보드 \(snap.modelNumber)번, 펌웨어 \(snap.version), 배터리 \(v)V예요",
                detail: snap.voltageVolts < 9.5 ? "⚠ 전압이 낮아요. 충전을 권장해요." : nil
            )
        } catch {
            return ExecutionResult(speak: "보드 상태를 읽지 못했어요", detail: "\(error)")
        }
    }

    private func runJointState(args: [String: ArgValue]) async throws -> ExecutionResult {
        let id = args["id"]?.intValue ?? 19
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "로봇이 연결되어 있지 않아요.")
        }
        guard let jid = JointID(rawValue: UInt8(clamping: id)) else {
            return ExecutionResult(speak: "그 관절은 사용하지 않는 번호예요 (\(id))")
        }
        do {
            let s = try bus.readState(jid)
            let label = KoreanUX.JointName.from(rawId: id)
            let temp = s.presentTemperature
            let hot = temp >= 60 ? " (조금 따뜻해요)" : ""
            return ExecutionResult(
                speak: "\(label) — 위치 \(s.presentPosition), 온도 \(temp)°C\(hot)",
                detail: "goal=\(s.goalPosition) speed=\(s.presentSpeed) load=\(s.presentLoad)"
            )
        } catch {
            return ExecutionResult(speak: "관절 상태를 읽지 못했어요", detail: "\(error)")
        }
    }

    private func runMotionInspect(args: [String: ArgValue]) async throws -> ExecutionResult {
        guard let path = args["path"]?.stringValue else {
            return ExecutionResult(speak: "어떤 동작 파일을 볼지 알려주세요. (예: motion.mtn)")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ExecutionResult(speak: "그 파일을 열 수 없어요: \(url.lastPathComponent)")
        }
        do {
            let json = try Motion.mtnToJSON(text, generation: "op2")
            let pages = countPages(in: json)
            return ExecutionResult(
                speak: "\(url.lastPathComponent): 페이지 \(pages)개의 동작이 들어있어요",
                detail: String(json.prefix(400))
            )
        } catch {
            return ExecutionResult(speak: "파일을 읽었지만 형식을 이해하지 못했어요", detail: "\(error)")
        }
    }

    private func runStatusReport() async throws -> ExecutionResult {
        let board = try await runBoardSnapshot()
        return ExecutionResult(
            speak: "지금 \(board.speak). 자세한 관절 상태는 전문가 모드에서 볼 수 있어요.",
            detail: board.detail
        )
    }

    // MARK: - 모터 동작 (HITL 후 호출됨)

    private func runJointSetPosition(args: [String: ArgValue]) async throws -> ExecutionResult {
        guard let id = args["id"]?.intValue,
              let rawPos = args["position"]?.intValue else {
            throw DispatcherError.invalidArgs("관절 ID와 위치가 필요해요")
        }
        guard SafetyLimits.isValidJointId(id),
              let jid = JointID(rawValue: UInt8(clamping: id)) else {
            throw DispatcherError.invalidArgs("\(id)번 관절은 지원하지 않아요")
        }
        let (clipped, wasClipped) = SafetyLimits.clipJointPosition(rawPos)
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(
                speak: "[시뮬] \(KoreanUX.JointName.from(rawId: id))을(를) \(clipped)으로 보낼 거예요. 실 로봇 연결 후 진행돼요.",
                wasClipped: wasClipped
            )
        }
        do {
            let appliedPos = try bus.setPosition(jid, raw: UInt16(clamping: clipped))
            let label = KoreanUX.JointName.from(rawId: id)
            let speak: String
            if wasClipped {
                speak = "\(label)을(를) 안전 범위(\(appliedPos))로 보냈어요"
            } else {
                speak = "\(label)을(를) \(appliedPos) 위치로 보냈어요"
            }
            return ExecutionResult(speak: speak, wasClipped: wasClipped)
        } catch {
            throw DispatcherError.forge("\(error)")
        }
    }

    private func runJointTorque(args: [String: ArgValue]) async throws -> ExecutionResult {
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "로봇이 연결되어 있지 않아 시뮬만 했어요.")
        }
        let enable = args["enable"]?.boolValue ?? true
        if let target = args["id"]?.stringValue, target.lowercased() == "all" {
            try setTorqueAll(bus: bus, enable: enable)
            return ExecutionResult(speak: enable
                ? "관절 20개에 모두 힘이 들어왔어요"
                : "관절 20개의 힘을 모두 풀었어요")
        }
        if let id = args["id"]?.intValue, let jid = JointID(rawValue: UInt8(clamping: id)) {
            try bus.setTorque(jid, enable: enable)
            let label = KoreanUX.JointName.from(rawId: id)
            return ExecutionResult(speak: "\(label) 힘을 \(enable ? "켰어요" : "풀었어요")")
        }
        throw DispatcherError.invalidArgs("관절을 특정해 주세요 (id 또는 'all')")
    }

    private func runWakeUp() async throws -> ExecutionResult {
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "[시뮬] " + KoreanUX.Motion.wakeUpStart)
        }
        try setTorqueAll(bus: bus, enable: true)
        return ExecutionResult(speak: KoreanUX.Motion.wakeUpDone)
    }

    private func runSleep() async throws -> ExecutionResult {
        guard let bus = connectionStore?.bus else {
            return ExecutionResult(speak: "[시뮬] " + KoreanUX.Motion.sleepStart)
        }
        // E-stop과 같은 효과 — 모든 관절 토크 OFF.
        try bus.emergencyStop()
        return ExecutionResult(speak: KoreanUX.Motion.sleepDone)
    }

    /// 모든 관절에 토크 켜기 — FFI에 batch 함수 없어 loop.
    /// (실 로봇 운영 시: SYNC_WRITE를 통한 batch 토크 설정은 forge-core가 내부적으로 1회로 묶음)
    private func setTorqueAll(bus: Bus, enable: Bool) throws {
        if !enable {
            // 모든 토크 OFF는 emergency_stop이 단일 SYNC_WRITE로 처리.
            try bus.emergencyStop()
            return
        }
        for jid in JointID.allCases {
            try bus.setTorque(jid, enable: true)
        }
    }

    private func runEmergencyStop() async throws -> ExecutionResult {
        // L5 — 항상 시도. Bus 없어도 시뮬 응답.
        if let bus = connectionStore?.bus {
            try? bus.emergencyStop()
        }
        return ExecutionResult(speak: KoreanUX.Safety.estopTriggered)
    }

    // MARK: - 헬퍼

    private func countPages(in json: String) -> Int {
        // 가벼운 카운팅 — 정식 디코딩은 후속.
        return json.components(separatedBy: "\"id\"").count - 1
    }
}
