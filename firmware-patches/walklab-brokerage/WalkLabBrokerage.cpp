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
#include <sys/stat.h>
#include "Walking.h"        // Robot::Walking::GetInstance()
#include "Head.h"           // Robot::Head::GetInstance()
#include "CM730.h"          // Robot::CM730 register map + bulk-read buffer
#include "MotionStatus.h"   // Robot::MotionStatus (IMU fallback + FALLEN)
#include "MotionManager.h"
#include "Action.h"         // **v1.13** Robot::Action (getup 모션 player)
// 볼 트래킹 (2026-06-02) — 온보드 자동 헤드 추적 (기본 데모와 동일 vision 파이프라인).
#include "LinuxCamera.h"    // Robot::LinuxCamera::GetInstance() — main.cpp 가 이미 Initialize
#include "ColorFinder.h"    // Robot::ColorFinder — HSV 볼 검출
#include "BallTracker.h"    // Robot::BallTracker — 볼 위치 → Head::MoveTracking
#include "Point.h"          // Robot::Point2D

namespace Robotis {

    // C++03: 정적 멤버 클래스 외부 정의 (로봇 g++ 는 constexpr 미지원)
    const char* const WalkLabBrokerage::CMD_PATH = "/tmp/df-walklab-cmd";
    const char* const WalkLabBrokerage::ACK_PATH = "/tmp/df-walklab-ack";
    const char* const WalkLabBrokerage::TELEMETRY_PATH = "/tmp/df-walklab-telemetry";
    const char* const WalkLabBrokerage::ESTOP_PATH = "/tmp/df-walklab-estop";
    const double WalkLabBrokerage::HIP_PITCH_MIN = 0.0;
    const double WalkLabBrokerage::HIP_PITCH_MAX = 20.0;

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
            WriteTelemetry(cm730, walking_active);
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
            WriteTelemetry(cm730, walking_active);
            usleep(8000);
        }

        // 4) 모션 완료 대기. (telemetry 계속 write.)
        while (action->IsRunning()) {
            // 리뷰(codex C1) fix: getup 모션 중 e-stop → 모션 중단(Stop) + body torque off.
            if (EstopRequested()) { action->Stop(); action->m_Joint.SetEnableBody(false, true); m_fall_count = 0; return true; }
            WriteTelemetry(cm730, walking_active);
            usleep(8000);
        }

        // 5) joint 을 Walking/Head 로 반납 — Run() 초기 enable 과 동일 패턴.
        Robot::Head* head = Robot::Head::GetInstance();
        if (head) head->m_Joint.SetEnableHeadOnly(true, true);
        walking->m_Joint.SetEnableBodyWithoutHead(true, true);

        m_fall_count = 0;   // 복구 완료 — 카운터 reset.
        printf("[WalkLabBrokerage] getup complete — joints returned to Walking, idle\n");
        return true;   // 보행은 정지 유지 — 다음 Mac 명령까지 대기.
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
    void WalkLabBrokerage::ProcessBallTracking() {
        if (!m_vision_ready) {
            // 기본 생성자 = 주황 공 (ROBOTIS 표준 데모 ball). config.ini 튜닝 없이도 동작.
            m_ball_finder = new Robot::ColorFinder();
            m_tracker = new Robot::BallTracker();
            m_vision_ready = true;
            printf("[WalkLabBrokerage] ball-tracking vision init (orange ball default)\n");
        }
        Robot::LinuxCamera::GetInstance()->CaptureFrame();
        Robot::Point2D pos = m_ball_finder->GetPosition(
            Robot::LinuxCamera::GetInstance()->fbuffer->m_HSVFrame);
        // 볼 보이면 Head::MoveTracking(offset), 안 보이면 scan/InitTracking (데모와 동일).
        m_tracker->Process(pos);
    }

    void WalkLabBrokerage::Run(Robot::CM730* cm730) {
        m_head_commanded = false;
        m_fall_count = 0;   // **v1.13** auto-getup debounce 카운터 초기화.
        // 볼 트래킹 (2026-06-02) — vision 상태 초기화 (lazy-init 은 첫 enable 시).
        m_balltrack_enabled = false;
        m_vision_ready = false;
        m_ball_finder = 0;
        m_tracker = 0;
        InstallSignalHandlers();

        Robot::Walking* walking = Robot::Walking::GetInstance();
        if (!walking) {
            fprintf(stderr, "WalkLabBrokerage: Walking::GetInstance() == NULL\n");
            return;
        }

        printf("[WalkLabBrokerage] start polling %s every %dms\n",
               CMD_PATH, POLL_INTERVAL_MS);

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

        while (true) {
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
                }
                WriteTelemetry(cm730, walking_active);  // Mac 에 정지 상태 계속 보고.
                usleep(POLL_INTERVAL_MS * 1000);
                continue;   // flag 가 있는 동안 명령 무시.
            } else if (estop_latched) {
                // flag 제거됨 — re-arm 허용. body torque 는 다음 Start() 가 복구.
                printf("[WalkLabBrokerage] E-STOP cleared — re-armed\n");
                estop_latched = false;
                memset(&last_stat, 0, sizeof(last_stat));  // 정지 후 첫 명령 강제 재처리.
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

            struct stat current_stat = {};
            int stat_ret = stat(CMD_PATH, &current_stat);

            if (stat_ret == 0) {
                // **v1.11.16.2 (2026-05-19) — Codex CRITICAL 1 fix**: mtime+size 만으로는
                // 같은 길이 명령이 1초 내 변경 시 미처리. nanosecond mtim 사용 + 매 poll
                // 시 cmd_id 비교로 신뢰성 확보. Linux 의 st_mtim.tv_sec/tv_nsec 사용.
                bool file_changed =
                    (current_stat.st_mtim.tv_sec != last_stat.st_mtim.tv_sec) ||
                    (current_stat.st_mtim.tv_nsec != last_stat.st_mtim.tv_nsec) ||
                    (current_stat.st_size != last_stat.st_size);
                if (file_changed) {
                    last_stat = current_stat;
                    if (ParseAndApply(walking, walking_active)) {
                        last_cmd_time = time(NULL);
                    }
                }

                // Stale check — Mac 명령 5초 이상 안 오면 자동 stop.
                if (walking_active && last_cmd_time > 0 &&
                    (time(NULL) - last_cmd_time) > (STALE_TIMEOUT_MS / 1000)) {
                    printf("[WalkLabBrokerage] stale > %dms — auto stop\n",
                           STALE_TIMEOUT_MS);
                    walking->Stop();
                    walking_active = false;
                }
            } else {
                // 파일 없음 — Mac 측 미연결. polling 만 유지.
                if (walking_active) {
                    walking->Stop();
                    walking_active = false;
                }
                // 볼 트래킹 (2026-06-02): Mac 끊김 → 자동 추적 해제 (헤드 scan 무한지속 방지).
                m_balltrack_enabled = false;
            }

            // 볼 트래킹 (2026-06-02): enabled 면 매 poll 카메라+BallTracker 로 헤드를 움직인다.
            // 보행 여부와 무관 (헤드 전용). e-stop/getup 은 위에서 continue 하므로 여기 미도달.
            if (m_balltrack_enabled) {
                ProcessBallTracking();
            }

            // **v1.12 (§A)** — telemetry uplink. ~200ms(5Hz) 로 gate.
            struct timespec now_ts;
            clock_gettime(CLOCK_REALTIME, &now_ts);
            long long now_ms =
                (long long)now_ts.tv_sec * 1000LL + now_ts.tv_nsec / 1000000LL;
            if (now_ms - last_tel_ms >= TELEMETRY_INTERVAL_MS) {
                last_tel_ms = now_ms;
                WriteTelemetry(cm730, walking_active);
            }

            usleep(POLL_INTERVAL_MS * 1000);
        }
    }

    bool WalkLabBrokerage::ParseAndApply(Robot::Walking* walking, bool& walking_active) {
        FILE* fp = fopen(CMD_PATH, "r");
        if (!fp) return false;

        char line[256];
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp);
            return false;
        }
        fclose(fp);

        // **v1.11.16.2 (2026-05-19) — Codex CRITICAL 1 fix**: cmd_id nonce 첫 token.
        // **v1.12 (2026-06-01) — §C**: balance(3) + head(2) 토큰 추가 → 12 필드.
        // 형식(cmd_id 포함, 13 token):
        //   "{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable} {blevel} {headPan} {headTilt}"
        // backward-compat(cmd_id 없음, 12 token) 및 구형(7 token, hip 까지)도 처리.
        // cmd_id 가 있으면 ACK 에 echo 하여 Mac 이 stale ACK 검출 가능.
        char cmd_id[32] = "no_id";  // default — backward compat
        int enabled = 0;
        float x = 0, y = 0, a = 0, period = 0, foot = 0, hip = 13.0f;
        // **v1.12** — balance 필드(현재 미적용, 토큰 위치 정렬용으로 consume)와 head 필드.
        float bgain = 1.0f; int benable = 0, blevel = 2;
        float head_pan = 0.0f, head_tilt = 0.0f;  // default 0 (keep-last 는 위험).
        // 볼 트래킹 (2026-06-02) — 13번째 필드. 0=off, 1=on. 옛 Mac(12필드)은 미전송 → 0 유지.
        float balltrack = 0.0f;
        // 첫 token 이 숫자가 아니면 cmd_id 로 간주.
        // 시도 1: cmd_id 포함 형식 (최대 14 token — head 2 + ball_track 1).
        int n = sscanf(line, "%31s %d %f %f %f %f %f %f %f %d %d %f %f %f",
                       cmd_id, &enabled, &x, &y, &a, &period, &foot, &hip,
                       &bgain, &benable, &blevel, &head_pan, &head_tilt, &balltrack);
        if (n < 7) {
            // 시도 2: cmd_id 없는 형식 (최대 13 token).
            n = sscanf(line, "%d %f %f %f %f %f %f %f %d %d %f %f %f",
                       &enabled, &x, &y, &a, &period, &foot, &hip,
                       &bgain, &benable, &blevel, &head_pan, &head_tilt, &balltrack);
            if (n < 6) {
                // 잘못된 line 무시 — 이전 명령 유지 (safety).
                return false;
            }
            strcpy(cmd_id, "no_id");
        }
        if (n == 6) {
            // v1.11.5 (6 필드) backward-compat — hip 미전달 시 default 유지.
            hip = walking->HIP_PITCH_OFFSET;
        }

        // hip_pitch_deg clamp [0, 20].
        if (hip < HIP_PITCH_MIN) hip = HIP_PITCH_MIN;
        if (hip > HIP_PITCH_MAX) hip = HIP_PITCH_MAX;

        // **v1.12 (§C)** — head pan/tilt clamp + 적용. Mac 가 이미 clamp 하지만 방어.
        if (head_pan < -90.0f) head_pan = -90.0f;
        if (head_pan >  90.0f) head_pan =  90.0f;
        if (head_tilt < -45.0f) head_tilt = -45.0f;
        if (head_tilt >  45.0f) head_tilt =  45.0f;

        // PERIOD_TIME 갑작스러운 변경은 cycle 중간 불안정 — 다음 cycle 부터 적용 의도지만
        // ROBOTIS Walking.cpp 은 매 8ms tick 의 m_PeriodTime 갱신 → 즉시 반영.
        // (안정성 검증 필요 항목 — TODO.)
        walking->X_MOVE_AMPLITUDE = (double)x;
        walking->Y_MOVE_AMPLITUDE = (double)y;
        walking->A_MOVE_AMPLITUDE = (double)a;
        walking->Z_MOVE_AMPLITUDE = (double)foot;
        walking->PERIOD_TIME = (double)period;
        walking->HIP_PITCH_OFFSET = (double)hip;

        // 볼 트래킹 (2026-06-02) — 모드 토글. ON 이면 로봇이 자체 카메라로 헤드를 제어하므로
        // 아래 Mac head MoveByAngle 을 skip (singleton Head 의 last-write-wins 충돌 방지).
        m_balltrack_enabled = (balltrack > 0.5f);

        // **v1.12 (§C)** — head pan/tilt 적용. walklab injection 이 이미
        // Head::GetInstance()->m_Joint.SetEnableHeadOnly(true,true) 호출함.
        // 한 번도 non-zero head 명령을 받은 적이 없고 둘 다 0 이면, 프레임워크
        // default head pose 보존을 위해 MoveByAngle skip. 그 외엔 항상 적용.
        // **볼 트래킹 ON 이면 Mac head 무시** — ProcessBallTracking 이 Head::MoveTracking 으로
        // 제어한다 (Mac 도 ballTracking 시 head 0 을 보내지만 방어적으로 여기서도 gate).
        bool head_nonzero = (head_pan != 0.0f) || (head_tilt != 0.0f);
        if (head_nonzero) m_head_commanded = true;
        if (m_head_commanded && !m_balltrack_enabled) {
            Robot::Head* head = Robot::Head::GetInstance();
            if (head) head->MoveByAngle((double)head_pan, (double)head_tilt);
        }

        // enabled 토글 — Start/Stop edge 감지.
        bool want_active = (enabled != 0);
        if (want_active && !walking_active) {
            walking->Start();
            walking_active = true;
            printf("[WalkLabBrokerage] start (x=%.2f y=%.2f a=%.2f p=%.0f f=%.0f h=%.2f)\n",
                   x, y, a, period, foot, hip);
        } else if (!want_active && walking_active) {
            walking->Stop();
            walking_active = false;
            printf("[WalkLabBrokerage] stop\n");
        }
        // **v1.11.16.1 (2026-05-19)** — ACK write. Mac 측이 250ms 후 cat 으로 검증.
        // ts_ms = unix epoch * 1000 (간단한 monotonic ID).
        // **v1.11.16.2 — Codex CRITICAL 1 fix**: cmd_id echo 로 stale ACK 검출.
        // 형식: "OK {ts_ms} {cmd_id} {cmd_line}\n" — Mac 의 검출 시 cmd_id 매치.
        // ACK write 도 tmp + rename 으로 atomic (부분 read 차단).
        const char* ack_tmp = "/tmp/df-walklab-ack.tmp";
        FILE* ack = fopen(ack_tmp, "w");
        if (ack) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            long long ts_ms = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
            fprintf(ack, "OK %lld %s %s", ts_ms, cmd_id, line);
            fclose(ack);
            // atomic rename (같은 filesystem 보장).
            rename(ack_tmp, ACK_PATH);
        }
        return true;
    }

    // ===== Telemetry writer (§A) ================================================
    // 매 ~200ms(5Hz) 호출. cm730 의 bulk-read 버퍼(motion loop 가 8ms 마다 갱신)에서
    // voltage + 3축 raw IMU 를 추가 bus 트래픽 없이 read. cm730 NULL 이면 MotionStatus
    // 로 graceful degrade. tmp + rename 으로 atomic write (부분 read 차단).
    void WalkLabBrokerage::WriteTelemetry(Robot::CM730* cm730, bool walking_active) {
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

        // §A.2 PINNED 형식: "TEL {ts} {gx} {gy} {gz} {ax} {ay} {az} {vdV} {w} {fallen}\n"
        const char* tel_tmp = "/tmp/df-walklab-telemetry.tmp";
        FILE* fp = fopen(tel_tmp, "w");
        if (!fp) return;
        fprintf(fp, "TEL %lld %d %d %d %d %d %d %d %d %d\n",
                ts_ms, gx, gy, gz, ax, ay, az, vdV, walking01, fallen);
        fclose(fp);
        rename(tel_tmp, TELEMETRY_PATH);   // atomic (같은 filesystem 보장).
    }

}  // namespace Robotis
