/*
 * GamepadPilot.h — RG G01 2.4G 동글 온보드 직결 파일럿 (H1+H2)
 *
 * 2026-06-12 (handheld-direct-pilot-upgrade Wave H1+H2, P7) — 로봇 USB 의 RG G01
 * 동글(XInput 045e:028e → xpad 네이티브, H0 실측 보고서
 * docs/reports/2026-06-12-rgg01-usb-probe.md)을 읽어 보행/머리 명령을 만들고, O1
 * latest-wins 슬롯(source=local)으로 supervisor 에 합류시킨다. E-STOP(B)만 예외 —
 * 슬롯 경유 없이 읽기 스레드에서 즉시 콜백(브로커리지 TriggerEstopImmediate).
 *
 * 매핑은 H0/P7 초기엔 콕핏 RG G01 프리셋과 1:1 이었으나, 실기 F10/F12(2026-06-13)에서
 * 의도적으로 이탈했다(데드맨 해제·LT/RT 회전·우스틱 헤드 레이트·LB/RB 킥·터보 제거).
 * 본문 주석이 각 이탈을 기록한다 — 파일을 "1:1 패리티"로 읽지 말 것.
 *
 * 2026-06-14 (anbernic-dongle-direct-control-hardening) — Batch A/B: 외부 E-STOP 의
 * ForceDisarm(reset≠restart), 노드소멸 단일 안전상태(버튼무관), local 신선창=침묵창
 * 정렬(선점 결함 제거), 측보 축별 정규화, ARM idle timeout.
 *
 * 구조: 순수 로직(디코더/매핑/성형/settle/failsafe 판정)은 Robot:: 의존 0 —
 * 호스트 단위 테스트(tests/test_gamepad.cpp). 장치 I/O(/dev/input 스캔·읽기
 * 스레드)는 __linux__ 게이트 — macOS 호스트에서도 같은 TU 가 컴파일된다.
 *
 * 제약: C++03 / POSIX(pthread) 만. 로봇 g++ 가 컴파일하므로 C++11 금지.
 */

#ifndef GAMEPAD_PILOT_H_
#define GAMEPAD_PILOT_H_

#include <pthread.h>
#include "WalkLabTransport.h"   // CommandSlot — O1 latest-wins 합류 지점

