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

    /// Polling 주기 (ms). **v1.12** — e-stop latency 단축 위해 200→100ms 로 강화.
    /// Telemetry write 는 ~200ms(5Hz) 로 gate (매 2 poll).
    static const int POLL_INTERVAL_MS = 100;

    /// Telemetry write 주기 (ms). 200ms = 5Hz (§A.1).
    static const int TELEMETRY_INTERVAL_MS = 200;

    /// 명령 stale 임계 (ms). Mac 명령 갱신 끊긴 후 자동 stop.
    static const int STALE_TIMEOUT_MS = 5000;

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
    /// CMD_PATH 한 줄 read + parse + Walking/Head 적용.
    /// @return true = 정상 parse, false = 파싱 실패 (이전 명령 유지).
    bool ParseAndApply(Robot::Walking* walking, bool& walking_active);

    /// **v1.12** — Telemetry 한 줄 atomic write (§A.2). tmp + rename.
    /// cm730 NULL 이면 MotionStatus fallback (§A.1).
    void WriteTelemetry(Robot::CM730* cm730, bool walking_active);

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
};

}  // namespace Robotis

#endif  // WALKLAB_BROKERAGE_H_
