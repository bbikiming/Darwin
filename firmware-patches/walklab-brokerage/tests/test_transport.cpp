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

    printf("=== %d checks, %d failures ===\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
