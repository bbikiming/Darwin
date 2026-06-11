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
    double bgain;         // balance gain (현재 미적용 — O2)
    int    benable;       // balance enable (미적용 — O2)
    int    blevel;        // balance level 0..3 (미적용 — O2)
    double head_pan;      // deg, clamp [-90,90]
    double head_tilt;     // deg, clamp [-45,65]
    int    balltrack;     // 0/1
    bool   head_explicit; // 이 라인이 non-zero head 를 지시했는가
    WalkCommand();
};

// 명령 라인 1개 파싱 (cmd_id 포함 14-token / 미포함 13-token / 구형 6-token).
// 안전 클램프(hip 0..20, head pan ±90, tilt -45..65) 적용. 토큰 부족(≥6 실패) 시 false
// → 호출부는 이전 명령 유지(safety). out 은 항상 유효 기본값으로 시작.
bool ParseCommandLine(const char* line, WalkCommand* out);

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
