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
//
// **Anbernic 고도화 P2/P3/P4 (2026-06-13, docs/design/anbernic-gait-upgrade.md)** —
// 좌우 고속·회전 대각·복합 유기화. 불변식: ENVELOPE_Y_MAX/A_MAX 는 게임패드 클램프
// GP_MAX_SIDE_MM/GP_MAX_TURN_DEG 와 **항상 동일값**으로 같이 변경(작은 쪽이 클램프).
// 이 거버너는 전 클라이언트(Switch·핸드헬드·bus-direct) 공유 최종 클램프이므로 상향 시
// 게임패드뿐 아니라 전 클라이언트 회전·횡속이 함께 빨라진다(의도된 전역 변경).
// 2단계(좌우 32·회전 20·L2 엔벨로프)는 온스탠드 IK-freeze 스윕 검증 후에만 — 보류.
static const double ENVELOPE_SUM_MAX = 1.25;  // P3: 1.15→1.25 (L1 budget — 3축 동시최대 collapse 38%→41.7% 완화; 단일축·≤1.15 블렌드는 종전과 동일)
static const double ENVELOPE_Y_MAX   = 28.0;  // mm — P2: 22→28 (GP_MAX_SIDE_MM 과 동일). 32 는 P7 스윕 후
static const double ENVELOPE_A_MAX   = 18.0;  // deg — P4: 12→18 (GP_MAX_TURN_DEG 과 동일, 발 yaw peak 9°). 20 은 P7
// period 종속 x_max(mm) 스케줄 — 초기값(벤치로 갱신). 경계 밖 끝값 고정, 중간 선형 보간.
//   700ms→40, 600→38, 500→32, 440→28.
double EnvelopeXMax(double period_ms);
// 비율합이 상한을 넘으면 x/y/a 를 동일 비율로 축소(방향 보존). 0 분모는 안전 처리.
void GovernEnvelope(double* x, double* y, double* a, double period_ms);

// ===== O2 래치 단위 슬루 (G5) — 셰이핑 일원화: 가속 제한 ====================
// 인접 래치(반주기) 간 축당 최대 변화. 첫걸음 capturability 보호. 단일 정의(D1 공유).
// **Anbernic 고도화 P5** — 좌우 응답성·회전 끊김 완화: DY 6→7, DA 4→6(끊김 직접 원인).
// 둘 다 SLEW_DX_MAX=8 미만 유지(측·회전 첫걸음 capturability 가 전진보다 빡빡).
static const double SLEW_DX_MAX      = 8.0;   // mm
static const double SLEW_DY_MAX      = 7.0;   // mm — P5: 6→7 (측보 시작 응답성)
static const double SLEW_DA_MAX      = 6.0;   // deg — P5: 4→6 (0→18 ~3 latch·끊김 완화; 7 은 표면별 검증 후 P7)
static const double SLEW_DPERIOD_MAX = 60.0;  // ms
// 슬루 상태(마지막 적용값). valid=false 면 첫 적용 — 슬루 없이 target 수용 후 valid.
struct SlewState {
    double x, y, a, period;
    bool   valid;
    SlewState();
};
// **Anbernic 고도화 P1 — 동기화(co-arrival) 슬루**: 세 이동축(x/y/a)이 같은 래치 수 N 에
// 함께 도달하도록 각 축을 (target-prev)/N 전진. N = 각 축이 자기 캡(SLEW_*_MAX)으로
// 도달하는 데 필요한 래치 수의 최댓값. 어떤 축도 자기 캡을 넘지 않으며(|Δ|/N ≤ cap),
// 빠른 축을 느린 축에 맞춰 늦춰 twist 벡터를 *직선* 이동 → 복합 전이가 한 곡선·peak
// twist rate↓(turn-then-drift 제거). 단일/지배축은 Δ/N(≤자기 캡, 균등 페이싱)으로 전진 —
// 도달 래치 수는 ceil(|Δ|/cap)로 종전과 동일(Δ가 캡의 정수배일 때만 첫 스텝=캡, 예 40/8).
// period 는 종전대로 독립 대칭 슬루(케이던스는 보행 강도 종속, co-arrival 불요).
// 호출 cadence(래치당 1회)는 호출부가 결정 — 본 함수는 순수 1-스텝(호스트 테스트).
void SlewToward(SlewState* st, double* x, double* y, double* a, double* period);

// 슬루 전진 cadence 판정(순수) — last_slew_ms==0(미전진) 또는 반주기(period/2) 경과 시 true.
// period<=0 면 반주기 300ms 로 폴백. 브로커리지: ApplyCommandLine(명령 도착)·supervisor 루프
// (단발 명령 후 목표 도달까지 진행) 양쪽이 동일 판정을 공유한다.
bool SlewCadenceDue(long long now_ms, long long last_slew_ms, double period_ms);

// 슬루 현재값이 목표(x/y/a/period)에 도달했는가(축당 1e-6 허용) — 루프 진행 종료 가드.
bool SlewAtTarget(const SlewState& st, double x, double y, double a, double period);

