/*
 * WalkLabTransport.cpp — DarwinForge onboard transport layer (pure logic)
 * O1 (2026-06-12). 구현 메모는 WalkLabTransport.h 참조. C++03/POSIX only.
 */

#include "WalkLabTransport.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace Robotis {

// ===== WalkCommand / ParseCommandLine =======================================

WalkCommand::WalkCommand()
    : enabled(0), x(0), y(0), a(0), period(0), foot(0), hip(13.0),
      bgain(1.0), benable(0), blevel(2),
      head_pan(0), head_tilt(0), balltrack(0), flags(0), head_explicit(false) {
    strcpy(cmd_id, "no_id");
}

// 클램프 상수 — 브로커리지 ParseAndApply 와 동일(단일 정의가 목표지만 C++03 헤더 상수
// 중복을 피하려 여기서 직접 사용; 값은 ssh-parity-contract §C 와 일치).
static const double HIP_MIN = 0.0;
static const double HIP_MAX = 20.0;

// V2 twist 분기 — "V2 {seq} {t_tx_ms} {flags} {vx} {vy} {wz} {period} {foot} {hip_cdeg}
//   {blevel} {pan_cdeg} {tilt_cdeg}". 정수 SI. 로봇이 변환 소유(§G.8). 클램프는 공용 적용.
static bool ParseV2Line(const char* line, WalkCommand* out) {
    long long seq = 0, t_tx = 0;
    int flags = 0, blevel = 2;
    long vx = 0, vy = 0, wz = 0;
    long period = 0, foot = 0, hip_cdeg = 0, pan_cdeg = 0, tilt_cdeg = 0;
    // "V2 " 접두는 호출부가 확인 — 여기선 그 뒤를 파싱.
    int n = sscanf(line + 3, "%lld %lld %d %ld %ld %ld %ld %ld %ld %d %ld %ld",
                   &seq, &t_tx, &flags, &vx, &vy, &wz,
                   &period, &foot, &hip_cdeg, &blevel, &pan_cdeg, &tilt_cdeg);
    if (n < 12) return false;   // V2 는 전 필드 필수(부분 라인 거부 → 이전 명령 유지).

    WalkCommand c;
    const double T = (double)period / 1000.0;            // s
    c.x = TWIST_K_X * (double)vx * T / 2.0;              // mm
    c.y = TWIST_K_Y * (double)vy * T / 2.0;              // mm
    c.a = TWIST_K_A * ((double)wz / 1000.0) * T / 2.0 * (180.0 / M_PI);  // deg
    c.period = (double)period;
    c.foot   = (double)foot;
    c.hip    = (double)hip_cdeg / 100.0;
    c.head_pan  = (double)pan_cdeg / 100.0;
    c.head_tilt = (double)tilt_cdeg / 100.0;
    c.blevel = blevel;
    c.flags  = flags;
    // boolean 토글은 flags 로 접힘.
    c.enabled   = (flags & FLAG_ENABLED) ? 1 : 0;
    c.benable   = (flags & FLAG_BALANCE_ENABLE) ? 1 : 0;
    c.balltrack = (flags & FLAG_BALLTRACK) ? 1 : 0;
    c.bgain = 1.0;   // deprecated — blevel 로 단일화.

    // 안전 클램프(공용).
    if (c.hip < HIP_MIN) c.hip = HIP_MIN;
    if (c.hip > HIP_MAX) c.hip = HIP_MAX;
    if (c.head_pan < -90.0) c.head_pan = -90.0;
    if (c.head_pan >  90.0) c.head_pan =  90.0;
    if (c.head_tilt < -45.0) c.head_tilt = -45.0;
    if (c.head_tilt >  65.0) c.head_tilt =  65.0;
    c.head_explicit = (c.head_pan != 0.0) || (c.head_tilt != 0.0);

    // cmd_id = "v2#{seq}" (ACK 상관용 — Mac 이 seq 로 매치).
    snprintf(c.cmd_id, sizeof(c.cmd_id), "v2#%lld", seq);

    *out = c;
    return true;
}

