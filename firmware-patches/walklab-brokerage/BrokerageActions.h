/*
 * BrokerageActions.h — WalkLab 단일동작(킥/앉기/일어서기/패스) 순수 결정 로직.
 *
 * 왜 별도 헤더인가: WalkLabBrokerage.cpp 는 ROBOTIS Robot:: 프레임워크(Action/Walking/
 * MotionStatus …)에 의존해 호스트(Mac/CI)에서 컴파일·테스트할 수 없다. 단일동작 안전의
 * 핵심 *결정* 로직(side→page 매핑, 앉음·볼추종 게이트)을 Robot:: 의존이 0 인 이 헤더로
 * 추출해 host 단위테스트(tests/test_brokerage_actions.cpp)로 검증한다. WalkLabBrokerage.cpp
 * 는 이 함수들을 호출만 한다(단일 진실의 원천).
 *
 * 의존: GamepadPilot.h (Robotis::GP_KICK_* / GP_ACTION_* — 역시 Robot:: 의존 0).
 */

#ifndef WALKLAB_BROKERAGE_ACTIONS_H_
#define WALKLAB_BROKERAGE_ACTIONS_H_

#include "GamepadPilot.h"   // Robotis::GP_KICK_LEFT/RIGHT, GP_ACTION_STAND/SIT/PASS_*

namespace Robotis {

// ===== 공식 ROBOTIS motion_4096.bin Action 페이지 (단일 진실의 원천) =================
// ⚠️ 킥 비대칭: RIGHT=12 · LEFT=13 (demo main.cpp:271/276, forge-core library.rs 교차검증).
// D-패드(2026-06-14): 위=stand up(16)·아래=sit down(15)·좌=lPASS(71)·우=rPASS(70).
static const int BROK_KICK_PAGE_RIGHT = 12;
static const int BROK_KICK_PAGE_LEFT  = 13;
static const int BROK_STAND_PAGE      = 16;
static const int BROK_SIT_PAGE        = 15;
static const int BROK_PASS_LEFT_PAGE  = 71;
static const int BROK_PASS_RIGHT_PAGE = 70;

/// side(GP_KICK_* / GP_ACTION_*) → Action 페이지 번호. 미지 side = -1.
/// CheckAndExecuteKick 의 switch 를 대체하는 단일 매핑 지점(host 테스트 가능).
inline int ActionSideToPage(int side) {
    switch (side) {
        case GP_KICK_LEFT:         return BROK_KICK_PAGE_LEFT;
        case GP_KICK_RIGHT:        return BROK_KICK_PAGE_RIGHT;
        case GP_ACTION_STAND:      return BROK_STAND_PAGE;
        case GP_ACTION_SIT:        return BROK_SIT_PAGE;
        case GP_ACTION_PASS_LEFT:  return BROK_PASS_LEFT_PAGE;
        case GP_ACTION_PASS_RIGHT: return BROK_PASS_RIGHT_PAGE;
        default:                   return -1;
    }
}

/// side → 사람이 읽는 이름(로그용). 미지 side = "?".
inline const char* ActionSideName(int side) {
    switch (side) {
        case GP_KICK_LEFT:         return "KICK LEFT";
        case GP_KICK_RIGHT:        return "KICK RIGHT";
        case GP_ACTION_STAND:      return "STAND";
        case GP_ACTION_SIT:        return "SIT";
        case GP_ACTION_PASS_LEFT:  return "PASS LEFT";
        case GP_ACTION_PASS_RIGHT: return "PASS RIGHT";
        default:                   return "?";
    }
}

// ===== 볼-추종(자동 사커 보행) 게이트 =================================================
// 불변식: 단일 동작(킥/앉기/일어서기/패스) 수행 중·직후엔 헤드무빙 외 동작이 겹치면
// 안 된다. 볼-추종은 supervisor 직렬화 *바깥*에서 Walking 을 직접 소유하므로(BallFollower::
// Process → Walking::Start), 단일동작과 충돌하지 않도록 아래 게이트로 명시 차단한다.

/// 볼-추종 활성 여부: balltrack==2(START 토글)이고 앉지 않았을 때만. (리뷰 D1 critical —
/// 앉은 상태에서 추종 활성 시 앉은 자세로 보행 시작 → 확실 낙상.)
inline bool BallFollowEnabledFor(int balltrack, bool sitting) {
    return (balltrack == 2) && !sitting;
}

/// 볼-추종 보행을 실제 실행해도 되는가: 추종 활성 + ARM + 비-앉음. (앉음·미ARM 이면 보행 금지.)
inline bool ShouldRunBallFollow(bool ballfollow_enabled, bool armed, bool sitting) {
    return ballfollow_enabled && armed && !sitting;
}

/// 수동 보행 Start 를 앉음 때문에 차단해야 하는가. (앉은 상태에서 walk 진입은 낙상 위험 —
/// STAND 가 m_sitting 을 해제하기 전엔 보행 금지.) 이미 보행 중이면 start gate 대상 아님.
inline bool ShouldBlockManualWalkStartForSit(bool want_active, bool walking_active, bool sitting) {
    return want_active && !walking_active && sitting;
}

/// **SIT 앉음 유지 (2026-06-15 실기)** — SIT 완료 시 관절을 Walking 에 반납하지 않는다
/// (반납하면 Walking::Process()가 직립 standby 포즈를 매 tick 서보에 써 앉음→기립). Action 이
/// body 를 계속 소유해 page15 마지막 포즈를 홀드. STAND/킥/패스는 정상 반납.
inline bool ShouldHoldSitPose(int side) {
    return side == GP_ACTION_SIT;
}

/// **STAND-from-SIT (2026-06-15 실기)** — 앉음 자세(page15)가 실기 IMU 에 비STANDUP 으로
/// 읽히므로, m_sitting 상태의 STAND 는 STANDUP 안전게이트를 우회한다(m_sitting=의도된 앉음=
/// 신뢰 신호, IMU 보다 우선). 그 외엔 게이트 유지 — 진짜 낙상엔 auto-getup 이 처리.
inline bool ShouldBypassStandupGate(bool sitting, int side) {
    return sitting && side == GP_ACTION_STAND;
}

/// **D2 (2026-06-15)** — 이미 서 있을 때(비-앉음) STAND(D-패드 위)는 의미 없는 no-op.
/// STAND=page16 은 "앉은자세→서기" 모션이라 서 있는 로봇에 재생하면 불필요한 크라우치→
/// 기립으로 불안정해진다. STAND 는 앉음 해제 용도로만 유효 → 비-앉음이면 건너뛴다.
inline bool ShouldSkipRedundantStand(int side, bool sitting) {
    return (side == GP_ACTION_STAND) && !sitting;
}

// ===== 햅틱(진동) 트리거 결정 (2026-06-15) =========================================
// 안베르닉 동글 force feedback. 3 트리거: 낙상(강·길)·최대속도 도달(약)·킥(강·짧).
// 진동 write 자체는 GamepadPilot(로봇 전용); 여기선 "언제 울릴지" 순수 판정만 host 테스트.

/// 전진 보폭(applied_x, mm)이 period 종속 x_max 캡에 도달했는가(0.5mm 여유).
inline bool AtForwardSpeedCap(double applied_x, double x_max) {
    return x_max > 0.0 && applied_x >= (x_max - 0.5);
}

/// 상승 엣지(직전 false·현재 true) — 최대속도 도달 1회만 발화(연속 윙윙 방지).
inline bool RisingEdge(bool prev, bool now) {
    return (!prev) && now;
}

}  // namespace Robotis

#endif  // WALKLAB_BROKERAGE_ACTIONS_H_
