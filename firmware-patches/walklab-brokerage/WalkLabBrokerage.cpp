/*
 * WalkLabBrokerage.cpp — DarwinForge WalkLab onboard brokerage mode
 *
 * v1.11.6 (2026-05-18) — Mac DarwinForge ↔ robot ROBOTIS Walking 엔진 bridge.
 *
 * Usage (robot main.cpp):
 *   #include "WalkLabBrokerage.h"
 *
 *   int main() {
 *     // ... motion manager / Walking init ...
 *
 *     // Pilot mode 파일 read.
 *     char mode[16] = {0};
 *     FILE* fp = fopen("/tmp/df-pilot-mode", "r");
 *     if (fp) { fscanf(fp, "%15s", mode); fclose(fp); }
 *
 *     if (strcmp(mode, "walklab") == 0) {
 *       WalkLabBrokerage brokerage;
 *       brokerage.Run(&cm730);   // 무한 루프 — Mac SSH 명령 polling + telemetry uplink
 *     } else if (strcmp(mode, "soccer") == 0) {
 *       // 기존 SOCCER 모드 (ball tracker) ...
 *     } else {
 *       // 기존 READY 모드 ...
 *     }
 *     return 0;
 *   }
 *
 * 컴파일: gcc make 시 Framework/Linux/Makefile.mk 의 OBJS 에 WalkLabBrokerage.o 추가.
 */

#include "WalkLabBrokerage.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <math.h>          // 두리번 스캔 sweep (sin)
#include <sys/stat.h>
#include <sys/socket.h>     // UDP 업링크 (2026-06-03) — socket / sendto / recvfrom / setsockopt
#include <sys/time.h>       // O1 — struct timeval (SO_RCVTIMEO)
#include <netinet/in.h>     // sockaddr_in
#include <arpa/inet.h>      // inet_addr / htons / INADDR_NONE
#include <fcntl.h>          // O_NONBLOCK (비차단 소켓)
#include <errno.h>
#include <pwd.h>            // 실기 F7 — getpwnam (세션 파일 소유권 자가 치유)
#include "Walking.h"        // Robot::Walking::GetInstance()
#include "Head.h"           // Robot::Head::GetInstance()
#include "CM730.h"          // Robot::CM730 register map + bulk-read buffer
#include "FSR.h"            // **O4** Robot::FSR — 발 압력센서(4셀+CoP), 벌크리드 버퍼에 이미 포함
#include "MotionStatus.h"   // Robot::MotionStatus (IMU fallback + FALLEN)
#include "MotionManager.h"
#include "Action.h"         // **v1.13** Robot::Action (getup 모션 player)
#include "StatusCheck.h"    // **2026-06-08 후면 MODE 버튼 정지** — m_is_started 폴링
// 볼 트래킹 (2026-06-02) — 온보드 자동 헤드 추적 (기본 데모와 동일 vision 파이프라인).
#include "LinuxCamera.h"    // Robot::LinuxCamera::GetInstance() — main.cpp 가 이미 Initialize
#include "ColorFinder.h"    // Robot::ColorFinder — HSV 볼 검출
#include "BallTracker.h"    // Robot::BallTracker — 볼 위치 → Head::MoveTracking
#include "BallFollower.h"   // Robot::BallFollower — 볼-추종 보행(2026-06-14). Head 각도 → Walking X/A_MOVE
#include "Point.h"          // Robot::Point2D
#include "Camera.h"         // Robot::Camera::WIDTH/HEIGHT (예측 시 프레임 clamp)
#include "minIni.h"         // Robot::minIni — config 에서 공 색상(HSV) 로드 (싸커 데모와 동일)
// **C1 카메라 스트림 (2026-06-12)** — walklab 중 8080 MJPEG 프레임 펌프.
// Linux/include/mjpg_streamer.h(shim) → build/streamer/mjpg_streamer.h + httpd.h.
// httpd::ClientRequest(public static bool) = "클라이언트가 프레임 대기중" — 이 플래그
// 덕에 무뷰어 시 캡처/인코드 비용이 0 이다 (send_image 도 인코드를 이 플래그로 gate).
#include "mjpg_streamer.h"  // mjpg_streamer::send_image + httpd::ClientRequest

namespace Robotis {

    // C++03: 정적 멤버 클래스 외부 정의 (로봇 g++ 는 constexpr 미지원)
    const char* const WalkLabBrokerage::CMD_PATH = "/tmp/df-walklab-cmd";
    const char* const WalkLabBrokerage::ACK_PATH = "/tmp/df-walklab-ack";
    const char* const WalkLabBrokerage::TELEMETRY_PATH = "/tmp/df-walklab-telemetry";
    const char* const WalkLabBrokerage::ESTOP_PATH = "/tmp/df-walklab-estop";
    const char* const WalkLabBrokerage::UPLINK_PATH = "/tmp/df-walklab-uplink";
    // O1 — 핸드셰이크 파일("TOKEN ESTOP_PORT CMD_PORT"). Mac 이 세션 시작 시 기록.
    const char* const WalkLabBrokerage::CHANNEL_PATH = "/tmp/df-walklab-channel";
    const double WalkLabBrokerage::HIP_PITCH_MIN = 0.0;
    const double WalkLabBrokerage::HIP_PITCH_MAX = 20.0;

    // 공 색상 config 경로 (2026-06-03). [Find Color] 섹션을 ColorFinder 에 로드.
    // 절대 경로 — 데몬 cwd 무관. install-onboard 가 빨간 공 기본값으로 생성한다.
    #define BALLCOLOR_INI "/robotis/Linux/project/demo/balltrack.ini"

    // 추적 평활화 상수 (2026-06-03). EMA: 검출 위치 저역통과(0=강한평활/1=평활없음).
    // VEL_DECAY: 미검출 예측 시 속도 감쇠(overshoot 억제).
    #define BALL_EMA  0.45
    #define VEL_DECAY 0.85

    // **검출 강건화 — 카메라 추적 방법론 적용 (2026-06-03)**
    //  · BALL_GATE: 공간 검증 게이트(validation gate). 새 검출이 예측 위치에서 이
    //    픽셀거리 이상 떨어지면 false-positive(다른 적색 물체/노이즈)로 보고 기각 →
    //    그 프레임은 예측으로 coast. 프레임폭(320) 대비 0.40 → 128px. 실제 빠른 공
    //    이동은 허용하되 화면 반대편으로의 순간 점프는 차단(헤드가 노이즈를 안 쫓음).
    #define BALL_GATE_FRAC 0.45
    //  · GATE_HOLD_FRAMES: 게이트는 갓 추적중(미검출 N프레임 이내)일 때만 적용. 그 이상
    //    끊긴 뒤엔 공이 이동했을 수 있으므로 게이트를 풀어 어디서든 즉시 재획득(re-acquire).
    #define GATE_HOLD_FRAMES 3
    //  · LOCK_STREAK: 스캔 중 연속 일관검출 N프레임 후 추적 락-인(1프레임 specks 무시).
    //    2프레임=66ms → 사용자 체감 "즉시"이면서 1프레임 헛검출 방지.
    #define LOCK_STREAK 2
    //  · SCAN_STEP: 두리번 위상 증가/프레임. 0.16 → ~1.3s/좌우왕복(30fps). 명확한 sweep.
    #define SCAN_STEP 0.16

    // **한계각 고착 탈출 (2026-06-03)** — 가장자리 오검출(코너 응시) 감지·탈출.
    //  헤드가 한계각(LIM_PAN/LIM_TILT) 근처에서 STATIC_EPS 미만으로 거의 안 움직인 채
    //  LIMIT_STUCK_FRAMES 연속 지속되면 고착으로 보고 재스캔(진짜 공 재탐색).
    #define LIM_PAN  68.0     // pan 한계(±70) 바로 근처만
    #define LIM_TILT 54.0     // tilt 상한(55) 바로 근처만
    #define STATIC_EPS 1.5    // 프레임간 각 변화 < 1.5° = 정지로 간주
    #define LIMIT_STUCK_FRAMES 20   // ~0.7s 고착 → 탈출

    // **C1 카메라 스트림 (2026-06-12)** — 펌프 튜닝.
    //  · VIEWER_HOLD: 마지막 클라이언트 요청 관측 후 캡처를 유지하는 창. 스트림 클라이언트는
    //    프레임 소비마다 요청을 재게양하므로 시청 중엔 계속 갱신된다. 창 밖 = 무뷰어 휴면.
    //  · 캡처는 항상 카메라 자연 페이스(~30fps) — 캡처를 늦추면 V4L2 mmap 4-버퍼 FIFO 특성상
    //    DQBUF 가 200ms+ 묵은 프레임을 반환한다(조종용 영상 부적합). 대역/인코드 절감은
    //    send_every(매 N 캡처당 1회 송출)로만 한다.
    #define STREAM_VIEWER_HOLD_MS 2000
    #define STREAM_IDLE_SLEEP_US  (100 * 1000)  // 볼트랙 양보 중 펌프 휴면
    #define STREAM_POLL_SLEEP_US  (10 * 1000)   // 무뷰어 플래그 폴링(요청 감지 지연 상한 10ms)

    // ===== SIGTERM/SIGINT 핸들러 (§B) ============================================
    // Mac e-stop 의 belt-and-suspenders 경로(`killall -TERM demo demo-pilot`) 와
    // Ctrl-C 가 gait 를 빠르게 멈추도록: Walking::Stop() + body torque off 후 즉시 종료.
    // async-signal-safe 제약: 여기서는 프레임워크 호출(Stop/SetEnableBody)만 수행하고
    // stdio 는 쓰지 않는다 (printf 는 비-재진입). _exit() 로 atexit/flush 우회.
    extern "C" void WalkLabBrokerage_SignalStop(int /*sig*/) {
        Robot::Walking* walking = Robot::Walking::GetInstance();
        if (walking) {
            walking->Stop();
            walking->m_Joint.SetEnableBody(false);
        }
        // F12 — 킥(Action) 진행 중 SIGTERM/Ctrl-C 시 모션도 즉시 중단. 없으면 body
        // 토크 차단 후에도 Action 이 ~1~2s 더 서보를 구동(불안전). TriggerEstopImmediate·
        // MODE 종료와 동일 계약(설계 §7). Stop()은 멱등 플래그 셋(stdio 없음)이라 위
        // Walking::Stop 과 동일 클래스로 async-signal 안전.
        Robot::Action* action = Robot::Action::GetInstance();
        if (action && action->IsRunning()) action->Stop();
        _exit(0);
    }

    namespace {
        // 핸들러 1회 설치 (C++03: 람다/std::once 미사용).
        void InstallSignalHandlers() {
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_handler = WalkLabBrokerage_SignalStop;
            sigemptyset(&sa.sa_mask);
            sa.sa_flags = 0;
            sigaction(SIGTERM, &sa, NULL);
            sigaction(SIGINT, &sa, NULL);
            // **C1 [CRITICAL] (2026-06-12)** — SIGPIPE 무시. httpd::send_stream 은
            // `write()<0 → break` 에러 처리가 이미 있지만, SIGPIPE 기본 동작(프로세스 종료)이
            // write 가 -1 을 반환하기 **전에** 데모를 죽인다. 스트림 클라이언트가 끊긴 뒤
            // 카메라 펌프의 broadcast 가 고아 send_stream 스레드를 깨우면 죽은 소켓 write →
            // SIGPIPE → 데모 전체 사망(실측: Run 진입 ~200ms 내 무로그 종료). SIG_IGN 이면
            // write 가 EPIPE 를 반환해 공장 에러 경로가 설계대로 연결을 정리한다.
            // (공장 READY/SOCCER 모드 스트리밍도 같은 취약점이 있었음 — 본 패치로 함께 경화.)
            struct sigaction sp;
            memset(&sp, 0, sizeof(sp));
            sp.sa_handler = SIG_IGN;
            sigemptyset(&sp.sa_mask);
            sp.sa_flags = 0;
            sigaction(SIGPIPE, &sp, NULL);
        }

        // raw 10-bit ADC word 를 0..1023 으로 clamp (§A.1).
        int ClampAdc(int v) {
            if (v < 0) return 0;
            if (v > 1023) return 1023;
            return v;
        }
    }

    bool WalkLabBrokerage::EstopRequested() {
        return access(ESTOP_PATH, F_OK) == 0;
    }

    // ===== ONBOARD auto-getup (자동 일어나기) — v1.13 (§D) ========================
    // 공식 ROBOTIS demo 의 StatusCheck::Check() 낙상 복구 블록을 그대로 옮겼다.
    // (출처: /robotis 펌웨어 백업 Linux/project/demo/StatusCheck.cpp L41-57,
    //  DARwIn-OP_ROBOTIS_v1.6.0 동일. enum: MotionStatus.h — BACKWARD=-1/STANDUP=0/FORWARD=1.)
    //
    // 절차 (공식과 동일 순서):
    //   1. Walking::Stop() → IsRunning() 가 false 될 때까지 8ms 간격 대기.
    //   2. body joint 을 Action 모듈에 인계: Action::m_Joint.SetEnableBody(true,true).
    //   3. getup 모션 재생: FORWARD→Start(10), BACKWARD→Start(11). (motion_4096.bin)
    //   4. Action::IsRunning() 가 false 될 때까지 대기 (모션 완료).
    //   5. joint 을 Walking/Head 로 반납: Head::SetEnableHeadOnly(true,true) +
    //      Walking::SetEnableBodyWithoutHead(true,true). (Run() 초기 enable 과 동일.)
    // 대기 루프 안에서 telemetry 를 계속 write 하여 Mac 이 getup 상태를 관찰.
    bool WalkLabBrokerage::CheckAndRecoverFall(Robot::Walking* walking,
                                               Robot::CM730* cm730,
                                               bool& walking_active) {
        // 방어: e-stop flag 가 있으면 절대 auto-getup 하지 않는다 (caller 가 이미
        // 처리하지만, 호출 순서가 바뀌어도 안전하도록 재확인).
        if (EstopRequested()) {
            m_fall_count = 0;
            return false;
        }

        // **D-패드 앉음(2026-06-14, 리뷰 HIGH-1)** — auto-getup 을 *억제하지 않는다*. 앉음
        // (page15)은 몸통 직립=STANDUP 이라 아래 STANDUP 분기가 자연히 getup 을 막고(앉음 유지),
        // 앉다 진짜로 넘어지면(FALLEN) auto-getup 이 정상 복구해야 안전하다(억제 시 deadlock).
        // getup 이 실제 발화하면(아래) 로봇은 일어선 것이므로 m_sitting 을 해제한다.
        int fallen = Robot::MotionStatus::FALLEN;
        if (fallen == Robot::STANDUP) {
            m_fall_count = 0;   // 똑바로 서 있음 — 카운터 reset.
            return false;
        }

        // 낙상 후보 — debounce. walking jolt 로 인한 순간 FALLEN 은 무시.
        m_fall_count++;
        if (m_fall_count < FALL_DEBOUNCE_POLLS) {
            return false;
        }

        // 지속 낙상 확정. getup page 결정 — **명시적 3-way (리뷰 H1 fix)**.
        // FORWARD=엎드림→앞 getup, BACKWARD=누움→뒤 getup. 그 외(모호/예상밖 enum)는
        // 잘못된 방향으로 일어나면 위험하므로 getup 하지 않고 정지 유지 + 다음 poll 재판정.
        int page;
        const char* dir;
        if (fallen == Robot::FORWARD) {
            page = GETUP_PAGE_FORWARD;
            dir = "FORWARD";
        } else if (fallen == Robot::BACKWARD) {
            page = GETUP_PAGE_BACKWARD;
            dir = "BACKWARD";
        } else {
            // 모호한 낙상 방향 — 추측 금지. 정지 유지, 카운터 1단계 낮춰 재확인.
            fprintf(stderr, "[df] fall dir ambiguous (FALLEN=%d) — getup 보류\n", fallen);
            if (m_fall_count > 0) m_fall_count--;
            return false;
        }
        printf("[WalkLabBrokerage] FALL detected (%s, %d polls) — getup page %d\n",
               dir, m_fall_count, page);

        // 1) 보행 중단 + 완전 정지 대기. (telemetry 계속 write.)
        walking->Stop();
        walking_active = false;
        while (walking->IsRunning()) {
            // 리뷰(codex C1) fix: getup 대기 중에도 e-stop 즉시 반응 — 정지 유지하고 복귀.
            if (EstopRequested()) { m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);  // getup 중 파일+UDP 계속 보고.
            usleep(8000);   // 공식 demo 와 동일 8ms.
        }

        // 2) body joint 을 Action 모듈에 인계.
        Robot::Action* action = Robot::Action::GetInstance();
        if (!action) {
            // Action 모듈 미등록 — getup 불가. 안전하게 정지 유지하고 복귀.
            fprintf(stderr, "[WalkLabBrokerage] Action::GetInstance()==NULL — getup skip\n");
            m_fall_count = 0;
            return true;   // 보행은 멈춘 상태 — 이번 poll 명령은 skip.
        }
        action->m_Joint.SetEnableBody(true, true);

        // 3) getup 모션 재생. Start() 가 false 면 모듈이 아직 busy — 재시도
        //    (공식 SOCCER_REST 경로의 `while(Start(..)==false)` 패턴과 동일 안전장치).
        while (action->Start(page) == false) {
            // 리뷰(codex C1) fix: e-stop 시 getup 시작 중단 + body torque off.
            if (EstopRequested()) { action->m_Joint.SetEnableBody(false, true); m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);  // getup 중 파일+UDP 계속 보고.
            usleep(8000);
        }

        // 4) 모션 완료 대기. (telemetry 계속 write.)
        while (action->IsRunning()) {
            // 리뷰(codex C1) fix: getup 모션 중 e-stop → 모션 중단(Stop) + body torque off.
            if (EstopRequested()) { action->Stop(); action->m_Joint.SetEnableBody(false, true); m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);  // getup 중 파일+UDP 계속 보고.
            usleep(8000);
        }

        // 5) joint 을 Walking/Head 로 반납 — Run() 초기 enable 과 동일 패턴.
        Robot::Head* head = Robot::Head::GetInstance();
        if (head) head->m_Joint.SetEnableHeadOnly(true, true);
        walking->m_Joint.SetEnableBodyWithoutHead(true, true);

        m_fall_count = 0;   // 복구 완료 — 카운터 reset.
        m_sitting = false;  // **D-패드(2026-06-14)** — getup 으로 일어섰으니 앉음 상태 해제.
        printf("[WalkLabBrokerage] getup complete — joints returned to Walking, idle\n");
        return true;   // 보행은 정지 유지 — 다음 Mac 명령까지 대기.
    }