bool ParseCommandLine(const char* line, WalkCommand* out) {
    if (!line || !out) return false;
    // V2 방언 우선 분기(접두 "V2 " 검사).
    if (strncmp(line, "V2 ", 3) == 0) return ParseV2Line(line, out);

    WalkCommand c;   // 기본값 시드(파싱 실패 필드는 기본 유지).

    char cmd_id[32] = "no_id";
    int enabled = 0;
    float x = 0, y = 0, a = 0, period = 0, foot = 0, hip = 13.0f;
    float bgain = 1.0f; int benable = 0, blevel = 2;
    float head_pan = 0.0f, head_tilt = 0.0f, balltrack = 0.0f;

    // 시도 1: cmd_id 포함 (최대 14 token).
    int n = sscanf(line, "%31s %d %f %f %f %f %f %f %f %d %d %f %f %f",
                   cmd_id, &enabled, &x, &y, &a, &period, &foot, &hip,
                   &bgain, &benable, &blevel, &head_pan, &head_tilt, &balltrack);
    if (n < 7) {
        // 시도 2: cmd_id 없음 (최대 13 token).
        n = sscanf(line, "%d %f %f %f %f %f %f %f %d %d %f %f %f",
                   &enabled, &x, &y, &a, &period, &foot, &hip,
                   &bgain, &benable, &blevel, &head_pan, &head_tilt, &balltrack);
        if (n < 6) return false;   // 잘못된 라인 — 이전 명령 유지(safety).
        strcpy(cmd_id, "no_id");
    }
    if (n == 6) {
        // 6 필드(구형) backward-compat — hip 미전달 시 기본 유지.
        hip = (float)c.hip;
    }

    // 안전 클램프.
    if (hip < HIP_MIN) hip = (float)HIP_MIN;
    if (hip > HIP_MAX) hip = (float)HIP_MAX;
    if (head_pan < -90.0f) head_pan = -90.0f;
    if (head_pan >  90.0f) head_pan =  90.0f;
    if (head_tilt < -45.0f) head_tilt = -45.0f;
    if (head_tilt >  65.0f) head_tilt =  65.0f;

    strncpy(c.cmd_id, cmd_id, sizeof(c.cmd_id) - 1);
    c.cmd_id[sizeof(c.cmd_id) - 1] = '\0';
    c.enabled   = enabled;
    c.x = x; c.y = y; c.a = a;
    c.period = period; c.foot = foot; c.hip = hip;
    c.bgain = bgain; c.benable = benable; c.blevel = blevel;
    c.head_pan = head_pan; c.head_tilt = head_tilt;
    c.balltrack = (balltrack > 0.5f) ? 1 : 0;
    c.head_explicit = (head_pan != 0.0f) || (head_tilt != 0.0f);

    *out = c;
    return true;
}

// ===== CommandSlot ==========================================================

CommandSlot::CommandSlot()
    : m_last_seq(0), m_stream_seq(0), m_pending_seq(0), m_pending(false) {
    pthread_mutex_init(&m_mtx, 0);
    m_line[0] = '\0';
}

CommandSlot::~CommandSlot() {
    pthread_mutex_destroy(&m_mtx);
}

bool CommandSlot::Offer(const char* line, long long seq) {
    if (!line) return false;
    pthread_mutex_lock(&m_mtx);
    bool accept;
    long long accepted_seq = 0;
    if (seq == 0) {
        // 스트림 소스 — 순서 보장됨. 내부 카운터로 항상 수용.
        m_stream_seq += 1;
        m_last_seq = (m_last_seq > m_stream_seq) ? m_last_seq : m_stream_seq;
        accepted_seq = m_stream_seq;
        accept = true;
    } else {
        // UDP 소스 — 역행 datagram 폐기(seq 단조).
        accept = (seq > m_last_seq);
        if (accept) { m_last_seq = seq; accepted_seq = seq; }
    }
    if (accept) {
        strncpy(m_line, line, sizeof(m_line) - 1);
        m_line[sizeof(m_line) - 1] = '\0';
        m_pending_seq = accepted_seq;
        m_pending = true;
    }
    pthread_mutex_unlock(&m_mtx);
    return accept;
}

bool CommandSlot::Take(char* out, int capacity, long long* seq_out) {
    if (!out || capacity <= 0) return false;
    pthread_mutex_lock(&m_mtx);
    bool had = m_pending;
    if (had) {
        strncpy(out, m_line, (size_t)capacity - 1);
        out[capacity - 1] = '\0';
        if (seq_out) *seq_out = m_pending_seq;
        m_pending = false;
    }
    pthread_mutex_unlock(&m_mtx);
    return had;
}

