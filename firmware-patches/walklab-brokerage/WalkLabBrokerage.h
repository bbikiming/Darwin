/*
 * WalkLabBrokerage.h — DarwinForge WalkLab onboard brokerage mode
 *
 * v1.11.7 (2026-05-18) — Mac DarwinForge ↔ robot ROBOTIS Walking 엔진 bridge.
 *
 * Header. Implementation: WalkLabBrokerage.cpp.
 * 통합 절차: README-INTEGRATION.md 참조.
 */

#ifndef WALKLAB_BROKERAGE_H_
#define WALKLAB_BROKERAGE_H_

#include <pthread.h>          // O1 transport 스레드
#include "WalkLabTransport.h" // O1 — latest-wins 슬롯·워치독·파서(Robot:: 의존 0)

// 공식 ROBOTIS 프레임워크의 Walking/CM730 클래스는 namespace Robot 에 있음 (Robotis 아님).
namespace Robot { class Walking; }
namespace Robot { class CM730; }
namespace Robot { class Head; }
// 볼 트래킹 (2026-06-02) — 헤더 include 없이 forward 선언 (impl 에서만 사용).
namespace Robot { class ColorFinder; }
namespace Robot { class BallTracker; }

namespace Robotis {

class WalkLabBrokerage {
public:
    /// 명령 파일 경로 — Mac SSH 가 atomic mv 로 write.
    /// (C++03: 클래스 내 초기화 불가 → .cpp 에서 정의)
    static const char* const CMD_PATH;

    /// **v1.11.16.1 (2026-05-19)** — ACK 파일 경로.
    /// daemon 이 ParseAndApply 성공 시 "OK {ts_ms} {cmd_line}\n" write.
    /// Mac 측 send 명령이 250ms 후 cat 으로 ACK 검증 → 진짜 통신 성공 판단.
    /// 종전: Mac 의 SSH 가 명령 write 성공만 알고 daemon 처리 여부 silent.
    static const char* const ACK_PATH;

    /// **v1.12 (2026-06-01)** — Robot→Mac telemetry uplink 파일 경로 (§A).
    /// Run() 이 매 poll(200ms=5Hz) atomic write. Mac 이 SSH 로 cat → HUD + safety gates.
    /// 형식: "TEL {ts_ms} {gx} {gy} {gz} {ax} {ay} {az} {voltage_dV} {walking01} {fallen}\n"
    static const char* const TELEMETRY_PATH;

    /// **v1.12 (2026-06-01)** — E-stop flag 파일 경로 (§B). presence == STOP.
    /// Mac 이 SSH `touch` 로 생성 → 로봇이 매 poll 검사 → 즉시 Stop()+torque off.
    /// `rm -f` (Mac re-arm) 전까지 hold-stopped.
    static const char* const ESTOP_PATH;

    /// **UDP 업링크 타깃 파일 (2026-06-03)** — Mac 이 "IP PORT" 한 줄 기록 → 로봇이 매 poll
    /// 그 주소로 telemetry `TEL …` 라인을 UDP push (`RefreshUplinkTarget` 가 read).
    /// 없으면 파일+SSH(폴링) fallback. SSH cat 폴링(≈2Hz) 대비 10–30Hz·1 RTT 신선도.
    static const char* const UPLINK_PATH;

    /// Polling 주기 (ms). **v1.12** — e-stop latency 단축 위해 200→100ms 로 강화.
    /// Telemetry write 는 ~200ms(5Hz) 로 gate (매 2 poll).
    static const int POLL_INTERVAL_MS = 100;

    /// Telemetry write 주기 (ms). 200ms = 5Hz (§A.1). **파일 write 전용** — UDP push 는
    /// 매 poll(10–30Hz) 전송하고, 파일만 이 주기로 gate 한다(SSH fallback·디스크 churn 억제).
    static const int TELEMETRY_INTERVAL_MS = 200;