namespace Robotis {

// ===== H0 확정 장치 식별 (보고서 §2·§3, 부록 A.2) ============================
// 매칭은 이름+VID/PID 재스캔 — event 노드 번호 불변 가정 금지(재연결 시 input
// 번호 증가 실측 A.4, 노드 번호 재사용은 우연).
static const unsigned short GP_VENDOR_ID  = 0x045e;
static const unsigned short GP_PRODUCT_ID = 0x028e;
static const char* const    GP_DEVICE_NAME = "Microsoft X-Box 360 pad";

// ===== H0 확정 evdev 코드 테이블 (보고서 §3 — 상수화) ========================
static const unsigned short GP_EV_SYN = 0x00;
static const unsigned short GP_EV_KEY = 0x01;
static const unsigned short GP_EV_ABS = 0x03;
static const unsigned short GP_SYN_REPORT = 0;
// 실기 F9 (2026-06-13): evdev 링 오버플로 통지 — 이 사이 이벤트(release 포함)가
// 유실됐다는 뜻. 수신 시 디코더 리셋(스테일 押下 고착 → B E-STOP 영구 침묵 차단).
static const unsigned short GP_SYN_DROPPED = 3;

// 축 8종. 스틱 ±32768(fuzz 16/flat 128), 트리거 0..255 순수 아날로그(BTN_TL2/TR2
// 없음 — 실측 교차확인), D-pad ±1. ABS_Y/RY 아래=+(실측). ABS_X 오른쪽=+ 는 표준
// 가정 잔존 — 실기 브링업 1단계에서 확정(GP_SIGN_SIDE 로만 반전).
static const unsigned short GP_ABS_X     = 0;   // 왼스틱 X (횡)
static const unsigned short GP_ABS_Y     = 1;   // 왼스틱 Y (전후)
static const unsigned short GP_ABS_Z     = 2;   // LT (머리팬 좌)
static const unsigned short GP_ABS_RX    = 3;   // 오른스틱 X (턴)
static const unsigned short GP_ABS_RY    = 4;   // 오른스틱 Y (머리틸트)
static const unsigned short GP_ABS_RZ    = 5;   // RT (머리팬 우)
static const unsigned short GP_ABS_HAT0X = 16;  // D-pad X — 1차 미배선(상수만)
static const unsigned short GP_ABS_HAT0Y = 17;  // D-pad Y — 1차 미배선(상수만)

static const int GP_STICK_MAX   = 32767;  // 정규화 분모(−32768 은 클램프)
static const int GP_TRIGGER_MAX = 255;

// 버튼 (보고서 §3 — 콕핏 의미론).
static const unsigned short GP_BTN_A      = 304;  // ARM
static const unsigned short GP_BTN_B      = 305;  // E-STOP (rising, 데드맨 무시)
static const unsigned short GP_BTN_X      = 307;  // 볼트랙 토글
static const unsigned short GP_BTN_Y      = 308;  // 복구 (estop flag 해제 + ARM)
static const unsigned short GP_BTN_LB     = 310;  // 왼발 킥 (F12 — rising, ARM 게이트)
static const unsigned short GP_BTN_RB     = 311;  // 오른발 킥 (F12 — 터보 제거 후 재할당)
static const unsigned short GP_BTN_BACK   = 314;  // 예약
static const unsigned short GP_BTN_START  = 315;  // 예약
static const unsigned short GP_BTN_HOME   = 316;  // 예약
static const unsigned short GP_BTN_THUMBL = 317;  // 예약
static const unsigned short GP_BTN_THUMBR = 318;  // 예약

// ===== 킥 — F12 (2026-06-13): LB=왼발·RB=오른발 ==============================
// rising edge + ARM 게이트(SYN 커밋) → kick_cb(ctx, side). 페이지 매핑(LEFT→13,
// RIGHT→12)은 brokerage 단일 지점(KICK_PAGE_*)이 소유 — 비대칭(R=12/L=13) 실수 차단.
// 콜백은 brokerage 플래그만 세팅(비블로킹) — 실행은 supervisor 루프(getup 패턴 복제).
static const int GP_KICK_LEFT  = 0;
static const int GP_KICK_RIGHT = 1;

// ===== D-패드 모션 (2026-06-14): 상하좌우 → 공식 Action 페이지 =================
// kick_cb 을 재사용해 "액션 코드"를 전달(킥+D-패드 통합). 페이지 매핑은 brokerage 단일
// 지점이 소유(STAND→16, SIT→15, PASS_LEFT→71, PASS_RIGHT→70). rising edge(D-패드 0→±1)
// + ARM 게이트(킥과 동일) + estop 동률 패. 실행은 supervisor 의 모듈 스왑(페이지 속도 준수).
static const int GP_ACTION_STAND      = 2;   // 위  — stand up (page 16)
static const int GP_ACTION_SIT        = 3;   // 아래 — sit down (page 15)
static const int GP_ACTION_PASS_LEFT  = 4;   // 좌  — lPASS (page 71)
static const int GP_ACTION_PASS_RIGHT = 5;   // 우  — rPASS (page 70)
// D-패드 부호(표준 evdev): 위=−1·아래=+1(HAT0Y), 좌=−1·우=+1(HAT0X). 실기서 반대면 반전.
static const int GP_DPAD_UP    = -1;
static const int GP_DPAD_DOWN  =  1;
static const int GP_DPAD_LEFT  = -1;
static const int GP_DPAD_RIGHT =  1;

// ===== 매핑·성형 상수 (콕핏 RG G01 프리셋 1:1 + §5 통일안) ===================
static const double GP_DEADZONE    = 0.10;  // 통일안 (콕핏 0.10)
static const double GP_DRIVE_CURVE = 1.35;  // 통일안 (Switch drive_curve)
// F12 (2026-06-13): 터보(GP_TURBO_SCALE ×1.3) 제거 — RB 를 오른발 킥에 재할당.
// LT/RT 아날로그 턴 + 풀스틱 스트라이드로 ×1.3 부스트는 중복이라 단순화.
// **Anbernic 고도화 P2/P4 (2026-06-13, docs/design/anbernic-gait-upgrade.md)** — 좌우
// 고속화·회전 대각화. 불변식: GP_MAX_SIDE_MM/GP_MAX_TURN_DEG 는 거버너 ENVELOPE_Y_MAX/
// A_MAX 와 **항상 동일값**(작은 쪽이 클램프). 2단계(좌우 32·회전 20)는 온스탠드
// IK-freeze 스윕(좌우)·발yaw 무스컬프 14°(회전) 검증 후에만 — P7 보류.
static const double GP_MAX_STRIDE_MM = 38.0;  // UI 클램프 — 최종은 거버너(O2)
// **하드닝 B2 (2026-06-14)**: 측보/회전 상한을 거버너 ENVELOPE_*_MAX 로 **직접** 정의 —
// 불변식 GP_MAX_SIDE_MM==ENVELOPE_Y_MAX, GP_MAX_TURN_DEG==ENVELOPE_A_MAX 가 구조적으로
// 보장되어 한쪽만 바꿔도 발산 불가(종전엔 양쪽 헤더 주석에만 — 조용히 깨질 수 있었다).
// GpGaitSchedule 측보 정규화가 GP_MAX_SIDE_MM 를 분모로 쓰므로(P1-1) 이 정렬이 핵심.
// 값은 WalkLabTransport.h: ENVELOPE_Y_MAX=28(P2), ENVELOPE_A_MAX=18(P4). C++03 라 const
// double 은 정수상수식이 아니어서 컴파일타임 array-assert 불가 → 구조적 동일 정의로 대체.
static const double GP_MAX_SIDE_MM   = ENVELOPE_Y_MAX;  // ==32 (실기튜닝 2026-06-14, per-leg half-amp 16mm, IK-freeze 관찰)
static const double GP_MAX_TURN_DEG  = ENVELOPE_A_MAX;  // ==28 (실기튜닝 2026-06-14, 발 yaw ~14° 무스컬프 천장, 충돌 ~40° 마진)
static const double GP_MAX_HEAD_PAN_DEG  = 70.0;  // Switch max_head_pan 패리티
static const double GP_MAX_HEAD_TILT_DEG = 35.0;  // Switch max_head_tilt 패리티
// 실기 F10b (2026-06-13): 데드존 0.05→0.02 — 트리거 살짝 눌러도 회전 시작.
static const double GP_TRIGGER_DEADZONE  = 0.02;  // RT−LT 차분 휴지 노이즈 제거
// 턴 응답 곡선 — 지수 <1 = 저압 부스트(살짝 눌러도 체감 회전, 풀프레스 1 불변).
static const double GP_TURN_CURVE        = 0.65;

// ===== 실기 F10 (2026-06-13) — 사용자 매핑 리디자인 ==========================
// 변경: ① 데드맨(LB) 해제 — 이동 게이트는 ARM(A)만. ② 우스틱 = 헤드 무빙
// (레이트 제어 — 곡선 성형 후 °/s 적분, 클램프). ③ LT/RT = 좌/우회전(아날로그
// 비례, RT−LT 차분). 콕핏 RG G01 프리셋 1:1 패리티에서 의도적으로 이탈 —
// 실기 조종감 피드백 반영(ssh-parity-contract 매핑 표 후속 개정 필요).
static const bool   GP_DEADMAN_REQUIRED    = false;  // true 로 되돌리면 LB 데드맨 복원
// 실기 F10b — 최고속 상향(90→150 / 50→85), 곡선 1.35→1.7(가파르게)로 저속 구간은
// 종전과 거의 동일 유지: 소폭 deflection 의 °/s 는 같고 풀스틱만 빨라진다.
static const double GP_HEAD_PAN_RATE_DPS   = 150.0;  // 풀스틱 — 풀스윕(±70°) ~0.9s
static const double GP_HEAD_TILT_RATE_DPS  = 85.0;   // 풀스틱 — 풀스윕(±35°) ~0.8s
static const double GP_HEAD_CURVE          = 1.7;    // 헤드 전용 응답 곡선
static const double GP_MAP_DT_MAX_MS       = 200.0;  // 적분 dt 상한(이벤트 공백 점프 방지)

// 부호 (실측 — 보고서 §3 + 브링업 라운드4 GP_SIGN_SIDE 확정 2026-06-12).
// 로봇 좌표: X_MOVE+=전진, Y_MOVE+=좌횡, A_MOVE+=좌회전, head pan+=좌, tilt+=상.
static const double GP_SIGN_STRIDE = -1.0;  // ABS_Y 아래=+(실측) → 위=전진
static const double GP_SIGN_SIDE   = -1.0;  // ABS_X 오른쪽=+(실측 확정) → 우=−Y(우횡)
static const double GP_SIGN_TURN   = -1.0;  // RT(우)−LT(좌) 차분 → RT=−A(우회전) [F10]
static const double GP_SIGN_TILT   = -1.0;  // ABS_RY 아래=+(실측) → 위=+tilt(머리들기)
static const double GP_SIGN_PAN    = -1.0;  // ABS_RX 오른쪽=+(실측) → 우=−pan(robot pan+=좌) [F10]

// 성형 스케줄 — switch-pilot ssh_control_client._gait_params 식 채택(검증된
// 조종감): shaped=intensity^0.7, period 는 max→min, foot 는 min→max 선형 보간.
// 상수는 설계 §1.1/§5 의 560–700ms 채택(Walking 출하 default 600/40 과 정합).
static const double GP_GAIT_PERIOD_MAX_MS  = 700.0;  // 저강도(느린 케이던스)
static const double GP_GAIT_PERIOD_MIN_MS  = 560.0;  // 풀스틱
static const double GP_GAIT_FOOT_MIN_MM    = 18.0;
static const double GP_GAIT_FOOT_MAX_MM    = 40.0;
static const double GP_GAIT_PERIOD_DEFAULT = 600.0;  // 정지 시(스케줄 비적용)
static const double GP_GAIT_FOOT_DEFAULT   = 40.0;
static const double GP_HIP_DEG             = 13.0;   // ROBOTIS 원본 고정

// ===== H2 타이밍 상수 =========================================================
// **하드닝 P1-2/A2 (2026-06-14)**: local 우선권 창 = ③티어 침묵 창(1500ms). 종전엔
// local 1000 < 침묵 1500 이라, 1.0~1.5s 구간에 GamepadPilot 이 보유 상태를 계속 offer
// 하는데도 supervisor 는 drain 만 하고 UDP/파일이 제어권을 선점할 수 있었다(P1-2). 두
// 창을 정렬해 선점 구간을 제거 — 신선 창 내내 local 이 SRC_LOCAL 을 유지하므로 P0-3↔P1-2
// 결합 결함(active_source 플립으로 ②티어 슬루 무장해제)도 근본 차단된다.
static const long long GP_SILENCE_SLEW_MS = 1500;
static const long long GP_LOCAL_FRESH_MS  = GP_SILENCE_SLEW_MS;  // 침묵 창과 단일화(정렬)
// ③티어 — 마지막 *이벤트* 경과 ≥1.5s = 단절 의심(초기값 — 실기에서 정속 보행 침묵
// 분포 실측 후 확정). EVIOCGKEY 폴은 생존 판정 금지(H0 실측 반증 — 보고서 §5 함의 4).
// 정렬 불변식 컴파일타임 강제(한쪽만 바꾸면 선점 결함 부활 → 빌드 실패로 차단).
typedef char GpAssert_LocalFreshEqSilence[(GP_LOCAL_FRESH_MS == GP_SILENCE_SLEW_MS) ? 1 : -1];
static const int GP_REFRESH_MS = 50;    // 보유 상태 재공급(스트림 워치독 600/2500ms 정합)
static const int GP_RESCAN_MS  = 1000;  // 장치 미발견/소실 시 재스캔 주기(핫플러그 겸용)
// **하드닝 B3 (2026-06-14)**: 데드맨 제거 후 ARM 무기한 유지의 완화책 — ARM 후 모든
// 입력(이동·턴·머리·트리거·버튼)이 N초 없으면 auto-disarm(거치 중 스틱 오접촉 차단).
// enabling-device 정석은 hold-to-run(3-position, ISO 10218-1 Annex C)이나 RG G01 엔
// 하드웨어가 없어 idle-timeout 이 약식 등가 — 표준 충족 아닌 완화책. 값 15s 는 설계
// 초기값(실기 idle gap p99 분포 실측 후 확정 — P1-4/측정 프로토콜).
static const long long GP_ARM_IDLE_TIMEOUT_MS = 15000;

// ===== 16B input_event 디코드 (H0: i686 timeval 8 + type 2 + code 2 + value 4) ==
// 원시 바이트를 리틀엔디언 명시 조립으로 해석 — struct 레이아웃 이식성 문제 차단
// (호스트 테스트와 로봇 i686 이 동일 코드 경로). 타임스탬프(앞 8B)는 미사용 —
// 신선도는 수신 시각(로컬 클럭) 기준(H0 §4: 타임스탬프는 사용자공간 수신 시각 기준).
struct GpEvent {
    unsigned short type;
    unsigned short code;
    int value;
};
void DecodeGamepadEvent(const unsigned char* raw16, GpEvent* out);

// ===== 스냅샷 (EV_SYN 커밋 단위 — 축 일관성 보장) ============================
struct GamepadSnapshot {
    double lx, ly, rx, ry;   // 스틱 [-1,1] (raw 부호 그대로 — 부호는 매핑이 적용)
    double lt, rt;           // 트리거 [0,1]
    int hat_x, hat_y;        // D-pad −1/0/+1 (1차 미배선 — 디코드만)
    bool btn_a, btn_b, btn_x, btn_y, btn_lb, btn_rb;
    bool btn_start;   // 볼-추종 토글 (2026-06-14) — rising edge 판정용 추적
    GamepadSnapshot();
};

// FeedEvent 반환 비트.
static const int GP_FEED_COMMITTED = 0x01;  // EV_SYN(SYN_REPORT) — out 에 스냅샷 커밋

class GamepadDecoder {
public:
    GamepadDecoder();
    void Reset();
    // 이벤트 1건 누적. SYN_REPORT 에서 pending 을 out 으로 커밋(GP_FEED_COMMITTED).
    int FeedEvent(const GpEvent& ev, GamepadSnapshot* out);
    // ENODEV/노드 소멸 시 pending 강제 커밋 — release 합성이 SYN 없이 끊겨도 데드맨
    // 해제를 반영(H2 ①티어 정합). 미커밋 변경이 있었으면 true.
    bool ForceCommit(GamepadSnapshot* out);
    // 현재(pending) 버튼 상태 — rising edge 판정용(호출부가 Feed 전에 조회).
    bool ButtonState(unsigned short code) const;
private:
    GamepadSnapshot m_pending;
    bool m_dirty;
};

// ===== 매핑 (콕핏 RG G01 프리셋 1:1 — ControllerBindingProfile.xbox) =========
// 머리 hold 상태 — 입력이 0 이면 직전 명령 각을 유지(switch hold_head 패리티).
struct GamepadHeadHold {
    double pan, tilt;
    GamepadHeadHold();
};

struct GamepadWalkFields {
    int enabled;
    double x, y, a;          // mm/mm/deg
    double period, foot;     // ms/mm (intensity 스케줄)
    double hip;              // deg
    double pan, tilt;        // deg (hold 적용 후)
    GamepadWalkFields();
};

// 데드존 0.10 → 잔여 [0,1] 재스케일(부호 보존) — switch _deadzone 식.
double GpApplyDeadzone(double v);
// 데드존 → 곡선 1.35 (부호 보존) — switch _drive_axis 식.
double GpShapeDriveAxis(double v);
// F10b — 헤드 전용: 데드존 → 곡선 GP_HEAD_CURVE(1.7). 저속 미세 조작은 종전과
// 동일, 풀스틱 최고속만 상향(RATE_DPS 와 한 쌍).
double GpShapeHeadAxis(double v);
// RT−LT 차분 [−1,1] — 차분에 GP_TRIGGER_DEADZONE 적용 후 재스케일.
double GpTriggerDiff(double rt, double lt);
// F10b — 턴 저압 부스트: |d|^GP_TURN_CURVE(0.65), 부호 보존. 살짝 눌러도 체감
// 회전이 시작되고 풀프레스(±1)는 불변.
double GpShapeTurn(double d);
// intensity^0.7 → period/foot (switch _gait_params 식). enabled=0 이면 default.
void GpGaitSchedule(double x_mm, double y_mm, double a_deg, int enabled,
                    double* period_ms, double* foot_mm);
// 스냅샷 → 보행/머리 필드. 실기 F10: armed && 이동입력 일 때만 enabled=1
// (데드맨 해제 — GP_DEADMAN_REQUIRED). 이동/턴만 게이트, 머리는 비게이트.
// F12: 터보 제거 — LB/RB 는 킥 전용(MapGamepad 비관여, ProcessEvent 처리).
// 머리 = 우스틱 레이트 제어: 곡선 성형(GpShapeDriveAxis) × RATE_DPS × dt_ms 적분,
// ±MAX 클램프 — dt_ms ≤ 0 이면 머리 적분 생략(레거시 호출/리셋 직후 안전).
void MapGamepad(const GamepadSnapshot& s, bool armed, double dt_ms,
                GamepadHeadHold* hold, GamepadWalkFields* out);

// v1 14-token 명령 라인 빌더 — 형식 불변(P9: TEL v1/명령 토큰 추가 금지).
// "gp{seq} {en} {x} {y} {a} {period} {foot} {hip} 1.0 0 2 {pan} {tilt} {ball}"
// blevel=2(×1.0 — 종전 출하 게인과 동일·ON). 반환 = 기록 길이(snprintf 의미).
int BuildGamepadLine(char* out, int cap, long long seq,
                     const GamepadWalkFields& f, int balltrack);

// ===== H2 settle (switch-pilot settle_safety_state 이식) =====================
// 같은 틱(SYN 배치)에서 E-STOP 이 ARM/복구를 이긴다 — estop edge 를 마지막에 적용.
bool SettleArmed(bool armed, bool arm_edge, bool estop_edge);

// ===== H2 3티어 failsafe 판정 (순수) =========================================
// ①티어(release 합성→데드맨 해제)는 이벤트 경로(MapGamepad 게이트)가 소화. 본
// 판정은 ②(노드 소멸 — inputSourceLost)·③(이벤트 침묵 ≥1.5s — 단절 의심)만.
// 효과는 disarm 아닌 "진폭 제자리 슬루"(WD_SLEW_ZERO 동일) — 오발 비용 = 완만한
// 정지, 미탐 비용 = 폭주(안전 측 편향). Stop 은 워치독 WD_STOP(2.5s)이 이어받는다.
enum GamepadFailsafe {
    GP_FS_NONE      = 0,
    GP_FS_SLEW_ZERO = 1
};
GamepadFailsafe GamepadFailsafeDecision(long long now_ms, long long last_alive_ms,
                                        bool node_ok, bool had_device);

// ===== GamepadPilot 본체 (읽기 스레드 + 장치 스캔 + 상태기계) =================
class GamepadPilot {
public:
    GamepadPilot();
    ~GamepadPilot();

