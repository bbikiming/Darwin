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
static int g_kick_calls = 0;       // F12 — 킥 콜백 발화 횟수
static int g_kick_last_side = -1;  // F12 — 마지막 킥 side (GP_KICK_LEFT/RIGHT)
static void OnEstop(void*) { g_estop_calls++; }
static void OnRecover(void*) { g_recover_calls++; }
static void OnKick(void*, int side) { g_kick_calls++; g_kick_last_side = side; }

static void ResetCallbacks() {
    g_estop_calls = 0;
    g_recover_calls = 0;
    g_kick_calls = 0;
    g_kick_last_side = -1;
}

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
    printf("test_trigger_diff (F10b — 데드존 0.02·저압 부스트)\n");
    CHECK_DEQ(GpTriggerDiff(0.0, 0.0), 0.0, "휴지 → 0");
    CHECK_DEQ(GpTriggerDiff(1.0, 0.0), 1.0, "RT 풀 → +1");
    CHECK_DEQ(GpTriggerDiff(0.0, 1.0), -1.0, "LT 풀 → -1");
    CHECK_DEQ(GpTriggerDiff(0.51, 0.5), 0.0, "차분 0.01 < 데드존 0.02 → 0");
    CHECK_NEAR(GpTriggerDiff(0.55, 0.0), (0.55 - 0.02) / 0.98, 1e-9, "차분 재스케일");
    CHECK_DEQ(GpTriggerDiff(1.0, 1.0), 0.0, "양 트리거 풀 → 상쇄 0");
    // F10b 저압 부스트: 살짝(0.10) 눌러도 체감 회전(≥0.2 정규값 = ≥2.4°).
    double light = GpShapeTurn(GpTriggerDiff(0.10, 0.0));
    CHECK(light > 0.15, "트리거 0.10 → 정규 턴 >0.15 (저압 부스트 — 종전 0.05 대비 ~3.7배)");
    CHECK_DEQ(GpShapeTurn(1.0), 1.0, "풀프레스 불변 (=1)");
    CHECK_DEQ(GpShapeTurn(-1.0), -1.0, "풀프레스 부호 보존");
}

// ---- 매핑: 부호·게이트·터보·hold ---------------------------------------------