    // ===== F12 (2026-06-13) — 게임패드 LB/RB 킥 모션 ============================
    // getup(CheckAndRecoverFall)과 동일한 walk↔action 모듈 스왑을 복제하되, getup
    // page(10/11) 대신 공식 킥 page(LEFT=13 / RIGHT=12)를 재생한다. getup 과의 2가지
    // 차이: ① 게이트가 반대 — getup 은 FALLEN 일 때, 킥은 STANDUP 일 때만 발동.
    // ② 완료 후 settle(C)+낙상판정(B): ~300ms 정적 유지로 진동 감쇠 뒤 반납, settle 후
    // STANDUP 이면 m_fall_count 리셋(착지 transient 오발 억제), FALLEN 이면 리셋 대신
    // 임계로 올려 auto-getup 에 즉시 인계. 절차·8ms 대기·estop 즉시 반응·joint 반납(F9
    // 명시 재enable)은 getup 과 동일(프로덕션 검증 패턴). 블로킹(~2s) — 그 사이 estop·
    // 낙상 감지는 루프 상단에서 이미 처리됨, 새 walk 명령은 킥 후로 미뤄진다.
    bool WalkLabBrokerage::CheckAndExecuteKick(Robot::Walking* walking,
                                               Robot::CM730* cm730,
                                               bool& walking_active) {
        // 1) 보류 킥 요청 take (읽기 스레드와 배타). 없으면 즉시 복귀.
        pthread_mutex_lock(&m_kick_mtx);
        int side = m_pending_kick_side;
        m_pending_kick_side = -1;
        pthread_mutex_unlock(&m_kick_mtx);
        if (side < 0) return false;   // 요청 없음

        // 2) 단절 가드 — 패드가 사라졌으면 폐기. 읽기 스레드 단절(HandleNodeLost)은
        //    m_pending_kick_side(별 객체)를 비우지 못하므로 supervisor 가 여기서 막아
        //    "LB 누름 → 곧바로 단절" 시 stale 킥 발화를 차단한다(리뷰 concurrency-2).
        if (!m_gamepad.DevicePresent()) {
            printf("[WalkLabBrokerage] kick 무시 — gamepad 미연결(stale)\n");
            return false;
        }

        // 3) 안전 게이트 — estop 중이면 폐기(복구 전까지 모든 모션 금지). caller 가
        //    이미 estop 을 처리하지만 호출 순서 무관하게 안전하도록 재확인.
        if (EstopRequested()) return false;

        // 3.5) **D-패드(2026-06-14)** — 앉음 상태에선 STAND(위) 외 모션 차단(먼저 일어서기).
        if (m_sitting && side != Robotis::GP_ACTION_STAND) {
            printf("[WalkLabBrokerage] 앉은 상태 — STAND(D-패드 위) 먼저. action 무시(side=%d)\n", side);
            return false;
        }

        // 4) side → page + 이름. **단일 매핑 지점**(킥 비대칭 + D-패드 공식 페이지, op2 교차검증).
        int page = -1; const char* name = "?";   // default 가 return 하나 g++ uninit 경고 방지.
        switch (side) {
            case Robotis::GP_KICK_LEFT:         page = KICK_PAGE_LEFT;   name = "KICK LEFT";  break;
            case Robotis::GP_KICK_RIGHT:        page = KICK_PAGE_RIGHT;  name = "KICK RIGHT"; break;
            case Robotis::GP_ACTION_STAND:      page = STAND_PAGE;       name = "STAND";      break;
            case Robotis::GP_ACTION_SIT:        page = SIT_PAGE;         name = "SIT";        break;
            case Robotis::GP_ACTION_PASS_LEFT:  page = PASS_LEFT_PAGE;   name = "PASS LEFT";  break;
            case Robotis::GP_ACTION_PASS_RIGHT: page = PASS_RIGHT_PAGE;  name = "PASS RIGHT"; break;
            default:
                fprintf(stderr, "[WalkLabBrokerage] invalid action side=%d — 무시\n", side);
                return false;
        }

        // 5) 안전 게이트 — STANDUP(직립 몸통) 일 때만. 낙상/불안정 중 모션 금지(getup 우선).
        //    **STAND 도 STANDUP 요구**(리뷰 HIGH-2): 앉음(page15)은 몸통 직립=STANDUP 이라
        //    통과하고, 진짜 낙상(FORWARD/BACKWARD)에선 page16(앉은자세→서기)이 아니라
        //    auto-getup(page10/11)이 올바른 방향으로 일으킨다 — 넘어진 로봇에 page16 재생 차단.
        int fallen = Robot::MotionStatus::FALLEN;
        if (fallen != Robot::STANDUP) {
            printf("[WalkLabBrokerage] %s 무시 — not STANDUP (FALLEN=%d → auto-getup 이 처리)\n",
                   name, fallen);
            return false;
        }
        printf("[WalkLabBrokerage] ACTION %s — page %d\n", name, page);

        // 6) getup 과 동일 모듈 스왑 (검증된 패턴) ─────────────────────────────
        // 6-1) 보행 중단 + 완전 정지 대기(안정 스탠스로 수렴). telemetry 계속.
        walking->Stop();
        walking_active = false;
        while (walking->IsRunning()) {
            if (EstopRequested()) { m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);
            usleep(8000);   // 공식 demo 와 동일 8ms.
        }
        // 보행 완전 정지 후 STANDUP 재확인 — 안정 시점 1회(감속 중 자이로 transient 로
        // 인한 오발 회피, 리뷰 R2-FIX-3). 정지 대기 사이 실제 낙상이면 여기서 Action::Start
        // 를 막고 getup 에 인계(쓰러진 채 킥 금지, 리뷰 safety-1). Action 시작 *후*엔 킥
        // 모션 자체가 자세를 바꾸므로 FALLEN 검사 안 함(estop 만 중단). return true =
        // 보행 정지함→이번 poll 명령 skip(getup 의 estop-대기-bail 과 동일 계약, 안전).
        // 정지 후 STANDUP 재확인(감속 transient 회피). 비STANDUP(정지 사이 실제 낙상)이면
        // Action 시작 전 중단 → getup 인계(STAND 포함 — page16 은 STANDUP 전제, 낙상 시 부적합).
        if (Robot::MotionStatus::FALLEN != Robot::STANDUP) {
            printf("[WalkLabBrokerage] %s 중단 — 정지 후 낙상 감지 → getup 인계\n", name);
            m_fall_count = 0;
            return true;
        }
        // 6-2) body joint 을 Action 모듈에 인계.
        Robot::Action* action = Robot::Action::GetInstance();
        if (!action) {
            fprintf(stderr, "[WalkLabBrokerage] Action::GetInstance()==NULL — kick skip\n");
            m_fall_count = 0;
            return true;   // 보행은 멈춘 상태 — 이번 poll 명령 skip.
        }
        action->m_Joint.SetEnableBody(true, true);
        // 6-3) 킥 모션 재생. Start() false 면 모듈 busy — 재시도(estop bail + 토크 off).
        //   getup 패리티: Start()가 false 면 아직 미시작 → Stop() 불요(중단할 모션 없음).
        while (action->Start(page) == false) {
            if (EstopRequested()) { action->m_Joint.SetEnableBody(false, true); m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);
            usleep(8000);
        }
        // 6-4) 모션 완료 대기. estop → 모션 중단(Stop) + body torque off.
        while (action->IsRunning()) {
            if (EstopRequested()) { action->Stop(); action->m_Joint.SetEnableBody(false, true); m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);
            usleep(8000);
        }
        // 6-5) **C (2026-06-13) — 킥 착지 안정화 settle**. 모션 완료 직후 Action 이 여전히
        //   body joint 을 소유한 채(아직 미반납) 최종 스탠스를 ~300ms 유지한다 — 서보가
        //   마지막 포즈를 홀드하므로 스윙 잔여 진동이 감쇠된다. 이 정적 유지 뒤에 Walking 으로
        //   반납하면 핸드오프 순간의 흔들림 bump 가 줄어 낙상 마진을 회복. estop 즉시 반응 +
        //   telemetry 계속(getup/모션완료 대기 루프와 동일 계약). 페이지 감속(A)과 함께
        //   "빠른 스냅 → 넘어질 듯" 문제를 완화하는 두 번째 레버.
        for (int settle = 0; settle < KICK_SETTLE_TICKS; ++settle) {
            if (EstopRequested()) { action->m_Joint.SetEnableBody(false, true); m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking, walking_active, true);
            usleep(8000);
        }
        // 7) joint 을 Walking/Head 로 반납 — ★F9: Walking::Start()는 enable 복구 안 함★
        //    (MotionManager 는 enable==true 만 서보 기록). getup 반납과 동일 패턴.
        //    (estop bail 경로는 의도적으로 반납 안 함 — estop=토크 OFF 유지, 재enable 은
        //     Y 복구 경로가 SoftTorqueRearm+getup 패턴으로 수행. getup estop bail 과 동일.)
        Robot::Head* head = Robot::Head::GetInstance();
        if (head) head->m_Joint.SetEnableHeadOnly(true, true);
        walking->m_Joint.SetEnableBodyWithoutHead(true, true);

        // 8) **B (2026-06-13) — settle 후 낙상 판정**. 킥 중 능동 자이로 밸런스는 프레임워크
        //    구조상 불가하다(Action 은 개루프 위치재생, MotionManager 는 balance 미적용,
        //    BALANCE_*_GAIN 은 Walking 모듈 전용). 자이로의 현실적 보호 역할은 "넘어졌으면
        //    일으켜 세우기" — 그 경로(auto-getup)를 킥이 막지 않도록 한다.
        //    settle(~300ms)로 착지 transient 가 지났으므로 이 시점 FALLEN 은 "킥이 실제로
        //    넘어뜨림"의 신뢰 신호. STANDUP 이면 종전처럼 카운터 리셋(transient 오발 억제).
        //    FALLEN 이면 m_fall_count 를 임계로 올려 다음 poll 의 CheckAndRecoverFall 이
        //    즉시 복구(getup)하게 인계한다 — 종전의 무조건 리셋이 만들던 ~600ms 복구 지연 제거.
        // **D-패드 자세(2026-06-14)**: SIT 은 의도된 앉음 — 낙상 판정 건너뛰고 앉음 상태로.
        // (앉음 자세가 비STANDUP 으로 읽혀도 m_sitting 이 auto-getup 을 추가 차단한다.)
        if (side == Robotis::GP_ACTION_SIT) {
            m_sitting = true;
            m_fall_count = 0;
            printf("[WalkLabBrokerage] SIT complete — 앉음(보행/getup 차단; STAND 로 해제)\n");
            return true;
        }
        if (side == Robotis::GP_ACTION_STAND) m_sitting = false;   // 일어섬 — 앉음 해제.

        if (Robot::MotionStatus::FALLEN == Robot::STANDUP) {
            m_fall_count = 0;   // 똑바로 섬 — 착지 transient 의 auto-getup 오발 억제(기존 동작).
            printf("[WalkLabBrokerage] ACTION complete — STANDUP, joints returned, idle\n");
        } else {
            // settle 후에도 낙상 — 억제 금지. 다음 poll 이 즉시 debounce 충족하도록 임계 set.
            m_fall_count = FALL_DEBOUNCE_POLLS;
            fprintf(stderr, "[WalkLabBrokerage] action 후 FALLEN(%d) — auto-getup 에 인계\n",
                    Robot::MotionStatus::FALLEN);
        }
        return true;   // 보행 정지 유지 — 다음 명령까지 idle(getup 과 동일).
    }

    // ===== 볼 트래킹 (2026-06-02) — 온보드 자동 헤드 추적 =====================
    // 공식 ROBOTIS soccer demo (Linux/project/demo/main.cpp) 의 ball-tracking 루프를
    // 그대로 옮겼다: LinuxCamera::CaptureFrame → ColorFinder::GetPosition(HSV) →
    // BallTracker::Process. 볼이 보이면 Head::MoveTracking(offset) 로 따라가고, 안 보이면
    // NoBall scan(Head::MoveTracking())/InitTracking 으로 검색한다 — 전부 Head 싱글톤이
    // 처리하므로 추가 모터 bus write 없이 MotionManager 8ms tick 이 헤드를 구동한다.
    //
    // 카메라/Head/ColorFinder 전제: walklab 진입(RobotSetupCommand injection) 이 이미
    // (1) LinuxCamera::Initialize(0) (demo main.cpp L63, 주입 anchor 이전) 과
    // (2) Head::SetEnableHeadOnly(true,true) 를 수행했다. ColorFinder/BallTracker 만
    // 본 모듈이 lazy-init (첫 enable 시). Run() 무한루프라 delete 불필요.
    // 공 색상(HSV)을 config 에서 m_ball_finder 로 로드. 파일/키 없으면 ColorFinder 기존값 유지.
    // 싸커 데모의 `ball_finder->LoadINISettings(ini)` 와 동일 메커니즘 ([Find Color] 섹션).
    void WalkLabBrokerage::ReloadBallColor() {
        if (!m_ball_finder) return;
        // minIni 는 전역 namespace (ROBOTIS Framework — Robot 아님). 데모도 `minIni*` 사용.
        minIni ini(BALLCOLOR_INI);
        m_ball_finder->LoadINISettings(&ini);

        // **카메라 조도(노출/게인) — config 로드·적용 (2026-06-03)**. 재빌드 없이 ini 로 튜닝.
        // 기본값 = ROBOTIS 프레임워크/싸커 데모 baseline (gain 255, exposure 1000, manual).
        // 종전 하드코딩(gain255/exp2300)은 과노출 → 채도 washout → 배경 적색 오검출 유발.
        // 노출을 baseline 으로 "초기화"해 색 채도를 살려 깔끔하게 검출. AUTO 먼저(manual 고정)
        // 후 GAIN/EXPOSURE 적용 순서 준수.
        Robot::LinuxCamera* cam = Robot::LinuxCamera::GetInstance();
        if (cam) {
            int auto_exp = ini.geti("Camera", "auto_exposure", 1);   // 1 = manual
            int gain     = ini.geti("Camera", "gain", 255);
            int exposure = ini.geti("Camera", "exposure", 1000);
            cam->v4l2SetControl(V4L2_CID_EXPOSURE_AUTO, auto_exp);
            cam->v4l2SetControl(V4L2_CID_GAIN, gain);
            cam->v4l2SetControl(V4L2_CID_EXPOSURE_ABSOLUTE, exposure);
        }
    }

