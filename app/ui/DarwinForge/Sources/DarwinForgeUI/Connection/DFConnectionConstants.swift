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

    /// **텔레메트리 UDP 업링크 포트 (2026-06-03)** — robot→Mac 텔레메트리 push 경로.
    /// 로봇 브로커리지가 `/tmp/df-walklab-telemetry` 의 `TEL …` 라인을 동일 형식으로
    /// 이 포트에 UDP push → Mac `OnboardTelemetryUDPReceiver` 가 bind/수신해 기존
    /// ingest 경로에 주입. SSH `cat` 폴링(≈2Hz) 대비 10–30Hz·1 RTT 도착.
    /// bridgePort(5530)/vncPort(5900)/Tello(8890) 와 비충돌 고정 사설 포트 —
    /// 로봇이 sendto 하는 계약값이므로 robot uplink 설정과 반드시 일치해야 한다.
    public static let telemetryUDPPort: UInt16 = 17371

    /// **E-STOP UDP 포트 (2026-06-12, cockpit-latency-hardening S5 / onboard O1)** —
    /// Mac→robot 긴급정지 전용 채널. 페이로드 `DF-ESTOP v1 {token} {unixMillis}` 를
    /// ×3 연발(0/50/100ms) 발사 — SSH 확인 경로와 *병행*(먼저 닿는 쪽 승리). 로봇 측
    /// 리스너(브로커리지 O1)는 수신 즉시 `Walking::Stop()`+토크OFF(~1–5ms). 토큰은 세션
    /// 시작 시 SSH 로 프로비저닝(spoofing 시에도 피해 = '불필요 정지' = fail-safe).
    /// telemetry(17371)/command(17374) 와 비충돌 고정 사설 포트.
    public static let estopUDPPort: UInt16 = 17372

    /// **명령 UDP 포트 (2026-06-12, onboard O1)** — Mac→robot 조종 명령(latest-wins) 채널.
    /// 페이로드 `DFCMD {token} {seq} {14-token-line}`. 로봇 리스너가 seq 단조 검사 후
    /// latest-wins 슬롯에 저장 → supervisor 가 적용. UDP 차단 시 파일+SSH 폴백 영구 보존.
    public static let commandUDPPort: UInt16 = 17374
}