long long CommandSlot::LastSeq() {
    pthread_mutex_lock(&m_mtx);
    long long s = m_last_seq;
    pthread_mutex_unlock(&m_mtx);
    return s;
}

// ===== WatchdogDecision =====================================================

WatchdogAction WatchdogDecision(long long elapsed_ms, bool walking_active, bool from_stream) {
    if (!walking_active) return WD_NONE;
    if (!from_stream) return WD_NONE;   // 티어는 스트림(UDP 슬롯) 소스 전용 — 파일 경로 제외.
    if (elapsed_ms >= WATCHDOG_STOP_MS) return WD_STOP;
    if (elapsed_ms >= WATCHDOG_SLEW_MS) return WD_SLEW_ZERO;
    return WD_NONE;
}

// ===== ServoGuardDecide (실기 F8) ===========================================

ServoGuardAction ServoGuardDecide(bool read_ok, int torque_limit,
                                  bool temp_ok, int temp_c) {
    if (!read_ok) return SG_NONE;            // 무응답 — 추측 복원 금지.
    if (torque_limit != 0) return SG_NONE;   // tl>0 — 셧다운 래치 아님.
    if (!temp_ok) return SG_SKIP_HOT;        // 온도 미상 — 보수적 보류.
    if (temp_c > SG_TEMP_SAFE_C) return SG_SKIP_HOT;
    return SG_RESTORE;
}

// ===== O2 거버너 / 슬루 / 밸런스 / 게이트 스케줄 (순수 로직) =================

double EnvelopeXMax(double period_ms) {
    // period 종속 x_max 스케줄 — 구간 선형 보간(700→40, 600→38, 500→32, 440→28).
    // 경계 밖은 끝값 고정(빠른 주기일수록 작은 보폭으로 안정 확보).
    if (period_ms >= 700.0) return 40.0;
    if (period_ms >= 600.0) return 38.0 + (period_ms - 600.0) * (40.0 - 38.0) / 100.0;
    if (period_ms >= 500.0) return 32.0 + (period_ms - 500.0) * (38.0 - 32.0) / 100.0;
    if (period_ms >= 440.0) return 28.0 + (period_ms - 440.0) * (32.0 - 28.0) / 60.0;
    return 28.0;
}

void GovernEnvelope(double* x, double* y, double* a, double period_ms) {
    if (!x || !y || !a) return;
    double x_max = EnvelopeXMax(period_ms);
    double y_max = ENVELOPE_Y_MAX;
    double a_max = ENVELOPE_A_MAX;
    if (x_max <= 0.0 || y_max <= 0.0 || a_max <= 0.0) return;
    double sum = fabs(*x) / x_max + fabs(*y) / y_max + fabs(*a) / a_max;
    if (sum > ENVELOPE_SUM_MAX) {
        double scale = ENVELOPE_SUM_MAX / sum;   // 방향 보존 비례 축소.
        *x *= scale;
        *y *= scale;
        *a *= scale;
    }
}

SlewState::SlewState() : x(0), y(0), a(0), period(0), valid(false) {}

static double SlewAxis(double prev, double target, double max_delta) {
    double d = target - prev;
    if (d >  max_delta) d =  max_delta;
    if (d < -max_delta) d = -max_delta;
    return prev + d;
}

// **Anbernic 고도화 P1** — 축이 자기 캡으로 잔여 거리를 좁히는 데 필요한 래치 수(≥1).
static int SlewStepsFor(double delta, double cap) {
    if (cap <= 0.0) return 1;
    double mag = (delta < 0.0) ? -delta : delta;
    int n = (int)ceil(mag / cap);
    return (n < 1) ? 1 : n;
}

