/*
 * WalkLabBrokerage.cpp — DarwinForge WalkLab onboard brokerage mode
 *
 * v1.11.6 (2026-05-18) — Mac DarwinForge ↔ robot ROBOTIS Walking 엔진 bridge.
 *
 * Usage (robot main.cpp):
 *   #include "WalkLabBrokerage.h"
 *
 *   int main() {
 *     // ... motion manager / Walking init ...
 *
 *     // Pilot mode 파일 read.
 *     char mode[16] = {0};
 *     FILE* fp = fopen("/tmp/df-pilot-mode", "r");
 *     if (fp) { fscanf(fp, "%15s", mode); fclose(fp); }
 *
 *     if (strcmp(mode, "walklab") == 0) {
 *       WalkLabBrokerage brokerage;
 *       brokerage.Run();   // 무한 루프 — Mac SSH 명령 polling
 *     } else if (strcmp(mode, "soccer") == 0) {
 *       // 기존 SOCCER 모드 (ball tracker) ...
 *     } else {
 *       // 기존 READY 모드 ...
 *     }
 *     return 0;
 *   }
 *
 * 컴파일: gcc make 시 Framework/Linux/Makefile.mk 의 OBJS 에 WalkLabBrokerage.o 추가.
 */

#include "WalkLabBrokerage.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include "Walking.h"  // Robotis::Walking::GetInstance()
#include "MotionManager.h"

namespace Robotis {

    void WalkLabBrokerage::Run() {
        Walking* walking = Walking::GetInstance();
        if (!walking) {
            fprintf(stderr, "WalkLabBrokerage: Walking::GetInstance() == NULL\n");
            return;
        }

        printf("[WalkLabBrokerage] start polling %s every %dms\n",
               CMD_PATH, POLL_INTERVAL_MS);

        // 초기 default 상태 (정지).
        walking->X_MOVE_AMPLITUDE = 0.0;
        walking->Y_MOVE_AMPLITUDE = 0.0;
        walking->A_MOVE_AMPLITUDE = 0.0;
        walking->Z_MOVE_AMPLITUDE = 40.0;   // foot height default
        walking->PERIOD_TIME = 600.0;       // 600ms default
        walking->HIP_PITCH_OFFSET = 13.0;   // ROBOTIS 원본

        bool walking_active = false;
        time_t last_cmd_time = 0;
        struct stat last_stat = {};

        while (true) {
            struct stat current_stat = {};
            int stat_ret = stat(CMD_PATH, &current_stat);

            if (stat_ret == 0) {
                // 파일이 mtime 변경됐을 때만 re-parse (불필요한 disk read 회피).
                bool file_changed = (current_stat.st_mtime != last_stat.st_mtime) ||
                                    (current_stat.st_size != last_stat.st_size);
                if (file_changed) {
                    last_stat = current_stat;
                    if (ParseAndApply(walking, walking_active)) {
                        last_cmd_time = time(NULL);
                    }
                }

                // Stale check — Mac 명령 5초 이상 안 오면 자동 stop.
                if (walking_active && last_cmd_time > 0 &&
                    (time(NULL) - last_cmd_time) > (STALE_TIMEOUT_MS / 1000)) {
                    printf("[WalkLabBrokerage] stale > %dms — auto stop\n",
                           STALE_TIMEOUT_MS);
                    walking->Stop();
                    walking_active = false;
                }
            } else {
                // 파일 없음 — Mac 측 미연결. polling 만 유지.
                if (walking_active) {
                    walking->Stop();
                    walking_active = false;
                }
            }

            usleep(POLL_INTERVAL_MS * 1000);
        }
    }

    bool WalkLabBrokerage::ParseAndApply(Walking* walking, bool& walking_active) {
        FILE* fp = fopen(CMD_PATH, "r");
        if (!fp) return false;

        char line[256];
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp);
            return false;
        }
        fclose(fp);

        int enabled = 0;
        float x = 0, y = 0, a = 0, period = 0, foot = 0, hip = 13.0f;
        int n = sscanf(line, "%d %f %f %f %f %f %f",
                       &enabled, &x, &y, &a, &period, &foot, &hip);
        if (n < 6) {
            // 잘못된 line 무시 — 이전 명령 유지 (safety).
            return false;
        }
        if (n == 6) {
            // v1.11.5 (6 필드) backward-compat — hip 미전달 시 default 유지.
            hip = walking->HIP_PITCH_OFFSET;
        }

        // hip_pitch_deg clamp [0, 20].
        if (hip < HIP_PITCH_MIN) hip = HIP_PITCH_MIN;
        if (hip > HIP_PITCH_MAX) hip = HIP_PITCH_MAX;

        // PERIOD_TIME 갑작스러운 변경은 cycle 중간 불안정 — 다음 cycle 부터 적용 의도지만
        // ROBOTIS Walking.cpp 은 매 8ms tick 의 m_PeriodTime 갱신 → 즉시 반영.
        // (안정성 검증 필요 항목 — TODO.)
        walking->X_MOVE_AMPLITUDE = (double)x;
        walking->Y_MOVE_AMPLITUDE = (double)y;
        walking->A_MOVE_AMPLITUDE = (double)a;
        walking->Z_MOVE_AMPLITUDE = (double)foot;
        walking->PERIOD_TIME = (double)period;
        walking->HIP_PITCH_OFFSET = (double)hip;

        // enabled 토글 — Start/Stop edge 감지.
        bool want_active = (enabled != 0);
        if (want_active && !walking_active) {
            walking->Start();
            walking_active = true;
            printf("[WalkLabBrokerage] start (x=%.2f y=%.2f a=%.2f p=%.0f f=%.0f h=%.2f)\n",
                   x, y, a, period, foot, hip);
        } else if (!want_active && walking_active) {
            walking->Stop();
            walking_active = false;
            printf("[WalkLabBrokerage] stop\n");
        }
        // **v1.11.16.1 (2026-05-19)** — ACK write. Mac 측이 250ms 후 cat 으로 검증.
        // ts_ms = unix epoch * 1000 (간단한 monotonic ID).
        // 형식: "OK {ts_ms} {cmd_line}\n" — Mac 의 검출 regex 와 일치.
        FILE* ack = fopen(ACK_PATH, "w");
        if (ack) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            long long ts_ms = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
            fprintf(ack, "OK %lld %s", ts_ms, line);
            fclose(ack);
        }
        return true;
    }

}  // namespace Robotis
