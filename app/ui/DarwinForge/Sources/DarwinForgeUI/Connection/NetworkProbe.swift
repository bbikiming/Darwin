import Foundation
import Network

/// `@Sendable` 캡처 호환을 위한 단순 박스.
private final class ResumedBox: @unchecked Sendable {
    var value: Bool = false
}

/// 단일 host:port 가 listen 중인지 짧은 timeout 내 확인.
///
/// 실제 데이터를 보내지 않고 NWConnection.handshake (TCP SYN→SYN-ACK→ACK) 만으로 판단.
/// 호스트 unreachable / 포트 closed 모두 .failed 로 떨어진다.
public enum NetworkProbe {
    public enum Result: Equatable {
        case open(rttMs: Int)
        case refused
        case unreachable
        case timedOut
    }

    /// ICMP ping 결과. 호스트 reachability를 포트 reachability와 별도로 진단.
    ///
    /// "ping OK + port refused" → 호스트는 살아있고 socat 만 안 떠 있음 (가장 흔한 케이스).
    /// "ping fail"             → 케이블/서브넷/방화벽 문제. 다른 액션 필요.
    public enum PingResult: Equatable {
        case ok(rttMs: Double)
        case unreachable
        case timedOut
    }

    /// `/sbin/ping`을 단발 (1 packet) 로 실행하고 결과 파싱. macOS 표준 binary 사용 — 별도 권한 불필요.
    public static func pingProbe(host: String, timeout: TimeInterval = 1.2) async -> PingResult {
        await withCheckedContinuation { (cont: CheckedContinuation<PingResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/sbin/ping"
                // -c 1: 1 packet · -W <ms>: per-packet timeout (macOS) · -t <s>: deadline
                let waitMs = max(100, Int(timeout * 1000))
                let waitSec = max(1, Int(timeout.rounded(.up)) + 1)
                task.arguments = ["-c", "1", "-W", "\(waitMs)", "-t", "\(waitSec)", host]
                let outPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = Pipe()
                do { try task.run() } catch {
                    cont.resume(returning: .unreachable)
                    return
                }
                task.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if let rtt = parseRTT(from: text) {
                    cont.resume(returning: .ok(rttMs: rtt))
                } else if task.terminationStatus == 0 {
                    cont.resume(returning: .ok(rttMs: -1))
                } else if text.lowercased().contains("no route to host") ||
                          text.lowercased().contains("host is down") {
                    cont.resume(returning: .unreachable)
                } else {
                    cont.resume(returning: .timedOut)
                }
            }
        }
    }

    /// "time=0.547 ms" 패턴에서 ms 값 추출.
    private static func parseRTT(from text: String) -> Double? {
        guard let r = text.range(of: #"time=([0-9.]+)"#, options: .regularExpression) else { return nil }
        let snippet = String(text[r])
        let val = snippet.replacingOccurrences(of: "time=", with: "")
        return Double(val)
    }

    /// `host:port` 에 대한 TCP probe. 실패해도 throw 하지 않고 Result로 반환.
    public static func tcpProbe(host: String, port: UInt16, timeout: TimeInterval = 1.0) async -> Result {
        guard let port = NWEndpoint.Port(rawValue: port) else { return .unreachable }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = []
        let conn = NWConnection(to: endpoint, using: params)
        let started = Date()

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            // 모든 콜백이 같은 큐에서 직렬 실행돼 한 번만 resume 한다.
            let queue = DispatchQueue(label: "df.netprobe", qos: .userInitiated)
            let didResume = NSLock()
            let resumedBox = ResumedBox()
            @Sendable func once(_ r: Result) {
                didResume.lock()
                defer { didResume.unlock() }
                if !resumedBox.value {
                    resumedBox.value = true
                    cont.resume(returning: r)
                    conn.cancel()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let rtt = Int(Date().timeIntervalSince(started) * 1000)
                    once(.open(rttMs: rtt))
                case .failed(let err):
                    if case .posix(let code) = err {
                        switch code {
                        case .ECONNREFUSED: once(.refused)
                        case .EHOSTUNREACH, .ENETUNREACH: once(.unreachable)
                        case .ETIMEDOUT: once(.timedOut)
                        default: once(.unreachable)
                        }
                    } else {
                        once(.unreachable)
                    }
                case .cancelled:
                    once(.timedOut)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once(.timedOut)
            }
            conn.start(queue: queue)
        }
    }

    /// Mac의 모든 활성 IPv4 인터페이스에서 (mac_ip, broadcast_or_subnet_root) 추론.
    /// 192.168.123.105/24 → "192.168.123.1" (전형적 .1 게이트웨이 후보).
    /// 진단 시 가장 가능성 높은 robot IP 후보를 만들기 위함.
    public static func likelyRobotCandidates() -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        for ip in localIPv4Addresses() {
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let octet1 = parts[0]
            let octet2 = parts[1]
            let octet3 = parts[2]
            // 게이트웨이/로봇이 흔히 쓰는 .1
            let dot1 = "\(octet1).\(octet2).\(octet3).1"
            if !seen.contains(dot1), dot1 != ip {
                seen.insert(dot1); candidates.append(dot1)
            }
        }
        // OP2 e-Manual 표준은 항상 후보에 포함.
        if !seen.contains(DFConnectionConstants.robotEthernetIP) {
            candidates.append(DFConnectionConstants.robotEthernetIP)
        }
        return candidates
    }

    /// macOS의 IPv4 주소 — `getifaddrs(3)` 으로 직접 enumerate.
    /// loopback (127.x) 과 link-local (169.254.x) 는 제외.
    public static func localIPv4Addresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let addr = p.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) == IFF_UP,
               (flags & IFF_LOOPBACK) == 0 {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let success = withUnsafePointer(to: p.pointee.ifa_addr.pointee) { addrPtr in
                    getnameinfo(addrPtr,
                                socklen_t(MemoryLayout<sockaddr_in>.size),
                                &hostBuf, socklen_t(hostBuf.count),
                                nil, 0, NI_NUMERICHOST) == 0
                }
                if success {
                    let s = String(cString: hostBuf)
                    if !s.hasPrefix("169.254.") && s != "0.0.0.0" {
                        out.append(s)
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return out
    }

    /// `arp -a` 출력에서 IP/MAC 쌍을 파싱.
    /// ROBOTIS OUI (00:07:32) 가 보이면 강한 단서. SBC 일반 OUI 도 후보로 받음.
    public static func arpScan() -> [(ip: String, mac: String)] {
        let task = Process()
        task.launchPath = "/usr/sbin/arp"
        task.arguments = ["-a", "-n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        var pairs: [(String, String)] = []
        for line in str.components(separatedBy: "\n") {
            // 형식: ? (192.168.123.1) at 0:7:32:40:8c:e8 on en10 ifscope [ethernet]
            guard let lparen = line.firstIndex(of: "("),
                  let rparen = line.firstIndex(of: ")"),
                  lparen < rparen else { continue }
            let ip = String(line[line.index(after: lparen)..<rparen])
            guard let atRange = line.range(of: " at ") else { continue }
            let after = line[atRange.upperBound...]
            guard let space = after.firstIndex(of: " ") else { continue }
            let mac = String(after[after.startIndex..<space])
            if mac == "(incomplete)" { continue }
            pairs.append((ip, mac))
        }
        return pairs
    }
}