void SlewToward(SlewState* st, double* x, double* y, double* a, double* period) {
    if (!st || !x || !y || !a || !period) return;
    if (!st->valid) {
        // 첫 적용 — 슬루 없이 target 수용(정지→첫 명령 즉시 반영, 이후부터 제한).
        st->x = *x; st->y = *y; st->a = *a; st->period = *period;
        st->valid = true;
        return;
    }
    // 동기화(co-arrival) 슬루: 세 이동축이 같은 래치 수 N 에 함께 도달하도록 각 축을
    // Δ/N 전진. N = 각 축이 자기 캡으로 도달하는 데 필요한 래치 수의 최댓값. 매 호출마다
    // 현재 governed target 대비 재계산(캐시 금지 — 목표가 움직이면 재수렴). |Δ|/N ≤ cap
    // 이 보장되어 어떤 축도 자기 캡을 초과하지 않는다(ceil 정의상 N ≥ |Δ|/cap).
    double dx = *x - st->x, dy = *y - st->y, da = *a - st->a;
    int n = SlewStepsFor(dx, SLEW_DX_MAX);
    int ny = SlewStepsFor(dy, SLEW_DY_MAX);
    int na = SlewStepsFor(da, SLEW_DA_MAX);
    if (ny > n) n = ny;
    if (na > n) n = na;
    if (n <= 1) {
        // 세 축 모두 한 래치 안에 자기 캡으로 도달 — target 즉시 수용.
        st->x = *x; st->y = *y; st->a = *a;
    } else {
        st->x += dx / (double)n;
        st->y += dy / (double)n;
        st->a += da / (double)n;
        *x = st->x; *y = st->y; *a = st->a;
    }
    // period 는 독립 대칭 슬루(케이던스는 보행 강도 종속 — co-arrival 불요).
    *period = SlewAxis(st->period, *period, SLEW_DPERIOD_MAX);
    st->period = *period;
}

bool SlewCadenceDue(long long now_ms, long long last_slew_ms, double period_ms) {
    if (last_slew_ms == 0) return true;   // 아직 전진 안 함 → 즉시 허용.
    double half = (period_ms > 0.0) ? (period_ms / 2.0) : 300.0;
    return (now_ms - last_slew_ms) >= (long long)half;
}

bool SlewAtTarget(const SlewState& st, double x, double y, double a, double period) {
    if (!st.valid) return false;
    return fabs(st.x - x) < 1e-6 && fabs(st.y - y) < 1e-6 &&
           fabs(st.a - a) < 1e-6 && fabs(st.period - period) < 1e-6;
}

double BalanceGainScale(int blevel) {
    if (blevel <= 0) return 0.0;
    if (blevel == 1) return 0.5;
    if (blevel == 2) return 1.0;
    return 1.5;   // blevel >= 3 → 1.5 (끝값 클램프).
}

GateBoost::GateBoost() : z_move(0), y_swap(0), hip(0) {}

GateBoost GateSchedule(double x, double y, double period_ms, int flags) {
    GateBoost b;
    if (flags & FLAG_GATE_SCHED_OFF) return b;   // 기본 ON, flags 비트로 OFF.
    double x_max = EnvelopeXMax(period_ms);
    if (x_max <= 0.0) return b;
    // **P6 gate-on-y**: 전진(|x|/x_max)과 횡속(|y|/ENVELOPE_Y_MAX) 중 큰 비율로 발화 —
    // 순수 strafe(x=0)도 Y_SWAP/Z_MOVE boost 를 받아 swing foot lateral CoM 을 feasible 유지.
    double ratio = fabs(x) / x_max;
    if (ENVELOPE_Y_MAX > 0.0) {
        double yr = fabs(y) / ENVELOPE_Y_MAX;
        if (yr > ratio) ratio = yr;
    }
    if (ratio <= GATE_SPEED_THRESH) return b;    // 상위 30% 구간에서만 가산.
    // 임계~1.0 을 0~1 로 정규화(상한 클램프).
    double t = (ratio - GATE_SPEED_THRESH) / (1.0 - GATE_SPEED_THRESH);
    if (t > 1.0) t = 1.0;
    b.z_move = GATE_ZMOVE_ADD_MAX * t;
    b.y_swap = GATE_YSWAP_ADD_MAX * t;
    b.hip    = GATE_HIP_ADD_MAX * t;
    return b;
}

// ===== 데이터그램 파서 ======================================================

// 첫 토큰들을 안전하게 NUL 종료 버퍼로 복사(recvfrom 은 NUL 미보장).
static void CopyBounded(const char* buf, int len, char* dst, int cap) {
    int n = (len < cap - 1) ? len : (cap - 1);
    if (n < 0) n = 0;
    memcpy(dst, buf, (size_t)n);
    dst[n] = '\0';
}

