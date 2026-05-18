/*
 * WalkLabBrokerage.h — DarwinForge WalkLab onboard brokerage mode
 *
 * v1.11.7 (2026-05-18) — Mac DarwinForge ↔ robot ROBOTIS Walking 엔진 bridge.
 *
 * Header. Implementation: WalkLabBrokerage.cpp.
 * 통합 절차: README-INTEGRATION.md 참조.
 */

#ifndef WALKLAB_BROKERAGE_H_
#define WALKLAB_BROKERAGE_H_

namespace Robotis {

class WalkLabBrokerage {
public:
    /// 명령 파일 경로 — Mac SSH 가 atomic mv 로 write.
    static constexpr const char* CMD_PATH = "/tmp/df-walklab-cmd";

    /// Polling 주기 (ms). Mac 측 50ms tick 의 4배 = 200ms = 5Hz.
    static constexpr int POLL_INTERVAL_MS = 200;

    /// 명령 stale 임계 (ms). Mac 명령 갱신 끊긴 후 자동 stop.
    static constexpr int STALE_TIMEOUT_MS = 5000;

    /// HIP_PITCH_OFFSET 안전 clamp 범위 (°).
    static constexpr double HIP_PITCH_MIN = 0.0;
    static constexpr double HIP_PITCH_MAX = 20.0;

    /// 무한 루프 — robot main() 가 호출. 외부에서 SIGTERM 또는 demo-pilot kill 까지 동작.
    void Run();

private:
    /// CMD_PATH 한 줄 read + parse + Walking 적용.
    /// @return true = 정상 parse, false = 파싱 실패 (이전 명령 유지).
    bool ParseAndApply(class Walking* walking, bool& walking_active);
};

}  // namespace Robotis

#endif  // WALKLAB_BROKERAGE_H_
