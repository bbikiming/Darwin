/*
 * GamepadPilot.cpp — RG G01 2.4G 동글 온보드 직결 파일럿 (H1+H2)
 *
 * 헤더(GamepadPilot.h)의 계약 구현. 순수 로직은 Robot:: 의존 0 — 호스트 단위
 * 테스트(tests/test_gamepad.cpp). 장치 I/O 는 __linux__ 게이트.
 * H0 실측: docs/reports/2026-06-12-rgg01-usb-probe.md.
 */

#include "GamepadPilot.h"

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>

#ifdef __linux__
#include <dirent.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <linux/input.h>   // EVIOCGNAME/EVIOCGID — 커널 3.2 헤더 가용(H0 프로브 동일 ioctl)
#endif

namespace Robotis {

    // ===== 16B 디코드 ========================================================
    // i686 input_event = timeval 8B + type 2B + code 2B + value 4B (H0 실측 검증).
    // 리틀엔디언 명시 조립 — 호스트(테스트)와 로봇이 동일 경로.
    void DecodeGamepadEvent(const unsigned char* raw16, GpEvent* out) {
        out->type = (unsigned short)(raw16[8] | (raw16[9] << 8));
        out->code = (unsigned short)(raw16[10] | (raw16[11] << 8));
        // value 는 부호 있는 32bit — unsigned 로 조립 후 재해석.
        unsigned int v = (unsigned int)raw16[12] |
                         ((unsigned int)raw16[13] << 8) |
                         ((unsigned int)raw16[14] << 16) |
                         ((unsigned int)raw16[15] << 24);
        out->value = (int)v;
    }

    // ===== 스냅샷/디코더 =====================================================
    GamepadSnapshot::GamepadSnapshot()
        : lx(0.0), ly(0.0), rx(0.0), ry(0.0), lt(0.0), rt(0.0),
          hat_x(0), hat_y(0),
          btn_a(false), btn_b(false), btn_x(false), btn_y(false),
          btn_lb(false), btn_rb(false) {}

    GamepadDecoder::GamepadDecoder() : m_pending(), m_dirty(false) {}

    void GamepadDecoder::Reset() {
        m_pending = GamepadSnapshot();
        m_dirty = false;
    }

    static double NormStick(int v) {
        double n = (double)v / (double)GP_STICK_MAX;
        if (n > 1.0) n = 1.0;
        if (n < -1.0) n = -1.0;   // −32768 → −1.00003 클램프
        return n;
    }

    static double NormTrigger(int v) {
        double n = (double)v / (double)GP_TRIGGER_MAX;
        if (n > 1.0) n = 1.0;
        if (n < 0.0) n = 0.0;
        return n;
    }

    static int ClampHat(int v) {
        if (v > 1) return 1;
        if (v < -1) return -1;
        return v;
    }

    int GamepadDecoder::FeedEvent(const GpEvent& ev, GamepadSnapshot* out) {
        if (ev.type == GP_EV_ABS) {
            switch (ev.code) {
            case GP_ABS_X:     m_pending.lx = NormStick(ev.value); break;
            case GP_ABS_Y:     m_pending.ly = NormStick(ev.value); break;
            case GP_ABS_Z:     m_pending.lt = NormTrigger(ev.value); break;
            case GP_ABS_RX:    m_pending.rx = NormStick(ev.value); break;
            case GP_ABS_RY:    m_pending.ry = NormStick(ev.value); break;
            case GP_ABS_RZ:    m_pending.rt = NormTrigger(ev.value); break;
            case GP_ABS_HAT0X: m_pending.hat_x = ClampHat(ev.value); break;
            case GP_ABS_HAT0Y: m_pending.hat_y = ClampHat(ev.value); break;
            default: return 0;   // 미지 축 무시
            }
            m_dirty = true;
            return 0;
        }
        if (ev.type == GP_EV_KEY) {
            bool down = (ev.value != 0);   // 1=press, 2=autorepeat(押下 유지)
            switch (ev.code) {
            case GP_BTN_A:  m_pending.btn_a = down; break;
            case GP_BTN_B:  m_pending.btn_b = down; break;
            case GP_BTN_X:  m_pending.btn_x = down; break;
            case GP_BTN_Y:  m_pending.btn_y = down; break;
            case GP_BTN_LB: m_pending.btn_lb = down; break;
            case GP_BTN_RB: m_pending.btn_rb = down; break;
            default: return 0;   // Back/Start/Home/스틱클릭 — 예약(미배선)
            }
            m_dirty = true;
            return 0;
        }
        if (ev.type == GP_EV_SYN && ev.code == GP_SYN_REPORT) {
            *out = m_pending;
            m_dirty = false;
            return GP_FEED_COMMITTED;
        }
        if (ev.type == GP_EV_SYN && ev.code == GP_SYN_DROPPED) {
            // 실기 F9: 링 오버플로 — 직전 이벤트들(release 포함) 유실. pending 을
            // 리셋해 스테일 押下 고착을 끊는다(버튼 false 방향 = 정지 측 안전 편향;
            // 실제로 눌려 있으면 다음 이벤트/press 가 다시 세운다).
            Reset();
            return 0;
        }
        return 0;
    }

