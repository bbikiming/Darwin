import SwiftUI

/// **활성 연결 경로 분류 (2026-06-02)** — 지금 *실제로 붙어 있는* SSH/LAN 경로가
/// **유선(직결 이더넷)** 인지 **무선(WiFi)** 인지 활성 host IP 로 추론한다.
///
/// # 왜 필요한가
///
/// 사용자가 마법사에서 고른 `ConnectionLink`(선택)와, **실제 활성 host**(현실)는
/// 다를 수 있다. 예: 무선이라 믿었지만 기본값(유선 192.168.123.1)으로 붙어 있던 경우
/// 랜선을 뽑으면 SSH 가 끊겨 모터 명령이 멈춘다. 이 분류기는 "지금 연결이 케이블에
/// 의존하는가"를 화면에 정직하게 노출해 그 혼동을 없앤다.
///
/// # 비유
///
/// 노트북이 "WiFi 로 인터넷 중"인지 "랜선으로 인터넷 중"인지 메뉴바 아이콘이 알려주는 것과
/// 같다. 둘 다 인터넷이 되지만, 랜선을 뽑아도 되는지는 어느 쪽인지에 달렸다.
///
/// # 휴리스틱
///
/// **유효한 IPv4 만** 판정한다: 직결 이더넷 서브넷(`robotEthernetIP` 의 /24, 기본
/// `192.168.123.x`)이면 **유선**, 그 외 유효 IPv4(예: `192.168.0.33` WiFi)면 **무선**.
/// 빈 host·호스트명(op2.local)·비IP 는 **unknown** — 호스트명은 유선 IP 로 resolve 될 수
/// 있어 무선으로 단정하지 않는다(정직성). 필요하면 호출부가 resolve 후 재분류한다.
public enum ConnectionLinkKind: String, Equatable, Sendable {
    /// 직결 이더넷(케이블) — `192.168.123.x`.
    case wired
    /// WiFi — 그 외 IP.
    case wireless
    /// host 미상/빈값.
    case unknown

    /// 직결 이더넷 서브넷의 앞 3옥텟 — `robotEthernetIP`(192.168.123.1)에서 파생, 하드코딩 회피.
    private static var wiredNetworkOctets: [Int] {
        ipv4Octets(DFConnectionConstants.robotEthernetIP).map { Array($0.prefix(3)) } ?? [192, 168, 123]
    }

    /// 엄격 IPv4 파싱 — 정확히 4옥텟, 각 0–255, 빈 옥텟/비숫자 거부. 아니면 nil(호스트명 등).
    /// (codex MEDIUM fix: 종전 raw prefix 매칭은 "192.168.123.foo" 를 유선으로 오분류.)
    private static func ipv4Octets(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isNumber }), let v = Int(p), (0...255).contains(v)
            else { return nil }
            out.append(v)
        }
        return out
    }

    /// 활성 host 로 경로 분류. (시스템 경계 — 외부 host 문자열을 검증 없이 신뢰하지 않는다.)
    ///
    /// **codex HIGH fix (2026-06-02)**: 호스트명(op2.local 등)·비IP·빈값은 **무선으로 단정하지
    /// 않고 `.unknown`** 으로 둔다. 종전엔 비-유선 = 무선으로 봐서, 유선 IP 로 resolve 되는
    /// 호스트명을 "무선"으로 거짓 표기할 수 있었다(랜선 뽑으면 끊기는데). 정직하게 "경로?".
    public static func classify(host: String) -> ConnectionLinkKind {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return .unknown }
        guard let octets = ipv4Octets(h) else { return .unknown }   // 호스트명/비IP = 미상
        return Array(octets.prefix(3)) == wiredNetworkOctets ? .wired : .wireless
    }

    /// 짧은 한국어 라벨.
    public var label: String {
        switch self {
        case .wired:    return "유선"
        case .wireless: return "무선"
        case .unknown:  return "경로?"
        }
    }

    /// SF Symbol.
    public var icon: String {
        switch self {
        case .wired:    return "cable.connector.horizontal"
        case .wireless: return "wifi"
        case .unknown:  return "questionmark.circle"
        }
    }

    /// 이 경로가 케이블에 의존하는가 — 유선만 true.
    public var requiresCable: Bool { self == .wired }

    /// 케이블 의존 여부를 사람말로 — hover/접근성 힌트.
    public var cableHint: String {
        switch self {
        case .wired:    return "직결 이더넷 — 랜선을 뽑으면 연결이 끊겨 모터가 멈춥니다."
        case .wireless: return "WiFi — 랜선 없이 동작합니다(케이블을 뽑아도 유지)."
        case .unknown:  return "활성 host 를 알 수 없습니다."
        }
    }

    /// 상태 tint — 유선=cable 톤(forge), 무선=success, unknown=secondary.
    public var tint: Color {
        switch self {
        case .wired:    return DFColor.forge
        case .wireless: return DFColor.success
        case .unknown:  return DFColor.textSecondary
        }
    }
}
