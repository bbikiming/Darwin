/*
 * test_transport.cpp — host unit tests for WalkLabTransport (O1 pure logic).
 *
 * 로봇 toolchain·Robot:: 프레임워크 불요 — WalkLabTransport.cpp 만 링크.
 * 외부 테스트 프레임워크 없이 매크로 assert. 실패 시 비-0 exit + 메시지.
 *
 *   make -C firmware-patches/walklab-brokerage/tests
 */

#include "../WalkLabTransport.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

using namespace Robotis;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; printf("  FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); } \
} while (0)

#define CHECK_DEQ(a, b, msg) CHECK(fabs((double)(a) - (double)(b)) < 1e-6, msg)

// ---- ParseCommandLine -------------------------------------------------------

static void test_parse_full_line() {
    printf("test_parse_full_line\n");
    WalkCommand c;
    // cmd_id + 13 fields (14 token): id en x y a period foot hip bgain benable blevel pan tilt ball
    bool ok = ParseCommandLine("c123_ab12 1 28.00 10.00 5.00 600 40 13.00 1.00 0 2 20.00 -10.00 0", &c);
    CHECK(ok, "full line parses");
    CHECK(strcmp(c.cmd_id, "c123_ab12") == 0, "cmd_id captured");
    CHECK(c.enabled == 1, "enabled");
    CHECK_DEQ(c.x, 28.0, "x");
    CHECK_DEQ(c.y, 10.0, "y");
    CHECK_DEQ(c.a, 5.0, "a");
    CHECK_DEQ(c.period, 600.0, "period");
    CHECK_DEQ(c.foot, 40.0, "foot");
    CHECK_DEQ(c.hip, 13.0, "hip");
    CHECK_DEQ(c.head_pan, 20.0, "head_pan");
    CHECK_DEQ(c.head_tilt, -10.0, "head_tilt");
    CHECK(c.head_explicit, "head_explicit true when nonzero");
    CHECK(c.balltrack == 0, "balltrack off");
}

static void test_parse_clamps() {
    printf("test_parse_clamps\n");
    WalkCommand c;
    // hip 99 → 20, pan 200 → 90, tilt -99 → -45, tilt 99 → 65
    bool ok = ParseCommandLine("idX 1 0 0 0 600 40 99.0 1.0 0 2 200.0 -99.0 0", &c);
    CHECK(ok, "clamp line parses");
    CHECK_DEQ(c.hip, 20.0, "hip clamped to 20");
    CHECK_DEQ(c.head_pan, 90.0, "pan clamped to 90");
    CHECK_DEQ(c.head_tilt, -45.0, "tilt clamped to -45");

    WalkCommand c2;
    ParseCommandLine("idY 1 0 0 0 600 40 -5.0 1.0 0 2 0 99.0 0", &c2);
    CHECK_DEQ(c2.hip, 0.0, "hip clamped to 0");
    CHECK_DEQ(c2.head_tilt, 65.0, "tilt clamped to +65 (asymmetric)");
}

static void test_parse_backward_compat() {
    printf("test_parse_backward_compat\n");
    // 진짜 backward-compat 경로: cmd_id + 6 필드(구형 v1.11.5). hip 미전달 → 기본 13 유지.
    // (deployed 브로커리지 ParseAndApply 와 동일 — attempt1 sscanf n==7, hip 토큰 부재.)
    WalkCommand c;
    bool ok = ParseCommandLine("legacyid 1 5.0 0.0 0.0 600 40", &c);
    CHECK(ok, "cmd_id + 6 fields (legacy) parses");
    CHECK(strcmp(c.cmd_id, "legacyid") == 0, "cmd_id captured");
    CHECK_DEQ(c.x, 5.0, "x backward");
    CHECK_DEQ(c.hip, 13.0, "hip defaults to 13 when omitted");
    CHECK(!c.head_explicit, "head_explicit false when zero/absent head");
}

static void test_parse_rejects_short() {
    printf("test_parse_rejects_short\n");
    WalkCommand c;
    CHECK(!ParseCommandLine("garbage", &c), "single token rejected");
    CHECK(!ParseCommandLine("", &c), "empty rejected");
    CHECK(!ParseCommandLine("1 2 3", &c), "3 tokens rejected (<6)");
}

// ---- CommandSlot ------------------------------------------------------------

static void test_slot_stream_latest_wins() {
    printf("test_slot_stream_latest_wins\n");
    CommandSlot slot;
    char out[256];
    CHECK(!slot.Take(out, sizeof(out)), "empty slot take false");

    CHECK(slot.Offer("cmd A", 0), "stream offer A accepted");
    CHECK(slot.Offer("cmd B", 0), "stream offer B accepted (latest wins)");
    CHECK(slot.Take(out, sizeof(out)), "take after offers true");
    CHECK(strcmp(out, "cmd B") == 0, "latest (B) wins over A");
    CHECK(!slot.Take(out, sizeof(out)), "second take empty (pending cleared)");
}

static void test_slot_udp_seq_monotonic() {
    printf("test_slot_udp_seq_monotonic\n");
    CommandSlot slot;
    char out[256];
    CHECK(slot.Offer("seq10", 10), "seq 10 accepted");
    CHECK(!slot.Offer("seq5", 5), "older seq 5 rejected");
    CHECK(slot.Offer("seq11", 11), "newer seq 11 accepted");
    CHECK(slot.LastSeq() == 11, "last seq is 11");
    CHECK(slot.Take(out, sizeof(out)), "take true");
    CHECK(strcmp(out, "seq11") == 0, "slot holds seq11 (5 never stored)");
}

static void test_slot_equal_seq_rejected() {
    printf("test_slot_equal_seq_rejected\n");
    CommandSlot slot;
    CHECK(slot.Offer("a", 7), "seq 7 accepted");
    CHECK(!slot.Offer("b", 7), "duplicate seq 7 rejected (strict monotonic)");
}

// ---- WatchdogDecision -------------------------------------------------------

static void test_watchdog_tiers() {
    printf("test_watchdog_tiers\n");
    // 스트림(UDP 슬롯) 소스 — 티어 발화.
    CHECK(WatchdogDecision(0, true, true) == WD_NONE, "fresh → none");
    CHECK(WatchdogDecision(599, true, true) == WD_NONE, "599ms → none");
    CHECK(WatchdogDecision(600, true, true) == WD_SLEW_ZERO, "600ms → slew zero");
    CHECK(WatchdogDecision(2499, true, true) == WD_SLEW_ZERO, "2499ms → slew zero");
    CHECK(WatchdogDecision(2500, true, true) == WD_STOP, "2500ms → stop");
    CHECK(WatchdogDecision(9999, true, true) == WD_STOP, "way stale → stop");
    CHECK(WatchdogDecision(5000, false, true) == WD_NONE, "not walking → none regardless");
}

static void test_watchdog_stream_only() {
    printf("test_watchdog_stream_only\n");
    // **[HIGH] 티어는 스트림 소스 전용** — 파일 소스(from_stream=false)는 항상 WD_NONE.
    CHECK(WatchdogDecision(700, true, false) == WD_NONE, "file source 700ms → none (no tier)");
    CHECK(WatchdogDecision(3000, true, false) == WD_NONE, "file source 3s → none (no tier)");
    CHECK(WatchdogDecision(9999, true, false) == WD_NONE, "file source way-stale → none");
    // 동일 경과라도 스트림 소스면 발화 — 게이트가 소스만으로 갈린다.
    CHECK(WatchdogDecision(700, true, true) == WD_SLEW_ZERO, "stream source 700ms → slew zero");
    CHECK(WatchdogDecision(3000, true, true) == WD_STOP, "stream source 3s → stop");
}

// ---- datagram parsers -------------------------------------------------------

static void test_estop_datagram() {
    printf("test_estop_datagram\n");
    const char* p1 = "DF-ESTOP v1 TOK123 1748736000123";
    CHECK(ParseEstopDatagram(p1, (int)strlen(p1), "TOK123"), "valid estop with ts");
    const char* p2 = "DF-ESTOP v1 TOK123";
    CHECK(ParseEstopDatagram(p2, (int)strlen(p2), "TOK123"), "valid estop without ts");
    CHECK(!ParseEstopDatagram(p1, (int)strlen(p1), "WRONG"), "wrong token rejected");
    const char* bad = "HELLO WORLD";
    CHECK(!ParseEstopDatagram(bad, (int)strlen(bad), "TOK123"), "bad prefix rejected");
}

static void test_cmd_datagram() {
    printf("test_cmd_datagram\n");
    const char* p = "DFCMD TOK123 42 c1_ab 1 28.0 0 0 600 40 13.0 1.0 0 2 0 0 0";
    long long seq = 0; char line[256];
    bool ok = ParseCmdDatagram(p, (int)strlen(p), "TOK123", &seq, line, sizeof(line));
    CHECK(ok, "valid cmd datagram parses");
    CHECK(seq == 42, "seq extracted");
    CHECK(strcmp(line, "c1_ab 1 28.0 0 0 600 40 13.0 1.0 0 2 0 0 0") == 0, "line extracted verbatim");
    // round-trip: extracted line is a parseable command.
    WalkCommand c;
    CHECK(ParseCommandLine(line, &c), "extracted line is parseable");
    CHECK(c.enabled == 1 && fabs(c.x - 28.0) < 1e-6, "round-trip command fields");

    long long seq2; char line2[256];
    CHECK(!ParseCmdDatagram(p, (int)strlen(p), "WRONG", &seq2, line2, sizeof(line2)),
          "wrong token rejected");
}

// ---- O2: V2 twist protocol --------------------------------------------------

static void test_parse_v2_twist() {
    printf("test_parse_v2_twist\n");
    // V2 seq t_tx flags vx vy wz period foot hip_cdeg blevel pan_cdeg tilt_cdeg
    // flags = ENABLED(1) → enabled. vx=200mm/s, period=600ms → T=0.6, X=200*0.6/2=60? then
    // governor not applied here (parse only). k_x=1.0.
    WalkCommand c;
    bool ok = ParseCommandLine(
        "V2 42 1748736000000 1 200 0 0 600 40 1300 2 2000 -1000", &c);
    CHECK(ok, "v2 line parses (12 tokens after V2)");
    CHECK(c.enabled == 1, "v2 enabled from FLAG_ENABLED");
    // X_MOVE = k_x · vx · T/2 = 1 · 200 · 0.6/2 = 60.0
    CHECK_DEQ(c.x, 60.0, "v2 vx→X_MOVE (vx·T/2)");
    CHECK_DEQ(c.y, 0.0, "v2 vy zero");
    CHECK_DEQ(c.a, 0.0, "v2 wz zero → A zero");
    CHECK_DEQ(c.period, 600.0, "v2 period passthrough");
    CHECK_DEQ(c.foot, 40.0, "v2 foot passthrough");
    CHECK_DEQ(c.hip, 13.0, "v2 hip_cdeg 1300 → 13.0deg");
    CHECK_DEQ(c.head_pan, 20.0, "v2 pan_cdeg 2000 → 20.0deg");
    CHECK_DEQ(c.head_tilt, -10.0, "v2 tilt_cdeg -1000 → -10.0deg");
    CHECK(c.blevel == 2, "v2 blevel");
    CHECK(strcmp(c.cmd_id, "v2#42") == 0, "v2 cmd_id = v2#seq");
    CHECK(c.head_explicit, "v2 head_explicit when nonzero");
}

static void test_parse_v2_yaw_conversion() {
    printf("test_parse_v2_yaw_conversion\n");
    // wz = 1000 mrad/s = 1 rad/s, period 600 → T=0.6. A = 1·1·0.6/2·(180/π) = 0.3·57.2958 = 17.188deg
    WalkCommand c;
    bool ok = ParseCommandLine(
        "V2 1 0 1 0 0 1000 600 40 1300 2 0 0", &c);
    CHECK(ok, "v2 yaw line parses");
    CHECK(c.a > 17.0 && c.a < 17.4, "v2 wz 1000mrad/s → A≈17.19deg");
    // flags only ENABLED → balance off, balltrack off.
    CHECK(c.benable == 0, "v2 balance off (no FLAG_BALANCE_ENABLE)");
    CHECK(c.balltrack == 0, "v2 balltrack off");
}

static void test_parse_v2_flags() {
    printf("test_parse_v2_flags\n");
    WalkCommand c;
    // flags = ENABLED|BALANCE_ENABLE|BALLTRACK|GATE_SCHED_OFF = 1|2|4|8 = 15
    ParseCommandLine("V2 1 0 15 100 0 0 500 40 0 1 0 0", &c);
    CHECK(c.enabled == 1, "flags enabled");
    CHECK(c.benable == 1, "flags balance enable");
    CHECK(c.balltrack == 1, "flags balltrack");
    CHECK((c.flags & FLAG_GATE_SCHED_OFF) != 0, "flags gate-sched-off preserved");
    // disabled: flags=0
    WalkCommand c2;
    ParseCommandLine("V2 2 0 0 100 0 0 500 40 0 2 0 0", &c2);
    CHECK(c2.enabled == 0, "flags=0 → disabled");
}

static void test_parse_v2_rejects_short() {
    printf("test_parse_v2_rejects_short\n");
    WalkCommand c;
    CHECK(!ParseCommandLine("V2 1 0 1 100 0 0 600", &c), "v2 partial (8 tok) rejected");
    // v1 still works (no V2 prefix).
    CHECK(ParseCommandLine("idX 1 28 0 0 600 40 13 1 0 2 0 0 0", &c), "v1 still parses");
    CHECK_DEQ(c.x, 28.0, "v1 x intact after v2 branch added");
    CHECK(c.flags == 0, "v1 flags default 0 (gate ON)");
}

// ---- O2: envelope governor --------------------------------------------------

static void test_envelope_xmax_table() {
    printf("test_envelope_xmax_table\n");
    CHECK_DEQ(EnvelopeXMax(700), 40.0, "700ms → 40mm");
    CHECK_DEQ(EnvelopeXMax(600), 38.0, "600ms → 38mm");
    CHECK_DEQ(EnvelopeXMax(500), 32.0, "500ms → 32mm");
    CHECK_DEQ(EnvelopeXMax(440), 28.0, "440ms → 28mm");
    CHECK_DEQ(EnvelopeXMax(800), 40.0, "above 700 → clamp 40");
    CHECK_DEQ(EnvelopeXMax(400), 28.0, "below 440 → clamp 28");
    CHECK_DEQ(EnvelopeXMax(650), 39.0, "650ms → 39mm (interp 38..40)");
    CHECK_DEQ(EnvelopeXMax(550), 35.0, "550ms → 35mm (interp 32..38)");
}

static void test_governor_scaledown() {
    printf("test_governor_scaledown\n");
    // period 600 → x_max=38, y_max=22, a_max=12. Under-budget passes unchanged.
    double x = 19.0, y = 0.0, a = 0.0;  // 0.5 sum
    GovernEnvelope(&x, &y, &a, 600);
    CHECK_DEQ(x, 19.0, "under-budget x unchanged");

    // Over-budget: x=38(1.0)+y=22(1.0)+a=12(1.0) = 3.0 → scale 1.15/3.0.
    double x2 = 38.0, y2 = 22.0, a2 = 12.0;
    GovernEnvelope(&x2, &y2, &a2, 600);
    double sum = fabs(x2)/38.0 + fabs(y2)/22.0 + fabs(a2)/12.0;
    CHECK(sum > 1.149 && sum < 1.151, "over-budget scaled to sum≈1.15");
    CHECK(x2 > 14.5 && x2 < 14.7, "x scaled (38·1.15/3≈14.57)");

    // Direction preserved (signs).
    double x3 = -50.0, y3 = 0.0, a3 = 0.0;  // |x|/38 = 1.32 > 1.15
    GovernEnvelope(&x3, &y3, &a3, 600);
    CHECK(x3 < 0, "negative x stays negative");
    CHECK(fabs(x3) < 50.0, "|x| reduced toward x_max·1.15");
}

// ---- O2: latch slew ---------------------------------------------------------

static void test_slew_first_apply() {
    printf("test_slew_first_apply\n");
    SlewState st;
    double x = 30.0, y = 10.0, a = 8.0, p = 600.0;
    SlewToward(&st, &x, &y, &a, &p);
    CHECK(st.valid, "first apply sets valid");
    CHECK_DEQ(x, 30.0, "first apply accepts target (no slew)");
    CHECK_DEQ(a, 8.0, "first apply a accepted");
}

static void test_slew_clamps_delta() {
    printf("test_slew_clamps_delta\n");
    SlewState st;
    double x = 0, y = 0, a = 0, p = 600;
    SlewToward(&st, &x, &y, &a, &p);   // seed at 0
    // Step to large target — each axis clamped to its max delta.
    double x2 = 40.0, y2 = 30.0, a2 = 20.0, p2 = 440.0;
    SlewToward(&st, &x2, &y2, &a2, &p2);
    CHECK_DEQ(x2, 8.0, "x slew +8mm max");
    CHECK_DEQ(y2, 6.0, "y slew +6mm max");
    CHECK_DEQ(a2, 4.0, "a slew +4deg max");
    CHECK_DEQ(p2, 540.0, "period slew -60ms max (600→540)");
    // Negative direction clamps too.
    double x3 = -100, y3 = 0, a3 = 0, p3 = 600;
    SlewToward(&st, &x3, &y3, &a3, &p3);
    CHECK_DEQ(x3, 0.0, "x slew -8mm from 8 → 0");
}

static void test_slew_reaches_target() {
    printf("test_slew_reaches_target\n");
    SlewState st;
    double x = 0, y = 0, a = 0, p = 600;
    SlewToward(&st, &x, &y, &a, &p);   // seed
    // Within delta — target reached in one step.
    double x2 = 5.0, y2 = 0, a2 = 0, p2 = 600;
    SlewToward(&st, &x2, &y2, &a2, &p2);
    CHECK_DEQ(x2, 5.0, "small step reaches target");
}

static void test_slew_cadence_due() {
    printf("test_slew_cadence_due\n");
    // last==0 → always due (아직 미전진).
    CHECK(SlewCadenceDue(1000, 0, 600), "last=0 → due");
    // period 600 → half 300ms. 299 미만 not due, 300 이상 due.
    CHECK(!SlewCadenceDue(1299, 1000, 600), "299ms elapsed → not due (<300)");
    CHECK(SlewCadenceDue(1300, 1000, 600), "300ms elapsed → due (half-period)");
    CHECK(SlewCadenceDue(2000, 1000, 600), "1000ms elapsed → due");
    // period<=0 → fallback half 300ms.
    CHECK(!SlewCadenceDue(1200, 1000, 0), "period 0 → fallback 300, 200ms not due");
    CHECK(SlewCadenceDue(1300, 1000, 0), "period 0 → fallback 300, 300ms due");
    // 빠른 주기(440 → half 220).
    CHECK(SlewCadenceDue(1220, 1000, 440), "period 440 → half 220, due");
    CHECK(!SlewCadenceDue(1219, 1000, 440), "period 440 → half 220, 219 not due");
}

static void test_slew_at_target() {
    printf("test_slew_at_target\n");
    SlewState st;   // valid=false 초기
    CHECK(!SlewAtTarget(st, 0, 0, 0, 600), "invalid slew → not at target");
    double x = 30, y = 5, a = 4, p = 600;
    SlewToward(&st, &x, &y, &a, &p);   // seed valid at (30,5,4,600)
    CHECK(SlewAtTarget(st, 30, 5, 4, 600), "seeded value at target");
    CHECK(!SlewAtTarget(st, 38, 5, 4, 600), "different x → not at target");
    CHECK(!SlewAtTarget(st, 30, 5, 4, 540), "different period → not at target");
}

// [HIGH fix] 단발 명령(파일 경로) 후 루프 슬루 진행으로 목표 도달 시나리오.
// SlewToward 만 반복 호출(루프 측 진행 모사) → 첫 스텝 고착 없이 목표까지 램프.
static void test_slew_loop_progression_reaches_target() {
    printf("test_slew_loop_progression_reaches_target\n");
    SlewState st;
    // 정지→보행 재시드 모사: 0 에서 valid 시작.
    st.x = 0; st.y = 0; st.a = 0; st.period = 600; st.valid = true;
    double tx = 38.0, ty = 0.0, ta = 0.0, tp = 600.0;   // 단발 명령 목표 38mm.

    // 명령 도착 1회(첫 전진) — 0→8.
    double sx = tx, sy = ty, sa = ta, sp = tp;
    SlewToward(&st, &sx, &sy, &sa, &sp);
    CHECK_DEQ(st.x, 8.0, "명령 도착 첫 전진 0→8mm");
    CHECK(!SlewAtTarget(st, tx, ty, ta, tp), "아직 목표 미도달(고착 지점)");

    // 루프 측 진행 — 재송신 없이 SlewToward 반복으로 목표 도달.
    int steps = 0;
    while (!SlewAtTarget(st, tx, ty, ta, tp) && steps < 50) {
        double lx = tx, ly = ty, la = ta, lp = tp;
        SlewToward(&st, &lx, &ly, &la, &lp);
        steps++;
    }
    CHECK(SlewAtTarget(st, tx, ty, ta, tp), "루프 진행으로 목표 도달(고착 해소)");
    CHECK_DEQ(st.x, 38.0, "최종 38mm 도달");
    // 0→8→16→24→32→38: 첫 전진 후 추가 4스텝(8·8·8·6) = 5스텝째 도달.
    CHECK(steps == 4, "8mm/스텝으로 38mm 까지 추가 4스텝(첫 전진 포함 5)");
}

// ---- O2: balance gain scale -------------------------------------------------

static void test_balance_gain_scale() {
    printf("test_balance_gain_scale\n");
    CHECK_DEQ(BalanceGainScale(0), 0.0, "blevel 0 → 0 (off)");
    CHECK_DEQ(BalanceGainScale(1), 0.5, "blevel 1 → 0.5");
    CHECK_DEQ(BalanceGainScale(2), 1.0, "blevel 2 → 1.0 (default)");
    CHECK_DEQ(BalanceGainScale(3), 1.5, "blevel 3 → 1.5");
    CHECK_DEQ(BalanceGainScale(9), 1.5, "blevel >3 → 1.5 clamp");
    CHECK_DEQ(BalanceGainScale(-2), 0.0, "blevel <0 → 0 clamp");
    // base gains applied: knee 0.3 × 1.5 = 0.45.
    CHECK_DEQ(BASE_BALANCE_KNEE_GAIN * BalanceGainScale(3), 0.45, "knee×1.5=0.45");
}

// ---- O2: gate schedule ------------------------------------------------------

static void test_gate_schedule() {
    printf("test_gate_schedule\n");
    // period 600 → x_max 38. threshold 0.7 → 26.6mm. Below = no boost.
    GateBoost low = GateSchedule(20.0, 600, 0);
    CHECK_DEQ(low.z_move, 0.0, "below threshold → no z boost");
    CHECK_DEQ(low.y_swap, 0.0, "below threshold → no y_swap boost");

    // At x_max (ratio 1.0) → full boost.
    GateBoost full = GateSchedule(38.0, 600, 0);
    CHECK_DEQ(full.z_move, 5.0, "at x_max → +5mm Z_MOVE");
    CHECK_DEQ(full.y_swap, 2.0, "at x_max → +2mm Y_SWAP");
    CHECK_DEQ(full.hip, 1.5, "at x_max → +1.5deg HIP");

    // Midway: ratio 0.85 (x=32.3) → t = (0.85-0.7)/0.3 = 0.5 → half boost.
    GateBoost mid = GateSchedule(32.3, 600, 0);
    CHECK(mid.z_move > 2.4 && mid.z_move < 2.6, "midway → ~half z boost");

    // flags OFF → no boost regardless.
    GateBoost off = GateSchedule(38.0, 600, FLAG_GATE_SCHED_OFF);
    CHECK_DEQ(off.z_move, 0.0, "FLAG_GATE_SCHED_OFF → no boost");
}

// ---- O4: CommandSlot.Take seq_out -------------------------------------------

static void test_slot_take_seq_out() {
    printf("test_slot_take_seq_out\n");
    CommandSlot slot;
    char out[256];
    long long seq = -1;
    // 스트림 소스(seq==0) — 내부 카운터가 적용 seq 를 부여(1,2,..).
    slot.Offer("a", 0);
    slot.Offer("b", 0);   // latest-wins, 카운터는 2.
    CHECK(slot.Take(out, sizeof(out), &seq), "stream take true");
    CHECK(strcmp(out, "b") == 0, "latest line");
    CHECK(seq == 2, "stream seq_out = internal counter (2)");

    // UDP 소스 — datagram seq 가 그대로.
    CommandSlot slot2;
    long long seq2 = -1; char out2[256];
    slot2.Offer("u", 77);
    CHECK(slot2.Take(out2, sizeof(out2), &seq2), "udp take true");
    CHECK(seq2 == 77, "udp seq_out = datagram seq (77)");

    // seq_out NULL 안전(기존 2-인자 호출 호환).
    CommandSlot slot3;
    char out3[256];
    slot3.Offer("x", 0);
    CHECK(slot3.Take(out3, sizeof(out3)), "2-arg take still works (default seq_out=0)");
}

// ---- O4: TEL2 formatter -----------------------------------------------------

static void test_format_tel2_full() {
    printf("test_format_tel2_full\n");
    char buf[320];
    int fsr8[8] = { 100, 110, 120, 130, 140, 150, 160, 170 };
    int n = FormatTel2(buf, sizeof(buf),
                       1748736000123LL, 42, 2,
                       28.0, 10.0, 5.0, 600.0,
                       511, 530, 498, 512, 489, 760,
                       true, fsr8,
                       true, 20, -5,
                       0, false, 0.0,
                       122, "udp", 18);
    const char* expect =
        "TEL2 1748736000123 42 2 28.00 10.00 5.00 600.00 "
        "511 530 498 512 489 760 100 110 120 130 140 150 160 170 20 -5 0 - 122 udp 18\n";
    CHECK(n == (int)strlen(expect), "tel2 full length matches");
    CHECK(strcmp(buf, expect) == 0, "tel2 full line exact");
}

static void test_format_tel2_fsr_missing() {
    printf("test_format_tel2_fsr_missing\n");
    char buf[320];
    // FSR 미장착(OP1/PING 실패) → fsr "-", cop "-". risk 미구현 "-". active=file.
    int n = FormatTel2(buf, sizeof(buf),
                       1000LL, 7, 0,
                       0.0, 0.0, 0.0, 600.0,
                       512, 512, 512, 512, 512, 700,
                       false, 0,
                       false, 0, 0,
                       -1, false, 0.0,
                       0, "file", 5);
    const char* expect =
        "TEL2 1000 7 0 0.00 0.00 0.00 600.00 "
        "512 512 512 512 512 700 - - -1 - 0 file 5\n";
    CHECK(n == (int)strlen(expect), "tel2 fsr-missing length");
    CHECK(strcmp(buf, expect) == 0, "tel2 fsr/cop '-' fallback exact");
}

static void test_format_tel2_risk_present() {
    printf("test_format_tel2_risk_present\n");
    char buf[320];
    int fsr8[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
    // forward-compat: risk_present → 소수 2자리. (O3 결선 시 사용 — 자리 검증.)
    FormatTel2(buf, sizeof(buf),
               2000LL, 1, 1,
               12.0, 0.0, 0.0, 500.0,
               500, 500, 500, 500, 500, 700,
               true, fsr8,
               true, 0, 0,
               0, true, 16.25,
               120, "udp", 20);
    CHECK(strstr(buf, " 16.25 ") != 0, "risk present → 16.25 formatted");
    CHECK(strstr(buf, " - ") == 0, "no '-' tokens when fsr/cop/risk all present");
}

// ---- 실기 F8 — ServoGuardDecide (서보 셧다운 복원 판정) ----------------------

static void test_servo_guard_decide() {
    printf("test_servo_guard_decide\n");
    // 무응답 — 추측 복원 금지.
    CHECK(ServoGuardDecide(false, 0, true, 30) == SG_NONE, "no-reply -> NONE");
    // 정상 서보(tl>0) — err 비트와 무관하게 복원 대상 아님.
    CHECK(ServoGuardDecide(true, 1023, true, 45) == SG_NONE, "healthy 1023 -> NONE");
    CHECK(ServoGuardDecide(true, 1, true, 45) == SG_NONE, "tl=1 -> NONE");
    // 셧다운 래치(tl==0) + 안전 온도 — 복원.
    CHECK(ServoGuardDecide(true, 0, true, 45) == SG_RESTORE, "latch cool -> RESTORE");
    CHECK(ServoGuardDecide(true, 0, true, SG_TEMP_SAFE_C) == SG_RESTORE,
          "boundary 65C -> RESTORE");
    CHECK(ServoGuardDecide(true, 0, true, 0) == SG_RESTORE, "cold -> RESTORE");
    // 과열 — 냉각 전 복원 보류(다음 복구 때 재시도).
    CHECK(ServoGuardDecide(true, 0, true, SG_TEMP_SAFE_C + 1) == SG_SKIP_HOT,
          "66C -> SKIP_HOT");
    CHECK(ServoGuardDecide(true, 0, true, 90) == SG_SKIP_HOT, "90C -> SKIP_HOT");
    // 온도 미상 — 보수적 보류.
    CHECK(ServoGuardDecide(true, 0, false, -1) == SG_SKIP_HOT, "temp unknown -> SKIP_HOT");
    // 실기 재현 케이스(2026-06-12): 양 발목 피치 ID15/16 err=0x20, tl=0, 43~45C → 복원.
    CHECK(ServoGuardDecide(true, 0, true, 43) == SG_RESTORE, "field ID16 -> RESTORE");
    CHECK(ServoGuardDecide(true, 0, true, 45) == SG_RESTORE, "field ID15 -> RESTORE");
    // 상수 핀 — 프로토콜/프레임워크(MX28.h) 고정값과 일치해야 한다.
    CHECK(SG_ADDR_TORQUE_LIMIT_L == 34, "addr34 pin");
    CHECK(SG_ADDR_PRESENT_TEMPERATURE == 43, "addr43 pin");
    CHECK(SG_TORQUE_LIMIT_RESTORE == 1023, "restore 1023 pin");
    CHECK(DXL_ERR_OVERLOAD == 0x20 && DXL_ERR_OVERHEAT == 0x04, "err bits pin");
    CHECK(SG_JOINT_ID_MIN == 1 && SG_JOINT_ID_MAX == 20, "id range pin");
}

int main() {
    printf("=== WalkLabTransport host unit tests ===\n");
    test_parse_full_line();
    test_parse_clamps();
    test_parse_backward_compat();
    test_parse_rejects_short();
    test_slot_stream_latest_wins();
    test_slot_udp_seq_monotonic();
    test_slot_equal_seq_rejected();
    test_watchdog_tiers();
    test_watchdog_stream_only();
    test_estop_datagram();
    test_cmd_datagram();
    test_parse_v2_twist();
    test_parse_v2_yaw_conversion();
    test_parse_v2_flags();
    test_parse_v2_rejects_short();
    test_envelope_xmax_table();
    test_governor_scaledown();
    test_slew_first_apply();
    test_slew_clamps_delta();
    test_slew_reaches_target();
    test_slew_cadence_due();
    test_slew_at_target();
    test_slew_loop_progression_reaches_target();
    test_balance_gain_scale();
    test_gate_schedule();
    test_slot_take_seq_out();
    test_format_tel2_full();
    test_format_tel2_fsr_missing();
    test_format_tel2_risk_present();
    test_servo_guard_decide();

    printf("=== %d checks, %d failures ===\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