    bool GamepadDecoder::ForceCommit(GamepadSnapshot* out) {
        *out = m_pending;
        bool had = m_dirty;
        m_dirty = false;
        return had;
    }

    bool GamepadDecoder::ButtonState(unsigned short code) const {
        switch (code) {
        case GP_BTN_A:  return m_pending.btn_a;
        case GP_BTN_B:  return m_pending.btn_b;
        case GP_BTN_X:  return m_pending.btn_x;
        case GP_BTN_Y:  return m_pending.btn_y;
        case GP_BTN_LB: return m_pending.btn_lb;
        case GP_BTN_RB: return m_pending.btn_rb;
        default: return false;
        }
    }

    // ===== 매핑·성형 =========================================================
    GamepadHeadHold::GamepadHeadHold() : pan(0.0), tilt(0.0) {}

    GamepadWalkFields::GamepadWalkFields()
        : enabled(0), x(0.0), y(0.0), a(0.0),
          period(GP_GAIT_PERIOD_DEFAULT), foot(GP_GAIT_FOOT_DEFAULT),
          hip(GP_HIP_DEG), pan(0.0), tilt(0.0) {}

    double GpApplyDeadzone(double v) {
        double mag = fabs(v);
        if (mag < GP_DEADZONE) return 0.0;
        double scaled = (mag - GP_DEADZONE) / (1.0 - GP_DEADZONE);
        if (scaled > 1.0) scaled = 1.0;
        return (v >= 0.0) ? scaled : -scaled;
    }

    double GpShapeDriveAxis(double v) {
        double n = GpApplyDeadzone(v);
        if (n == 0.0) return 0.0;
        double shaped = pow(fabs(n), GP_DRIVE_CURVE);
        return (n >= 0.0) ? shaped : -shaped;
    }

    double GpShapeHeadAxis(double v) {
        // F10b — 곡선 1.7: 미세 deflection 의 °/s 는 종전(1.35×90)과 거의 동일,
        // 풀스틱 최고속만 RATE_DPS 상향분만큼 빨라진다.
        double n = GpApplyDeadzone(v);
        if (n == 0.0) return 0.0;
        double shaped = pow(fabs(n), GP_HEAD_CURVE);
        return (n >= 0.0) ? shaped : -shaped;
    }

    double GpShapeTurn(double d) {
        // F10b — 지수 0.65 저압 부스트: 트리거 살짝(0.1)에서도 ~0.2 의 체감 회전,
        // 풀프레스 ±1 불변. GpTriggerDiff 의 데드존 통과 후 값에 적용.
        if (d == 0.0) return 0.0;
        double shaped = pow(fabs(d), GP_TURN_CURVE);
        return (d >= 0.0) ? shaped : -shaped;
    }

    double GpTriggerDiff(double rt, double lt) {
        double d = rt - lt;
        double mag = fabs(d);
        if (mag < GP_TRIGGER_DEADZONE) return 0.0;
        double scaled = (mag - GP_TRIGGER_DEADZONE) / (1.0 - GP_TRIGGER_DEADZONE);
        if (scaled > 1.0) scaled = 1.0;
        return (d >= 0.0) ? scaled : -scaled;
    }

    // **하드닝 A1/B3** — 이동 의도(데드존·곡선 통과 후 전진/측보/턴 성분 중 하나라도
    // 0 이 아닌가). 재ARM 중립 게이트 해제 판정의 단일 기준. 부호 승수는 0 여부에 무관해
    // 생략. 머리(우스틱)는 이동 게이트와 무관하므로 제외(머리는 비게이트라 항상 동작).
    static bool GpMovingIntent(const GamepadSnapshot& s) {
        double fwd  = GpShapeDriveAxis(s.ly);
        double side = GpShapeDriveAxis(s.lx);
        double turn = GpShapeTurn(GpTriggerDiff(s.rt, s.lt));
        return (fwd != 0.0) || (side != 0.0) || (turn != 0.0);
    }

