import Foundation
import ForgeCore

// MARK: - ConnectionStore + Harness instrumentation (v1.12.0)
//
// ConnectionStore 의 @MainActor 상태를 텔레메트리 하네스의 context snapshot 으로 변환.
// Harness 가 record() 호출 시 contextProvider 를 통해 자동 첨부.
//
// 자세한 설계: docs/harness/telemetry-harness.md

public extension ConnectionStore {
    /// 현재 connection 상태의 compact snapshot.
    /// Harness 의 context provider 로 등록되어 heartbeat / event 마다 첨부됨.
    func harnessContext(section: String? = nil) -> TelemetryContext {
        let cn: TelemetryContext.ConnectionState
        switch status {
        case .disconnected: cn = .disconnected
        case .connecting: cn = .connecting
        case .connected: cn = .connected
        case .error: cn = .error
        }
        let bv = lastTelemetry?.board?.voltageVolts
        let imuStale = isImuStale
        return TelemetryContext(
            connection: cn,
            endpoint: HarnessRedaction.endpoint(activeEndpoint),
            section: section,
            batteryV: bv,
            rttMs: lastRoundTripMs,
            imuStale: imuStale
        )
    }
}

/// **v1.12.2 (Codex P1-3 fix)** — PII redaction central — hook site 마다 흩어진 raw
/// 사용자 식별 정보 (IPv4/IPv6 마지막 부분, USB serial suffix, hostname, 사용자 텍스트)
/// 를 단일 helper 로 normalize. callsite 는 한 줄로 redact 가능.
public enum HarnessRedaction {

    /// Endpoint (USB / network) → safe display string.
    /// USB: serial suffix 제거 (`/dev/tty.usbserial-A50285BI` → `usb:tty.usb-X`).
    /// IPv4: 마지막 옥텟 마스크. IPv6: 마지막 hextet 마스크. mDNS (.local): 그대로.
    public static func endpoint(_ ep: Endpoint?) -> String? {
        guard let ep else { return nil }
        switch ep {
        case .usbSerial(let path):
            return "usb:\(usbName((path as NSString).lastPathComponent))"
        case .network(let h, let port):
            return "net:\(host(h)):\(port)"
        }
    }

    /// Endpoint kind 만 — 디스플레이 / 통계용. PII 없음.
    public static func endpointKind(_ ep: Endpoint?) -> String {
        guard let ep else { return "none" }
        switch ep {
        case .usbSerial: return "usb"
        case .network: return "network"
        }
    }

    /// "tty.usbserial-A50285BI" → "tty.usb-X" (serial suffix 제거).
    /// "tty.usbmodem14201" → "tty.usbmodem-X". 알 수 없는 패턴은 prefix 만 유지.
    public static func usbName(_ name: String) -> String {
        // "-XXXX" 또는 알파숫자 4+ 의 trailing 부분 제거.
        let s = name
        if let dashIdx = s.lastIndex(of: "-"), s.distance(from: dashIdx, to: s.endIndex) > 2 {
            return String(s[..<dashIdx]) + "-X"
        }
        // 숫자 trailing 만 제거.
        var idx = s.endIndex
        while idx > s.startIndex {
            let prev = s.index(before: idx)
            if s[prev].isNumber { idx = prev } else { break }
        }
        if idx < s.endIndex { return String(s[..<idx]) + "X" }
        return s
    }

    /// 호스트이름 redact.
    /// - "10.0.0.42" → "10.0.0.x"
    /// - "192.168.1.5" → "192.168.1.x"
    /// - "2001:db8::1" → "2001:db8::x" (마지막 hextet 마스크)
    /// - "op2.local", "robot.lab.example.com" — domain 의 leftmost label 유지, 나머지 mask.
    public static func host(_ h: String) -> String {
        // IPv4
        let dot = h.split(separator: ".")
        if dot.count == 4, dot.allSatisfy({ Int($0) != nil }) {
            return "\(dot[0]).\(dot[1]).\(dot[2]).x"
        }
        // IPv6 (포함 ::, hex digits)
        if h.contains(":") {
            // 마지막 ":" 뒤 token 만 마스크.
            if let last = h.lastIndex(of: ":") {
                return String(h[..<h.index(after: last)]) + "x"
            }
            return "ipv6:x"
        }
        // mDNS / hostname — leftmost label 만 유지.
        if dot.count >= 2 {
            return "\(dot[0]).x"
        }
        return h
    }

    /// 사용자 입력 텍스트 → 길이 + 짧은 해시 (FNV-1a).
    /// 본문은 절대 디스크 안 감. 그루핑 / 중복 검출 가능.
    public static func textProbe(_ s: String) -> [String: AnyCodable] {
        [
            "len": AnyCodable(s.count),
            "hash": AnyCodable(Harness.shortHash(s))
        ]
    }

    /// **v1.14.1 (Security P1 fix, 2026-05-21)** — JSON / Markdown export 의 payload
    /// 를 외부로 보내기 직전 redact. allow-list 기반 — 안전 확실한 키만 통과.
    /// 알려지지 않은 키 (사용자 자유 텍스트일 수 있음) 는 길이+해시로 치환.
    ///
    /// **왜 allow-list?** Hook site 마다 보내는 payload key 가 다르고, 미래에 새 hook 이
    /// 추가될 때 raw 텍스트가 들어갈 수 있음. allow-list 면 새 키 추가 시 의식적으로
    /// scrubber 도 갱신해야 외부 노출 가능 → 정책 강제.
    public static func scrubPayload(_ raw: [String: AnyCodable]) -> [String: AnyCodable] {
        // PII 위험 없는 안전 키 — 숫자 / enum / boolean / 해시 등.
        let safeKeys: Set<String> = [
            // 표준 metadata
            "kind", "level", "actor", "reason", "source", "op",
            // 메트릭
            "rtt_ms", "battery_v", "elapsed_ms", "duration_s", "duration_ms",
            "tilt_deg", "fall_score", "advanced",
            // 카운트
            "attempts", "attempt", "consecutive", "consec_failures",
            "total_pages", "remaining_pages", "page_id", "step_count",
            "joint_count", "joints", "snapshots", "total_snapshots",
            "snapshot_id", "remaining", "count_before", "library_size_after",
            "position_failed", "speed_failed", "total_joints", "i",
            "turn", "text_length", "text_len",
            // redacted endpoint (이미 안전)
            "endpoint", "endpoint_kind",
            // imu / preset
            "imu_scale", "imu_source", "preset", "active_preset",
            "requested_preset", "engine", "mode", "profile",
            // bookmark / harness self
            "len", "hash", "name_hash", "name_len", "name_was_default",
            "from_hash", "to_hash", "to_len",
            "page_name_hash", "error_len", "error_hash", "reason_hash",
            "consec_fail", "consec_failures",
            "version", "build", "os", "device",
            "connected", "bus_connected",
            "note", "partial", "joint"
        ]
        var out: [String: AnyCodable] = [:]
        for (k, v) in raw {
            if safeKeys.contains(k) {
                out[k] = v
            } else {
                // 알 수 없는 키 — 값이 String 이면 len+hash, 그 외엔 type marker.
                if let s = v.value as? String {
                    out["\(k)_len"] = AnyCodable(s.count)
                    out["\(k)_hash"] = AnyCodable(Harness.shortHash(s))
                } else {
                    // 숫자 / bool 등은 원본 유지 (PII 아님).
                    out[k] = v
                }
            }
        }
        return out
    }
}
