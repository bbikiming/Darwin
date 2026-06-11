/*
 * WalkLabTransport.cpp — DarwinForge onboard transport layer (pure logic)
 * O1 (2026-06-12). 구현 메모는 WalkLabTransport.h 참조. C++03/POSIX only.
 */

#include "WalkLabTransport.h"

#include <string.h>
#include <stdio.h>
#include <stdlib.h>

namespace Robotis {

// ===== WalkCommand / ParseCommandLine =======================================

WalkCommand::WalkCommand()
    : enabled(0), x(0), y(0), a(0), period(0), foot(0), hip(13.0),
      bgain(1.0), benable(0), blevel(2),
      head_pan(0), head_tilt(0), balltrack(0), head_explicit(false) {
    strcpy(cmd_id, "no_id");
}

// 클램프 상수 — 브로커리지 ParseAndApply 와 동일(단일 정의가 목표지만 C++03 헤더 상수
// 중복을 피하려 여기서 직접 사용; 값은 ssh-parity-contract §C 와 일치).
static const double HIP_MIN = 0.0;
static const double HIP_MAX = 20.0;

bool ParseCommandLine(const char* line, WalkCommand* out) {
    if (!line || !out) return false;
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
    : m_last_seq(0), m_stream_seq(0), m_pending(false) {
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
    if (seq == 0) {
        // 스트림 소스 — 순서 보장됨. 내부 카운터로 항상 수용.
        m_stream_seq += 1;
        m_last_seq = (m_last_seq > m_stream_seq) ? m_last_seq : m_stream_seq;
        accept = true;
    } else {
        // UDP 소스 — 역행 datagram 폐기(seq 단조).
        accept = (seq > m_last_seq);
        if (accept) m_last_seq = seq;
    }
    if (accept) {
        strncpy(m_line, line, sizeof(m_line) - 1);
        m_line[sizeof(m_line) - 1] = '\0';
        m_pending = true;
    }
    pthread_mutex_unlock(&m_mtx);
    return accept;
}

bool CommandSlot::Take(char* out, int capacity) {
    if (!out || capacity <= 0) return false;
    pthread_mutex_lock(&m_mtx);
    bool had = m_pending;
    if (had) {
        strncpy(out, m_line, (size_t)capacity - 1);
        out[capacity - 1] = '\0';
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

}  // namespace Robotis
