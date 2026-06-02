import Foundation

// MARK: - SSHDiagnostics (2026-06-02)
//
// SSH 제어 명령의 진단 분류 — 순수 함수 모음. 외부 의존성 없음(Foundation 만).
//
// **왜 분리?**
// - `RemoteShell.send` 의 telemetry payload 를 **순수 함수**로 빌드 → XCTest 로 정확
//   검증 가능(실 로봇 없이). send 자체는 thin wiring 만 남김.
// - "조종한 내용"을 (1) category(원문 없이 안전한 의미 신호) (2) preview(민감정보
//   마스킹 + 절삭) 두 층으로 기록 → 진단엔 충분, PII 노출은 최소.
// - 실패 원인을 **안정적인 문자열 코드**로 분류 → 세션 간 dashboards/그루핑 일관성.
//
// 비유: 택배 송장. category=품목 분류("의류"), preview=내용물 요약("티셔츠 2벌,
// 영수증 가림"), error_case=반송 사유 코드("수취인 부재"). 원본 전체(주소·연락처)는
// 적지 않는다.

public enum SSHDiagnostics {

    // MARK: - 실패 원인 코드

    /// SSH 실패 원인 — 안정적인 문자열 코드(dashboards/분석 그루핑용).
    ///
    /// 종전 RemoteShell 은 `key_auth_required` vs `ssh_generic` 2값뿐이라
    /// "왜 끊겼나"(타임아웃? 프로세스 실패? 네트워크?)를 로그만으로 구분 불가했다.
    public enum ErrorCode: String, Sendable, CaseIterable {
        /// watchdog 타임아웃 — WiFi stall / 로봇 무응답. 가장 흔한 무선 장애.
        case timeout
        /// BatchMode + publickey 실패 → `ssh-copy-id` 1회 셋업 필요.
        case keyAuthRequired = "key_auth_required"
        /// `/usr/bin/ssh` 프로세스 실행 자체 실패(드묾 — 바이너리/권한 문제).
        case spawnFailed = "spawn_failed"
        /// 그 외(네트워크 도달 불가, 알 수 없는 에러).
        case generic
    }

    /// `Error` → 안정적 코드. `SSHShell.SSHError` 케이스를 1:1 매핑, 그 외 generic.
    public static func classify(_ error: Error) -> ErrorCode {
        if let e = error as? SSHShell.SSHError {
            switch e {
            case .timeout:          return .timeout
            case .keyAuthRequired:  return .keyAuthRequired
            case .spawnFailed:      return .spawnFailed
            }
        }
        return .generic
    }

    // MARK: - 명령 카테고리

    /// 제어 명령 카테고리 — 원문 없이 "무엇을 조종했나" 안전 신호.
    /// best-effort 키워드 매칭(완벽 분류 아님). 미매칭은 `.other`.
    public enum CommandCategory: String, Sendable, CaseIterable {
        case walk           // df-walklab-cmd 쓰기 / walklab start·stop·verify
        case stop           // estop / emergency
        case telemetry      // df-walklab-telemetry poll
        case demo           // df-pilot-mode / start-demo
        case vision         // camera / ball tracker / vision config
        case bridge         // socat / ttyUSB / LAN 5530 bridge
        case head           // 머리 pan/tilt
        case motion         // 모션 페이지 재생
        case setup          // ssh-keygen / copy-id / chmod / install
        case service        // systemctl / service / pkill
        case query          // 순수 조회(cat/tail/grep/hostname/ls/ps)
        case other
    }

    /// 명령 → 카테고리. 구체적 → 일반 순서로 검사(첫 매칭 반환).
    public static func category(of command: String) -> CommandCategory {
        let c = command.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { c.contains($0) } }