    /// **UDP 업링크 타깃 파일 재read 주기 (ms, 2026-06-03)**. 타깃은 거의 안 바뀌므로 1s throttle.
    static const int UPLINK_REFRESH_MS = 1000;

    /// 명령 stale 임계 (ms). Mac 명령 갱신 끊긴 후 자동 stop (워치독 최후 방어선).
    static const int STALE_TIMEOUT_MS = 5000;

    // ===== O1 이벤트 구동 전송 (2026-06-12, walklab-onboard-teleop-upgrade Wave O1) =====
    /// supervisor 루프 주기 (ms) — 보행 중. 종전 100ms → 20ms(실효율 ≥20Hz 목표).
    /// 정지/유휴 시엔 POLL_INTERVAL_MS(100ms) 유지(CPU 절약). 볼트래킹은 카메라 페이스.
    static const int SUPERVISOR_WALK_MS = 20;
    /// 핸드셰이크 파일 — Mac 이 세션 시작 시 "TOKEN ESTOP_PORT CMD_PORT" 한 줄 기록.
    /// 존재하면 UDP transport 스레드 기동(토큰 인증). 없으면 파일 폴 단독(영구 폴백).
    static const char* const CHANNEL_PATH;
    /// UDP transport 활성 시 파일 폴 완화 주기 (ms) — 250ms(디스크 churn 억제). 비활성 시 매 루프.
    static const int FILE_POLL_RELAXED_MS = 250;

    /// **v1.13 (2026-06-02)** — ONBOARD auto-getup (자동 일어나기) debounce.
    /// MotionStatus::FALLEN 이 STANDUP(0) 이 아닌 상태가 이 횟수만큼 연속 poll 동안
    /// 지속되어야 getup 발동 (walking jolt 로 인한 single-poll false trigger 방지).
    /// poll 이 100ms 이므로 6 = ~600ms 지속 낙상 확인.
    static const int FALL_DEBOUNCE_POLLS = 6;

    /// **v1.13** — 공식 ROBOTIS demo (StatusCheck.cpp) 의 getup 모션 page 번호.
    /// FALLEN==FORWARD(엎어짐) → page 10, FALLEN==BACKWARD(뒤로) → page 11.
    /// motion_4096.bin 에 내장. (출처: /robotis 펌웨어 백업 StatusCheck.cpp L48-51,
    /// DARwIn-OP_ROBOTIS_v1.6.0 동일.)
    static const int GETUP_PAGE_FORWARD = 10;
    static const int GETUP_PAGE_BACKWARD = 11;

    /// HIP_PITCH_OFFSET 안전 clamp 범위 (°). (C++03: .cpp 에서 정의)
    static const double HIP_PITCH_MIN;
    static const double HIP_PITCH_MAX;

    /// 무한 루프 — robot main() 가 호출. 외부에서 SIGTERM 또는 demo-pilot kill 까지 동작.
    /// **v1.12** — cm730 포인터 주입 (§A.1): voltage + 3축 raw IMU 를 bulk-read 버퍼에서
    /// 추가 bus 트래픽 없이 read. NULL 이면 MotionStatus 로 graceful degrade.
    void Run(Robot::CM730* cm730);

    /// **v1.12.1 (2026-06-01)** — 레거시 호출 호환 오버로드.
    /// 기존 main.cpp 주입부는 `Run()` (무인자) 로 호출한다. DARWIN 프레임워크의
    /// 활성 CM730 인스턴스는 main.cpp 지역변수라 외부에서 접근 불가하고
    /// MotionManager::m_CM730 는 private 이므로, 무인자 경로는 NULL 을 넘겨
    /// telemetry 를 MotionStatus(IMU) 로 graceful degrade 시킨다 (§A.1).
    /// CM730 을 직접 넘길 수 있는 호출부는 Run(cm730) 를 쓴다.
    void Run() { Run(0); }

private:
    /// CMD_PATH 한 줄 read → ApplyCommandLine 위임 (파일 경로 — 영구 폴백).
    /// @return true = 정상 parse, false = 파싱 실패 (이전 명령 유지).
    bool ParseAndApply(Robot::Walking* walking, bool& walking_active);

