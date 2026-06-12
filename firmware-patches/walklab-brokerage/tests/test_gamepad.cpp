/*
 * test_gamepad.cpp — host unit tests for GamepadPilot (H1+H2 pure logic + 상태기계).
 *
 * 로봇 toolchain·Robot:: 프레임워크 불요 — GamepadPilot.cpp + WalkLabTransport.cpp 만
 * 링크. 장치 I/O 없이 주입(InjectEventForTest 등)으로 전체 상태기계를 구동한다.
 * 외부 테스트 프레임워크 없이 매크로 assert. 실패 시 비-0 exit + 메시지.
 *
 *   make -C firmware-patches/walklab-brokerage/tests
 *
 * 검증 범위(P7): 16B 디코더 · 매핑 전수(부호/데드존/곡선/트리거 차분/터보/게이트) ·
 * 성형 스케줄 · 중재 우선순위(HasControl 1s 창 — supervisor 게이트는 로봇측) ·
 * ARM/재 ARM(settle·estop 우선) · 3티어 failsafe(release→ENODEV / ENODEV 단독 /
 * 무이벤트 1.5s 오발) · 라인 빌더 왕복(ParseCommandLine 정합).
 */

#include "../GamepadPilot.h"
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
#define CHECK_NEAR(a, b, tol, msg) CHECK(fabs((double)(a) - (double)(b)) < (tol), msg)

// ---- 헬퍼 -------------------------------------------------------------------

static GpEvent Ev(unsigned short type, unsigned short code, int value) {
    GpEvent e;
    e.type = type;
    e.code = code;
    e.value = value;
    return e;
}

static GpEvent Syn() { return Ev(GP_EV_SYN, GP_SYN_REPORT, 0); }

static int g_estop_calls = 0;
static int g_recover_calls = 0;
static void OnEstop(void*) { g_estop_calls++; }
static void OnRecover(void*) { g_recover_calls++; }

static void ResetCallbacks() { g_estop_calls = 0; g_recover_calls = 0; }

// 슬롯에서 라인 take + 파싱. 라인이 없으면 false.
static bool TakeParsed(GamepadPilot& p, WalkCommand* out) {
    char line[256];
    if (!p.TakeCommand(line, sizeof(line))) return false;
    return ParseCommandLine(line, out);
}

static void DrainSlot(GamepadPilot& p) {
    char line[256];
    while (p.TakeCommand(line, sizeof(line))) {}
}

// ---- 16B 디코더 (H0: i686 timeval 8 + type 2 + code 2 + value 4, LE) ---------

static void test_decode_raw16() {
    printf("test_decode_raw16\n");
    // EV_ABS / ABS_X / value=-32768 (0xFFFF8000 LE). 타임스탬프 8B 는 무시.
    unsigned char raw[16] = { 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44,
                              0x03, 0x00,   /* type  = EV_ABS  */
                              0x00, 0x00,   /* code  = ABS_X   */
                              0x00, 0x80, 0xFF, 0xFF };
    GpEvent ev;
    DecodeGamepadEvent(raw, &ev);
    CHECK(ev.type == GP_EV_ABS, "type EV_ABS");
    CHECK(ev.code == GP_ABS_X, "code ABS_X");
    CHECK(ev.value == -32768, "value -32768 (signed LE)");

    // EV_KEY / BTN_B(305=0x131) / value=1.
    unsigned char raw2[16] = { 0,0,0,0,0,0,0,0,
                               0x01, 0x00, 0x31, 0x01, 0x01, 0x00, 0x00, 0x00 };
    DecodeGamepadEvent(raw2, &ev);
    CHECK(ev.type == GP_EV_KEY, "type EV_KEY");
    CHECK(ev.code == GP_BTN_B, "code BTN_B(305)");
    CHECK(ev.value == 1, "value 1");

    // EV_ABS / ABS_RZ(5) / value=255 (트리거 풀).
    unsigned char raw3[16] = { 0,0,0,0,0,0,0,0,
                               0x03, 0x00, 0x05, 0x00, 0xFF, 0x00, 0x00, 0x00 };
    DecodeGamepadEvent(raw3, &ev);
    CHECK(ev.code == GP_ABS_RZ && ev.value == 255, "ABS_RZ 255");
}

