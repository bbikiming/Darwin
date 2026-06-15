/*
 * test_brokerage_actions.cpp — host unit tests for BrokerageActions.h (단일동작 결정 로직).
 *
 * 로봇 toolchain·Robot:: 프레임워크 불요 — BrokerageActions.h(헤더 onlt) + GamepadPilot.h
 * 만 include. WalkLabBrokerage.cpp 자체는 Robot:: 의존이라 호스트 빌드 불가 → 그 안전
 * 결정 로직을 BrokerageActions.h 로 추출해 여기서 검증한다(리뷰 G1/G3 격차 해소).
 *
 *   make -C firmware-patches/walklab-brokerage/tests
 *
 * 검증 범위:
 *   - ActionSideToPage: side(GP_*) → page 6종 + 미지 side(-1) 매핑(상수 핀).
 *   - BallFollowEnabledFor: balltrack/앉음 조합 — 앉은 중 추종 비활성(D1).
 *   - ShouldRunBallFollow: 추종·ARM·앉음 게이트(D1).
 *   - ShouldBlockManualWalkStartForSit: 앉음 보행 차단 게이트.
 */

#include "../BrokerageActions.h"
#include "../GamepadPilot.h"

#include <stdio.h>
#include <string>

using namespace Robotis;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; printf("  FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); } \
} while (0)

// ---- ActionSideToPage: 6종 + 미지 -------------------------------------------
static void test_action_side_to_page() {
    // 킥 비대칭(RIGHT=12 · LEFT=13) — 핀.
    CHECK(ActionSideToPage(GP_KICK_LEFT) == 13,  "KICK_LEFT → page 13");
    CHECK(ActionSideToPage(GP_KICK_RIGHT) == 12, "KICK_RIGHT → page 12");
    // D-패드.
    CHECK(ActionSideToPage(GP_ACTION_STAND) == 16, "STAND → page 16");
    CHECK(ActionSideToPage(GP_ACTION_SIT) == 15,   "SIT → page 15");
    CHECK(ActionSideToPage(GP_ACTION_PASS_LEFT) == 71,  "PASS_LEFT → page 71");
    CHECK(ActionSideToPage(GP_ACTION_PASS_RIGHT) == 70, "PASS_RIGHT → page 70");
    // 미지 side — 안전하게 -1(호출측이 거부).
    CHECK(ActionSideToPage(99) == -1, "unknown side(99) → -1");
    CHECK(ActionSideToPage(-1) == -1, "unknown side(-1) → -1");
    CHECK(ActionSideToPage(6)  == -1, "unknown side(6) → -1");
    // 이름 매핑 일부.
    CHECK(std::string(ActionSideName(GP_ACTION_SIT)) == "SIT", "name(SIT)");
    CHECK(std::string(ActionSideName(99)) == "?", "name(unknown) → ?");
}

// ---- BallFollowEnabledFor: 앉은 중 추종 비활성 (D1) -------------------------
static void test_ballfollow_enabled_for() {
    CHECK(BallFollowEnabledFor(2, false) == true,  "balltrack=2 + 비앉음 → 추종 ON");
    CHECK(BallFollowEnabledFor(2, true)  == false, "balltrack=2 + 앉음 → 추종 차단 (D1)");
    CHECK(BallFollowEnabledFor(1, false) == false, "balltrack=1(머리만) → 추종 OFF");
    CHECK(BallFollowEnabledFor(0, false) == false, "balltrack=0(off) → 추종 OFF");
    CHECK(BallFollowEnabledFor(1, true)  == false, "balltrack=1 + 앉음 → OFF");
}

// ---- ShouldRunBallFollow: 추종·ARM·앉음 게이트 (D1) ------------------------
static void test_should_run_ballfollow() {
    CHECK(ShouldRunBallFollow(true,  true,  false) == true,  "추종ON·ARM·비앉음 → 실행");
    CHECK(ShouldRunBallFollow(true,  true,  true)  == false, "추종ON·ARM·앉음 → 차단 (D1)");
    CHECK(ShouldRunBallFollow(true,  false, false) == false, "추종ON·미ARM → 차단");
    CHECK(ShouldRunBallFollow(false, true,  false) == false, "추종OFF → 차단");
    CHECK(ShouldRunBallFollow(false, false, true)  == false, "전부 비활성 → 차단");
}

// ---- ShouldBlockManualWalkStartForSit ---------------------------------------
static void test_should_block_manual_walk_for_sit() {
    CHECK(ShouldBlockManualWalkStartForSit(true, false, true)  == true,  "보행의도+미보행+앉음 → 차단");
    CHECK(ShouldBlockManualWalkStartForSit(true, false, false) == false, "비앉음 → 허용");
    CHECK(ShouldBlockManualWalkStartForSit(true, true,  true)  == false, "이미 보행 중 → start gate 대상 아님");
    CHECK(ShouldBlockManualWalkStartForSit(false, false, true) == false, "보행의도 없음 → 차단 불요");
}

// ---- ShouldSkipRedundantStand: 서있을때 STAND no-op (D2) --------------------
static void test_should_skip_redundant_stand() {
    CHECK(ShouldSkipRedundantStand(GP_ACTION_STAND, false) == true,  "STAND + 비앉음 → no-op 건너뜀 (D2)");
    CHECK(ShouldSkipRedundantStand(GP_ACTION_STAND, true)  == false, "STAND + 앉음 → 실행(기립)");
    CHECK(ShouldSkipRedundantStand(GP_ACTION_SIT, false)   == false, "SIT 은 STAND 가드 무관");
    CHECK(ShouldSkipRedundantStand(GP_KICK_LEFT, false)    == false, "킥은 STAND 가드 무관");
    CHECK(ShouldSkipRedundantStand(GP_ACTION_PASS_RIGHT, false) == false, "패스는 STAND 가드 무관");
}

// ---- ShouldHoldSitPose / ShouldBypassStandupGate (앉음 유지·STAND-from-SIT) ----
static void test_sit_hold_and_stand_bypass() {
    CHECK(ShouldHoldSitPose(GP_ACTION_SIT) == true,   "SIT 은 Walking 미반납(포즈 홀드)");
    CHECK(ShouldHoldSitPose(GP_ACTION_STAND) == false, "STAND 은 정상 반납");
    CHECK(ShouldHoldSitPose(GP_KICK_LEFT) == false,    "킥은 정상 반납");
    CHECK(ShouldHoldSitPose(GP_ACTION_PASS_RIGHT) == false, "패스는 정상 반납");
    // STAND-from-SIT: 앉음+STAND 만 STANDUP 게이트 우회
    CHECK(ShouldBypassStandupGate(true,  GP_ACTION_STAND) == true,  "앉음+STAND → 게이트 우회");
    CHECK(ShouldBypassStandupGate(false, GP_ACTION_STAND) == false, "비앉음+STAND → 게이트 유지");
    CHECK(ShouldBypassStandupGate(true,  GP_ACTION_SIT) == false,   "앉음+SIT → 우회 아님");
    CHECK(ShouldBypassStandupGate(true,  GP_KICK_LEFT) == false,    "앉음+킥 → 우회 아님(킥은 m_sitting 게이트서 차단)");
    CHECK(ShouldBypassStandupGate(false, GP_KICK_RIGHT) == false,   "비앉음+킥 → 우회 아님");
}

int main() {
    test_action_side_to_page();
    test_ballfollow_enabled_for();
    test_should_run_ballfollow();
    test_should_block_manual_walk_for_sit();
    test_should_skip_redundant_stand();
    test_sit_hold_and_stand_bypass();
    printf("== test_brokerage_actions: %d checks, %d failures ==\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