    /// 읽기 스레드 기동. estop_cb = B rising 즉시(슬롯 경유 금지) — 브로커리지
    /// TriggerEstopImmediate. recover_cb = Y 복구(estop flag 해제 — switch recover
    /// 패리티). kick_cb = LB/RB rising(ARM·estop 게이트 후) — side=GP_KICK_LEFT/RIGHT.
    /// 킥 콜백은 **플래그만 세팅하고 즉시 반환**(블로킹 금지 — E-STOP 응답성 보존).
    /// with_thread=false 는 호스트 테스트(주입 구동) 전용.
    void Start(void (*estop_cb)(void*), void (*recover_cb)(void*),
               void (*kick_cb)(void*, int side), void* cb_ctx, bool with_thread);
    /// 스레드 정지+합류 (MODE 버튼 정상 종료 경로). 미기동이면 no-op.
    void Stop();

    /// supervisor 소비 — 슬롯에서 최신 라인 take(있으면 true). 적용 여부는
    /// 호출부가 HasControl 로 게이트(스테일 drain 을 위해 항상 take).
    bool TakeCommand(char* out, int cap);
    /// H2-1 — local 우선권: 마지막 *이벤트* 수신이 GP_LOCAL_FRESH_MS(1s) 이내.
    bool HasControl(long long now_ms);
    /// H2 ②③ 티어 폴 — supervisor 가 매 루프 호출(적용은 active_source==local 게이트).
    GamepadFailsafe PollFailsafe(long long now_ms);
    /// 장치 노드 보유 여부 (진단용).
    bool DevicePresent();
    /// **하드닝 A1 (2026-06-14)** — 외부 E-STOP(UDP/Switch/Mac flag)이 ARM 을 latch-해제.
    /// ISO 13850: reset(flag clear)은 재기동을 "허용"만 하고 그 자체로 재기동 금지 →
    /// 외부 E-STOP 후엔 명시적 A 재ARM 없이 재보행 불가. 재ARM 후에도 스틱이 중립을
    /// 한 번 거쳐야 enabled=1(잔여 스틱 즉시 재보행 차단). thread-safe(m_mtx).
    /// **재진입 불변식**: m_mtx 를 잡으므로 m_mtx 보유 구간에서 호출 금지. Gamepad-B
    /// estop 콜백은 ProcessEvent 가 unlock 한 뒤(락 밖) 발화하므로 안전. UDP/supervisor
    /// flag 경로는 락 미보유라 무문제. (non-recursive mutex 가정.)
    void ForceDisarm();
    /// ARM 상태(TEL2 armed 노출용 — IEC 60204-1 §10.3 관찰가능성). thread-safe.
    bool Armed();

