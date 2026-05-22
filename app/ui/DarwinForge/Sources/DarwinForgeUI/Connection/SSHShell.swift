import Foundation

/// SSH 채널을 통한 즉시 명령 실행 — macOS native `/usr/bin/ssh` subprocess.
///
/// 전제:
///   - 로봇에 openssh-server 설치 + 시작 (port 22 listen)
///   - SSH key 인증 셋업 완료 (`ssh-copy-id` 한 번 실행)
///     → BatchMode=yes 로 password prompt 없이 즉시 실행 가능
///
/// 응답 속도 ~30-80ms (SMB watcher 의 ~2초 대비 30배 빠름).
public enum SSHShell {

    public struct Result {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let elapsedMs: Int

        public var combined: String {
            var s = stdout
            if !stderr.isEmpty {
                if !s.isEmpty { s += "\n" }
                s += "--- stderr ---\n\(stderr)"
            }
            s += "\n--- exit \(exitCode) ---"
            return s
        }

        public var ok: Bool { exitCode == 0 }
    }

    public enum SSHError: Error {
        case spawnFailed(String)
        case timeout
        case keyAuthRequired
    }

    /// SSH 가능 여부 — port 22 reachable + BatchMode 로 즉시 응답.
    /// `true` 면 SSHShell.run 사용 가능. `false` 면 SMB fallback 권장.
    public static func isReachable(host: String, user: String = "robotis",
                                   timeout: TimeInterval = 2.0) async -> Bool {
        let result = try? await run(
            command: "echo ok",
            host: host, user: user,
            timeoutSeconds: timeout
        )
        return result?.ok == true
    }

    /// SSH 로 명령 실행 — key 인증 가정 (BatchMode=yes).
    /// password 가 필요하면 즉시 실패 → SSHError.keyAuthRequired.
    public static func run(command: String,
                           host: String,
                           user: String = "robotis",
                           timeoutSeconds: TimeInterval = 30) async throws -> Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                let task = Process()
                task.launchPath = "/usr/bin/ssh"
                // 2026-05-17 security audit HIGH fix (CVSS ~7.4): MITM 차단.
                // 종전: `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null` →
                //       LAN 공격자가 robot 으로 위장해도 사용자가 인지 못 함.
                // 신규: `accept-new` → 첫 연결 시 자동 등록, 이후 host key 변경 시 거부 (TOFU).
                //       known_hosts 는 사용자 홈 디렉터리 default 사용 → 영속 검증.
                task.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "LogLevel=ERROR",
                    "-o", "ConnectTimeout=\(Int(min(timeoutSeconds, 10)))",
                    "\(user)@\(host)",
                    command
                ]
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                do {
                    try task.run()
                } catch {
                    cont.resume(throwing: SSHError.spawnFailed(error.localizedDescription))
                    return
                }
                // Timeout watchdog.
                let timer = DispatchWorkItem {
                    if task.isRunning { task.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds,
                                                  execute: timer)
                task.waitUntilExit()
                timer.cancel()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)

                // BatchMode 에서 password prompt 가 필요하면 exit 255 + "Permission denied".
                if task.terminationStatus == 255 &&
                   (stderr.contains("Permission denied") || stderr.contains("publickey")) {
                    cont.resume(throwing: SSHError.keyAuthRequired)
                    return
                }
                cont.resume(returning: Result(
                    stdout: stdout, stderr: stderr,
                    exitCode: task.terminationStatus,
                    elapsedMs: elapsed
                ))
            }
        }
    }

    // MARK: - 셋업 명령 (사용자가 한 번만 Mac 터미널에서 실행)

    /// SSH key 인증 셋업 가이드 — 사용자가 Mac 터미널에서 한 번 실행하면 그 이후 password 없음.
    ///
    /// 흐름:
    ///   1. ~/.ssh/id_ed25519 가 없으면 생성 (passphrase 없이)
    ///   2. ssh-copy-id 로 public key 를 로봇에 등록 (password 한 번 입력)
    public static func keyAuthSetupCommand(host: String = DFConnectionConstants.robotEthernetIP,
                                           user: String = "robotis") -> String {
        return """
        # ── DarwinForge SSH 무인증 셋업 (Mac 터미널에서 한 번만 실행) ──
        # 이후 DarwinForge 안에서 SSH 명령이 password 없이 즉시 실행됩니다.

        # 1. SSH key 가 없으면 생성 (passphrase 없이).
        [ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

        # 2. 로봇에 public key 등록 (이 단계에서 robotis 비번 한 번 입력 — 보통 '111111').
        ssh-copy-id \(user)@\(host)

        # 3. 검증 — password 없이 들어가지면 성공.
        ssh \(user)@\(host) 'echo OK from $(hostname)'
        """
    }
}
