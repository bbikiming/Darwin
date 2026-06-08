import Foundation

/// SSH 채널을 통한 즉시 명령 실행 — macOS native `/usr/bin/ssh` subprocess.
///
/// 전제:
///   - 로봇에 openssh-server 설치 + 시작 (port 22 listen)
///   - SSH key 인증 셋업 완료 (`ssh-copy-id` 한 번 실행)
///     → BatchMode=yes 로 password prompt 없이 즉시 실행 가능
///
/// 응답 속도 ~30-80ms (SMB watcher 의 ~2초 대비 30배 빠름).
/// 타임아웃 watchdog 와 waitUntilExit 스레드 간 안전한 플래그 (codex HIGH fix).
private final class SSHTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

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

    /// SSH 연결 옵션 — 구형 서버(DARwIn-OP OpenSSH 5.9) 호환 + 전용 키.
    public struct SSHOptions: Equatable, Sendable {
        /// 전용 identity 파일 경로(절대경로). nil = ssh 기본 키 탐색.
        public let identityFile: String?
        /// true 면 `+ssh-rsa` (SHA-1 RSA) 알고리즘 명시 허용 — 구형 OpenSSH 5.x 서버 필수.
        /// 최신 서버에는 무해(additive). 최신 macOS ssh 클라이언트는 기본적으로
        /// SHA-1 ssh-rsa 를 끄므로, 구형 서버 RSA 키 인증이 실패한다 → 이 옵션으로 복구.
        public let legacyServerCompat: Bool

        /// **연결 재사용 (ControlMaster) (2026-06-02)**: 켜면 첫 SSH 가 마스터 소켓을 만들고
        /// 이후 명령/텔레메트리가 핸드셰이크 없이 재사용 → 무선 지연·throughput 대폭 개선.
        /// 소켓 경로(`~/.ssh/df-cm-%C`)가 필요하므로 `~/.ssh` 가 보장될 때(=RSA 키 존재)만 켠다.
        public let multiplex: Bool

        /// `-i` 로 준 키만 배타적으로 offer 할지(`IdentitiesOnly=yes`). 기본 true =
        /// 종전 동작(로봇: 지정 RSA 키만 — too-many-auth-failures 차단). **false** 면
        /// 지정 키를 *추가로* offer 하되 ssh 기본 키/agent 키도 시도 — Switch 처럼
        /// `id_rsa_darwin`(비표준 파일명, 자동 offer 안 됨)이 authorized 인데 사용자의
        /// 다른 키도 살려둬야 하는 경우(2026-06-07 실측 회귀 수정).
        public let identitiesOnly: Bool

        public init(identityFile: String? = nil,
                    legacyServerCompat: Bool = true,
                    multiplex: Bool = false,
                    identitiesOnly: Bool = true) {
            self.identityFile = identityFile
            self.legacyServerCompat = legacyServerCompat
            self.multiplex = multiplex
            self.identitiesOnly = identitiesOnly
        }
    }

    /// 기본 옵션 — `~/.ssh/id_rsa_darwin` 이 있으면 그 RSA 키를 사용(구형 로봇 전용),
    /// 없으면 ssh 기본 키 탐색. 구형 서버 호환은 항상 켬(최신 서버에 무해).
    /// ControlMaster 멀티플렉싱은 RSA 키(=`~/.ssh` 디렉터리 존재) 가 있을 때만 켠다 —
    /// 소켓 경로 디렉터리 부재로 인한 연결 실패를 회피.
    public static func defaultOptions() -> SSHOptions {
        let rsaPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".ssh/id_rsa_darwin")
        let identity = FileManager.default.fileExists(atPath: rsaPath) ? rsaPath : nil
        return SSHOptions(identityFile: identity,
                          legacyServerCompat: true,
                          multiplex: identity != nil)
    }

    /// `/usr/bin/ssh` subprocess 인자 배열 — 순수 함수(테스트 가능).
    /// host@user 와 command 는 항상 마지막 2개 요소(순서 보장).
    public static func sshArguments(host: String,
                                    user: String,
                                    command: String,
                                    connectTimeoutSeconds: Int,
                                    options: SSHOptions) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
            // ② 죽은 연결 빠른 감지 — WiFi 끊김/stall 시 ~4s(2×2) 내 ssh 가 abort →
            //    30s 행 + 직렬 큐 막힘 방지(정지/제어 빠른 복구). 정상 짧은 명령엔 무영향.
            "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=2",
        ]
        // ① ControlMaster 연결 재사용 — 명령/텔레메트리마다 새 핸드셰이크 제거(무선 RTT 지연
        //    수배 감소, throughput↑). 소켓은 %C(연결 파라미터 해시)로 호스트별 격리, 30s 유지.
        if options.multiplex {
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/df-cm-%C",
                "-o", "ControlPersist=30",
            ]
        }
        if options.legacyServerCompat {
            // 구형 OpenSSH 5.x 서버 호환 (`+` = 기존 알고리즘에 추가 → 최신 서버엔 무해).
            //  - PubkeyAcceptedAlgorithms: 클라이언트 *인증* 서명에 SHA-1 ssh-rsa 허용.
            //  - HostKeyAlgorithms: 5.9 의 *호스트키* 도 SHA-1 RSA 라 수락 알고리즘에 추가 필요.
            //    (둘은 별개 축 — 하나만으론 5.9 와 핸드셰이크 불가. 정리하지 말 것.)
            args += ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
                     "-o", "HostKeyAlgorithms=+ssh-rsa"]
        }
        if let identity = options.identityFile {
            // 지정 키를 offer. identitiesOnly=true 면 그 키만 배타적으로(로봇: too-many-
            // auth-failures 차단). false 면 ssh 기본/agent 키도 함께 시도(Switch fallback).
            args += ["-i", identity]
            if options.identitiesOnly {
                args += ["-o", "IdentitiesOnly=yes"]
            }
        }
        args += ["\(user)@\(host)", command]
        return args
    }

    /// `/usr/bin/scp` subprocess 인자 배열 — 순수 함수(테스트 가능).
    /// source(로컬) 와 destination(`user@host:remote`) 은 항상 마지막 2개 요소(순서 보장).
    ///
    /// SSH 와 동일 연결 옵션(BatchMode/accept-new/legacy/identity)을 공유하되,
    /// ControlMaster 멀티플렉싱은 쓰지 않는다(scp 단발 전송 — 소켓 재사용 이득 없음).
    public static func scpArguments(localPath: String,
                                    remotePath: String,
                                    host: String,
                                    user: String,
                                    connectTimeoutSeconds: Int,
                                    options: SSHOptions) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
        ]
        if options.legacyServerCompat {
            args += ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
                     "-o", "HostKeyAlgorithms=+ssh-rsa"]
        }
        if let identity = options.identityFile {
            args += ["-i", identity]
            if options.identitiesOnly {
                args += ["-o", "IdentitiesOnly=yes"]
            }
        }
        args += [localPath, "\(user)@\(host):\(remotePath)"]
        return args
    }

    /// `scp` 로 로컬 파일을 원격으로 복사 — key 인증 가정 (BatchMode=yes).
    /// timeout watchdog 는 `run` 과 동일 패턴.
    public static func copyFile(localPath: String,
                                remotePath: String,
                                host: String,
                                user: String = "robotis",
                                timeoutSeconds: TimeInterval = 60,
                                options: SSHOptions = SSHShell.defaultOptions()) async throws -> Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                let task = Process()
                task.launchPath = "/usr/bin/scp"
                task.arguments = scpArguments(
                    localPath: localPath, remotePath: remotePath,
                    host: host, user: user,
                    connectTimeoutSeconds: Int(min(timeoutSeconds, 10)),
                    options: options
                )
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
                let timedOut = SSHTimeoutFlag()
                let timer = DispatchWorkItem {
                    if task.isRunning { timedOut.set(); task.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds,
                                                  execute: timer)
                task.waitUntilExit()
                timer.cancel()
                if timedOut.get() {
                    cont.resume(throwing: SSHError.timeout)
                    return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
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
    ///
    /// - Parameter stdin: 원격 명령의 표준입력으로 흘려보낼 문자열(옵션). `sudo -S` 가
    ///   비밀번호를 읽는 용도 — **명령행에 비번을 넣지 않기 위한** 안전 경로. 호출자가
    ///   비번을 detail/로그에 남기지 않을 책임을 진다(이 함수는 stdin 데이터를 보관하지 않음).
    public static func run(command: String,
                           host: String,
                           user: String = "robotis",
                           timeoutSeconds: TimeInterval = 30,
                           options: SSHOptions = SSHShell.defaultOptions(),
                           stdin: String? = nil) async throws -> Result {
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
                // 2026-06-01: 구형 로봇(OpenSSH 5.9) 호환 옵션 + 전용 RSA 키는
                //       sshArguments() 가 options 로부터 구성(테스트 가능한 순수 함수).
                task.arguments = sshArguments(
                    host: host, user: user, command: command,
                    connectTimeoutSeconds: Int(min(timeoutSeconds, 10)),
                    options: options
                )
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                // sudo -S 비번 등 원격 stdin 주입 — TTY 없는 ssh 도 원격 명령 stdin 으로 전달.
                let inPipe: Pipe? = (stdin != nil) ? Pipe() : nil
                if let inPipe { task.standardInput = inPipe }
                do {
                    try task.run()
                } catch {
                    cont.resume(throwing: SSHError.spawnFailed(error.localizedDescription))
                    return
                }
                if let inPipe, let data = stdin?.data(using: .utf8) {
                    // 비번을 한 줄로 써 보내고 EOF — sudo -S 가 첫 줄을 읽는다. 데이터는 보관 안 함.
                    inPipe.fileHandleForWriting.write(data)
                    try? inPipe.fileHandleForWriting.close()
                }
                // Timeout watchdog. **codex HIGH fix (2026-06-02)**: 종전엔 terminate 만 하고
                // 비정상 종료 Result 를 그대로 반환 → caller(RemoteShell.send)가 성공으로 오인,
                // 실패 집계/폴백 미작동. timedOut 플래그를 세워 SSHError.timeout 으로 throw 한다
                // (RemoteShell catch 가 exchange.error 설정 → bridge 가 연속실패로 집계).
                let timedOut = SSHTimeoutFlag()
                let timer = DispatchWorkItem {
                    if task.isRunning { timedOut.set(); task.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds,
                                                  execute: timer)
                task.waitUntilExit()
                timer.cancel()
                if timedOut.get() {
                    cont.resume(throwing: SSHError.timeout)
                    return
                }

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
    ///   1. ~/.ssh/id_rsa_darwin 가 없으면 RSA 키 생성 (passphrase 없이)
    ///   2. ssh-copy-id 로 public key 를 로봇에 등록 (password 한 번 입력)
    ///   3. 검증
    ///
    /// **RSA 인 이유**: DARwIn-OP 의 OpenSSH 5.9 는 ed25519 키를 지원하지 않는다
    /// (ed25519 는 OpenSSH 6.5+). 그리고 `+ssh-rsa` 알고리즘을 명시 허용해야
    /// 최신 macOS ssh 클라이언트가 SHA-1 RSA 서명으로 구형 서버와 인증한다.
    public static func keyAuthSetupCommand(host: String = DFConnectionConstants.robotEthernetIP,
                                           user: String = "robotis") -> String {
        let compat = "-o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa"
        return """
        # ── DarwinForge SSH 무인증 셋업 (Mac 터미널에서 한 번만 실행) ──
        # 이후 DarwinForge 안에서 SSH 명령이 password 없이 즉시 실행됩니다.
        # (로봇 OpenSSH 5.9 구형 → RSA 키 + ssh-rsa 알고리즘 필요)

        # 0. 로봇 SSH 가 꺼져 있으면 먼저 VNC 에서: sudo service ssh start

        # 1. 전용 RSA 키 생성 (없을 때만, passphrase 없이).
        [ ! -f ~/.ssh/id_rsa_darwin ] && ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa_darwin -C darwin-robot

        # 2. 로봇에 public key 등록 (robotis 비번 한 번 입력 — 기본값은 보통 111111, 변경했다면 그 비번).
        ssh-copy-id \(compat) -i ~/.ssh/id_rsa_darwin.pub \(user)@\(host)

        # 3. 검증 — password 없이 'OK' 가 나오면 성공.
        ssh -i ~/.ssh/id_rsa_darwin -o IdentitiesOnly=yes \(compat) \(user)@\(host) 'echo OK from $(hostname)'
        """
    }
}