    void WalkLabBrokerage::ProcessBallTracking() {
        if (!m_vision_ready) {
            m_ball_finder = new Robot::ColorFinder();
            // **싸커 데모와 동일 (2026-06-03)**: ColorFinder 기본 생성자는 hue356(빨강)이라
            // 주황 공을 못 잡는다. soccer demo 의 `ball_finder->LoadINISettings(ini)` 처럼
            // config 에서 [Find Color] 섹션(hue/sat/val/percent)을 로드한다. 파일을 재빌드
            // 없이 편집해 hue 를 공 색에 맞춰 튜닝 가능. ReloadBallColor 가 [Camera] 조도도 함께
            // 적용한다(노출/게인 baseline 초기화 — 과노출 washout 제거).
            ReloadBallColor();
            // **상하 추적 개선 (2026-06-03)**: 머리 tilt 상한이 기본 40°라 공을 머리보다 높이
            // 들면 더 못 올라가 상하 추적이 막혔다. config([Head Pan/Tilt] top_limit)로 상한을
            // 올려 위쪽 추적 범위 확보 (프레임워크 수정 없이 LoadINISettings 로).
            {
                minIni hini(BALLCOLOR_INI);
                Robot::Head::GetInstance()->LoadINISettings(&hini);
            }
            m_tracker = new Robot::BallTracker();
            m_vision_ready = true;
            printf("[WalkLabBrokerage] ball-tracking vision init (config %s)\n", BALLCOLOR_INI);
        }
        // C1 (2026-06-12) — 캡처/fbuffer 는 펌프 스레드와 m_cam_mutex 로 배타. 볼트랙 중엔
        // 펌프가 양보(m_balltrack_enabled)하므로 평시 경합 없음 — 모드 전환 순간만 직렬화.
        pthread_mutex_lock(&m_cam_mutex);
        Robot::LinuxCamera::GetInstance()->CaptureFrame();
        Robot::Point2D pos = m_ball_finder->GetPosition(
            Robot::LinuxCamera::GetInstance()->fbuffer->m_HSVFrame);
        // 볼트랙 중에도 같은 프레임을 8080 으로 송출(추가 캡처 0 비용). send_image 는
        // **무조건 호출**(send_every 페이스만 적용) — 요청 유무 분기·인코드 게이트는
        // send_image 내부가 한다(CameraPumpLoop 의 missed-wakeup 주석 참조). 무시청 시
        // 비용은 lock+broadcast 마이크로초 수준.
        if (m_streamer && m_stream_enabled && ++m_stream_skip >= m_stream_send_every) {
            m_stream_skip = 0;
            m_streamer->send_image(Robot::LinuxCamera::GetInstance()->fbuffer->m_YUVFrame);
        }
        pthread_mutex_unlock(&m_cam_mutex);

        // **추적 품질 업그레이드 (2026-06-03) — 카메라 추적 방법론 적용**:
        //  · 공간 검증 게이트(validation gate): 검출이 예측 위치에서 너무 멀면(다른 적색
        //    물체/노이즈) 기각 → 헤드가 화면을 가로질러 노이즈를 쫓지 않음(끊김의 주원인).
        //  · 스캔 락-인 hysteresis: 두리번 중 연속 LOCK_STREAK 프레임 일관검출돼야 추적
        //    전환(1프레임 specks 무시) — 게이트가 무력한 스캔 구간 false-lock 방지.
        //  · EMA 저역통과 평활화: Head PD 의 "제곱 D항"이 검출 노이즈를 증폭(jerk)하던
        //    것을 억제 → 자연스럽고 끊김 없는 추적.
        //  · 등속도 예측(Kalman 경량판): 짧은 미검출 동안 마지막 위치+(감쇠)속도로 공을
        //    추정해 끊김 없이 계속 추적 → lock 유지.
        //  · 긴 미검출: 두리번 스캔 — 상하+좌우, 명확하고 빠르게.
        Robot::Head* head = Robot::Head::GetInstance();
        const double W = (double)Robot::Camera::WIDTH;
        const double H = (double)Robot::Camera::HEIGHT;
        const double GATE = BALL_GATE_FRAC * W;

        bool raw_found = (pos.X >= 0 && pos.Y >= 0);
        bool found = raw_found;

        // 공간 검증 게이트 — 갓 추적중(track_valid + 미검출 GATE_HOLD_FRAMES 이내)일 때만.
        // 예측 위치에서 GATE 이상 벗어난 검출은 같은 공이 아니라고 보고 이 프레임은
        // 미검출로 처리(coast). 단 오래 끊긴 뒤엔 게이트를 풀어(공 이동 가능) 즉시 재획득.
        // **볼-추종(2026-06-14)**: 추종 보행 중엔 몸 이동으로 시야가 흔들려 공이 프레임에서
        // 크게 점프한다 — 정적 추적용 게이트가 이를 "다른 물체"로 기각하면 추적 상실→보행
        // 정지→스캔(한 번 걷고 머리만 거동). 보행 중엔 게이트 비활성(공 점프는 정당).
        if (raw_found && m_track_valid && !m_scanning && m_noball_count <= GATE_HOLD_FRAMES &&
            !m_ballfollow_enabled) {
            double px = m_ball_x + m_vel_x;       // 등속 예측 위치
            double py = m_ball_y + m_vel_y;
            double dx = pos.X - px, dy = pos.Y - py;
            if (dx * dx + dy * dy > GATE * GATE) found = false;
        }

        // **한계각 고착 탈출** — 헤드(직전 프레임 명령 결과)가 한계각에 붙은 채 거의 정지이고
        // **공이 프레임 중앙에 안 잡혔을 때만**. 가장자리 오검출(공+다른 적색물체 무게중심)에
        // 고착되면 중심을 못 맞춰 공 픽셀이 가장자리에 남는다 → 탈출. 반면 공을 높이 들어 tilt 가
        // 한계(55°)여도 공이 화면 중앙에 잡혔으면 정상 추적이므로 오발동 금지(중앙 정지 공의 상하
        // 흔들림 버그 수정). 따라가는 공은 헤드도 움직여(non-static) 역시 발동 안 함.
        // **볼-추종(2026-06-14)**: 추종 보행 중엔 비활성 — 접근하며 head tilt 가 한계로 내려갈
        // 때(공이 발 앞) 고착으로 오판해 재스캔→보행 정지하는 것 방지. 근접-정지는 follower 가 소유.
        if (head && m_track_valid && !m_scanning && !m_ballfollow_enabled) {
            double pa = head->GetPanAngle();
            double ti = head->GetTiltAngle();
            bool near_limit = (pa <= -LIM_PAN || pa >= LIM_PAN || ti >= LIM_TILT);
            bool static_head = (fabs(pa - m_last_pan) < STATIC_EPS &&
                                fabs(ti - m_last_tilt) < STATIC_EPS);
            // 공이 화면 중앙 영역에 잡혔으면 헤드가 중심을 맞춘 것 → 고착 아님.
            bool centered = raw_found &&
                            (fabs(pos.X - W * 0.5) < W * 0.25) &&
                            (fabs(pos.Y - H * 0.5) < H * 0.30);
            m_last_pan = pa; m_last_tilt = ti;
            if (near_limit && static_head && !centered) m_limit_stuck++;
            else m_limit_stuck = 0;
            if (m_limit_stuck >= LIMIT_STUCK_FRAMES) {
                // 고착 확정 — 추적 포기하고 즉시 재스캔(진짜 공 재탐색).
                m_limit_stuck = 0;
                m_found_streak = 0;
                m_track_valid = false;
                found = false;
                m_noball_count = NOBALL_SCAN_DELAY;   // coast 건너뛰고 바로 스캔
            }
        }

        if (found && m_scanning) {
            // 스캔 → 추적 전환: 연속 일관검출 hysteresis (false-lock 방지).
            m_found_streak++;
            if (m_found_streak >= LOCK_STREAK) {
                if (head) head->InitTracking();
                m_scanning = false;
                m_ball_x = pos.X; m_ball_y = pos.Y; m_vel_x = 0.0; m_vel_y = 0.0;
                m_track_valid = true;
                m_noball_count = 0;
                m_tracker->Process(Robot::Point2D(m_ball_x, m_ball_y));
            } else {
                // 아직 미확정 — 헤드 정지 보류(스캔 모션 멈춤), 다음 프레임 재확인.
                m_ball_x = pos.X; m_ball_y = pos.Y; m_vel_x = 0.0; m_vel_y = 0.0;
            }
        } else if (found) {
            // 정상 추적 — EMA 평활 + 속도 추정.
            if (!m_track_valid) {
                m_ball_x = pos.X; m_ball_y = pos.Y; m_vel_x = 0.0; m_vel_y = 0.0;
                m_track_valid = true;
            } else {
                double nx = BALL_EMA * pos.X + (1.0 - BALL_EMA) * m_ball_x;
                double ny = BALL_EMA * pos.Y + (1.0 - BALL_EMA) * m_ball_y;
                m_vel_x = nx - m_ball_x;   // 속도 추정 (픽셀/프레임)
                m_vel_y = ny - m_ball_y;
                m_ball_x = nx; m_ball_y = ny;
            }
            m_noball_count = 0;
            m_tracker->Process(Robot::Point2D(m_ball_x, m_ball_y));
        } else {
            m_found_streak = 0;
            m_noball_count++;
            if (m_track_valid && m_noball_count < NOBALL_SCAN_DELAY) {
                // 등속도 예측 — 공이 갔을 위치를 추정해 끊김 없이 추적 (속도 감쇠로 overshoot 억제).
                m_vel_x *= VEL_DECAY; m_vel_y *= VEL_DECAY;
                m_ball_x += m_vel_x; m_ball_y += m_vel_y;
                if (m_ball_x < 0.0) m_ball_x = 0.0; if (m_ball_x > W - 1) m_ball_x = W - 1;
                if (m_ball_y < 0.0) m_ball_y = 0.0; if (m_ball_y > H - 1) m_ball_y = H - 1;
                m_tracker->Process(Robot::Point2D(m_ball_x, m_ball_y));
            } else {
                // 오래 잃음 — 두리번 스캔. 상하좌우. 시작 시 현재 pan 에 위상 동기(점프 방지).
                m_track_valid = false;
                if (!m_scanning && head) {
                    double s = head->GetPanAngle() / 55.0;
                    if (s > 1.0) s = 1.0; if (s < -1.0) s = -1.0;
                    m_scan_phase = asin(s);
                    m_scanning = true;
                }
                m_scan_phase += SCAN_STEP;    // 명확한 두리번 (~1.3s/좌우왕복).
                double scan_pan  = 60.0 * sin(m_scan_phase);
                double scan_tilt = 20.0 + 24.0 * sin(m_scan_phase * 0.7);   // 상하 sweep (좌우와 다른 주기 → 자연스러운 패턴)
                if (head) head->MoveByAngle(scan_pan, scan_tilt);
            }
        }
    }

    // ===== 볼-추종 보행 (2026-06-14) — 싸커 데모 응용 =============================
    // ProcessBallTracking 이 머리를 추적·갱신한 직후 호출(tracker.ball_position 신선).
    // BallFollower 가 Head 각도(pan/tilt %)로 전진/회전량을 산출해 Walking::X/A_MOVE 를
    // **직접** 구동한다(거버너/슬루 우회 — 공식 싸커 데모와 동일 메커니즘). 사용자 선택:
    // 추종만(자동 킥 없음 — KickBall 무시, 킥은 LB/RB 수동). 호출 게이트는 supervisor 가
    // (m_ballfollow_enabled && Armed) 로 소유. E-STOP/disarm/미ARM 은 보행을 막는다.
    void WalkLabBrokerage::ProcessBallFollow(Robot::Walking* walking, bool& walking_active) {
        if (!m_tracker) return;   // 방어(리뷰 LOW-3) — ProcessBallTracking 이 먼저 init 하나 가드.
        if (!m_follower) m_follower = new Robot::BallFollower();
        if (m_track_valid && !m_scanning) {
            // 공 추적 중 — 공을 향해 보행. KickBall 신호는 무시(추종만, 사용자 선택).
            m_follower->Process(m_tracker->ball_position);
            // follower 는 X(전진)/A(회전)만 구동 — Y(측보) 미사용. 수동 ApplyCommandLine 이
            // 둔 측보 진폭이 누출되지 않게 0 고정(자동 중 스틱 측보 무시 — 완전 follower 전용).
            // 슬루 목표/상태의 Y 도 0 으로 끌어 다음 루프 WriteShapedCommand 가 Y 를 안 쓰게
            // (리뷰 MEDIUM-1: 직전 측보 명령의 m_tgt_y 잔존이 20ms 측보 누출되던 것 차단).
            walking->Y_MOVE_AMPLITUDE = 0.0;
            m_tgt_y = 0.0; m_slew.y = 0.0;
        } else {
            // 공 미검출 — 보행 정지(머리는 ProcessBallTracking 스캔이 탐색). follower 의
            // MoveToHome(머리)와 스캔 충돌을 피해 follower 미호출, Walking 직접 정지.
            if (walking->IsRunning()) walking->Stop();
        }
        // follower 가 Walking 을 직접 Start/Stop 하므로 walking_active 를 실제 상태로 동기화.
        walking_active = walking->IsRunning();
    }

    // ===== C1 카메라 스트림 펌프 (2026-06-12) =====================================
    // 근본 원인: walklab 분기는 demo 원본 메인 루프(CaptureFrame→send_image, 원본 main.cpp
    // L159/L249) **진입 전에** Run() 으로 빠진다 → 8080 httpd 스레드와 /dev/video0 은 살아
    // 있는데 프레임을 밀어 넣는 코드만 영원히 실행되지 않았다("포트 열림·영상 없음"의 정체,
    // 클라이언트는 condvar 대기 고착). 이 펌프가 그 역할을 전담 스레드로 복원한다.
    //
    // 설계 불변식:
    //  · 캡처는 카메라 자연 페이스(~30fps) — CaptureFrame 이 다음 프레임까지 블록해 스스로
    //    페이스를 만든다. 느린 캡처는 V4L2 4-버퍼 FIFO 에 묵은 프레임을 남긴다(상단 주석).
    //  · 무뷰어 = 무비용: httpd::ClientRequest 미관측(VIEWER_HOLD 창 밖)이면 캡처/인코드
    //    없이 10ms 플래그 폴링만 한다. supervisor 루프(보행 20ms)는 어느 경우에도 무영향.
    //  · 볼트랙 양보: m_balltrack_enabled 동안 펌프는 캡처하지 않는다(ProcessBallTracking
    //    이 캡처+송출 겸임). fbuffer 경합은 m_cam_mutex 가 전환 순간을 직렬화.
    //  · CPU 근거: 공장 SOCCER 데모는 같은 CPU 에서 캡처+컬러파인더 4종+보행+인코드를 단일
    //    루프로 동시 수행(원본 main.cpp L159-249) — 본 펌프 부하는 그 부분집합.

    void* WalkLabBrokerage::CameraPumpThreadEntry(void* self) {
        ((WalkLabBrokerage*)self)->CameraPumpLoop();
        return 0;
    }

