import Foundation
import SwiftUI

/// SSH 기반 원격 명령 채널.
///
/// 흐름:
///   1. 사용자가 명령 입력 → `send(_:)` 호출
///   2. SSH key 인증으로 로봇에 접속 (`SSHShell.run`)
///   3. 명령 즉시 실행 → stdout/stderr 결합 결과 반환 (30-80ms)
///
/// 연결 불가 케이스:
///   - SSH key 미인증 → `ssh-copy-id` 1회 안내 후 명확한 에러 표시
///   - 로봇 미연결(전원/LAN) → 연결 실패 에러 반환
///
/// 종전 SMB 인박스/아웃박스 폴백은 2026-06-01 제거됨: 공유명/권한 불일치로 사실상
/// 미작동이었고, 텔레메트리 poller(5Hz)가 존재하지 않는 공유 마운트를 반복 시도해
/// Finder 다이얼로그 스팸을 유발했다. 이제 SSH 만 사용한다.
@MainActor
public final class RemoteShell: ObservableObject {

    public enum ShellError: LocalizedError {
        case shellNotConfigured

        public var errorDescription: String? {
            switch self {
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
        /// 원격 exit code — UX 리디자인(2026-06-13): 비-0 exit 를 성공으로 칠하던
        /// 콘솔 표시 결함의 데이터 기반. SSHShell.run 이 이미 반환하던 값을 저장만 추가
        /// (additive — 기존 소비처의 error==nil 의존 불변).
        public var exitCode: Int32?

        public var elapsedMs: Int? {
            guard let r = receivedAt else { return nil }
            return Int(r.timeIntervalSince(sentAt) * 1000)
        }
    }

    /// 히스토리 상한 — 장시간 세션 무한 증식 방지(oldest-drop 링버퍼).
    public static let historyLimit = 200

    /// 사용 중인 채널 표시 — UI 에서 사용자에게 노출.
    public enum Channel: Equatable {
        case unknown        // probe 전 / 진행 중
        case ssh            // SSH 연결됨 — 즉시 (30-80ms)
        case unavailable    // SSH 도달 불가 (전원/LAN/key 미인증)
    }

    @Published public private(set) var history: [Exchange] = []
    @Published public private(set) var isSending: Bool = false
    @Published public private(set) var activeChannel: Channel = .unknown
    @Published public var host: String = DFConnectionConstants.robotEthernetIP
    @Published public var username: String = "robotis"

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    private let harness: any HarnessFacade

    public init(harness: (any HarnessFacade)? = nil) {
        self.harness = harness ?? LiveHarness.shared
        // 진입 즉시 SSH 가능 여부 probe — 백그라운드.
        Task { await probeChannel() }
    }

    /// 채널 자동 선택 — SSH key 인증 가능하면 `.ssh`, 아니면 `.unavailable`.
    public func probeChannel() async {
        let ok = await SSHShell.isReachable(host: host, user: username, timeout: 2.5)
        let from = activeChannel
        let to: Channel = ok ? .ssh : .unavailable
        activeChannel = to
        // 사이클 182 (P1 #3.6 fix): probe 결과 telemetry. 사용자 환경 별 channel
        // 분포 분석 (key 미셋업 vs 정상 비율 등). host 는 redaction — 마지막 옥텟 mask.
        harness.record(
            .remoteChannelChanged, level: .info, actor: .system,
            data: ["from": AnyCodable(String(describing: from)),
                   "to": AnyCodable(String(describing: to)),
                   "host_hash": AnyCodable(Harness.shortHash(host))]
        )
    }

    /// 명령 전송 → 결과 반환. SSH key 인증으로 즉시 실행 (30-80ms).
    /// **v1.11.16 (2026-05-19) — onboard 통합 fix**: `Exchange?` 반환 — caller 가
    /// 결과/에러 확인 가능. 종전 `async` 반환만 → 호출자가 history 폴링 필요해 silent
    /// failure 위험. nil = 빈 명령 (no-op).
    /// - Parameter timeoutSeconds: SSH 명령 타임아웃. 기본 30s(셋업/기동 명령용). 스트리밍
    ///   조종 명령(머리/스틱/정지)은 짧게(예: 6s) 주어, WiFi stall 시 직렬 큐가 오래 막히지
    ///   않고 다음 명령/정지로 빠르게 넘어가게 한다. (ServerAlive 와 함께 빠른 복구.)
    @discardableResult
    public func send(_ command: String, timeoutSeconds: TimeInterval = 30) async -> Exchange? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var exchange = Exchange(command: trimmed, sentAt: Date())
        history.append(exchange)
        // 링버퍼 절단 — 결과 갱신은 아래 id 매칭이라 인덱스 이동에 안전.
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        isSending = true
        defer { isSending = false }

        // 명령 송신 telemetry. **2026-06-02 — SSHDiagnostics 빌더로 강화**: 종전
        // len+hash 만 → category(무엇을 조종했나) + 마스킹 preview(상세 내용) 추가.
        // payload 구성은 순수 함수라 단위 테스트로 검증(SSHDiagnosticsTests).
        let channelAtSend = String(describing: activeChannel)
        harness.record(
            .remoteCommandSent, level: .info, actor: .user,
            data: SSHDiagnostics.sentData(command: trimmed, channel: channelAtSend)
        )

        // SSH 전용 (2026-06-01) — SMB 폴백 제거됨(파일 헤더 참고).
        // 실패 시 마운트 시도 없이 명확한 에러를 반환한다.
        do {
            let r = try await SSHShell.run(command: trimmed,
                                            host: host, user: username,
                                            timeoutSeconds: timeoutSeconds)
            exchange.result = r.combined
            exchange.receivedAt = Date()
            exchange.exitCode = r.exitCode
            // id 매칭 갱신 — 종전 위치 인덱스는 링버퍼 절단/동시 send 에서 어긋날 수 있다.
            if let i = history.firstIndex(where: { $0.id == exchange.id }) { history[i] = exchange }
            activeChannel = .ssh
            // **2026-06-02 핵심 추가**: exit_code + ok. 종전엔 비-0 exit(로봇이 명령
            // 거부)도 "responded"로만 기록돼 성공으로 오인됐다. 이제 로봇 수락 여부 기록.
            harness.record(
                .remoteCommandResponded, level: r.ok ? .info : .warn, actor: .system,
                data: SSHDiagnostics.respondedData(
                    command: trimmed, channel: "ssh",
                    exitCode: r.exitCode,
                    elapsedMs: exchange.elapsedMs ?? 0,
                    resultLen: r.combined.count)
            )
            return exchange
        } catch {
            let isAuth: Bool = {
                if case SSHShell.SSHError.keyAuthRequired = error { return true }
                return false
            }()
            exchange.error = isAuth
                ? "SSH 키 인증 실패 — Mac 터미널에서 `ssh-copy-id -i ~/.ssh/id_rsa_darwin.pub robotis@\(host)` 1회 실행"
                : "로봇에 닿지 못했어요 — 로봇 전원과 유선 LAN 을 확인한 뒤 '채널 재탐색'을 눌러 주세요. (\(error.localizedDescription))"
            exchange.receivedAt = Date()
            if let i = history.firstIndex(where: { $0.id == exchange.id }) { history[i] = exchange }
            // **2026-06-02 강화**: elapsed_ms(종전 누락 — 실패까지 걸린 시간은 timeout
            // 진단의 핵심) + 4-way error_case(timeout/key_auth_required/spawn_failed/
            // generic) + multiplex(ControlMaster 재사용 여부). isAuth 는 위 사용자 메시지용.
            harness.record(
                .remoteCommandError, level: .warn, actor: .system,
                data: SSHDiagnostics.errorData(
                    command: trimmed, channel: "ssh",
                    error: error,
                    elapsedMs: exchange.elapsedMs ?? 0,
                    multiplex: SSHShell.defaultOptions().multiplex)
            )
            return exchange
        }
    }

    public func clear() { history.removeAll() }
}
