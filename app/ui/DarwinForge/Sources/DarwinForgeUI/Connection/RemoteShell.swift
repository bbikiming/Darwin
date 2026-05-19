import Foundation
import SwiftUI

/// SMB 기반 단방향 원격 명령 채널.
///
/// 흐름:
///   1. 사용자가 명령 입력 → `send(_:)` 호출
///   2. SMB share 자동 마운트 (`/Volumes/<share>`)
///   3. `<mount>/.df_inbox/cmd_<timestamp>.sh` 작성
///   4. 로봇 측 watcher daemon 이 2초 내 감지 → 실행 → `.df_outbox/<name>.out` 작성
///   5. Mac이 outbox 폴링 → 결과 반환
///
/// 폴더 접근 불가 케이스:
///   - Samba [homes] share 비활성 → home 안 보임 → fallback `/tmp/df_inbox` 시도
///   - 사용자 권한 없음 → 명확한 에러 표시 + 셋업 안내
@MainActor
public final class RemoteShell: ObservableObject {

    public enum ShellError: LocalizedError {
        case mountFailed(String)
        case inboxNotFound(String)
        case writeFailed(String)
        case resultTimeout
        case shellNotConfigured

        public var errorDescription: String? {
            switch self {
            case .mountFailed(let m):     return "SMB 마운트 실패: \(m)"
            case .inboxNotFound(let p):   return "Inbox 폴더 없음: \(p) — 로봇에서 셋업 명령 실행 필요"
            case .writeFailed(let m):     return "명령 파일 작성 실패: \(m)"
            case .resultTimeout:          return "결과 응답 대기 timeout (30초) — watcher 미실행 가능성"
            case .shellNotConfigured:     return "원격 셸이 셋업되지 않았어요. 셋업 명령을 먼저 실행하세요."
            }
        }
    }

    /// 한 명령 + 결과 한 쌍.
    public struct Exchange: Identifiable, Equatable {
        public let id: UUID = UUID()
        public let command: String
        public var result: String?
        public var error: String?
        public let sentAt: Date
        public var receivedAt: Date?

        public var elapsedMs: Int? {
            guard let r = receivedAt else { return nil }
            return Int(r.timeIntervalSince(sentAt) * 1000)
        }
    }

    /// 사용 중인 채널 표시 — UI 에서 사용자에게 노출.
    public enum Channel: Equatable {
        case unknown
        case ssh        // 즉시 (30-80ms)
        case smb        // 폴링 (~2초)
    }

    @Published public private(set) var history: [Exchange] = []
    @Published public private(set) var isSending: Bool = false
    @Published public private(set) var lastMountPath: String?
    @Published public private(set) var activeChannel: Channel = .unknown
    @Published public var host: String = "192.168.123.1"
    @Published public var shareName: String = "robotis"
    @Published public var username: String = "robotis"

    public init() {
        // 진입 즉시 SSH 가능 여부 probe — 백그라운드.
        Task { await probeChannel() }
    }

    /// 채널 자동 선택 — SSH key 인증 가능하면 SSH, 아니면 SMB.
    public func probeChannel() async {
        let ok = await SSHShell.isReachable(host: host, user: username, timeout: 2.5)
        activeChannel = ok ? .ssh : .smb
    }

    /// 명령 전송 → 결과 반환. SSH 가능하면 즉시 (30-80ms), 아니면 SMB watcher (2-30초).
    /// **v1.11.16 (2026-05-19) — onboard 통합 fix**: `Exchange?` 반환 — caller 가
    /// 결과/에러 확인 가능. 종전 `async` 반환만 → 호출자가 history 폴링 필요해 silent
    /// failure 위험. nil = 빈 명령 (no-op).
    @discardableResult
    public func send(_ command: String) async -> Exchange? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var exchange = Exchange(command: trimmed, sentAt: Date())
        history.append(exchange)
        let index = history.count - 1
        isSending = true
        defer { isSending = false }