    /// **O1** — 명령 라인 1개를 파싱(WalkLabTransport::ParseCommandLine)·클램프·적용 +
    /// ACK write. 파일 경로와 UDP 슬롯 경로가 공유하는 단일 적용 함수(중복 제거).
    /// @return true = 적용됨, false = 파싱 실패(이전 명령 유지).
    bool ApplyCommandLine(Robot::Walking* walking, bool& walking_active, const char* line);

    // ===== O1 transport (UDP 리스너 스레드 — 핸드셰이크 토큰 있을 때만 기동) =====
    /// CHANNEL_PATH 읽어 m_udp_token/포트 채움. 토큰 있으면 true.
    bool LoadHandshake();
    /// **cross-review [MEDIUM]** — CHANNEL_PATH 를 1s 주기로 점검: 미기동 시 재시도 기동,
    /// mtime 변경(토큰 회전) 시 재기동, 파일 삭제(세션 종료) 시 정지(파일 폴 복귀).
    void RefreshHandshake(long long now_ms);
    /// UDP 명령(17374)·E-STOP(17372) 리스너 스레드 기동. 토큰 없으면 no-op.
    void StartTransportThreads();
    /// 리스너 스레드 정지 + 소켓 close (정상 종료 경로).
    void StopTransportThreads();
    /// UDP 명령 리스너 루프 — recvfrom → ParseCmdDatagram → 슬롯 Offer + UDP ACK 회신.
    void CmdUdpLoop();
    /// UDP E-STOP 리스너 루프 — recvfrom → ParseEstopDatagram → 즉시 Stop+토크OFF+flag touch.
    void EstopUdpLoop();
    /// pthread entry trampolines (C++03).
    static void* CmdUdpThreadEntry(void* self);
    static void* EstopUdpThreadEntry(void* self);

    /// **v1.12** — Telemetry 한 줄 (§A.2). 한 번 format 후: UDP push(매 poll) + (write_file
    /// 면) 파일 atomic write(tmp+rename, 200ms gate). cm730 NULL 이면 MotionStatus fallback.
    void WriteTelemetry(Robot::CM730* cm730, bool walking_active, bool write_file);

    /// **UDP 업링크 (2026-06-03)** — UPLINK_PATH("IP PORT")를 주기적(UPLINK_REFRESH_MS) read.
    void RefreshUplinkTarget(long long now_ms);
    /// UDP 소켓 lazy-open (비차단). 실패 시 m_udp_fd 는 -1 유지 → 파일+SSH fallback.
    void EnsureUdpSocket();
    /// telemetry 한 줄을 업링크 타깃으로 UDP 전송 (비차단 sendto, 실패 무음 — lossy 허용).
    void SendTelemetryUDP(const char* line, int len);

    /// **v1.12** — E-stop flag 존재 여부 (§B). access(F_OK).
    static bool EstopRequested();

    /// **v1.13 (2026-06-02)** — ONBOARD auto-getup. 매 poll 호출 (e-stop 검사 직후).
    /// MotionStatus::FALLEN 을 읽어 FALL_DEBOUNCE_POLLS 연속 낙상 시 공식 demo
    /// (StatusCheck.cpp) 와 동일한 절차로 일어선다: Walking::Stop() → body joint 을
    /// Action 에 인계 → getup page(10 fwd / 11 back) 재생 → 완료 후 joint 을 Walking 으로
    /// 반납. getup 동안 telemetry 를 계속 write (Mac 이 상태 관찰). e-stop flag 가 있으면
    /// 발동하지 않음 (caller 가 이미 e-stop 처리하지만 방어적으로 재확인).
    /// @param walking          Walking 싱글톤 (non-NULL 보장; caller 가 확인).
    /// @param cm730            telemetry 용 (getup 중 계속 write). NULL 허용.
    /// @param walking_active   [in/out] getup 발동 시 false 로 갱신 (보행 중단됨).
    /// @return true = getup 을 수행함 (이번 poll 의 명령 처리는 skip 권장).
    bool CheckAndRecoverFall(Robot::Walking* walking, Robot::CM730* cm730,
                             bool& walking_active);