    void GpGaitSchedule(double x_mm, double y_mm, double a_deg, int enabled,
                        double* period_ms, double* foot_mm) {
        if (!enabled) {
            *period_ms = GP_GAIT_PERIOD_DEFAULT;
            *foot_mm = GP_GAIT_FOOT_DEFAULT;
            return;
        }
        // **하드닝 B2/P1-1 (2026-06-14)**: 축별 최대치로 정규화. 종전엔 측보 y 도 전진
        // 최대(GP_MAX_STRIDE_MM=38)로 나눠, 순수 좌우 풀스틱(실제 축별 최대 28mm)이 강도
        // 28/38=0.7368 로 체계적 과소평가됐다(period↑·foot↓ — 덜 빠릿·발 클리어런스 부족).
        // 비대칭 진폭은 per-axis max 로 정규화가 정석(Capture Steps/NimbRo). GateSchedule 도
        // 이미 ENVELOPE_Y_MAX 를 분모로 쓰므로 두 경로 논리 일관. 진폭은 불변(MapGamepad 가
        // GP_MAX_SIDE_MM 로 확정·거버너가 28mm 클램프) — period/foot 스케줄만 보정.
        double si = fabs(x_mm) / GP_MAX_STRIDE_MM;
        double yi = fabs(y_mm) / GP_MAX_SIDE_MM;
        double ti = fabs(a_deg) / GP_MAX_TURN_DEG;
        // **Anbernic 고도화 P1 — 결합강도**: max-of-axes 대신 L2 magnitude. 복합 stride 는
        // 총 발 이동이 단축보다 크므로 더 높은 케이던스+발높이를 받아야 자연스럽다(종전엔
        // 같은 케이던스로 '끌렸다'). 단일축은 sqrt(축²)=|축| 그대로라 단축 거동 불변.
        double inten = sqrt(si * si + yi * yi + ti * ti);
        if (inten > 1.0) inten = 1.0;
        if (inten < 0.0) inten = 0.0;
        double shaped = pow(inten, 0.7);
        *period_ms = GP_GAIT_PERIOD_MAX_MS -
                     (GP_GAIT_PERIOD_MAX_MS - GP_GAIT_PERIOD_MIN_MS) * shaped;
        *foot_mm = GP_GAIT_FOOT_MIN_MM +
                   (GP_GAIT_FOOT_MAX_MM - GP_GAIT_FOOT_MIN_MM) * shaped;
    }

    static double ClampAbs(double v, double cap) {
        if (v > cap) return cap;
        if (v < -cap) return -cap;
        return v;
    }

    void MapGamepad(const GamepadSnapshot& s, bool armed, double dt_ms,
                    GamepadHeadHold* hold, GamepadWalkFields* out) {
        // 이동 — 데드존 0.10 → 곡선 1.35 → MAX 스케일. (F12: 터보 제거.)
        // 실기 F10: 턴은 LT/RT 아날로그 차분(LT=좌회전, RT=우회전 — 비례).
        double fwd  = GP_SIGN_STRIDE * GpShapeDriveAxis(s.ly);
        double side = GP_SIGN_SIDE   * GpShapeDriveAxis(s.lx);
        double turn = GP_SIGN_TURN   * GpShapeTurn(GpTriggerDiff(s.rt, s.lt));
        // F12 (2026-06-13) — 터보(RB ×1.3) 제거: LB/RB 는 킥 전용(ProcessEvent). LT/RT
        // 아날로그 턴 + 풀스틱 스트라이드로 ×1.3 부스트는 중복이라 단순화. (s.btn_rb 미관여)
        bool moving = (fwd != 0.0) || (side != 0.0) || (turn != 0.0);
        // H2-2 — ARM(A) 전 이동 게이트 잠금. 실기 F10: 데드맨(LB) 해제 —
        // GP_DEADMAN_REQUIRED=true 로 되돌리면 종전 동작 복원. 머리는 비게이트.
        bool deadman_ok = GP_DEADMAN_REQUIRED ? s.btn_lb : true;
        int enabled = (armed && deadman_ok && moving) ? 1 : 0;
        out->enabled = enabled;
        out->x = enabled ? fwd  * GP_MAX_STRIDE_MM : 0.0;
        out->y = enabled ? side * GP_MAX_SIDE_MM   : 0.0;
        out->a = enabled ? turn * GP_MAX_TURN_DEG  : 0.0;
        GpGaitSchedule(out->x, out->y, out->a, enabled, &out->period, &out->foot);
        out->hip = GP_HIP_DEG;

        // 머리 — 실기 F10: 우스틱 레이트 제어. 곡선 성형(미세 조작 정밀·풀스틱
        // 고속)된 입력을 °/s 로 적분 — "자연스러운 속도 조절". 입력 0 이면 직전
        // 각 유지(hold). dt 는 호출자(이벤트/50ms 재공급)가 공급, 상한으로 점프 방지.
        if (dt_ms > 0.0) {
            double dt_s = (dt_ms > GP_MAP_DT_MAX_MS ? GP_MAP_DT_MAX_MS : dt_ms) / 1000.0;
            double pan_rate  = GP_SIGN_PAN  * GpShapeHeadAxis(s.rx);
            double tilt_rate = GP_SIGN_TILT * GpShapeHeadAxis(s.ry);
            hold->pan  = ClampAbs(hold->pan  + pan_rate  * GP_HEAD_PAN_RATE_DPS  * dt_s,
                                  GP_MAX_HEAD_PAN_DEG);
            hold->tilt = ClampAbs(hold->tilt + tilt_rate * GP_HEAD_TILT_RATE_DPS * dt_s,
                                  GP_MAX_HEAD_TILT_DEG);
        }
        out->pan = hold->pan;
        out->tilt = hold->tilt;
    }