    // ── 호스트 테스트 주입 (장치 없이 전체 상태기계 검증 — __linux__ 불요) ──
    void InjectAdoptForTest(long long now_ms);            // 노드 (재)획득 시뮬
    void InjectEventForTest(const GpEvent& ev, long long now_ms);
    void InjectNodeLostForTest(long long now_ms);         // ENODEV 시뮬
    void TickForTest(long long now_ms);                   // refresh cadence 시뮬
    bool ArmedForTest();
    int  BalltrackForTest();
    int  BallfollowForTest();   // 볼-추종 토글 상태(2026-06-14)

private:
    // 이벤트 1건 처리(읽기 스레드/테스트 공용): edge 수집 → SYN 커밋 시 settle +
    // 라인 Offer. B rising 은 즉시 estop 콜백(락 밖에서 발화).
    void ProcessEvent(const GpEvent& ev, long long now_ms);
    // ENODEV/노드 소실: pending 강제 커밋(①티어 정합) → disarm(재 ARM 필수) →
    // 최종 정지 라인 Offer → 재스캔 전이.
    void HandleNodeLost(long long now_ms);
    // 노드 (재)획득: 디코더 리셋 + disarm (H2-2 — 재 ARM 필수).
    void AdoptDevice(int fd, long long now_ms);
    // 이벤트가 없어도 보유 상태를 GP_REFRESH_MS 마다 재공급 — 스트림 워치독
    // (600ms 제자리/2.5s 정지) 餓死 방지. 침묵 ≥1.5s(③티어)면 중단.
    void MaybeRefresh(long long now_ms);
    // 현재 스냅샷 → 라인 빌드 + 슬롯 Offer. m_mtx 보유 상태에서만 호출.
    void OfferCurrentLocked(long long now_ms);

#ifdef __linux__
    void ReaderLoop();
    static void* ThreadEntry(void* self);
#endif

