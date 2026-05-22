import Foundation

/// **사이클 137 (audit #8, codex MAJOR sweep)**: 네트워크 endpoint 상수 단일 source of truth.
///
/// 종전 "192.168.123.1" 가 30+ 곳에 hardcoded. 본 enum 으로 통일 — endpoint 변경 시
/// 한 곳만 수정. ROBOTIS DARwIn-OP2 ethernet direct connection 의 표준 IP.
public enum DFConnectionConstants {
    /// 이더넷 직결 시 robot 의 default IP (Quick Connect, NetworkProbe fallback 등).
    public static let robotEthernetIP: String = "192.168.123.1"

    /// forge-bridge USB↔TCP 데몬의 listen 포트.
    public static let bridgePort: UInt16 = 5530

    /// SSH 표준 포트.
    public static let sshPort: UInt16 = 22

    /// VNC 화면 공유 포트.
    public static let vncPort: UInt16 = 5900
}