    void WalkLabBrokerage::StartCameraPump() {
        if (!m_streamer || !m_stream_enabled) {
            printf("[WalkLabBrokerage] camera stream pump off (%s)\n",
                   m_streamer ? "[Stream] enabled=0" : "no streamer from main.cpp");
            return;
        }
        Robot::LinuxCamera* cam = Robot::LinuxCamera::GetInstance();
        if (!cam || !cam->fbuffer) {
            // 카메라 미초기화(이론상 demo 는 초기화 실패 시 기동 전에 죽지만 방어적으로).
            printf("[WalkLabBrokerage] camera not initialized — stream pump disabled\n");
            return;
        }
        m_camera_running = true;
        if (pthread_create(&m_camera_thread, 0, CameraPumpThreadEntry, this) != 0) {
            m_camera_running = false;
            printf("[WalkLabBrokerage] camera pump thread create failed — stream disabled\n");
            return;
        }
        printf("[WalkLabBrokerage] camera stream pump started (:8080, send_every=%d)\n",
               m_stream_send_every);
    }

    void WalkLabBrokerage::StopCameraPump() {
        if (!m_camera_running) return;
        m_camera_running = false;   // 루프 종료 — 최대 휴면(100ms)+캡처 1회 후 합류.
        pthread_join(m_camera_thread, 0);
    }