    CommandSlot m_slot;            // local 전용 latest-wins 슬롯(supervisor Take)
    pthread_mutex_t m_mtx;         // 아래 상태 전체 보호(읽기 스레드 ↔ supervisor)
    pthread_t m_thread;
    volatile bool m_running;
    bool m_threadless;             // with_thread=false(호스트 테스트) — Stop 의 join 생략

    int  m_fd;                     // event 노드 fd (−1 = 미보유)
    bool m_node_ok;
    bool m_had_device;             // 한 번이라도 획득 — ②티어 게이트
    bool m_armed;                  // H2-2 ARM (A rising). 노드 (재)획득 시 false.
    // **하드닝 A1** — 외부/B E-STOP latch-disarm 후, 재ARM 해도 스틱이 중립을 한 번
    // 거치기 전엔 enabled=1 억제(reset≠restart 완성 — 잔여 스틱 즉시 재보행 차단).
    bool m_rearm_requires_neutral;
    int  m_balltrack;              // X 토글 (0/1) — 머리 추적
    int  m_ballfollow;             // START 토글 (0/1) — 볼-추종 보행(2026-06-14). 명령라인 balltrack 값=2 로 송출

    GamepadDecoder  m_decoder;
    GamepadSnapshot m_snap;        // 마지막 커밋 스냅샷
    GamepadHeadHold m_hold;
    bool m_have_snap;

