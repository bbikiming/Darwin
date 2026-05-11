import Foundation

/// Claude CLI를 비대화형 subprocess로 호출해 사용자 한국어 입력을
/// `CommandPlan` JSON으로 변환한다.
///
/// 근거:
/// - Claude CLI reference (code.claude.com/docs/en/cli-reference)
///   --bare / --print / --output-format json / --no-session-persistence /
///   --max-budget-usd / --model haiku / --system-prompt
/// - Anthropic Haiku 4.5 가격 — $1/$5 per Mtok (조사 B)
/// - SystemPromptBuilder가 생성한 한국어 프롬프트 임베드
public actor ClaudeCommander {

    public enum CommanderError: Error, LocalizedError {
        case cliNotFound
        case notLoggedIn                              // Claude CLI 로그인 필요.
        case nonZeroExit(code: Int32, stderr: String)
        case invalidWrapper(String)
        case invalidPlan(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return KoreanUX.Errors.claudeNotInstalled.title
            case .notLoggedIn:
                return "Claude 로그인이 필요해요. Mac 터미널에서 `claude /login` 한 번만 실행 후 인증하세요."
            case .nonZeroExit(let code, let stderr):
                return "Claude 호출 실패 (exit=\(code)): \(stderr.prefix(120))"
            case .invalidWrapper(let raw):
                return "Claude 응답 형식이 예상과 달라요: \(raw.prefix(80))"
            case .invalidPlan(let raw):
                return "Claude가 의도를 정확히 만들지 못했어요: \(raw.prefix(80))"
            case .timeout:
                return "Claude 응답이 너무 늦어 중단했어요"
            }
        }
    }

    private struct ClaudeWrapper: Decodable {
        let type: String
        let result: String?
        let total_cost_usd: Double?
        let is_error: Bool?
    }

    /// claude 바이너리 경로 결정.
    /// 우선순위: 1) 명시 경로 2) `which claude` 3) "/usr/local/bin/claude" 폴백.
    public let claudePath: String
    public let modelAlias: String
    public let maxBudgetUSD: Double

    public init(
        claudePath: String? = nil,
        modelAlias: String = "haiku",
        maxBudgetUSD: Double = 0.10
    ) {
        if let p = claudePath {
            self.claudePath = p
        } else {
            self.claudePath = ClaudeCommander.locateClaudeBinary()
        }
        self.modelAlias = modelAlias
        self.maxBudgetUSD = maxBudgetUSD
    }

    /// 사용자 발화를 받아 CommandPlan 생성.
    public func plan(userText: String) async throws -> CommandPlan {
        let wrapper = try await invoke(userText: userText)
        if wrapper.is_error == true {
            // Claude CLI 가 result 필드에 사람이 읽을 에러 문자열을 넣음.
            let body = wrapper.result ?? ""
            let lower = body.lowercased()
            if lower.contains("not logged in")
                || lower.contains("please run /login")
                || lower.contains("/login") {
                throw CommanderError.notLoggedIn
            }
            throw CommanderError.nonZeroExit(code: -1, stderr: body)
        }
        guard let inner = wrapper.result else {
            throw CommanderError.invalidWrapper("missing result")
        }
        // Claude의 result 필드는 모델이 만든 텍스트 — JSON 객체여야 함.
        let cleaned = ClaudeCommander.extractJSONObject(from: inner)
        guard let data = cleaned.data(using: .utf8) else {
            throw CommanderError.invalidPlan(inner)
        }
        do {
            return try JSONDecoder().decode(CommandPlan.self, from: data)
        } catch {
            throw CommanderError.invalidPlan("\(error.localizedDescription) | raw: \(inner.prefix(200))")
        }
    }

    // MARK: - Internal

    private func invoke(userText: String) async throws -> ClaudeWrapper {
        // CLI 미설치 사전 체크
        if !FileManager.default.isExecutableFile(atPath: claudePath) {
            throw CommanderError.cliNotFound
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = [
            "--bare",
            "--print",
            "--output-format", "json",
            "--no-session-persistence",
            "--max-budget-usd", String(format: "%.2f", maxBudgetUSD),
            "--model", modelAlias,
            "--append-system-prompt", SystemPromptBuilder.build()
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        // 환경 변수 — 사용자 셸 PATH 포함하지 않으므로 명시.
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        p.environment = env

        try p.run()

        // 사용자 입력은 stdin으로.
        if let data = userText.data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try stdinPipe.fileHandleForWriting.close()

        // 60초 timeout.
        let timeoutTask = Task { [weak p] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if p?.isRunning == true { p?.terminate() }
        }

        p.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if p.terminationStatus != 0 {
            throw CommanderError.nonZeroExit(code: p.terminationStatus, stderr: stderrText)
        }

        guard let raw = String(data: stdoutData, encoding: .utf8), !raw.isEmpty else {
            throw CommanderError.invalidWrapper("empty stdout")
        }

        do {
            return try JSONDecoder().decode(ClaudeWrapper.self, from: stdoutData)
        } catch {
            throw CommanderError.invalidWrapper("\(error.localizedDescription) | raw: \(raw.prefix(200))")
        }
    }

    // MARK: - Static helpers

    /// PATH에서 claude 바이너리 찾기.
    private static func locateClaudeBinary() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_CLI_PATH"],
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            // nvm 경로 패턴
            (ProcessInfo.processInfo.environment["HOME"]).map { "\($0)/.nvm/versions/node/v24.14.0/bin/claude" },
            (ProcessInfo.processInfo.environment["HOME"]).map { "\($0)/.local/bin/claude" }
        ].compactMap { $0 }

        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // `which claude` 시도
        if let p = whichOutput("claude") { return p }
        return "/usr/local/bin/claude"  // 폴백 — 파일 미존재 시 에러로 떨어짐
    }

    private static func whichOutput(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [command]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Claude의 result 필드에서 첫 번째 JSON 객체만 추출 (관대한 파싱).
    /// 시스템 프롬프트로 강제하지만 모델이 가끔 prose를 추가하는 경우 대비.
    static func extractJSONObject(from text: String) -> String {
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < text.endIndex {
            let c = text[idx]
            if escape { escape = false }
            else if c == "\\" && inString { escape = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return String(text[start...])
    }
}

private extension Pipe {
    /// macOS 12+ readToEnd() 대체 — 이미 있는 경우 사용.
    func _readToEnd() throws -> Data? {
        try fileHandleForReading.readToEnd()
    }
}
