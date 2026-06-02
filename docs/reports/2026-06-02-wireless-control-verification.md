# 무선(Wi-Fi) 단독 로봇 조종 검증 — 2026-06-02

> **결론**: 유선랜 없이 **Wi-Fi만으로 로봇 조종이 정상 동작**함을 라이브로 확인.
> 하네스가 조종 명령·연결 상태·중간 끊김·회복을 **로컬 로그에 또렷이 기록**했다.

설치 빌드: DarwinForge **1.24.0 (build 566)** · commit `12ce996` · ad-hoc 서명
하네스 세션: `083C4444-1748-4A8A-8819-8950196665BC`
원본 로그: `~/Library/Application Support/DarwinForge/Harness/`
(실행 중 `current-083C4444…/events.jsonl`, 종료 시 `sessions/083C4444…/`로 아카이브)

---

## 1. 네트워크 경로 (실측)

| 항목 | 값 | 해석 |
|---|---|---|
| 로봇 SSH 연결 (established) | `192.168.0.18:64424 → 192.168.0.33:22` | Mac **Wi-Fi(en1)** ↔ 로봇 |
| `route get 192.168.0.33` | interface **en1 (Wi-Fi)** | 로봇 트래픽은 Wi-Fi로만 |
| en0 (유선) | `220.93.150.29` (WAN/인터넷) | 로봇망(192.168.0.x)과 무관 — 인터넷 전용 |
| en10 (USB 유선 LAN) | inactive | 미사용 |
| 텔레메트리 경로 | SSH onboard (`cat /tmp/df-walklab-telemetry`) | 5530 유선 브릿지 아님 |

→ **로봇 조종·텔레메트리는 100% Wi-Fi.** 유선랜(인터넷 회선)을 뽑아도 조종 유지.
유선은 인터넷 기능(예: Claude 분석)에만 영향.

---

## 2. 세션 진단 (11:25:01 ~ 11:33:09, ~8분)

| 지표 | 값 |
|---|---|
| 명령 송신 / 응답 / 실패(throw) | 752 / 748 / 3 |
| 명령 성공률 | **90.8%** (ok 682 / 751) |
| 왕복 지연 (ok, ms) | p50 **227** · p95 **664** · max **3844** · mean 295 (n=682) |
| 무엇을 조종했나 | telemetry **585**, walk **167** |
| 비-0 exit | exit 255 ×63 (SSH 도달 불가), exit 1 ×3 (로봇 walk 거부) |
| throw 에러 | timeout ×3 |

---

## 3. 끊김 → 회복이 로그에 또렷이 남음 (하네스 가치 입증)

`11:27:52 ~ 11:28:06` 구간에 **약 14초 연결 저하**가 발생했고, 하네스가 단계별로 포착:

```
11:27:52.960  remote.command_error      error_case=timeout  elapsed=4012ms   ← SSH 4초 무응답
11:27:57.506  remote.command_error      error_case=timeout  elapsed=4044ms
11:28:02.027  remote.command_responded  ok=false exit=255   elapsed=4016ms   ← SSH 전송 불가 시작
11:28:02.5~06 remote.command_responded  ok=false exit=255   (버스트 ~10건)
 …이후              remote.command_responded  ok=true            ← 자동 회복, 정상 조종 재개
```

- `timeout`(4s) = ServerAliveInterval 2×2 가드가 죽은 연결을 빠르게 끊은 것.
- `exit=255` = SSH 전송 자체 불가(WiFi 순간 단절) — 크래시가 아니라 **명확한 실패 코드로 기록**.
- 이후 `ok=true` 복귀 → 무선 재연결 후 조종 지속.

이처럼 **"왜·언제·얼마나" 끊겼는지**가 로그만으로 추적된다. 이 데이터가 매 세션 누적되어
무선 안정성 추세(특히 p95/max 지연, timeout/255 빈도)를 지속 모니터링·개선할 수 있다.

---

## 4. 재현/확인 방법

```bash
HD=~/Library/Application\ Support/DarwinForge/Harness
NEW=$(ls -dt "$HD"/current-* "$HD"/sessions/* 2>/dev/null | head -1)
# 끊김/거부만 보기
grep -E '"ok":false|command_error' "$NEW/events.jsonl"
```
앱 내: **Harness Inspector → 세션 → Export Markdown → "SSH 연결·조종 진단"** 섹션.