        if has("df-walklab-telemetry")                                  { return .telemetry }
        if has("estop", "e_stop", "emergency", "df-walklab-estop")      { return .stop }
        if has("df-walklab-cmd", "x_move_amplitude", "walklab", "walk") { return .walk }
        if has("df-pilot-mode", "start-demo", "df-demo", "demo")        { return .demo }
        if has("camera", "mjpg", "ball", "vision", "config.ini", "hsv") { return .vision }
        if has("socat", "ttyusb", "stty", "5530")                       { return .bridge }
        if has("ssh-keygen", "ssh-copy-id", "authorized_keys",
               "bashrc", "ssh-rsa", "mkdir", "chmod", "install")        { return .setup }
        if has("systemctl", "service ", "init.d", "pkill", "pgrep")     { return .service }
        if has("pan", "tilt", "head")                                   { return .head }
        if has("motion", "page", ".mtn")                                { return .motion }
        if has("cat ", "tail", "grep", "hostname", "ls ", "ps ",
               "echo", "uptime", "free", "df ")                         { return .query }
        return .other
    }

    // MARK: - 민감정보 마스킹 프리뷰

    /// 로컬 로그용 명령 프리뷰 — 개행/연속공백 1칸 압축 + 민감정보 마스킹 + 절삭.
    ///
    /// "상세 로그"(사용자 목표)를 위해 원문에 가까운 프리뷰를 남기되, 비밀번호·토큰
    /// 류는 `***`로 가린다. send() 경로 명령엔 실측상 비밀이 거의 없지만(setup 가이드는
    /// UI 표시용이라 send 안 함) 방어적으로 마스킹한다.
    public static func redactedPreview(_ command: String, maxLen: Int = 160) -> String {
        // 1) 개행 + 연속 공백 → 단일 공백.
        let collapsed = command
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // 2) 민감 패턴 마스킹(대소문자 무시). 값 부분만 `***`로.
        var s = collapsed
        let secretPatterns = [
            // password=foo / passwd:foo / pwd foo
            #"(?i)(pass(word|wd)?\s*[:=]\s*)\S+"#,
            // sshpass -p SECRET  /  ssh ... -p SECRET (password)
            #"(?i)(sshpass\s+-p\s*)\S+"#,
            // Authorization / token / bearer 헤더성 값
            #"(?i)(token|bearer|secret|api[_-]?key)\s*[:=]\s*\S+"#,
        ]
        for pat in secretPatterns {
            if let re = try? NSRegularExpression(pattern: pat) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1***")
            }
        }

        // 3) 절삭.
        if s.count > maxLen {
            let end = s.index(s.startIndex, offsetBy: maxLen)
            return String(s[s.startIndex..<end]) + "…"
        }
        return s
    }

    // MARK: - Payload 빌더 (RemoteShell 가 호출 — 순수, 테스트 가능)

    /// `remote.command_sent` payload. 명령 송신 직전.
    public static func sentData(command: String,
                                channel: String) -> [String: AnyCodable] {
        [
            "channel": AnyCodable(channel),
            "cmd_len": AnyCodable(command.count),
            "cmd_hash": AnyCodable(Harness.shortHash(command)),
            "category": AnyCodable(category(of: command).rawValue),
            "preview": AnyCodable(redactedPreview(command)),
        ]
    }

    /// `remote.command_responded` payload. SSH 응답 수신(성공 경로).
    /// **핵심 추가**: `exit_code` + `ok` — 종전엔 비-0 exit(로봇이 명령 거부)도
    /// "responded"로만 기록돼 성공으로 오인됐다. 이제 로봇 수락 여부가 로그에 남는다.
    public static func respondedData(command: String,
                                     channel: String,
                                     exitCode: Int32,
                                     elapsedMs: Int,
                                     resultLen: Int) -> [String: AnyCodable] {
        [
            "channel": AnyCodable(channel),
            "elapsed_ms": AnyCodable(elapsedMs),
            "result_len": AnyCodable(resultLen),
            "cmd_hash": AnyCodable(Harness.shortHash(command)),
            "category": AnyCodable(category(of: command).rawValue),
            "exit_code": AnyCodable(Int(exitCode)),
            "ok": AnyCodable(exitCode == 0),
        ]
    }

    /// `remote.command_error` payload. SSH 실행 실패 경로.
    /// **핵심 추가**: `elapsed_ms`(종전 누락 — 실패까지 걸린 시간은 timeout 진단의 핵심) +
    /// 4-way `error_case` + `multiplex`(ControlMaster 재사용 여부).
    public static func errorData(command: String,
                                 channel: String,
                                 error: Error,
                                 elapsedMs: Int,
                                 multiplex: Bool) -> [String: AnyCodable] {
        [
            "channel": AnyCodable(channel),
            "error_case": AnyCodable(classify(error).rawValue),
            "category": AnyCodable(category(of: command).rawValue),
            "elapsed_ms": AnyCodable(elapsedMs),
            "multiplex": AnyCodable(multiplex),
            "cmd_hash": AnyCodable(Harness.shortHash(command)),
        ]
    }
}