    void WalkLabBrokerage::CameraPumpLoop() {
        long long last_req_ms = 0;   // 마지막 클라이언트 요청 관측 시각(monotonic) — 뷰어 창.
        while (m_camera_running) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            long long now_ms = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
            // httpd 스레드가 set, send_image 가 consume — 공장 코드와 동일한 cross-thread
            // bool 관례(비-volatile이지만 단순 플래그 관측이라 지연 허용·정확성 무관).
            if (httpd::ClientRequest) last_req_ms = now_ms;

            bool viewer = (last_req_ms != 0 &&
                           now_ms - last_req_ms < STREAM_VIEWER_HOLD_MS);
            if (!viewer) { usleep(STREAM_POLL_SLEEP_US); continue; }
            if (m_balltrack_enabled) { usleep(STREAM_IDLE_SLEEP_US); continue; }

            pthread_mutex_lock(&m_cam_mutex);
            if (!m_balltrack_enabled) {   // 전환 레이스 재확인 (mutex 하).
                Robot::LinuxCamera::GetInstance()->CaptureFrame();   // ~33ms 페이스(신선 프레임).
                // send_image 는 **무조건 호출** (send_every 페이스만 적용) — 요청 유무 분기는
                // send_image 내부가 한다. 공장 프로토콜의 함정: ClientRequest=false 클리어가
                // db 뮤텍스 해제 **후**라, httpd 가 그 사이 재게양한 다음 요청을 지울 수 있다
                // (missed-wakeup). 공장 데모는 매 프레임 send_image 를 불러 else-브랜치의
                // broadcast 로 잠든 클라이언트를 깨워 자가 회복한다 — 바깥에서 ClientRequest
                // 로 게이트하면 그 회복 경로가 끊겨 스트림이 1프레임에서 고착한다(실측).
                if (++m_stream_skip >= m_stream_send_every) {
                    m_stream_skip = 0;
                    m_streamer->send_image(
                        Robot::LinuxCamera::GetInstance()->fbuffer->m_YUVFrame);
                }
            }
            pthread_mutex_unlock(&m_cam_mutex);
        }
    }

    // ===== O1 transport — UDP 리스너 스레드 (2026-06-12) =========================
    // 핸드셰이크 토큰이 있을 때만 기동. 스레드는 "수신→슬롯/정지"만 수행(적용 로직 없음).
    // Walking 파라미터 쓰기는 supervisor 단일 루프가 담당(§c 스레드 안전 — 단일 writer).

    bool WalkLabBrokerage::LoadHandshake() {
        m_udp_token[0] = '\0';
        m_estop_port = 0;
        m_cmd_port = 0;
        FILE* fp = fopen(CHANNEL_PATH, "r");
        if (!fp) return false;
        char tok[64] = {0};
        int ep = 0, cp = 0;
        int n = fscanf(fp, "%63s %d %d", tok, &ep, &cp);
        fclose(fp);
        if (n < 1 || tok[0] == '\0') return false;
        strncpy(m_udp_token, tok, sizeof(m_udp_token) - 1);
        m_udp_token[sizeof(m_udp_token) - 1] = '\0';
        // 포트 미기재 시 DFConnectionConstants 기본값(17372/17374)과 일치.
        m_estop_port = (n >= 2 && ep > 0) ? ep : 17372;
        m_cmd_port   = (n >= 3 && cp > 0) ? cp : 17374;
        // 세션 사용자 캡처(실기 F1) — 핸드셰이크는 Mac 이 SSH(robotis)로 쓰므로 그
        // 소유자가 곧 재무장(rm) 주체. UDP estop flag 를 이 uid 로 chown 해야
        // sticky /tmp 에서 Mac 의 rm 재무장이 가능하다(§G.2).
        struct stat hs_st;
        if (stat(CHANNEL_PATH, &hs_st) == 0) {
            m_session_uid = (int)hs_st.st_uid;
            m_session_gid = (int)hs_st.st_gid;
        }
        return true;
    }

    // 1s recv 타임아웃 UDP 리스너 소켓 open+bind. 실패 시 -1.
    static int OpenUdpListener(int port) {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return -1;
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons((unsigned short)port);
        struct timeval tv; tv.tv_sec = 1; tv.tv_usec = 0;   // 종료 플래그 재검사 주기.
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
        return fd;
    }

    void* WalkLabBrokerage::EstopUdpThreadEntry(void* self) {
        ((WalkLabBrokerage*)self)->EstopUdpLoop();
        return 0;
    }
    void* WalkLabBrokerage::CmdUdpThreadEntry(void* self) {
        ((WalkLabBrokerage*)self)->CmdUdpLoop();
        return 0;
    }

    void WalkLabBrokerage::EstopUdpLoop() {
        char buf[256];
        while (m_transport_running) {
            struct sockaddr_in src; socklen_t slen = sizeof(src);
            int len = (int)recvfrom(m_estop_listen_fd, buf, sizeof(buf) - 1, 0,
                                    (struct sockaddr*)&src, &slen);
            if (len <= 0) continue;   // 타임아웃/에러 — 종료 플래그 재검사.
            if (!Robotis::ParseEstopDatagram(buf, len, m_udp_token)) continue;
            // 즉시 정지(~1–5ms) + flag set — H1 공유 헬퍼(GamepadPilot B 버튼과 공용).
            TriggerEstopImmediate();
        }
    }

    // ===== H1/H2 E-STOP·복구 공유 헬퍼 (2026-06-12, P7) =========================
    // UDP estop 리스너(EstopUdpLoop)와 GamepadPilot B 버튼(읽기 스레드 콜백)이
    // 공유하는 단일 즉시-정지 경로 — 중복 구현 금지. 어느 스레드에서든 호출 가능.
    void WalkLabBrokerage::TriggerEstopImmediate() {
        Robot::Walking* w = Robot::Walking::GetInstance();
        // body 토크는 여기서 즉시 OFF — 킥 중이라 body joint 가 Action 소유여도, 같은
        // 물리 joint 의 enable 비트를 끄므로 로봇은 Action 상태와 무관하게 즉시 limp.
        if (w) { w->Stop(); w->m_Joint.SetEnableBody(false); }
        // F12 (2026-06-13) — 킥(Action) 진행 중이면 즉시 중단. 종전엔 Walking 만 멈춰
        // 킥 중 B 를 눌러도 모션이 1~2s 계속됐다(결함).
        // [스레드 안전] Stop()은 m_StopPlaying=true 멱등 플래그 셋이고, Action 을 실제로
        // 처리하는 건 MotionManager 의 별도 8ms 타이머 스레드(다음 tick 에 플래그 읽음).
        // reader/UDP/supervisor 어느 스레드가 호출해도 같은 값(true)을 쓰므로 torn write
        // 불가(단일 바이트 bool). supervisor 의 킥/getup 대기 루프도 EstopRequested()로
        // 동일 Stop 을 백스톱(≤8ms). 본 호출은 그보다 빠른 즉시 중단 — mutex 는 미설치:
        // 타이머 스레드(프레임워크 미계측)와는 동기화 불가라 효과 없고, getup 이 이미
        // supervisor↔타이머 동일 패턴으로 프로덕션 검증됨(리뷰 concurrency-1 판정).
        Robot::Action* a = Robot::Action::GetInstance();
        if (a && a->IsRunning()) a->Stop();
        // F12 — estop 시 보류 킥 요청 폐기(리뷰 R2-FIX-4). armed 상태에서 킥 직전 B 를
        // 누르면 큐된 m_pending_kick_side 가 Y 복구 후 깜짝 발화할 수 있다. m_kick_mtx 는
        // estop 호출 스레드(reader/UDP) 기동 전 Run() init(L1014)에서 초기화됨(순서 보장).
        pthread_mutex_lock(&m_kick_mtx);
        m_pending_kick_side = -1;
        pthread_mutex_unlock(&m_kick_mtx);
        TouchEstopFlag();
        // **하드닝 A1 (2026-06-14)**: 외부 E-STOP(UDP)·Gamepad-B 가 공유하는 이 경로에서
        // GamepadPilot 의 ARM 도 latch-해제(ISO 13850 reset≠restart). 종전엔 B 경로만
        // ProcessEvent 내부에서 disarm 했고 UDP E-STOP 은 물리정지+flag 만 했다 — flag
        // 해제 시 여전히 armed 라 잔여 스틱으로 즉시 재보행 가능했다. ForceDisarm 은
        // m_mtx 를 잡지만 이 함수는 락 미보유 컨텍스트(B 콜백은 ProcessEvent unlock 후
        // 발화)라 재진입 데드락 없음. Switch/Mac flag-only 경로는 별도 배선(아래 supervisor).
        m_gamepad.ForceDisarm();
        // **볼-추종(2026-06-14)**: E-STOP 시 자동 추종 모드 해제 — flag 해제 후 잔여 모드로
        // 자동 재보행 방지(재개하려면 START 재토글 필요). 안전 측 편향.
        m_ballfollow_enabled = false;
        // **D-패드 앉음(2026-06-14)**: E-STOP 시 앉음 상태 해제 — 복구 후 정상 게이트로.
        m_sitting = false;
    }

    void WalkLabBrokerage::TouchEstopFlag() {
        // flag 파일 touch — 기존 latch/re-arm(EstopRequested) 경로가 hold-stopped 소유.
        // 일회성 신호(UDP datagram·버튼 edge) → 파일이 상태를 소유(해제 전까지 정지 유지).
        // 실기 F1(2026-06-12): demo 는 root 라 flag 가 root 소유로 생기면 sticky /tmp
        // 에서 Mac(SSH robotis)의 rm 재무장이 영구 차단된다 → 세션 사용자로 chown.
        int fd = open(ESTOP_PATH, O_CREAT | O_WRONLY, 0644);
        if (fd >= 0) {
            if (m_session_uid >= 0 &&
                fchown(fd, (uid_t)m_session_uid, (gid_t)m_session_gid) != 0) {
                // chown 실패(비 root 실행 등)는 무해 — flag 자체는 유효.
            }
            close(fd);
        }
    }

    void WalkLabBrokerage::ClearEstopFlag() {
        // 복구(Y) — switch-pilot recover(`rm -f ESTOP_PATH`) 패리티. 전 소스 상시
        // 유효(H2-1). 파일 제거 → supervisor 가 다음 poll 에 "E-STOP cleared" 재무장.
        // 실기 F9: unlink 결과를 남긴다 — 라운드6 사후 분석에서 "복구가 발화했는가"를
        // 판별할 흔적이 전무했다(관측성). ENOENT(flag 없음)는 정상 no-op.
        if (unlink(ESTOP_PATH) == 0) {
            printf("[WalkLabBrokerage] recover — estop flag cleared\n");
        } else if (errno != ENOENT) {
            printf("[WalkLabBrokerage] recover — estop flag unlink FAILED errno=%d\n", errno);
        }
    }

    void WalkLabBrokerage::GamepadEstopTrampoline(void* self) {
        ((WalkLabBrokerage*)self)->TriggerEstopImmediate();
    }
    void WalkLabBrokerage::GamepadRecoverTrampoline(void* self) {
        ((WalkLabBrokerage*)self)->ClearEstopFlag();
    }

    // F12 (2026-06-13) — 킥 트램펄린. GamepadPilot 읽기 스레드가 LB/RB rising(ARM·
    // estop 게이트 통과) 시 호출. **블로킹 금지** — m_pending_kick_side 만 세팅하고
    // 즉시 반환(estop_cb 처럼 가볍게). 실제 모듈 스왑(1~2s 블로킹)은 supervisor 의
    // CheckAndExecuteKick 이 수행 — 읽기 스레드를 막으면 E-STOP(B) 응답이 죽는다.
    void WalkLabBrokerage::GamepadKickTrampoline(void* self, int side) {
        ((WalkLabBrokerage*)self)->RequestKick(side);
    }
    void WalkLabBrokerage::RequestKick(int side) {
        // 비블로킹 — 플래그만 세팅(읽기 스레드 막으면 E-STOP 응답 죽음). supervisor 가
        // 다음 poll(유휴 100ms→입력 신선 시 20ms, F11)에 소비 → 킥은 ≤1 poll 지연으로
        // 발화(즉발 아님 — 비블로킹 콜백 설계의 본질적 비용, 손실 아님). 콜백이 supervisor
        // 의 take 직후 도착하면 그 poll 을 놓치고 다음 poll 에 발화(여전히 단조 1회).
        pthread_mutex_lock(&m_kick_mtx);
        m_pending_kick_side = side;   // last-wins(동시 LB+RB 극히 드묾 — 무해)
        pthread_mutex_unlock(&m_kick_mtx);
    }

    // ===== 실기 F8 (2026-06-12) — 서보 알람 셧다운 스윕·복원 ====================
    // 실기 증상: 보행 벤치 후 양 발목 피치(ID15/16) 빨간 LED 점등 + 무토크,
    // 복구(getup/estop 해제)로도 미복구. 진단(브리지 직접 read): err=0x20(과부하),
    // Torque Limit=0 — MX-28 알람 셧다운이 tl 을 0 으로 강제(전원 재투입 또는
    // 재기록 전까지 토크 불가). 기존 복구 경로는 tl 을 재기록하지 않아 불응.
    // 쓰기는 Torque Limit 한정 — 토크 enable 은 건드리지 않으므로 자세 점프 없음
    // (enable 은 이후 Walking/Action Start 가 기존 경로로 복구).
    void WalkLabBrokerage::SweepServoShutdown(Robot::CM730* cm730, const char* reason) {
        if (!cm730) return;
        int restored = 0, hot = 0, failed = 0;
        for (int id = Robotis::SG_JOINT_ID_MIN; id <= Robotis::SG_JOINT_ID_MAX; ++id) {
            int tl = -1, err = -1;
            if (cm730->ReadWord(id, Robotis::SG_ADDR_TORQUE_LIMIT_L, &tl, &err)
                    != Robot::CM730::SUCCESS)
                continue;   // 무응답 — 추측 복원 금지(SG_NONE 동치).
            int temp = -1, terr = -1;
            bool temp_ok =
                (cm730->ReadByte(id, Robotis::SG_ADDR_PRESENT_TEMPERATURE, &temp, &terr)
                     == Robot::CM730::SUCCESS);
            Robotis::ServoGuardAction act =
                Robotis::ServoGuardDecide(true, tl, temp_ok, temp);
            if (act == Robotis::SG_RESTORE) {
                cm730->WriteWord(id, Robotis::SG_ADDR_TORQUE_LIMIT_L,
                                 Robotis::SG_TORQUE_LIMIT_RESTORE, 0);
                int tl2 = -1, err2 = -1;
                bool ok = (cm730->ReadWord(id, Robotis::SG_ADDR_TORQUE_LIMIT_L,
                                           &tl2, &err2) == Robot::CM730::SUCCESS)
                          && tl2 > 0;
                if (ok) ++restored; else ++failed;
                printf("[WalkLabBrokerage] servo guard(%s): ID%d shutdown latch"
                       " (err=0x%02x temp=%dC) -> torque limit %s\n",
                       reason, id, err & 0xFF, temp,
                       ok ? "restored" : "RESTORE FAILED");
            } else if (act == Robotis::SG_SKIP_HOT) {
                ++hot;
                printf("[WalkLabBrokerage] servo guard(%s): ID%d shutdown latch"
                       " but hot/unknown (temp=%dC > %dC safe) — cooling 후"
                       " 복구 재시도 필요\n",
                       reason, id, temp, Robotis::SG_TEMP_SAFE_C);
            }
        }
        if (restored || hot || failed)
            printf("[WalkLabBrokerage] servo guard(%s): restored=%d hot-skip=%d"
                   " failed=%d\n", reason, restored, hot, failed);
    }

    // 실기 F10 (2026-06-13) — E-STOP 복구 소프트 토크 램프. 사용자 피드백: Y 복구
    // 순간 관절이 목표 자세로 스냅(충격). Torque Limit 을 30%→100% 4단계로 올려
    // 관절이 낮은 토크로 끌려가다 점차 정상 토크에 도달하게 한다. 쓰기는 Torque
    // Limit 한정(enable 불변) — SweepServoShutdown 과 동일 버스 직렬화 경로.
    void WalkLabBrokerage::SoftTorqueRearm(Robot::CM730* cm730) {
        if (!cm730) return;
        for (int step = 0; step < Robotis::SG_SOFT_RAMP_STEPS; ++step) {
            int v = Robotis::SG_SOFT_RAMP_VALUES[step];
            for (int id = Robotis::SG_JOINT_ID_MIN; id <= Robotis::SG_JOINT_ID_MAX; ++id) {
                cm730->WriteWord(id, Robotis::SG_ADDR_TORQUE_LIMIT_L, v, 0);
            }
            if (step < Robotis::SG_SOFT_RAMP_STEPS - 1)
                usleep(Robotis::SG_SOFT_RAMP_INTERVAL_MS * 1000);
        }
        printf("[WalkLabBrokerage] soft torque re-arm — ramp %d steps to %d\n",
               Robotis::SG_SOFT_RAMP_STEPS,
               Robotis::SG_SOFT_RAMP_VALUES[Robotis::SG_SOFT_RAMP_STEPS - 1]);
    }

    void WalkLabBrokerage::CmdUdpLoop() {
        char buf[512];
        while (m_transport_running) {
            struct sockaddr_in src; socklen_t slen = sizeof(src);
            int len = (int)recvfrom(m_cmd_listen_fd, buf, sizeof(buf) - 1, 0,
                                    (struct sockaddr*)&src, &slen);
            if (len <= 0) continue;
            long long seq = 0;
            char line[256];
            if (!Robotis::ParseCmdDatagram(buf, len, m_udp_token, &seq, line, sizeof(line)))
                continue;
            // latest-wins 슬롯(seq 단조 — 역행 폐기). 적용은 supervisor.
            if (m_cmd_slot.Offer(line, seq)) {
                struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
                long long t_rx = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
                char ack[64];
                int an = snprintf(ack, sizeof(ack), "ACK %lld %lld\n", seq, t_rx);
                if (an > 0) sendto(m_cmd_listen_fd, ack, (size_t)an, 0,
                                   (struct sockaddr*)&src, slen);  // best-effort.
            }
        }
    }

    // **cross-review [MEDIUM] (2026-06-12)** — CHANNEL_PATH 1s 주기 점검.
    //  · 미기동 + 파일 존재 → LoadHandshake → 기동(Mac 이 나중에 기록해도 1s 내 수용).
    //  · 기동 중 + mtime 변경 → 재기동(구세션 토큰 잔존/회전 대응).
    //  · 기동 중 + 파일 삭제 → 정지(세션 종료 — walkLabClearChannelHandshake → 파일 폴 복귀).
    void WalkLabBrokerage::RefreshHandshake(long long now_ms) {
        if (m_last_channel_check_ms != 0 && (now_ms - m_last_channel_check_ms) < 1000) return;
        m_last_channel_check_ms = now_ms;

        struct stat st;
        if (stat(CHANNEL_PATH, &st) != 0) {
            // 파일 없음 — Mac 세션 종료. transport 가 떠 있으면 내려 파일 폴 단독 복귀.
            if (m_transport_running) {
                printf("[WalkLabBrokerage] channel handshake cleared — UDP transport down\n");
                StopTransportThreads();
                m_channel_mtime_sec = 0;
                m_channel_mtime_nsec = 0;
            }
            return;
        }

        bool mtime_changed = (st.st_mtim.tv_sec != m_channel_mtime_sec) ||
                             (st.st_mtim.tv_nsec != m_channel_mtime_nsec);

        if (!m_transport_running) {
            if (LoadHandshake()) {
                StartTransportThreads();
                m_channel_mtime_sec = st.st_mtim.tv_sec;
                m_channel_mtime_nsec = st.st_mtim.tv_nsec;
            }
        } else if (mtime_changed) {
            // 토큰/포트 회전 — 내렸다 새 핸드셰이크로 재기동.
            printf("[WalkLabBrokerage] channel handshake changed — restart UDP transport\n");
            StopTransportThreads();
            if (LoadHandshake()) StartTransportThreads();
            m_channel_mtime_sec = st.st_mtim.tv_sec;
            m_channel_mtime_nsec = st.st_mtim.tv_nsec;
        }
    }

    void WalkLabBrokerage::StartTransportThreads() {
        if (m_transport_running) return;
        if (m_udp_token[0] == '\0') return;   // 토큰 없음 — 파일 폴 단독(영구 폴백).
        m_estop_listen_fd = OpenUdpListener(m_estop_port);
        m_cmd_listen_fd   = OpenUdpListener(m_cmd_port);
        if (m_estop_listen_fd < 0 && m_cmd_listen_fd < 0) return;   // 둘 다 실패 — 폴백.
        m_transport_running = true;
        if (m_estop_listen_fd >= 0)
            pthread_create(&m_estop_thread, 0, EstopUdpThreadEntry, this);
        if (m_cmd_listen_fd >= 0)
            pthread_create(&m_cmd_thread, 0, CmdUdpThreadEntry, this);
        printf("[WalkLabBrokerage] UDP transport up (estop:%d cmd:%d)\n",
               m_estop_port, m_cmd_port);
    }

    void WalkLabBrokerage::StopTransportThreads() {
        if (!m_transport_running) return;
        m_transport_running = false;   // 스레드 루프 종료(≤1s recv 타임아웃 후).
        if (m_estop_listen_fd >= 0) {
            pthread_join(m_estop_thread, 0);
            close(m_estop_listen_fd); m_estop_listen_fd = -1;
        }
        if (m_cmd_listen_fd >= 0) {
            pthread_join(m_cmd_thread, 0);
            close(m_cmd_listen_fd); m_cmd_listen_fd = -1;
        }
    }

    void WalkLabBrokerage::Run(Robot::CM730* cm730, mjpg_streamer* streamer) {
        // **실기 F9 (2026-06-13)** — stdout 라인버퍼링. nohup 리다이렉트(파일)에선 블록
        // 버퍼링이라 estop/복구/획득 같은 안전 이벤트 로그가 수 시간 미flush 됐다
        // (실기 라운드6 사후 분석 불능의 원인). 진단 가치 > 미세 I/O 비용.
        setvbuf(stdout, NULL, _IOLBF, 0);
        // **실기 F7 (2026-06-12)** — 세션 파일 소유권 자가 치유. 부팅 rc.local 훅(root)이
        // 만든 /tmp/df-walklab-cmd 는 sticky /tmp 에서 Mac(SSH robotis)의 원자 교체
        // (mv = 대상 unlink)를 거부한다 → SSH 온보드 ACK 게이트 영구 실패. ACK 파일(root
        // 생성)의 rm 도 동급. demo 는 root 로 돌므로 진입 시 robotis 로 chown 해 Mac 쪽
        // 쓰기 경로를 복구한다(비root 실행/사용자 부재 시 무해 no-op).
        if (geteuid() == 0) {
            struct passwd* pw = getpwnam("robotis");
            if (pw) {
                if (chown(CMD_PATH, pw->pw_uid, pw->pw_gid) != 0) { /* 부재 시 무해 */ }
                if (chmod(CMD_PATH, 0666) != 0) { /* 동상 */ }
                if (chown(ACK_PATH, pw->pw_uid, pw->pw_gid) != 0) { /* 동상 */ }
            }
        }
        m_head_commanded = false;
        // O0 계측 — last_cmd_id/loop_ms 초기화.
        strcpy(m_last_cmd_id, "no_id");
        m_loop_ms = 0;
        // O1 transport — 멤버 초기화. 핸드셰이크는 루프의 RefreshHandshake 가 1s 내 수용.
        m_last_cmd_ms = 0;
        m_last_cmd_from_stream = false;
        // H2-4 — TEL2 active_source 초기값(종전 "file" 표시와 동일).
        m_active_source = SRC_FILE;
        // O2 셰이핑 — 목표/슬루 초기화(첫 명령은 SlewState.valid=false 라 즉시 수용).
        m_tgt_x = 0.0; m_tgt_y = 0.0; m_tgt_a = 0.0; m_tgt_period = 600.0;
        m_tgt_foot = 40.0; m_tgt_hip = 13.0; m_tgt_flags = 0;
        m_last_slew_ms = 0;
        m_yswap_base = Robotis::DEFAULT_Y_SWAP_AMPLITUDE;  // Run 진입 시 config 값으로 덮어씀.
        // O4 — TEL2 래치/seq/UDP gate 초기화.
        m_lat_x = 0.0; m_lat_y = 0.0; m_lat_a = 0.0; m_lat_period = 600.0;
        m_last_seq_applied = 0;
        m_last_udp_tel_ms = 0;
        m_udp_token[0] = '\0';
        m_estop_port = 0;
        m_cmd_port = 0;
        m_estop_listen_fd = -1;
        m_cmd_listen_fd = -1;
        m_transport_running = false;
        m_last_channel_check_ms = 0;
        m_channel_mtime_sec = 0;
        m_channel_mtime_nsec = 0;
        m_session_uid = -1;
        m_session_gid = -1;
        m_fall_count = 0;   // **v1.13** auto-getup debounce 카운터 초기화.
        // 볼 트래킹 (2026-06-02) — vision 상태 초기화 (lazy-init 은 첫 enable 시).
        m_balltrack_enabled = false;
        m_balltrack_prev = false;
        m_ballfollow_enabled = false;   // 볼-추종 보행(2026-06-14) — START 토글
        m_follower = 0;                 // lazy-init (첫 추종 시)
        m_sitting = false;              // D-패드 앉음 상태(2026-06-14)
        m_vision_ready = false;
        m_ball_finder = 0;
        m_tracker = 0;
        m_scan_phase = 0.0;
        m_noball_count = 0;
        m_scanning = false;
        m_ball_x = 0.0; m_ball_y = 0.0;
        m_vel_x = 0.0; m_vel_y = 0.0;
        m_track_valid = false;
        m_found_streak = 0;
        m_limit_stuck = 0;
        m_last_pan = 0.0; m_last_tilt = 0.0;
        // UDP 텔레메트리 업링크 (2026-06-03) — lazy-open. 타깃은 Mac 이 UPLINK_PATH 로 알림.
        m_udp_fd = -1;
        m_uplink_ip[0] = 0;
        m_uplink_port = 0;
        m_last_uplink_ms = 0;
        // C1 카메라 스트림 (2026-06-12) — 상태 초기화 + [Stream] 설정(balltrack.ini 공용,
        // 섹션/파일 없으면 기본값 = enabled·send_every 2 ≈ 15fps). 재빌드 없이 토글 가능.
        m_streamer = streamer;
        m_camera_running = false;
        pthread_mutex_init(&m_cam_mutex, 0);
        m_stream_skip = 0;
        // F12 (2026-06-13) — 킥 요청 상태 (게임패드 읽기 스레드 ↔ supervisor 배타).
        // 게임패드 Start(읽기 스레드 기동) 이전에 init 되어야 한다(아래 m_gamepad.Start).
        m_pending_kick_side = -1;
        pthread_mutex_init(&m_kick_mtx, 0);
        {
            minIni sini(BALLCOLOR_INI);
            m_stream_enabled = sini.geti("Stream", "enabled", 1) != 0;
            m_stream_send_every = sini.geti("Stream", "send_every", 2);
            if (m_stream_send_every < 1) m_stream_send_every = 1;
        }
        InstallSignalHandlers();

        Robot::Walking* walking = Robot::Walking::GetInstance();
        if (!walking) {
            fprintf(stderr, "WalkLabBrokerage: Walking::GetInstance() == NULL\n");
            return;
        }

        // O1 — 핸드셰이크는 루프의 RefreshHandshake 가 1s 주기로 점검(첫 루프에서 즉시 시도).
        // Mac 은 세션 시작 시 언제든 CHANNEL_PATH 를 기록하면 되고, 로봇이 1s 내 수용한다.

        printf("[WalkLabBrokerage] start polling %s every %dms\n",
               CMD_PATH, POLL_INTERVAL_MS);

        // **O2 [MEDIUM fix]** — Y_SWAP base 캡처: config.ini(LoadINISettings, main.cpp 가
        //    Run 전 호출)로 튜닝된 값을 1회 캡처해 게이트 부스트의 base 로 쓴다. 상수 20.0
        //    하드코딩은 튜닝값과 다르면 매 명령마다 실거동을 바꾼다(리뷰 지적). 0/음수면 폴백.
        m_yswap_base = (walking->Y_SWAP_AMPLITUDE > 0.0)
                           ? walking->Y_SWAP_AMPLITUDE
                           : Robotis::DEFAULT_Y_SWAP_AMPLITUDE;

        // 초기 default 상태 (정지).
        walking->X_MOVE_AMPLITUDE = 0.0;
        walking->Y_MOVE_AMPLITUDE = 0.0;
        walking->A_MOVE_AMPLITUDE = 0.0;
        walking->Z_MOVE_AMPLITUDE = 40.0;   // foot height default
        walking->PERIOD_TIME = 600.0;       // 600ms default
        walking->HIP_PITCH_OFFSET = 13.0;   // ROBOTIS 원본

        bool walking_active = false;
        bool estop_latched = false;     // **v1.12** — e-stop hold-stopped 상태 (§B).
        time_t last_cmd_time = 0;
        struct stat last_stat = {};
        // **v1.12** — telemetry write 를 ~200ms(5Hz) 로 gate (poll 은 100ms).
        long long last_tel_ms = 0;

        // C1 (2026-06-12) — 카메라 펌프 스레드 기동 (streamer NULL/disabled/카메라 미초기화면
        // no-op). supervisor 루프와 분리된 스레드라 보행 제어 타이밍엔 영향 없음.
        StartCameraPump();

        // H1 (2026-06-12) — RG G01 동글 직결 파일럿 기동. 패드 미연결 시 1s 재스캔만
        // 도는 무동작 스레드(자연 게이트). E-STOP(B)은 읽기 스레드에서 즉시 공유 헬퍼,
        // 복구(Y)는 estop flag 해제. 빌드 게이트: -DDF_NO_GAMEPAD_PILOT 로 제외 가능.
#ifndef DF_NO_GAMEPAD_PILOT
        m_gamepad.Start(&WalkLabBrokerage::GamepadEstopTrampoline,
                        &WalkLabBrokerage::GamepadRecoverTrampoline,
                        &WalkLabBrokerage::GamepadKickTrampoline, this, true);   // F12
#endif

        // 실기 F8 (2026-06-12) — 기동 스윕: demo 재시작(전원 유지)으로 이월된 서보
        // 셧다운 래치 복원. 전원 재투입 후라면 래치가 이미 풀려 있어 no-op.
        SweepServoShutdown(cm730, "startup");

        while (true) {
            // **2026-06-08 후면 MODE 버튼 정지** — 사용자가 데모 후면 패널의 MODE
            // 버튼을 다시 누르면 `StatusCheck::Check()` 가 m_is_started=0,
            // m_cur_mode=READY 로 설정한다(공식 데모와 동일 패턴). 이 폴링이 그 신호를
            // 받아 보행을 정중히 멈추고 Run() 을 빠져나가 main.cpp 의 switch case 가
            // 자연 종료되도록 한다. e-stop flag 와 별개의 정상 종료 경로.
            if (Robot::StatusCheck::m_is_started == 0) {
                printf("[WalkLabBrokerage] STOP signal from MODE button — exit Run()\n");
                walking->Stop();
                while (walking->IsRunning()) usleep(8000);
                walking->m_Joint.SetEnableBody(false);
                // F12 — 잔여 킥 모션 정리(정상 종료 경로에서도 Action 미잔존 보장).
                Robot::Action* kick_a = Robot::Action::GetInstance();
                if (kick_a && kick_a->IsRunning()) kick_a->Stop();
                // 헤드도 정지 + 토크 풀어 사용자가 들고 내릴 수 있게.
                Robot::Head::GetInstance()->m_Joint.SetEnableHeadOnly(false);
                StopTransportThreads();   // O1 — UDP 리스너 정리 후 정상 종료.
                StopCameraPump();         // C1 — 카메라 펌프 정리 (정상 종료 경로).
                m_gamepad.Stop();         // H1 — 읽기 스레드 정리 (미기동이면 no-op).
                break;
            }

            // 루프 시각 1회 계산 — uplink refresh throttle + telemetry gate 공용.
            struct timespec loop_ts;
            clock_gettime(CLOCK_REALTIME, &loop_ts);
            long long now_ms =
                (long long)loop_ts.tv_sec * 1000LL + loop_ts.tv_nsec / 1000000LL;
            // O0 계측 — 루프 1회 소요(직전 루프 시작과의 delta). 첫 루프(prev==0)는 0.
            static long long prev_loop_ms = 0;
            m_loop_ms = (prev_loop_ms != 0 && now_ms >= prev_loop_ms) ? (now_ms - prev_loop_ms) : 0;
            prev_loop_ms = now_ms;
            // UDP 업링크 타깃(/tmp/df-walklab-uplink) 주기 갱신(내부 1Hz throttle). Mac 연결 시
            // 자기 IP:port 를 기록 → 로봇이 그쪽으로 telemetry push. e-stop 전에 둬 정지 중에도 갱신.
            RefreshUplinkTarget(now_ms);
            // O1 — 핸드셰이크 재시도·토큰 회전 점검(1s throttle). e-stop 전에 둬 정지 중에도 갱신.
            RefreshHandshake(now_ms);

            // **v1.12 (§B)** — e-stop flag 검사를 명령 parse 보다 먼저. presence == STOP.
            // flag 존재 시 즉시 Stop()+body torque off, 제거될 때까지 hold (재-arm 가능하도록
            // 루프 종료 X). SIGTERM 경로는 별도 핸들러가 처리 (_exit).
            if (EstopRequested()) {
                if (!estop_latched) {
                    printf("[WalkLabBrokerage] E-STOP flag detected — stop + torque off\n");
                    walking->Stop();
                    walking->m_Joint.SetEnableBody(false);
                    walking_active = false;
                    estop_latched = true;
                    m_ballfollow_enabled = false;  // 볼-추종(리뷰 HIGH-1): flag E-STOP 도 추종 해제(TriggerEstopImmediate 와 대칭)
                    m_sitting = false;             // D-패드(리뷰 HIGH-1): flag E-STOP 도 앉음 해제(deadlock 방지)
                    // **하드닝 A1 (2026-06-14)**: Switch/Mac flag-only E-STOP 의 물리정지는
                    // 이 블록이 TriggerEstopImmediate 를 거치지 않고 직접 수행한다 — 그래서
                    // ForceDisarm 을 TriggerEstopImmediate 에만 넣으면 이 경로의 GamepadPilot
                    // ARM 이 latch 된 채 남는다(감사가 든 바로 그 시나리오: 외부 E-STOP→flag
                    // 해제→잔여 스틱 재보행). latch 진입 시점에 ARM 도 해제(ISO 13850).
                    m_gamepad.ForceDisarm();
                }
                WriteTelemetry(cm730, walking, walking_active, true);  // Mac 에 정지 상태 계속 보고(파일+UDP).
                // 실기 F11 — hold 중 20ms 폴: flag 해제(Y/rm) 감지가 종전 평균 50ms
                // → 10ms. 복구 체감 반응성(estop hold 루프 부하는 무시 가능).
                usleep(SUPERVISOR_WALK_MS * 1000);
                continue;   // flag 가 있는 동안 명령 무시.
            } else if (estop_latched) {
                // flag 제거됨 — re-arm. **실기 F9 (2026-06-13, P7 브링업)**: 종전 주석
                // "body torque 는 다음 Start() 가 복구"는 허위 — Walking::Start() 는
                // m_Ctrl_Running/m_Real_Running 플래그만 세팅하고 joint enable 을 건드리지
                // 않으며, MotionManager 는 GetEnable(id)==true 인 관절만 서보에 기록한다.
                // 그래서 estop 의 SetEnableBody(false) 이후 복구하면 명령·ACK 는 정상인데
                // 서보 기록이 0건(완전 무반응)이 됐다(실기 라운드6). getup 반납과 동일
                // 패턴으로 여기서 직접 재-enable 한다.
                printf("[WalkLabBrokerage] E-STOP cleared — re-armed (joints re-enabled)\n");
                estop_latched = false;
                Robot::Head* rearm_head = Robot::Head::GetInstance();
                if (rearm_head) rearm_head->m_Joint.SetEnableHeadOnly(true, true);
                walking->m_Joint.SetEnableBodyWithoutHead(true, true);
                // 관절 re-enable 과 한 쌍: stale enabled=1 cmd 파일 재적용 차단(getup 의
                // codex HIGH fix 패턴). 종전 memset(강제 재처리)은 관절이 살아난 뒤엔
                // 무의도 즉시 재보행이 된다 — *새 명령*이 와야 보행 재개.
                struct stat post_rearm = {};
                if (stat(CMD_PATH, &post_rearm) == 0) {
                    last_stat = post_rearm;
                } else {
                    memset(&last_stat, 0, sizeof(last_stat));
                }
                // 실기 F8 — 복구 시 서보 셧다운 스윕: 과부하 래치(빨간 LED·무토크)는
                // estop 해제/getup 만으로 안 풀린다 — Torque Limit 재기록 필요.
                // 보행 정지 상태(직전까지 hold-stopped)라 스윕 수십 ms 가 안전.
                SweepServoShutdown(cm730, "re-arm");
                // 실기 F10 — 소프트 토크 램프(300→1023, ~0.6s): 재무장 순간 관절이
                // 목표 자세로 스냅하던 충격 제거. 스윕(래치 복원) 뒤에 둬 종값 일관.
                SoftTorqueRearm(cm730);
            }

            // **v1.13 (2026-06-02)** — ONBOARD auto-getup. e-stop 검사 직후 (여기 도달 ==
            // e-stop flag 없음). 지속 낙상 감지 시 보행을 멈추고 일어선 뒤 이번 poll 의
            // 명령 처리는 건너뛴다 (getup 중 들어온 stale 명령으로 즉시 재보행 방지).
            // walking 은 NULL 아님 (위에서 확인). getup 후 다음 Mac 명령까지 정지 유지.
            if (CheckAndRecoverFall(walking, cm730, walking_active)) {
                // **codex HIGH fix (2026-06-02)**: getup 후 낙상 직전 명령을 다시 적용하지
                // 않는다(재보행→재낙상 루프 차단). 종전 `memset(&last_stat, 0)` 은 의도와 정반대로
                // 다음 poll 에서 *현재 파일*을 "변경됨"으로 보게 해 stale enabled=1 명령을 즉시
                // 재적용했다. 현재 cmd stat 을 last_stat 에 캡처해 "이미 처리됨"으로 표시 →
                // *새 명령*(다른 mtime/cmd_id)이 와야 보행 재개. (Mac 연결 시엔 Mac 이 정지 명령을
                // 보내고, WiFi 끊김 중엔 이 backstop 이 정지 유지.)
                struct stat post_getup = {};
                if (stat(CMD_PATH, &post_getup) == 0) {
                    last_stat = post_getup;
                } else {
                    memset(&last_stat, 0, sizeof(last_stat));
                }
                last_cmd_time = time(NULL);
                usleep(POLL_INTERVAL_MS * 1000);
                continue;
            }

            // F12 (2026-06-13) — 게임패드 LB/RB 킥. getup 직후·명령 적용 직전(여기 도달 ==
            // e-stop flag 없음). 보류 킥(읽기 스레드가 m_pending_kick_side 세팅)을 STANDUP
            // 게이트 통과 시 getup 과 동일 모듈 스왑으로 실행. 킥 후 보행 정지 유지 →
            // getup 과 동일하게 stale 명령 재적용 방지(다음 새 명령까지 정지). 우선순위:
            // estop(위) > getup(위) > kick(여기) > 보행 명령(아래).
            if (CheckAndExecuteKick(walking, cm730, walking_active)) {
                struct stat post_kick = {};
                if (stat(CMD_PATH, &post_kick) == 0) {
                    last_stat = post_kick;
                } else {
                    memset(&last_stat, 0, sizeof(last_stat));
                }
                last_cmd_time = time(NULL);
                usleep(POLL_INTERVAL_MS * 1000);
                continue;
            }

            // ── H1/H2 (2026-06-12): local 게임패드 소스. 우선순위 = E-STOP(전 소스
            //    상시 — 콜백/flag 경로, 여기 비경유) > local(최근 입력 ≤1s) > 네트워크.
            //    슬롯은 항상 drain(스테일 잔존 방지)하되 적용은 신선 창 안에서만.
            //    local 라인도 ApplyCommandLine 단일 지점 통과 — 거버너(O2)가 최종 클램프.
            bool local_control = m_gamepad.HasControl(now_ms);
            {
                char gp_line[256];
                if (m_gamepad.TakeCommand(gp_line, sizeof(gp_line)) && local_control) {
                    if (ApplyCommandLine(walking, walking_active, gp_line, now_ms)) {
                        last_cmd_time = time(NULL);
                        m_last_cmd_ms = now_ms;
                        m_last_cmd_from_stream = true;   // 연속 재공급(≤50ms) — 티어 대상.
                        m_active_source = SRC_LOCAL;     // H2-4 — TEL2 active_source.
                    }
                }
            }

            // ── O1: UDP latest-wins 슬롯 소비 (이벤트 구동). transport 미기동이면
            //    슬롯은 항상 비어 no-op → 종전 파일 경로 동작 완전 보존.
            //    H2-1: local 신선 창에는 네트워크 walk 명령 폐기(drain 만 — estop·복구는
            //    별도 경로라 영향 없음).
            {
                char slot_line[256];
                long long slot_seq = 0;
                if (m_cmd_slot.Take(slot_line, sizeof(slot_line), &slot_seq) &&
                    !local_control) {
                    if (ApplyCommandLine(walking, walking_active, slot_line, now_ms)) {
                        last_cmd_time = time(NULL);
                        m_last_cmd_ms = now_ms;
                        m_last_cmd_from_stream = true;   // 스트림 소스 — 워치독 티어 대상.
                        m_last_seq_applied = slot_seq;   // O4 — TEL2 seq_applied 폐루프.
                        m_active_source = SRC_UDP;       // H2-4.
                    }
                }
            }

            // ── 파일 경로 (영구 폴백). transport 활성 시 250ms 완화(디스크 churn 억제),
            //    비활성 시 매 루프(종전 동작 보존).
            static long long last_file_poll_ms = 0;
            bool do_file_poll = !m_transport_running ||
                                (now_ms - last_file_poll_ms >= FILE_POLL_RELAXED_MS);
            if (do_file_poll) {
                last_file_poll_ms = now_ms;
                struct stat current_stat = {};
                int stat_ret = stat(CMD_PATH, &current_stat);

                if (stat_ret == 0) {
                    // mtime(ns)+size 변경 감지(같은 길이 1초 내 변경 대응).
                    bool file_changed =
                        (current_stat.st_mtim.tv_sec != last_stat.st_mtim.tv_sec) ||
                        (current_stat.st_mtim.tv_nsec != last_stat.st_mtim.tv_nsec) ||
                        (current_stat.st_size != last_stat.st_size);
                    if (file_changed) {
                        last_stat = current_stat;
                        // H2-1 — local 신선 창에는 파일 walk 명령도 폐기(소비 표시만).
                        if (!local_control &&
                            ParseAndApply(walking, walking_active, now_ms)) {
                            last_cmd_time = time(NULL);
                            m_last_cmd_ms = now_ms;
                            m_last_cmd_from_stream = false;  // 파일 소스 — 티어 제외(5s STALE 만).
                            m_active_source = SRC_FILE;      // H2-4.
                        }
                    }

                    // 5s STALE_TIMEOUT — 최후 방어선(워치독 2.5s 가 먼저 발화하므로 backstop).
                    if (walking_active && last_cmd_time > 0 &&
                        (time(NULL) - last_cmd_time) > (STALE_TIMEOUT_MS / 1000)) {
                        printf("[WalkLabBrokerage] stale > %dms — auto stop\n",
                               STALE_TIMEOUT_MS);
                        walking->Stop();
                        walking_active = false;
                        m_ballfollow_enabled = false;   // 볼-추종(리뷰 CRITICAL-1): stale 정지 시 추종 해제
                    }
                } else {
                    // 파일 없음 — Mac 측 미연결. transport 가 없으면 정지(종전 동작).
                    // transport 활성이면 UDP 가 명령을 공급하므로 파일 부재로 정지하지 않는다
                    // (정지는 워치독 티어가 명령 stale 기준으로 판정).
                    // H1: local 게임패드가 조종 중일 때도 파일 부재로 정지하지 않는다.
                    if (!m_transport_running && !local_control) {
                        if (walking_active) {
                            walking->Stop();
                            walking_active = false;
                        }
                        m_balltrack_enabled = false;   // 헤드 scan 무한지속 방지.
                        m_ballfollow_enabled = false;  // 볼-추종(리뷰 CRITICAL-1): 정지 시 추종 해제
                    }
                }
            }

            // H2 ②③티어 활성 판정 — 아래 워치독 스냅 양보와 티어 블록이 공유.
            // **하드닝 A2 (2026-06-14)**: SRC_LOCAL 게이트는 유지한다 — 이 게이트는 "유휴
            // 패드가 Mac/Switch 네트워크 보행을 정지시키는" 회귀를 막으려는 의도적 설계다.
            // P0-3↔P1-2 결합 결함(선점 창에서 active_source 플립으로 ②티어 슬루 무장해제)은
            // GP_LOCAL_FRESH_MS 를 GP_SILENCE_SLEW_MS 와 정렬해 근본 차단했다: local 신선
            // 창(1.5s) 내내 UDP/파일은 게이트아웃(!local_control)되어 active_source 가
            // SRC_LOCAL 을 유지하므로, 신선 중 노드 소멸은 항상 local_fs_slew=true 로 잡힌다.
            // 신선 창 만료 후 다른 소스가 보행을 인계하면 그 소스의 워치독이 정지를 소유한다.
            // 경계 주의(리뷰 HIGH-1): 침묵 정확히 1500ms 틱에서는 local_control(≤1500)과 ③티어
            // SLEW_ZERO(≥1500)가 동시 참 — 결함이 아니라 ③티어 슬루 *개시* 시점이다. 그 순간
            // local_control=true 가 UDP/파일 선점을 막는 동안 local 이 목표 0 으로 슬루를 시작하고
            // (완만 정지, 급정지 아님), 1501ms 이후 소유권은 끊김 없이 이어진다.
            bool local_fs_slew =
                (m_active_source == SRC_LOCAL &&
                 m_gamepad.PollFailsafe(now_ms) == Robotis::GP_FS_SLEW_ZERO);

            // ── O1 워치독 티어 (G3) — 매 루프. 600ms: 진폭 0 슬루(제자리 걸음, 토크 유지),
            //    2.5s: Walking::Stop()(토크 유지 — 컷은 E-STOP 만). 5s STALE 은 위의 backstop.
            //    **[HIGH] 티어는 스트림(UDP 슬롯) 소스 전용** — 파일 소스(dedup·변경시만 송신)는
            //    제외(일정 스틱 홀드 회귀 방지). WatchdogDecision 이 from_stream 으로 게이팅.
            if (m_last_cmd_ms > 0) {
                Robotis::WatchdogAction wd = Robotis::WatchdogDecision(
                    now_ms - m_last_cmd_ms, walking_active, m_last_cmd_from_stream);
                if (wd == Robotis::WD_SLEW_ZERO) {
                    // **codex P2 r2 fix (2026-06-12)**: local ②③티어 활성 중엔 스냅을
                    // 양보 — 티어(목표 0)+루프 슬루 램프가 완만한 정지를 소유한다.
                    // 종전엔 local 유실 후 600ms 에 이 스냅이 램프를 선점해 잔여
                    // 진폭(~22mm)을 1루프에 0 으로 떨어뜨렸다. WD_STOP(2.5s) 백스톱과
                    // UDP 스트림 유실 경로(즉시 0 — O1 의미)는 불변.
                    if (!local_fs_slew) ForceSlewZero(walking);
                } else if (wd == Robotis::WD_STOP) {
                    if (walking_active) {
                        printf("[WalkLabBrokerage] watchdog stale — auto stop (torque held)\n");
                        walking->Stop();
                        walking_active = false;
                    }
                    // **볼-추종(2026-06-14, 리뷰 CRITICAL-1)**: 명령 stale 안전정지 시 자동
                    // 추종 해제 — follower 가 다음 카메라 프레임에 보행을 재개해 정지를 무효화
                    // 하지 못하게(재개하려면 START 재토글). 평시엔 패드 refresh 로 미발화.
                    m_ballfollow_enabled = false;
                }
            }

            // ── H2 ②③티어 (2026-06-12) — local 노드 소멸(inputSourceLost)/이벤트 침묵
            //    ≥1.5s(단절 의심): 진폭 제자리 슬루. local 이 마지막 활성 소스일 때만
            //    (유휴 패드가 Mac/Switch 주행을 정지시키지 않도록). disarm 아님 — 오발
            //    (정속 직진 이벤트 침묵) 비용 = 완만한 정지. Stop 은 워치독 WD_STOP
            //    (2.5s)·5s STALE 이 이어받는다(티어 합류). ①티어(release 합성→데드맨
            //    해제)는 이벤트 경로(enabled=0 라인)가 즉시 소화.
            //    **codex P2 fix (2026-06-12)**: 목표만 0 — 워치독 스냅(ForceSlewZero)과
            //    달리 슬루 상태는 유지해 아래 "루프 측 슬루 전진"이 SLEW_*_MAX 로 램프
            //    다운(스펙의 "완만한 정지" — 풀스트라이드 1루프 스냅 방지).
            if (local_fs_slew && walking_active) {
                m_tgt_x = 0.0; m_tgt_y = 0.0; m_tgt_a = 0.0;
                // **codex P2 fix**: local 신선 창까지 만료됐으면 파일 보유 명령의
                // 재적용을 허용(소비 표시 리셋) — 파일(dedup) 소스는 변경이 없으면
                // 재적용 기회가 없어 active_source 가 local 에 고착, Mac 의 보유
                // 명령으로 제어가 복귀하지 못한다. 재적용되면 SRC_FILE 로 전환되며
                // 이 블록은 자연히 비활성화(UDP 는 새 datagram 도착 즉시 전환).
                if (!local_control) {
                    memset(&last_stat, 0, sizeof(last_stat));
                }
            }

            // ── O2 [HIGH fix] 루프 측 슬루 전진 — 슬루는 명령 도착(ApplyCommandLine)에서만
            //    전진하면, 단발 명령(파일 경로 Mac 브리지 dedup·키보드 정확값)은 재송신이 없어
            //    진폭이 첫 스텝(예: 0→38 명령 시 8mm)에 영구 고착한다. 여기서 보행 중·미도달·
            //    cadence 충족 시 1스텝 더 전진시켜 목표까지 램프(UDP 스트림은 명령마다 전진하므로
            //    이미 정상 — 이 블록은 주로 단발/저빈도 소스를 구제). 워치독 WD_SLEW_ZERO 가
            //    목표·슬루를 모두 0 으로 동기화했으면 SlewAtTarget==true 라 자연히 no-op.
            if (walking_active && m_slew.valid &&
                !Robotis::SlewAtTarget(m_slew, m_tgt_x, m_tgt_y, m_tgt_a, m_tgt_period) &&
                Robotis::SlewCadenceDue(now_ms, m_last_slew_ms, m_tgt_period)) {
                double sx = m_tgt_x, sy = m_tgt_y, sa = m_tgt_a, sp = m_tgt_period;
                Robotis::SlewToward(&m_slew, &sx, &sy, &sa, &sp);
                m_last_slew_ms = now_ms;
                WriteShapedCommand(walking, sx, sy, sa, sp);
            }

            // 볼 트래킹 (2026-06-02): enabled 면 매 poll 카메라+BallTracker 로 헤드를 움직인다.
            // 보행 여부와 무관 (헤드 전용). e-stop/getup 은 위에서 continue 하므로 여기 미도달.
            // **볼-추종 보행 (2026-06-14)**: balltrack 값 2(START)면 m_ballfollow_enabled — 머리
            // 추적 직후 BallFollower 로 공을 향해 보행. ARM 필요(미ARM 자동보행 금지·안전).
            // 수동 Start/Stop 은 ApplyCommandLine 에서 억제됨 → follower 가 Walking 을 소유.
            if (m_balltrack_enabled) {
                ProcessBallTracking();
                if (m_ballfollow_enabled) {
                    if (m_gamepad.Armed()) {
                        ProcessBallFollow(walking, walking_active);
                    } else {
                        if (walking->IsRunning()) walking->Stop();
                        walking_active = false;
                    }
                }
            }

            // **v1.12 (§A) + UDP push (2026-06-03)** — telemetry uplink.
            // UDP 는 매 poll 전송(1 RTT 신선도). O1 supervisor 주기상 **보행 중 ~50Hz**(20ms)·
            // 정지/유휴 ~10Hz(100ms)·볼트래킹 ~30Hz(카메라 페이스). 파일은 종전대로 200ms(5Hz)
            // gate(SSH fallback·디스크 churn 억제). now_ms 는 루프 상단에서 계산됨.
            bool write_tel_file = (now_ms - last_tel_ms >= TELEMETRY_INTERVAL_MS);
            if (write_tel_file) last_tel_ms = now_ms;
            WriteTelemetry(cm730, walking, walking_active, write_tel_file);

            // **헤드 트래킹 30fps fix (2026-06-02)**: 볼 트래킹 중에는 ProcessBallTracking 의
            // LinuxCamera::CaptureFrame() 가 카메라 프레임레이트(~30fps ≈ 33ms)로 루프를 paces 한다
            // — 기본 SOCCER 데모와 동일 구조. 여기에 100ms usleep 을 더하면 ~7fps 로 떨어져 헤드가
            // 버벅이고 반응이 느려진다(사용자 보고). 트래킹 중엔 usleep 생략 → 카메라 자연 페이스로
            // 부드러운 추적. e-stop/getup/command 검사도 30Hz 로 더 자주 돌아 반응성도 향상.
            // 볼 트래킹 OFF 일 때만 sleep. **O1**: 보행 중 20ms(SUPERVISOR_WALK_MS, 실효율
            // ≥20Hz) / 정지·유휴 100ms(CPU 절약). 볼트래킹은 카메라 페이스(usleep 생략).
            if (!m_balltrack_enabled) {
                // 실기 F11 (2026-06-13) — 레이턴시: 게임패드 입력이 신선(≤1.5s)하면
                // 유휴에도 20ms 루프. 종전엔 정지 상태의 첫 스틱 입력이 평균 50ms
                // (최대 100ms) 동안 슬롯에서 대기했다 — 기동 체감 지연의 주범.
                // **하드닝 B1/P0-1 (2026-06-14)**: 패드가 연결돼 있으면(DevicePresent)
                // 유휴(신선창 만료 후)에도 20ms 유지 — 1초 이상 무입력 후 첫 스틱
                // 이벤트의 worst-case 지연을 100ms→~20ms 로 축소(reader→슬롯 가시성은
                // mutex 보장이나 wake 프리미티브가 없어 ~20ms 잔존; 이벤트구동 wake 는
                // 2단계, 측정 후 우선순위 재평가 — 1단계로 운동수행 임계 충족). 부하는
                // balltrack OFF·미조종 구간 한정(balltrack ON 은 카메라 페이스, 보행 중은
                // 이미 20ms). 패드 미연결이면 종전대로 100ms(CPU 절약 불변).
                bool local_fresh = m_gamepad.HasControl(now_ms);
                bool pad_present = m_gamepad.DevicePresent();
                int sleep_ms = (walking_active || local_fresh || pad_present)
                                   ? SUPERVISOR_WALK_MS : POLL_INTERVAL_MS;
                usleep(sleep_ms * 1000);
            }
        }
    }

    bool WalkLabBrokerage::ParseAndApply(Robot::Walking* walking, bool& walking_active,
                                         long long now_ms) {
        FILE* fp = fopen(CMD_PATH, "r");
        if (!fp) return false;

        char line[256];
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp);
            return false;
        }
        fclose(fp);
        return ApplyCommandLine(walking, walking_active, line, now_ms);
    }

    // 진폭 즉시 0 + 슬루 0 동기화 — 워치독 WD_SLEW_ZERO 전용(O1 기존 의미 그대로
    // 추출). 명령 복귀 시 0 에서 다시 램프(급가속 방지). H2 ②③티어는 목표만 0 으로
    // 두고 루프 슬루가 램프 다운한다(codex P2 fix — 동작 차이 의도적).
    void WalkLabBrokerage::ForceSlewZero(Robot::Walking* walking) {
        walking->X_MOVE_AMPLITUDE = 0.0;
        walking->Y_MOVE_AMPLITUDE = 0.0;
        walking->A_MOVE_AMPLITUDE = 0.0;
        m_slew.x = 0.0; m_slew.y = 0.0; m_slew.a = 0.0;
        m_tgt_x = 0.0; m_tgt_y = 0.0; m_tgt_a = 0.0;
    }

    // **O1 (2026-06-12)** — 파일 경로와 UDP 슬롯 경로가 공유하는 단일 적용 함수.
    // 파싱·클램프는 WalkLabTransport::ParseCommandLine(순수, 호스트 단위 테스트됨)에 위임 —
    // 양 경로가 동일 의미로 적용됨을 보장(중복 제거). 명령 라인 형식(cmd_id 포함 14 token,
    // backward-compat 13/6 token)은 §C 와 동일.
    // **O2 [HIGH fix]** — 슬루 후 진폭에 게이트 부스트를 얹어 Walking 에 대입하는 공유 지점.
    // ApplyCommandLine(명령 도착)·supervisor 루프 슬루 진행 양쪽이 호출. 게이트 부스트는
    // 보관된 비-슬루 목표(m_tgt_flags)와 슬루 진폭(sx)으로 재계산 — 루프 진행 시에도 일관.
    void WalkLabBrokerage::WriteShapedCommand(Robot::Walking* walking,
                                              double sx, double sy, double sa, double sp) {
        // P6 gate-on-y — 슬루 후 횡진폭 sy 를 전달해 순수 strafe 도 발 클리어런스·sway boost.
        Robotis::GateBoost boost = Robotis::GateSchedule(sx, sy, sp, m_tgt_flags);
        // supervisor 단일 writer(§c 스레드 안전). 셰이핑(거버너→슬루→게이트)을 통과한 값.
        walking->X_MOVE_AMPLITUDE = sx;
        walking->Y_MOVE_AMPLITUDE = sy;
        walking->A_MOVE_AMPLITUDE = sa;
        walking->Z_MOVE_AMPLITUDE = m_tgt_foot + boost.z_move;
        walking->PERIOD_TIME      = sp;
        walking->HIP_PITCH_OFFSET = m_tgt_hip + boost.hip;
        walking->Y_SWAP_AMPLITUDE = m_yswap_base + boost.y_swap;  // [MEDIUM fix] config base.
        // O4 — 래치값 기록(TEL2 x/y/a/period_lat). 게이트 부스트는 측정 셰이핑 후 진폭만 표시
        // (z_move/y_swap/hip 부스트는 별도 노출 안 함 — "명령 vs 적용" 차이는 x/y/a/period 로 충분).
        m_lat_x = sx; m_lat_y = sy; m_lat_a = sa; m_lat_period = sp;
    }

    bool WalkLabBrokerage::ApplyCommandLine(Robot::Walking* walking, bool& walking_active,
                                            const char* line, long long now_ms) {
        Robotis::WalkCommand cmd;
        if (!Robotis::ParseCommandLine(line, &cmd)) {
            return false;   // 파싱 실패 — 이전 명령 유지(safety).
        }

        // ── O2 (1) 결합 엔벨로프 거버너 — 로봇이 소유하는 **최종 클램프**(G6). v1/v2·전
        //    클라이언트(Switch 50mm 무클램프 포함)에 동일 적용. 거버너 후 값이 목표가 된다.
        double gx = cmd.x, gy = cmd.y, ga = cmd.a;
        Robotis::GovernEnvelope(&gx, &gy, &ga, cmd.period);
        m_tgt_x = gx; m_tgt_y = gy; m_tgt_a = ga; m_tgt_period = cmd.period;
        // 게이트 부스트 재계산용 비-슬루 목표 보관(루프 슬루 진행이 공유) — [HIGH fix].
        m_tgt_foot = cmd.foot; m_tgt_hip = cmd.hip; m_tgt_flags = cmd.flags;

        // 정지→보행 전환이면 슬루를 0 에서 재시드 — 첫걸음을 SLEW_*_MAX 로 램프(정지 후
        //    잔존 슬루값에서 출발해 즉시 풀스트라이드로 시작하는 capturability 위험 차단).
        if ((cmd.enabled != 0) && !walking_active) {
            m_slew.x = 0.0; m_slew.y = 0.0; m_slew.a = 0.0; m_slew.period = cmd.period;
            m_slew.valid = true;
            m_last_slew_ms = 0;   // 첫 전진 즉시 허용.
        }

        // ── O2 (2) 래치 단위 슬루 — 셰이핑 일원화(Mac EMA 완화분을 로봇이 흡수). 슬루는
        //    래치(반주기) cadence 로만 1스텝 전진; 래치 사이의 명령은 직전 슬루값을 재적용.
        //    (첫 적용은 SlewState.valid=false → 즉시 수용; 이후 SLEW_*_MAX 로 가속 제한.)
        //    cadence 판정은 루프 측 진행과 공유하는 순수 함수(SlewCadenceDue).
        bool advance = (!m_slew.valid) ||
                       Robotis::SlewCadenceDue(now_ms, m_last_slew_ms, m_tgt_period);
        double sx = m_tgt_x, sy = m_tgt_y, sa = m_tgt_a, sp = m_tgt_period;
        if (advance) {
            Robotis::SlewToward(&m_slew, &sx, &sy, &sa, &sp);
            m_last_slew_ms = now_ms;
        } else {
            // 전진 시점이 아니면 직전 슬루값 유지(목표는 갱신돼 있음 — 다음 래치에 반영).
            sx = m_slew.x; sy = m_slew.y; sa = m_slew.a; sp = m_slew.period;
        }

        // ── O2 (5) 셰이핑-대입 — 게이트 스케줄 가산 후 Walking 에 대입(루프 진행과 공유).
        WriteShapedCommand(walking, sx, sy, sa, sp);

        // ── O2 (4) 죽은 토큰 결선 (G7 일부) — blevel(0..3)→게인 ×{0,0.5,1.0,1.5}.
        //    출하 게인(BASE_*)에 배율 곱(누적 방지 — 현재값 곱하면 매 명령 발산).
        //    **밸런스 enable = blevel 단일 소스**(설계 "blevel 로 단일화"): 배율>0 이면 ON.
        //    benable/bgain 토큰은 deprecated — *enable 을 benable 에 직결하지 않는다*. 이유:
        //    배포된 Mac 의 benable 기본값=0 이라 직결하면 매 기본 명령이 자이로 밸런스를 끄게
        //    되는데, 종전엔 Walking 기본(BALANCE_ENABLE=true)으로 **항상 켜져** 있었다 →
        //    직결은 보행 중 밸런스 OFF(낙상) 회귀. blevel 기본 2(×1.0)면 종전과 동일 게인·ON.
        //    명시적 OFF 는 blevel=0(게인 0 → enable false). (cross-review 주목 지점.)
        double bscale = Robotis::BalanceGainScale(cmd.blevel);
        walking->BALANCE_ENABLE          = (bscale > 0.0);
        walking->BALANCE_KNEE_GAIN        = Robotis::BASE_BALANCE_KNEE_GAIN * bscale;
        walking->BALANCE_ANKLE_PITCH_GAIN = Robotis::BASE_BALANCE_ANKLE_PITCH_GAIN * bscale;
        walking->BALANCE_HIP_ROLL_GAIN    = Robotis::BASE_BALANCE_HIP_ROLL_GAIN * bscale;
        walking->BALANCE_ANKLE_ROLL_GAIN  = Robotis::BASE_BALANCE_ANKLE_ROLL_GAIN * bscale;

        // 볼 트래킹/추종 토글 (edge 처리). **볼-추종(2026-06-14)**: balltrack 0=off,
        // 1=머리추적(X), 2=볼-추종 보행(START). 1·2 모두 머리추적 포함, 2 는 추가로 보행.
        bool want_balltrack = (cmd.balltrack >= 1);
        m_ballfollow_enabled = (cmd.balltrack == 2);
        if (want_balltrack && !m_balltrack_prev && m_ball_finder) {
            ReloadBallColor();
            printf("[WalkLabBrokerage] ball color reloaded from %s\n", BALLCOLOR_INI);
        }
        if (!want_balltrack && m_balltrack_prev) {
            m_scanning = false;
            m_noball_count = 0;
            m_track_valid = false;
            m_found_streak = 0;
            m_limit_stuck = 0;
            Robot::Head* h = Robot::Head::GetInstance();
            if (h) h->InitTracking();
        }
        m_balltrack_prev = want_balltrack;
        m_balltrack_enabled = want_balltrack;

        // head 적용 (default pose 보존: 한 번도 non-zero 미수신이면 skip). 볼트래킹 ON 이면
        // ProcessBallTracking 이 Head 를 소유 → Mac head 무시.
        if (cmd.head_explicit) m_head_commanded = true;
        if (m_head_commanded && !m_balltrack_enabled) {
            Robot::Head* head = Robot::Head::GetInstance();
            if (head) head->MoveByAngle(cmd.head_pan, cmd.head_tilt);
        }

        // enabled 토글 — Start/Stop edge 감지. **볼-추종(2026-06-14)**: 추종 모드에선
        // BallFollower 가 Walking Start/Stop 을 소유하므로 수동 Start/Stop 억제(stop↔start
        // 매 루프 충돌 방지). 진폭은 위 WriteShapedCommand 가 중립(0)으로 두고 ProcessBallFollow
        // 가 루프 말미에 공 추종값으로 덮어쓴다(슬루는 중립 0 추종 → 추종 해제 시 깨끗).
        if (!m_ballfollow_enabled) {
            bool want_active = (cmd.enabled != 0);
            // **D-패드 앉음(2026-06-14)** — 앉은 채 보행 Start 금지(먼저 D-패드 위로 STAND).
            // 앉은 자세에서 walk 진입은 불안정/낙상 위험. STAND 가 m_sitting 을 해제한다.
            if (want_active && !walking_active && m_sitting) {
                static long long last_sit_warn = 0;
                if (now_ms - last_sit_warn > 1000) {
                    printf("[WalkLabBrokerage] 앉은 상태 — 보행 무시(먼저 D-패드 위로 일어서기)\n");
                    last_sit_warn = now_ms;
                }
            } else if (want_active && !walking_active) {
                walking->Start();
                walking_active = true;
                printf("[WalkLabBrokerage] start (x=%.2f y=%.2f a=%.2f p=%.0f f=%.0f h=%.2f)\n",
                       cmd.x, cmd.y, cmd.a, cmd.period, cmd.foot, cmd.hip);
            } else if (!want_active && walking_active) {
                walking->Stop();
                walking_active = false;
                printf("[WalkLabBrokerage] stop\n");
            }
        }

        // O0 계측 — 적용된 cmd_id 보존(TEL last_cmd_id 토큰 → Mac 폐루프 확인).
        strncpy(m_last_cmd_id, cmd.cmd_id, sizeof(m_last_cmd_id) - 1);
        m_last_cmd_id[sizeof(m_last_cmd_id) - 1] = '\0';

        // ACK write — "OK {ts_ms} {cmd_id} {line}" atomic(tmp+rename). Mac 이 cmd_id 매치.
        const char* ack_tmp = "/tmp/df-walklab-ack.tmp";
        FILE* ack = fopen(ack_tmp, "w");
        if (ack) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            long long ts_ms = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
            fprintf(ack, "OK %lld %s %s", ts_ms, cmd.cmd_id, line);
            fclose(ack);
            rename(ack_tmp, ACK_PATH);
        }
        return true;
    }

    // ===== Telemetry writer (§A / O4 §A.2-TEL2) =================================
    // cm730 의 bulk-read 버퍼(motion loop 가 8ms 마다 갱신)에서 voltage + 3축 raw IMU + FSR 을
    // 추가 bus 트래픽 없이 read. cm730 NULL 이면 MotionStatus 로 graceful degrade.
    //  · **파일**(write_file=true, 5Hz gate): TEL v1 형식 그대로 — SSH 폴백·구버전 Mac 호환
    //    (영구 폴백 불변식). tmp + rename atomic.
    //  · **UDP**(30Hz gate, TEL2_UDP_INTERVAL_MS): TEL2(v2) — 위상·래치 진폭·FSR/CoP·seq_applied·
    //    active_source. 비차단·실패 무음. E-STOP·워치독 경로 무영향(여기선 read·송신만).
    void WalkLabBrokerage::WriteTelemetry(Robot::CM730* cm730, Robot::Walking* walking,
                                          bool walking_active, bool write_file) {
        int gx, gy, gz, ax, ay, az, vdV;

        if (cm730) {
            // §A.1 — bulk-read 버퍼의 raw 10-bit ADC word (center-subtract 안 됨).
            Robot::BulkReadData& cm = cm730->m_BulkReadData[Robot::CM730::ID_CM];
            gx = ClampAdc(cm.ReadWord(Robot::CM730::P_GYRO_X_L));
            gy = ClampAdc(cm.ReadWord(Robot::CM730::P_GYRO_Y_L));
            gz = ClampAdc(cm.ReadWord(Robot::CM730::P_GYRO_Z_L));
            ax = ClampAdc(cm.ReadWord(Robot::CM730::P_ACCEL_X_L));
            ay = ClampAdc(cm.ReadWord(Robot::CM730::P_ACCEL_Y_L));
            az = ClampAdc(cm.ReadWord(Robot::CM730::P_ACCEL_Z_L));
            vdV = cm.ReadByte(Robot::CM730::P_VOLTAGE);   // deci-volts (e.g. 122=12.2V)
            if (vdV < 0) vdV = 0;   // read 실패(-1) → unknown.
        } else {
            // §A.1 fallback — MotionStatus 의 2 gyro + 2 accel 만 가용. center-subtracted
            // gyro 는 0-center → +512 로 raw ADC 호환 형태로 환원. voltage 는 unknown(0).
            gx = ClampAdc(Robot::MotionStatus::RL_GYRO + 512);
            gy = ClampAdc(Robot::MotionStatus::FB_GYRO + 512);
            gz = 0;
            ax = ClampAdc(Robot::MotionStatus::RL_ACCEL);
            ay = ClampAdc(Robot::MotionStatus::FB_ACCEL);
            az = 512;
            vdV = 0;   // unknown → Mac 가 L0 voltage gate 발동 금지 (§A.1).
        }

        int fallen = Robot::MotionStatus::FALLEN;   // -1 back / 0 up / 1 fwd
        int walking01 = walking_active ? 1 : 0;

        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        long long ts_ms = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;

        // ── 파일: TEL v1 (5Hz gate) — 영구 폴백·구버전 호환(형식 무변경, §A.2 v1).
        //   "TEL {ts} {gx} {gy} {gz} {ax} {ay} {az} {vdV} {w} {fallen} {last_cmd_id} {loop_ms}\n"
        if (write_file) {
            char buf[160];
            int n = snprintf(buf, sizeof(buf), "TEL %lld %d %d %d %d %d %d %d %d %d %s %lld\n",
                             ts_ms, gx, gy, gz, ax, ay, az, vdV, walking01, fallen,
                             m_last_cmd_id, m_loop_ms);
            if (n > 0) {
                if (n > (int)sizeof(buf)) n = (int)sizeof(buf);   // truncation guard.
                const char* tel_tmp = "/tmp/df-walklab-telemetry.tmp";
                FILE* fp = fopen(tel_tmp, "w");
                if (fp) {
                    fwrite(buf, 1, (size_t)n, fp);
                    fclose(fp);
                    rename(tel_tmp, TELEMETRY_PATH);   // atomic (같은 filesystem 보장).
                }
            }
        }

        // ── UDP: TEL2 (30Hz gate). 종전 매 poll(~50Hz) push 를 정식화.
        if (ts_ms - m_last_udp_tel_ms < TEL2_UDP_INTERVAL_MS) return;
        m_last_udp_tel_ms = ts_ms;

        // FSR — m_BulkReadData[FSR::ID_L/R_FSR] (8ms 벌크리드에 이미 포함, 추가 버스 0).
        //   error==0 = 유효 read(둘 다 장착·PING 성공). 미장착(OP1/PING 실패)·NULL → "-" 토큰.
        bool fsr_present = false, cop_present = false;
        int fsr8[8] = {0,0,0,0,0,0,0,0};
        int copx = 0, copy = 0;
        if (cm730) {
            Robot::BulkReadData& fl = cm730->m_BulkReadData[Robot::FSR::ID_L_FSR];
            Robot::BulkReadData& fr = cm730->m_BulkReadData[Robot::FSR::ID_R_FSR];
            if (fl.error == 0 && fr.error == 0) {
                fsr_present = true;
                fsr8[0] = fl.ReadWord(Robot::FSR::P_FSR1_L);
                fsr8[1] = fl.ReadWord(Robot::FSR::P_FSR2_L);
                fsr8[2] = fl.ReadWord(Robot::FSR::P_FSR3_L);
                fsr8[3] = fl.ReadWord(Robot::FSR::P_FSR4_L);
                fsr8[4] = fr.ReadWord(Robot::FSR::P_FSR1_L);
                fsr8[5] = fr.ReadWord(Robot::FSR::P_FSR2_L);
                fsr8[6] = fr.ReadWord(Robot::FSR::P_FSR3_L);
                fsr8[7] = fr.ReadWord(Robot::FSR::P_FSR4_L);
                // 전신 CoP 근사 = 접지한 발의 FSR_X/Y 바이트 평균. 바이트 255 = 무접지 →
                // 평균에서 제외(둘 다 무접지면 cop "-"). 발별 정밀 CoP 는 Mac 이 셀에서 재구성.
                int lx = fl.ReadByte(Robot::FSR::P_FSR_X), ly = fl.ReadByte(Robot::FSR::P_FSR_Y);
                int rx = fr.ReadByte(Robot::FSR::P_FSR_X), ry = fr.ReadByte(Robot::FSR::P_FSR_Y);
                int cnt = 0, sxv = 0, syv = 0;
                if (lx >= 0 && lx < 255) { sxv += lx; syv += ly; cnt++; }
                if (rx >= 0 && rx < 255) { sxv += rx; syv += ry; cnt++; }
                if (cnt > 0) { cop_present = true; copx = sxv / cnt; copy = syv / cnt; }
            }
        }

        int phase = walking ? walking->GetCurrentPhase() : -1;   // 공식 getter(Walking.h:139).
        // H2-4 — active_source: 마지막 적용 소스(local/udp/file). TEL v1 파일 포맷 불변.
        const char* src = (m_active_source == SRC_LOCAL) ? "local"
                          : (m_active_source == SRC_UDP) ? "udp" : "file";

        // 하드닝 B3 — armed/estop_latched 관찰가능성(IEC 60204-1 §10.3). estop latch 는
        // flag 파일 존재(EstopRequested)로 판정 — supervisor 의 estop_latched 로컬과 동치.
        int gp_armed = m_gamepad.Armed() ? 1 : 0;
        int gp_estop_latched = EstopRequested() ? 1 : 0;
        char tbuf[320];
        int tn = Robotis::FormatTel2(tbuf, sizeof(tbuf),
                                     ts_ms, m_last_seq_applied, phase,
                                     m_lat_x, m_lat_y, m_lat_a, m_lat_period,
                                     gx, gy, gz, ax, ay, az,
                                     fsr_present, fsr8,
                                     cop_present, copx, copy,
                                     fallen, /*risk_present*/ false, 0.0,  // risk: O3 미구현 "-".
                                     vdV, src, m_loop_ms,
                                     gp_armed, gp_estop_latched);
        if (tn > 0) {
            if (tn > (int)sizeof(tbuf)) tn = (int)sizeof(tbuf);   // truncation guard.
            SendTelemetryUDP(tbuf, tn);   // 비차단·실패 무음.
        }
    }

    // ===== UDP 텔레메트리 업링크 (2026-06-03) ===================================
    // Mac 이 UPLINK_PATH 에 "IP PORT" 를 쓰면 로봇이 매 poll 그 주소로 TEL 라인을 UDP push.
    // SSH cat 폴링(≈2Hz) 대비 10–30Hz·1 RTT. 전부 비차단·실패 무음 (텔레메트리는 lossy 허용;
    // 신뢰 경로인 명령/ACK/e-stop 은 파일+SSH 그대로 — 안전 영향 없음).

    // UPLINK_PATH("IP PORT")를 ~1s 마다 read 해 타깃 갱신. 타깃은 거의 안 바뀌므로 throttle.
    void WalkLabBrokerage::RefreshUplinkTarget(long long now_ms) {
        if (m_last_uplink_ms != 0 && (now_ms - m_last_uplink_ms) < UPLINK_REFRESH_MS) return;
        m_last_uplink_ms = now_ms;
        FILE* fp = fopen(UPLINK_PATH, "r");
        if (!fp) return;   // 없음 → 기존 타깃 유지(또는 미설정 → UDP no-op, 파일 fallback).
        char ip[64];
        int port = 0;
        ip[0] = 0;
        if (fscanf(fp, "%63s %d", ip, &port) == 2 && port > 0 && port <= 65535) {
            strncpy(m_uplink_ip, ip, sizeof(m_uplink_ip) - 1);
            m_uplink_ip[sizeof(m_uplink_ip) - 1] = 0;
            m_uplink_port = port;
        }
        fclose(fp);
    }

    // UDP 소켓 lazy-open (비차단). 실패해도 -1 유지 → 다음에 재시도(파일+SSH fallback).
    void WalkLabBrokerage::EnsureUdpSocket() {
        if (m_udp_fd >= 0) return;
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return;
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);   // belt-and-suspenders.
        m_udp_fd = fd;
    }

    // telemetry 한 줄을 업링크 타깃으로 UDP 전송. 비차단 sendto — realtime 루프를 절대 막지
    // 않는다. 반환값 무시(EAGAIN/ENETUNREACH 등 전부 조용히 drop — UDP 는 lossy 허용).
    void WalkLabBrokerage::SendTelemetryUDP(const char* line, int len) {
        if (m_uplink_port <= 0 || m_uplink_ip[0] == 0) return;   // 타깃 미설정.
        EnsureUdpSocket();
        if (m_udp_fd < 0) return;
        struct sockaddr_in dst;
        memset(&dst, 0, sizeof(dst));
        dst.sin_family = AF_INET;
        dst.sin_port = htons((unsigned short)m_uplink_port);
        dst.sin_addr.s_addr = inet_addr(m_uplink_ip);
        if (dst.sin_addr.s_addr == INADDR_NONE) return;   // 잘못된 IP 문자열.
        (void)sendto(m_udp_fd, line, (size_t)len, MSG_DONTWAIT,
                     (struct sockaddr*)&dst, sizeof(dst));
    }

}  // namespace Robotis