static void test_decoder_syn_commit() {
    printf("test_decoder_syn_commit\n");
    GamepadDecoder d;
    GamepadSnapshot s;
    // SYN 전에는 커밋 없음 — 축 일관성 보장(H1-2).
    CHECK(d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_X, 32767), &s) == 0, "ABS_X no commit");
    CHECK(d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_Y, -16384), &s) == 0, "ABS_Y no commit");
    CHECK(d.FeedEvent(Ev(GP_EV_KEY, GP_BTN_LB, 1), &s) == 0, "LB no commit");
    int fr = d.FeedEvent(Syn(), &s);
    CHECK(fr & GP_FEED_COMMITTED, "SYN commits");
    CHECK_NEAR(s.lx, 1.0, 1e-4, "lx=+1 (32767)");
    CHECK_NEAR(s.ly, -0.5, 1e-3, "ly≈-0.5 (-16384)");
    CHECK(s.btn_lb, "LB held in snapshot");
    // 미지 코드(Back=314)는 무시 — 예약.
    CHECK(d.FeedEvent(Ev(GP_EV_KEY, GP_BTN_BACK, 1), &s) == 0, "reserved key ignored");
    CHECK(!d.ButtonState(GP_BTN_BACK), "reserved key not tracked");
}

static void test_decoder_normalization() {
    printf("test_decoder_normalization\n");
    GamepadDecoder d;
    GamepadSnapshot s;
    d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_X, -32768), &s);
    d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_Z, 255), &s);
    d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_RZ, 128), &s);
    d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_HAT0X, 1), &s);
    d.FeedEvent(Ev(GP_EV_ABS, GP_ABS_HAT0Y, -1), &s);
    d.FeedEvent(Syn(), &s);
    CHECK_DEQ(s.lx, -1.0, "스틱 -32768 → -1.0 클램프");
    CHECK_DEQ(s.lt, 1.0, "트리거 255 → 1.0");
    CHECK_NEAR(s.rt, 128.0 / 255.0, 1e-6, "트리거 128 → ~0.502");
    CHECK(s.hat_x == 1 && s.hat_y == -1, "D-pad ±1 (디코드만 — 1차 미배선)");
}

static void test_decoder_force_commit() {
    printf("test_decoder_force_commit\n");
    GamepadDecoder d;
    GamepadSnapshot s;
    d.FeedEvent(Ev(GP_EV_KEY, GP_BTN_LB, 1), &s);
    d.FeedEvent(Syn(), &s);
    // release 합성이 SYN 없이 끊긴 시나리오 — pending 강제 커밋(H2 ①티어 정합).
    d.FeedEvent(Ev(GP_EV_KEY, GP_BTN_LB, 0), &s);
    GamepadSnapshot forced;
    CHECK(d.ForceCommit(&forced), "미커밋 변경 있음 — true");
    CHECK(!forced.btn_lb, "데드맨 해제 반영");
    CHECK(!d.ForceCommit(&forced), "재호출 — 변경 없음 false");
}

// ---- 매핑: 데드존·곡선·트리거 차분 -------------------------------------------

static void test_deadzone_curve() {
    printf("test_deadzone_curve\n");
    CHECK_DEQ(GpApplyDeadzone(0.05), 0.0, "데드존 내 → 0");
    CHECK_DEQ(GpApplyDeadzone(-0.0999), 0.0, "데드존 경계 내(음) → 0");
    CHECK_NEAR(GpApplyDeadzone(0.55), 0.5, 1e-9, "0.55 → (0.55-0.1)/0.9 = 0.5");
    CHECK_DEQ(GpApplyDeadzone(1.0), 1.0, "풀스틱 → 1");
    CHECK_DEQ(GpApplyDeadzone(-1.0), -1.0, "풀스틱(음) → -1 (부호 보존)");
    // 곡선 1.35: 0.5^1.35 ≈ 0.39229.
    CHECK_NEAR(GpShapeDriveAxis(0.55), 0.39229, 1e-3, "곡선 1.35 중간값");
    CHECK_NEAR(GpShapeDriveAxis(-0.55), -0.39229, 1e-3, "곡선 부호 보존");
    CHECK_DEQ(GpShapeDriveAxis(1.0), 1.0, "곡선 풀스틱 = 1");
    CHECK_DEQ(GpShapeDriveAxis(0.08), 0.0, "곡선 데드존 내 = 0");
}