    int BuildGamepadLine(char* out, int cap, long long seq,
                         const GamepadWalkFields& f, int balltrack) {
        // v1 14-token — ParseCommandLine 의 full 방언과 동일(형식 불변·P9).
        // bgain/benable 는 deprecated 토큰(switch 와 동일 "1.0 0"), blevel=2(×1.0).
        return snprintf(out, (size_t)cap,
                        "gp%lld %d %.2f %.2f %.2f %.0f %.0f %.2f 1.0 0 2 %.2f %.2f %d",
                        seq, f.enabled, f.x, f.y, f.a, f.period, f.foot, f.hip,
                        f.pan, f.tilt, balltrack ? 1 : 0);
    }

    // ===== settle / failsafe 판정 ===========================================
    bool SettleArmed(bool armed, bool arm_edge, bool estop_edge) {
        if (arm_edge) armed = true;
        if (estop_edge) armed = false;   // estop 이 같은 틱 ARM 을 이긴다(settle 이식)
        return armed;
    }

    GamepadFailsafe GamepadFailsafeDecision(long long now_ms, long long last_alive_ms,
                                            bool node_ok, bool had_device) {
        if (had_device && !node_ok) return GP_FS_SLEW_ZERO;   // ② inputSourceLost
        if (node_ok && last_alive_ms > 0 &&
            (now_ms - last_alive_ms) >= GP_SILENCE_SLEW_MS) {
            return GP_FS_SLEW_ZERO;                           // ③ 단절 의심(이벤트 침묵)
        }
        return GP_FS_NONE;
    }

    // ===== GamepadPilot 본체 =================================================
    GamepadPilot::GamepadPilot()
        : m_slot(), m_running(false), m_threadless(true),
          m_fd(-1), m_node_ok(false), m_had_device(false),
          m_armed(false), m_rearm_requires_neutral(false), m_balltrack(0),
          m_decoder(), m_snap(), m_hold(), m_have_snap(false),
          m_last_event_ms(0), m_last_activity_ms(0), m_adopt_ms(0),
          m_last_offer_ms(0), m_last_map_ms(0), m_seq(0),
          m_pending_arm_edge(false), m_pending_estop_edge(false),
          m_pending_recover_edge(false),
          m_pending_left_kick_edge(false), m_pending_right_kick_edge(false),
          m_estop_cb(0), m_recover_cb(0), m_kick_cb(0), m_cb_ctx(0) {
        pthread_mutex_init(&m_mtx, 0);
    }

    GamepadPilot::~GamepadPilot() {
        Stop();
        pthread_mutex_destroy(&m_mtx);
    }

    void GamepadPilot::Start(void (*estop_cb)(void*), void (*recover_cb)(void*),
                             void (*kick_cb)(void*, int side),
                             void* cb_ctx, bool with_thread) {
        if (m_running) return;
        m_estop_cb = estop_cb;
        m_recover_cb = recover_cb;
        m_kick_cb = kick_cb;
        m_cb_ctx = cb_ctx;
        m_running = true;
#ifdef __linux__
        if (with_thread) {
            if (pthread_create(&m_thread, 0, ThreadEntry, this) != 0) {
                m_running = false;   // 스레드 실패 — 파일럿 비활성(다른 경로 무영향)
                fprintf(stderr, "[GamepadPilot] pthread_create failed\n");
                return;
            }
            m_threadless = false;
            return;
        }
#endif
        (void)with_thread;       // 호스트/주입 구동 — 스레드 없음
        m_threadless = true;
    }

