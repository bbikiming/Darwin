/*
 * WalkLabTransport.h — DarwinForge onboard transport layer (pure logic)
 *
 * O1 (2026-06-12, walklab-onboard-teleop-upgrade Wave O1) — 이벤트 구동 전송의
 * 순수 로직(Robot:: 의존 0): latest-wins 슬롯, 워치독 티어, 명령/E-STOP 데이터그램
 * 파서, 명령 라인 파서+클램프. 로봇 toolchain 없이 호스트 빌드로 단위 테스트한다
 * (tests/Makefile). 브로커리지(WalkLabBrokerage.cpp)가 이 타입들을 써서 실제 스레드·
 * 소켓·Walking 적용을 수행한다.
 *
 * 제약: C++03 / POSIX(pthread) 만. 로봇 g++ 가 컴파일하므로 constexpr/C++11 금지.
 */

#ifndef WALKLAB_TRANSPORT_H_
#define WALKLAB_TRANSPORT_H_

#include <pthread.h>

namespace Robotis {

// ===== 파싱된 조종 명령 (Robot:: 의존 0) =====================================
// v1 명령 라인의 의미를 담는 값. 파싱 시 안전 클램프가 적용된다.
struct WalkCommand {
    char   cmd_id[32];
    int    enabled;
    double x, y, a;       // X/Y/A_MOVE_AMPLITUDE (mm/mm/deg)
    double period;        // PERIOD_TIME (ms)
    double foot;          // Z_MOVE_AMPLITUDE (mm)
    double hip;           // HIP_PITCH_OFFSET (deg) — clamp [0,20]
    double bgain;         // balance gain (deprecated — blevel 로 단일화, O2)
    int    benable;       // balance enable → BALANCE_ENABLE (O2 결선)
    int    blevel;        // balance level 0..3 → 게인 ×{0,.5,1,1.5} (O2 결선)
    double head_pan;      // deg, clamp [-90,90]
    double head_tilt;     // deg, clamp [-45,65]
    int    balltrack;     // 0/1
    int    flags;         // V2 flags 비트필드(v1=0). FLAG_* 참조. 게이트 스케줄 OFF 등.
    bool   head_explicit; // 이 라인이 non-zero head 를 지시했는가
    WalkCommand();
};

// ===== V2 flags 비트 (twist 프로토콜) =======================================
// v1 라인은 flags=0 → 보행 활성 토글은 v1 의 `enabled` 토큰이 담당(아래 enabled 그대로).
// V2 는 boolean 토글을 flags 로 접는다(정수 프로토콜 — 부동소수 파싱 배제).
static const int FLAG_ENABLED        = 0x01;  // 보행 활성.
static const int FLAG_BALANCE_ENABLE = 0x02;  // 자이로 보정 on → BALANCE_ENABLE.
static const int FLAG_BALLTRACK      = 0x04;  // 온보드 볼 트래킹 on.
static const int FLAG_GATE_SCHED_OFF = 0x08;  // 속도 비례 게이트 스케줄 비활성(기본 0=ON).

// 명령 라인 1개 파싱. 두 방언을 모두 수용:
//  · v1: (cmd_id 포함 14-token / 미포함 13-token / 구형 6-token), mm/deg 혼합 — §C.
//  · v2: "V2 {seq} {t_tx_ms} {flags} {vx_mms} {vy_mms} {wz_mrad_s} {period_ms} {foot_mm}
//        {hip_cdeg} {blevel} {headPan_cdeg} {headTilt_cdeg}" — REP-103 SI 밀리단위 정수.
//        로봇이 twist→진폭 변환을 소유(X≈k_x·vx·T/2, A≈k_a·wz·T/2). §G.8.
// 안전 클램프(hip 0..20, head pan ±90, tilt -45..65) 적용. 파싱 실패 시 false
// → 호출부는 이전 명령 유지(safety). out 은 항상 유효 기본값으로 시작.
bool ParseCommandLine(const char* line, WalkCommand* out);

// ===== O2 twist 변환 보정 계수 (벤치 후 확정) ===============================
// REP-103 SI: vx,vy[mm/s], wz[mrad/s], T=period/1000[s].
//   X_MOVE[mm] = TWIST_K_X · vx · T/2,  Y_MOVE = TWIST_K_Y · vy · T/2,
//   A_MOVE[deg] = TWIST_K_A · (wz/1000) · T/2 · (180/π).
// TODO(bench-O0): 스텝 응답 정착 거리/회전각 실측으로 k_x·k_y·k_a 보정. 초기값 1.0.
static const double TWIST_K_X = 1.0;
static const double TWIST_K_Y = 1.0;
static const double TWIST_K_A = 1.0;

// ===== O2 결합 엔벨로프 거버너 (G6) — 로봇이 소유하는 최종 클램프 ============
// |x|/x_max + |y|/y_max + |a|/a_max ≤ ENVELOPE_SUM_MAX 초과 시 x/y/a 비례 스케일다운.
// Switch(stride 50mm 무클램프)·핸드헬드 포함 **전 클라이언트의 안전 전제** — 로봇 최종판.
// 단일 정의(bus-direct-teleop-upgrade D1 와 공유). Mac 클램프(38/22/12)는 UX 레이어로 유지.
static const double ENVELOPE_SUM_MAX = 1.15;
static const double ENVELOPE_Y_MAX   = 22.0;  // mm
static const double ENVELOPE_A_MAX   = 12.0;  // deg
// period 종속 x_max(mm) 스케줄 — 초기값(벤치로 갱신). 경계 밖 끝값 고정, 중간 선형 보간.
//   700ms→40, 600→38, 500→32, 440→28.
double EnvelopeXMax(double period_ms);
// 비율합이 상한을 넘으면 x/y/a 를 동일 비율로 축소(방향 보존). 0 분모는 안전 처리.
void GovernEnvelope(double* x, double* y, double* a, double period_ms);

// ===== O2 래치 단위 슬루 (G5) — 셰이핑 일원화: 가속 제한 ====================
// 인접 래치(반주기) 간 축당 최대 변화. 첫걸음 capturability 보호. 단일 정의(D1 공유).
static const double SLEW_DX_MAX      = 8.0;   // mm
static const double SLEW_DY_MAX      = 6.0;   // mm
static const double SLEW_DA_MAX      = 4.0;   // deg
static const double SLEW_DPERIOD_MAX = 60.0;  // ms
// 슬루 상태(마지막 적용값). valid=false 면 첫 적용 — 슬루 없이 target 수용 후 valid.
struct SlewState {
    double x, y, a, period;
    bool   valid;
    SlewState();
};
// st 에서 target(*x/*y/*a/*period)으로 축당 SLEW_*_MAX 만큼만 전진. *값을 갱신 + st 저장.
// 호출 cadence(래치당 1회)는 호출부가 결정 — 본 함수는 순수 1-스텝 클램프(호스트 테스트).
void SlewToward(SlewState* st, double* x, double* y, double* a, double* period);

// 슬루 전진 cadence 판정(순수) — last_slew_ms==0(미전진) 또는 반주기(period/2) 경과 시 true.
// period<=0 면 반주기 300ms 로 폴백. 브로커리지: ApplyCommandLine(명령 도착)·supervisor 루프
// (단발 명령 후 목표 도달까지 진행) 양쪽이 동일 판정을 공유한다.
bool SlewCadenceDue(long long now_ms, long long last_slew_ms, double period_ms);

// 슬루 현재값이 목표(x/y/a/period)에 도달했는가(축당 1e-6 허용) — 루프 진행 종료 가드.
bool SlewAtTarget(const SlewState& st, double x, double y, double a, double period);

// ===== O2 죽은 토큰 결선 (G7 일부) ==========================================
// Walking 출하 밸런스 게인(단일 정의) — blevel 배율의 곱셈 기준.
static const double BASE_BALANCE_KNEE_GAIN        = 0.3;
static const double BASE_BALANCE_ANKLE_PITCH_GAIN = 0.9;
static const double BASE_BALANCE_HIP_ROLL_GAIN    = 0.5;
static const double BASE_BALANCE_ANKLE_ROLL_GAIN  = 1.0;
// blevel(0..3) → 게인 배율 {0, 0.5, 1.0, 1.5}. 범위 밖은 끝값 클램프.
double BalanceGainScale(int blevel);

// ===== O2 속도 비례 게이트 스케줄 (역동성) ==================================
// |x|/x_max 가 GATE_SPEED_THRESH(상위 30%) 초과 시 선형 가산 — 발 클리어런스·측면 안정.
// FLAG_GATE_SCHED_OFF 이면 0. 기본 ON.
static const double GATE_SPEED_THRESH  = 0.70;  // x_max 대비 비율 임계
static const double GATE_ZMOVE_ADD_MAX = 5.0;   // mm (Z_MOVE_AMPLITUDE 가산)
static const double GATE_YSWAP_ADD_MAX = 2.0;   // mm (Y_SWAP_AMPLITUDE 가산)
static const double GATE_HIP_ADD_MAX   = 1.5;   // deg (HIP_PITCH_OFFSET 가산)
static const double DEFAULT_Y_SWAP_AMPLITUDE = 20.0;  // Walking 출하값(가산 기준).
struct GateBoost { double z_move, y_swap, hip; GateBoost(); };
// x(슬루 후 진폭)·period·flags 로 가산량 산출. 임계 이하 또는 OFF 면 0 boost.
GateBoost GateSchedule(double x, double period_ms, int flags);

// ===== latest-wins 슬롯 (KEEP_LAST depth 1) =================================
// transport 스레드가 Offer, supervisor 가 Take. mutex 보호 1칸.
class CommandSlot {
public:
    CommandSlot();
    ~CommandSlot();

