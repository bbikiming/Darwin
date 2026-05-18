import Foundation

/// **v1.11.9 (2026-05-19)** — Claude CLI 호출 layer.
///
/// `WalkSessionClaudePrompt` 가 생성한 markdown prompt 를 stdin 으로 claude CLI 에
/// 전달하고 markdown 응답을 stdout 으로 받음. Process API 사용 (sandbox 해제 가정).
///
/// **claude CLI 호출 모드** (Claude Code 2.x):
/// - `claude -p "..."` — single-shot print 모드 (대화형 X)
/// - `--output-format text|json|stream-json` — text 가 가독성 best
/// - `--permission-mode bypassPermissions` — 또는 default (이 분석은 read-only)
///
/// **에러 처리**:
/// - CLI 미설치 → 명확한 에러 메시지
/// - 타임아웃 (60초 default) → cancel + 에러
/// - stderr 로깅 → 사용자에게 표시
///
/// **Privacy**: prompt 가 사용자 robot 데이터 포함. claude CLI 가 내부에서 어떻게
/// 처리하든 (Anthropic API or local LLM) caller 책임 아님. 사용자가 명시 실행.
public actor WalkSessionClaudeAnalyst {

    /// claude CLI 후보 path list — `which` 결과 또는 흔한 위치.
    public static let candidatePaths: [String] = [
        "/Users/bbikiming/.local/bin/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/Users/bbikiming/.npm-global/bin/claude",
    ]

    /// 분석 timeout (초). default 120 (Claude Code 응답 길이 고려).
    public let timeoutSeconds: TimeInterval

    /// claude CLI 절대 경로. nil 이면 candidatePaths 에서 자동 탐지.
    public let cliPath: String?

    /// 마지막 stderr (디버그 용).
    public private(set) var lastStderr: String = ""

    public init(cliPath: String? = nil, timeoutSeconds: TimeInterval = 120) {
        self.cliPath = cliPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// claude CLI 가 시스템에 존재하는지 검증.
    public static func resolvedCliPath(override: String? = nil) -> String? {
        let fm = FileManager.default
        if let override, fm.isExecutableFile(atPath: override) {
            return override
        }
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            return p
        }
        // 사용자 PATH 추가 (env $PATH 의 첫 hit).
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.split(separator: ":") {
            let candidate = String(dir) + "/claude"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// prompt 를 claude CLI 에 전달 + 응답 받기.
    /// - Parameter prompt: markdown prompt (`WalkSessionClaudePrompt.build(...)` 결과)
    /// - Returns: stdout markdown 응답
    /// - Throws: `AnalystError` (CLI 없음 / timeout / non-zero exit / stderr 있음)
    public func analyze(prompt: String) async throws -> String {
        guard let path = Self.resolvedCliPath(override: cliPath) else {
            throw AnalystError.cliNotFound(searched: Self.candidatePaths)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // Claude Code 2.x: `-p` print mode + stdin 으로 prompt.
        // --output-format text — 가독성. (`stream-json` 은 incremental 지만 SwiftUI binding 복잡.)
        process.arguments = ["-p", "--output-format", "text"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Env: PATH 확장 (claude CLI 가 npm/node 의존 시 PATH 필요).
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        let extraPath = "/usr/local/bin:/opt/homebrew/bin:/Users/bbikiming/.local/bin"
        env["PATH"] = currentPath.isEmpty ? extraPath : "\(currentPath):\(extraPath)"
        process.environment = env

        try process.run()

        // stdin write — promtp 전달 후 EOF.
        if let data = prompt.data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try stdinPipe.fileHandleForWriting.close()

        // Timeout 감시 Task.
        let timeoutTask = Task { [timeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        // wait 완료.
        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        self.lastStderr = stderr

        let exitStatus = process.terminationStatus
        if exitStatus != 0 {
            throw AnalystError.nonZeroExit(status: Int(exitStatus), stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AnalystError.emptyOutput(stderr: stderr)
        }
        return trimmed
    }

    public enum AnalystError: LocalizedError {
        case cliNotFound(searched: [String])
        case nonZeroExit(status: Int, stderr: String)
        case emptyOutput(stderr: String)
        case jsonParseError(raw: String, reason: String)
        case validationFailed(issues: [String])

        public var errorDescription: String? {
            switch self {
            case .cliNotFound(let searched):
                return "claude CLI 를 찾을 수 없습니다. 탐색 위치: \(searched.joined(separator: ", "))"
            case .nonZeroExit(let status, let stderr):
                return "claude CLI 가 exit \(status) 로 종료. stderr: \(stderr.prefix(200))"
            case .emptyOutput(let stderr):
                return "claude CLI 응답이 비었습니다. stderr: \(stderr.prefix(200))"
            case .jsonParseError(_, let reason):
                return "Claude 응답 JSON 파싱 실패: \(reason)"
            case .validationFailed(let issues):
                return "Claude 응답 검증 실패: \(issues.joined(separator: "; "))"
            }
        }
    }

    // MARK: - v1.11.10 (2026-05-19) — Critic JSON response

    /// **Critic 모드**: prompt 전송 → JSON 응답 받기 → ClaudeCriticResponse decode → deterministic validate.
    /// markdown 흔적 (```json ... ```) 자동 제거. 1회 retry 가능.
    ///
    /// - Throws: AnalystError (CLI 없음 / parse 실패 / validation fail)
    public func analyzeAsCritic(prompt: String) async throws -> ClaudeCriticResponse {
        let raw = try await analyze(prompt: prompt)
        let cleaned = Self.stripMarkdownFence(raw)
        let decoder = JSONDecoder()
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalystError.jsonParseError(raw: cleaned, reason: "UTF-8 conversion failed")
        }
        let response: ClaudeCriticResponse
        do {
            response = try decoder.decode(ClaudeCriticResponse.self, from: data)
        } catch {
            throw AnalystError.jsonParseError(raw: cleaned, reason: "\(error)")
        }
        let validation = response.validate()
        if !validation.passed {
            throw AnalystError.validationFailed(issues: validation.issues)
        }
        return response
    }

    /// markdown fence (```json / ```) 제거.
    static func stripMarkdownFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```json") {
            t = String(t.dropFirst("```json".count))
        } else if t.hasPrefix("```") {
            t = String(t.dropFirst(3))
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