    void GamepadPilot::Stop() {
        if (!m_running) return;
        m_running = false;
        if (!m_threadless) {
            pthread_join(m_thread, 0);
        }
        m_threadless = false;
    }

    bool GamepadPilot::TakeCommand(char* out, int cap) {
        return m_slot.Take(out, cap);
    }

    bool GamepadPilot::HasControl(long long now_ms) {
        pthread_mutex_lock(&m_mtx);
        long long last = m_last_event_ms;
        pthread_mutex_unlock(&m_mtx);
        return last > 0 && (now_ms - last) <= GP_LOCAL_FRESH_MS;
    }

    GamepadFailsafe GamepadPilot::PollFailsafe(long long now_ms) {
        if (!m_running) return GP_FS_NONE;
        pthread_mutex_lock(&m_mtx);
        // ③티어 기준은 max(마지막 이벤트, 노드 획득) — 획득 직후 무입력 즉발 방지.
        long long alive = (m_last_event_ms > m_adopt_ms) ? m_last_event_ms : m_adopt_ms;
        bool node_ok = m_node_ok;
        bool had = m_had_device;
        pthread_mutex_unlock(&m_mtx);
        return GamepadFailsafeDecision(now_ms, alive, node_ok, had);
    }

    bool GamepadPilot::DevicePresent() {
        pthread_mutex_lock(&m_mtx);
        bool ok = m_node_ok;
        pthread_mutex_unlock(&m_mtx);
        return ok;
    }

    void GamepadPilot::ForceDisarm() {
        // **하드닝 A1** — 외부 E-STOP(UDP/Switch/Mac flag)이 ARM 을 latch-해제 + 재ARM
        // 중립 게이트 설정. ISO 13850: reset 은 재기동 "허용"만, 실제 재보행은 명시적
        // A 재ARM(+중립 경유)만 트리거. m_mtx 보유 구간 밖에서만 호출(헤더 재진입 불변식).
        pthread_mutex_lock(&m_mtx);
        m_armed = false;
        m_rearm_requires_neutral = true;
        pthread_mutex_unlock(&m_mtx);
    }

    bool GamepadPilot::Armed() {
        pthread_mutex_lock(&m_mtx);
        bool a = m_armed;
        pthread_mutex_unlock(&m_mtx);
        return a;
    }

    void GamepadPilot::AdoptDevice(int fd, long long now_ms) {
        pthread_mutex_lock(&m_mtx);
        m_fd = fd;
        m_node_ok = true;
        m_had_device = true;
        m_armed = false;            // H2-2 — 노드 (재)획득 후 재 ARM 필수
        m_rearm_requires_neutral = false;  // 하드닝 A1 — 물리 재연결은 깨끗한 슬레이트
        m_last_activity_ms = now_ms;       // 하드닝 B3 — idle timeout 기준 리셋
        m_decoder.Reset();
        m_have_snap = false;
        m_pending_arm_edge = false;
        m_pending_estop_edge = false;
        m_pending_recover_edge = false;
        m_pending_left_kick_edge = false;    // F12
        m_pending_right_kick_edge = false;
        m_adopt_ms = now_ms;        // ③티어 기준점(이벤트 전 즉발 방지)
        m_last_map_ms = 0;          // F10 — 재획득 후 첫 매핑 dt=0(머리 점프 방지)
        pthread_mutex_unlock(&m_mtx);
        printf("[GamepadPilot] device acquired: %s (%04x:%04x) — ARM(A) required\n",
               GP_DEVICE_NAME, GP_VENDOR_ID, GP_PRODUCT_ID);
    }