static void test_mapping_signs() {
    printf("test_mapping_signs (F10 — LT/RT=턴, RS=헤드 레이트)\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    // 풀스틱 전진(위=raw −) + 우횡 + RT 풀(우회전) + RS 우+위(헤드 우팬·들기).
    s.ly = -1.0; s.lx = 1.0; s.rx = 1.0; s.ry = -1.0; s.rt = 1.0; s.lt = 0.0;
    MapGamepad(s, true, 1000.0, &hold, &f);   // dt=1s → 캡 200ms 적분
    CHECK(f.enabled == 1, "armed+이동 → enabled (F10: 데드맨 불요)");
    CHECK_NEAR(f.x, GP_MAX_STRIDE_MM, 1e-6, "스틱 위 → 전진 +38 (ABS_Y 아래=+ 실측)");
    CHECK_NEAR(f.y, -GP_MAX_SIDE_MM, 1e-6, "스틱 우 → 우횡 −28 (Anbernic P2: Y_MOVE+=좌)");
    CHECK_NEAR(f.a, -GP_MAX_TURN_DEG, 1e-6, "RT 풀 → 우회전 −18 (Anbernic P4: A_MOVE+=좌)");
    // 헤드 레이트: dt 캡 200ms — 풀스틱 1콜 적분 = RATE × 0.2s.
    CHECK_NEAR(f.tilt, GP_HEAD_TILT_RATE_DPS * 0.2, 1e-6,
               "RS 위 → 틸트 +10 (50°/s × 0.2s 캡)");
    CHECK_NEAR(f.pan, -GP_HEAD_PAN_RATE_DPS * 0.2, 1e-6,
               "RS 우 → 팬 −18 (90°/s × 0.2s 캡, pan+=좌)");
    CHECK_DEQ(f.hip, GP_HIP_DEG, "hip 고정 13");
}

static void test_mapping_gates() {
    printf("test_mapping_gates (F10 — ARM 단일 게이트)\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    s.ly = -1.0; s.ry = -1.0;
    // F10: 데드맨(LB) 미홀드여도 armed+이동이면 enabled.
    s.btn_lb = false;
    MapGamepad(s, true, 100.0, &hold, &f);
    CHECK(f.enabled == 1, "F10: LB 없이도 armed+이동 → enabled");
    CHECK(f.x > 0.0, "전진 적용");
    CHECK(hold.tilt > 0.0, "머리 비게이트 — 틸트 적분 진행");
    // ARM 전 — 이동 잠금 (H2-2 유지). 머리는 비게이트.
    GamepadHeadHold hold2;
    MapGamepad(s, false, 100.0, &hold2, &f);
    CHECK(f.enabled == 0, "ARM 전 → 이동 게이트 잠금");
    CHECK_DEQ(f.x, 0.0, "x=0");
    CHECK(hold2.tilt > 0.0, "머리는 ARM 전에도 비게이트");
    // armed 인데 스틱 중립 — enabled 0 (정지).
    GamepadSnapshot idle;
    MapGamepad(idle, true, 100.0, &hold, &f);
    CHECK(f.enabled == 0, "이동 입력 없음 → enabled 0");
}

static void test_mapping_turbo_removed() {
    printf("test_mapping_turbo_removed (F12 — 터보 제거, RB 는 킥 전용)\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    s.ly = -0.55;
    MapGamepad(s, true, 0.0, &hold, &f);
    double base_x = f.x;   // 0.39229 × 38 ≈ 14.91 (터보 없음)
    CHECK_NEAR(base_x, 0.39229 * GP_MAX_STRIDE_MM, 0.05, "기준값 (터보 없음)");
    // F12: RB 눌러도 전진 스케일 불변 — 터보 제거.
    s.btn_rb = true;
    MapGamepad(s, true, 0.0, &hold, &f);
    CHECK_NEAR(f.x, base_x, 1e-9, "F12: RB 눌러도 전진 스케일 불변 (터보 제거)");
    // 턴(트리거)도 RB 무관 — RT 0.5 기준 비교.
    GamepadSnapshot t;
    t.rt = 0.5;
    MapGamepad(t, true, 0.0, &hold, &f);
    double base_a = f.a;
    t.btn_rb = true;
    MapGamepad(t, true, 0.0, &hold, &f);
    CHECK_NEAR(f.a, base_a, 1e-9, "F12: RB 눌러도 턴 스케일 불변");
    // LB 도 매핑(이동)엔 무관 — 킥 전용.
    GamepadSnapshot l;
    l.ly = -0.55; l.btn_lb = true;
    MapGamepad(l, true, 0.0, &hold, &f);
    CHECK_NEAR(f.x, base_x, 1e-9, "F12: LB 눌러도 전진 스케일 불변 (킥 전용)");
}

static void test_mapping_head_rate() {
    printf("test_mapping_head_rate (F10 — 우스틱 레이트 제어)\n");
    GamepadSnapshot s;
    GamepadHeadHold hold;
    GamepadWalkFields f;
    // RS 우 풀스틱 100ms — 팬 −9°(90°/s × 0.1s).
    s.rx = 1.0;
    MapGamepad(s, true, 100.0, &hold, &f);
    CHECK_NEAR(f.pan, -GP_HEAD_PAN_RATE_DPS * 0.1, 1e-6, "RS 우 100ms → 팬 −9°");
    // 추가 100ms — 적분 누적 −18°.
    MapGamepad(s, true, 100.0, &hold, &f);
    CHECK_NEAR(f.pan, -GP_HEAD_PAN_RATE_DPS * 0.2, 1e-6, "적분 누적 −18°");
    // 절반 스틱 — 곡선 성형으로 절반보다 느리게(미세 조작 정밀). dt=100ms.
    GamepadSnapshot half;
    half.rx = 0.5;
    GamepadHeadHold hold_half;
    MapGamepad(half, true, 100.0, &hold_half, &f);
    double half_shaped = GpShapeHeadAxis(0.5);
    CHECK_NEAR(f.pan, -half_shaped * GP_HEAD_PAN_RATE_DPS * 0.1, 1e-6,
               "절반 스틱 — 곡선 성형 레이트 (선형 절반보다 저속)");
    CHECK(fabs(f.pan) < GP_HEAD_PAN_RATE_DPS * 0.5 * 0.1, "곡선 1.7 — 미세 정밀 확인");
    // F10b — 저속 보존: 소폭(0.2) deflection 의 °/s 가 종전(곡선 1.35 × 90°/s)
    // 대비 ±25% 안에 머무는지(저속 유지) + 풀스틱은 150°/s 로 상향됐는지.
    double old_low = pow((0.2 - 0.1) / 0.9, 1.35) * 90.0;
    double new_low = GpShapeHeadAxis(0.2) * GP_HEAD_PAN_RATE_DPS;
    CHECK(fabs(new_low - old_low) / old_low < 0.25, "저속(0.2 스틱) 종전 ±25% 유지");
    CHECK_NEAR(GpShapeHeadAxis(1.0) * GP_HEAD_PAN_RATE_DPS, 150.0, 1e-6,
               "풀스틱 최고속 150°/s 상향");
    // 스틱 해제 — 직전 각 유지(hold).
    GamepadSnapshot rest;
    double held = hold.pan;
    MapGamepad(rest, true, 100.0, &hold, &f);
    CHECK_NEAR(f.pan, held, 1e-6, "스틱 해제 → 팬 유지");
    // dt=0 (레거시/획득 직후) — 적분 생략, 유지.
    MapGamepad(s, true, 0.0, &hold, &f);
    CHECK_NEAR(f.pan, held, 1e-6, "dt=0 → 적분 생략");
    // dt 상한 — 1000ms 공백도 200ms 로 캡(점프 방지).
    GamepadHeadHold hold_cap;
    MapGamepad(s, true, 5000.0, &hold_cap, &f);
    CHECK_NEAR(f.pan, -GP_HEAD_PAN_RATE_DPS * (GP_MAP_DT_MAX_MS / 1000.0), 1e-6,
               "dt 상한 200ms 캡");
    // 틸트 클램프 — 위로 계속 밀어도 +35 초과 금지.
    GamepadSnapshot up;
    up.ry = -1.0;
    GamepadHeadHold hold_t;
    for (int i = 0; i < 20; ++i) MapGamepad(up, true, 100.0, &hold_t, &f);
    CHECK_NEAR(f.tilt, GP_MAX_HEAD_TILT_DEG, 1e-6, "틸트 클램프 +35");
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
    // 중간 강도 0.5 → shaped = 0.5^0.7 ≈ 0.61557. (단일축 = L2(sqrt(0.5²))=0.5 불변.)
    GpGaitSchedule(19.0, 0.0, 0.0, 1, &period, &foot);
    CHECK_NEAR(period, 700.0 - 140.0 * 0.61557, 0.1, "중간 강도 period ≈ 613.8");
    CHECK_NEAR(foot, 18.0 + 22.0 * 0.61557, 0.1, "중간 강도 foot ≈ 31.5");
    // 풀턴 단독도 강도=1 (ti=GP_MAX_TURN_DEG/GP_MAX_TURN_DEG=1 → L2=1).
    GpGaitSchedule(0.0, 0.0, GP_MAX_TURN_DEG, 1, &period, &foot);
    CHECK_DEQ(period, GP_GAIT_PERIOD_MIN_MS, "풀턴 → period 560");
    // **Anbernic P1 결합강도(L2 magnitude)**: 블렌드(전진+횡)는 단일축보다 강도가 커
    // 케이던스↑(period↓)·발높이↑. half-전진(19) 단독 vs half-전진+half-횡(19,19).
    double p_single = 0.0, f_single = 0.0;
    GpGaitSchedule(19.0, 0.0, 0.0, 1, &p_single, &f_single);
    double p_blend = 0.0, f_blend = 0.0;
    GpGaitSchedule(19.0, 19.0, 0.0, 1, &p_blend, &f_blend);   // L2 = sqrt(0.5²+0.5²)=0.707
    CHECK(p_blend < p_single - 10.0, "블렌드 period < 단축 period (결합강도 케이던스↑)");
    CHECK(f_blend > f_single + 3.0, "블렌드 foot > 단축 foot (발 클리어런스↑)");
    // 3축 풀 블렌드는 L2 ≥ 1 → 강도 1.0 클램프(최속·최대 발높이).
    GpGaitSchedule(GP_MAX_STRIDE_MM, GP_MAX_STRIDE_MM, GP_MAX_TURN_DEG, 1, &period, &foot);
    CHECK_DEQ(period, GP_GAIT_PERIOD_MIN_MS, "3축 풀 → period 560 (L2 clamp 1.0)");
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1010);
    p.InjectEventForTest(Syn(), 1010);
    WalkCommand c;
    CHECK(TakeParsed(p, &c) && c.enabled == 1, "주행 중");
    // F10: 데드맨 해제로 ①티어(LB release 합성)는 더 이상 이동을 막지 않는다 —
    // 단절 보호는 ②티어(ENODEV, release 합성 +~1ms 후속 — H0 §5 공통원인)가 소화.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 2000);
    p.InjectEventForTest(Syn(), 2000);
    CHECK(TakeParsed(p, &c), "release 라인 발행");
    CHECK(c.enabled == 1, "F10: LB release 무영향 — 주행 유지 (②티어가 보호)");
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
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
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // 획득 직후 무입력 — ③티어 기준은 max(이벤트, 획득)이라 1.5s 유예.
    CHECK(p.PollFailsafe(2000) == GP_FS_NONE, "획득 +1.0s 무입력 → 유예");
    // 1.5s 후엔 발화하지만, supervisor 가 active_source==local 로 게이트하므로
    // 입력이 한 번도 없던 패드는 무해(라인 미발행 → local 소스가 될 수 없음).
    CHECK(p.PollFailsafe(2600) == GP_FS_SLEW_ZERO, "획득 +1.6s — 발화 (소스 게이트로 무해)");
    CHECK(!p.HasControl(2000), "입력 전 — local 우선권 없음");
    p.Stop();
}

// ---- 실기 F9 (2026-06-13) — B E-STOP 스테일 면역 + SYN_DROPPED 리셋 --------

static void test_pilot_estop_stale_pending_immune() {
    printf("test_pilot_estop_stale_pending_immune\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // B press 가 커밋된 뒤 release 이벤트가 유실된 상황(링 오버플로 등) —
    // pending btn_b 가 押下로 고착. 종전 rising 검사(!ButtonState)는 이때
    // 두 번째 B press 를 영구 침묵시켰다(안전 임계).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(g_estop_calls == 1, "1차 B → estop 발화");
    // release 유실 — pending btn_b == true 인 채로 다음 press 도착.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 2000);
    CHECK(g_estop_calls == 2, "release 유실 후 재 B → 그래도 발화 (스테일 면역)");
    p.InjectEventForTest(Syn(), 2000);
    CHECK(!p.ArmedForTest(), "estop 후 disarm 유지");
    p.Stop();
}

static void test_pilot_syn_dropped_resets_decoder() {
    printf("test_pilot_syn_dropped_resets_decoder\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // ARM + 데드맨 + 전진 주행 라인 확립.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -20000), 1020);
    p.InjectEventForTest(Syn(), 1020);
    WalkCommand c;
    CHECK(TakeParsed(p, &c) && c.enabled == 1, "주행 라인 확립 (enabled=1)");
    // SYN_DROPPED — 커널 링 오버플로 통지. pending 스냅샷 리셋(정지 측 편향).
    p.InjectEventForTest(Ev(GP_EV_SYN, GP_SYN_DROPPED, 0), 1100);
    p.InjectEventForTest(Syn(), 1100);
    CHECK(TakeParsed(p, &c) && c.enabled == 0,
          "SYN_DROPPED → 데드맨/스틱 리셋 — 정지 라인 (안전 편향)");
    CHECK(p.ArmedForTest(), "SYN_DROPPED 는 disarm 아님 — 입력 재공급으로 즉시 재개");
    // 입력 재공급 — 곧바로 주행 재개 가능(재 ARM 불요).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1150);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -20000), 1150);
    p.InjectEventForTest(Syn(), 1150);
    CHECK(TakeParsed(p, &c) && c.enabled == 1, "재공급 → 주행 재개");
    // 스테일 면역과의 결합: SYN_DROPPED 리셋 후에도 B 는 즉시 발화.
    p.InjectEventForTest(Ev(GP_EV_SYN, GP_SYN_DROPPED, 0), 1200);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1210);
    CHECK(g_estop_calls == 1, "SYN_DROPPED 직후 B → 즉시 발화");
    p.Stop();
}

// ---- F12 (2026-06-13) — 킥 모션 트리거 (LB=왼발 page13, RB=오른발 page12) -------

static void test_pilot_kick_left_right() {
    printf("test_pilot_kick_left_right\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // ARM 먼저.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(p.ArmedForTest(), "ARM");
    // LB rising → 왼발 킥 (SYN 커밋서 발화).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    CHECK(g_kick_calls == 0, "SYN 전 — 킥 미발화 (rising 수집만)");
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 1, "LB → 킥 1회 (SYN 커밋)");
    CHECK(g_kick_last_side == GP_KICK_LEFT, "LB → side=LEFT (page 13)");
    // LB release.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 1030);
    p.InjectEventForTest(Syn(), 1030);
    // RB rising → 오른발 킥.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_RB, 1), 1040);
    p.InjectEventForTest(Syn(), 1040);
    CHECK(g_kick_calls == 2, "RB → 킥 2회");
    CHECK(g_kick_last_side == GP_KICK_RIGHT, "RB → side=RIGHT (page 12)");
    CHECK(p.ArmedForTest(), "킥은 disarm 아님 — ARM 유지");
    p.Stop();
}

static void test_pilot_kick_requires_arm() {
    printf("test_pilot_kick_requires_arm\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // 미ARM(획득 직후) 상태에서 LB → 킥 금지(사고 방지).
    CHECK(!p.ArmedForTest(), "획득 직후 — 미ARM");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(g_kick_calls == 0, "미ARM LB → 킥 무시");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_RB, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 0, "미ARM RB → 킥 무시");
    p.Stop();
}

static void test_pilot_kick_estop_wins() {
    printf("test_pilot_kick_estop_wins\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // 같은 SYN 배치에 LB(킥) + B(estop) — estop 승리: 킥 억제.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_estop_calls == 1, "estop 발화");
    CHECK(g_kick_calls == 0, "같은 틱 LB+B → 킥 억제 (estop 승리)");
    CHECK(!p.ArmedForTest(), "estop → disarm");
    p.Stop();
}

static void test_pilot_kick_debounce() {
    printf("test_pilot_kick_debounce (rising-edge only — 홀드/오토리피트 재발화 금지)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // LB press → 1회.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 1, "1차 press → 킥 1회");
    // 홀드 유지(추가 SYN, release 없음) — 재발화 금지.
    p.InjectEventForTest(Syn(), 1030);
    p.InjectEventForTest(Syn(), 1040);
    CHECK(g_kick_calls == 1, "홀드 유지 → 재발화 없음 (rising-edge only)");
    // 오토리피트(value=2) — 여전히 재발화 금지(rising 은 value==1 만).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 2), 1050);
    p.InjectEventForTest(Syn(), 1050);
    CHECK(g_kick_calls == 1, "오토리피트(value=2) → 재발화 없음");
    // release 후 재press → 2회.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 1060);
    p.InjectEventForTest(Syn(), 1060);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1070);
    p.InjectEventForTest(Syn(), 1070);
    CHECK(g_kick_calls == 2, "release 후 재press → 킥 2회");
    p.Stop();
}

static void test_pilot_kick_walk_line_intact() {
    printf("test_pilot_kick_walk_line_intact (킥은 walk 라인 비간섭)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    DrainSlot(p);
    // LB 킥 + 풀스틱 전진 동시 — walk 라인은 스틱 상태 그대로(enabled=1), 킥은 별개.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 1, "킥 발화");
    CHECK(g_kick_last_side == GP_KICK_LEFT, "side=LEFT");
    WalkCommand c;
    CHECK(TakeParsed(p, &c), "walk 라인 발행 (킥과 독립)");
    CHECK(c.enabled == 1, "walk 라인 enabled=1 (스틱 반영 — 킥 비간섭)");
    CHECK_NEAR(c.x, GP_MAX_STRIDE_MM, 0.01, "x=+38 (전진 유지)");
    // 킥만(스틱 중립) — walk 라인 enabled=0.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 1030);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, 0), 1030);
    p.InjectEventForTest(Syn(), 1030);
    DrainSlot(p);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_RB, 1), 1040);
    p.InjectEventForTest(Syn(), 1040);
    CHECK(g_kick_calls == 2, "RB 킥 발화");
    CHECK(TakeParsed(p, &c) && c.enabled == 0, "스틱 중립 — walk 라인 enabled=0 (킥만)");
    p.Stop();
}

static void test_pilot_kick_arm_same_tick() {
    printf("test_pilot_kick_arm_same_tick (A+LB 같은 틱 — settle 후 armed → 킥 발화)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // 미ARM 상태에서 A(arm)+LB(kick) 같은 SYN — settle 로 armed=true 후 킥 게이트 통과.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(p.ArmedForTest(), "A → armed");
    CHECK(g_kick_calls == 1, "A+LB 같은 틱 → armed 후 킥 발화");
    CHECK(g_kick_last_side == GP_KICK_LEFT, "side=LEFT");
    p.Stop();
}

static void test_pilot_kick_disarmed_after_estop() {
    printf("test_pilot_kick_disarmed_after_estop (estop 후 재ARM 전 킥 금지)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // E-STOP → disarm.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(!p.ArmedForTest(), "estop → disarm");
    // B·A release (재ARM 은 A rising-edge 필요 — 기존 estop 복구 패턴).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_B, 0), 1030);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 0), 1030);
    p.InjectEventForTest(Syn(), 1030);
    // 재ARM 전 LB → 킥 금지.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1040);
    p.InjectEventForTest(Syn(), 1040);
    CHECK(g_kick_calls == 0, "estop 후 미ARM — LB 킥 금지");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 0), 1050);
    p.InjectEventForTest(Syn(), 1050);
    // 재ARM(A rising) 후 LB → 킥 정상.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1060);
    p.InjectEventForTest(Syn(), 1060);
    CHECK(p.ArmedForTest(), "A rising → 재ARM");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1070);
    p.InjectEventForTest(Syn(), 1070);
    CHECK(g_kick_calls == 1, "재ARM 후 LB → 킥 정상");
    p.Stop();
}

static void test_pilot_kick_null_cb_safe() {
    printf("test_pilot_kick_null_cb_safe (kick_cb=NULL 안전)\n");
    ResetCallbacks();
    GamepadPilot p;
    // kick_cb=0 — 콜백 미설정이어도 크래시/오동작 없어야.
    p.Start(OnEstop, OnRecover, 0, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 0, "kick_cb=NULL — 발화 없음(크래시 없음)");
    CHECK(p.ArmedForTest(), "상태 정상");
    p.Stop();
}

// ── F12 적대적 리뷰 보강 (2026-06-13 — 동시성/엣지케이스 6종) ─────────────────

static void test_pilot_kick_both_pressed_same_syn() {
    printf("test_pilot_kick_both_pressed_same_syn (LB+RB 동시 SYN — 양 콜백, last-wins)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // 같은 SYN 배치에 LB+RB rising — 양쪽 콜백 독립 발화(LEFT 먼저, RIGHT 나중).
    // brokerage RequestKick 은 last-wins → RIGHT 로 수렴(단일 킥).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_RB, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 2, "LB+RB 동시 → 양 콜백 발화(2회)");
    CHECK(g_kick_last_side == GP_KICK_RIGHT, "마지막 = RB(RIGHT) → brokerage last-wins");
    p.Stop();
}

static void test_pilot_kick_disarmed_edge_not_stale() {
    printf("test_pilot_kick_disarmed_edge_not_stale (미ARM LB edge → ARM 후 스테일 미발화)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    // 미ARM 상태 LB press → edge 수집되나 SYN 커밋서 게이트(미armed) → 미발화 + edge clear.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    CHECK(g_kick_calls == 0, "미ARM → LB 킥 미발화");
    // 이제 ARM. 직전 LB edge 가 스테일로 남아 발화하면 안 됨(SYN 커밋서 이미 clear).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(p.ArmedForTest(), "A → armed");
    CHECK(g_kick_calls == 0, "ARM 시 직전 LB edge 스테일 미발화");
    p.Stop();
}

static void test_pilot_kick_during_silence_tier() {
    printf("test_pilot_kick_during_silence_tier (③티어 침묵 중 LB → 킥 발화)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // ③티어 진입(침묵 ≥1.5s) — walk amplitude 슬루-제로.
    CHECK(p.PollFailsafe(2600) == GP_FS_SLEW_ZERO, "③티어 진입");
    // ③티어 중에도 LB → 킥 발화(킥은 failsafe 와 독립 — estop 만 게이트).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 2700);
    p.InjectEventForTest(Syn(), 2700);
    CHECK(g_kick_calls == 1, "③티어 중 LB → 킥 발화(failsafe 와 독립)");
    CHECK(g_kick_last_side == GP_KICK_LEFT, "side=LEFT");
    p.Stop();
}

static void test_pilot_kick_syn_dropped_clears_edge() {
    printf("test_pilot_kick_syn_dropped_clears_edge (SYN_DROPPED → 보류 킥 폐기, 안전 편향)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // LB rising 수집 → SYN 커밋 전 SYN_DROPPED(링 오버플로) → 보류 킥 폐기.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_SYN, GP_SYN_DROPPED, 0), 1030);
    p.InjectEventForTest(Syn(), 1030);
    CHECK(g_kick_calls == 0, "SYN_DROPPED → 보류 킥 미발화 (고토크 액션 안전 편향)");
    // 재누름은 정상 발화(rising — 디코더 리셋으로 ButtonState=false).
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1040);
    p.InjectEventForTest(Syn(), 1040);
    CHECK(g_kick_calls == 1, "재누름 → 킥 정상 발화");
    p.Stop();
}

static void test_pilot_kick_with_balltrack() {
    printf("test_pilot_kick_with_balltrack (X 볼트랙 + LB 킥 동시 — 비간섭)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    DrainSlot(p);
    // 같은 SYN 에 X(볼트랙 토글) + LB(킥) — 독립 처리.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_X, 1), 1020);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectEventForTest(Syn(), 1020);
    CHECK(g_kick_calls == 1, "LB → 킥 발화");
    CHECK(g_kick_last_side == GP_KICK_LEFT, "side=LEFT");
    CHECK(p.BalltrackForTest() == 1, "X → 볼트랙 ON(독립)");
    WalkCommand c;
    CHECK(TakeParsed(p, &c) && c.balltrack == 1, "walk 라인에 balltrack=1 반영");
    p.Stop();
}

static void test_pilot_kick_lost_on_device_reacquire() {
    printf("test_pilot_kick_lost_on_device_reacquire (device 유실 → 보류 킥 폐기)\n");
    ResetCallbacks();
    GamepadPilot p;
    p.Start(OnEstop, OnRecover, OnKick, 0, false);
    p.InjectAdoptForTest(1000);
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 1010);
    p.InjectEventForTest(Syn(), 1010);
    // LB rising 수집(SYN 커밋 전) → 장치 유실.
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_LB, 1), 1020);
    p.InjectNodeLostForTest(1021);
    CHECK(g_kick_calls == 0, "유실 전 SYN 미발화 → 콜백 0");
    // 재획득 → disarm. 재 ARM 후 스틱만 — 스테일 킥 미발화(Adopt/HandleNodeLost edge clear).
    p.InjectAdoptForTest(2000);
    CHECK(!p.ArmedForTest(), "재획득 → disarm");
    p.InjectEventForTest(Ev(GP_EV_KEY, GP_BTN_A, 1), 2010);
    p.InjectEventForTest(Syn(), 2010);
    p.InjectEventForTest(Ev(GP_EV_ABS, GP_ABS_Y, -32768), 2020);
    p.InjectEventForTest(Syn(), 2020);
    CHECK(g_kick_calls == 0, "재획득 후 → 스테일 킥 미발화");
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
    test_mapping_turbo_removed();
    test_mapping_head_rate();
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
    test_pilot_estop_stale_pending_immune();
    test_pilot_syn_dropped_resets_decoder();
    // F12 — 킥 트리거 (LB=왼발/RB=오른발)
    test_pilot_kick_left_right();
    test_pilot_kick_requires_arm();
    test_pilot_kick_estop_wins();
    test_pilot_kick_debounce();
    test_pilot_kick_walk_line_intact();
    test_pilot_kick_arm_same_tick();
    test_pilot_kick_disarmed_after_estop();
    test_pilot_kick_null_cb_safe();
    // F12 적대적 리뷰 보강 — 동시성/엣지케이스
    test_pilot_kick_both_pressed_same_syn();
    test_pilot_kick_disarmed_edge_not_stale();
    test_pilot_kick_during_silence_tier();
    test_pilot_kick_syn_dropped_clears_edge();
    test_pilot_kick_with_balltrack();
    test_pilot_kick_lost_on_device_reacquire();

    printf("== %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
