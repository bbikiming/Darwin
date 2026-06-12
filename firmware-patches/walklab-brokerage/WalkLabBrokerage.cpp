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
#include "Point.h"          // Robot::Point2D
#include "Camera.h"         // Robot::Camera::WIDTH/HEIGHT (예측 시 프레임 clamp)
#include "minIni.h"         // Robot::minIni — config 에서 공 색상(HSV) 로드 (싸커 데모와 동일)

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
        Robot::LinuxCamera::GetInstance()->CaptureFrame();
        Robot::Point2D pos = m_ball_finder->GetPosition(
            Robot::LinuxCamera::GetInstance()->fbuffer->m_HSVFrame);

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
        if (raw_found && m_track_valid && !m_scanning && m_noball_count <= GATE_HOLD_FRAMES) {
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
        if (head && m_track_valid && !m_scanning) {
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
            // 즉시 정지(~1–5ms): Walking::Stop + body torque off.
            Robot::Walking* w = Robot::Walking::GetInstance();
            if (w) { w->Stop(); w->m_Joint.SetEnableBody(false); }
            // flag 파일 touch — 기존 latch/re-arm(EstopRequested) 경로가 hold-stopped 소유.
            // UDP estop 은 일회성 datagram → 파일이 상태를 소유(Mac 이 rm 할 때까지 정지 유지).
            int fd = open(ESTOP_PATH, O_CREAT | O_WRONLY, 0644);
            if (fd >= 0) close(fd);
        }
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

    void WalkLabBrokerage::Run(Robot::CM730* cm730) {
        m_head_commanded = false;
        // O0 계측 — last_cmd_id/loop_ms 초기화.
        strcpy(m_last_cmd_id, "no_id");
        m_loop_ms = 0;
        // O1 transport — 멤버 초기화. 핸드셰이크는 루프의 RefreshHandshake 가 1s 내 수용.
        m_last_cmd_ms = 0;
        m_last_cmd_from_stream = false;
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
        m_fall_count = 0;   // **v1.13** auto-getup debounce 카운터 초기화.
        // 볼 트래킹 (2026-06-02) — vision 상태 초기화 (lazy-init 은 첫 enable 시).
        m_balltrack_enabled = false;
        m_balltrack_prev = false;
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
                // 헤드도 정지 + 토크 풀어 사용자가 들고 내릴 수 있게.
                Robot::Head::GetInstance()->m_Joint.SetEnableHeadOnly(false);
                StopTransportThreads();   // O1 — UDP 리스너 정리 후 정상 종료.
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
                }
                WriteTelemetry(cm730, walking, walking_active, true);  // Mac 에 정지 상태 계속 보고(파일+UDP).
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

            // ── O1: UDP latest-wins 슬롯 우선 소비 (이벤트 구동). transport 미기동이면
            //    슬롯은 항상 비어 no-op → 종전 파일 경로 동작 완전 보존.
            {
                char slot_line[256];
                long long slot_seq = 0;
                if (m_cmd_slot.Take(slot_line, sizeof(slot_line), &slot_seq)) {
                    if (ApplyCommandLine(walking, walking_active, slot_line, now_ms)) {
                        last_cmd_time = time(NULL);
                        m_last_cmd_ms = now_ms;
                        m_last_cmd_from_stream = true;   // 스트림 소스 — 워치독 티어 대상.
                        m_last_seq_applied = slot_seq;   // O4 — TEL2 seq_applied 폐루프.
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
                        if (ParseAndApply(walking, walking_active, now_ms)) {
                            last_cmd_time = time(NULL);
                            m_last_cmd_ms = now_ms;
                            m_last_cmd_from_stream = false;  // 파일 소스 — 티어 제외(5s STALE 만).
                        }
                    }

                    // 5s STALE_TIMEOUT — 최후 방어선(워치독 2.5s 가 먼저 발화하므로 backstop).
                    if (walking_active && last_cmd_time > 0 &&
                        (time(NULL) - last_cmd_time) > (STALE_TIMEOUT_MS / 1000)) {
                        printf("[WalkLabBrokerage] stale > %dms — auto stop\n",
                               STALE_TIMEOUT_MS);
                        walking->Stop();
                        walking_active = false;
                    }
                } else {
                    // 파일 없음 — Mac 측 미연결. transport 가 없으면 정지(종전 동작).
                    // transport 활성이면 UDP 가 명령을 공급하므로 파일 부재로 정지하지 않는다
                    // (정지는 워치독 티어가 명령 stale 기준으로 판정).
                    if (!m_transport_running) {
                        if (walking_active) {
                            walking->Stop();
                            walking_active = false;
                        }
                        m_balltrack_enabled = false;   // 헤드 scan 무한지속 방지.
                    }
                }
            }

            // ── O1 워치독 티어 (G3) — 매 루프. 600ms: 진폭 0 슬루(제자리 걸음, 토크 유지),
            //    2.5s: Walking::Stop()(토크 유지 — 컷은 E-STOP 만). 5s STALE 은 위의 backstop.
            //    **[HIGH] 티어는 스트림(UDP 슬롯) 소스 전용** — 파일 소스(dedup·변경시만 송신)는
            //    제외(일정 스틱 홀드 회귀 방지). WatchdogDecision 이 from_stream 으로 게이팅.
            if (m_last_cmd_ms > 0) {
                Robotis::WatchdogAction wd = Robotis::WatchdogDecision(
                    now_ms - m_last_cmd_ms, walking_active, m_last_cmd_from_stream);
                if (wd == Robotis::WD_SLEW_ZERO) {
                    walking->X_MOVE_AMPLITUDE = 0.0;
                    walking->Y_MOVE_AMPLITUDE = 0.0;
                    walking->A_MOVE_AMPLITUDE = 0.0;
                    // O2 — 슬루 상태도 0 동기화: 명령 복귀 시 0 에서 다시 램프(급가속 방지).
                    m_slew.x = 0.0; m_slew.y = 0.0; m_slew.a = 0.0;
                    m_tgt_x = 0.0; m_tgt_y = 0.0; m_tgt_a = 0.0;
                } else if (wd == Robotis::WD_STOP) {
                    if (walking_active) {
                        printf("[WalkLabBrokerage] watchdog stale — auto stop (torque held)\n");
                        walking->Stop();
                        walking_active = false;
                    }
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
            if (m_balltrack_enabled) {
                ProcessBallTracking();
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
                int sleep_ms = walking_active ? SUPERVISOR_WALK_MS : POLL_INTERVAL_MS;
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

    // **O1 (2026-06-12)** — 파일 경로와 UDP 슬롯 경로가 공유하는 단일 적용 함수.
    // 파싱·클램프는 WalkLabTransport::ParseCommandLine(순수, 호스트 단위 테스트됨)에 위임 —
    // 양 경로가 동일 의미로 적용됨을 보장(중복 제거). 명령 라인 형식(cmd_id 포함 14 token,
    // backward-compat 13/6 token)은 §C 와 동일.
    // **O2 [HIGH fix]** — 슬루 후 진폭에 게이트 부스트를 얹어 Walking 에 대입하는 공유 지점.
    // ApplyCommandLine(명령 도착)·supervisor 루프 슬루 진행 양쪽이 호출. 게이트 부스트는
    // 보관된 비-슬루 목표(m_tgt_flags)와 슬루 진폭(sx)으로 재계산 — 루프 진행 시에도 일관.
    void WalkLabBrokerage::WriteShapedCommand(Robot::Walking* walking,
                                              double sx, double sy, double sa, double sp) {
        Robotis::GateBoost boost = Robotis::GateSchedule(sx, sp, m_tgt_flags);
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

        // 볼 트래킹 토글 (edge 처리 — 종전과 동일).
        bool want_balltrack = (cmd.balltrack != 0);
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

        // enabled 토글 — Start/Stop edge 감지.
        bool want_active = (cmd.enabled != 0);
        if (want_active && !walking_active) {
            walking->Start();
            walking_active = true;
            printf("[WalkLabBrokerage] start (x=%.2f y=%.2f a=%.2f p=%.0f f=%.0f h=%.2f)\n",
                   cmd.x, cmd.y, cmd.a, cmd.period, cmd.foot, cmd.hip);
        } else if (!want_active && walking_active) {
            walking->Stop();
            walking_active = false;
            printf("[WalkLabBrokerage] stop\n");
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
        const char* src = m_last_cmd_from_stream ? "udp" : "file";   // H2 active_source.

        char tbuf[320];
        int tn = Robotis::FormatTel2(tbuf, sizeof(tbuf),
                                     ts_ms, m_last_seq_applied, phase,
                                     m_lat_x, m_lat_y, m_lat_a, m_lat_period,
                                     gx, gy, gz, ax, ay, az,
                                     fsr_present, fsr8,
                                     cop_present, copx, copy,
                                     fallen, /*risk_present*/ false, 0.0,  // risk: O3 미구현 "-".
                                     vdV, src, m_loop_ms);
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