    void GamepadPilot::ProcessEvent(const GpEvent& ev, long long now_ms) {
        bool fire_estop = false;
        bool fire_recover = false;
        bool fire_kick_left = false;    // F12
        bool fire_kick_right = false;
        pthread_mutex_lock(&m_mtx);
        m_last_event_ms = now_ms;
        if (ev.type == GP_EV_KEY && ev.value == 1 && ev.code == GP_BTN_B) {
            // E-STOP — 모든 중재·게이트·데드맨보다 먼저(불변식). 즉시 disarm.
            // 실기 F9: rising 검사(!ButtonState) 없이 value==1 이면 무조건 발화 —
            // release 유실(링 오버플로 등)로 pending 이 押下 고착이면 종전 코드는
            // B 를 영구 침묵시켰다. 중복 발화는 멱등(Stop+flag touch)이라 무해.
            m_pending_estop_edge = true;
            m_armed = false;
            m_rearm_requires_neutral = true;  // 하드닝 A1 — B(명시적 E-STOP)도 재ARM 중립 게이트
            fire_estop = (m_estop_cb != 0);
        } else if (ev.type == GP_EV_KEY && ev.value == 1 &&
                   !m_decoder.ButtonState(ev.code)) {
            // rising edge — SYN 대기 없이 수집.
            if (ev.code == GP_BTN_A) {
                m_pending_arm_edge = true;
            } else if (ev.code == GP_BTN_Y) {
                // 복구 — estop flag 해제(switch recover 패리티) + ARM 의도(settle).
                m_pending_arm_edge = true;
                m_pending_recover_edge = true;
            } else if (ev.code == GP_BTN_X) {
                m_balltrack = m_balltrack ? 0 : 1;
            } else if (ev.code == GP_BTN_LB) {
                m_pending_left_kick_edge = true;   // F12 — 왼발 킥(ARM/estop 게이트는 SYN 커밋)
            } else if (ev.code == GP_BTN_RB) {
                m_pending_right_kick_edge = true;  // F12 — 오른발 킥
            }
        }
        // F12 — 링 오버플로(SYN_DROPPED): 보류 킥 edge 폐기. 고토크 HighRisk 액션은
        // 입력 스트림 무결성 손실 시 발화 금지가 안전 편향(사용자 재누름). 디코더 버튼
        // 상태 리셋은 FeedEvent 가 수행(정지 측 편향과 일관). arm/recover edge 와 달리
        // 킥은 의도적으로 더 보수적 — 오발 비용(킥)이 미발(재누름)보다 크다.
        if (ev.type == GP_EV_SYN && ev.code == GP_SYN_DROPPED) {
            m_pending_left_kick_edge = false;
            m_pending_right_kick_edge = false;
        }
        GamepadSnapshot snap;
        int fr = m_decoder.FeedEvent(ev, &snap);
        if (fr & GP_FEED_COMMITTED) {
            m_snap = snap;
            m_have_snap = true;
            m_armed = SettleArmed(m_armed, m_pending_arm_edge, m_pending_estop_edge);
            if (m_pending_recover_edge && !m_pending_estop_edge) {
                fire_recover = (m_recover_cb != 0);
            }
            // F12 킥 — estop 동률 패(억제) + ARM 게이트(settle 후 armed 필요). 콜백은
            // brokerage 플래그만 세팅(비블로킹) → supervisor 가 getup 패턴으로 실행.
            if (!m_pending_estop_edge && m_armed && m_kick_cb != 0) {
                if (m_pending_left_kick_edge)  fire_kick_left = true;
                if (m_pending_right_kick_edge) fire_kick_right = true;
            }
            // **하드닝 B3** — ARM idle timeout 활동 카운트: 의도적 입력(이동/턴/머리/버튼
            // 보유)이면 타이머 리셋. 스틱 데드존 노이즈는 데드존이 걸러 활동으로 안 친다
            // → 거치 중 미세 드리프트로는 무장이 유지되지 않는다(킥 셋업 중 버튼 보유는 활동).
            bool head_active = (GpApplyDeadzone(m_snap.rx) != 0.0) ||
                               (GpApplyDeadzone(m_snap.ry) != 0.0);
            // btn_b(E-STOP)는 활동에서 제외 — 눌리면 m_armed=false 라 idle-timeout 자체가
            // 무의미하고, "조종 의도"가 아닌 비상정지다(리뷰 MEDIUM-4).
            bool btn_active = m_snap.btn_a || m_snap.btn_x || m_snap.btn_y ||
                              m_snap.btn_lb || m_snap.btn_rb;
            if (GpMovingIntent(m_snap) || head_active || btn_active) {
                m_last_activity_ms = now_ms;
            }
            m_pending_arm_edge = false;
            m_pending_estop_edge = false;
            m_pending_recover_edge = false;
            m_pending_left_kick_edge = false;
            m_pending_right_kick_edge = false;
            OfferCurrentLocked(now_ms);
        }
        pthread_mutex_unlock(&m_mtx);
        // 콜백은 락 밖 — estop 은 Walking::Stop+토크OFF+flag(브로커리지 공유 헬퍼).
        if (fire_estop) m_estop_cb(m_cb_ctx);
        if (fire_recover) m_recover_cb(m_cb_ctx);
        // F12 — 킥: brokerage 가 m_pending_kick_side 세팅 후 즉시 반환(supervisor 실행).
        if (fire_kick_left)  m_kick_cb(m_cb_ctx, GP_KICK_LEFT);
        if (fire_kick_right) m_kick_cb(m_cb_ctx, GP_KICK_RIGHT);
    }