// ===== O2 죽은 토큰 결선 (G7 일부) ==========================================
// Walking 출하 밸런스 게인(단일 정의) — blevel 배율의 곱셈 기준.
// **Anbernic 고도화 P0 (2026-06-13)** — 좌우 진폭 상향 전, lateral 자이로 권한을 factory
// config.ini(hip_roll=0.6, ankle_roll=1.2) 검증값으로 먼저 복원. Walking.cpp 표준 빌드는
// `*4` 경로(L588-598, MX28_1024 미정의 실측)라 효과 게인 hip_roll≈2.4/ankle_roll≈4.8.
// NOTE(검증 지적·미변경): sagittal(knee 0.3>factory 0.2, ankle_pitch 0.9>factory 0.6)은
// factory 를 *초과* — 의도/불일치 확정은 별도 리뷰(무성찰 일괄 정합은 sagittal 거동 변경 위험).
static const double BASE_BALANCE_KNEE_GAIN        = 0.3;
static const double BASE_BALANCE_ANKLE_PITCH_GAIN = 0.9;
static const double BASE_BALANCE_HIP_ROLL_GAIN    = 0.6;  // P0: 0.5→0.6 (factory 정합 — lateral 권한 복원)
static const double BASE_BALANCE_ANKLE_ROLL_GAIN  = 1.2;  // P0: 1.0→1.2 (factory 정합 — lateral CoP 유지)
// blevel(0..3) → 게인 배율 {0, 0.5, 1.0, 1.5}. 범위 밖은 끝값 클램프.
double BalanceGainScale(int blevel);

// ===== O2 속도 비례 게이트 스케줄 (역동성) ==================================
// max(|x|/x_max, |y|/ENVELOPE_Y_MAX) 가 GATE_SPEED_THRESH(상위 30%) 초과 시 선형 가산 —
// 발 클리어런스·측면 안정. FLAG_GATE_SCHED_OFF 이면 0. 기본 ON.
// **Anbernic 고도화 P6 — gate-on-y**: 종전 ratio=|x|/x_max 만이라 순수 strafe(x=0)는 boost
// 0 을 받아 발 클리어런스·body sway 증대 없이 진폭만 커지는 IK-freeze 최근접 구성이었다.
// y 를 인자로 받아 측보도 Y_SWAP/Z_MOVE boost 를 받게 한다(swing foot lateral CoM feasible).
// (DEFAULT_Y_SWAP_AMPLITUDE 상수 상향은 무효 — Run 진입 시 config 19 로 덮어씀, brokerage
//  L1078 실측. 추가 sway 는 오직 이 gate-on-y(slew-bounded·speed-gated)로.)
static const double GATE_SPEED_THRESH  = 0.70;  // x_max/y_max 대비 비율 임계
static const double GATE_ZMOVE_ADD_MAX = 5.0;   // mm (Z_MOVE_AMPLITUDE 가산)
static const double GATE_YSWAP_ADD_MAX = 2.0;   // mm (Y_SWAP_AMPLITUDE 가산)
static const double GATE_HIP_ADD_MAX   = 1.5;   // deg (HIP_PITCH_OFFSET 가산)
static const double DEFAULT_Y_SWAP_AMPLITUDE = 20.0;  // Walking 출하값(가산 기준).
struct GateBoost { double z_move, y_swap, hip; GateBoost(); };
// x·y(슬루 후 진폭)·period·flags 로 가산량 산출. 임계 이하 또는 OFF 면 0 boost.
GateBoost GateSchedule(double x, double y, double period_ms, int flags);

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
    // seq_out(non-NULL)에는 그 명령이 수용된 seq 를 적재(스트림 소스는 내부 단조 카운터,
    // UDP 소스는 datagram seq) — O4 TEL2 `seq_applied` 폐루프(Mac 이 적용 확인)용.
    bool Take(char* out, int capacity, long long* seq_out = 0);

    long long LastSeq();

private:
    pthread_mutex_t m_mtx;
    char            m_line[256];
    long long       m_last_seq;    // 마지막 수용 seq (UDP 역행 검사)
    long long       m_stream_seq;  // 스트림(seq==0) 내부 단조 카운터
    long long       m_pending_seq; // 현재 pending 라인이 수용된 seq (O4 — Take seq_out).
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

// ===== 서보 알람 셧다운 가드 (실기 F8, 2026-06-12) — 순수 판정 ================
// 실기 증상: 보행 벤치 후 양 발목 피치(ID15/16)가 빨간 LED 점등 + 무토크,
// getup/estop 해제(복구)로도 미복구. 원인: MX-28 알람 셧다운(과부하 err=0x20)이
// Torque Limit(addr 34)을 0 으로 강제 — 전원 재투입 또는 재기록 전까지 토크 불가.
// 복구 의미론: 셧다운 래치의 단일 진실은 **tl==0** (err 비트는 부하에 따라
// transient — tl>0 이면 토크 가능하므로 복원 대상 아님). 복원은 온도 가드 하에.