    long long m_last_event_ms;     // 마지막 *이벤트* 수신 — HasControl/③티어 기준
    long long m_last_activity_ms;  // **하드닝 B3** — 마지막 *의도적* 입력(이동/턴/머리/
                                   // 버튼) 시각. ARM idle timeout 기준(스틱 데드존 노이즈 제외).
    long long m_adopt_ms;          // 노드 획득 시각 — ③티어 즉발 방지(이벤트 전)
    long long m_last_offer_ms;     // refresh cadence
    long long m_last_map_ms;       // F10 — 머리 레이트 적분 dt 기준(직전 매핑 시각)
    long long m_seq;               // cmd_id("gp{seq}") 단조

    bool m_pending_arm_edge;       // SYN 커밋까지 수집되는 edge (settle 입력)
    bool m_pending_estop_edge;
    bool m_pending_recover_edge;
    bool m_pending_left_kick_edge;  // F12 — LB rising(왼발 킥). SYN 커밋서 ARM/estop 게이트.
    bool m_pending_right_kick_edge; // F12 — RB rising(오른발 킥).

    void (*m_estop_cb)(void*);
    void (*m_recover_cb)(void*);
    void (*m_kick_cb)(void*, int side);   // F12 — 킥(side: GP_KICK_LEFT/RIGHT). 락 밖 발화.
    void* m_cb_ctx;

    // 비복사 (C++03).
    GamepadPilot(const GamepadPilot&);
    GamepadPilot& operator=(const GamepadPilot&);
};

}  // namespace Robotis

#endif  // GAMEPAD_PILOT_H_