    void GamepadPilot::OfferCurrentLocked(long long now_ms) {
        if (!m_have_snap) return;
        // **하드닝 A1** — 외부/B E-STOP 후 재ARM 했어도, 스틱이 중립을 한 번 거치기 전엔
        // 이동을 억제(reset≠restart 완성 — 잔여 스틱 즉시 재보행 차단). 중립 관측 시 게이트
        // 해제. 머리/킥은 비영향(머리 비게이트, 킥은 fresh 버튼 rising 필요).
        bool eff_armed = m_armed;
        if (m_rearm_requires_neutral) {
            if (!GpMovingIntent(m_snap)) {
                m_rearm_requires_neutral = false;   // 중립 관측 → 게이트 해제
            } else {
                eff_armed = false;                   // 잔여 이동 입력 → enabled 억제
            }
        }
        GamepadWalkFields f;
        // F10 — 머리 레이트 적분 dt: 직전 매핑 이후 경과(이벤트·50ms 재공급 공용).
        // 첫 매핑(m_last_map_ms==0)은 dt=0 으로 적분 생략(획득 직후 점프 방지).
        double dt_ms = (m_last_map_ms > 0 && now_ms > m_last_map_ms)
                           ? (double)(now_ms - m_last_map_ms) : 0.0;
        m_last_map_ms = now_ms;
        MapGamepad(m_snap, eff_armed, dt_ms, &m_hold, &f);
        char line[192];
        m_seq++;
        int n = BuildGamepadLine(line, sizeof(line), m_seq, f, m_balltrack);
        if (n > 0 && n < (int)sizeof(line)) m_slot.Offer(line, 0);   // 스트림 소스(seq=0)
        m_last_offer_ms = now_ms;
    }

    void GamepadPilot::MaybeRefresh(long long now_ms) {
        pthread_mutex_lock(&m_mtx);
        // **하드닝 B3** — ARM idle timeout: ARM 후 의도적 입력이 GP_ARM_IDLE_TIMEOUT_MS
        // 없으면 auto-disarm(+재ARM 중립 게이트). 데드맨 제거의 완화책 — 거치 중 스틱
        // 오접촉으로 인한 의도치 않은 보행 차단. 활동 기준은 ProcessEvent 가 갱신.
        if (m_armed && m_last_activity_ms > 0 &&
            (now_ms - m_last_activity_ms) >= GP_ARM_IDLE_TIMEOUT_MS) {
            m_armed = false;
            m_rearm_requires_neutral = true;
        }
        if (m_node_ok && m_have_snap && m_last_event_ms > 0 &&
            (now_ms - m_last_event_ms) < GP_SILENCE_SLEW_MS &&
            (now_ms - m_last_offer_ms) >= GP_REFRESH_MS) {
            // 보유 상태 재공급 — 정적 홀드(이벤트 0)에서 스트림 워치독 餓死 방지.
            // 침묵 ≥1.5s 면 중단 → ③티어(PollFailsafe)가 제자리 슬루를 이어받는다.
            OfferCurrentLocked(now_ms);
        }
        pthread_mutex_unlock(&m_mtx);
    }

    void GamepadPilot::HandleNodeLost(long long now_ms) {
        (void)now_ms;
        pthread_mutex_lock(&m_mtx);
        m_pending_arm_edge = false;
        m_pending_estop_edge = false;
        m_pending_recover_edge = false;
        m_pending_left_kick_edge = false;    // F12 — 단절 시 보류 킥 폐기
        m_pending_right_kick_edge = false;
        m_armed = false;                // H2-2 — 재획득 후 재 ARM 필수
        // **하드닝 A2/P0-3 (2026-06-14)**: 노드 소멸 시 최종 enabled=0 라인을 발행하지
        // 않는다(버튼 상태와 무관 — 단일 안전상태). 종전엔 release 합성(!btn_lb)일 때만
        // enabled=0 라인을 내, "직전 버튼 상태"가 단절 정지 방식(즉시 Walking::Stop vs
        // 완만한 ②티어 슬루)을 갈랐다 — IEC 62745(무선 link-loss 는 신호 부재 자체가
        // 정지 결정, 마지막 버튼 상태 무관) 위반 패턴. 이제 모든 노드 소멸은 동일하게
        // PollFailsafe ②티어(GP_FS_SLEW_ZERO, controlled stop/cat-1)가 단일 소유한다.
        // (ForceCommit/스냅 갱신도 제거 — 발행하지 않으므로 불필요.)
        m_node_ok = false;
        m_have_snap = false;            // 재획득 전 refresh 발행 금지
        if (m_fd >= 0) { close(m_fd); m_fd = -1; }
        pthread_mutex_unlock(&m_mtx);
        printf("[GamepadPilot] input source lost — rescan every %dms (slew owns stop)\n",
               GP_RESCAN_MS);
    }