static void test_trigger_diff() {
    printf("test_trigger_diff\n");
    CHECK_DEQ(GpTriggerDiff(0.0, 0.0), 0.0, "휴지 → 0");
    CHECK_DEQ(GpTriggerDiff(1.0, 0.0), 1.0, "RT 풀 → +1");
    CHECK_DEQ(GpTriggerDiff(0.0, 1.0), -1.0, "LT 풀 → -1");
    CHECK_DEQ(GpTriggerDiff(0.52, 0.5), 0.0, "차분 0.02 < 데드존 0.05 → 0");
    CHECK_NEAR(GpTriggerDiff(0.55, 0.0), (0.55 - 0.05) / 0.95, 1e-9, "차분 재스케일");
    CHECK_DEQ(GpTriggerDiff(1.0, 1.0), 0.0, "양 트리거 풀 → 상쇄 0");
}

// ---- 매핑: 부호·게이트·터보·hold ---------------------------------------------

static void test_mapping_signs() {
    printf("test_mapping_signs\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    // 풀스틱 전진(위=raw −) + 우횡 + 우턴 + 머리들기(위=raw −) + RT 풀 — armed+LB.
    s.ly = -1.0; s.lx = 1.0; s.rx = 1.0; s.ry = -1.0; s.rt = 1.0; s.lt = 0.0;
    s.btn_lb = true;
    MapGamepad(s, true, &hold, &f);
    CHECK(f.enabled == 1, "armed+데드맨+이동 → enabled");
    CHECK_NEAR(f.x, GP_MAX_STRIDE_MM, 1e-6, "스틱 위 → 전진 +38 (ABS_Y 아래=+ 실측)");
    CHECK_NEAR(f.y, -GP_MAX_SIDE_MM, 1e-6, "스틱 우 → 우횡 −22 (Y_MOVE+=좌)");
    CHECK_NEAR(f.a, -GP_MAX_TURN_DEG, 1e-6, "RS 우 → 우회전 −12 (A_MOVE+=좌)");
    CHECK_NEAR(f.tilt, GP_MAX_HEAD_TILT_DEG, 1e-6, "RS 위 → 머리들기 +35");
    CHECK_NEAR(f.pan, -GP_MAX_HEAD_PAN_DEG, 1e-6, "RT → 우팬 −70 (pan+=좌)");
    CHECK_DEQ(f.hip, GP_HIP_DEG, "hip 고정 13");
}

static void test_mapping_gates() {
    printf("test_mapping_gates\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    s.ly = -1.0; s.ry = -1.0;
    // 데드맨 미홀드 — 이동 잠금, 머리는 비게이트(H1-4: 이동/턴만 게이트).
    s.btn_lb = false;
    MapGamepad(s, true, &hold, &f);
    CHECK(f.enabled == 0, "데드맨 해제 → 이동 게이트 잠금");
    CHECK_DEQ(f.x, 0.0, "x=0");
    CHECK_NEAR(f.tilt, GP_MAX_HEAD_TILT_DEG, 1e-6, "머리는 비게이트 — 틸트 통과");
    // ARM 전 — 데드맨 홀드여도 이동 잠금 (H2-2).
    s.btn_lb = true;
    MapGamepad(s, false, &hold, &f);
    CHECK(f.enabled == 0, "ARM 전 → 이동 게이트 잠금");
    // armed+데드맨인데 스틱 중립 — enabled 0 (정지).
    GamepadSnapshot idle;
    idle.btn_lb = true;
    MapGamepad(idle, true, &hold, &f);
    CHECK(f.enabled == 0, "이동 입력 없음 → enabled 0");
}

static void test_mapping_turbo() {
    printf("test_mapping_turbo\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    s.ly = -0.55; s.btn_lb = true;
    MapGamepad(s, true, &hold, &f);
    double base_x = f.x;   // 0.39229 × 38 ≈ 14.91
    CHECK_NEAR(base_x, 0.39229 * GP_MAX_STRIDE_MM, 0.05, "터보 OFF 기준값");
    s.btn_rb = true;
    MapGamepad(s, true, &hold, &f);
    CHECK_NEAR(f.x, 0.39229 * GP_TURBO_SCALE * GP_MAX_STRIDE_MM, 0.05,
               "터보 ×1.3 (콕핏 turboScale 패리티)");
    // 풀스틱 + 터보 — ±1 클램프로 38 초과 금지.
    s.ly = -1.0;
    MapGamepad(s, true, &hold, &f);
    CHECK_NEAR(f.x, GP_MAX_STRIDE_MM, 1e-6, "터보 풀스틱 → ±1 클램프 (38 초과 금지)");
}

static void test_mapping_head_hold() {
    printf("test_mapping_head_hold\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    s.rt = 1.0;
    MapGamepad(s, true, &hold, &f);
    CHECK_NEAR(f.pan, -GP_MAX_HEAD_PAN_DEG, 1e-6, "팬 명령");
    // 트리거 해제 — 직전 각 유지(switch hold_head 패리티).
    GamepadSnapshot rest;
    MapGamepad(rest, true, &hold, &f);
    CHECK_NEAR(f.pan, -GP_MAX_HEAD_PAN_DEG, 1e-6, "트리거 해제 → 팬 유지");
}

// ---- 성형 스케줄 (intensity^0.7 → period/foot) -------------------------------

static void test_gait_schedule() {
    printf("test_gait_schedule\n");
    double period = 0.0, foot = 0.0;
    GpGaitSchedule(0.0, 0.0, 0.0, 0, &period, &foot);
    CHECK_DEQ(period, GP_GAIT_PERIOD_DEFAULT, "정지 → period 600 (스케줄 비적용)");
    CHECK_DEQ(foot, GP_GAIT_FOOT_DEFAULT, "정지 → foot 40");
    GpGaitSchedule(GP_MAX_STRIDE_MM, 0.0, 0.0, 1, &period, &foot);
    CHECK_DEQ(period, GP_GAIT_PERIOD_MIN_MS, "풀스틱 → period 560 (최속)");
    CHECK_DEQ(foot, GP_GAIT_FOOT_MAX_MM, "풀스틱 → foot 40");
    GpGaitSchedule(0.0, 0.0, 0.0, 1, &period, &foot);
    CHECK_DEQ(period, GP_GAIT_PERIOD_MAX_MS, "강도 0 → period 700 (최저속)");
    CHECK_DEQ(foot, GP_GAIT_FOOT_MIN_MM, "강도 0 → foot 18");
    // 중간 강도 0.5 → shaped = 0.5^0.7 ≈ 0.61557.
    GpGaitSchedule(19.0, 0.0, 0.0, 1, &period, &foot);
    CHECK_NEAR(period, 700.0 - 140.0 * 0.61557, 0.1, "중간 강도 period ≈ 613.8");
    CHECK_NEAR(foot, 18.0 + 22.0 * 0.61557, 0.1, "중간 강도 foot ≈ 31.5");
    // intensity = max(전후/횡/턴) — 턴 단독도 강도에 산입.
    GpGaitSchedule(0.0, 0.0, GP_MAX_TURN_DEG, 1, &period, &foot);
    CHECK_DEQ(period, GP_GAIT_PERIOD_MIN_MS, "풀턴 → period 560");
}

// ---- 라인 빌더 (v1 14-token — 형식 불변·ParseCommandLine 왕복) ----------------

static void test_line_builder_roundtrip() {
    printf("test_line_builder_roundtrip\n");
    GamepadWalkFields f;
    f.enabled = 1;
    f.x = 12.34; f.y = -5.6; f.a = 3.21;
    f.period = 613.8; f.foot = 31.5; f.hip = 13.0;
    f.pan = -70.0; f.tilt = 35.0;
    char line[192];
    int n = BuildGamepadLine(line, sizeof(line), 7, f, 1);
    CHECK(n > 0 && n < (int)sizeof(line), "빌드 성공");
    // 토큰 수 = 14 (P9 — 토큰 추가 금지).
    int tokens = 1;
    for (const char* p = line; *p; p++) if (*p == ' ') tokens++;
    CHECK(tokens == 14, "정확히 14 토큰");
    WalkCommand c;
    CHECK(ParseCommandLine(line, &c), "ParseCommandLine 왕복 파싱");
    CHECK(strcmp(c.cmd_id, "gp7") == 0, "cmd_id gp{seq}");
    CHECK(c.enabled == 1, "enabled");
    CHECK_NEAR(c.x, 12.34, 1e-6, "x 왕복");
    CHECK_NEAR(c.y, -5.6, 1e-6, "y 왕복");
    CHECK_NEAR(c.a, 3.21, 1e-6, "a 왕복");
    CHECK_NEAR(c.period, 614.0, 1e-6, "period %.0f 반올림");
    CHECK_NEAR(c.foot, 32.0, 1e-6, "foot %.0f 반올림");
    CHECK(c.blevel == 2, "blevel=2 (×1.0 종전 게인)");
    CHECK(c.balltrack == 1, "balltrack 토큰");
    CHECK_NEAR(c.head_pan, -70.0, 1e-6, "pan 왕복 (클램프 ±90 내)");
    CHECK_NEAR(c.head_tilt, 35.0, 1e-6, "tilt 왕복");
}

// ---- settle / failsafe 판정 (순수) -------------------------------------------

static void test_settle() {
    printf("test_settle\n");
    CHECK(SettleArmed(false, true, false) == true, "ARM edge → armed");
    CHECK(SettleArmed(true, false, true) == false, "estop edge → disarm");
    CHECK(SettleArmed(false, true, true) == false, "같은 틱 ARM+estop → estop 승리");
    CHECK(SettleArmed(true, false, false) == true, "무 edge → 유지");
    CHECK(SettleArmed(false, false, false) == false, "무 edge → 유지(false)");
}

static void test_failsafe_decision() {
    printf("test_failsafe_decision\n");
    // 정상: 노드 ok + 이벤트 신선.
    CHECK(GamepadFailsafeDecision(2000, 1000, true, true) == GP_FS_NONE,
          "침묵 1000ms < 1500 → NONE");
    CHECK(GamepadFailsafeDecision(2499, 1000, true, true) == GP_FS_NONE,
          "침묵 1499ms → NONE (경계)");
    // ③티어: 이벤트 침묵 ≥1.5s.
    CHECK(GamepadFailsafeDecision(2500, 1000, true, true) == GP_FS_SLEW_ZERO,
          "침묵 1500ms → SLEW_ZERO (③)");
    // ②티어: 노드 소멸 — 침묵 시간 무관 즉시.
    CHECK(GamepadFailsafeDecision(1001, 1000, false, true) == GP_FS_SLEW_ZERO,
          "노드 소멸 → SLEW_ZERO (②, 즉시)");
    // 장치를 한 번도 못 본 상태 — 발화 금지(패드 미연결 = 무동작 자연 게이트).
    CHECK(GamepadFailsafeDecision(99999, 0, false, false) == GP_FS_NONE,
          "장치 이력 없음 → NONE");
}

// ---- GamepadPilot 상태기계 (주입 구동) ----------------------------------------

static void test_pilot_arm_and_estop() {
    printf("test_pilot_arm_and_estop\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    CHECK(!p.ArmedForTest(), "획득 직후 — ARM 전 잠금");
    CHECK(p.DevicePresent(), "노드 보유");
    // A rising + SYN → ARM.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(p.ArmedForTest(), "A → armed");
    // B rising — SYN 대기 없이 즉시 콜백(불변식: E-STOP 이 모든 것보다 먼저).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1020);
    CHECK(g_estop_calls == 1, "B → estop 콜백 즉시 (SYN 전)");
    CHECK(!p.ArmedForTest(), "B → 즉시 disarm");
    p.InjectEventForTest(Syn(), 1020);
    // 재 ARM.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 0), 1030);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 0), 1030);
    p.InjectEventForTest(Syn(), 1030);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1040);
    p.InjectEventForTest(Syn(), 1040);
    CHECK(p.ArmedForTest(), "estop 후 A → 재 ARM");
    p.Stop();
}

static void test_pilot_estop_wins_same_tick() {
    printf("test_pilot_estop_wins_same_tick\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    // 같은 SYN 배치에 A 와 B — settle 규칙: estop 승리.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(!p.ArmedForTest(), "같은 틱 A+B → estop 승리(disarm)");
    CHECK(g_estop_calls == 1, "estop 콜백 발화");
    p.Stop();
}

static void test_pilot_recover() {
    printf("test_pilot_recover\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    // Y — 복구(estop flag 해제 콜백) + ARM 의도(settle 이식).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_Y, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(g_recover_calls == 1, "Y → recover 콜백");
    CHECK(p.ArmedForTest(), "Y → ARM (settle: recover=arm 의도)");
    // Y+B 같은 틱 — estop 승리: recover 미발화.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_Y, 0), 1020);
    p.InjectEventForTest(Syn(), 1020);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_Y, 1), 1030);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1030);
    p.InjectEventForTest(Syn(), 1030);
    CHECK(g_recover_calls == 1, "같은 틱 Y+B → recover 억제 (estop 승리)");
    CHECK(g_estop_calls == 1, "estop 은 발화");
    p.Stop();
}

static void test_pilot_line_flow_and_arbitration_window() {
    printf("test_pilot_line_flow_and_arbitration_window\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    DrainSlot(p);
    // LB 홀드 + 풀스틱 전진 → enabled=1 라인.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1020);
    p.InjectEventForTest(Syn(), 1020);
    WalkCommand c;
    CHECK(TakeParsed(p, &c), "이동 라인 발행");
    CHECK(c.enabled == 1, "enabled=1");
    CHECK_NEAR(c.x, GP_MAX_STRIDE_MM, 0.01, "x=+38 (전진)");
    CHECK_NEAR(c.period, 560.0, 1e-6, "성형: 풀스틱 period 560");
    char tmp[256];
    CHECK(!p.TakeCommand(tmp, sizeof(tmp)), "take 후 슬롯 비움 (latest-wins drain)");
    // H2-1 중재 창: 마지막 이벤트 ≤1s 만 local 우선.
    CHECK(p.HasControl(1500), "이벤트 +480ms → local 우선");
    CHECK(p.HasControl(2020), "이벤트 +1000ms (경계) → local 우선");
    CHECK(!p.HasControl(2021), "이벤트 +1001ms → 네트워크 복귀");
    p.Stop();
}

static void test_pilot_refresh_cadence() {
    printf("test_pilot_refresh_cadence\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1010);
    p.InjectEventForTest(Syn(), 1010);
    DrainSlot(p);
    char line[256];
    // 정적 홀드(이벤트 0) — 50ms cadence 재공급으로 스트림 워치독 餓死 방지.
    p.TickForTest(1030);
    CHECK(!p.TakeCommand(line, sizeof(line)), "20ms — refresh 전 (cadence 50ms)");
    p.TickForTest(1070);
    CHECK(p.TakeCommand(line, sizeof(line)), "60ms — 보유 상태 재공급");
    WalkCommand c;
    CHECK(ParseCommandLine(line, &c) && c.enabled == 1, "재공급 라인 = 보유 이동 상태");
    // ③티어 진입(침묵 ≥1.5s) 후에는 재공급 중단 — 제자리 슬루로 인계.
    p.TickForTest(1010 + 1600);
    CHECK(!p.TakeCommand(line, sizeof(line)), "침묵 1.6s — 재공급 중단 (③ 인계)");
    p.Stop();
}

static void test_pilot_tier1_release_then_enodev() {
    printf("test_pilot_tier1_release_then_enodev (graceful 단절 — H0 §5 실측 시퀀스)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1010);
    p.InjectEventForTest(Syn(), 1010);
    WalkCommand c;
    CHECK(TakeParsed(p, &c) && c.enabled == 1, "주행 중");
    // ①티어: 커널 release 합성(LB keyup) + SYN → 데드맨 해제 = 이동 게이트 즉시 잠금.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 2000);
    p.InjectEventForTest(Syn(), 2000);
    CHECK(TakeParsed(p, &c), "release 라인 발행");
    CHECK(c.enabled == 0, "①티어: 데드맨 해제 → enabled=0 (즉시 정지)");
    // ~1ms 뒤 ENODEV(②티어) — disarm + 최종 정지 라인 + SLEW_ZERO.
    p.InjectNodeLostForTest(2001);
    CHECK(!p.ArmedForTest(), "②티어: disarm (재 ARM 필수)");
    CHECK(TakeParsed(p, &c) && c.enabled == 0, "최종 정지 라인");
    CHECK(p.PollFailsafe(2010) == GP_FS_SLEW_ZERO, "②티어: SLEW_ZERO (재획득 전 지속)");
    CHECK(p.HasControl(2500), "마지막 이벤트 +500ms — 정지 라인 적용 창 유지");
    CHECK(!p.HasControl(3100), "+1.1s — local 우선 해제");
    // 재전원 → 재획득(~1.3s 실측) → 재 ARM 필수.
    p.InjectAdoptForTest(3300);
    CHECK(p.PollFailsafe(3400) == GP_FS_NONE, "재획득 → failsafe 해제");
    CHECK(!p.ArmedForTest(), "재획득 후에도 ARM 전 잠금");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 3500);
    p.InjectEventForTest(Syn(), 3500);
    CHECK(p.ArmedForTest(), "A → 재 ARM 완료");
    p.Stop();
}

static void test_pilot_tier2_enodev_without_release() {
    printf("test_pilot_tier2_enodev_without_release (release 미합성 — SYN 유실)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1010);
    p.InjectEventForTest(Syn(), 1010);
    DrainSlot(p);
    // release 이벤트가 SYN 없이 끊긴 케이스 — ForceCommit 이 pending 을 커밋
    // → 데드맨 해제 관측 = ①티어로 취급, 정지 라인 발행.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 2000);
    p.InjectNodeLostForTest(2001);
    WalkCommand c;
    CHECK(TakeParsed(p, &c), "노드 소멸 시 최종 라인 발행 (강제 커밋 — release 관측)");
    CHECK(c.enabled == 0, "최종 라인 enabled=0 (disarm+release 반영)");
    CHECK(p.PollFailsafe(2100) == GP_FS_SLEW_ZERO, "②티어 SLEW_ZERO");
    CHECK(!p.DevicePresent(), "노드 미보유 — 재스캔 전이");
    p.Stop();
}

static void test_pilot_tier2_enodev_deadman_held() {
    printf("test_pilot_tier2_enodev_deadman_held (비정상 단절 — release 전무, codex P1 fix)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1010);
    p.InjectEventForTest(Syn(), 1010);
    DrainSlot(p);
    // 데드맨이 눌린 채 노드만 소멸(거리 이탈·배터리 탈락 모사 — release 합성 없음).
    // 정지 라인을 발행하면 supervisor 가 즉시 Walking::Stop — ②티어 스펙(제자리
    // 슬루 → WD_STOP 2.5s) 위반이므로 라인 미발행이 정답.
    p.InjectNodeLostForTest(2000);
    char line[256];
    CHECK(!p.TakeCommand(line, sizeof(line)), "②티어: 정지 라인 미발행 (슬루가 소화)");
    CHECK(!p.ArmedForTest(), "②티어: disarm (재 ARM 필수)");
    CHECK(p.PollFailsafe(2100) == GP_FS_SLEW_ZERO, "②티어: SLEW_ZERO 지속");
    p.Stop();
}

static void test_pilot_tier3_silence_false_positive() {
    printf("test_pilot_tier3_silence_false_positive (정속 직진 이벤트 침묵 — 오발 시나리오)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1100);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1100);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1100);
    p.InjectEventForTest(Syn(), 1100);
    DrainSlot(p);
    // 스틱 레일 고정(이벤트 0) — 1.5s 전엔 정상.
    CHECK(p.PollFailsafe(2599) == GP_FS_NONE, "침묵 1499ms → 정상");
    // ③티어 발화 — 단 효과는 disarm 이 아닌 슬루 정지(오발 비용 = 완만한 정지).
    CHECK(p.PollFailsafe(2600) == GP_FS_SLEW_ZERO, "침묵 1500ms → ③ SLEW_ZERO");
    CHECK(p.ArmedForTest(), "③티어는 disarm 아님 — armed 유지");
    // 스틱을 흔들면 즉시 복귀(이벤트 재개) — 재 ARM 불요.
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -30000), 3000);
    p.InjectEventForTest(Syn(), 3000);
    CHECK(p.PollFailsafe(3010) == GP_FS_NONE, "이벤트 재개 → ③ 해제");
    WalkCommand c;
    CHECK(TakeParsed(p, &c) && c.enabled == 1, "주행 라인 즉시 재개 (재 ARM 불요)");
    p.Stop();
}

static void test_pilot_balltrack_toggle() {
    printf("test_pilot_balltrack_toggle\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_X, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    WalkCommand c;
    CHECK(TakeParsed(p, &c) && c.balltrack == 1, "X → 볼트랙 ON 토큰");
    CHECK(p.BalltrackForTest() == 1, "내부 토글 상태 ON");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_X, 0), 1020);
    p.InjectEventForTest(Syn(), 1020);
    DrainSlot(p);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_X, 1), 1030);
    p.InjectEventForTest(Syn(), 1030);
    CHECK(TakeParsed(p, &c) && c.balltrack == 0, "X 재누름 → 볼트랙 OFF");
    p.Stop();
}

static void test_pilot_adopt_grace() {
    printf("test_pilot_adopt_grace\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, 0, false);
    p.InjectAdoptForTest(1000);
    // 획득 직후 무입력 — ③티어 기준은 max(이벤트, 획득)이라 1.5s 유예.
    CHECK(p.PollFailsafe(2000) == GP_FS_NONE, "획득 +1.0s 무입력 → 유예");
    // 1.5s 후엔 발화하지만, supervisor 가 active_source==local 로 게이트하므로
    // 입력이 한 번도 없던 패드는 무해(라인 미발행 → local 소스가 될 수 없음).
    CHECK(p.PollFailsafe(2600) == GP_FS_SLEW_ZERO, "획득 +1.6s — 발화 (소스 게이트로 무해)");
    CHECK(!p.HasControl(2000), "입력 전 — local 우선권 없음");
    p.Stop();
}

// ---- main --------------------------------------------------------------------

int main() {
    printf("== GamepadPilot host tests (H1+H2) ==\n");
    test_decode_raw16();
    test_decoder_syn_commit();
    test_decoder_normalization();
    test_decoder_force_commit();
    test_deadzone_curve();
    test_trigger_diff();
    test_mapping_signs();
    test_mapping_gates();
    test_mapping_turbo();
    test_mapping_head_hold();
    test_gait_schedule();
    test_line_builder_roundtrip();
    test_settle();
    test_failsafe_decision();
    test_pilot_arm_and_estop();
    test_pilot_estop_wins_same_tick();
    test_pilot_recover();
    test_pilot_line_flow_and_arbitration_window();
    test_pilot_refresh_cadence();
    test_pilot_tier1_release_then_enodev();
    test_pilot_tier2_enodev_without_release();
    test_pilot_tier2_enodev_deadman_held();
    test_pilot_tier3_silence_false_positive();
    test_pilot_balltrack_toggle();
    test_pilot_adopt_grace();

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
