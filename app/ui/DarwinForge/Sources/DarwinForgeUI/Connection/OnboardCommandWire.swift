import Foundation

/// 온보드 명령 채널의 **순수 와이어 포맷·큐 로직** (cockpit-latency-hardening Wave 1 / onboard O1).
///
/// 소켓/SSH 같은 부수효과 없이 직렬화·파싱·코얼레싱만 담는다 — 전부 호스트 단위 테스트
/// 가능. 실제 전송은 `OnboardCommandChannel`(actor)이 이 타입들을 써서 수행한다.

// MARK: - 명령 정책

/// 명령 전송 정책 (cockpit-latency-hardening §4 Wave 1, §7 불변식).
public enum SendPolicy: Equatable, Sendable {
    /// 같은 `key` 의 **미송신** 명령을 최신으로 대체(coalesce). freeform tuning 류.
    case latestWins(key: String)
    /// 코얼레싱 금지·순서 보존. **estop·모드전환 전용**(§7: estop 은 항상 `.ordered`).
    case ordered

    /// 코얼레싱 키 — `.ordered` 는 nil(절대 합쳐지지 않음).
    public var coalesceKey: String? {
        if case let .latestWins(key) = self { return key }
        return nil
    }
}

/// 채널에 넣는 한 건의 명령. `line` 은 14-토큰 직렬화 라인(`WalkingEngineCommand.serializedLine`
/// 앞에 cmd_id prepend 형태) 또는 임의 셸 명령(모드 전환). `cmdId` 는 ACK 상관용.
public struct OnboardCommand: Equatable, Sendable {
    public let line: String
    public let cmdId: String
    public let policy: SendPolicy
    /// 입력 이벤트 correlation seq — `PilotLatencyTracer.mark` 에 echo(0 = 미상관).
    public let traceSeq: UInt32

    public init(line: String, cmdId: String, policy: SendPolicy, traceSeq: UInt32 = 0) {
        self.line = line
        self.cmdId = cmdId
        self.policy = policy
        self.traceSeq = traceSeq
    }
}

/// 명령 처리 결과(ACK). 로봇이 적용 시각·exit code 를 회신.
public struct OnboardAck: Equatable, Sendable {
    public let cmdId: String
    public let robotTsMs: Int64?
    public let exitCode: Int32
    public init(cmdId: String, robotTsMs: Int64?, exitCode: Int32) {
        self.cmdId = cmdId
        self.robotTsMs = robotTsMs
        self.exitCode = exitCode
    }
    public var ok: Bool { exitCode == 0 }
}

// MARK: - E-STOP 데이터그램 (S5 / O1)

/// 긴급정지 UDP 페이로드 `DF-ESTOP v1 {token} {unixMillis}` (양끝 계약 — 로봇 리스너와 일치).
public enum OnboardEstopDatagram {
    public static let prefix = "DF-ESTOP v1"
    /// ×3 연발 발사 오프셋(ms) — 첫 패킷 유실에도 한 번은 닿도록(§5.4).
    public static let burstOffsetsMs: [Int] = [0, 50, 100]

    public static func payload(token: String, unixMillis: Int64) -> String {
        "\(prefix) \(token) \(unixMillis)"
    }

    public static func data(token: String, unixMillis: Int64) -> Data {
        Data(payload(token: token, unixMillis: unixMillis).utf8)
    }

    /// 로봇 측 검증 미러(테스트·문서용): prefix 일치 + 토큰 일치 시 true.
    public static func validate(_ payload: String, expectedToken: String) -> Bool {
        let t = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(prefix) else { return false }
        let rest = t.dropFirst(prefix.count).split(separator: " ", omittingEmptySubsequences: true)
        guard let token = rest.first else { return false }
        return String(token) == expectedToken
    }
}

// MARK: - 명령 데이터그램 (O1 latest-wins)

/// 조종 명령 UDP 페이로드 `DFCMD {token} {seq} {line}` (로봇 리스너가 seq 단조 검사).
public enum OnboardCommandDatagram {
    public static let prefix = "DFCMD"

    public static func payload(token: String, seq: UInt64, line: String) -> String {
        "\(prefix) \(token) \(seq) \(line)"
    }

    public static func data(token: String, seq: UInt64, line: String) -> Data {
        Data(payload(token: token, seq: seq, line: line).utf8)
    }
}

// MARK: - Persistent SSH sentinel

/// 상주 SSH 채널의 stdout 완료 sentinel `__DF_DONE_{id}_{exit}__` (cockpit-latency-hardening §5.4).
///
/// 비유: 주방(로봇 셸)에 주문지를 계속 밀어넣고, 각 요리가 끝나면 "{번호}번 {결과} 나왔습니다"
/// 라고 외치게 한다. Mac 은 그 외침(sentinel)으로 어느 명령이 끝났는지·성공했는지 구분한다.
public enum OnboardChannelSentinel {
    public static let marker = "__DF_DONE_"

    /// id·exit 로 sentinel 라인 생성(테스트·로봇 셸 양쪽이 같은 식 사용).
    public static func line(id: UInt64, exit: Int32) -> String {
        "\(marker)\(id)_\(exit)__"
    }

    /// stdout 한 줄을 파싱 → sentinel 이면 (id, exit). 아니면 nil.
    public static func parse(_ raw: String) -> (id: UInt64, exit: Int32)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(marker), line.hasSuffix("__") else { return nil }
        let inner = line.dropFirst(marker.count).dropLast(2)   // "{id}_{exit}"
        guard let sep = inner.lastIndex(of: "_") else { return nil }
        let idPart = inner[inner.startIndex..<sep]
        let exitPart = inner[inner.index(after: sep)...]
        guard let id = UInt64(idPart), let exit = Int32(exitPart) else { return nil }
        return (id, exit)
    }

    /// 명령을 감싸 실행 후 sentinel 을 emit 하는 셸 라인(상주 셸 stdin 으로 write).
    /// `command` 종료 코드를 `$?` 로 캡처해 sentinel 에 싣는다.
    public static func wrap(command: String, id: UInt64) -> String {
        "\(command); printf '\(marker)%s_%s__\\n' \(id) \"$?\""
    }
}

// MARK: - 코얼레싱 큐 (순수 — 단위 테스트 대상)

/// `.latestWins(key:)`/`.ordered` 정책을 집행하는 FIFO 큐.
///
/// 불변식: 같은 coalesceKey 의 미송신 명령은 1건만 — 새 명령이 옛 것을 *대체*(latest wins).
/// `.ordered` 는 절대 합쳐지지 않고 순서 보존. estop/모드전환의 순서 보장이 여기서 나온다.
public struct CoalescingQueue: Sendable {
    private var entries: [OnboardCommand] = []

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    /// 테스트·디버그용 스냅샷.
    public var pending: [OnboardCommand] { entries }

    /// 명령 enqueue. `.latestWins` 면 같은 key 의 기존 미송신 명령을 제거하고 말미에 추가
    /// (최신이 이김, 다른 key 와의 상대 순서는 보존). `.ordered` 면 그대로 추가.
    public mutating func enqueue(_ command: OnboardCommand) {
        if let key = command.policy.coalesceKey {
            entries.removeAll { $0.policy.coalesceKey == key }
        }
        entries.append(command)
    }

    /// 큐 head 1건 제거·반환.
    public mutating func dequeue() -> OnboardCommand? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    public mutating func clear() { entries.removeAll() }
}