    /// **v1.12** — head 가 한 번이라도 non-zero 명령을 받았는지 (default pose 보존용).
    bool m_head_commanded;

    // ===== O0 계측 (2026-06-12, walklab-onboard-teleop-upgrade Wave O0) =====
    /// 마지막으로 적용한 명령의 cmd_id (TEL 에 append → Mac 폐루프 확인). "no_id" 기본.
    char m_last_cmd_id[32];
    /// supervisor 루프 1회 소요(ms). 직전 루프 시작과의 delta. TEL loop_ms 토큰.
    long long m_loop_ms;

    // ===== O1 transport 상태 =====
    Robotis::CommandSlot m_cmd_slot;   ///< latest-wins 명령 슬롯(transport 스레드↔supervisor).
    long long m_last_cmd_ms;           ///< 마지막 유효 명령 적용 시각(ms) — 워치독 티어.
    bool m_last_cmd_from_stream;       ///< 마지막 명령이 UDP 슬롯(스트림) 소스였나 — 티어 게이트.
    char  m_udp_token[64];             ///< 핸드셰이크 토큰("" = transport 비활성).
    int   m_estop_port;                ///< E-STOP UDP 포트(핸드셰이크).
    int   m_cmd_port;                  ///< 명령 UDP 포트(핸드셰이크).
    int   m_estop_listen_fd;           ///< E-STOP 리스너 소켓 fd(-1 = 미생성).
    int   m_cmd_listen_fd;             ///< 명령 리스너 소켓 fd(-1 = 미생성).
    pthread_t m_estop_thread;          ///< E-STOP 리스너 스레드.
    pthread_t m_cmd_thread;            ///< 명령 리스너 스레드.
    volatile bool m_transport_running; ///< 스레드 기동 여부(스레드 루프 종료 플래그 — volatile).
    // 핸드셰이크 재시도·토큰 회전(cross-review [MEDIUM] 2026-06-12).
    long long m_last_channel_check_ms; ///< 마지막 CHANNEL_PATH 점검 시각(ms) — 1s throttle.
    long  m_channel_mtime_sec;         ///< CHANNEL_PATH mtime(sec) — 토큰 회전 감지.
    long  m_channel_mtime_nsec;        ///< CHANNEL_PATH mtime(nsec).

    // ===== UDP 텔레메트리 업링크 (2026-06-03) =====
    int m_udp_fd;               ///< UDP 소켓 fd. -1 = 미생성(lazy-open).
    char m_uplink_ip[64];       ///< 업링크 타깃 IP 문자열. "" = 타깃 없음.
    int m_uplink_port;          ///< 업링크 타깃 포트. 0 = 타깃 없음.
    long long m_last_uplink_ms; ///< 마지막 UPLINK_PATH read 시각(ms) — refresh throttle.

    /// **v1.13** — 연속 낙상 poll 카운터 (debounce). STANDUP 복귀 시 0 으로 reset.
    int m_fall_count;

    // ===== 볼 트래킹 (2026-06-02) — 로봇 온보드 자동 헤드 추적 (기본 데모와 동일) =====
    /// Mac serializedLine 13번째 필드(ball_track)로 토글. true 면 매 poll
    /// ProcessBallTracking() 이 카메라+ColorFinder+BallTracker 로 헤드를 움직인다.
    bool m_balltrack_enabled;

    /// vision 객체 lazy-init 여부. 첫 enable 시 ColorFinder/BallTracker 생성
    /// (카메라 싱글톤은 main.cpp 가 이미 Initialize). Run() 무한루프라 해제 불필요.
    bool m_vision_ready;

    /// 주황 공 색 finder (ROBOTIS 표준 데모 기본값). lazy-init.
    Robot::ColorFinder* m_ball_finder;