enum ServoGuardAction {
    SG_NONE     = 0,   // 정상(tl>0) 또는 무응답(추측 복원 금지)
    SG_RESTORE  = 1,   // 셧다운 래치 + 안전 온도 — Torque Limit 복원
    SG_SKIP_HOT = 2    // 셧다운 래치 + 과열/온도 미상 — 냉각 후 복구 재시도
};

// DXL protocol 1.0 status error 비트 (보고용 — 판정은 tl==0 이 1차 신호).
static const int DXL_ERR_OVERHEAT = 0x04;
static const int DXL_ERR_OVERLOAD = 0x20;

// protocol 1.0 RAM 레지스터 (MX-28) — 프레임워크 MX28.h 와 동일 값(프로토콜 고정).
static const int SG_ADDR_TORQUE_LIMIT_L      = 34;
static const int SG_ADDR_PRESENT_TEMPERATURE = 43;

// 복원값(MX-28 공장 기본 최대)·온도 상한(셧다운 기본 80°C 에서 15°C 마진)·ID 범위.
static const int SG_TORQUE_LIMIT_RESTORE = 1023;
static const int SG_TEMP_SAFE_C          = 65;
static const int SG_JOINT_ID_MIN         = 1;    // JointData::ID_R_SHOULDER_PITCH
static const int SG_JOINT_ID_MAX         = 20;   // JointData::ID_HEAD_TILT

// 실기 F10 (2026-06-13) — E-STOP 복구 소프트 토크 램프. 재무장 시 Torque Limit 을
// 단계 상승시켜 관절이 목표 자세로 '부드럽게' 끌려가게 한다(스냅 방지). 시작값
// 30%는 직립 자세 유지에 충분한 하한(접지 복구 시 무릎 붕괴 방지), 종값은 복원
// 최대와 동일. 총 소요 ≈ 4×150ms = 0.6s — 복구 순간 supervisor 블록 허용 범위.
static const int SG_SOFT_RAMP_STEPS = 4;
static const int SG_SOFT_RAMP_VALUES[SG_SOFT_RAMP_STEPS] = { 300, 600, 900, 1023 };
static const int SG_SOFT_RAMP_INTERVAL_MS = 150;

// 판정. read_ok = Torque Limit read 성공(무응답이면 손대지 않는다),
// temp_ok = 온도 read 성공(미상이면 보수적으로 SKIP_HOT — 복원 보류).
ServoGuardAction ServoGuardDecide(bool read_ok, int torque_limit,
                                  bool temp_ok, int temp_c);

// ===== 데이터그램 파서 ======================================================
// "DF-ESTOP v1 {token} {ts}" — prefix + token 일치 시 true (ts 는 무시).
bool ParseEstopDatagram(const char* buf, int len, const char* token);

// "DFCMD {token} {seq} {line...}" — token 일치 시 seq + 나머지 line 추출, true.
// line_out 에 capacity 만큼 복사(널 종료). token 불일치/형식 오류 시 false.
bool ParseCmdDatagram(const char* buf, int len, const char* token,
                      long long* seq_out, char* line_out, int line_cap);

// ===== O4 TEL2 텔레메트리 v2 포맷터 (순수 — Robot:: 의존 0, 호스트 테스트) ======
// 형식(ssh-parity-contract §A.2 TEL2):
//   "TEL2 {ts} {seq_applied} {phase} {x_lat} {y_lat} {a_lat} {period_lat}
//    {gx gy gz ax ay az} {fsr l1..l4 r1..r4 | -} {copx copy | -}
//    {fallen} {risk|-} {vdV} {active_source} {loop_ms}\n"
// 가변 토큰: FSR 미장착 시 그 그룹은 단일 "-", CoP 미가용 시 "-", risk 미가용(O3 미구현)
//   시 "-". x/y/a/period_lat·risk 는 소수 2자리, FSR 셀·CoP·ADC·phase 는 정수.
// fsr8 은 fsr_present 일 때만 8개(l1..l4 r1..r4) 정수를 읽는다. copx/copy 는 정수(FSR_X/Y
//   바이트 평균 — 전신 균형 인디케이터; 발별 CoP 는 Mac 이 셀에서 재구성). active_source 는
//   "udp"/"file". snprintf 의미(반환=기록 길이, 잘림 시 cap 으로 클램프는 호출부).
int FormatTel2(char* out, int cap,
               long long ts_ms, long long seq_applied, int phase,
               double x_lat, double y_lat, double a_lat, double period_lat,
               int gx, int gy, int gz, int ax, int ay, int az,
               bool fsr_present, const int* fsr8,
               bool cop_present, int copx, int copy,
               int fallen, bool risk_present, double risk,
               int vdV, const char* active_source, long long loop_ms);

}  // namespace Robotis

#endif  // WALKLAB_TRANSPORT_H_