        // 1) SSH 채널 우선 시도 (즉시 응답).
        if activeChannel != .smb {
            do {
                let r = try await SSHShell.run(command: trimmed,
                                                host: host, user: username,
                                                timeoutSeconds: 30)
                exchange.result = r.combined
                exchange.receivedAt = Date()
                if index < history.count { history[index] = exchange }
                activeChannel = .ssh
                return exchange
            } catch SSHShell.SSHError.keyAuthRequired {
                // key 미셋업 — 명확한 안내 + SMB fallback.
                activeChannel = .smb
            } catch {
                // 일반 SSH 실패 — SMB fallback.
                activeChannel = .smb
            }
        }

        // 2) SMB watcher fallback.
        do {
            let mount = try await ensureMounted()
            let inboxURL = try findInbox(under: mount)
            let outboxURL = inboxURL.deletingLastPathComponent()
                .appendingPathComponent(".df_outbox")
            let stem = "cmd_\(Self.timestamp())"
            let cmdFile = inboxURL.appendingPathComponent("\(stem).sh")
            let outFile = outboxURL.appendingPathComponent("\(stem).out")

            // 명령 파일 작성.
            let script = "#!/bin/bash\nset +e\n\(trimmed)\n"
            do {
                try script.write(to: cmdFile, atomically: true, encoding: .utf8)
                // 실행 권한 부여 (SMB는 종종 mode 보존 안 함 — chmod fallback).
                _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: cmdFile.path)
            } catch {
                throw ShellError.writeFailed(error.localizedDescription)
            }

            // outbox 폴링 (최대 30초).
            let started = Date()
            while Date().timeIntervalSince(started) < 30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if FileManager.default.fileExists(atPath: outFile.path) {
                    let body = (try? String(contentsOf: outFile, encoding: .utf8)) ?? "<read failed>"
                    exchange.result = body
                    exchange.receivedAt = Date()
                    if index < history.count { history[index] = exchange }
                    return exchange
                }
            }
            throw ShellError.resultTimeout
        } catch let err as ShellError {
            exchange.error = err.errorDescription
            exchange.receivedAt = Date()
            if index < history.count { history[index] = exchange }
        } catch {
            exchange.error = error.localizedDescription
            exchange.receivedAt = Date()
            if index < history.count { history[index] = exchange }
        }
        return exchange
    }

    public func clear() { history.removeAll() }

    // MARK: - Mount helpers

    /// SMB share 가 마운트돼 있는지 확인 + 필요 시 마운트.
    private func ensureMounted() async throws -> URL {
        // 후보 경로 — macOS 가 자동 부여하는 마운트 위치.
        let candidates = [
            "/Volumes/\(shareName)",
            "/Volumes/\(username)",
            "/Volumes/\(host)",
            "/Volumes/\(shareName)-1"
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                lastMountPath = c
                return URL(fileURLWithPath: c)
            }
        }

        // 마운트 트리거 — Finder 가 비밀번호 입력 요청 (한 번 입력하면 키체인에 저장).
        let url = URL(string: "smb://\(host)/\(shareName)")!
        NSWorkspace.shared.open(url)

        // 최대 25초 대기.
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for c in candidates {
                if FileManager.default.fileExists(atPath: c) {
                    lastMountPath = c
                    return URL(fileURLWithPath: c)
                }
            }
        }
        throw ShellError.mountFailed("\(url.absoluteString) — Finder에서 인증 후 다시 시도")
    }

    /// 마운트된 share 안에서 inbox 폴더 위치 탐색.
    /// 우선순위: ~/.df_inbox (homes share) → /tmp/df_inbox (fallback share).
    private func findInbox(under mount: URL) throws -> URL {
        let candidates = [
            mount.appendingPathComponent(".df_inbox"),
            mount.appendingPathComponent("df_inbox"),
            mount.appendingPathComponent("robotis/.df_inbox"),
            mount.appendingPathComponent("home/robotis/.df_inbox"),
            mount.appendingPathComponent("tmp/df_inbox")
        ]
        for c in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue {
                return c
            }
        }
        // 폴더가 없어도 시도 — share 루트에 새로 작성.
        let fallback = mount.appendingPathComponent(".df_inbox")
        do {
            try FileManager.default.createDirectory(at: fallback,
                                                    withIntermediateDirectories: true)
            return fallback
        } catch {
            throw ShellError.inboxNotFound(fallback.path)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}