    /// 볼 위치 → Head::MoveTracking PD 추적기. lazy-init.
    Robot::BallTracker* m_tracker;

    /// **볼 트래킹** — 매 poll 호출 (enabled 시). 카메라 프레임 캡처 → 볼 위치 검출 →
    /// BallTracker::Process 가 Head::MoveTracking(offset) 또는 검색 scan 을 수행한다.
    /// 보행 여부와 무관 (헤드 전용). 카메라/Head 는 진입 시 이미 초기화돼 있음.
    void ProcessBallTracking();

    /// **공 색상 로드 (2026-06-03)** — config(balltrack.ini)의 [Find Color] 섹션을
    /// m_ball_finder 에 적용 (싸커 데모의 ColorFinder::LoadINISettings 와 동일).
    /// 주황 공은 hue≈25. 파일을 편집하고 볼 트래킹을 껐다 켜면 재빌드 없이 반영된다.
    void ReloadBallColor();

    /// 볼 트래킹 이전 enable 상태 (false→true edge 감지 → ReloadBallColor).
    bool m_balltrack_prev;

    /// 두리번 스캔 위상 (공 미검출 시 머리 sweep 정현파). enable 마다 리셋.
    double m_scan_phase;

    /// 연속 미검출 프레임 카운터. 이 값 이상이면 스캔 시작 (짧은 dropout 무시 → lock 유지).
    int m_noball_count;

    /// 현재 스캔(두리번) 중인가. 스캔→추적 전환 시 InitTracking(PD 리셋)에 사용.
    bool m_scanning;

    /// **끈끈한 추적 (2026-06-03)** — 스캔 시작 전 허용 dropout 프레임 수.
    /// 실측: 공이 눈앞에 있어도 검출률 ~40-60% 로 깜빡임 → 종전 15(0.5s)는 잠깐 끊겨도
    /// 두리번으로 이탈해 "못 따라옴"의 주원인. 45(~1.5s)로 늘려, 공이 있는 동안엔 검출이
    /// 끊겨도 마지막 위치를 응시하며 lock 유지(예측 coast). 진짜 사라졌을 때만 스캔 재개.
    static const int NOBALL_SCAN_DELAY = 45;

    // 추적 평활화/예측 상태 (2026-06-03). EMA 평활 위치 + 속도 추정.
    double m_ball_x;       ///< EMA 평활된 공 픽셀 X
    double m_ball_y;       ///< EMA 평활된 공 픽셀 Y
    double m_vel_x;        ///< 공 X 속도 (픽셀/프레임) — 미검출 예측에 사용
    double m_vel_y;        ///< 공 Y 속도 (픽셀/프레임)
    bool   m_track_valid;  ///< 유효한 추적 상태인가 (평활/예측 시드됨)

    /// **검출 강건화 (2026-06-03)** — 스캔(두리번) 중 락-인 hysteresis.
    /// 스캔 상태(m_track_valid=false)에서는 공간 게이트가 무력하므로, 연속
    /// LOCK_STREAK 프레임 일관 검출돼야 추적으로 전환(1프레임 false-positive 무시).
    int m_found_streak;

    /// **한계각 고착 탈출 (2026-06-03)** — 헤드가 pan/tilt 한계에 붙은 채 정지(static)한
    /// 연속 프레임. ColorFinder 가 공+다른 적색물체의 "무게중심"을 반환해 헤드가 중심을
    /// 못 맞추는 가장자리 오검출에 고착(코너 응시 = "딴 데 봄")하는 것을 감지·탈출한다.
    /// 추적중 따라가는 공은 헤드가 움직이므로(non-static) 오발동하지 않는다.
    int m_limit_stuck;
    double m_last_pan;   ///< 직전 프레임 pan (static 판정용)
    double m_last_tilt;  ///< 직전 프레임 tilt
};

}  // namespace Robotis

#endif  // WALKLAB_BROKERAGE_H_