    // ── 호스트 테스트 주입 ───────────────────────────────────────────────────
    void GamepadPilot::InjectAdoptForTest(long long now_ms) { AdoptDevice(-1, now_ms); }
    void GamepadPilot::InjectEventForTest(const GpEvent& ev, long long now_ms) {
        ProcessEvent(ev, now_ms);
    }
    void GamepadPilot::InjectNodeLostForTest(long long now_ms) { HandleNodeLost(now_ms); }
    void GamepadPilot::TickForTest(long long now_ms) { MaybeRefresh(now_ms); }
    bool GamepadPilot::ArmedForTest() {
        pthread_mutex_lock(&m_mtx);
        bool a = m_armed;
        pthread_mutex_unlock(&m_mtx);
        return a;
    }
    int GamepadPilot::BalltrackForTest() {
        pthread_mutex_lock(&m_mtx);
        int b = m_balltrack;
        pthread_mutex_unlock(&m_mtx);
        return b;
    }

#ifdef __linux__
    // ===== 장치 스캔/읽기 스레드 (로봇 전용) =================================
    // switch-pilot input_linux.py 의 장치 선택 로직 C 이식 — 단, RG G01 은 H0 로
    // 정체가 확정돼(이름+VID/PID) 능력 휴리스틱 없이 정확 매칭한다.
    static long long GpNowMs() {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
    }

    static int ScanAndOpenGamepad() {
        DIR* d = opendir("/dev/input");
        if (!d) return -1;
        struct dirent* e;
        int found = -1;
        while ((e = readdir(d)) != 0) {
            if (strncmp(e->d_name, "event", 5) != 0) continue;
            char path[64];
            snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
            int fd = open(path, O_RDONLY | O_NONBLOCK);
            if (fd < 0) continue;   // 권한(root 0640) — brokerage 는 root demo 내부라 무문제
            char name[80] = {0};
            struct input_id iid;
            memset(&iid, 0, sizeof(iid));
            if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
                ioctl(fd, EVIOCGID, &iid) >= 0 &&
                strcmp(name, GP_DEVICE_NAME) == 0 &&
                iid.vendor == GP_VENDOR_ID && iid.product == GP_PRODUCT_ID) {
                found = fd;
                break;
            }
            close(fd);
        }
        closedir(d);
        return found;
    }

    void* GamepadPilot::ThreadEntry(void* self) {
        ((GamepadPilot*)self)->ReaderLoop();
        return 0;
    }

    void GamepadPilot::ReaderLoop() {
        while (m_running) {
            if (m_fd < 0) {
                int fd = ScanAndOpenGamepad();
                if (fd < 0) {
                    // 미발견 — 1s 재스캔(핫플러그 겸용). 패드 미연결 = 무동작(자연 게이트).
                    usleep(GP_RESCAN_MS * 1000);
                    continue;
                }
                AdoptDevice(fd, GpNowMs());
            }
            fd_set rf;
            FD_ZERO(&rf);
            FD_SET(m_fd, &rf);
            struct timeval tv;
            tv.tv_sec = 0;
            tv.tv_usec = GP_REFRESH_MS * 1000;   // refresh cadence 겸 종료 플래그 재검사
            int r = select(m_fd + 1, &rf, 0, 0, &tv);
            long long now = GpNowMs();
            if (r < 0) {
                if (errno == EINTR) continue;
                HandleNodeLost(now);
                continue;
            }
            if (r > 0) {
                unsigned char buf[16 * 64];
                ssize_t n = read(m_fd, buf, sizeof(buf));
                if (n <= 0) {
                    if (n < 0 && errno == EAGAIN) { MaybeRefresh(now); continue; }
                    // ENODEV(단절 — H0 §5)·EOF — ②티어: 강제 커밋 + 재스캔 전이.
                    HandleNodeLost(now);
                    continue;
                }
                for (ssize_t off = 0; off + 16 <= n; off += 16) {
                    GpEvent ev;
                    DecodeGamepadEvent(buf + off, &ev);
                    ProcessEvent(ev, now);
                }
            }
            MaybeRefresh(now);
        }
        if (m_fd >= 0) { close(m_fd); m_fd = -1; }
    }
#endif  // __linux__

}  // namespace Robotis