bool ParseEstopDatagram(const char* buf, int len, const char* token) {
    if (!buf || !token || len <= 0) return false;
    char tmp[128];
    CopyBounded(buf, len, tmp, (int)sizeof(tmp));
    // "DF-ESTOP v1 {token} {ts?}"
    const char* prefix = "DF-ESTOP v1 ";
    size_t plen = strlen(prefix);
    if (strncmp(tmp, prefix, plen) != 0) return false;
    char got_token[64] = {0};
    long long ts = 0;
    int n = sscanf(tmp + plen, "%63s %lld", got_token, &ts);
    if (n < 1) return false;
    return strcmp(got_token, token) == 0;
}

bool ParseCmdDatagram(const char* buf, int len, const char* token,
                      long long* seq_out, char* line_out, int line_cap) {
    if (!buf || !token || !seq_out || !line_out || line_cap <= 0 || len <= 0) return false;
    char tmp[512];
    CopyBounded(buf, len, tmp, (int)sizeof(tmp));
    const char* prefix = "DFCMD ";
    size_t plen = strlen(prefix);
    if (strncmp(tmp, prefix, plen) != 0) return false;

    // "{token} {seq} {line...}" — token/seq 만 sscanf 로 떼고 나머지는 수동 추출.
    char got_token[64] = {0};
    long long seq = 0;
    int consumed = 0;
    int n = sscanf(tmp + plen, "%63s %lld %n", got_token, &seq, &consumed);
    if (n < 2) return false;
    if (strcmp(got_token, token) != 0) return false;

    const char* rest = tmp + plen + consumed;
    // 후행 개행 제거 후 복사.
    int rlen = (int)strlen(rest);
    while (rlen > 0 && (rest[rlen - 1] == '\n' || rest[rlen - 1] == '\r')) rlen--;
    int copy = (rlen < line_cap - 1) ? rlen : (line_cap - 1);
    memcpy(line_out, rest, (size_t)copy);
    line_out[copy] = '\0';

    *seq_out = seq;
    return true;
}

// ===== O4 TEL2 포맷터 =========================================================

int FormatTel2(char* out, int cap,
               long long ts_ms, long long seq_applied, int phase,
               double x_lat, double y_lat, double a_lat, double period_lat,
               int gx, int gy, int gz, int ax, int ay, int az,
               bool fsr_present, const int* fsr8,
               bool cop_present, int copx, int copy,
               int fallen, bool risk_present, double risk,
               int vdV, const char* active_source, long long loop_ms) {
    if (!out || cap <= 0) return 0;

    // FSR 그룹: 장착 시 8셀, 아니면 "-".
    char fsr_buf[96];
    if (fsr_present && fsr8) {
        snprintf(fsr_buf, sizeof(fsr_buf), "%d %d %d %d %d %d %d %d",
                 fsr8[0], fsr8[1], fsr8[2], fsr8[3],
                 fsr8[4], fsr8[5], fsr8[6], fsr8[7]);
    } else {
        strcpy(fsr_buf, "-");
    }

    // CoP 그룹: 가용 시 정수 2개, 아니면 "-".
    char cop_buf[32];
    if (cop_present) {
        snprintf(cop_buf, sizeof(cop_buf), "%d %d", copx, copy);
    } else {
        strcpy(cop_buf, "-");
    }

    // risk: O3 미구현 → 자리만 "-" (forward-compat: risk_present 시 소수 2자리).
    char risk_buf[24];
    if (risk_present) {
        snprintf(risk_buf, sizeof(risk_buf), "%.2f", risk);
    } else {
        strcpy(risk_buf, "-");
    }

    const char* src = (active_source && active_source[0]) ? active_source : "file";

    int n = snprintf(out, (size_t)cap,
        "TEL2 %lld %lld %d %.2f %.2f %.2f %.2f %d %d %d %d %d %d %s %s %d %s %d %s %lld\n",
        ts_ms, seq_applied, phase,
        x_lat, y_lat, a_lat, period_lat,
        gx, gy, gz, ax, ay, az,
        fsr_buf, cop_buf,
        fallen, risk_buf, vdV, src, loop_ms);
    if (n < 0) return 0;
    return n;
}

}  // namespace Robotis