    // 원시 명령 라인을 단조 seq 와 함께 제시. seq>0 이고 last_seq 이하면 거부(역행
    // datagram 폐기). seq==0 = 스트림 소스(순서 보장됨) → 내부 카운터로 항상 수용.
    // 저장하면 true, 거부하면 false.
    bool Offer(const char* line, long long seq);

    // 미소비 명령이 있으면 out(capacity)에 복사 + pending 해제, true. 없으면 false.
    bool Take(char* out, int capacity);

    long long LastSeq();

private:
    pthread_mutex_t m_mtx;
    char            m_line[256];
    long long       m_last_seq;    // 마지막 수용 seq (UDP 역행 검사)
    long long       m_stream_seq;  // 스트림(seq==0) 내부 단조 카운터
    bool            m_pending;

    // 비복사 (C++03: private 선언만).
    CommandSlot(const CommandSlot&);
    CommandSlot& operator=(const CommandSlot&);
};

// ===== 워치독 티어 (G3) =====================================================
enum WatchdogAction {
    WD_NONE      = 0,  // 정상 — 명령 신선.
    WD_SLEW_ZERO = 1,  // 600ms~ : 진폭 0 슬루(제자리 걸음). 토크 유지.
    WD_STOP      = 2   // 2.5s~  : Walking::Stop(). 토크 유지(컷은 E-STOP 만).
};

// 마지막 유효 명령 후 경과(ms) 기준 워치독 티어. 5s 레거시는 호출부가 별도 최후 방어로 유지.
static const long long WATCHDOG_SLEW_MS = 600;
static const long long WATCHDOG_STOP_MS = 2500;

// 워치독 티어 결정. WD_NONE 조건:
//  · !walking_active (정지 상태엔 무의미), 또는
//  · !from_stream — **티어는 UDP 슬롯(스트림) 소스 전용** (cross-review [HIGH] 2026-06-12).
//    파일 소스(Mac 브리지 dedup·Switch 변경 시만 송신)는 일정 스틱 홀드 시 명령이 갱신되지
//    않는 게 정상이므로, 600ms 제자리/2.5s 정지로 회귀시키면 안 된다 → 파일 경로는 5s STALE
//    backstop 만 적용. 스트림 소스(연속 20–30Hz)에서만 패킷 유실을 티어로 판정한다.
// 보행 중 + 스트림 소스일 때만 임계로 티어 결정.
WatchdogAction WatchdogDecision(long long elapsed_ms, bool walking_active, bool from_stream);

// ===== 데이터그램 파서 ======================================================
// "DF-ESTOP v1 {token} {ts}" — prefix + token 일치 시 true (ts 는 무시).
bool ParseEstopDatagram(const char* buf, int len, const char* token);

// "DFCMD {token} {seq} {line...}" — token 일치 시 seq + 나머지 line 추출, true.
// line_out 에 capacity 만큼 복사(널 종료). token 불일치/형식 오류 시 false.
bool ParseCmdDatagram(const char* buf, int len, const char* token,
                      long long* seq_out, char* line_out, int line_cap);

}  // namespace Robotis

#endif  // WALKLAB_TRANSPORT_H_
